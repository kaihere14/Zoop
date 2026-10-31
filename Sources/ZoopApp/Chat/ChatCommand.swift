import Foundation

/// Slash commands typed in the chat input. They run locally in the app and are never sent to a model,
/// so they cost no tokens.
enum ChatCommand: String, CaseIterable, Identifiable {
    case clear, help

    enum Parsed: Equatable {
        case command(ChatCommand)
        case unknown(String)
    }

    var id: String { rawValue }
    var name: String { "/" + rawValue }
    var summary: String {
        switch self {
        case .clear: "Erase the chat and finished tasks"
        case .help: "List the available commands"
        }
    }

    /// Returns nil for normal messages. A leading word such as `/Users/me/file` contains another slash,
    /// so it is treated as text rather than an unknown command.
    static func parse(_ text: String) -> Parsed? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let word = trimmed.dropFirst().prefix { !$0.isWhitespace }.lowercased()
        guard !word.contains("/") else { return nil }
        return ChatCommand(rawValue: word).map(Parsed.command) ?? .unknown("/" + word)
    }

    /// Commands that match a partly typed `/word`, for the suggestion menu.
    static func suggestions(for draft: String) -> [ChatCommand] {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return [] }
        let prefix = draft.dropFirst().lowercased()
        guard !prefix.contains("/") else { return [] }
        return allCases.filter { $0.rawValue.hasPrefix(prefix) }
    }

    static var helpText: String {
        "Commands:\n" + allCases.map { "\($0.name) — \($0.summary)" }.joined(separator: "\n")
    }
}
