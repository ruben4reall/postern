import Foundation
import PosternBridge
import PosternModel
import PosternPolicy
import PosternServer
import PosternVault

/// Everything the XPC side needs, readable from any thread. The app's interface is the only writer.
final class CoreState: @unchecked Sendable {
    static let shared = CoreState()
    static let accessGroup = "D8HG34L8XK.ch.rubencatalao.postern"

    let vault: any SecretStore = KeychainVault(accessGroup: CoreState.accessGroup)
    private let lock = NSLock()
    private var _policy: Policy = .initial
    private var _backend: BridgeBackend?
    private var sessions: [ObjectIdentifier: Session] = [:]

    var policy: Policy { lock.withLock { _policy } }
    var backend: BridgeBackend? { lock.withLock { _backend } }

    /// Why tools are unavailable, or nil when Postern can serve.
    var readiness: PosternError? {
        backend == nil ? PosternError(.notConfigured, "Postern is not set up yet. Open Postern to finish setup.") : nil
    }

    /// Reads the configuration and policy from the Keychain. Anything missing leaves Postern closed.
    func reload() {
        let policy = PolicyStore(vault: vault).load()
        var backend: BridgeBackend?
        if let endpoint = try? vault.read(.bridgeEndpoint, as: BridgeEndpoint.self),
           let pin = try? vault.read(.certificatePin, as: CertificatePin.self),
           let credentials = try? vault.read(.bridgeCredentials, as: BridgeCredentials.self) {
            backend = BridgeBackend(client: BridgeClient(endpoint: endpoint, pin: pin, credentials: credentials))
        }
        let previous = lock.withLock { () -> BridgeBackend? in
            let old = _backend
            _policy = policy
            _backend = backend
            return old
        }
        if let previous { Task { await previous.shutdown() } }
        notifySessions()
    }

    func add(_ session: Session, for key: ObjectIdentifier) { lock.withLock { sessions[key] = session } }

    func removeSession(for key: ObjectIdentifier) -> Session? { lock.withLock { sessions.removeValue(forKey: key) } }

    var sessionCount: Int { lock.withLock { sessions.count } }

    private func notifySessions() {
        let current = lock.withLock { Array(sessions.values) }
        for session in current { Task { await session.toolsChanged() } }
    }
}
