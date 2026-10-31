import Foundation
import Testing
import ZoopAgents
import ZoopShared
@testable import ZoopApp

func basePlan() -> TaskPlan {
    TaskPlan(request: "Task", title: "Task", steps: [PlanStep(summary: "Check", kind: .decide, goal: "Check and finish")])
}

func pendingTask(_ id: UUID = UUID()) -> CompanionTask {
    CompanionTask(id: id, request: "Task", title: "Task", domain: "Agent workspace", fileName: "\(id).md",
                  steps: ["Check"], kind: .tools, executablePlan: basePlan())
}

actor StoreService: CompanionService {
    private(set) var executions = 0
    var continuation: CheckedContinuation<AgentOutcome, Never>?
    let reply: CompanionReply
    init(reply: CompanionReply = CompanionReply(text: "Plan", plan: basePlan())) { self.reply = reply }
    func respond(to messages: [CompanionMessage], pendingPlan: TaskPlan?) async throws -> CompanionReply { reply }
    private(set) var modes: [ApprovalMode] = []
    func execute(_ plan: TaskPlan, mode: ApprovalMode, prompter: any UserPrompting, onEvent: @escaping @Sendable (AgentEvent) -> Void) async -> AgentOutcome {
        executions += 1; modes.append(mode)
        onEvent(.progress(note: "Checking the actual result", step: 1, percent: 100))
        onEvent(.toolFinished(name: "screenshot", result: ToolResult(tool: "screenshot", isError: false, content: ["ok": true],
            image: ToolImage(data: Data([1, 2, 3]), mediaType: "image/png", width: 1, height: 1))))
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(success: Bool) {
        continuation?.resume(returning: AgentOutcome(status: success ? .completed : .failed,
            summary: success ? "Actual result" : "Could not finish", report: success ? "# Real report\nVerified result" : nil,
            steps: 1, usage: ModelUsage(inputTokens: 1, outputTokens: 1)))
        continuation = nil
    }
}

@MainActor func waitFor(_ condition: () async -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
        guard ContinuousClock.now < end else { throw NSError(domain: "Test timed out", code: 1) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor @Suite(.serialized) struct CompanionStoreTests {
    func fixture(_ tasks: [CompanionTask] = [], service: StoreService) throws -> (CompanionStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zoop-ui-\(UUID())")
        let persistence = CompanionPersistence(directory: folder)
        try persistence.save(CompanionSnapshot(tasks: tasks, soundEnabled: false))
        let store = CompanionStore(service: service, persistence: persistence,
                                   exports: ExportCoordinator(directory: folder.appendingPathComponent("exports")))
        store.isExpanded = true; store.recordInteraction()
        return (store, folder)
    }

    @Test func proposalWaitsForTheButtonAndOnlyOneTaskExecutes() async throws {
        let service = StoreService()
        let (store, folder) = try fixture(service: service)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        store.send("Task")
        try await waitFor { !store.isResponding }
        let task = try #require(store.tasks.last)
        #expect(task.phase == .pending)
        #expect(await service.executions == 0)
        #expect(store.approve(task.id))
        #expect(!store.approve(task.id))
        store.finishDispatch(task.id)
        try await waitFor { await service.executions == 1 }
        let messages = store.messages.count
        store.send("Another task")
        #expect(store.messages.count == messages)
        try await waitFor { store.screenshot(for: task.id) != nil }
        #expect(store.task(task.id)?.progress == 99) // progress notes cannot fake completion
        await service.finish(success: true)
        try await waitFor { store.task(task.id)?.phase == .complete }
        #expect(store.task(task.id)?.progress == 100)
        let report = try String(contentsOf: folder.appendingPathComponent("exports/\(task.fileName)"), encoding: .utf8)
        #expect(report == "# Real report\nVerified result")
        #expect(store.messages.last?.text.contains("Actual result") == true)
    }

    @Test func aSecondApprovalIsRejectedWhileTheFirstTaskRuns() async throws {
        let first = pendingTask(), second = pendingTask()
        let service = StoreService()
        let (store, folder) = try fixture([first, second], service: service)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        #expect(store.approve(first.id))
        #expect(!store.approve(second.id))
        store.finishDispatch(first.id)
        try await waitFor { await service.executions == 1 }
        #expect(!store.approve(second.id))
        await service.finish(success: false)
        try await waitFor { store.task(first.id)?.phase == .failed }
        #expect(store.task(first.id)?.progress != 100)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("exports/\(first.fileName)").path))
    }

    @Test func oldSnapshotRemainsReadableAndIsBackedUpBeforeWriting() throws {
        let service = StoreService(reply: CompanionReply(text: "Hello"))
        let (store, folder) = try fixture([pendingTask()], service: service)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("companion-state.json")
        let original = try Data(contentsOf: file)
        let persistence = CompanionPersistence(directory: folder)
        try persistence.save(CompanionSnapshot())
        #expect(try Data(contentsOf: folder.appendingPathComponent("companion-state.pre-live.json")) == original)
        try persistence.save(CompanionSnapshot(messages: [.init(role: .user, text: "New")]))
        #expect(try Data(contentsOf: folder.appendingPathComponent("companion-state.pre-live.json")) == original)
    }

    @Test func restoredRunningTaskCannotResumeOrExecuteAutomatically() throws {
        var task = pendingTask()
        task.apply(.approve); task.apply(.arrive)
        let service = StoreService()
        let (store, folder) = try fixture([task], service: service)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: folder) }
        #expect(store.tasks[0].phase == .failed)
        #expect(!store.approve(task.id))
        #expect(store.workingTask == nil)
    }

    @Test func questionIsAnsweredInTheAppAndCancellationUnblocksIt() async throws {
        let (stream, sink) = AsyncStream.makeStream(of: CompanionPrompter.Question?.self)
        let prompter = CompanionPrompter { sink.yield($0) }
        let waiting = Task { await prompter.ask("Proceed?") }
        var iterator = stream.makeAsyncIterator()
        let event = try #require(await iterator.next())
        let question = try #require(event)
        await prompter.answer(question.id, text: "no")
        #expect(await waiting.value == "no")
        _ = await iterator.next() // cleared question
        let cancelled = Task { await prompter.ask("Another?") }
        _ = await iterator.next()
        cancelled.cancel()
        #expect(await cancelled.value == nil)
        sink.finish()
    }

    @Test func permissionCardCarriesExactChoicesAndStaleNotificationCannotAnswerIt() async throws {
        let permission = PermissionPrompt(id: "system-dialog", ownerApp: "com.apple.CoreLocationAgent", ownerName: "CoreLocationAgent",
            message: "Maps requests your location", choices: [.init(id: "once", title: "Allow Once"), .init(id: "deny", title: "Don’t Allow")])
        let (stream, sink) = AsyncStream.makeStream(of: CompanionPrompter.Question?.self)
        let prompter = CompanionPrompter { sink.yield($0) }
        let waiting = Task { await prompter.choosePermission(permission) }
        var iterator = stream.makeAsyncIterator()
        let event = try #require(await iterator.next())
        let question = try #require(event)
        #expect(question.permission == permission)
        await prompter.answer(UUID(), text: "deny") // unrelated old notification
        await prompter.answer(question.id, text: "once")
        #expect(await waiting.value == "once")
        sink.finish()
    }
}
