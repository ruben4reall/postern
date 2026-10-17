import Foundation
import PosternApproval
import PosternAudit
import PosternBridge
import PosternModel
import PosternPolicy
import PosternServer
import PosternVault

/// Everything the XPC side needs, readable from any thread. The app's interface is the only writer.
final class CoreState: @unchecked Sendable {
    static let shared = CoreState()
    static let accessGroup = "D8HG34L8XK.ch.rubencatalao.postern"
    static let activityRetention: TimeInterval = 90 * 24 * 3600

    let vault: any SecretStore
    let activity: ActivityLog
    let ledger: KeychainLedger
    /// One desk for the whole app: one approval panel at a time, whatever the client.
    let desk = ApprovalDesk(presenter: PanelPresenter(), authenticator: PolicyAuthenticator())
    private let lock = NSLock()
    private var _policy: Policy = .initial
    private var _backend: BridgeBackend?
    private var sessions: [ObjectIdentifier: (session: Session, connection: RelayConnection)] = [:]
    /// Called on the main queue whenever the policy, the configuration or the connected apps change.
    var onChange: (@Sendable () -> Void)?

    private init() {
        let vault = KeychainVault(accessGroup: CoreState.accessGroup)
        self.vault = vault
        ledger = KeychainLedger(vault: vault)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        activity = ActivityLog(
            fileURL: support.appendingPathComponent("Postern/activity.jsonl"), head: VaultHeadStore(vault: vault)
        )
        try? activity.prune(olderThan: Date().addingTimeInterval(-Self.activityRetention))
    }

    var policy: Policy { lock.withLock { _policy } }
    var backend: BridgeBackend? { lock.withLock { _backend } }

    /// Why tools are unavailable, or nil when Postern can serve.
    var readiness: PosternError? {
        backend == nil ? PosternError(.notConfigured, "Postern is not set up yet. Open Postern to finish setup.") : nil
    }

    /// Reads the configuration and policy from the Keychain. Anything missing leaves Postern closed.
    func reload() {
        var backend: BridgeBackend?
        if let endpoint = try? vault.read(.bridgeEndpoint, as: BridgeEndpoint.self),
           let pin = try? vault.read(.certificatePin, as: CertificatePin.self),
           let credentials = try? vault.read(.bridgeCredentials, as: BridgeCredentials.self) {
            backend = BridgeBackend(endpoint: endpoint, pin: pin, credentials: credentials)
        }
        let previous = lock.withLock { () -> BridgeBackend? in
            let old = _backend
            _backend = backend
            return old
        }
        if let previous { Task { await previous.shutdown() } }
        reloadPolicy()
    }

    /// Re-reads the policy only, keeping the Bridge session, and pushes the new tool list to every client.
    func reloadPolicy() {
        let policy = PolicyStore(vault: vault).load()
        lock.withLock { _policy = policy }
        let current = lock.withLock { sessions.values.map(\.session) }
        for session in current { Task { await session.toolsChanged() } }
        changed()
    }

    func add(_ session: Session, connection: RelayConnection, for key: ObjectIdentifier) {
        lock.withLock { sessions[key] = (session, connection) }
        changed()
    }

    func removeSession(for key: ObjectIdentifier) -> Session? {
        let removed = lock.withLock { sessions.removeValue(forKey: key)?.session }
        changed()
        return removed
    }

    var sessionCount: Int { lock.withLock { sessions.count } }

    /// Names of the apps connected right now, one entry per session.
    var connectedApps: [String] { lock.withLock { sessions.values.map(\.connection.clientName) }.sorted() }

    func record(_ report: ToolCallReport, client: String) {
        try? activity.append(client: client, tool: report.tool, outcome: report.outcome, items: report.items)
        changed()
    }

    /// Tells the interface that something it shows has changed.
    func changed() {
        guard let onChange else { return }
        DispatchQueue.main.async { onChange() }
    }
}

/// Keeps the activity log's last hash in the Keychain, out of reach of whoever can edit the log file.
struct VaultHeadStore: HeadStore {
    let vault: any SecretStore

    func load() -> String? { try? vault.read(.activityHead, as: String.self) }
    func save(_ hash: String) { try? vault.write(hash, for: .activityHead) }
}

/// Recent send times in the Keychain, so a client cannot reset the limits by touching a file.
final class KeychainLedger: SendLedger, @unchecked Sendable {
    private let vault: any SecretStore
    private let lock = NSLock()

    init(vault: any SecretStore) {
        self.vault = vault
    }

    func recentSends() -> [Date] {
        lock.withLock { ((try? vault.read(.sendLedger, as: [Date].self)) ?? []).filter { Date().timeIntervalSince($0) < 86_400 } }
    }

    func recordSend(at date: Date) {
        lock.withLock {
            let kept = ((try? vault.read(.sendLedger, as: [Date].self)) ?? []).filter { date.timeIntervalSince($0) < 86_400 }
            try? vault.write(kept + [date], for: .sendLedger)
        }
    }
}

/// Touch ID or an Apple Watch; the Mac password only when the user allowed it.
struct PolicyAuthenticator: Authenticating {
    func confirm(reason: String) async -> Bool {
        await Authenticator.confirm(reason, allowPassword: CoreState.shared.policy.allowPasswordFallback) == .confirmed
    }
}
