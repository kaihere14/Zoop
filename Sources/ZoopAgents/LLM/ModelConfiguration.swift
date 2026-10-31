import Foundation
import ZoopShared

/// Known OpenAI-compatible providers. `custom` takes any base URL.
public enum ModelProvider: String, Sendable, CaseIterable {
    case anthropic, gemini, openrouter, groq, openai, ollama, lmstudio, custom

    public var defaultBaseURL: URL? {
        switch self {
        case .anthropic: URL(string: "https://api.anthropic.com/v1/")
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
        case .anthropic: ["ANTHROPIC_API_KEY"]
        case .gemini: ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
        case .openrouter: ["OPENROUTER_API_KEY"]
        case .groq: ["GROQ_API_KEY"]
        case .openai: ["OPENAI_API_KEY"]
        case .ollama, .lmstudio: []
        case .custom: ["ZOOP_CUSTOM_API_KEY"]
        }
    }

    var requiresKey: Bool { ![.ollama, .lmstudio, .custom].contains(self) }

    /// Hosted providers that need an API key; these appear in the app's settings.
    public static let keyed: [ModelProvider] = [.anthropic, .gemini, .openrouter, .groq, .openai]

    /// Claude uses Anthropic's own Messages API; every other provider speaks the OpenAI format.
    public var usesAnthropicAPI: Bool { self == .anthropic }

    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic Claude"
        case .gemini: "Google Gemini"
        case .openrouter: "OpenRouter"
        case .groq: "Groq"
        case .openai: "OpenAI"
        case .ollama: "Ollama"
        case .lmstudio: "LM Studio"
        case .custom: "Custom"
        }
    }

    /// Picked automatically after a key is added, if the provider offers it.
    public var preferredModels: [String] {
        switch self {
        case .anthropic: ["claude-haiku-5-5"]
        case .gemini: ["gemini-3.5-flash", "gemini-2.5-flash"]
        case .openai: ["gpt-5-mini", "gpt-4.1-mini"]
        case .groq: ["llama-3.3-70b-versatile"]
        case .openrouter: ["google/gemini-3.5-flash", "google/gemini-2.5-flash"]
        default: []
        }
    }

    /// Model names as the chat API expects them, without speech, image, embedding and other
    /// non-chat models. Gemini lists names as `models/…`; its OpenAI-compatible API takes the bare name.
    public func chatModels(from names: [String]) -> [String] {
        let excluded = ["tts", "embedding", "image", "audio", "live", "veo", "imagen", "aqa", "whisper", "dall-e", "moderation", "transcribe", "realtime"]
        let cleaned = names.map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
        return Array(Set(cleaned.filter { name in !excluded.contains { name.lowercased().contains($0) } })).sorted()
    }
    var simplifiesSchemas: Bool { self == .gemini }
    var extraHeaders: [String: String] { self == .openrouter ? ["X-Title": "Zoop"] : [:] }
}

/// The agents that use a model. Each can run on a different provider and model.
public enum AgentRole: String, Sendable {
    case executor, chat, planner
}

/// Resolves which provider, model and key an agent uses.
///
/// Sources, highest priority first:
/// 1. explicit overrides (for example CLI flags),
/// 2. environment: `ZOOP_EXECUTOR_PROVIDER`, `ZOOP_EXECUTOR_MODEL`, `ZOOP_EXECUTOR_BASE_URL`
///    (`CHAT` instead of `EXECUTOR` for the chat agent) and provider keys such as `GEMINI_API_KEY`,
/// 3. the Keychain for API keys (added in the app's Settings), then
/// 4. `~/.zoop/config.json` (or `$ZOOP_CONFIG`):
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
    let keys: (any ProviderKeyStore)?

    /// Keys come from the Keychain only when the real config file is loaded. Passing `file`
    /// explicitly (tests, tools) uses no Keychain unless `keys` is given too.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment, file: JSONValue? = nil,
                keys: (any ProviderKeyStore)? = nil) {
        self.environment = environment
        self.file = file ?? Self.loadFile(environment: environment)
        self.keys = keys ?? (file == nil ? KeychainKeyStore() : nil)
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
        if role == .planner, !hasPlannerConfiguration {
            return try endpoint(for: .executor, overrides: overrides, requireModel: requireModel)
        }
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
        // Environment first (handy for one-off runs), then the Keychain, then a plain key left in the file.
        let key = provider.keyVariables.compactMap { environment[$0] }.first { !$0.isEmpty }
            ?? keys?.key(for: provider) ?? settings?["apiKey"]?.stringValue
        if provider.requiresKey, key?.isEmpty ?? true {
            throw ModelError.configuration("no API key for \(provider.rawValue). Set \(provider.keyVariables.joined(separator: " or ")) or providers.\(provider.rawValue).apiKey in \(Self.configPath(environment: environment)).")
        }
        return ModelEndpoint(provider: provider.rawValue, baseURL: baseURL, apiKey: key, model: model,
                             extraHeaders: provider.extraHeaders, simplifiesSchemas: provider.simplifiesSchemas)
    }

    public var hasPlannerConfiguration: Bool {
        file["agents"]?["planner"] != nil || ["ZOOP_PLANNER_PROVIDER", "ZOOP_PLANNER_MODEL", "ZOOP_PLANNER_BASE_URL"].contains { environment[$0] != nil }
    }

    public func model(for role: AgentRole, overrides: Overrides = Overrides()) throws -> any ChatModel {
        let endpoint = try endpoint(for: role, overrides: overrides)
        let transport = TracingTransport(base: URLSessionTransport(), role: role)
        let base: any ChatModel = ModelProvider(rawValue: endpoint.provider)?.usesAnthropicAPI == true
            ? AnthropicModel(endpoint: endpoint, transport: transport)
            : OpenAICompatibleModel(endpoint: endpoint, transport: transport)
        // Every call is logged to ~/Zoop/logs (see ModelTrace); read the log with `zoop-agent trace`.
        return TracingModel(base: base, role: role)
    }

    /// Lists the models an endpoint offers, using the provider's own API format.
    public static func listModels(_ endpoint: ModelEndpoint) async throws -> [String] {
        if ModelProvider(rawValue: endpoint.provider)?.usesAnthropicAPI == true { return try await AnthropicModel.listModels(endpoint) }
        return try await OpenAICompatibleModel.listModels(endpoint)
    }

    static var providerList: String { ModelProvider.allCases.map(\.rawValue).joined(separator: ", ") }
}
