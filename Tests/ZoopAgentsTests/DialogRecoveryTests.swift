import Foundation
import Testing
import ZoopShared
@testable import ZoopAgents

actor DialogRecoveryTools: ToolRunning {
    private(set) var called: [String] = []
    func call(_ name: String, argumentsJSON: String) async -> ToolResult {
        called.append(name)
        if name == "screenshot" {
            return ToolResult(tool: name, isError: false, content: ["ok": true],
                              image: ToolImage(data: Data([0xff]), mediaType: "image/png", width: 100, height: 60))
        }
        if name == "click" { return ToolResult(tool: name, isError: false, content: ["requires_observation": true, "verified": .null]) }
        if name == "request_dialog_help" {
            return ToolResult(tool: name, isError: false, content: ["verified": true, "requires_observation": true, "human_choice": "Not Now"])
        }
        return ToolResult(tool: name, isError: false, content: ["ok": true])
    }
}

@Suite struct DialogRecoveryTests {
    /// Dialogs belong to the person: request_dialog_help is available right away, with no
    /// Accessibility or mouse attempts first.
    @Test func dialogHelpIsAvailableImmediatelyAndTheChoiceIsObserved() async {
        let tools = DialogRecoveryTools()
        let model = ScriptedModel([
            calls(("request_dialog_help", #"{"bundle_id":"maps"}"#)),
            calls(("finish_task", #"{"success":true,"summary":"Checked the new screen"}"#)),
        ])
        let result = await ExecutorAgent(model: model, tools: tools, prompter: FakePrompter(reply: nil)).run(ExecutorTask(request: "Dismiss sheet"))
        #expect(result.status == .completed && result.summary == "Checked the new screen")
        #expect(await tools.called == ["request_dialog_help", "screenshot"])
    }

    @Test func dialogHelpNeedsTheAppAndStaysAvailableAtTheRetryLimit() async {
        let tools = DialogRecoveryTools(), model = ScriptedModel([
            calls(("request_dialog_help", "{}")),
            calls(("request_dialog_help", #"{"bundle_id":"maps"}"#)),
            calls(("finish_task", #"{"success":false,"summary":"Reported"}"#)),
        ])
        _ = await AgentSession(model: model, tools: tools, prompter: FakePrompter(reply: nil)).run(ExecutorTask(request: "Dismiss"),
            failedAttempts: ["a", "b", "c"])
        #expect(await tools.called.filter { $0 == "request_dialog_help" }.count == 1)
    }
}
