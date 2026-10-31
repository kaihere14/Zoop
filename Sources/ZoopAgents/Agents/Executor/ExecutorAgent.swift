import Foundation
import ZoopShared

/// The executor: runs one approved task by looping model → tools → model until the model
/// calls `finish_task`, a limit is reached, or the task is cancelled.
///
/// Each step sends the whole conversation (with only the newest screenshots as images), runs
/// the requested tools one after another, and appends their results. Screenshots go back as
/// a user message after the tool results, because OpenAI-compatible tool messages carry text only.
public struct ExecutorAgent: Sendable {
    let model: any ChatModel
    let tools: any ToolRunning
    let prompter: any UserPrompting
    let limits: ExecutorLimits

    public init(model: any ChatModel, tools: any ToolRunning, prompter: any UserPrompting, limits: ExecutorLimits = ExecutorLimits()) {
        self.model = model
        self.tools = tools
        self.prompter = prompter
        self.limits = limits
    }

    /// Runs the task. `onEvent` receives every step as it happens. Cancel the calling task to
    /// stop between steps; the outcome is then `cancelled`.
    public func run(_ task: ExecutorTask, onEvent: @Sendable (AgentEvent) -> Void = { _ in }) async -> AgentOutcome {
        var history: [ModelMessage] = [.user(ExecutorPrompt.taskMessage(task))]
        var usage = ModelUsage(inputTokens: 0, outputTokens: 0)
        var step = 0
        var nudges = 0
        let toolList = SessionTools.catalog.map(ModelTool.init) + ExecutorPrompt.controlTools
        onEvent(.started(model: model.name))

        func end(_ status: AgentOutcome.Status, _ summary: String, report: String? = nil) -> AgentOutcome {
            let outcome = AgentOutcome(status: status, summary: summary, report: report, steps: step, usage: usage)
            onEvent(.finished(outcome))
            return outcome
        }

        while step < limits.maxSteps {
            if Task.isCancelled { return end(.cancelled, "Stopped by the person.") }
            step += 1
            onEvent(.step(step))
            let response: ModelResponse
            do {
                response = try await model.complete(ModelRequest(system: ExecutorPrompt.system,
                                                                 messages: Self.render(history, keepingImages: limits.keptScreenshots),
                                                                 tools: toolList, maxOutputTokens: limits.maxOutputTokens))
            } catch is CancellationError {
                return end(.cancelled, "Stopped by the person.")
            } catch {
                if Task.isCancelled { return end(.cancelled, "Stopped by the person.") }
                return end(.failed, "The model call failed: \(error)")
            }
            if let used = response.usage {
                usage.inputTokens += used.inputTokens
                usage.outputTokens += used.outputTokens
                onEvent(.usage(usage))
            }
            history.append(response.message)
            let thought = response.message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !thought.isEmpty { onEvent(.thought(thought)) }

            guard !response.message.toolCalls.isEmpty else {
                nudges += 1
                if nudges > limits.maxNudges {
                    return end(.failed, thought.isEmpty ? "The model stopped without finishing the task." : thought)
                }
                history.append(.user(ExecutorPrompt.nudge))
                continue
            }
            nudges = 0

            var screenshots: [(id: String, image: ToolImage)] = []
            var finished: AgentOutcome?
            for call in response.message.toolCalls {
                if finished != nil {
                    history.append(.toolResult(id: call.id, #"{"ok":false,"error":"skipped","message":"The task already finished."}"#))
                    continue
                }
                if Task.isCancelled { return end(.cancelled, "Stopped by the person.") }
                switch ExecutorPrompt.Control(rawValue: call.name) {
                case .finishTask?:
                    let args = Self.arguments(call)
                    guard let success = args?["success"]?.boolValue, let summary = args?["summary"]?.stringValue else {
                        history.append(.toolResult(id: call.id, Self.invalid("finish_task needs success (boolean) and summary (string)")))
                        continue
                    }
                    history.append(.toolResult(id: call.id, #"{"ok":true}"#))
                    let report = args?["report_markdown"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                    finished = AgentOutcome(status: success ? .completed : .failed, summary: summary, report: report,
                                            steps: step, usage: usage)
                case .askUser?:
                    guard let question = Self.arguments(call)?["question"]?.stringValue, !question.isEmpty else {
                        history.append(.toolResult(id: call.id, Self.invalid("ask_user needs a question")))
                        continue
                    }
                    onEvent(.question(question))
                    let answer = await prompter.ask(question) ?? ""
                    onEvent(.answer(answer))
                    history.append(.toolResult(id: call.id, JSONValue.object(["answer": .string(answer)]).jsonText))
                case .reportProgress?:
                    guard let args = Self.arguments(call), let note = args["note"]?.stringValue else {
                        history.append(.toolResult(id: call.id, Self.invalid("report_progress needs a note")))
                        continue
                    }
                    let percent = args["percent"]?.numberValue.map { min(100, max(0, Int($0))) }
                    onEvent(.progress(note: note, step: args["step"]?.numberValue.map(Int.init), percent: percent))
                    history.append(.toolResult(id: call.id, #"{"ok":true}"#))
                case nil:
                    onEvent(.toolStarted(name: call.name, arguments: call.arguments))
                    let result = await tools.call(call.name, argumentsJSON: call.arguments)
                    onEvent(.toolFinished(name: call.name, result: result))
                    var text = result.text
                    if let image = result.image {
                        screenshots.append((call.id, image))
                        text += "\n(The image follows in the next message.)"
                    }
                    history.append(.toolResult(id: call.id, text))
                }
            }
            if !screenshots.isEmpty {
                var content: [ModelContent] = []
                for shot in screenshots {
                    content.append(.text("Screenshot from tool call \(shot.id), \(shot.image.width)×\(shot.image.height); one pixel is one screen point."))
                    if let jpeg = ImageCompression.jpeg(fromPNG: shot.image.data) {
                        content.append(.image(data: jpeg, mediaType: "image/jpeg"))
                    } else {
                        content.append(.image(data: shot.image.data, mediaType: shot.image.mediaType))
                    }
                }
                history.append(ModelMessage(role: .user, content: content))
            }
            if var outcome = finished {
                outcome.usage = usage
                onEvent(.finished(outcome))
                return outcome
            }
        }
        return end(.failed, "Stopped after \(limits.maxSteps) steps without finishing.")
    }

    // MARK: - Helpers

    /// Keeps the newest `keepingImages` image-bearing messages intact and replaces older
    /// images with a note, so the conversation does not grow by a screenshot every step.
    static func render(_ history: [ModelMessage], keepingImages: Int) -> [ModelMessage] {
        var remaining = keepingImages
        var result = history
        for index in result.indices.reversed() {
            let hasImage = result[index].content.contains { if case .image = $0 { true } else { false } }
            guard hasImage else { continue }
            if remaining > 0 { remaining -= 1; continue }
            result[index].content = result[index].content.map { part in
                if case .image = part { .text("[Older screenshot removed to save space.]") } else { part }
            }
        }
        return result
    }

    static func arguments(_ call: ModelToolCall) -> JSONValue? {
        let text = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        return try? JSONValue.parse(text.isEmpty ? "{}" : text)
    }

    static func invalid(_ message: String) -> String {
        JSONValue.object(["ok": false, "error": "invalid_arguments", "message": .string(message),
                          "next": "Fix the arguments and call again."]).jsonText
    }
}
