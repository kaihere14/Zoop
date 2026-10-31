import Foundation
import Testing
import ZoopAgents
import ZoopShared
@testable import ZoopApp

struct ChatCommandTests {
    @Test func parsesCommandsAndLeavesNormalTextAlone() {
        #expect(ChatCommand.parse("/clear") == .command(.clear))
        #expect(ChatCommand.parse("  /HELP  ") == .command(.help))
        #expect(ChatCommand.parse("/nope") == .unknown("/nope"))
        #expect(ChatCommand.parse("hello /clear") == nil)
        #expect(ChatCommand.parse("/Users/me/notes.txt summarize this") == nil)
    }

    @Test func suggestsMatchingCommandsOnlyWhileTypingTheName() {
        #expect(ChatCommand.suggestions(for: "/") == ChatCommand.allCases)
        #expect(ChatCommand.suggestions(for: "/cl") == [.clear])
        #expect(ChatCommand.suggestions(for: "/clear now").isEmpty)
        #expect(ChatCommand.suggestions(for: "clear").isEmpty)
    }
}

@MainActor @Suite(.serialized) struct ChatCommandStoreTests {
    @Test func clearErasesTheChatOnDiskWithoutCallingTheModel() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zoop-cmd-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let persistence = CompanionPersistence(directory: folder)
        try persistence.save(CompanionSnapshot(messages: [.init(role: .user, text: "old"), .init(role: .assistant, text: "reply")],
                                               tasks: [], soundEnabled: false))
        let store = CompanionStore(service: StoreService(reply: CompanionReply(text: "unused")), persistence: persistence,
                                   exports: ExportCoordinator(directory: folder.appendingPathComponent("exports")))
        defer { store.shutdown() }
        #expect(store.messages.count == 2)
        store.send("/clear")
        #expect(store.messages.isEmpty)
        #expect(try persistence.load().messages.isEmpty)

        store.send("/help")
        #expect(store.messages.count == 1 && store.messages[0].text == ChatCommand.helpText)
        store.send("/bogus")
        #expect(store.notice?.contains("/bogus") == true)
        #expect(!store.isThinking)
    }
}
