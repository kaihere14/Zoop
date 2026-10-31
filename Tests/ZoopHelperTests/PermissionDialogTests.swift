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
}
