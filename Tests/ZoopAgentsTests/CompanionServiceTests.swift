import Foundation
import Testing
import ZoopShared
@testable import ZoopAgents

@Suite struct CompanionServiceTests {
    @Test func ordinaryChatUsesOnlyTheChatModelAndNoHelper() async throws {
        let chat = ScriptedModel([say("Hello! What would you like to talk about?")])
        let planner = ScriptedModel([])
        let executor = ScriptedModel([])
        let tools = FakeTools()
        let service = LiveCompanionService(configuration: ModelConfiguration(environment: [:], file: [:]),
            tools: tools, chatModel: chat, plannerModel: planner, executorModel: executor)
        let reply = try await service.respond(to: [.init(role: .user, text: "Hi")], pendingPlan: nil)
        #expect(reply.plan == nil && reply.text.contains("Hello"))
        #expect(await tools.called.isEmpty)
        #expect(await planner.requests.isEmpty)
        #expect(await executor.requests.isEmpty)
        #expect(await chat.requests[0].tools.map(\.name) == ["plan_task"])
    }

    @Test func concreteTaskPlansReadOnlyThenExecutesThroughTheSeparateEntryPoint() async throws {
        let chat = ScriptedModel([calls(("plan_task", #"{"request":"Open Calculator and read its display"}"#))])
        let proposal = #"{"title":"Calculator","steps":[{"summary":"Open","kind":"action","confirm":false,"tool":"open_app","bundle_id":"com.apple.calculator"},{"summary":"Read","kind":"decide","goal":"Read the display and finish_task","confirm":false}]}"#
        let planner = ScriptedModel([calls(("submit_plan", proposal))])
        let executor = ScriptedModel([calls(("finish_task", ##"{"success":true,"summary":"The result is 7","report_markdown":"# Actual result\n7"}"##))])
        let tools = FakeTools()
        let service = LiveCompanionService(tools: tools, chatModel: chat, plannerModel: planner, executorModel: executor)
        let reply = try await service.respond(to: [.init(role: .user, text: "Open Calculator and read its display")], pendingPlan: nil)
        let plan = try #require(reply.plan)
        #expect(await tools.called.map(\.0) == ["screenshot"])
        #expect(await executor.requests.isEmpty)
        let outcome = await service.execute(plan, mode: .ask, prompter: FakePrompter(reply: nil)) { _ in }
        #expect(outcome.status == .completed && outcome.summary == "The result is 7")
        #expect(outcome.report == "# Actual result\n7")
        #expect(await tools.called.map(\.0) == ["screenshot", "open_app", "screenshot"])
    }

    @Test func chatCannotDispatchDesktopToolsOrExecuteAPlan() async throws {
        let chat = ScriptedModel([
            calls(("open_app", #"{"bundle_id":"com.apple.calculator"}"#)),
            say("Please use Execute the plan after reviewing it."),
        ])
        let tools = FakeTools()
        let service = LiveCompanionService(tools: tools, chatModel: chat)
        let reply = try await service.respond(to: [.init(role: .user, text: "Execute that")], pendingPlan: samplePlan())
        #expect(reply.plan == nil)
        #expect(await tools.called.isEmpty)
        #expect(await chat.requests[1].messages.last?.text.contains("plan_task") == true)
    }

    @Test func aRefinedRequestReceivesThePendingPlansContext() async throws {
        let chat = ScriptedModel([say("Which part would you like to change?")])
        let service = LiveCompanionService(tools: FakeTools(), chatModel: chat)
        _ = try await service.respond(to: [.init(role: .user, text: "Change the last step")], pendingPlan: samplePlan())
        #expect(await chat.requests[0].system.contains("Calculator task") == true)
    }
}
