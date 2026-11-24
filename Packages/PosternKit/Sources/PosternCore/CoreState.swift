import Foundation
import MCP
import PosternApproval
import PosternAudit
import PosternBridge
import PosternModel
import PosternPolicy
import PosternServer
import PosternVault
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// What differs from one system to the next. Everything else about the core is the same on macOS, Linux and Windows.
public struct CorePlatform: Sendable {
    /// Where the Bridge password, the certificate pin, the policy and the counters live.
    public var vault: any SecretStore
    /// Reads hostile messages outside the core's process.
    public var reader: any MessageReading
    /// Shows approval panels and returns the person's choice.
    public var presenter: any ApprovalPresenter
    /// Proves that the person at the computer is the user, after they chose Send or Delete.
    public var authenticator: any Authenticating
    /// The activity log and the sealed batches.
    public var supportFolder: URL
    /// Postern's version, as clients see it.
    public var version: String
    /// Why Postern cannot read its settings while the store is closed, such as a locked Mac or keyring.
    public var storeClosedMessage: String
    /// What to tell a client while Postern is not set up.
    public var notConfiguredMessage: String

    public init(
        vault: any SecretStore, reader: any MessageReading, presenter: any ApprovalPresenter,
        authenticator: any Authenticating, supportFolder: URL, version: String,
        storeClosedMessage: String = "Postern cannot read its settings right now: the system keeps its secret store closed. Unlock your computer or your keyring, then try again.",
        notConfiguredMessage: String = "Postern is not set up yet. Open Postern to finish setup."
    ) {
        self.vault = vault
        self.reader = reader
        self.presenter = presenter
        self.authenticator = authenticator
        self.supportFolder = supportFolder
        self.version = version
        self.storeClosedMessage = storeClosedMessage
        self.notConfiguredMessage = notConfiguredMessage
    }
}

/// An app connected to Postern, as the core lists it.
public protocol ClientConnection: AnyObject, Sendable {
    var clientName: String { get }
}

/// Everything the sessions need, readable from any thread. Only Postern's own interface changes the policy.
public final class CoreState: @unchecked Sendable {
    public static let activityRetention: TimeInterval = 90 * 24 * 3600

    public let platform: CorePlatform
    public let vault: any SecretStore
    public let activity: ActivityLog
    public let ledger: VaultLedger
    /// One desk for the whole core: one approval panel at a time, whatever the client.
    public let desk: ApprovalDesk
    /// Batches of drafts and sends, for every client, while the core runs. Each email a batch sends is logged.
    /// Approved send batches are sealed on disk as they go, so a long one survives a restart and waits for the
    /// user to resume it.
    public let board: BatchBoard
    /// When Proton itself said stop, so the interface can show the account's real limit.
    public let protonLimits: ProtonLimitLog

    private let lock = NSLock()
    private var _policy: Policy = .initial
    private var _backend: BridgeBackend?
    private var sessions: [ObjectIdentifier: (session: Session, connection: any ClientConnection)] = [:]
    /// The store could not be read at the last reload, as when the core starts while the computer is locked.
    private var storeClosed = false
    private var lastRetry = Date.distantPast
    private var knownBatchKey: SymmetricKey?
    private let changeHandlers = ChangeHandlers()

    public init(platform: CorePlatform) {
        self.platform = platform
        let vault = platform.vault
        self.vault = vault
        ledger = VaultLedger(vault: vault)
        desk = ApprovalDesk(presenter: platform.presenter, authenticator: platform.authenticator)
        activity = ActivityLog(
            fileURL: platform.supportFolder.appendingPathComponent("activity.jsonl"), head: VaultHeadStore(vault: vault)
        )
        protonLimits = ProtonLimitLog(vault: vault)
        let owner = WeakCore()
        board = BatchBoard(
            onChange: { owner.core?.changed() },
            record: { client, tool, outcome in
                try? owner.core?.activity.append(client: client, tool: tool, outcome: outcome, items: 1)
                if outcome == "proton_limit", let core = owner.core { core.protonLimits.record(sentToday: core.ledger.recentSends().count) }
            },
            store: SealedBatchStore(
                folder: platform.supportFolder.appendingPathComponent("Batches", isDirectory: true),
                key: { owner.core?.batchKey() },
                index: VaultBatchIndex(vault: vault)
            )
        )
        owner.core = self
        DraftThreads.shared.persist(
            load: { try? vault.read(.draftThreads, as: [String: ThreadReference].self) },
            save: { try? vault.write($0, for: .draftThreads) }
        )
        try? activity.prune(olderThan: Date().addingTimeInterval(-Self.activityRetention))
        let board = self.board
        Task { await board.restore() }
    }

    /// Called whenever the policy, the configuration or the connected apps change. Each platform's interface
    /// registers its own handler; they run on whatever thread the change happened.
    public func onChange(_ handler: @escaping @Sendable () -> Void) {
        changeHandlers.add(handler)
    }

    /// The key that seals batches: made once, kept in the secret store, and held in memory once read, so a batch
    /// running while the computer is locked keeps its file up to date. Nil while the store cannot be read.
    public func batchKey() -> SymmetricKey? {
        if let known = lock.withLock({ knownBatchKey }) { return known }
        do {
            let key: SymmetricKey
            if let stored = try vault.data(for: .batchKey), stored.count == 32 {
                key = SymmetricKey(data: stored)
            } else {
                key = SymmetricKey(size: .bits256)
                try vault.set(key.withUnsafeBytes { Data($0) }, for: .batchKey)
            }
            lock.withLock { knownBatchKey = key }
            return key
        } catch {
            return nil
        }
    }

    public var policy: Policy { lock.withLock { _policy } }
    public var backend: BridgeBackend? { lock.withLock { _backend } }
    public var isConfigured: Bool { backend != nil }

    /// Why tools are unavailable, or nil when Postern can serve.
    public var readiness: PosternError? {
        if backend == nil { retryWhileClosed() }
        guard backend == nil else { return nil }
        return lock.withLock { storeClosed }
            ? PosternError(.notConfigured, platform.storeClosedMessage)
            : PosternError(.notConfigured, platform.notConfiguredMessage)
    }

    /// A core started while the store was closed could not read its settings. It tries again, at most every five
    /// seconds while apps ask, so it serves again as soon as the store opens, without a restart.
    private func retryWhileClosed() {
        let due = lock.withLock { () -> Bool in
            guard storeClosed, Date().timeIntervalSince(lastRetry) > 5 else { return false }
            lastRetry = Date()
            return true
        }
        if due { reload() }
    }

    /// Reads the configuration and policy from the store. Anything missing leaves Postern closed.
    public func reload() {
        var backend: BridgeBackend?
        var closed = false
        do {
            if let endpoint = try vault.read(.bridgeEndpoint, as: BridgeEndpoint.self),
               let pin = try vault.read(.certificatePin, as: CertificatePin.self),
               let credentials = try vault.read(.bridgeCredentials, as: BridgeCredentials.self) {
                backend = BridgeBackend(endpoint: endpoint, pin: pin, credentials: credentials, reader: platform.reader)
            }
        } catch VaultError.keychain {
            closed = true
        } catch {
            backend = nil
        }
        let previous = lock.withLock { () -> BridgeBackend? in
            let old = _backend
            _backend = backend
            storeClosed = closed
            return old
        }
        if let previous { Task { await previous.shutdown() } }
        reloadPolicy()
        // Batches sealed before a restart open with a key from the store: once it can be read, bring them back.
        if !closed {
            let board = self.board
            Task { await board.restore() }
        }
    }

    /// Re-reads the policy only, keeping the Bridge session, and pushes the new tool list to every client.
    public func reloadPolicy() {
        let policy = PolicyStore(vault: vault).load()
        lock.withLock { _policy = policy }
        let current = lock.withLock { sessions.values.map(\.session) }
        for session in current { Task { await session.toolsChanged() } }
        changed()
    }

    /// Saves a new policy. The caller has already asked for proof when the change adds power.
    public func save(_ policy: Policy) throws {
        try PolicyStore(vault: vault).save(policy)
        reloadPolicy()
    }

    /// Opens one MCP session over a transport: the relay of one app. Call `close` when the app goes away.
    public func openSession(transport: any Transport, connection: any ClientConnection) -> CoreSession {
        let key = ObjectIdentifier(connection)
        let session = Session(
            transport: transport, backend: LiveBackend { [weak self] in self?.backend }, version: platform.version,
            policy: { [weak self] in self?.policy ?? .initial },
            readiness: { [weak self] in self?.readiness ?? PosternError(.notConfigured, "Postern is shutting down.") },
            onCall: { [weak self, weak connection] report in
                self?.record(report, client: connection?.clientName ?? "MCP client")
            },
            desk: desk, ledger: ledger,
            clientName: { [weak connection] in connection?.clientName ?? "An app" }, board: board
        )
        lock.withLock { sessions[key] = (session, connection) }
        changed()
        Task { try? await session.start() }
        return CoreSession(key: key, session: session, core: self)
    }

    fileprivate func removeSession(for key: ObjectIdentifier) -> Session? {
        let removed = lock.withLock { sessions.removeValue(forKey: key)?.session }
        changed()
        return removed
    }

    public var sessionCount: Int { lock.withLock { sessions.count } }

    /// Names of the apps connected right now, one entry per session.
    public var connectedApps: [String] { lock.withLock { sessions.values.map(\.connection.clientName) }.sorted() }

    public func record(_ report: ToolCallReport, client: String) {
        try? activity.append(client: client, tool: report.tool, outcome: report.outcome, items: report.items)
        if report.outcome == "proton_limit" { protonLimits.record(sentToday: ledger.recentSends().count) }
        changed()
    }

    /// Tells every interface that something it shows has changed.
    public func changed() {
        changeHandlers.run()
    }

    /// Resumes a batch the user approved before a restart, after they prove it is them again.
    @discardableResult
    public func resume(batch id: String) async -> Bool {
        await BatchResumer(
            board: board, desk: desk, backend: LiveBackend { [weak self] in self?.backend }, ledger: ledger,
            policy: { [weak self] in self?.policy ?? .initial }
        ).resume(id)
    }
}

/// One app's session, until its relay goes away.
public final class CoreSession: Sendable {
    let key: ObjectIdentifier
    public let session: Session
    private weak let core: CoreState?

    init(key: ObjectIdentifier, session: Session, core: CoreState) {
        self.key = key
        self.session = session
        self.core = core
    }

    public func close() {
        guard let removed = core?.removeSession(for: key) else { return }
        Task { await removed.stop() }
    }
}

private final class WeakCore: @unchecked Sendable {
    weak var core: CoreState?
}

private final class ChangeHandlers: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [@Sendable () -> Void] = []

    func add(_ handler: @escaping @Sendable () -> Void) { lock.withLock { handlers.append(handler) } }
    func run() { for handler in lock.withLock({ handlers }) { handler() } }
}

/// Keeps the activity log's last hash in the secret store, out of reach of whoever can edit the log file.
public struct VaultHeadStore: HeadStore {
    let vault: any SecretStore

    public init(vault: any SecretStore) { self.vault = vault }
    public func load() -> String? { try? vault.read(.activityHead, as: String.self) }
    public func save(_ hash: String) { try? vault.write(hash, for: .activityHead) }
}

/// Recent send times in the secret store, so a client cannot reset the limits by touching a file. A copy stays in
/// memory: when the store cannot be read, such as while the screen is locked, the limits keep counting what was
/// sent instead of starting from zero, and nothing is written over the stored list.
public final class VaultLedger: SendLedger, @unchecked Sendable {
    private let vault: any SecretStore
    private let lock = NSLock()
    private var memory: [Date] = []

    public init(vault: any SecretStore) {
        self.vault = vault
        memory = ((try? vault.read(.sendLedger, as: [Date].self)) ?? nil) ?? []
    }

    public func recentSends() -> [Date] {
        lock.withLock { current(Date()).dates }
    }

    public func reserve(at date: Date, allowed: ([Date]) -> Bool) -> Bool {
        lock.withLock {
            let (dates, readable) = current(date)
            guard allowed(dates) else { return false }
            memory = dates + [date]
            if readable { try? vault.write(memory, for: .sendLedger) }
            return true
        }
    }

    public func release(at date: Date) {
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

/// The digests of the sealed batch files, in the secret store: no other program can change them through Postern.
public struct VaultBatchIndex: BatchIndex {
    let vault: any SecretStore

    public init(vault: any SecretStore) { self.vault = vault }

    public func read() -> [String: String]? {
        do { return try vault.read(.batchIndex, as: [String: String].self) ?? [:] } catch { return nil }
    }

    @discardableResult
    public func write(_ index: [String: String]) -> Bool {
        (try? vault.write(index, for: .batchIndex)) != nil
    }
}

/// The moments Proton refused an email for its own sending limit, with how many emails Postern had sent in the 24
/// hours before: the closest anyone gets to the real limit of a paid account, which Proton does not publish.
public final class ProtonLimitLog: @unchecked Sendable {
    public struct Hit: Codable, Sendable, Equatable {
        public let date: Date
        public let sentInLastDay: Int
    }

    private let vault: any SecretStore
    private let lock = NSLock()

    public init(vault: any SecretStore) { self.vault = vault }

    /// The last ten, newest last.
    public var hits: [Hit] { lock.withLock { ((try? vault.read(.protonLimits, as: [Hit].self)) ?? nil) ?? [] } }

    func record(sentToday: Int, at date: Date = Date()) {
        lock.withLock {
            var hits = ((try? vault.read(.protonLimits, as: [Hit].self)) ?? nil) ?? []
            // One refusal of a batch is enough: the next ones within the hour say the same thing.
            if let last = hits.last, date.timeIntervalSince(last.date) < 3600 { return }
            hits.append(Hit(date: date, sentInLastDay: sentToday))
            try? vault.write(Array(hits.suffix(10)), for: .protonLimits)
        }
    }
}

/// The names apps go by in the activity log and the list of connected apps, from the process that launched the relay.
public enum ClientNames {
    public static func label(forProcess process: String) -> String {
        let name = process.lowercased()
        let known: [(String, String)] = [
            ("claude-code", "Claude Code"), ("cursor", "Cursor"), ("windsurf", "Windsurf"), ("devin", "Devin"),
            ("gemini", "Gemini CLI"), ("kiro", "Kiro"), ("cline", "Cline"), ("zed", "Zed"), ("goose", "Goose"),
            ("lm studio", "LM Studio"), ("lmstudio", "LM Studio"), ("warp", "Warp"), ("opencode", "opencode"),
            ("codex", "Codex"), ("code", "VS Code"),
        ]
        if name == "claude" || name == "claude.exe" { return "Claude Code" }
        if name.contains("claude") { return "Claude Desktop" }
        for (needle, label) in known where name.contains(needle) { return label }
        return String(process.prefix(40))
    }
}
