import Foundation
import Testing
import ZoopShared
@testable import ZoopAgents

func finishPlanStep() -> PlanStep {
    PlanStep(summary: "Check the result", kind: .decide, goal: "Read the display and finish_task with the answer.")
}

func samplePlan() -> TaskPlan {
    TaskPlan(request: "Calculate", title: "Calculator task", steps: [
        PlanStep(summary: "Open Calculator", kind: .action, tool: .openApp, arguments: ["bundle_id": "com.apple.calculator"]),
        PlanStep(summary: "Press 7", kind: .action, tool: .click, arguments: ["bundle_id": "com.apple.calculator", "element": "7"]),
        finishPlanStep(),
    ])
}

let submittedPlan = #"{"title":"Calculate","steps":[{"summary":"Press 7","kind":"action","confirm":false,"tool":"click","bundle_id":"com.apple.calculator","element":"7"},{"summary":"Check","kind":"decide","goal":"Read the result and finish_task","confirm":false}]}"#

@Suite struct PlannerAgentTests {
    @Test func groundsNamedTargetsReadOnlyAndReturnsAnUnexecutedPlan() async throws {
        let model = ScriptedModel([
            calls(("open_app", #"{"bundle_id":"com.apple.calculator"}"#)), // must be denied
            calls(("list_elements", #"{"bundle_id":"com.apple.calculator"}"#)),
            calls(("submit_plan", submittedPlan)),
        ])
        let tools = FakeTools()
        let result = try await PlannerAgent(model: model, tools: tools).plan("Calculate")
        #expect(result.plan.steps.first?.tool == .click)
        #expect(result.modelCalls == 3)
        #expect(result.usage.inputTokens == 300)
        #expect(await tools.called.map(\.0) == ["screenshot", "list_elements"])
        let requests = await model.requests
        #expect(requests[0].messages.contains { $0.content.contains { if case .image = $0 { true } else { false } } })
        #expect(Set(requests[0].tools.map(\.name)) == ["screenshot", "session_status", "list_elements", "inspect_point", "submit_plan"])
        #expect(requests[1].messages.last?.text.contains("read-only") == true)
    }

    @Test func asksForRealNamesBeforeAcceptingNamedClicks() async throws {
        let model = ScriptedModel([
            calls(("submit_plan", submittedPlan)),
            calls(("list_elements", #"{"bundle_id":"com.apple.calculator"}"#)),
            calls(("submit_plan", submittedPlan)),
        ])
        let result = try await PlannerAgent(model: model, tools: FakeTools()).plan("Calculate")
        #expect(result.modelCalls == 3)
        #expect(await model.requests[1].messages.last?.text.contains("list_elements") == true)
    }

    @Test func sameResponseObservationCannotGroundASubmittedPlan() async throws {
        let model = ScriptedModel([
            calls(("list_elements", #"{"bundle_id":"com.apple.calculator"}"#), ("submit_plan", submittedPlan)),
            calls(("submit_plan", submittedPlan)),
        ])
        let result = try await PlannerAgent(model: model, tools: FakeTools()).plan("Calculate")
        #expect(result.modelCalls == 2)
        #expect(await model.requests[1].messages.last?.text.contains("list_elements") == true)
    }

    @Test func validatesWholePlanIncludingNestedBatchBeforeApproval() throws {
        var plan = samplePlan()
        try plan.validate()
        let decoded = try JSONDecoder().decode(TaskPlan.self, from: JSONEncoder().encode(plan))
        #expect(decoded == plan)
        plan.steps[0] = PlanStep(summary: "Bad click", kind: .action, tool: .batch, arguments: ["actions": [
            ["tool": "click", "bundle_id": "com.apple.calculator", "element": "7"],
            ["tool": "click", "x": 5, "y": 10],
        ]])
        #expect(throws: (any Error).self) { try plan.validate() }
        plan = samplePlan()
        plan.steps[0] = PlanStep(summary: "Bad batch", kind: .action, tool: .batch, arguments: ["actions": [
            ["tool": "open_app", "bundle_id": "com.apple.calculator"], ["tool": "press_key", "combo": "return", "typo": true],
        ]])
        #expect(throws: (any Error).self) { try plan.validate() }
        plan = samplePlan(); plan.steps.removeLast()
        #expect(throws: PlanError.self) { try plan.validate() }
    }

    @Test func refusesToPlanWithoutAScreenshot() async {
        let tools = PlannedTools(failureTool: "screenshot", failure: ["error": "permission_denied"])
        let model = ScriptedModel([])
        await #expect(throws: PlanError.self) { try await PlannerAgent(model: model, tools: tools).plan("Calculate") }
        #expect(await model.requests.isEmpty)
    }
}

/// Fail once, then succeed, to prove repair does not replay earlier direct actions.
actor PlannedTools: ToolRunning {
    private(set) var called: [(String, String)] = []
    var failureTool: String?
    let failure: JSONValue

    init(failureTool: String? = nil, failure: JSONValue = ["error": "not_found"]) {
        self.failureTool = failureTool; self.failure = failure
    }
    func call(_ name: String, argumentsJSON: String) async -> ToolResult {
        called.append((name, argumentsJSON))
        if name == failureTool {
            failureTool = nil
            return ToolResult(tool: name, isError: true, content: failure)
        }
        return ToolResult(tool: name, isError: false, content: ["ok": true],
                          image: name == "screenshot" ? ToolImage(data: Data([0xff]), mediaType: "image/png", width: 10, height: 5) : nil)
    }
}

@Suite struct PlanRunnerTests {
    @Test func knownActionsNeedNoModelCallsUntilFinalVerification() async {
        let model = ScriptedModel([calls(("finish_task", #"{"success":true,"summary":"7 shown"}"#))])
        let tools = PlannedTools()
        let log = EventLog()
        let result = await PlanRunner(model: model, tools: tools, prompter: FakePrompter(reply: nil))
            .run(samplePlan(), approved: true, onEvent: log.add)
        #expect(result.status == .completed && result.steps == 1)
        #expect(result.usage == ModelUsage(inputTokens: 100, outputTokens: 10))
        #expect(await tools.called.map(\.0) == ["open_app", "click", "screenshot"])
        #expect(await model.requests.count == 1)
        #expect(log.lines.filter { $0.hasPrefix("finished:") } == ["finished:completed"])
    }

    @Test func noApprovalOrDeclinedRiskyStepStopsBeforeActing() async {
        let tools = PlannedTools()
        let model = ScriptedModel([])
        let runner = PlanRunner(model: model, tools: tools, prompter: FakePrompter(reply: "no"))
        #expect(await runner.run(samplePlan()).status == .cancelled)
        var risky = samplePlan(); risky.steps[0].requiresConfirmation = true
        #expect(await runner.run(risky, approved: true).status == .cancelled)
        #expect(await tools.called.isEmpty)
        #expect(await model.requests.isEmpty)
        #expect(!PlanRunner.isApproval("yes but don't do it"))
        #expect(PlanRunner.isApproval(" YES "))
    }

    @Test func repairsOnlyTheFailedStepThenResumesWithSharedModelBudget() async throws {
        let model = ScriptedModel([
            calls(("click", #"{"bundle_id":"com.apple.calculator","element":"7"}"#)),
            calls(("step_done", #"{"summary":"Pressed 7 after finding it again"}"#)),
            calls(("finish_task", #"{"success":true,"summary":"Verified"}"#)),
        ])
        let tools = PlannedTools(failureTool: "click")
        let result = await PlanRunner(model: model, tools: tools, prompter: FakePrompter(reply: nil))
            .run(samplePlan(), approved: true)
        #expect(result.status == .completed && result.steps == 3)
        #expect(await tools.called.map(\.0) == ["open_app", "click", "screenshot", "click", "screenshot"])
        let requests = await model.requests
        #expect(requests[0].messages.first?.text.contains("not_found") == true)
        #expect(requests[0].messages.last?.content.contains { if case .image = $0 { true } else { false } } == true)
        #expect(requests[2].messages.first?.text.contains("Pressed 7 after finding it again") == true)
    }

    @Test func partialBatchFailureIsPassedToRepairWithoutAutomaticReplay() async {
        var plan = samplePlan()
        plan.steps[1] = PlanStep(summary: "Enter expression", kind: .action, tool: .batch, arguments: ["actions": [
            ["tool": "click", "bundle_id": "com.apple.calculator", "element": "7"],
            ["tool": "click", "bundle_id": "com.apple.calculator", "element": "Equals"],
        ]])
        let tools = PlannedTools(failureTool: "batch", failure: ["error": "interrupted", "completed": 1])
        let model = ScriptedModel([
            calls(("step_done", #"{"summary":"Observed expression already complete"}"#)),
            calls(("finish_task", #"{"success":true,"summary":"Verified"}"#)),
        ])
        let result = await PlanRunner(model: model, tools: tools, prompter: FakePrompter(reply: nil)).run(plan, approved: true)
        #expect(result.status == .completed)
        #expect(await tools.called.map(\.0) == ["open_app", "batch", "screenshot", "screenshot"])
        #expect(await model.requests[0].messages.first?.text.contains("\"completed\":1") == true)
    }

    @Test func setupFailuresAndInvalidPlansDoNotStartRepair() async {
        let model = ScriptedModel([])
        let tools = PlannedTools(failureTool: "open_app", failure: ["error": "helper_unavailable"])
        let runner = PlanRunner(model: model, tools: tools, prompter: FakePrompter(reply: nil))
        #expect(await runner.run(samplePlan(), approved: true).status == .failed)
        #expect(await tools.called.map(\.0) == ["open_app"])
        var invalid = samplePlan(); invalid.steps[1].arguments = ["x": 1, "y": 2]
        #expect(await runner.run(invalid, approved: true).status == .failed)
        #expect(await tools.called.count == 1)
        #expect(await model.requests.isEmpty)
    }

    @Test func modelCallBudgetIsSharedAcrossDecisionSessions() async {
        var plan = samplePlan(); plan.steps.insert(PlanStep(summary: "Inspect", kind: .decide, goal: "Inspect controls"), at: 0)
        let model = ScriptedModel([calls(("step_done", #"{"summary":"Inspected"}"#))])
        let tools = PlannedTools()
        let result = await PlanRunner(model: model, tools: tools, prompter: FakePrompter(reply: nil), limits: ExecutorLimits(maxSteps: 1))
            .run(plan, approved: true)
        #expect(result.status == .failed && result.steps == 1)
        #expect(await model.requests.count == 1)
    }

    @Test func cancellationBeforeExecutionRunsNothing() async {
        let tools = PlannedTools()
        let task = Task {
            await PlanRunner(model: ScriptedModel([]), tools: tools, prompter: FakePrompter(reply: nil)).run(samplePlan(), approved: true)
        }
        task.cancel()
        #expect(await task.value.status == .cancelled)
        #expect(await tools.called.isEmpty)
    }
}

@Suite struct PlannerConfigurationTests {
    @Test func plannerDefaultsToExecutorButCanBeConfiguredIndependently() throws {
        let base: JSONValue = ["agents": ["executor": ["provider": "ollama", "model": "light"]]]
        let fallback = try ModelConfiguration(environment: [:], file: base).endpoint(for: .planner)
        #expect(fallback.model == "light" && fallback.provider == "ollama")
        let overriddenFallback = try ModelConfiguration(environment: [:], file: base).endpoint(for: .planner, overrides: .init(model: "strong"))
        #expect(overriddenFallback.model == "strong" && overriddenFallback.provider == "ollama")
        let separate: JSONValue = ["agents": [
            "executor": ["provider": "ollama", "model": "light"],
            "planner": ["provider": "lmstudio", "model": "strong"],
        ]]
        let configuration = ModelConfiguration(environment: [:], file: separate)
        #expect(configuration.hasPlannerConfiguration)
        #expect(try configuration.endpoint(for: .planner).model == "strong")
        #expect(try configuration.endpoint(for: .executor).model == "light")
        let override = try configuration.endpoint(for: .planner, overrides: .init(model: "stronger"))
        #expect(override.model == "stronger" && override.provider == "lmstudio")
    }

    @Test func plannerEnvironmentAndFlagsOverrideItsFileSettings() throws {
        let file: JSONValue = ["agents": ["planner": ["provider": "ollama", "model": "file"]]]
        let configuration = ModelConfiguration(environment: ["ZOOP_PLANNER_PROVIDER": "lmstudio", "ZOOP_PLANNER_MODEL": "env"], file: file)
        #expect(try configuration.endpoint(for: .planner).model == "env")
        #expect(try configuration.endpoint(for: .planner, overrides: .init(model: "flag")).model == "flag")
    }
}

@Suite struct PlanSessionBoundaryTests {
    @Test func intermediateStepCannotFinishTheWholeTaskSuccessfully() async {
        let model = ScriptedModel([
            calls(("finish_task", #"{"success":true,"summary":"Too early"}"#)),
            calls(("step_done", #"{"summary":"Step repaired"}"#)),
            calls(("finish_task", #"{"success":true,"summary":"Finally verified"}"#)),
        ])
        let tools = PlannedTools(failureTool: "click")
        let result = await PlanRunner(model: model, tools: tools, prompter: FakePrompter(reply: nil)).run(samplePlan(), approved: true)
        #expect(result.summary == "Finally verified" && result.steps == 3)
        #expect(await model.requests[1].messages.last?.text.contains("step_done") == true)
    }

    @Test func finalVerificationCannotReturnOnlyStepDone() async {
        let model = ScriptedModel([
            calls(("step_done", #"{"summary":"No final answer"}"#)),
            calls(("finish_task", #"{"success":true,"summary":"Verified"}"#)),
        ])
        let result = await PlanRunner(model: model, tools: PlannedTools(), prompter: FakePrompter(reply: nil)).run(samplePlan(), approved: true)
        #expect(result.status == .completed && result.steps == 2)
        #expect(await model.requests[0].tools.allSatisfy { $0.name != "step_done" })
    }
}

actor FailingClicks: ToolRunning {
    private(set) var clicks = 0
    func call(_ name: String, argumentsJSON: String) async -> ToolResult {
        guard name == "click" else { return ToolResult(tool: name, isError: false, content: ["ok": true]) }
        clicks += 1
        return ToolResult(tool: name, isError: true, content: ["ok": false, "error": "not_found", "message": "no element named Send"])
    }
}

@Suite struct ApprovalAndRetryTests {
    @Test func autoModeSkipsPlannedConfirmationsAndSaysSoToTheModel() async {
        var risky = samplePlan(); risky.steps[1].requiresConfirmation = true
        let model = ScriptedModel([calls(("finish_task", #"{"success":true,"summary":"Done"}"#))])
        let outcome = await PlanRunner(model: model, tools: PlannedTools(), prompter: FakePrompter(reply: "no"))
            .run(risky, approved: true, mode: .auto)
        #expect(outcome.status == .completed)
        #expect(await model.requests.first?.system.contains("AUTO MODE") == true)
        // Ask-first mode still stops at the same step when the person declines.
        let asked = await PlanRunner(model: ScriptedModel([]), tools: PlannedTools(), prompter: FakePrompter(reply: "no"))
            .run(risky, approved: true, mode: .ask)
        #expect(asked.status == .cancelled)
    }

    @Test func threeFailedAttemptsStopTheExecutorWithAReport() async {
        let click = ("click", #"{"bundle_id":"com.google.Chrome","element":"Send"}"#)
        let model = ScriptedModel([calls(click), calls(click), calls(click), calls(click), calls(click)])
        let tools = FailingClicks()
        let outcome = await ExecutorAgent(model: model, tools: tools, prompter: FakePrompter(reply: nil)).run(ExecutorTask(request: "x"))
        #expect(await tools.clicks == 3)
        #expect(outcome.status == .failed && outcome.summary.contains("Stopped after 3 failed attempts"))
        #expect(outcome.summary.contains("Suggested next step"))
        let third = await model.requests[3].messages.last?.text ?? ""
        #expect(third.contains("last attempt"))
    }

    @Test func aFailedFinishIncludesTheSuggestedNextStep() async {
        let model = ScriptedModel([calls(("finish_task", #"{"success":false,"summary":"Gmail is signed out","next_step":"Sign in to Gmail in the agent session"}"#))])
        let outcome = await ExecutorAgent(model: model, tools: FakeTools(), prompter: FakePrompter(reply: nil)).run(ExecutorTask(request: "x"))
        #expect(outcome.summary == "Gmail is signed out\n\nSuggested next step: Sign in to Gmail in the agent session")
    }
}
