// Where passwords, passphrases and tokens live: the Mac's Keychain, never jobs.json (owner decision 11).
// The core talks to `SecretStore`; the app uses `KeychainSecrets`, the tests `MemorySecrets`.
import Foundation
import Security

public protocol SecretStore: Sendable {
    func secret(for account: String) throws -> String?
    func set(_ secret: String, for account: String) throws
    func remove(for account: String) throws
    /// every account with a secret, for the Accounts settings
    func accounts() throws -> [String]
}

public enum SecretAccount {
    /// The secret for a destination (an SSH password or key passphrase, a share password, a cloud token).
    public static func destination(_ id: Destination.ID) -> String { "destination:\(id.uuidString)" }
    public static func destinationId(_ account: String) -> Destination.ID? {
        account.hasPrefix("destination:") ? UUID(uuidString: String(account.dropFirst("destination:".count))) : nil
    }
}

/// Generic passwords under one Keychain service, "Data Syncer".
public final class KeychainSecrets: SecretStore {
    public let service: String
    public init(service: String = "Data Syncer") { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func secret(for account: String) throws -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainSecrets.error(status, "read") }
        return String(decoding: data, as: UTF8.self)
    }

    public func set(_ secret: String, for account: String) throws {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainSecrets.error(status, "save") }
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrLabel as String] = "Data Syncer — \(account)"
        let added = SecItemAdd(q as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainSecrets.error(added, "save") }
    }

    public func remove(for account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainSecrets.error(status, "remove") }
    }

    public func accounts() throws -> [String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = out as? [[String: Any]] else { throw KeychainSecrets.error(status, "list") }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    private static func error(_ status: OSStatus, _ what: String) -> DSError {
        let why = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return DSError("The Keychain would not let Data Syncer \(what) the sign-in: \(why)")
    }
}

/// For tests and previews: secrets kept in memory only.
public final class MemorySecrets: SecretStore, @unchecked Sendable {
    private var store: [String: String]
    private let lock = NSLock()
    public init(_ initial: [String: String] = [:]) { store = initial }
    public func secret(for account: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return store[account] }
    public func set(_ secret: String, for account: String) throws { lock.lock(); defer { lock.unlock() }; store[account] = secret }
    public func remove(for account: String) throws { lock.lock(); defer { lock.unlock() }; store.removeValue(forKey: account) }
    public func accounts() throws -> [String] { lock.lock(); defer { lock.unlock() }; return store.keys.sorted() }
}
