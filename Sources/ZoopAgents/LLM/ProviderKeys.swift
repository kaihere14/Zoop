import Foundation
import Security

/// Where provider API keys live. The app and the CLI read the same store.
public protocol ProviderKeyStore: Sendable {
    func key(for provider: ModelProvider) -> String?
    func setKey(_ key: String?, for provider: ModelProvider) throws
}

public struct KeychainError: Error, Sendable, CustomStringConvertible {
    public let status: OSStatus
    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }
}

/// Keys are stored as generic passwords in the login Keychain: service `com.zoop.provider-keys`,
/// account = provider name. macOS encrypts them and asks before another app may read them.
///
/// Zoop is signed ad hoc, so macOS identifies it by the exact binary. After a rebuild (or from the
/// `zoop-agent` CLI) macOS asks once whether this program may read the key; choose Always Allow.
public struct KeychainKeyStore: ProviderKeyStore {
    public let service: String
    public init(service: String = "com.zoop.provider-keys") { self.service = service }

    private func query(_ provider: ModelProvider) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: provider.rawValue]
    }

    public func key(for provider: ModelProvider) -> String? {
        var search = query(provider)
        search[kSecReturnData] = true
        search[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self)
        return key.isEmpty ? nil : key
    }

    public func setKey(_ key: String?, for provider: ModelProvider) throws {
        let item = query(provider)
        guard let key, !key.isEmpty else {
            let status = SecItemDelete(item as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let data = Data(key.utf8)
        var status = SecItemUpdate(item as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = item
            add[kSecValueData] = data
            add[kSecAttrLabel] = "Zoop: \(provider.displayName) API key"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

/// For tests and previews.
public final class InMemoryKeyStore: ProviderKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [ModelProvider: String]
    public init(_ keys: [ModelProvider: String] = [:]) { self.keys = keys }
    public func key(for provider: ModelProvider) -> String? { lock.withLock { keys[provider] } }
    public func setKey(_ key: String?, for provider: ModelProvider) throws { lock.withLock { keys[provider] = key } }
}
