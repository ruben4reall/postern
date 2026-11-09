import CryptoKit
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
    /// Batches of drafts and sends, for every client, while the app runs. Each email a batch sends is logged.
    /// Approved send batches are sealed on disk as they go, so a long one survives a restart and waits for the
    /// user to resume it.
    let board = BatchBoard(
        onChange: { CoreState.shared.changed() },
        record: { client, tool, outcome in
            try? CoreState.shared.activity.append(client: client, tool: tool, outcome: outcome, items: 1)
        },
        store: SealedBatchStore(
            folder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Postern/Batches", isDirectory: true),
            key: { CoreState.batchKey() }
        )
    )
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
        let board = self.board
        Task { await board.restore() }
    }

    /// The key that seals batches: made once, kept in Postern's Keychain group, and held in memory once read, so a
    /// batch running while the Mac is locked keeps its file up to date. Nil while the Keychain cannot be read.
    static func batchKey() -> SymmetricKey? {
        if let known = keyLock.withLock({ knownKey }) { return known }
        let vault = KeychainVault(accessGroup: accessGroup)
        do {
            let key: SymmetricKey
            if let stored = try vault.data(for: .batchKey), stored.count == 32 {
                key = SymmetricKey(data: stored)
            } else {
                key = SymmetricKey(size: .bits256)
                try vault.set(key.withUnsafeBytes { Data($0) }, for: .batchKey)
            }
            keyLock.withLock { knownKey = key }
            return key
        } catch {
            return nil
        }
    }

    private static let keyLock = NSLock()
    nonisolated(unsafe) private static var knownKey: SymmetricKey?

    var policy: Policy { lock.withLock { _policy } }
    var backend: BridgeBackend? { lock.withLock { _backend } }

    /// Why tools are unavailable, or nil when Postern can serve.
    var readiness: PosternError? {
        if backend == nil { retryWhileLocked() }
        guard backend == nil else { return nil }
        return lock.withLock { keychainClosed }
            ? PosternError(.notConfigured, "Postern cannot read its settings while the Mac is locked: macOS keeps the Keychain closed until someone unlocks it. Unlock the Mac, then try again.")
            : PosternError(.notConfigured, "Postern is not set up yet. Open Postern to finish setup.")
    }

    /// The Keychain could not be read at the last reload, as when Postern starts while the Mac is locked.
    private var keychainClosed = false
    private var lastRetry = Date.distantPast

    /// A Postern started while the Mac was locked could not read its settings. It tries again, at most every five
    /// seconds while apps ask, so it serves again as soon as the Mac is unlocked, without a restart.
    private func retryWhileLocked() {
        let due = lock.withLock { () -> Bool in
            guard keychainClosed, Date().timeIntervalSince(lastRetry) > 5 else { return false }
            lastRetry = Date()
            return true
        }
        if due { reload() }
    }

    /// Reads the configuration and policy from the Keychain. Anything missing leaves Postern closed.
    func reload() {
        var backend: BridgeBackend?
        var closed = false
        do {
            if let endpoint = try vault.read(.bridgeEndpoint, as: BridgeEndpoint.self),
               let pin = try vault.read(.certificatePin, as: CertificatePin.self),
               let credentials = try vault.read(.bridgeCredentials, as: BridgeCredentials.self) {
                backend = BridgeBackend(endpoint: endpoint, pin: pin, credentials: credentials)
            }
        } catch VaultError.keychain {
            closed = true
        } catch {
            backend = nil
        }
        let previous = lock.withLock { () -> BridgeBackend? in
            let old = _backend
            _backend = backend
            keychainClosed = closed
            return old
        }
        if let previous { Task { await previous.shutdown() } }
        reloadPolicy()
        // Batches sealed before a restart open with a key from the Keychain: once it can be read, bring them back.
        if !closed {
            let board = self.board
            Task { await board.restore() }
        }
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

/// Recent send times in the Keychain, so a client cannot reset the limits by touching a file. A copy stays in
/// memory: when the Keychain cannot be read, such as while the screen is locked, the limits keep counting what was
/// sent instead of starting from zero, and nothing is written over the stored list.
final class KeychainLedger: SendLedger, @unchecked Sendable {
    private let vault: any SecretStore
    private let lock = NSLock()
    private var memory: [Date] = []

    init(vault: any SecretStore) {
        self.vault = vault
        memory = ((try? vault.read(.sendLedger, as: [Date].self)) ?? nil) ?? []
    }

    func recentSends() -> [Date] {
        lock.withLock { current(Date()).dates }
    }

    func reserve(at date: Date, allowed: ([Date]) -> Bool) -> Bool {
        lock.withLock {
            let (dates, readable) = current(date)
            guard allowed(dates) else { return false }
            memory = dates + [date]
            if readable { try? vault.write(memory, for: .sendLedger) }
            return true
        }
    }

    func release(at date: Date) {
        lock.withLock {
            let (dates, readable) = current(date)
            guard let index = dates.firstIndex(where: { abs($0.timeIntervalSince(date)) < 0.001 }) else { return }
            var kept = dates
            kept.remove(at: index)
            memory = kept
            if readable { try? vault.write(memory, for: .sendLedger) }
        }
    }

    /// The sends of the last day: the stored list merged with the copy in memory, each send once.
    private func current(_ now: Date) -> (dates: [Date], readable: Bool) {
        var readable = true
        var all = memory
        do {
            all += try vault.read(.sendLedger, as: [Date].self) ?? []
        } catch {
            readable = false
        }
        var merged: [Date] = []
        for date in all.filter({ now.timeIntervalSince($0) < 86_400 }).sorted() {
            if let previous = merged.last, date.timeIntervalSince(previous) < 0.001 { continue }
            merged.append(date)
        }
        memory = merged
        return (merged, readable)
    }
}

/// Touch ID or an Apple Watch; the Mac password only when the user allowed it.
struct PolicyAuthenticator: Authenticating {
    func confirm(reason: String) async -> Bool {
        await Authenticator.confirm(reason, allowPassword: CoreState.shared.policy.allowPasswordFallback) == .confirmed
    }
}
