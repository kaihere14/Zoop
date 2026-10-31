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
    @Test func helperRequiresBothStrategiesInTheSameApp() {
        var state = DialogRecoveryState()
        let unknown = ToolResult(tool: "click", isError: false, content: ["requires_observation": true, "verified": .null])
        state.record(name: "click", arguments: ["bundle_id": "maps", "element": "Not Now"], result: unknown)
        #expect(!state.canRequestHelp(in: "maps"))
        state.record(name: "click", arguments: ["bundle_id": "notes", "x": 1, "y": 2, "strategy": "mouse"], result: unknown)
        #expect(!state.canRequestHelp(in: "maps") && !state.canRequestHelp(in: "notes"))
        state.record(name: "click", arguments: ["bundle_id": "maps", "x": 1, "y": 2, "strategy": "mouse"], result: unknown)
        #expect(state.canRequestHelp(in: "maps"))
        state.record(name: "click", arguments: ["bundle_id": "maps"], result: ToolResult(tool: "click", isError: false, content: ["verified": true]))
        #expect(!state.canRequestHelp(in: "maps"))
    }

    @Test func batchCheckpointPreservesTheAccessibilityAttemptForRepair() {
        var state = DialogRecoveryState()
        state.record(name: "batch", arguments: ["actions": [["tool": "open_app", "bundle_id": "maps"],
            ["tool": "click", "bundle_id": "maps", "element": "Not Now"]]],
            result: ToolResult(tool: "batch", isError: false, content: ["requires_observation": true,
                "results": [["tool": "open_app", "ok": true], ["tool": "click", "verified": .null]]]))
        state.record(name: "click", arguments: ["bundle_id": "maps", "strategy": "mouse"],
                     result: ToolResult(tool: "click", isError: false, content: ["requires_observation": true]))
        #expect(state.canRequestHelp(in: "maps"))
    }

    @Test func runtimeOrdersAxThenVisualThenHumanAndObservesTheHumanChoice() async {
        let tools = DialogRecoveryTools()
        let model = ScriptedModel([
            calls(("request_dialog_help", #"{"bundle_id":"maps"}"#)), // premature: no dispatch
            calls(("click", #"{"bundle_id":"maps","element":"Not Now"}"#)),
            calls(("open_app", #"{"bundle_id":"maps"}"#), ("screenshot", "{}")),
            calls(("click", #"{"bundle_id":"maps","strategy":"mouse","x":10,"y":20}"#)),
            calls(("request_dialog_help", #"{"bundle_id":"maps"}"#),
                  ("finish_task", #"{"success":true,"summary":"Too early"}"#)),
            calls(("finish_task", #"{"success":true,"summary":"Checked the new screen"}"#)),
        ])
        let result = await ExecutorAgent(model: model, tools: tools, prompter: FakePrompter(reply: nil)).run(ExecutorTask(request: "Dismiss sheet"))
        #expect(result.status == .completed && result.summary == "Checked the new screen")
        #expect(await tools.called == ["click", "screenshot", "open_app", "screenshot", "click", "screenshot", "request_dialog_help", "screenshot"])
        #expect(await model.requests[1].messages.last?.text.contains("First try Accessibility") == true)
    }

    @Test func lastHumanFallbackIsAvailableAtRetryLimitButOnlyOnce() async {
        var state = DialogRecoveryState()
        let unknown = ToolResult(tool: "click", isError: false, content: ["requires_observation": true])
        state.record(name: "click", arguments: ["bundle_id": "maps"], result: unknown)
        state.record(name: "click", arguments: ["bundle_id": "maps", "strategy": "mouse"], result: unknown)
        let tools = DialogRecoveryTools(), model = ScriptedModel([
            calls(("request_dialog_help", #"{"bundle_id":"maps"}"#)),
            calls(("request_dialog_help", #"{"bundle_id":"maps"}"#)), // consumed
            calls(("finish_task", #"{"success":false,"summary":"No second helper click"}"#)),
        ])
        _ = await AgentSession(model: model, tools: tools, prompter: FakePrompter(reply: nil)).run(ExecutorTask(request: "Dismiss"),
            failedAttempts: ["a", "b", "c"], clickRecovery: state)
        #expect(await tools.called.filter { $0 == "request_dialog_help" }.count == 1)
    }
}
