import Foundation
import Security

public enum SecretStoreError: Error, Equatable, Sendable {
    /// A Keychain call failed with this OSStatus.
    case keychain(Int32)
    case invalidData
}

/// Stores secrets (passwords) by account key. Implementations must not sync off the device.
public protocol SecretStore: Sendable {
    func setSecret(_ secret: String, for account: String) throws
    /// nil when no secret is stored.
    func secret(for account: String) throws -> String?
    /// No error when absent.
    func deleteSecret(for account: String) throws
}

/// Generic-password Keychain items under one service name, accessible only when the device is
/// unlocked, this device only (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), never synchronized.
public struct KeychainStore: SecretStore {
    public let service: String

    public init(service: String = "com.lanjunq.duovnc") {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        // Use the iOS-style data-protection keychain on macOS too, so behavior matches the device.
        q[kSecUseDataProtectionKeychain as String] = true
        return q
    }

    public func setSecret(_ secret: String, for account: String) throws {
        let data = Data(secret.utf8)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
        var add = baseQuery(account)
        for (k, v) in attrs { add[k] = v }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw SecretStoreError.keychain(addStatus) }
    }

    public func secret(for account: String) throws -> String? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
        guard let data = result as? Data, let s = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.invalidData
        }
        return s
    }

    public func deleteSecret(for account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
    }
}

/// In-memory `SecretStore` for tests and demo mode. Thread-safe.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]

    public init() {}

    public func setSecret(_ secret: String, for account: String) throws {
        lock.withLock { items[account] = secret }
    }

    public func secret(for account: String) throws -> String? {
        lock.withLock { items[account] }
    }

    public func deleteSecret(for account: String) throws {
        lock.withLock { _ = items.removeValue(forKey: account) }
    }

    /// Number of stored secrets (for tests).
    public var count: Int { lock.withLock { items.count } }
}
