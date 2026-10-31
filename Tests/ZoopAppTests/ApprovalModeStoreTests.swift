import Foundation
import Testing
import ZoopAgents
import ZoopShared
@testable import ZoopApp

@MainActor @Suite(.serialized) struct ApprovalModeStoreTests {
    @Test func theModeChosenOnThePlanCardReachesTheExecutor() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zoop-mode-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let task = pendingTask()
        let persistence = CompanionPersistence(directory: folder)
        try persistence.save(CompanionSnapshot(tasks: [task], soundEnabled: false))
        let service = StoreService()
        let store = CompanionStore(service: service, persistence: persistence,
                                   exports: ExportCoordinator(directory: folder.appendingPathComponent("exports")))
        defer { store.shutdown() }
        store.approvalModes[task.id] = .auto
        #expect(store.approve(task.id))
        store.finishDispatch(task.id)
        try await waitFor { await service.executions == 1 }
        #expect(await service.modes == [.auto])
    }
}
