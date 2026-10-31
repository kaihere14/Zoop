import Foundation
import Testing
import ZoopShared
@testable import ZoopAgents

/// Tool fake whose typing cannot be confirmed (`verified: null`), like PID-posted keys.
actor UnconfirmedTyping: ToolRunning {
    private(set) var called: [String] = []
    func call(_ name: String, argumentsJSON: String) async -> ToolResult {
        called.append(name)
        if name == "screenshot" {
            return ToolResult(tool: name, isError: false, content: ["ok": true],
                              image: ToolImage(data: Data([0xff]), mediaType: "image/png", width: 10, height: 5))
        }
        if name == "type_text" { return ToolResult(tool: name, isError: false, content: ["ok": true, "method": "pidKeys", "verified": .null]) }
        return ToolResult(tool: name, isError: false, content: ["ok": true, "verified": true])
    }
}

actor CountingPrompter: UserPrompting {
    private(set) var questions: [String] = []
    func ask(_ question: String) async -> String? { questions.append(question); return "yes" }
}

@Suite struct StepCompletionTests {
    static func plan(_ steps: [PlanStep]) -> TaskPlan { TaskPlan(request: "Quote", title: "Quote", steps: steps + [finishPlanStep()]) }

    /// The failed quote run: Calculator never produced a result, but the runner moved on to TextEdit.
    @Test func anUnfinishedStepStopsTheTaskBeforeLaterSteps() async {
        let tools = UnconfirmedTyping()
        let model = ScriptedModel([calls(("step_done", #"{"summary":"Calculator display still reads 0","complete":false}"#))])
        let result = await PlanRunner(model: model, tools: tools, prompter: FakePrompter(reply: nil)).run(Self.plan([
            PlanStep(summary: "Compute the total", kind: .decide, goal: "The Calculator display shows 449700"),
            PlanStep(summary: "Open TextEdit", kind: .action, tool: .openApp, arguments: ["bundle_id": "com.apple.TextEdit"]),
        ]), approved: true)
        #expect(result.status == .failed)
        #expect(result.summary.contains("could not be completed"))
        #expect(await tools.called == ["screenshot"])
    }

    @Test func stepDoneMustSayWhetherTheStepFinished() async {
        let model = ScriptedModel([
            calls(("step_done", #"{"summary":"Done"}"#)),
            calls(("step_done", #"{"summary":"Done","complete":true}"#)),
            calls(("finish_task", #"{"success":true,"summary":"Verified"}"#)),
        ])
        let result = await PlanRunner(model: model, tools: UnconfirmedTyping(), prompter: FakePrompter(reply: nil)).run(Self.plan([
            PlanStep(summary: "Inspect", kind: .decide, goal: "Inspect"),
        ]), approved: true)
        #expect(result.status == .completed)
        #expect(await model.requests[1].messages.last?.text.contains("complete (true or false)") == true)
    }

    @Test func unconfirmedTypingIsCheckedBeforeTheNextScriptedStep() async {
        let tools = UnconfirmedTyping()
        let model = ScriptedModel([
            calls(("step_done", #"{"summary":"The document reads back the quote","complete":true}"#)),
            calls(("finish_task", #"{"success":true,"summary":"Saved"}"#)),
        ])
        let result = await PlanRunner(model: model, tools: tools, prompter: CountingPrompter()).run(Self.plan([
            PlanStep(summary: "Type the quote", kind: .action, tool: .typeText, arguments: ["text": "Quote"]),
            PlanStep(summary: "Save", kind: .action, tool: .saveDocument, arguments: ["bundle_id": "com.apple.TextEdit", "path": "~/Documents/Q.rtf"]),
        ]), approved: true)
        #expect(result.status == .completed)
        // The check (screenshot + model) happens between typing and saving.
        #expect(await tools.called == ["type_text", "screenshot", "save_document", "screenshot"])
        #expect(await model.requests[0].messages.first?.text.contains("effect is unconfirmed") == true)
    }

    @Test func aSaveStepAsksOnceThroughTheSaveCardNotTheStepConfirmation() async {
        let prompter = CountingPrompter()
        var save = PlanStep(summary: "Save", kind: .action, tool: .saveDocument, arguments: ["bundle_id": "com.apple.TextEdit", "path": "~/Documents/Q.rtf"])
        save.requiresConfirmation = true
        let model = ScriptedModel([calls(("finish_task", #"{"success":true,"summary":"Saved"}"#))])
        _ = await PlanRunner(model: model, tools: UnconfirmedTyping(), prompter: prompter).run(Self.plan([save]), approved: true)
        #expect(await prompter.questions.isEmpty)
    }

    @Test func openingTextEditNeverCreatesASecondDocument() async {
        let tools = PlannedTools()
        let model = ScriptedModel([calls(("finish_task", #"{"success":true,"summary":"One document"}"#))])
        _ = await PlanRunner(model: model, tools: tools, prompter: FakePrompter(reply: nil)).run(Self.plan([
            PlanStep(summary: "Open TextEdit", kind: .action, tool: .openApp, arguments: ["bundle_id": "com.apple.TextEdit"]),
            PlanStep(summary: "Create a new document", kind: .action, tool: .pressKey, arguments: ["keys": "cmd+n"]),
        ]), approved: true)
        #expect(await tools.called.map(\.0) == ["open_app", "screenshot"])
    }
}
