import Foundation
import ZoopShared

/// Reads and edits `~/.zoop/config.json` for the settings screen. Only the parts it manages change;
/// anything else in the file (for example an Ollama base URL) is kept.
///
/// "One active provider" means all three agents (chat, planner, executor) name the same provider
/// and model. Each provider also remembers its chosen model in `providers.<name>.model`, so turning
/// a provider back on restores its model.
public struct ZoopConfigFile: Sendable, Equatable {
    public private(set) var value: JSONValue
    static let roles: [AgentRole] = [.chat, .planner, .executor]

    public init(_ value: JSONValue = .object([:])) {
        self.value = value.objectValue == nil ? .object([:]) : value
    }

    public static func load(path: String = ModelConfiguration.configPath()) throws -> ZoopConfigFile {
        guard let data = FileManager.default.contents(atPath: path) else { return ZoopConfigFile() }
        return ZoopConfigFile(try JSONDecoder().decode(JSONValue.self, from: data))
    }

    /// Written atomically and readable only by this user (0600), because it may still hold other settings.
    public func save(path: String = ModelConfiguration.configPath()) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((value.prettyJSONText + "\n").utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// The provider every agent uses, or nil when none is set or the agents use different providers.
    public var activeProvider: ModelProvider? {
        let names = Self.roles.map { value["agents"]?[$0.rawValue]?["provider"]?.stringValue?.lowercased() }
        guard let first = names.first ?? nil, names.allSatisfy({ $0 == first }) else { return nil }
        return ModelProvider(rawValue: first)
    }

    public func model(for provider: ModelProvider) -> String? {
        if let saved = value["providers"]?[provider.rawValue]?["model"]?.stringValue, !saved.isEmpty { return saved }
        guard activeProvider == provider else { return nil }
        return value["agents"]?[AgentRole.executor.rawValue]?["model"]?.stringValue
    }

    public mutating func setModel(_ model: String, for provider: ModelProvider) {
        update(["providers", provider.rawValue, "model"], to: .string(model))
        if activeProvider == provider { activate(provider, model: model) }
    }

    public mutating func activate(_ provider: ModelProvider, model: String) {
        update(["providers", provider.rawValue, "model"], to: .string(model))
        for role in Self.roles {
            update(["agents", role.rawValue], to: ["provider": .string(provider.rawValue), "model": .string(model)])
        }
    }

    /// Turns every provider off: the agents have no provider until one is turned on again.
    public mutating func deactivate() {
        update(["agents"], to: .object([:]))
    }

    /// Removes plain-text `apiKey` entries and returns them, so they can move into the Keychain.
    public mutating func takePlainKeys() -> [ModelProvider: String] {
        var found: [ModelProvider: String] = [:]
        for (name, settings) in value["providers"]?.objectValue ?? [:] {
            guard let provider = ModelProvider(rawValue: name), let key = settings["apiKey"]?.stringValue else { continue }
            if !key.isEmpty { found[provider] = key }
            update(["providers", name, "apiKey"], to: nil)
        }
        return found
    }

    /// Sets (or with nil removes) the value at a key path, creating objects along the way.
    private mutating func update(_ path: [String], to newValue: JSONValue?) {
        func apply(_ node: JSONValue?, _ path: ArraySlice<String>) -> JSONValue {
            var object = node?.objectValue ?? [:]
            guard let key = path.first else { return newValue ?? .null }
            if path.count == 1 { object[key] = newValue } else { object[key] = apply(object[key], path.dropFirst()) }
            return .object(object)
        }
        value = apply(value, path[...])
    }
}
