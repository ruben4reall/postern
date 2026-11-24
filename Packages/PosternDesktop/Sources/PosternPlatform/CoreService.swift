import Foundation
import Logging
import MCP
import PosternApproval
import PosternAudit
import PosternBridge
import PosternClients
import PosternCompose
import PosternCore
import PosternModel
import PosternPolicy
import PosternServer
import PosternVault
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import WinSDK
#endif

/// Postern's core on Linux and Windows: one process per user, started by systemd (Linux), at sign-in (Windows) or
/// by the first relay. It holds the secrets, talks to Bridge, runs one MCP session per relay, and serves the app and
/// the command line over the same local channel.
public final class CoreService: @unchecked Sendable {
    public static let version = "2.0.0"
    static let log = Logger(label: "ch.rubencatalao.postern.core")

    public let core: CoreState
    let presenter: RemotePresenter
    let proof: ApprovalProof
    private let listener: LocalListener
    private let lock = NSLock()
    private var interfaces: [ObjectIdentifier: LocalConnection] = [:]
    private var changePending = false

    public init(listener: LocalListener, vault: any SecretStore = SystemVault.make(), reader: (any MessageReading)? = nil) throws {
        self.listener = listener
        let presenter = RemotePresenter()
        self.presenter = presenter
        let proof = ApprovalProof()
        self.proof = proof
        guard let parser = reader ?? PosternPaths.program("postern-parser").map({ JailedReader(program: $0) }) else {
            throw LocalChannelError.unavailable("postern-parser is missing next to postern-core: reinstall Postern.")
        }
        let support = PosternPaths.supportFolder
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        core = CoreState(platform: CorePlatform(
            vault: vault, reader: parser, presenter: presenter, authenticator: proof, supportFolder: support,
            version: Self.version, storeClosedMessage: SystemVault.closedMessage,
            notConfiguredMessage: "Postern is not set up yet. Open Postern (or run `postern setup`) to finish setup."
        ))
        presenter.service = self
        proof.service = self
        PosternFolders.prepare()
        core.onChange { [weak self] in self?.scheduleChanged() }
        core.reload()
    }

    /// Accepts connections until the process ends.
    public func run() {
        while let connection = listener.accept() {
            Thread.detachNewThread { [weak self] in self?.serve(connection) }
        }
    }

    private func serve(_ connection: LocalConnection) {
        guard let first = connection.readLine(), let hello = try? ControlWire.decoder.decode(ControlWire.Hello.self, from: first) else {
            connection.close()
            return
        }
        switch hello.postern {
        case .relay: serveRelay(connection, client: ClientNames.label(forProcess: hello.client ?? "MCP client"))
        case .control: serveInterface(connection)
        }
    }

    // MARK: Relays

    private func serveRelay(_ connection: LocalConnection, client: String) {
        let transport = XPCTransport { data in connection.write(data) }
        let session = core.openSession(transport: transport, connection: RelayClient(name: client))
        while let line = connection.readLine() {
            guard !line.isEmpty else { continue }
            transport.deliver(line)
        }
        transport.finish()
        session.close()
        connection.close()
    }

    // MARK: Interfaces

    private func serveInterface(_ connection: LocalConnection) {
        let key = ObjectIdentifier(connection)
        lock.withLock { interfaces[key] = connection }
        // Whatever waits for the user is shown at once to a window that just opened.
        for approval in presenter.waiting() { send(connection, event: "approval", data: .init(approval: approval)) }
        while let line = connection.readLine() {
            guard let request = try? ControlWire.decoder.decode(ControlWire.Request.self, from: line) else { continue }
            Task { [weak self] in
                guard let self else { return }
                let answer: ControlWire.Message
                do {
                    answer = ControlWire.Message(id: request.id, result: try await self.handle(request))
                } catch let failure as ControlWire.Failure {
                    answer = ControlWire.Message(id: request.id, error: failure)
                } catch let error as PosternError {
                    answer = ControlWire.Message(id: request.id, error: .init(error.code.rawValue, error.message))
                } catch {
                    answer = ControlWire.Message(id: request.id, error: .init("failed", String(describing: error)))
                }
                self.write(connection, answer)
            }
        }
        lock.withLock { _ = interfaces.removeValue(forKey: key) }
        connection.close()
    }

    var hasInterface: Bool { lock.withLock { !interfaces.isEmpty } }

    func broadcast(event: String, data: ControlWire.Result? = nil) {
        for connection in lock.withLock({ Array(interfaces.values) }) { send(connection, event: event, data: data) }
    }

    private func send(_ connection: LocalConnection, event: String, data: ControlWire.Result?) {
        write(connection, ControlWire.Message(event: event, data: data))
    }

    private func write(_ connection: LocalConnection, _ message: ControlWire.Message) {
        guard let data = try? ControlWire.encoder.encode(message) else { return }
        connection.write(data)
    }

    /// Changes come in bursts (a batch sends, the policy reloads): the interfaces hear of them at most ten times a second.
    private func scheduleChanged() {
        let first = lock.withLock { () -> Bool in
            defer { changePending = true }
            return !changePending
        }
        guard first else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.changePending = false }
            self.broadcast(event: "changed")
        }
    }

    // MARK: Requests

    func handle(_ request: ControlWire.Request) async throws -> ControlWire.Result {
        let params = request.params ?? ControlWire.Params()
        switch request.method {
        case "status":
            return .init(status: await status())
        case "tools":
            let policy = core.policy
            return .init(tools: ToolID.switchable.map { tool in
                let text = ToolText.for(tool)
                return ControlWire.ToolInfo(id: tool.rawValue, tier: tool.tier.rawValue, title: text.title, summary: text.allows,
                                            risk: text.risk, enabled: policy.enabledTools.contains(tool))
            })
        case "policy.update":
            guard let policy = params.policy else { throw ControlWire.Failure("invalid", "policy is missing.") }
            try await update(policy, reason: "change what your apps may do")
            return .init(status: await status())
        case "pause":
            var policy = core.policy
            policy.paused = params.paused ?? true
            try await update(policy, reason: "resume Postern")
            return .init(status: await status())
        case "setup.detect":
            return .init(detection: try await detect(imap: params.imapPort ?? 1143, smtp: params.smtpPort ?? 1025))
        case "setup.connect":
            try await connect(params)
            return .init(status: await status())
        case "setup.forget":
            for key in [VaultKey.bridgeCredentials, .bridgeEndpoint, .certificatePin] { try? core.vault.remove(key) }
            core.reload()
            return .init(status: await status())
        case "mailboxes":
            guard let backend = core.backend else { throw PosternError(.notConfigured, "Postern is not set up yet.") }
            let policy = core.policy
            let names = try await backend.mailboxNames()
            return .init(mailboxes: names.map { name in
                ControlWire.MailboxRow(name: name, kind: BridgeBackend.kind(of: name).rawValue, hidden: policy.hiddenMailboxes.contains(name))
            })
        case "apps":
            return .init(apps: apps())
        case "apps.connect":
            guard let id = params.app, let target = AppTarget.all().first(where: { $0.kind.rawValue == id }) else {
                throw ControlWire.Failure("invalid", "There is no app named \(params.app ?? "").")
            }
            guard let relay = PosternPaths.program("postern-mcp")?.path else {
                throw ControlWire.Failure("missing", "postern-mcp is missing next to postern-core: reinstall Postern.")
            }
            try target.connect(relay: relay)
            return .init(apps: apps())
        case "activity":
            let records = (try? core.activity.records(limit: min(max(params.limit ?? 200, 1), 2000))) ?? []
            return .init(activity: records.map {
                ControlWire.ActivityRow(date: $0.date, client: $0.client, tool: $0.tool, outcome: $0.outcome, items: $0.items)
            })
        case "batches":
            return .init(batches: await batches())
        case "batches.cancel":
            guard let id = params.id else { throw ControlWire.Failure("invalid", "id is missing.") }
            _ = await core.board.cancel(id)
            return .init(batches: await batches())
        case "batches.resume":
            guard let id = params.id else { throw ControlWire.Failure("invalid", "id is missing.") }
            await core.resume(batch: id)
            return .init(batches: await batches())
        case "approval.decide":
            guard let id = params.id, let decision = params.decision else { throw ControlWire.Failure("invalid", "id and decision are required.") }
            guard presenter.decide(id, decision: decision, reason: params.reason, chosen: params.chosen) else {
                throw ControlWire.Failure("gone", "This approval is no longer waiting.")
            }
            return .init(text: "ok")
        case "auth.signed":
            guard let id = params.id, let signature = params.signature.flatMap({ Data(base64Encoded: $0) }) else {
                throw ControlWire.Failure("invalid", "id and signature are required.")
            }
            proof.signed(id, signature: signature)
            return .init(text: "ok")
        case "hello.register":
            guard let key = params.publicKey.flatMap({ Data(base64Encoded: $0) }) else {
                throw ControlWire.Failure("invalid", "publicKey is missing.")
            }
            try proof.register(key, vault: core.vault)
            return .init(status: await status())
        default:
            throw ControlWire.Failure("unknown", "Postern has no method \(request.method).")
        }
    }

    /// Saves a new policy, after the system's proof when it gives apps more than they had.
    func update(_ requested: Policy, reason: String) async throws {
        var policy = requested
        let limits = Policy.clampedLimits(perHour: policy.sendsPerHour, perDay: policy.sendsPerDay)
        policy.sendsPerHour = limits.perHour
        policy.sendsPerDay = limits.perDay
        // Linux and Windows have no password fallback to allow: the system's own prompt decides.
        policy.allowPasswordFallback = false
        let old = core.policy
        if policy.addsPower(over: old) {
            guard await proof.confirmPolicyChange(reason: reason) else {
                throw ControlWire.Failure("not_authenticated", "The change was not confirmed, so nothing changed.")
            }
        }
        try core.save(policy)
    }

    func status() async -> ControlWire.Status {
        let policy = core.policy
        let sends = core.ledger.recentSends()
        let endpoint = try? core.vault.read(.bridgeEndpoint, as: BridgeEndpoint.self)
        let credentials = try? core.vault.read(.bridgeCredentials, as: BridgeCredentials.self)
        #if os(Linux)
        let ready = PolkitAuthenticator.installed
        let method = "polkit"
        #elseif os(Windows)
        let ready = proof.registeredKey(in: core.vault) != nil
        let method = "windows-hello"
        #else
        let ready = false
        let method = "none"
        #endif
        return ControlWire.Status(
            version: Self.version, processID: Self.processID, system: Self.systemName, configured: core.isConfigured,
            problem: core.readiness?.message, account: credentials?.username,
            imapPort: endpoint?.imap.port, smtpPort: endpoint?.smtp.port, policy: policy,
            sendsLastHour: sends.filter { Date().timeIntervalSince($0) < 3600 }.count, sendsLastDay: sends.count,
            connectedApps: core.connectedApps,
            protonLimits: core.protonLimits.hits.map { .init(date: $0.date, sentInLastDay: $0.sentInLastDay) },
            approvalsReady: ready, approvalMethod: method, pendingApprovals: presenter.waiting().count
        )
    }

    static var processID: Int32 {
        #if os(Windows)
        Int32(bitPattern: GetCurrentProcessId())
        #else
        getpid()
        #endif
    }

    static var systemName: String {
        #if os(Linux)
        "linux"
        #elseif os(Windows)
        "windows"
        #else
        "macos"
        #endif
    }

    func apps() -> [ControlWire.AppRow] {
        let relay = PosternPaths.program("postern-mcp")?.path ?? ""
        return AppTarget.all().map { target in
            let status: String = switch target.status(relay: relay) {
            case .connected: "connected"
            case .notConnected: "notConnected"
            case .connectedElsewhere: "connectedElsewhere"
            }
            return ControlWire.AppRow(id: target.kind.rawValue, title: target.title, path: target.writable.first?.path ?? "",
                                      installed: target.installed, status: status)
        }
    }

    func batches() async -> [ControlWire.BatchRow] {
        await core.board.all().map { batch in
            let (phase, reason): (String, String?) = switch batch.phase {
            case .running: ("running", nil)
            case .waiting(_, let why): ("waiting", why)
            case .finished: ("finished", nil)
            case .cancelled: ("cancelled", nil)
            }
            return ControlWire.BatchRow(
                id: batch.id, kind: batch.kind.rawValue, client: batch.client, created: batch.created, total: batch.items.count,
                done: batch.count(.sent) + batch.count(.saved), waiting: batch.count(.waiting),
                failed: batch.count(.failed) + batch.count(.uncertain), phase: phase, reason: reason, interrupted: batch.interrupted
            )
        }
    }

    // MARK: Setup

    func detect(imap: Int, smtp: Int) async throws -> ControlWire.Detection {
        let imapIdentity: PortIdentity
        let smtpIdentity: PortIdentity
        do {
            imapIdentity = try await BridgeProbe.inspect(port: imap, service: .imap)
            smtpIdentity = try await BridgeProbe.inspect(port: smtp, service: .smtp)
        } catch {
            throw ControlWire.Failure("bridge_unreachable", "Proton Mail Bridge is not answering on ports \(imap) and \(smtp). Open Bridge, sign in, and check its ports under Settings, then try again.")
        }
        guard imapIdentity.pin == smtpIdentity.pin else {
            throw ControlWire.Failure("certificate_mismatch", "Bridge shows a different certificate on each port. Restart Bridge and try again.")
        }
        let version = imapIdentity.greeting.firstMatch(of: /Proton Mail Bridge ([0-9.]+)/).map { String($0.1) }
        return ControlWire.Detection(bridgeVersion: version, imapPort: imap, smtpPort: smtp, imapMode: imapIdentity.mode.rawValue,
                                     smtpMode: smtpIdentity.mode.rawValue, fingerprint: imapIdentity.pin.display)
    }

    func connect(_ params: ControlWire.Params) async throws {
        guard let username = params.username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty,
              let password = params.password, !password.isEmpty, let fingerprint = params.fingerprint else {
            throw ControlWire.Failure("invalid", "Enter the username and password that Bridge shows for your account.")
        }
        let imapPort = params.imapPort ?? 1143
        let smtpPort = params.smtpPort ?? 1025
        let imap = try await BridgeProbe.inspect(port: imapPort, service: .imap)
        let smtp = try await BridgeProbe.inspect(port: smtpPort, service: .smtp)
        // The certificate must still be the one the user looked at.
        guard imap.pin == smtp.pin, CertificatePin(sha256Hex: fingerprint) == imap.pin else {
            throw ControlWire.Failure("certificate_mismatch", "Bridge's certificate changed while setting up. Start again from the first step.")
        }
        let endpoint = BridgeEndpoint(imap: BridgePort(port: imapPort, mode: imap.mode), smtp: BridgePort(port: smtpPort, mode: smtp.mode))
        let credentials = BridgeCredentials(username: username, password: password)
        let connection = IMAPConnection(endpoint: endpoint, pin: imap.pin, credentials: credentials)
        do {
            try await connection.open()
            await connection.close()
        } catch BridgeError.authenticationFailed {
            throw ControlWire.Failure("authentication_failed", "Bridge refused this username or password. Copy them again from Bridge.")
        } catch {
            throw ControlWire.Failure("bridge_unreachable", "Postern couldn't sign in to Bridge. Make sure Bridge is running and try again.")
        }
        try core.vault.write(endpoint, for: .bridgeEndpoint)
        try core.vault.write(imap.pin, for: .certificatePin)
        try core.vault.write(credentials, for: .bridgeCredentials)
        core.reload()
    }
}

/// An app connected through a relay.
final class RelayClient: ClientConnection, @unchecked Sendable {
    let clientName: String
    init(name: String) { clientName = name }
}
