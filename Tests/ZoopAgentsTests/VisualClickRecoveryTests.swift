import Foundation
import Testing
import ZoopShared
@testable import ZoopAgents

actor VisualRecoveryTools: ToolRunning {
    private(set) var called: [String] = []
    let clickError: Bool
    let captureFails: Bool
    init(clickError: Bool = false, captureFails: Bool = false) {
        self.clickError = clickError; self.captureFails = captureFails
    }
    func call(_ name: String, argumentsJSON: String) async -> ToolResult {
        called.append(name)
        if name == "screenshot" {
            return ToolResult(tool: name, isError: captureFails, content: ["ok": .bool(!captureFails)],
                              image: captureFails ? nil : ToolImage(data: Data([0xff]), mediaType: "image/png", width: 100, height: 60))
        }
        if name == "click" {
            let mouse = (try? JSONValue.parse(argumentsJSON))?["strategy"] == "mouse"
            return ToolResult(tool: name, isError: clickError && !mouse,
                              content: ["ok": .bool(!clickError || mouse), "verified": .null,
                                        "requires_observation": true, "method": mouse ? "pidMouse" : "axPress"])
        }
        return ToolResult(tool: name, isError: false, content: ["ok": true])
    }
}

@Suite struct VisualClickRecoveryTests {
    @Test func axFailureGetsAScreenshotBeforeFocusAndVisualRetry() async {
        let tools = VisualRecoveryTools(clickError: true)
        let model = ScriptedModel([
            calls(("click", #"{"bundle_id":"test.app","element":"Submit"}"#),
                  ("type_text", #"{"text":"must not type before checking"}"#)),
            calls(("open_app", #"{"bundle_id":"test.app"}"#), ("screenshot", "{}")),
            calls(("click", #"{"x":40,"y":30,"strategy":"mouse","bundle_id":"test.app"}"#)),
            calls(("finish_task", #"{"success":true,"summary":"Result visible"}"#)),
        ])
        let outcome = await ExecutorAgent(model: model, tools: tools, prompter: FakePrompter(reply: nil))
            .run(ExecutorTask(request: "Submit"))
        #expect(outcome.status == .completed)
        #expect(await tools.called == ["click", "screenshot", "open_app", "screenshot", "click", "screenshot"])
        let requests = await model.requests
        #expect(requests[1].messages.contains { $0.role == .tool && $0.text.contains("Skipped") })
        #expect(requests[1].messages.last?.content.contains { if case .image = $0 { true } else { false } } == true)
    }

    @Test func screenshotAndMouseInSameModelResponseCannotUseAnUnseenImage() async {
        let tools = VisualRecoveryTools()
        let model = ScriptedModel([
            calls(("open_app", #"{"bundle_id":"test.app"}"#), ("screenshot", "{}"),
                  ("click", #"{"x":40,"y":30,"strategy":"mouse","bundle_id":"test.app"}"#)),
            calls(("finish_task", #"{"success":false,"summary":"Check image first"}"#)),
        ])
        _ = await ExecutorAgent(model: model, tools: tools, prompter: FakePrompter(reply: nil)).run(ExecutorTask(request: "Click"))
        #expect(await tools.called == ["open_app", "screenshot"])
        #expect(await model.requests[1].messages.contains { $0.role == .tool && $0.text.contains("No click was sent") })
    }

    @Test func mouseRetryNeedsAScreenshotAfterFocusChangesToThatApp() async {
        let tools = VisualRecoveryTools()
        let model = ScriptedModel([
            calls(("screenshot", "{}")),
            calls(("open_app", #"{"bundle_id":"test.app"}"#)),
            calls(("click", #"{"x":40,"y":30,"strategy":"mouse","bundle_id":"test.app"}"#)),
            calls(("finish_task", #"{"success":false,"summary":"Need screenshot after focus"}"#)),
        ])
        _ = await ExecutorAgent(model: model, tools: tools, prompter: FakePrompter(reply: nil)).run(ExecutorTask(request: "Click"))
        #expect(await tools.called == ["screenshot", "open_app"])
    }

    @Test func inabilityToObserveStopsWithoutSendingAnotherAction() async {
        let tools = VisualRecoveryTools(captureFails: true)
        let model = ScriptedModel([
            calls(("click", #"{"x":40,"y":30}"#), ("press_key", #"{"keys":"return"}"#)),
        ])
        let outcome = await ExecutorAgent(model: model, tools: tools, prompter: FakePrompter(reply: nil)).run(ExecutorTask(request: "Click"))
        #expect(outcome.status == .failed)
        #expect(outcome.summary.contains("No retry was sent"))
        #expect(await tools.called == ["click", "screenshot"])
    }

    @Test func planRunnerChecksUnconfirmedClickBeforeTheNextDirectAction() async {
        let tools = VisualRecoveryTools()
        let model = ScriptedModel([
            calls(("step_done", #"{"summary":"Click already worked; no retry"}"#)),
            calls(("finish_task", #"{"success":true,"summary":"Done"}"#)),
        ])
        let plan = TaskPlan(request: "Enter text", title: "Text", steps: [
            PlanStep(summary: "Focus field", kind: .action, tool: .click, arguments: ["bundle_id": "test.app", "element": "Field"]),
            PlanStep(summary: "Type", kind: .action, tool: .typeText, arguments: ["text": "hello"]),
            finishPlanStep(),
        ])
        let outcome = await PlanRunner(model: model, tools: tools, prompter: FakePrompter(reply: nil)).run(plan, approved: true)
        #expect(outcome.status == .completed)
        #expect(await tools.called == ["click", "screenshot", "type_text", "screenshot"])
    }
}
