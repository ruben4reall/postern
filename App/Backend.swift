import Foundation
import OSLog
import PosternBridge
import PosternModel
import PosternServer

/// Forwards to whatever backend is configured right now, so a new setup applies to open sessions.
struct LiveBackend: MailBackend {
    private func current() throws -> BridgeBackend {
        guard let backend = CoreState.shared.backend else {
            throw PosternError(.notConfigured, "Postern is not set up yet. Open Postern to finish setup.")
        }
        return backend
    }

    func listMailboxes() async throws -> [MailboxInfo] { try await current().listMailboxes() }
    func search(_ query: SearchQuery, limit: Int, offset: Int) async throws -> (items: [MessageSummary], total: Int) {
        try await current().search(query, limit: limit, offset: offset)
    }
    func message(_ id: MessageID, maxChars: Int) async throws -> SanitizedMessage {
        try await current().message(id, maxChars: maxChars)
    }
    func thread(_ id: MessageID) async throws -> [MessageSummary] { try await current().thread(id) }
    func displayName(ofRawMailbox raw: String) async throws -> String {
        try await current().displayName(ofRawMailbox: raw)
    }
}

/// The mailbox over Bridge, with every message body decoded in the sandboxed parser service.
final class BridgeBackend: MailBackend, Sendable {
    static let log = Logger(subsystem: "ch.rubencatalao.postern", category: "bridge")
    static let maxMessageBytes = 25_000_000
    static let maxThreadMessages = 20

    private let client: BridgeClient
    private let parser = ParserClient()

    init(client: BridgeClient) {
        self.client = client
    }

    func shutdown() async { await client.shutdown() }

    func listMailboxes() async throws -> [MailboxInfo] {
        try await bridge {
            try await self.client.withConnection { connection in
                var result: [MailboxInfo] = []
                for mailbox in try await connection.mailboxes(refresh: true) where mailbox.selectable {
                    let counts = try await connection.status(mailbox)
                    result.append(MailboxInfo(name: mailbox.display, kind: Self.kind(of: mailbox.display),
                                              total: counts.total, unread: counts.unread))
                }
                return result
            }
        }
    }

    func search(_ query: SearchQuery, limit: Int, offset: Int) async throws -> (items: [MessageSummary], total: Int) {
        try await bridge {
            try await self.client.withConnection { connection in
                let mailbox = try await connection.mailbox(named: query.mailbox)
                let status = try await connection.examine(mailbox)
                let uids = try await connection.uidSearch(SearchKeyBuilder.key(for: query))
                let page = Array(uids.dropFirst(offset).prefix(limit))
                let fetched = try await connection.fetchSummaries(page)
                let items = fetched.compactMap { Self.summary($0, mailbox: mailbox.raw, validity: status.uidValidity) }
                    .sorted { $0.id.uid > $1.id.uid }
                return (items, uids.count)
            }
        }
    }

    func message(_ id: MessageID, maxChars: Int) async throws -> SanitizedMessage {
        let raw = try await rawMessage(id)
        let message = try await parser.sanitize(raw, maxChars: maxChars)
        // Server names that wrote Authentication-Results headers: hostnames only, never content.
        Self.log.info("Sender verdict \(message.verdict.level.rawValue, privacy: .public), authserv ids \(message.verdict.authservIDsSeen.joined(separator: ","), privacy: .public), forged \(message.verdict.forgedHeaderSeen, privacy: .public)")
        return message
    }

    func thread(_ id: MessageID) async throws -> [MessageSummary] {
        let message = try await parser.sanitize(try await rawMessage(id), maxChars: 500)
        var ids = message.headers.references
        if let own = message.headers.messageID { ids.append(own) }
        if let parent = message.headers.inReplyTo { ids.append(parent) }
        guard let key = SearchKeyBuilder.thread(ids: Array(Set(ids))) else { return [] }
        return try await bridge {
            try await self.client.withConnection { connection in
                let all = try await connection.mailbox(named: "All Mail")
                let status = try await connection.examine(all)
                let uids = Array(try await connection.uidSearch(key).prefix(Self.maxThreadMessages))
                return try await connection.fetchSummaries(uids)
                    .compactMap { Self.summary($0, mailbox: all.raw, validity: status.uidValidity) }
                    .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
            }
        }
    }

    func displayName(ofRawMailbox raw: String) async throws -> String {
        try await bridge {
            try await self.client.withConnection { connection in
                try await connection.mailboxes().first { $0.raw == raw }?.display ?? raw
            }
        }
    }

    private func rawMessage(_ id: MessageID) async throws -> Data {
        try await bridge {
            try await self.client.withConnection { connection in
                guard let mailbox = try await connection.mailboxes().first(where: { $0.raw == id.mailbox }) else {
                    throw BridgeError.mailboxNotFound(id.mailbox)
                }
                let status = try await connection.examine(mailbox)
                guard status.uidValidity == id.uidValidity else { throw BridgeError.staleUIDValidity }
                return try await connection.fetchRaw(uid: id.uid, maxBytes: Self.maxMessageBytes)
            }
        }
    }

    /// Runs a Bridge operation and turns its failures into errors a client can explain.
    private func bridge<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as BridgeError {
            // The exact Bridge failure, for diagnosis. It never contains a secret or message content.
            Self.log.error("Bridge operation failed: \(String(describing: error), privacy: .public)")
            throw Self.translate(error)
        }
    }

    static func translate(_ error: BridgeError) -> PosternError {
        switch error {
        case .unreachable, .timeout:
            PosternError(.bridgeUnreachable, "Proton Mail Bridge is not reachable. Make sure Bridge is running.")
        case .certificateMismatch:
            PosternError(.certificateMismatch, "Bridge presented a different certificate. Open Postern to review it.")
        case .authenticationFailed:
            PosternError(.authenticationFailed, "Bridge refused the password. Open Postern to sign in again.")
        case .staleUIDValidity:
            PosternError(.staleID, "This message id is out of date. Search again to get a fresh one.")
        case .mailboxNotFound(let name):
            PosternError(.notFound, "No mailbox or message matches \(name).")
        case .tooLarge:
            PosternError(.tooLarge, "This message is larger than 25 MB.")
        case .notBridge, .starttlsRefused, .tlsFailed, .commandFailed:
            PosternError(.bridgeUnreachable, "Bridge did not answer as expected. Try again in a moment.")
        }
    }

    static func summary(_ fetched: FetchedSummary, mailbox: String, validity: UInt32) -> MessageSummary? {
        guard let uid = fetched.uid else { return nil }
        let flags = Set(fetched.flags.map { $0.lowercased() })
        return MessageSummary(
            id: MessageID(mailbox: mailbox, uidValidity: validity, uid: uid), date: fetched.date, from: fetched.from,
            to: fetched.to, cc: fetched.cc, subject: fetched.subject, unread: !flags.contains("\\seen"),
            starred: flags.contains("\\flagged"), answered: flags.contains("\\answered"), size: fetched.size ?? 0,
            attachmentCount: fetched.attachmentCount, messageIDHeader: fetched.messageID, inReplyTo: fetched.inReplyTo
        )
    }

    static func kind(of name: String) -> MailboxInfo.Kind {
        if name.hasPrefix("Folders/") { return .folder }
        if name.hasPrefix("Labels/") { return .label }
        if ["All Mail", "Starred", "All Sent", "All Drafts", "All Scheduled"].contains(name) { return .virtual }
        return .system
    }
}

/// Talks to the sandboxed parser service. The connection is recreated after any failure.
final class ParserClient: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    private func proxy(onError: @escaping @Sendable (any Error) -> Void) -> ParserXPC {
        lock.withLock {
            if connection == nil {
                let fresh = NSXPCConnection(serviceName: PosternXPC.parserService)
                fresh.setCodeSigningRequirement(PosternXPC.teamRequirement)
                fresh.remoteObjectInterface = NSXPCInterface(with: ParserXPC.self)
                fresh.invalidationHandler = { [weak self] in self?.reset() }
                fresh.interruptionHandler = { [weak self] in self?.reset() }
                fresh.resume()
                connection = fresh
            }
            return connection!.remoteObjectProxyWithErrorHandler(onError) as! ParserXPC
        }
    }

    private func reset() { lock.withLock { connection = nil } }

    func sanitize(_ raw: Data, maxChars: Int) async throws -> SanitizedMessage {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SanitizedMessage, any Error>) in
            let once = OnceFlag()
            let fail: @Sendable (String) -> Void = { message in
                if once.claim() { continuation.resume(throwing: PosternError(.parseFailed, message)) }
            }
            let parser = proxy { _ in fail("The message reader stopped. Try again.") }
            parser.sanitize(raw, maxChars: maxChars) { data, error in
                guard let data, let message = try? JSONDecoder().decode(SanitizedMessage.self, from: data) else {
                    fail(error.map { "This message could not be read (\($0))." } ?? "This message could not be read.")
                    return
                }
                if once.claim() { continuation.resume(returning: message) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { fail("Reading this message took too long.") }
        }
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
