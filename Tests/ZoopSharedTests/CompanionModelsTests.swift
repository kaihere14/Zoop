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
    #expect(!task.apply(.arrive))
    #expect(!task.apply(.resume))
    #expect(task.apply(.approve))
    #expect(!task.apply(.approve))
    task.advance(by: 100)
    #expect(task.progress == 0)
    #expect(task.apply(.arrive))
    task.advance(by: 4)
    #expect(task.progress == 4)
}

@Test func pausedAndCancelledTasksCannotAdvance() {
    var task = sample(phase: .running, progress: 24)
    #expect(task.apply(.pause))
    task.advance(by: 50)
    #expect(task.progress == 24)
    #expect(task.apply(.resume))
    task.advance(by: 4)
    #expect(task.progress == 28)
    #expect(task.apply(.stop))
    task.advance(by: 100)
    #expect(task.phase == .cancelled)
    #expect(task.progress == 28)
    #expect(!task.apply(.resume))
}

@Test func completionIsBoundedAndTerminal() {
    var task = sample(phase: .running, progress: 98)
    task.advance(by: 10)
    #expect(task.progress == 100)
    #expect(task.phase == .complete)
    #expect(!task.apply(.resume))
    #expect(!task.apply(.stop))
    task.advance(by: -50)
    #expect(task.progress == 100)
}

@Test func restoringNeverRestartsWork() throws {
    let snapshot = CompanionSnapshot(tasks: [sample(phase: .running, progress: 44), sample(phase: .dispatching), sample(), sample(phase: .complete, progress: 100)])
    let data = try JSONEncoder().encode(snapshot)
    var restored = try JSONDecoder().decode(CompanionSnapshot.self, from: data)
    restored.prepareForRestore()
    #expect(restored.tasks.map(\.phase) == [.paused, .paused, .pending, .complete])
    #expect(restored.tasks[0].progress == 44)
}
