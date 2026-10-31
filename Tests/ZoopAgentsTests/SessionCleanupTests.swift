import Foundation
import Testing
import ZoopShared
@testable import ZoopAgents

actor FakeCleaner: SessionCleaning {
    private(set) var calls = 0
    let report: QuitAppsReport?
    init(_ report: QuitAppsReport?) { self.report = report }
    func quitApps(keeping: [String]) async throws -> QuitAppsReport {
        calls += 1
        guard let report else { throw ModelError.unavailable("helper gone") }
        return report
    }
}

@Suite struct SessionCleanupTests {
    static let safari = AppInfo(bundleID: "com.apple.Safari", name: "Safari", pid: 7, isActive: false)
    static let textEdit = AppInfo(bundleID: "com.apple.TextEdit", name: "TextEdit", pid: 8, isActive: true)
    static func outcome(_ status: AgentOutcome.Status) -> AgentOutcome {
        AgentOutcome(status: status, summary: "Done.", steps: 1, usage: ModelUsage(inputTokens: 0, outputTokens: 0))
    }

    @Test func successQuitsAppsAndSaysWhatStayedOpen() async {
        let cleaner = FakeCleaner(QuitAppsReport(quit: [Self.safari], stillOpen: [Self.textEdit]))
        let result = await SessionCleanup.afterTask(Self.outcome(.completed), using: cleaner)
        #expect(result.status == .completed)
        #expect(result.summary.hasPrefix("Done.\n\nClosed Safari."))
        #expect(result.summary.contains("Still open: TextEdit") && result.summary.contains("nothing was discarded"))
        #expect(await cleaner.calls == 1)
    }

    @Test func failedOrCancelledTasksKeepTheirApps() async {
        let cleaner = FakeCleaner(QuitAppsReport(quit: [Self.safari], stillOpen: []))
        for status in [AgentOutcome.Status.failed, .cancelled] {
            #expect(await SessionCleanup.afterTask(Self.outcome(status), using: cleaner) == Self.outcome(status))
        }
        #expect(await cleaner.calls == 0)
    }

    @Test func aCleanupErrorKeepsTheTaskSuccessful() async {
        let result = await SessionCleanup.afterTask(Self.outcome(.completed), using: FakeCleaner(nil))
        #expect(result.status == .completed && result.summary.contains("Could not close"))
        let nothingOpen = await SessionCleanup.afterTask(Self.outcome(.completed), using: FakeCleaner(QuitAppsReport(quit: [], stillOpen: [])))
        #expect(nothingOpen.summary == "Done.")
    }

    @Test func theServiceCleansUpAfterASuccessfulPlan() async throws {
        let executor = ScriptedModel([calls(("finish_task", #"{"success":true,"summary":"Opened it."}"#))])
        let cleaner = FakeCleaner(QuitAppsReport(quit: [Self.safari], stillOpen: []))
        let service = LiveCompanionService(tools: FakeTools(), cleaner: cleaner, executorModel: executor)
        let plan = TaskPlan(request: "Open Safari", title: "Open", steps: [
            PlanStep(summary: "Check", kind: .decide, goal: "Verify and finish_task"),
        ])
        let outcome = await service.execute(plan, mode: .ask, prompter: FakePrompter(reply: nil)) { _ in }
        #expect(outcome.status == .completed && outcome.summary == "Opened it.\n\nClosed Safari.")
        #expect(await cleaner.calls == 1)
    }
}

@Suite struct WaitToolTests {
    @Test func waitPausesAndIsBatchableButNotAPlanningTool() async throws {
        let definition = SessionTools.definition(for: .wait)
        #expect(definition.isReadOnly)
        #expect(SessionTools.guide.contains("cmd+r") && SessionTools.guide.contains("another source"))
        #expect(ExecutorLimits().maxFailedAttempts == 5)
    }
}
