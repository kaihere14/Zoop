import Foundation
import Testing
import ZoopShared
@testable import ZoopAgents

let locationPermission = PermissionPrompt(id: "location", ownerApp: "com.apple.CoreLocationAgent", ownerName: "CoreLocationAgent",
    message: "“Maps” would like to use your current location.",
    choices: [.init(id: "deny", title: "Don’t Allow"), .init(id: "allow", title: "Allow")])

actor PermissionSource: PermissionHandling {
    private var pending = [locationPermission]
    private(set) var selections: [(String, String)] = []
    var confirmed: Bool
    var replaceFirst: Bool
    var appPrompt: PermissionPrompt?
    init(confirmed: Bool = true, replaceFirst: Bool = false) { self.confirmed = confirmed; self.replaceFirst = replaceFirst }
    func permissionPrompts() async throws -> [PermissionPrompt] { pending }
    func setAppDialog(_ prompt: PermissionPrompt) { pending = []; appPrompt = prompt }
    func appDialogs(bundleID: String) async throws -> [PermissionPrompt] { appPrompt.map { [$0] } ?? [] }
    func respondToPermission(promptID: String, choiceID: String) async throws -> ActionReport {
        selections.append((promptID, choiceID))
        if replaceFirst {
            replaceFirst = false
            pending = [PermissionPrompt(id: "new", ownerApp: "system", ownerName: "System", message: "Changed request",
                                        choices: [.init(id: "once", title: "Allow Once")])]
            throw BridgeError.helperFailure(HelperFailure(.notFound, "changed"))
        }
        if confirmed { pending = [] }
        if confirmed { appPrompt = nil }
        return ActionReport(action: "permissionChoice", method: .axPress, landed: confirmed ? true : nil, detail: "Dialog still present")
    }
}

actor PermissionPrompter: UserPrompting {
    var replies: [String]
    private(set) var prompts: [PermissionPrompt] = []
    init(_ replies: [String]) { self.replies = replies }
    func ask(_ question: String) async -> String? { nil }
    func choosePermission(_ prompt: PermissionPrompt) async -> String? {
        prompts.append(prompt)
        return replies.isEmpty ? nil : replies.removeFirst()
    }
}

@Suite struct PermissionToolRunnerTests {
    @Test func finalDialogHelperShowsActualSaveContextAndSendsOnlyTheSelectedButton() async {
        let prompt = PermissionPrompt(id: "save", ownerApp: "com.apple.TextEdit", ownerName: "TextEdit",
            message: "Grocery List\nSave As: Untitled.rtf\nWhere: Documents", choices: [.init(id: "cancel", title: "Cancel"), .init(id: "save", title: "Save")], kind: .appDialog)
        let source = PermissionSource(), prompter = PermissionPrompter(["cancel"]), tools = FakeTools()
        await source.setAppDialog(prompt)
        let result = await PermissionToolRunner(tools: tools, permissions: source, prompter: prompter, onEvent: { _ in })
            .call("request_dialog_help", argumentsJSON: #"{"bundle_id":"com.apple.TextEdit"}"#)
        #expect(!result.isError && result.requiresObservation)
        #expect(result.content["human_choice"] == "Cancel")
        #expect(await prompter.prompts == [prompt])
        #expect(await source.selections.first?.1 == "cancel")
        #expect(await tools.called.isEmpty)
    }

    @Test func finalDialogHelperNeverRepeatsAnUnconfirmedSavePress() async {
        let source = PermissionSource(confirmed: false), tools = FakeTools()
        await source.setAppDialog(PermissionPrompt(id: "save", ownerApp: "textedit", ownerName: "TextEdit", message: "Save As: Untitled.rtf",
            choices: [.init(id: "save", title: "Save")], kind: .appDialog))
        let result = await PermissionToolRunner(tools: tools, permissions: source, prompter: PermissionPrompter(["save"]), onEvent: { _ in })
            .call("request_dialog_help", argumentsJSON: #"{"bundle_id":"textedit"}"#)
        #expect(result.isError)
        #expect(await source.selections.count == 1)
        #expect(await tools.called.isEmpty)
    }
    @Test(arguments: ["allow", "deny"])
    func onlyTheHumansExactChoiceIsDispatchedBeforeTaskContinues(_ choice: String) async throws {
        let source = PermissionSource(), prompter = PermissionPrompter([choice]), tools = FakeTools()
        let runner = PermissionToolRunner(tools: tools, permissions: source, prompter: prompter, onEvent: { _ in })
        let result = await runner.call("screenshot", argumentsJSON: "{}")
        #expect(!result.isError && result.image != nil)
        #expect(await prompter.prompts == [locationPermission])
        #expect(await source.selections.count == 1)
        #expect(await source.selections.first?.1 == choice)
        #expect(await tools.called.map(\.0) == ["screenshot"])
    }

    @Test(arguments: [[], ["yes"], ["cancel_permission"]] as [[String]])
    func dismissalOrGenericApprovalNeverPressesAChoice(_ replies: [String]) async {
        let source = PermissionSource(), tools = FakeTools()
        let result = await PermissionToolRunner(tools: tools, permissions: source, prompter: PermissionPrompter(replies), onEvent: { _ in })
            .call("click", argumentsJSON: #"{"x":1,"y":2}"#)
        #expect(result.isError)
        #expect(await source.selections.isEmpty)
        #expect(await tools.called.isEmpty)
    }

    @Test func unconfirmedSystemPressIsNeverRetriedAndTaskActionDoesNotRun() async {
        let source = PermissionSource(confirmed: false), tools = FakeTools()
        let result = await PermissionToolRunner(tools: tools, permissions: source, prompter: PermissionPrompter(["allow"]), onEvent: { _ in })
            .call("type_text", argumentsJSON: #"{"text":"hello"}"#)
        #expect(result.isError && result.content["error"] == "setup_error")
        #expect(await source.selections.count == 1)
        #expect(await tools.called.isEmpty)
    }

    @Test func replacementDialogRequiresANewHumanChoice() async {
        let source = PermissionSource(replaceFirst: true), prompter = PermissionPrompter(["allow", "once"])
        let result = await PermissionToolRunner(tools: FakeTools(), permissions: source, prompter: prompter, onEvent: { _ in })
            .call("screenshot", argumentsJSON: "{}")
        #expect(!result.isError)
        #expect(await prompter.prompts.map(\.id) == ["location", "new"])
        #expect(await source.selections.map(\.1) == ["allow", "once"])
    }
}
