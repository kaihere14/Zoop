import ApplicationServices
import Testing
import ZoopShared
@testable import ZoopHelper

@Suite struct PermissionDialogTests {
    @Test func sheetsAndModalDialogsAreDistinctFromOrdinaryAppWindows() {
        #expect(PermissionDialogs.isDialog(role: kAXSheetRole, subrole: nil, modal: false))
        #expect(PermissionDialogs.isDialog(role: kAXWindowRole, subrole: kAXDialogSubrole, modal: false))
        #expect(PermissionDialogs.isDialog(role: kAXWindowRole, subrole: nil, modal: true))
        #expect(!PermissionDialogs.isDialog(role: kAXWindowRole, subrole: kAXStandardWindowSubrole, modal: false))
        #expect(!PermissionDialogs.isDialog(role: kAXButtonRole, subrole: nil, modal: false))
    }
    @Test func changedTextOrChoicesInvalidateAnObservedPermission() {
        let window = AXElement(AXUIElementCreateApplication(42))
        let prompt = PermissionPrompt(id: "dialog", ownerApp: "com.apple.CoreLocationAgent", ownerName: "CoreLocationAgent",
            message: "Maps would like your location", choices: [.init(id: "deny", title: "Don’t Allow"), .init(id: "allow", title: "Allow")])
        let observed = PermissionDialogs.Observed(window: window, prompt: prompt, buttons: [window, window], labels: prompt.choices.map(\.title))
        #expect(PermissionDialogs.retainedPrompt(window: window, message: prompt.message, labels: observed.labels, previous: [observed]) == prompt)
        #expect(PermissionDialogs.retainedPrompt(window: window, message: "Different app wants microphone access", labels: observed.labels, previous: [observed]) == nil)
        #expect(PermissionDialogs.retainedPrompt(window: window, message: prompt.message, labels: ["Always Allow", "Don’t Allow"], previous: [observed]) == nil)
        #expect(PermissionDialogs.retainedPrompt(window: AXElement(AXUIElementCreateApplication(43)), message: prompt.message, labels: observed.labels, previous: [observed]) == nil)
    }

    @Test func oldOrInventedChoiceTokensCannotSelectAButton() throws {
        let window = AXElement(AXUIElementCreateApplication(42))
        let prompt = PermissionPrompt(id: "dialog", ownerApp: "system", ownerName: "System", message: "Permission",
                                      choices: [.init(id: "once", title: "Allow Once"), .init(id: "always", title: "Always Allow")])
        let dialog = PermissionDialogs.Observed(window: window, prompt: prompt, buttons: [window, window], labels: prompt.choices.map(\.title))
        #expect(try PermissionDialogs.selection(promptID: "dialog", choiceID: "once", in: [dialog]).1 == 0)
        #expect(try PermissionDialogs.selection(promptID: "dialog", choiceID: "always", in: [dialog]).1 == 1)
        #expect(throws: HelperFailure.self) { try PermissionDialogs.selection(promptID: "old", choiceID: "once", in: [dialog]) }
        #expect(throws: HelperFailure.self) { try PermissionDialogs.selection(promptID: "dialog", choiceID: "yes", in: [dialog]) }
        #expect(throws: HelperFailure.self) { try PermissionDialogs.selection(promptID: "dialog", choiceID: "once", in: []) }
    }

    @Test func disabledButtonsAreShownButCannotBePressed() throws {
        let window = AXElement(AXUIElementCreateApplication(42))
        let prompt = PermissionPrompt(id: "save", ownerApp: "com.apple.TextEdit", ownerName: "TextEdit", message: "Save As: Quote.rtf",
            choices: [.init(id: "cancel", title: "Cancel"), .init(id: "save", title: "Save", enabled: false)], kind: .appDialog)
        let dialog = PermissionDialogs.Observed(window: window, prompt: prompt, buttons: [window, window], labels: ["Cancel", "Save"], enabled: [true, false])
        #expect(try PermissionDialogs.selection(promptID: "save", choiceID: "cancel", in: [dialog]).1 == 0)
        #expect(throws: HelperFailure.self) { try PermissionDialogs.selection(promptID: "save", choiceID: "save", in: [dialog]) }
        // Save becoming enabled is a new situation: the old identity is not reused.
        #expect(PermissionDialogs.retainedPrompt(window: window, message: prompt.message, labels: ["Cancel", "Save"], enabled: [true, false], previous: [dialog]) == prompt)
        #expect(PermissionDialogs.retainedPrompt(window: window, message: prompt.message, labels: ["Cancel", "Save"], enabled: [true, true], previous: [dialog]) == nil)
    }

    @Test func scriptedSavesStayInsideTheAgentUsersHome() throws {
        #expect(try DocumentSaver.destination("~/Documents/MacBook Quote.rtf", home: "/Users/sbagent").path == "/Users/sbagent/Documents/MacBook Quote.rtf")
        #expect(try DocumentSaver.destination("/Users/sbagent/Desktop/a.txt", home: "/Users/sbagent").path == "/Users/sbagent/Desktop/a.txt")
        #expect(throws: HelperFailure.self) { try DocumentSaver.destination("Documents/a.rtf", home: "/Users/sbagent") }
        #expect(throws: HelperFailure.self) { try DocumentSaver.destination("~/../armanthakur/a.rtf", home: "/Users/sbagent") }
        #expect(throws: HelperFailure.self) { try DocumentSaver.destination("/tmp/a.rtf", home: "/Users/sbagent") }
        #expect(throws: HelperFailure.self) { try DocumentSaver.destination("/Users/sbagentx/a.rtf", home: "/Users/sbagent") }
    }

    /// Regression: waiting for the Automation answer while holding the action gate deadlocked
    /// the press of that same consent button. The wait must end at the limit.
    @Test func consentRequestStopsWaitingAtTheLimit() async {
        let start = ContinuousClock.now
        let slow = await DocumentSaver.firstResult(within: .milliseconds(100)) { Thread.sleep(forTimeInterval: 2); return 0 }
        #expect(slow == nil)
        #expect(ContinuousClock.now - start < .seconds(1))
        let quick = await DocumentSaver.firstResult(within: .seconds(2)) { -1744 }
        #expect(quick == -1744)
    }

    @Test func mailRecipientsMustBePlainAddressesAndTextIsEscaped() {
        #expect(MailSender.isAddress("nikhillutrha04052007@gmail.com"))
        #expect(!MailSender.isAddress("Nikhil <n@gmail.com>"))
        #expect(!MailSender.isAddress("n@gmail"))
        #expect(!MailSender.isAddress("a\"@b.com"))
        let script = MailSender.source(recipients: ["a@b.com"], subject: "Say \"hi\"", body: "x\\y")
        #expect(script.contains("subject:\"Say \\\"hi\\\"\""))
        #expect(script.contains("content:\"x\\\\y\""))
        #expect(script.contains("address:\"a@b.com\""))
    }
}
