import Foundation
import PosternVault
#if os(Linux)
import CPosternSecret
#elseif os(Windows)
import WinSDK
#endif

/// The secret store of this system, where the Bridge password, the certificate pin, the policy and the counters
/// live. Postern never falls back to a plain file: without the system's store, it stays closed.
public enum SystemVault {
    public static func make() -> any SecretStore {
        #if os(Linux)
        return SecretServiceVault()
        #elseif os(Windows)
        return DPAPIVault(folder: PosternPaths.localAppData.appendingPathComponent("Postern/Vault", isDirectory: true))
        #else
        // macOS builds of these programs are for development only; the Mac app keeps its secrets in the Keychain.
        return MemoryVault()
        #endif
    }

    /// What to tell an app while the store cannot be read.
    public static var closedMessage: String {
        #if os(Linux)
        "Postern cannot read its settings: the desktop's keyring is locked or missing. Unlock it (signing in to your desktop session usually does), then try again."
        #elseif os(Windows)
        "Postern cannot read its settings right now. Sign in to Windows again, then try again."
        #else
        "Postern cannot read its settings right now."
        #endif
    }
}

#if os(Linux)
/// The Secret Service (GNOME Keyring, KWallet, KeePassXC), one item per vault key, the value in base64. Any program
/// of the same user can ask the Secret Service for these items: docs/threat-model.md says what that means.
public struct SecretServiceVault: SecretStore {
    public init() {}

    public func data(for key: VaultKey) throws -> Data? {
        var value: UnsafeMutablePointer<CChar>?
        var found: Int32 = 0
        var problem: UnsafeMutablePointer<CChar>?
        guard postern_secret_lookup(key.rawValue, &value, &found, &problem) == 0 else {
            postern_secret_free(problem)
            throw VaultError.keychain(-1)
        }
        defer { postern_secret_free(value) }
        guard found != 0, let value else { return nil }
        guard let data = Data(base64Encoded: String(cString: value)) else { throw VaultError.corrupted(key) }
        return data
    }

    public func set(_ data: Data, for key: VaultKey) throws {
        var problem: UnsafeMutablePointer<CChar>?
        guard postern_secret_store(key.rawValue, data.base64EncodedString(), &problem) == 0 else {
            postern_secret_free(problem)
            throw VaultError.keychain(-1)
        }
    }

    public func remove(_ key: VaultKey) throws {
        var problem: UnsafeMutablePointer<CChar>?
        guard postern_secret_clear(key.rawValue, &problem) == 0 else {
            postern_secret_free(problem)
            throw VaultError.keychain(-1)
        }
    }
}
#endif

#if os(Windows)
/// One file per vault key, sealed with DPAPI for this Windows user. DPAPI keeps the files useless on another machine
/// or account; programs of the same user can unseal them, which docs/threat-model.md explains.
public struct DPAPIVault: SecretStore {
    let folder: URL
    /// Mixed into every seal, so the files are Postern's and not any DPAPI blob of the user.
    static let entropy = Data("ch.rubencatalao.postern.vault.v1".utf8)

    public init(folder: URL) {
        self.folder = folder
    }

    func url(_ key: VaultKey) -> URL { folder.appendingPathComponent(key.rawValue + ".sealed") }

    public func data(for key: VaultKey) throws -> Data? {
        guard let sealed = try? Data(contentsOf: url(key)) else { return nil }
        guard let plain = Self.unprotect(sealed) else { throw VaultError.keychain(Int32(bitPattern: GetLastError())) }
        return plain
    }

    public func set(_ data: Data, for key: VaultKey) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let sealed = Self.protect(data) else { throw VaultError.keychain(Int32(bitPattern: GetLastError())) }
        try sealed.write(to: url(key), options: .atomic)
    }

    public func remove(_ key: VaultKey) throws {
        try? FileManager.default.removeItem(at: url(key))
    }

    static func protect(_ data: Data) -> Data? {
        transform(data, protecting: true)
    }

    static func unprotect(_ data: Data) -> Data? {
        transform(data, protecting: false)
    }

    private static func transform(_ data: Data, protecting: Bool) -> Data? {
        var input = data
        var salt = entropy
        return input.withUnsafeMutableBytes { inputBytes -> Data? in
            salt.withUnsafeMutableBytes { saltBytes -> Data? in
                var source = DATA_BLOB(cbData: DWORD(inputBytes.count), pbData: inputBytes.bindMemory(to: BYTE.self).baseAddress)
                var extra = DATA_BLOB(cbData: DWORD(saltBytes.count), pbData: saltBytes.bindMemory(to: BYTE.self).baseAddress)
                var output = DATA_BLOB()
                let ok = protecting
                    ? CryptProtectData(&source, nil, &extra, nil, nil, DWORD(CRYPTPROTECT_UI_FORBIDDEN), &output)
                    : CryptUnprotectData(&source, nil, &extra, nil, nil, DWORD(CRYPTPROTECT_UI_FORBIDDEN), &output)
                guard ok, let bytes = output.pbData else { return nil }
                defer { LocalFree(bytes) }
                return Data(bytes: bytes, count: Int(output.cbData))
            }
        }
    }
}
#endif
