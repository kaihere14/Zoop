import Foundation
import Testing
import ZoopShared
@testable import ZoopHelper

@Suite(.serialized) struct PermissionBridgeTests {
    let prompt = PermissionPrompt(id: "system-dialog", ownerApp: "com.apple.CoreLocationAgent", ownerName: "CoreLocationAgent",
        message: "Maps requests your location", choices: [.init(id: "once", title: "Allow Once"), .init(id: "deny", title: "Don’t Allow")])

    @Test func appDialogKindAndSaveChoicesRoundTripOverTheBridge() async throws {
        let path = temporarySocketPath()
        let save = PermissionPrompt(id: "save", ownerApp: "com.apple.TextEdit", ownerName: "TextEdit", message: "Save As: Untitled.rtf",
                                    choices: [.init(id: "save", title: "Save"), .init(id: "cancel", title: "Cancel")], kind: .appDialog)
        let server = try startServer(at: path, backend: FakeBackend(prompts: [save]))
        defer { server.stop() }
        let connection = HelperConnection(configuration: testConfiguration(path))
        #expect(try await connection.appDialogs(bundleID: "com.apple.TextEdit") == [save])
        #expect(try await connection.appDialogs(bundleID: "com.apple.Maps").isEmpty)
        await connection.disconnect()
    }

    @Test func readsExactChoicesAndRoutesAHumanResponseOverTheSocket() async throws {
        let path = temporarySocketPath(), recorder = ActionRecorder()
        let server = try startServer(at: path, backend: FakeBackend(actionRecorder: recorder, prompts: [prompt]))
        defer { server.stop() }
        let connection = HelperConnection(configuration: testConfiguration(path))
        #expect(try await connection.permissionPrompts() == [prompt])
        await #expect(throws: BridgeError.helperFailure(HelperFailure(.notFound, "no permission dialog"))) {
            try await connection.respondToPermission(promptID: prompt.id, choiceID: "yes")
        }
        #expect(await recorder.permissionSelections == 0)
        #expect(try await connection.respondToPermission(promptID: prompt.id, choiceID: "once").landed == true)
        #expect(await recorder.permissionSelections == 1)
        await connection.disconnect()
    }

    @Test func neverReplaysAHumanChoiceAfterHelperRestart() async throws {
        let path = temporarySocketPath(), recorder = ActionRecorder()
        let backend = FakeBackend(actionDelay: .milliseconds(400), actionRecorder: recorder, prompts: [prompt])
        var server = try startServer(at: path, backend: backend)
        defer { server.stop() }
        let connection = HelperConnection(configuration: testConfiguration(path))
        _ = try await connection.connect()
        let selection = Task { try await connection.respondToPermission(promptID: prompt.id, choiceID: "once") }
        try await recorder.waitForPermission()
        server.stop()
        server = try startServer(at: path, backend: backend)
        await #expect(throws: BridgeError.interrupted(command: "respondToPermission")) { try await selection.value }
        _ = try await connection.permissionPrompts()
        try await Task.sleep(for: .milliseconds(450))
        #expect(await recorder.permissionSelections == 1)
        await connection.disconnect()
    }
}
