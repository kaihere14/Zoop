import Foundation

/// A real dialog observed by the helper, with opaque, short-lived action identities.
/// These are human choices, never model tool arguments.
public struct PermissionPrompt: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case systemPermission, appDialog }
    public let id: String
    public let ownerApp: String
    public let ownerName: String
    public let message: String
    public let choices: [PermissionChoice]
    public let kind: Kind

    public init(id: String, ownerApp: String, ownerName: String, message: String, choices: [PermissionChoice], kind: Kind = .systemPermission) {
        self.id = id; self.ownerApp = ownerApp; self.ownerName = ownerName
        self.message = message; self.choices = choices; self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case id, ownerApp, ownerName, message, choices, kind }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ownerApp = try c.decode(String.self, forKey: .ownerApp)
        ownerName = try c.decode(String.self, forKey: .ownerName)
        message = try c.decode(String.self, forKey: .message)
        choices = try c.decode([PermissionChoice].self, forKey: .choices)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .systemPermission
    }
}

public struct PermissionChoice: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    /// False when the dialog shows this button greyed out. It is listed so the person can see why
    /// the task is stuck (for example a disabled Save), but it cannot be chosen.
    public let enabled: Bool

    public init(id: String, title: String, enabled: Bool = true) { self.id = id; self.title = title; self.enabled = enabled }

    private enum CodingKeys: String, CodingKey { case id, title, enabled }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}
