import Foundation
import UserNotifications
import ZoopAgents

@MainActor
protocol QuestionNotifying: AnyObject {
    func post(_ question: CompanionPrompter.Question, task: String?)
    func withdraw(_ id: UUID)
}

/// Shows the executor's questions as macOS notifications while the notch is closed, so a task never
/// waits unseen. Confirmations get Allow and Deny buttons; information requests get a Reply field.
/// Clicking the notification itself opens the question in the notch.
///
/// The notification's identifier is the question's ID, so an answer only ever reaches the question
/// it was posted for, and answering in the notch removes the notification.
@MainActor
final class QuestionNotifier: NSObject, QuestionNotifying, UNUserNotificationCenterDelegate {
    private enum ID {
        static let confirm = "zoop.question.confirm"
        static let info = "zoop.question.info"
        static let allow = "zoop.allow"
        static let deny = "zoop.deny"
        static let reply = "zoop.reply"
        static let permission = "zoop.permission."
        static let choice = "zoop.permission.choice."
    }

    private weak var store: CompanionStore?
    private let center = UNUserNotificationCenter.current()
    private var authorized: Bool?
    private var categories: Set<UNNotificationCategory> = []

    init(store: CompanionStore) {
        self.store = store
        super.init()
        center.delegate = self
        let allow = UNNotificationAction(identifier: ID.allow, title: "Allow", options: [])
        let deny = UNNotificationAction(identifier: ID.deny, title: "Deny", options: [.destructive])
        let reply = UNTextInputNotificationAction(identifier: ID.reply, title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Your answer")
        categories = [
            UNNotificationCategory(identifier: ID.confirm, actions: [allow, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: ID.info, actions: [reply, deny], intentIdentifiers: []),
        ]
        center.setNotificationCategories(categories)
    }

    func post(_ question: CompanionPrompter.Question, task: String?) {
        Task { @MainActor in
            guard await ensureAuthorized() else { return }
            guard store?.question?.id == question.id else { return }
            let content = UNMutableNotificationContent()
            content.title = question.permission.map { $0.kind == .appDialog ? "\($0.ownerName) needs your choice" : "Permission needed in the agent session" }
                ?? (question.kind == .confirm ? "Zoop needs your approval" : "Zoop has a question")
            if let task { content.subtitle = task }
            content.body = question.text
            content.categoryIdentifier = question.kind == .confirm ? ID.confirm : ID.info
            if let permission = question.permission {
                let category = ID.permission + question.id.uuidString
                // Exact dialog labels; never turn 'Allow once' into a generic 'Allow'.
                let actions = permission.choices.prefix(4).map {
                    UNNotificationAction(identifier: ID.choice + $0.id, title: $0.title, options: [])
                }
                categories = categories.filter { !$0.identifier.hasPrefix(ID.permission) }
                categories.insert(UNNotificationCategory(identifier: category, actions: actions, intentIdentifiers: []))
                center.setNotificationCategories(categories)
                content.categoryIdentifier = category
            }
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: question.id.uuidString, content: content, trigger: nil))
        }
    }

    func withdraw(_ id: UUID) {
        center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
        center.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }

    /// Asks macOS for permission the first time a question needs a notification.
    private func ensureAuthorized() async -> Bool {
        if let authorized { return authorized }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        authorized = granted
        if !granted {
            store?.notice = "Turn on notifications for Zoop in System Settings to answer questions from notifications."
        }
        return granted
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = UUID(uuidString: response.notification.request.identifier) else { return }
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            guard let store else { return }
            if action.hasPrefix(ID.choice) {
                store.answerPermission(id, choiceID: String(action.dropFirst(ID.choice.count)))
                return
            }
            switch action {
            case ID.allow: store.answerQuestion(id, text: "yes")
            case ID.deny: store.answerQuestion(id, text: "no")
            case ID.reply:
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { store.answerQuestion(id, text: text) }
                else { store.showQuestion() }
            default: store.showQuestion()  // The notification itself was clicked.
            }
        }
    }
}
