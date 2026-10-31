import AppKit
import ZoopShared

/// Sends an email with the Mail app's AppleScript interface and Mail's configured account.
/// Web mail compose forms ignored synthetic input in the agent session, and typing into Mail's
/// own compose window is just as fragile, so the message is created and sent in one script.
/// The person approves each send in Zoop before this runs. The first send asks macOS for
/// Automation permission to control Mail; that appears as a card (`consentPending`).
enum MailSender {
    static let mail = "com.apple.mail"

    static func send(_ email: SendEmailAction) async throws -> ActionReport {
        let recipients = email.to.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !recipients.isEmpty, recipients.allSatisfy(isAddress) else {
            throw HelperFailure(.badRequest, "give one or more plain email addresses, such as name@example.com")
        }
        _ = try await Apps.open(mail)
        try await DocumentSaver.requireAutomation(mail, name: "Mail")
        let script = source(recipients: recipients, subject: email.subject, body: email.body)
        let outcome: (sent: Bool, error: String?) = await MainActor.run {
            var error: NSDictionary?
            guard let compiled = NSAppleScript(source: script) else { return (false, "could not build the send command") }
            let result = compiled.executeAndReturnError(&error)
            if let error { return (false, (error[NSAppleScript.errorMessage] as? String) ?? "\(error)") }
            return (result.booleanValue, nil)
        }
        if let failure = outcome.error {
            throw HelperFailure(.unsupported, "Mail could not send the message: \(failure). Check that Mail has an account set up in the agent session.")
        }
        let list = recipients.joined(separator: ", ")
        return ActionReport(action: "sendEmail", method: .appleEvent, app: mail, landed: outcome.sent,
                            detail: outcome.sent ? "Mail sent \"\(email.subject)\" to \(list). Check Mail's Sent mailbox if delivery matters."
                                                 : "Mail did not confirm sending \"\(email.subject)\" to \(list). Check Mail's Outbox.")
    }

    static func isAddress(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".")
            && !text.contains(where: { $0.isWhitespace || "\"\\<>,;".contains($0) })
    }

    static func source(recipients: [String], subject: String, body: String) -> String {
        let to = recipients.map {
            "make new to recipient at end of to recipients with properties {address:\"\(DocumentSaver.escape($0))\"}"
        }.joined(separator: "\n            ")
        // The client gives an action 10 seconds; stop the Apple event before that.
        return """
        with timeout of 8 seconds
            tell application id "\(mail)"
                set newMessage to make new outgoing message with properties {subject:"\(DocumentSaver.escape(subject))", content:"\(DocumentSaver.escape(body))", visible:false}
                tell newMessage
                    \(to)
                end tell
                return (send newMessage)
            end tell
        end timeout
        """
    }
}
