import Foundation
#if canImport(Security)
import Security
#endif

/// Secure storage for API keys, keyed by name. The app uses the Keychain; tests use memory.
public protocol SecretStore: Sendable {
    func secret(for key: String) -> String?
    func setSecret(_ value: String?, for key: String) throws
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]

    public init() {}

    public func secret(for key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return items[key]
    }

    public func setSecret(_ value: String?, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[key] = value
    }
}

#if canImport(Security)
/// Keychain-backed `SecretStore`. Items are readable only while the device is unlocked and never leave
/// this device (no iCloud Keychain sync, no backup restore to another phone).
public struct KeychainSecretStore: SecretStore {
    public struct KeychainError: Error, LocalizedError {
        public let status: OSStatus
        public var errorDescription: String? { "Could not save the key to the Keychain (error \(status))." }
    }

    private let service: String

    public init(service: String = "dev.kekaflow.applebot.models") {
        self.service = service
    }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    public func secret(for key: String) -> String? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ value: String?, for key: String) throws {
        let deleteStatus = SecItemDelete(query(key) as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainError(status: deleteStatus)
        }
        guard let value, !value.isEmpty else { return }
        var attributes = query(key)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}
#endif
