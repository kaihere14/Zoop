import Foundation
import ZoopShared

/// Known OpenAI-compatible providers. `custom` takes any base URL.
public enum ModelProvider: String, Sendable, CaseIterable {
    case gemini, openrouter, groq, openai, ollama, lmstudio, custom

    public var defaultBaseURL: URL? {
        switch self {
        case .gemini: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")
        case .openrouter: URL(string: "https://openrouter.ai/api/v1/")
        case .groq: URL(string: "https://api.groq.com/openai/v1/")
        case .openai: URL(string: "https://api.openai.com/v1/")
        case .ollama: URL(string: "http://localhost:11434/v1/")
        case .lmstudio: URL(string: "http://localhost:1234/v1/")
        case .custom: nil
        }
    }

    /// Environment variables that may hold this provider's key, in order of preference.
    public var keyVariables: [String] {
        switch self {
        case .gemini: ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
        case .openrouter: ["OPENROUTER_API_KEY"]
        case .groq: ["GROQ_API_KEY"]
        case .openai: ["OPENAI_API_KEY"]
        case .ollama, .lmstudio: []
        case .custom: ["ZOOP_CUSTOM_API_KEY"]
        }
    }

    var requiresKey: Bool { ![.ollama, .lmstudio, .custom].contains(self) }
    var simplifiesSchemas: Bool { self == .gemini }
    var extraHeaders: [String: String] { self == .openrouter ? ["X-Title": "Zoop"] : [:] }
}

/// The agents that use a model. Each can run on a different provider and model.
public enum AgentRole: String, Sendable {
    case executor, chat
}

/// Resolves which provider, model and key an agent uses.
///
/// Sources, highest priority first:
/// 1. explicit overrides (for example CLI flags),
/// 2. environment: `ZOOP_EXECUTOR_PROVIDER`, `ZOOP_EXECUTOR_MODEL`, `ZOOP_EXECUTOR_BASE_URL`
///    (`CHAT` instead of `EXECUTOR` for the chat agent) and provider keys such as `GEMINI_API_KEY`,
/// 3. `~/.zoop/config.json` (or `$ZOOP_CONFIG`):
///    `{"agents": {"executor": {"provider": "gemini", "model": "…"}},
///      "providers": {"gemini": {"apiKey": "…"}}}`
public struct ModelConfiguration: Sendable {
    public struct Overrides: Sendable {
        public var provider: String?
        public var model: String?
        public var baseURL: String?

        public init(provider: String? = nil, model: String? = nil, baseURL: String? = nil) {
            self.provider = provider
            self.model = model
            self.baseURL = baseURL
        }
    }

    let environment: [String: String]
    let file: JSONValue

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, file: JSONValue? = nil) {
        self.environment = environment
        self.file = file ?? Self.loadFile(environment: environment)
    }

    public static func configPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["ZOOP_CONFIG"] ?? (NSHomeDirectory() as NSString).appendingPathComponent(".zoop/config.json")
    }

    static func loadFile(environment: [String: String]) -> JSONValue {
        guard let data = FileManager.default.contents(atPath: configPath(environment: environment)),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .object([:]) }
        return value
    }

    /// - Parameter requireModel: pass false to resolve only the provider and key (for listing models).
    public func endpoint(for role: AgentRole, overrides: Overrides = Overrides(), requireModel: Bool = true) throws -> ModelEndpoint {
        let prefix = "ZOOP_\(role.rawValue.uppercased())_"
        let agent = file["agents"]?[role.rawValue]
        func pick(_ override: String?, _ variable: String, _ key: String) -> String? {
            [override, environment[prefix + variable], agent?[key]?.stringValue]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        }
        guard let providerName = pick(overrides.provider, "PROVIDER", "provider") else {
            throw ModelError.configuration("no provider for the \(role.rawValue) agent. Set \(prefix)PROVIDER (one of \(Self.providerList)) or agents.\(role.rawValue).provider in \(Self.configPath(environment: environment)).")
        }
        guard let provider = ModelProvider(rawValue: providerName.lowercased()) else {
            throw ModelError.configuration("unknown provider '\(providerName)'; use one of \(Self.providerList)")
        }
        guard let model = pick(overrides.model, "MODEL", "model") ?? (requireModel ? nil : "") else {
            throw ModelError.configuration("no model for the \(role.rawValue) agent. Set \(prefix)MODEL or agents.\(role.rawValue).model to a model name your \(provider.rawValue) account offers.")
        }
        let settings = file["providers"]?[provider.rawValue]
        let baseText = pick(overrides.baseURL, "BASE_URL", "baseURL") ?? settings?["baseURL"]?.stringValue
        guard let baseURL = baseText.flatMap(URL.init(string:)) ?? provider.defaultBaseURL else {
            throw ModelError.configuration("the custom provider needs a base URL: set \(prefix)BASE_URL or agents.\(role.rawValue).baseURL")
        }
        let key = provider.keyVariables.compactMap { environment[$0] }.first { !$0.isEmpty } ?? settings?["apiKey"]?.stringValue
        if provider.requiresKey, key?.isEmpty ?? true {
            throw ModelError.configuration("no API key for \(provider.rawValue). Set \(provider.keyVariables.joined(separator: " or ")) or providers.\(provider.rawValue).apiKey in \(Self.configPath(environment: environment)).")
        }
        return ModelEndpoint(provider: provider.rawValue, baseURL: baseURL, apiKey: key, model: model,
                             extraHeaders: provider.extraHeaders, simplifiesSchemas: provider.simplifiesSchemas)
    }

    public func model(for role: AgentRole, overrides: Overrides = Overrides()) throws -> any ChatModel {
        OpenAICompatibleModel(endpoint: try endpoint(for: role, overrides: overrides))
    }

    static var providerList: String { ModelProvider.allCases.map(\.rawValue).joined(separator: ", ") }
}
