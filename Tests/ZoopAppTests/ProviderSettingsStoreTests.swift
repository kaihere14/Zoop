import Foundation
import Testing
import ZoopAgents
import ZoopShared
@testable import ZoopApp

@MainActor @Suite struct ProviderSettingsStoreTests {
    func fixture(_ file: JSONValue = [:]) throws -> (ProviderSettingsStore, InMemoryKeyStore, String) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("zoop-cfg-\(UUID()).json").path
        try ZoopConfigFile(file).save(path: path)
        let keys = InMemoryKeyStore()
        let store = ProviderSettingsStore(keys: keys, configPath: path) { _, key in
            guard key == "good-key" else { throw ModelError.authentication("bad") }
            return ["gemini-2.5-flash", "gemini-3.5-flash"]
        }
        store.reload()
        return (store, keys, path)
    }

    func gemini(_ store: ProviderSettingsStore) -> ProviderSettingsStore.Row { store.rows.first { $0.provider == .gemini }! }

    @Test func aValidKeyIsSavedAndTurnsTheFirstProviderOn() async throws {
        let (store, keys, path) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        await store.saveKey("bad-key", for: .gemini)
        #expect(keys.key(for: .gemini) == nil && gemini(store).error?.contains("rejected") == true)
        await store.saveKey("good-key", for: .gemini)
        #expect(keys.key(for: .gemini) == "good-key" && gemini(store).keySuffix == "-key")
        #expect(store.active == .gemini && gemini(store).model == "gemini-3.5-flash")
        #expect(try ZoopConfigFile.load(path: path).activeProvider == .gemini)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        store.setActive(.gemini, on: false)
        #expect(store.active == nil)
    }

    @Test func plainKeysInTheFileMoveToTheKeychain() throws {
        let (store, keys, path) = try fixture(["providers": ["gemini": ["apiKey": "old-plain-key"]]])
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(keys.key(for: .gemini) == "old-plain-key")
        #expect(try ZoopConfigFile.load(path: path).value["providers"]?["gemini"]?["apiKey"] == nil)
        #expect(store.rows.first { $0.provider == .gemini }?.hasKey == true)
    }
}
