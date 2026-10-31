import Foundation
import Testing
@testable import ZoopShared

private func sample(phase: TaskPhase = .pending, progress: Int = 0) -> CompanionTask {
    .init(request: "Compare keyboards", title: "Keyboards", domain: "rtings.com", fileName: "keyboards.md", steps: ["Research", "Compare", "Save"], kind: .keyboards, phase: phase, progress: progress)
}

@Test func workCannotStartWithoutApproval() {
    var task = sample()
    task.advance(by: 100)
    #expect(task.phase == .pending)
    #expect(task.progress == 0)
    let arrivedBeforeApproval = task.apply(.arrive)
    #expect(!arrivedBeforeApproval)
    let resumedBeforeApproval = task.apply(.resume)
    #expect(!resumedBeforeApproval)
    let approved = task.apply(.approve)
    #expect(approved)
    let approvedAgain = task.apply(.approve)
    #expect(!approvedAgain)
    task.advance(by: 100)
    #expect(task.progress == 0)
    let arrivedAfterApproval = task.apply(.arrive)
    #expect(arrivedAfterApproval)
    task.advance(by: 4)
    #expect(task.progress == 4)
}

@Test func pausedAndCancelledTasksCannotAdvance() {
    var task = sample(phase: .running, progress: 24)
    let paused = task.apply(.pause)
    #expect(paused)
    task.advance(by: 50)
    #expect(task.progress == 24)
    let resumed = task.apply(.resume)
    #expect(resumed)
    task.advance(by: 4)
    #expect(task.progress == 28)
    let stopped = task.apply(.stop)
    #expect(stopped)
    task.advance(by: 100)
    #expect(task.phase == .cancelled)
    #expect(task.progress == 28)
    let resumedAfterStop = task.apply(.resume)
    #expect(!resumedAfterStop)
}

@Test func completionIsBoundedAndTerminal() {
    var task = sample(phase: .running, progress: 98)
    task.advance(by: 10)
    #expect(task.progress == 100)
    #expect(task.phase == .complete)
    let resumedAfterCompletion = task.apply(.resume)
    #expect(!resumedAfterCompletion)
    let stoppedAfterCompletion = task.apply(.stop)
    #expect(!stoppedAfterCompletion)
    task.advance(by: -50)
    #expect(task.progress == 100)
}

@Test func restoringNeverRestartsWork() throws {
    let snapshot = CompanionSnapshot(tasks: [sample(phase: .running, progress: 44), sample(phase: .dispatching), sample(), sample(phase: .complete, progress: 100)])
    let data = try JSONEncoder().encode(snapshot)
    var restored = try JSONDecoder().decode(CompanionSnapshot.self, from: data)
    restored.prepareForRestore()
    #expect(restored.tasks.map(\.phase) == [.failed, .failed, .pending, .complete])
    #expect(restored.tasks[0].progress == 44)
}

@Test func snapshotsWithoutLivePlanFieldsStillDecode() throws {
    let task = sample()
    var value = try #require(JSONValue.parse(String(decoding: JSONEncoder().encode(task), as: UTF8.self)).objectValue)
    for key in ["executablePlan", "statusNote", "resultSummary", "reportMarkdown"] { value.removeValue(forKey: key) }
    let decoded = try JSONDecoder().decode(CompanionTask.self, from: Data(JSONValue.object(value).jsonText.utf8))
    #expect(decoded.id == task.id)
    #expect(decoded.executablePlan == nil && decoded.resultSummary == nil)
}

@Test func realExecutionProgressCannotMarkCompletionWithoutTheOutcome() {
    var task = sample(phase: .running)
    task.updateExecution(note: "Checking", percent: 100)
    #expect(task.progress == 99 && task.phase == .running)
    task.finishExecution(success: false, summary: "Blocked")
    #expect(task.phase == .failed && task.progress == 99)
}
