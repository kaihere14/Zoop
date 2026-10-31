import Foundation
import Testing
@testable import ZoopAgents
import ZoopShared

/// Replays scripted model responses and records every request it receives.
actor ScriptedModel: ChatModel {
    nonisolated let name = "fake/scripted"
    private var script: [Result<ModelResponse, ModelError>]
    private(set) var requests: [ModelRequest] = []

    init(_ script: [Result<ModelResponse, ModelError>]) { self.script = script }

    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        requests.append(request)
        guard !script.isEmpty else { throw ModelError.unavailable("script exhausted") }
        return try script.removeFirst().get()
    }
}

func calls(_ calls: (String, String)..., text: String = "") -> Result<ModelResponse, ModelError> {
    .success(ModelResponse(message: ModelMessage(role: .assistant, content: text.isEmpty ? [] : [.text(text)],
                                                 toolCalls: calls.enumerated().map { ModelToolCall(id: "c\($0.offset)", name: $0.element.0, arguments: $0.element.1) }),
                           stopReason: .toolCalls, usage: ModelUsage(inputTokens: 100, outputTokens: 10)))
}

func say(_ text: String) -> Result<ModelResponse, ModelError> {
    .success(ModelResponse(message: ModelMessage(role: .assistant, content: [.text(text)]), stopReason: .endTurn))
}

actor FakeTools: ToolRunning {
    private(set) var called: [(String, String)] = []
    func call(_ name: String, argumentsJSON: String) async -> ToolResult {
        called.append((name, argumentsJSON))
        var result = ToolResult(tool: name, isError: false, content: ["ok": true])
        if name == "screenshot" { result.image = ToolImage(data: Data([0xFF]), mediaType: "image/png", width: 10, height: 5) }
        return result
    }
}

struct FakePrompter: UserPrompting {
    let reply: String?
    func ask(_ question: String) async -> String? { reply }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func add(_ event: AgentEvent) {
        let line: String = switch event {
        case .started: "started"
        case .step(let number): "step:\(number)"
        case .thought(let text): "thought:\(text)"
        case .toolStarted(let name, _): "tool:\(name)"
        case .toolFinished: "done"
        case .progress(let note, let step, let percent): "progress:\(note):\(step ?? 0):\(percent ?? -1)"
        case .question(let text): "question:\(text)"
        case .answer(let text): "answer:\(text)"
        case .usage: "usage"
        case .finished(let outcome): "finished:\(outcome.status.rawValue)"
        }
        lock.withLock { events.append(line) }
    }
    var lines: [String] { lock.withLock { events } }
}

@Suite struct ExecutorAgentTests {
    @Test func runsToolsAttachesScreenshotsAndFinishes() async throws {
        let model = ScriptedModel([
            calls(("screenshot", "{}"), ("report_progress", #"{"note":"Looking","step":1,"percent":150}"#), text: "First, look."),
            calls(("click", #"{"x":1,"y":2}"#)),
            calls(("finish_task", ##"{"success":true,"summary":"Done.","report_markdown":"# R"}"##)),
        ])
        let tools = FakeTools()
        let log = EventLog()
        let outcome = await ExecutorAgent(model: model, tools: tools, prompter: FakePrompter(reply: nil))
            .run(ExecutorTask(request: "Do the thing", plan: ["Look", "Click"]), onEvent: log.add)

        #expect(outcome.status == .completed)
        #expect(outcome.summary == "Done." && outcome.report == "# R")
        #expect(outcome.steps == 3 && outcome.usage == ModelUsage(inputTokens: 300, outputTokens: 30))
        #expect(await tools.called.map(\.0) == ["screenshot", "click"])
        #expect(log.lines.contains("thought:First, look."))
        #expect(log.lines.contains("progress:Looking:1:100"))
        #expect(log.lines.last == "finished:completed")

        let requests = await model.requests
        // The task and numbered plan open the conversation; tools include session and control tools.
        #expect(requests[0].messages.first?.text.contains("1. Look\n2. Click") == true)
        #expect(Set(requests[0].tools.map(\.name)).isSuperset(of: ["click", "screenshot", "finish_task", "ask_user", "report_progress"]))
        // Second request: assistant, two tool results, then the screenshot as a user image message.
        let second = requests[1].messages
        #expect(second.map(\.role) == [.user, .assistant, .tool, .tool, .user])
        #expect(second[2].toolCallID == "c0" && second[2].text.contains("image follows"))
        #expect(second[4].content.contains { if case .image = $0 { true } else { false } })
    }

    @Test func asksTheUserAndPassesTheAnswerBack() async {
        let model = ScriptedModel([
            calls(("ask_user", #"{"question":"Send the email?"}"#)),
            calls(("finish_task", #"{"success":false,"summary":"Not approved."}"#)),
        ])
        let log = EventLog()
        let outcome = await ExecutorAgent(model: model, tools: FakeTools(), prompter: FakePrompter(reply: "no"))
            .run(ExecutorTask(request: "Email Bob"), onEvent: log.add)
        #expect(outcome.status == .failed && outcome.summary == "Not approved.")
        #expect(log.lines.contains("question:Send the email?") && log.lines.contains("answer:no"))
        let answer = await model.requests[1].messages.last
        #expect(answer?.role == .tool && answer?.text == #"{"answer":"no"}"#)
    }

    @Test func remindsAModelThatStopsCallingToolsThenGivesUp() async {
        let model = ScriptedModel([say("I think I'm done?"), say("Really done."), say("Done!")])
        let outcome = await ExecutorAgent(model: model, tools: FakeTools(), prompter: FakePrompter(reply: nil),
                                          limits: ExecutorLimits(maxNudges: 2)).run(ExecutorTask(request: "x"))
        #expect(outcome.status == .failed && outcome.summary == "Done!")
        let requests = await model.requests
        #expect(requests.count == 3)
        #expect(requests[1].messages.last?.text.contains("finish_task") == true)
    }

    @Test func invalidControlArgumentsGoBackToTheModel() async {
        let model = ScriptedModel([
            calls(("finish_task", #"{"summary":"no success flag"}"#)),
            calls(("finish_task", #"{"success":true,"summary":"ok"}"#)),
        ])
        let outcome = await ExecutorAgent(model: model, tools: FakeTools(), prompter: FakePrompter(reply: nil)).run(ExecutorTask(request: "x"))
        #expect(outcome.status == .completed)
        #expect(await model.requests[1].messages.last?.text.contains("invalid_arguments") == true)
    }

    @Test func stopsAtTheStepLimitAndOnModelErrors() async {
        let looping = ScriptedModel(Array(repeating: calls(("screenshot", "{}")), count: 5))
        let limited = await ExecutorAgent(model: looping, tools: FakeTools(), prompter: FakePrompter(reply: nil),
                                          limits: ExecutorLimits(maxSteps: 3)).run(ExecutorTask(request: "x"))
        #expect(limited.status == .failed && limited.steps == 3)

        let broken = ScriptedModel([.failure(.authentication("HTTP 401: bad key"))])
        let failed = await ExecutorAgent(model: broken, tools: FakeTools(), prompter: FakePrompter(reply: nil)).run(ExecutorTask(request: "x"))
        #expect(failed.status == .failed && failed.summary.contains("bad key"))
    }

    @Test func cancellationStopsBetweenSteps() async {
        let model = ScriptedModel(Array(repeating: calls(("screenshot", "{}")), count: 50))
        let task = Task {
            await ExecutorAgent(model: model, tools: FakeTools(), prompter: FakePrompter(reply: nil)).run(ExecutorTask(request: "x"))
        }
        task.cancel()
        #expect(await task.value.status == .cancelled)
    }

    @Test func onlyTheNewestScreenshotsStayImages() {
        let image = ModelMessage(role: .user, content: [.text("shot"), .image(data: Data([1]), mediaType: "image/png")])
        let rendered = ExecutorAgent.render([.user("task"), image, .user("x"), image, image], keepingImages: 2)
        func hasImage(_ message: ModelMessage) -> Bool { message.content.contains { if case .image = $0 { true } else { false } } }
        #expect(rendered.map(hasImage) == [false, false, false, true, true])
        #expect(rendered[1].text.contains("Older screenshot removed"))
    }
}
