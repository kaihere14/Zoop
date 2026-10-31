import Foundation
import Observation
import ZoopAgents

/// Backs the Providers section of Settings. API keys go to the Keychain; which provider is on and
/// its model go to `~/.zoop/config.json`, which the agents (and the CLI) read for every request.
@MainActor @Observable
final class ProviderSettingsStore {
    struct Row: Identifiable, Equatable {
        let provider: ModelProvider
        var id: ModelProvider { provider }
        var keySuffix: String?
        var model: String?
        var models: [String] = []
        var isEditing = false
        var isChecking = false
        var error: String?
        var hasKey: Bool { keySuffix != nil }
    }

    private(set) var rows: [Row] = []
    private(set) var active: ModelProvider?
    private(set) var notice: String?

    typealias Validator = @Sendable (ModelProvider, String) async throws -> [String]
    @ObservationIgnored private let keys: any ProviderKeyStore
    @ObservationIgnored private let configPath: String
    @ObservationIgnored private let validate: Validator
    @ObservationIgnored private var config = ZoopConfigFile()

    init(keys: any ProviderKeyStore = KeychainKeyStore(), configPath: String = ModelConfiguration.configPath(),
         validate: @escaping Validator = ProviderSettingsStore.listModels) {
        self.keys = keys
        self.configPath = configPath
        self.validate = validate
    }

    /// Lists the provider's models with the key. A wrong key fails here, before it is saved.
    nonisolated static func listModels(_ provider: ModelProvider, key: String) async throws -> [String] {
        guard let baseURL = provider.defaultBaseURL else { return [] }
        let endpoint = ModelEndpoint(provider: provider.rawValue, baseURL: baseURL, apiKey: key, model: "")
        return provider.chatModels(from: try await ModelConfiguration.listModels(endpoint))
    }

    /// Called when Settings opens, not at launch: reading the Keychain can show a macOS prompt.
    func reload() {
        do { config = try ZoopConfigFile.load(path: configPath) } catch {
            notice = "~/.zoop/config.json couldn’t be read, so it won’t be changed. Fix or remove it, then reopen Settings."
            return
        }
        migratePlainKeys()
        active = config.activeProvider
        rows = ModelProvider.keyed.map { provider in
            let old = rows.first { $0.provider == provider }
            return Row(provider: provider, keySuffix: keys.key(for: provider).map(Self.suffix),
                       model: config.model(for: provider), models: old?.models ?? [])
        }
    }

    /// Fills each model menu once. Runs when Settings opens.
    func loadModels() async {
        for row in rows where row.hasKey && row.models.isEmpty {
            guard let key = keys.key(for: row.provider) else { continue }
            let models = (try? await validate(row.provider, key)) ?? []
            update(row.provider) { $0.models = models }
        }
    }

    func beginEditing(_ provider: ModelProvider) { update(provider) { $0.isEditing = true; $0.error = nil } }
    func cancelEditing(_ provider: ModelProvider) { update(provider) { $0.isEditing = false; $0.error = nil } }

    func saveKey(_ key: String, for provider: ModelProvider) async {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { update(provider) { $0.error = "Paste a key first." }; return }
        update(provider) { $0.isChecking = true; $0.error = nil }
        let models: [String]
        do { models = try await validate(provider, key) } catch {
            update(provider) { $0.isChecking = false; $0.error = Self.message(for: error) }
            return
        }
        do { try keys.setKey(key, for: provider) } catch {
            update(provider) { $0.isChecking = false; $0.error = "Couldn’t save to the Keychain: \(error)" }
            return
        }
        let current = row(provider)?.model
        let model = current.flatMap { models.contains($0) ? $0 : nil }
            ?? provider.preferredModels.first(where: models.contains) ?? current ?? models.first
        update(provider) {
            $0.isChecking = false; $0.isEditing = false; $0.keySuffix = Self.suffix(key)
            $0.models = models; $0.model = model
        }
        // The first key added turns that provider on, so Zoop works right away.
        if active == nil, model != nil { setActive(provider, on: true) }
    }

    func setActive(_ provider: ModelProvider, on: Bool) {
        if on {
            guard let row = row(provider), row.hasKey, let model = row.model else {
                update(provider) { $0.error = "Choose a model first." }
                return
            }
            config.activate(provider, model: model)
        } else {
            guard active == provider else { return }
            config.deactivate()
        }
        if write() { active = config.activeProvider }
    }

    func setModel(_ model: String, for provider: ModelProvider) {
        config.setModel(model, for: provider)
        if write() { update(provider) { $0.model = model } }
    }

    private func migratePlainKeys() {
        var stripped = config
        let plain = stripped.takePlainKeys()
        guard !plain.isEmpty else { return }
        do {
            for (provider, key) in plain where keys.key(for: provider) == nil { try keys.setKey(key, for: provider) }
            config = stripped
            if write() { notice = "Moved your API keys from config.json into the Keychain." }
        } catch {
            notice = "API keys are still in config.json because the Keychain refused them: \(error)"
        }
    }

    @discardableResult private func write() -> Bool {
        do { try config.save(path: configPath); return true } catch {
            notice = "Settings couldn’t be saved to ~/.zoop/config.json: \(error.localizedDescription)"
            return false
        }
    }

    private func row(_ provider: ModelProvider) -> Row? { rows.first { $0.provider == provider } }
    private func update(_ provider: ModelProvider, _ change: (inout Row) -> Void) {
        guard let index = rows.firstIndex(where: { $0.provider == provider }) else { return }
        change(&rows[index])
    }

    static func suffix(_ key: String) -> String { String(key.suffix(4)) }

    static func message(for error: Error) -> String {
        switch error {
        case ModelError.authentication: "That key was rejected. Check it and try again."
        case let error as URLError where error.code == .notConnectedToInternet: "No internet connection."
        default: "Couldn’t check the key: \(error)"
        }
    }
}
