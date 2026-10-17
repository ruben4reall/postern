import CryptoKit
import Foundation
import NIOCore
import OSLog
import PosternApproval
import PosternBridge
import PosternCompose
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
    func setFlag(_ flag: MessageFlag, on: Bool, ids: [MessageID]) async throws -> ChangeReport {
        try await current().setFlag(flag, on: on, ids: ids)
    }
    func move(_ ids: [MessageID], to mailbox: String) async throws -> ChangeReport {
        try await current().move(ids, to: mailbox)
    }
    func addLabel(_ ids: [MessageID], label: String) async throws -> ChangeReport {
        try await current().addLabel(ids, label: label)
    }
    func removeLabel(_ ids: [MessageID], label: String) async throws -> ChangeReport {
        try await current().removeLabel(ids, label: label)
    }
    func createMailbox(_ name: String) async throws -> MailboxInfo { try await current().createMailbox(name) }
    func ownAddress() async throws -> Address { try await current().ownAddress() }
    func hasSentTo(_ email: String) async throws -> Bool { try await current().hasSentTo(email) }
    func saveDraft(_ message: OutgoingMessage) async throws -> MessageID { try await current().saveDraft(message) }
    func deleteDraft(_ id: MessageID) async throws { try await current().deleteDraft(id) }
    func send(_ message: ApprovedMessage) async throws { try await current().send(message) }
    func saveAttachment(_ id: MessageID, index: Int) async throws -> SavedAttachment {
        try await current().saveAttachment(id, index: index)
    }
    func outboxAttachment(named name: String) async throws -> OutgoingAttachment {
        try await current().outboxAttachment(named: name)
    }
    func attachments(of id: MessageID) async throws -> [OutgoingAttachment] { try await current().attachments(of: id) }
    func deletionItems(_ ids: [MessageID]) async throws -> [DeletionItem] { try await current().deletionItems(ids) }
    func trash(_ approved: ApprovedDeletion) async throws -> ChangeReport { try await current().trash(approved) }
    func erase(_ approved: ApprovedDeletion) async throws -> ChangeReport { try await current().erase(approved) }
}

/// The mailbox over Bridge, with every message body decoded in the sandboxed parser service.
final class BridgeBackend: MailBackend, Sendable {
    static let log = Logger(subsystem: "ch.rubencatalao.postern", category: "bridge")
    static let maxMessageBytes = 25_000_000
    static let maxThreadMessages = 20

    private let client: BridgeClient
    private let sender: SMTPClient
    private let account: Address
    private let parser = ParserClient()

    init(endpoint: BridgeEndpoint, pin: CertificatePin, credentials: BridgeCredentials) {
        self.client = BridgeClient(endpoint: endpoint, pin: pin, credentials: credentials)
        self.sender = SMTPClient(endpoint: endpoint, pin: pin, credentials: credentials)
        self.account = Address(name: nil, email: credentials.username)
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

    // MARK: Organize

    func setFlag(_ flag: MessageFlag, on: Bool, ids: [MessageID]) async throws -> ChangeReport {
        try await bridge {
            try await self.client.withConnection { connection in
                let change: FlagChange = flag == .read ? .read(on) : .starred(on)
                return Self.report(try await Organizer(connection: connection).setFlag(change, ids: ids))
            }
        }
    }

    func move(_ ids: [MessageID], to mailbox: String) async throws -> ChangeReport {
        try await bridge {
            try await self.client.withConnection { connection in
                let destination = try await connection.mailbox(named: mailbox)
                return Self.report(try await Organizer(connection: connection).move(ids, to: destination))
            }
        }
    }

    func addLabel(_ ids: [MessageID], label: String) async throws -> ChangeReport {
        try await bridge {
            try await self.client.withConnection { connection in
                let target = try await connection.mailbox(named: label)
                return Self.report(try await Organizer(connection: connection).addLabel(ids, label: target))
            }
        }
    }

    func removeLabel(_ ids: [MessageID], label: String) async throws -> ChangeReport {
        try await bridge {
            try await self.client.withConnection { connection in
                let target = try await connection.mailbox(named: label)
                return Self.report(try await Organizer(connection: connection).removeLabel(ids, label: target))
            }
        }
    }

    func createMailbox(_ name: String) async throws -> MailboxInfo {
        try await bridge {
            try await self.client.withConnection { connection in
                let organizer = Organizer(connection: connection)
                let components = name.split(separator: "/").dropFirst().map(String.init)
                let created = name.hasPrefix("Labels/")
                    ? try await organizer.create(label: components.joined(separator: "/"))
                    : try await organizer.create(folder: components)
                return MailboxInfo(name: created.display, kind: Self.kind(of: created.display), total: 0, unread: 0)
            }
        }
    }

    // MARK: Drafts and sending

    func ownAddress() async throws -> Address { account }

    func hasSentTo(_ email: String) async throws -> Bool {
        try await bridge {
            try await self.client.withConnection { connection in
                _ = try await connection.examine(try await connection.mailbox(named: "Sent"))
                return !(try await connection.uidSearch(.to(ByteBuffer(string: email)))).isEmpty
            }
        }
    }

    func saveDraft(_ message: OutgoingMessage) async throws -> MessageID {
        try await bridge {
            try await self.client.withConnection { connection in
                let drafts = try await connection.mailbox(named: "Drafts")
                if let appended = try await connection.appendDraft(message.rfc822(includeBcc: true), to: drafts) {
                    return MessageID(mailbox: drafts.raw, uidValidity: appended.validity, uid: appended.uid)
                }
                let status = try await connection.examine(drafts)
                guard let uid = try await connection.uids(withMessageID: message.messageID).first else {
                    throw BridgeError.mailboxNotFound("the new draft")
                }
                return MessageID(mailbox: drafts.raw, uidValidity: status.uidValidity, uid: uid)
            }
        }
    }

    func deleteDraft(_ id: MessageID) async throws {
        try await bridge {
            try await self.client.withConnection { connection in
                let drafts = try await connection.mailbox(named: "Drafts")
                guard id.mailbox == drafts.raw else { throw BridgeError.mailboxNotFound("draft") }
                let status = try await connection.select(drafts)
                guard status.uidValidity == id.uidValidity else { throw BridgeError.staleUIDValidity }
                try await connection.deleteDrafts(uids: [id.uid])
            }
        }
    }

    func send(_ message: ApprovedMessage) async throws {
        try await bridge { try await self.sender.send(message) }
    }

    // MARK: Attachments

    func saveAttachment(_ id: MessageID, index: Int) async throws -> SavedAttachment {
        let raw = try await rawMessage(id)
        let file = try await parser.attachment(raw, index: index)
        return try PosternFolders.save(file.data, suggestedName: file.filename ?? "attachment-\(index)", mimeType: file.mimeType)
    }

    func outboxAttachment(named name: String) async throws -> OutgoingAttachment {
        try PosternFolders.outboxFile(named: name)
    }

    func attachments(of id: MessageID) async throws -> [OutgoingAttachment] {
        let raw = try await rawMessage(id)
        let listed = try await parser.sanitize(raw, maxChars: 100).attachments
        var files: [OutgoingAttachment] = []
        for item in listed {
            let file = try await parser.attachment(raw, index: item.index)
            let name = PosternFolders.safeName(file.filename ?? "attachment-\(item.index)")
            files.append(try OutgoingAttachment.make(filename: name, data: file.data, mimeType: file.mimeType))
        }
        return files
    }

    // MARK: Deleting

    func deletionItems(_ ids: [MessageID]) async throws -> [DeletionItem] {
        try await bridge {
            try await self.client.withConnection { connection in
                var items: [DeletionItem] = []
                let mailboxes = try await connection.mailboxes()
                for (raw, group) in Dictionary(grouping: ids, by: \.mailbox) {
                    guard let mailbox = mailboxes.first(where: { $0.raw == raw }) else { continue }
                    let status = try await connection.examine(mailbox)
                    let valid = group.filter { $0.uidValidity == status.uidValidity }
                    let summaries = try await connection.fetchSummaries(valid.map(\.uid))
                    for id in valid {
                        let summary = summaries.first { $0.uid == id.uid }
                        let from = summary?.from.first.map { $0.name.map { "\($0) <\(summary!.from[0].email)>" } ?? $0.email } ?? "Unknown sender"
                        items.append(DeletionItem(id: id, mailbox: mailbox.display, from: from,
                                                  subject: summary?.subject ?? "(not found)", date: summary?.date))
                    }
                }
                return items
            }
        }
    }

    func trash(_ approved: ApprovedDeletion) async throws -> ChangeReport {
        try await bridge {
            try await self.client.withConnection { connection in
                Self.report(try await Organizer(connection: connection).trash(approved))
            }
        }
    }

    func erase(_ approved: ApprovedDeletion) async throws -> ChangeReport {
        try await bridge {
            try await self.client.withConnection { connection in
                Self.report(try await Organizer(connection: connection).erase(approved))
            }
        }
    }

    static func report(_ result: OrganizeResult) -> ChangeReport {
        ChangeReport(done: result.done, failed: result.failed.map { ($0.id, $0.reason) }, verified: result.verified)
    }

    func rawMessage(_ id: MessageID) async throws -> Data {
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

    func proxy(onError: @escaping @Sendable (any Error) -> Void) -> ParserXPC {
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

extension ParserClient {
    func attachment(_ raw: Data, index: Int) async throws -> (data: Data, filename: String?, mimeType: String) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(data: Data, filename: String?, mimeType: String), any Error>) in
            let once = OnceFlag()
            let fail: @Sendable (String) -> Void = { message in
                if once.claim() { continuation.resume(throwing: PosternError(.parseFailed, message)) }
            }
            let parser = proxy { _ in fail("The message reader stopped. Try again.") }
            parser.attachment(raw, index: index) { data, filename, mimeType, error in
                guard let data, let mimeType else {
                    fail(error == nil ? "This attachment could not be read." : "There is no attachment \(index) in this message.")
                    return
                }
                if once.claim() { continuation.resume(returning: (data, filename, mimeType)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { fail("Reading this attachment took too long.") }
        }
    }
}

/// The two folders Postern touches on disk, both inside Downloads: saved attachments, and the outbox, the only
/// place a file can be attached from.
enum PosternFolders {
    static let maxOutboxFile = OutgoingMessage.maxAttachmentBytes

    static var downloads: URL {
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else {
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        return URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Downloads", isDirectory: true)
    }

    static var saved: URL { downloads.appendingPathComponent("Postern", isDirectory: true) }
    static var outbox: URL { saved.appendingPathComponent("Outbox", isDirectory: true) }

    static func prepare() {
        try? FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
    }

    /// A file name with no path, no leading dot, no control or invisible characters.
    static func safeName(_ name: String) -> String {
        let cleaned = name.unicodeScalars.filter { scalar in
            !"/\\:".unicodeScalars.contains(scalar) && scalar.properties.generalCategory != .control
                && scalar.properties.generalCategory != .format
        }
        var result = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix(".") { result.removeFirst() }
        if result.isEmpty { result = "attachment" }
        return String(result.prefix(150))
    }

    static func save(_ data: Data, suggestedName: String, mimeType: String) throws -> SavedAttachment {
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        let name = safeName(suggestedName)
        var url = saved.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            url = saved.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            counter += 1
        }
        try data.write(to: url, options: .withoutOverwriting)
        // Marked as downloaded: Gatekeeper and the quarantine checks apply before it opens.
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
            kLSQuarantineAgentNameKey as String: "Postern",
        ]
        try? url.setResourceValues(values)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return SavedAttachment(path: url.path, filename: url.lastPathComponent, mimeType: mimeType, size: data.count, sha256: hash)
    }

    /// Only a plain file sitting directly in the outbox: no path, no link out of it.
    static func outboxFile(named name: String) throws -> OutgoingAttachment {
        guard name == safeName(name), !name.contains("/") else {
            throw PosternError(.invalidArgument, "\(name) is not a plain file name. Attachments come only from Downloads › Postern › Outbox.")
        }
        let url = outbox.appendingPathComponent(name)
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard let values, values.isRegularFile == true, values.isSymbolicLink != true else {
            throw PosternError(.notFound, "\(name) is not in Downloads › Postern › Outbox. Put the file there first.")
        }
        guard (values.fileSize ?? 0) <= maxOutboxFile else { throw PosternError(.tooLarge, "\(name) is larger than 20 MB.") }
        do {
            return try OutgoingAttachment.make(filename: name, data: try Data(contentsOf: url))
        } catch {
            throw PosternError(.invalidArgument, "\(name) could not be attached.")
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
