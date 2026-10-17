import Foundation
import Security

/// The items Postern keeps. Each is one Keychain entry in Postern's access group.
public enum VaultKey: String, CaseIterable, Sendable {
    case bridgeCredentials = "bridge-credentials"
    case bridgeEndpoint = "bridge-endpoint"
    case certificatePin = "certificate-pin"
    case policy
    /// Hash of the activity log's last line, so edits to the log file are detected.
    case activityHead = "activity-head"
    /// When the last sends happened, for the hourly and daily limits.
    case sendLedger = "send-ledger"
}

public enum VaultError: Error, Equatable, Sendable {
    case keychain(OSStatus)
    case corrupted(VaultKey)
}

/// Storage for everything that grants power: the Bridge password, the pinned certificate, the policy.
///
/// Items live in the data protection Keychain under Postern's access group. Only binaries signed by Postern's
/// team with that entitlement can read or write them; the `security` command line tool does not even list them.
public protocol SecretStore: Sendable {
    func data(for key: VaultKey) throws -> Data?
    func set(_ data: Data, for key: VaultKey) throws
    func remove(_ key: VaultKey) throws
}

extension SecretStore {
    public func read<T: Decodable>(_ key: VaultKey, as type: T.Type) throws -> T? {
        guard let data = try data(for: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw VaultError.corrupted(key)
        }
    }

    public func write<T: Encodable>(_ value: T, for key: VaultKey) throws {
        try set(JSONEncoder().encode(value), for: key)
    }
}

public struct KeychainVault: SecretStore {
    public static let service = "ch.rubencatalao.postern"
    private let accessGroup: String

    public init(accessGroup: String) {
        self.accessGroup = accessGroup
    }

    private func query(_ key: VaultKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrSynchronizable as String: false,
        ]
    }

    public func data(for key: VaultKey) throws -> Data? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
        return result as? Data
    }

    public func set(_ data: Data, for key: VaultKey) throws {
        let update = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw VaultError.keychain(update) }
        var add = query(key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }

    public func remove(_ key: VaultKey) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.keychain(status) }
    }
}

/// For tests and previews only.
public final class MemoryVault: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [VaultKey: Data] = [:]

    public init() {}

    public func data(for key: VaultKey) throws -> Data? { lock.withLock { items[key] } }
    public func set(_ data: Data, for key: VaultKey) throws { lock.withLock { items[key] = data } }
    public func remove(_ key: VaultKey) throws { _ = lock.withLock { items.removeValue(forKey: key) } }
}
