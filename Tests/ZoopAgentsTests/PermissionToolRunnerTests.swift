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
    private var scans = 0
    func permissionPrompts() async throws -> [PermissionPrompt] {
        scans += 1
        // The pre-action scan sees nothing; the dialog appears once the action asked for consent.
        if scans == 2, let next = queued { queued = nil; pending = [next] }
        return pending
    }
    func setAppDialog(_ prompt: PermissionPrompt?) { pending = []; appPrompt = prompt }
    /// A system consent dialog that appears after the next action runs.
    private var queued: PermissionPrompt?
    func queueSystemPrompt(_ prompt: PermissionPrompt) { queued = prompt }
    func showSystemPrompt(_ prompt: PermissionPrompt) { pending = [prompt] }
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
    var answers: [String]
    private(set) var prompts: [PermissionPrompt] = []
    private(set) var questions: [String] = []
    init(_ replies: [String], answers: [String] = []) { self.replies = replies; self.answers = answers }
    func ask(_ question: String) async -> String? {
        questions.append(question)
        return answers.isEmpty ? nil : answers.removeFirst()
    }
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

    // MARK: - Dialogs and saves always go to the person

    static let saveSheet = PermissionPrompt(id: "save-sheet", ownerApp: "com.apple.TextEdit", ownerName: "TextEdit",
        message: "Save As: Untitled.rtf\nWhere: Documents",
        choices: [.init(id: "cancel", title: "Cancel"), .init(id: "save", title: "Save", enabled: false)], kind: .appDialog)

    @Test func aDialogTheActionOpensIsShownToThePersonImmediately() async {
        let source = PermissionSource(), prompter = PermissionPrompter(["cancel"]), tools = OpensDialog(source, Self.saveSheet)
        await source.setAppDialog(nil) // no permission prompt pending
        let result = await PermissionToolRunner(tools: tools, permissions: source, prompter: prompter, onEvent: { _ in })
            .call("press_key", argumentsJSON: #"{"keys":"cmd+s"}"#)
        #expect(!result.isError && result.requiresObservation)
        #expect(result.content["human_choice"] == "Cancel")
        #expect(result.content["dialog_disabled_choices"] == ["Save"])
        #expect(result.content["next"]?.stringValue?.contains("save_document") == true)
        #expect(await prompter.prompts == [Self.saveSheet])
        #expect(await source.selections.map(\.1) == ["cancel"])
    }

    @Test func anOpenDialogIsAnsweredBeforeTheActionAndTheActionIsNotRun() async {
        let source = PermissionSource(), prompter = PermissionPrompter(["cancel"]), tools = FakeTools()
        await source.setAppDialog(Self.saveSheet)
        let result = await PermissionToolRunner(tools: tools, permissions: source, prompter: prompter, onEvent: { _ in })
            .call("click", argumentsJSON: #"{"bundle_id":"com.apple.TextEdit","element":"Save"}"#)
        #expect(result.content["human_choice"] == "Cancel")
        #expect(result.content["detail"]?.stringValue?.hasPrefix("Not run") == true)
        #expect(await tools.called.isEmpty)
    }

    @Test(arguments: [("yes", 1), ("no", 0)])
    func everySaveNeedsThePersonsApproval(_ answer: String, _ saves: Int) async {
        let source = PermissionSource(), tools = FakeTools()
        await source.setAppDialog(nil)
        let prompter = PermissionPrompter([], answers: [answer])
        let result = await PermissionToolRunner(tools: tools, permissions: source, prompter: prompter, onEvent: { _ in })
            .call("save_document", argumentsJSON: #"{"bundle_id":"com.apple.TextEdit","path":"~/Documents/MacBook Quote.rtf"}"#)
        #expect(await prompter.questions == ["Save the TextEdit document as ~/Documents/MacBook Quote.rtf?"])
        #expect(await tools.called.count == saves)
        #expect(result.isError == (saves == 0))
        if saves == 0 { #expect(result.content["error"] == "declined") }
    }

    @Test(arguments: [("yes", 1), ("no", 0)])
    func everyEmailNeedsThePersonsApprovalOfTheExactMessage(_ answer: String, _ sends: Int) async {
        let source = PermissionSource(), tools = FakeTools()
        await source.setAppDialog(nil)
        let prompter = PermissionPrompter([], answers: [answer])
        let result = await PermissionToolRunner(tools: tools, permissions: source, prompter: prompter, onEvent: { _ in })
            .call("send_email", argumentsJSON: #"{"to":"nikhil@example.com","subject":"MacBook quote","body":"Total: 530646"}"#)
        #expect(await prompter.questions == ["Send this email to nikhil@example.com?\n\nSubject: MacBook quote\n\nTotal: 530646"])
        #expect(await tools.called.count == sends)
        if sends == 0 { #expect(result.content["error"] == "declined") }
    }

    @Test func consentPendingActionRunsOnceMoreAfterThePersonAnswers() async {
        let source = PermissionSource(), tools = ConsentThenSave()
        await source.setAppDialog(nil)
        await source.queueSystemPrompt(locationPermission)
        let prompter = PermissionPrompter(["allow"], answers: ["yes"])
        let result = await PermissionToolRunner(tools: tools, permissions: source, prompter: prompter, onEvent: { _ in })
            .call("save_document", argumentsJSON: #"{"bundle_id":"com.apple.TextEdit","path":"~/Documents/Quote.rtf"}"#)
        #expect(!result.isError && result.content["verified"] == true)
        #expect(await tools.calls == 2)
        #expect(await source.selections.map(\.1) == ["allow"])
    }

    @Test func missingConsentDialogDoesNotRepeatTheTaskAction() async {
        let source = PermissionSource(), tools = ConsentThenSave()
        await source.setAppDialog(nil)
        let result = await PermissionToolRunner(tools: tools, permissions: source,
            prompter: PermissionPrompter([], answers: ["yes"]), consentPolls: 0, onEvent: { _ in })
            .call("save_document", argumentsJSON: #"{"bundle_id":"com.apple.TextEdit","path":"~/Documents/Quote.rtf"}"#)
        #expect(result.isError && result.content["error"] == "consent_pending")
        #expect(await tools.calls == 1)
        #expect(await source.selections.isEmpty)
    }

    @Test func automationThenFolderConsentBothFinishBeforeSaving() async {
        let source = PermissionSource()
        await source.setAppDialog(nil)
        let tools = SequentialConsent(source: source)
        let prompter = PermissionPrompter(["allow", "folder-allow"], answers: ["yes"])
        let result = await PermissionToolRunner(tools: tools, permissions: source, prompter: prompter, consentPolls: 0, onEvent: { _ in })
            .call("save_document", argumentsJSON: #"{"bundle_id":"com.apple.TextEdit","path":"~/Documents/Quote.rtf"}"#)
        #expect(!result.isError && result.content["verified"] == true)
        #expect(await tools.calls == 3)
        #expect(await source.selections.map(\.1) == ["allow", "folder-allow"])
    }

    @Test func dialogReadFailureStopsInputInsteadOfBeingSilentlyIgnored() async {
        let tools = FakeTools()
        let result = await PermissionToolRunner(tools: tools, permissions: UnreadableDialogs(),
            prompter: PermissionPrompter([]), onEvent: { _ in })
            .call("click", argumentsJSON: #"{"bundle_id":"com.apple.TextEdit","x":1,"y":2}"#)
        #expect(result.isError && result.content["error"] == "setup_error")
        #expect(await tools.called.isEmpty)
    }

    @Test func aDisabledChoiceCannotBeDispatchedByThePrompter() async {
        let source = PermissionSource(), tools = FakeTools()
        await source.setAppDialog(Self.saveSheet)
        let result = await PermissionToolRunner(tools: tools, permissions: source, prompter: PermissionPrompter(["save"]), onEvent: { _ in })
            .call("request_dialog_help", argumentsJSON: #"{"bundle_id":"com.apple.TextEdit"}"#)
        #expect(result.isError)
        #expect(await source.selections.isEmpty)
    }

    @Test func closingADialogCannotTurnAFailedActionIntoSuccess() {
        let action = ToolResult(tool: "click", isError: true, content: ["ok": false, "error": "unsupported"])
        let answer = ToolResult(tool: "request_dialog_help", isError: false, content: ["ok": true, "human_choice": "OK"])
        #expect(PermissionToolRunner.merge(answer, into: action).isError)
    }
}

actor SequentialConsent: ToolRunning {
    let source: PermissionSource
    private(set) var calls = 0
    init(source: PermissionSource) { self.source = source }
    func call(_ name: String, argumentsJSON: String) async -> ToolResult {
        calls += 1
        if calls == 1 { await source.showSystemPrompt(locationPermission) }
        if calls == 2 {
            await source.showSystemPrompt(PermissionPrompt(id: "folder", ownerApp: "system", ownerName: "System", message: "Documents access",
                choices: [.init(id: "folder-allow", title: "OK")]))
        }
        return calls <= 2
            ? ToolResult(tool: name, isError: true, content: ["ok": false, "error": "consent_pending"])
            : ToolResult(tool: name, isError: false, content: ["ok": true, "verified": true])
    }
}

struct UnreadableDialogs: PermissionHandling {
    func permissionPrompts() async throws -> [PermissionPrompt] { [] }
    func appDialogs(bundleID: String) async throws -> [PermissionPrompt] {
        throw BridgeError.helperFailure(HelperFailure(.permissionDenied, "Accessibility missing"))
    }
    func respondToPermission(promptID: String, choiceID: String) async throws -> ActionReport {
        throw BridgeError.helperFailure(HelperFailure(.notFound, "No dialog"))
    }
}

/// Opens the given dialog in the app when it runs, like cmd+s opening a Save sheet.
actor OpensDialog: ToolRunning {
    let source: PermissionSource
    let dialog: PermissionPrompt
    init(_ source: PermissionSource, _ dialog: PermissionPrompt) { self.source = source; self.dialog = dialog }
    func call(_ name: String, argumentsJSON: String) async -> ToolResult {
        await source.setAppDialog(dialog)
        return ToolResult(tool: name, isError: false, content: ["ok": true, "method": "pidKeys", "app": .string(dialog.ownerApp)])
    }
}

/// First call: macOS shows a consent dialog instead of running. Second call: saved.
actor ConsentThenSave: ToolRunning {
    private(set) var calls = 0
    func call(_ name: String, argumentsJSON: String) async -> ToolResult {
        calls += 1
        return calls == 1
            ? ToolResult(tool: name, isError: true, content: ["ok": false, "error": "consent_pending", "message": "asking"])
            : ToolResult(tool: name, isError: false, content: ["ok": true, "verified": true])
    }
}
