import Foundation
import ZoopShared

/// Shared conversation engine: runs one approved task by looping model → tools → model until the model
/// calls `finish_task`, a limit is reached, or the task is cancelled.
///
/// Each step sends the whole conversation (with only the newest screenshots as images), runs
/// the requested tools one after another, and appends their results. Screenshots go back as
/// a user message after the tool results, because OpenAI-compatible tool messages carry text only.
struct AgentSession: Sendable {
    let model: any ChatModel
    let tools: any ToolRunning
    let prompter: any UserPrompting
    let limits: ExecutorLimits

    init(model: any ChatModel, tools: any ToolRunning, prompter: any UserPrompting, limits: ExecutorLimits = ExecutorLimits()) {
        self.model = model
        self.tools = tools
        self.prompter = prompter
        self.limits = limits
    }

    /// Runs the task. `onEvent` receives every step as it happens. Cancel the calling task to
    /// stop between steps; the outcome is then `cancelled`.
    func run(_ task: ExecutorTask, history initialHistory: [ModelMessage]? = nil,
             system: String = ExecutorPrompt.system, allowsStepDone: Bool = false,
             allowsTaskCompletion: Bool = true, failedAttempts: [String] = [],
             onEvent: @Sendable (AgentEvent) -> Void = { _ in }) async -> SessionOutcome {
        var history = initialHistory ?? [.user(ExecutorPrompt.taskMessage(task))]
        // Failed actions since the last successful one. At the limit the session refuses further
        // actions; the model must report with finish_task or the session ends with this list.
        var failures = failedAttempts
        var refusedResponses = 0
        var usage = ModelUsage(inputTokens: 0, outputTokens: 0)
        var step = 0
        var nudges = 0
        var focusedMouseApp: String?
        var observedMouseApp: String?
        let extraTools = await tools.extraModelTools()
        let system = extraTools.contains { $0.name.hasPrefix("browser_") } ? system + "\n\n" + BrowserToolRunner.guide : system
        let toolList = SessionTools.catalog.map(ModelTool.init) + extraTools + ExecutorPrompt.controlTools + (allowsStepDone ? [ExecutorPrompt.stepDoneTool] : [])
        onEvent(.started(model: model.name))

        func end(_ status: AgentOutcome.Status, _ summary: String, report: String? = nil) -> SessionOutcome {
            let outcome = AgentOutcome(status: status, summary: summary, report: report, steps: step, usage: usage)
            onEvent(.finished(outcome))
            return SessionOutcome(outcome: outcome, taskFinished: true)
        }

        while step < limits.maxSteps {
            if Task.isCancelled { return end(.cancelled, "Stopped by the person.") }
            // Only screenshots the model has actually received can ground a visual click.
            let mouseAppSeenByModel = observedMouseApp
            step += 1
            onEvent(.step(step))
            let response: ModelResponse
            do {
                response = try await model.complete(ModelRequest(system: system,
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
            if failures.count >= limits.maxFailedAttempts,
               !response.message.toolCalls.contains(where: {
                   $0.name == ExecutorPrompt.Control.finishTask.rawValue ||
                   $0.name == ExecutorPrompt.Control.requestDialogHelp.rawValue
               }) {
                refusedResponses += 1
                if refusedResponses > 1 {
                    return end(.failed, Self.failureReport(failures))
                }
            }

            var screenshots: [(id: String, image: ToolImage)] = []
            var mustObserve = false
            var finished: AgentOutcome?
            var taskFinished = true
            for call in response.message.toolCalls {
                if mustObserve {
                    history.append(.toolResult(id: call.id, Self.invalid("Skipped: the previous click requires a fresh screenshot. Inspect the automatic screenshot in the next response before continuing or finishing.")))
                    continue
                }
                if finished != nil {
                    history.append(.toolResult(id: call.id, #"{"ok":false,"error":"skipped","message":"The task already finished."}"#))
                    continue
                }
                if Task.isCancelled { return end(.cancelled, "Stopped by the person.") }
                switch ExecutorPrompt.Control(rawValue: call.name) {
                case .finishTask?:
                    let args = Self.arguments(call)
                    guard let success = args?["success"]?.boolValue, var summary = args?["summary"]?.stringValue else {
                        history.append(.toolResult(id: call.id, Self.invalid("finish_task needs success (boolean) and summary (string)")))
                        continue
                    }
                    if !success, let next = args?["next_step"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !next.isEmpty {
                        summary += "\n\nSuggested next step: \(next)"
                    }
                    guard !success || allowsTaskCompletion else {
                        history.append(.toolResult(id: call.id, Self.invalid("Use step_done after this step; final task verification comes later.")))
                        continue
                    }
                    history.append(.toolResult(id: call.id, #"{"ok":true}"#))
                    let report = args?["report_markdown"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                    finished = AgentOutcome(status: success ? .completed : .failed, summary: summary, report: report,
                                            steps: step, usage: usage)
                case .stepDone?:
                    guard allowsStepDone, let summary = Self.arguments(call)?["summary"]?.stringValue, !summary.isEmpty,
                          let complete = Self.arguments(call)?["complete"]?.boolValue else {
                        history.append(.toolResult(id: call.id, Self.invalid("step_done needs a summary and complete (true or false), and is only available during a plan step")))
                        continue
                    }
                    history.append(.toolResult(id: call.id, #"{"ok":true}"#))
                    // An unfinished step ends the task: later steps depend on it, so moving on would
                    // act on missing results (for example saving a quote whose numbers were never computed).
                    taskFinished = !complete
                    finished = AgentOutcome(status: complete ? .completed : .failed,
                                            summary: complete ? summary : "This step could not be completed, so Zoop stopped before the next one. \(summary)",
                                            steps: step, usage: usage)
                case .askUser?:
                    guard let question = Self.arguments(call)?["question"]?.stringValue, !question.isEmpty else {
                        history.append(.toolResult(id: call.id, Self.invalid("ask_user needs a question")))
                        continue
                    }
                    let kind = Self.arguments(call)?["kind"]?.stringValue.flatMap(QuestionKind.init(rawValue:)) ?? .info
                    onEvent(.question(question))
                    let answer = await prompter.ask(question, kind: kind) ?? ""
                    onEvent(.answer(answer))
                    history.append(.toolResult(id: call.id, JSONValue.object(["answer": .string(answer)]).jsonText))
                case .reportProgress?:
                    guard let args = Self.arguments(call), let note = args["note"]?.stringValue else {
                        history.append(.toolResult(id: call.id, Self.invalid("report_progress needs a note")))
                        continue
                    }
                    let percent = args["percent"]?.numberValue.map { Int(min(100, max(0, $0))) }
                    onEvent(.progress(note: note, step: args["step"]?.numberValue.flatMap { Int(exactly: $0) }, percent: percent))
                    history.append(.toolResult(id: call.id, #"{"ok":true}"#))
                case .requestDialogHelp?, nil:
                    let dialogHelp = call.name == ExecutorPrompt.Control.requestDialogHelp.rawValue
                    let isAction = dialogHelp || BrowserToolRunner.isAction(call.name) || (SessionTools.catalog.first { $0.name.rawValue == call.name }.map { !$0.isReadOnly } ?? false)
                    let args = Self.arguments(call)
                    // Dialogs are answered by the person, never clicked by the agent. Asking is
                    // allowed at any time, including at the retry limit.
                    if dialogHelp, args?["bundle_id"]?.stringValue?.isEmpty != false {
                        history.append(.toolResult(id: call.id, Self.invalid("request_dialog_help needs the bundle_id of the app showing the dialog.")))
                        continue
                    }
                    if call.name == "click", args?["strategy"] == "mouse" {
                        let app = args?["bundle_id"]?.stringValue
                        guard let app, app == mouseAppSeenByModel, app == observedMouseApp else {
                            history.append(.toolResult(id: call.id, Self.invalid("Visual mouse recovery needs open_app for this bundle_id, then screenshot in a later call. Inspect the returned image in a new response before choosing x/y. No click was sent.")))
                            continue
                        }
                    }
                    if isAction, !dialogHelp, failures.count >= limits.maxFailedAttempts {
                        history.append(.toolResult(id: call.id, JSONValue.object([
                            "ok": false, "error": "retry_limit",
                            "message": .string("\(failures.count) automatic attempts already failed. Do not act again. If an app dialog is open, request_dialog_help asks the person to answer it; otherwise call finish_task with success false, what you tried, and next_step.")]).jsonText))
                        continue
                    }
                    onEvent(.toolStarted(name: call.name, arguments: call.arguments))
                    let result = await tools.call(call.name, argumentsJSON: call.arguments)
                    onEvent(.toolFinished(name: call.name, result: result))
                    var text = result.text
                    mustObserve = result.requiresObservation
                    if isAction { observedMouseApp = nil }
                    if call.name == "open_app", !result.isError {
                        focusedMouseApp = args?["bundle_id"]?.stringValue
                    }
                    if call.name == "screenshot", !result.isError, result.image != nil {
                        observedMouseApp = focusedMouseApp
                    }
                    if isAction {
                        if result.isError || result.content["verified"] == false {
                            failures.append(Self.attempt(call, result))
                            if failures.count < limits.maxFailedAttempts {
                                text += "\n[Attempt \(failures.count) of \(limits.maxFailedAttempts) failed. Find out why, then try a different method. Do not repeat this action unchanged.]"
                            } else {
                                text += "\n[Attempt \(failures.count) of \(limits.maxFailedAttempts) failed. That was the last attempt: call finish_task now with success false, what you tried, and next_step.]"
                            }
                        } else {
                            failures = []
                        }
                    }
                    if let image = result.image {
                        screenshots.append((call.id, image))
                        text += "\n(The image follows in the next message.)"
                    }
                    history.append(.toolResult(id: call.id, text))
                }
            }
            if mustObserve {
                onEvent(.toolStarted(name: "screenshot", arguments: "{}"))
                let shot = await tools.call("screenshot", argumentsJSON: "{}")
                onEvent(.toolFinished(name: "screenshot", result: shot))
                guard !shot.isError, let image = shot.image else {
                    return end(.failed, "Cannot check the last click; it may have happened. No retry was sent. \(shot.text)")
                }
                screenshots.append(("automatic click verification", image))
                history.append(.user("Inspect this fresh screenshot before continuing. If an AX click had no effect, focus the app with open_app, screenshot again and try strategy mouse at the visually located target. Never click, type or press keys in a dialog or sheet: if one is open, call request_dialog_help with the app bundle_id and the person answers it. Do not repeat a click or the person's dialog choice if its intended effect is already visible. PID mouse delivery and a dialog closing do not establish task completion."))
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
                return SessionOutcome(outcome: outcome, taskFinished: taskFinished)
            }
        }
        return end(.failed, "Stopped after \(limits.maxSteps) steps without finishing.")
    }

    // MARK: - Helpers

    /// Keeps the newest `keepingImages` image-bearing messages intact and replaces older
    /// images with a note, so the conversation does not grow by a screenshot every step.
    /// Older long tool results (such as accessibility trees from `list_elements`) are cut the
    /// same way: the newest `keepingToolResults` stay whole, and older ones keep only a short preview.
    static func render(_ history: [ModelMessage], keepingImages: Int,
                       keepingToolResults: Int = 4, trimmedToolPreview: Int = 400) -> [ModelMessage] {
        var remaining = keepingImages
        var remainingTools = keepingToolResults
        var result = history
        for index in result.indices.reversed() {
            if result[index].role == .tool {
                if remainingTools > 0 { remainingTools -= 1; continue }
                let text = result[index].text
                guard text.count > trimmedToolPreview * 2 else { continue }
                result[index].content = [.text(String(text.prefix(trimmedToolPreview))
                    + "\n[Older tool output trimmed to save space: \(text.count - trimmedToolPreview) more characters. Call the tool again if you need it.]")]
                continue
            }
            let hasImage = result[index].content.contains { if case .image = $0 { true } else { false } }
            guard hasImage else { continue }
            if remaining > 0 { remaining -= 1; continue }
            result[index].content = result[index].content.map { part in
                if case .image = part { .text("[Older screenshot removed to save space.]") } else { part }
            }
        }
        return result
    }

    static func attempt(_ call: ModelToolCall, _ result: ToolResult) -> String {
        let reason = result.content["message"]?.stringValue ?? result.content["error"]?.stringValue ?? String(result.text.prefix(160))
        return "\(call.name) \(String(call.arguments.prefix(100))): \(String(reason.prefix(160)))"
    }

    /// Used when the model keeps acting after the retry limit instead of reporting.
    static func failureReport(_ attempts: [String]) -> String {
        "Stopped after \(attempts.count) failed attempts:\n" + attempts.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            + "\n\nSuggested next step: check the agent session (it may need a sign-in or a different page), then send the task again with more detail."
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

struct SessionOutcome: Sendable {
    let outcome: AgentOutcome
    let taskFinished: Bool
}
