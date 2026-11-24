import Foundation
import Logging
import NIOCore
import PosternApproval
import PosternBridge
import PosternCompose
import PosternModel
import PosternServer

/// Forwards to whatever backend is configured right now, so a new setup applies to open sessions.
public struct LiveBackend: MailBackend {
    private let provider: @Sendable () -> BridgeBackend?

    public init(_ provider: @escaping @Sendable () -> BridgeBackend?) {
        self.provider = provider
    }

    private func current() throws -> BridgeBackend {
        guard let backend = provider() else {
            throw PosternError(.notConfigured, "Postern is not set up yet. Open Postern to finish setup.")
        }
        return backend
    }

    public func listMailboxes() async throws -> [MailboxInfo] { try await current().listMailboxes() }
    public func search(_ query: SearchQuery, limit: Int, offset: Int) async throws -> (items: [MessageSummary], total: Int) {
        try await current().search(query, limit: limit, offset: offset)
    }
    public func message(_ id: MessageID, maxChars: Int) async throws -> SanitizedMessage {
        try await current().message(id, maxChars: maxChars)
    }
    public func thread(_ id: MessageID, in mailboxes: [String]) async throws -> [MessageSummary] {
        try await current().thread(id, in: mailboxes)
    }
    public func mailboxNames() async throws -> [String] { try await current().mailboxNames() }
    public func displayName(ofRawMailbox raw: String) async throws -> String {
        try await current().displayName(ofRawMailbox: raw)
    }
    public func setFlag(_ flag: MessageFlag, on: Bool, ids: [MessageID]) async throws -> ChangeReport {
        try await current().setFlag(flag, on: on, ids: ids)
    }
    public func move(_ ids: [MessageID], to mailbox: String) async throws -> ChangeReport {
        try await current().move(ids, to: mailbox)
    }
    public func addLabel(_ ids: [MessageID], label: String) async throws -> ChangeReport {
        try await current().addLabel(ids, label: label)
    }
    public func removeLabel(_ ids: [MessageID], label: String) async throws -> ChangeReport {
        try await current().removeLabel(ids, label: label)
    }
    public func createMailbox(_ name: String) async throws -> MailboxInfo { try await current().createMailbox(name) }
    public func ownAddress() async throws -> Address { try await current().ownAddress() }
    public func hasSentTo(_ email: String) async throws -> Bool { try await current().hasSentTo(email) }
    public func saveDraft(_ message: OutgoingMessage) async throws -> MessageID { try await current().saveDraft(message) }
    public func deleteDraft(_ id: MessageID) async throws { try await current().deleteDraft(id) }
    public func draftExists(_ id: MessageID) async throws -> Bool { try await current().draftExists(id) }
    public func send(_ message: ApprovedMessage) async throws { try await current().send(message) }
    public func saveAttachment(_ id: MessageID, index: Int) async throws -> SavedAttachment {
        try await current().saveAttachment(id, index: index)
    }
    public func outboxAttachment(named name: String) async throws -> OutgoingAttachment {
        try await current().outboxAttachment(named: name)
    }
    public func attachments(of id: MessageID) async throws -> [OutgoingAttachment] { try await current().attachments(of: id) }
    public func outboxFiles() async throws -> [OutboxFile] { PosternFolders.outboxFiles() }
    public func readAttachment(_ id: MessageID, index: Int, maxChars: Int) async throws -> AttachmentContent {
        try await current().readAttachment(id, index: index, maxChars: maxChars)
    }
    public func draftForSending(_ id: MessageID) async throws -> (message: SanitizedMessage, files: [OutgoingAttachment]) {
        try await current().draftForSending(id)
    }
    public func attachment(_ id: MessageID, index: Int) async throws -> OutgoingAttachment {
        try await current().attachment(id, index: index)
    }
    public func attachmentCount(of id: MessageID) async throws -> Int? { try await current().attachmentCount(of: id) }
    public func deletionItems(_ ids: [MessageID]) async throws -> [DeletionItem] { try await current().deletionItems(ids) }
    public func trash(_ approved: ApprovedDeletion) async throws -> ChangeReport { try await current().trash(approved) }
    public func erase(_ approved: ApprovedDeletion) async throws -> ChangeReport { try await current().erase(approved) }
}

/// The mailbox over Bridge, with every message body decoded in the sandboxed parser service.
public final class BridgeBackend: MailBackend, Sendable {
    static let log = Logger(label: "ch.rubencatalao.postern.bridge")
    static let maxMessageBytes = 25_000_000
    static let maxThreadMessages = 20

    private let client: BridgeClient
    private let sender: SMTPClient
    private let account: Address
    private let parser: any MessageReading

    public init(endpoint: BridgeEndpoint, pin: CertificatePin, credentials: BridgeCredentials, reader: any MessageReading) {
        self.client = BridgeClient(endpoint: endpoint, pin: pin, credentials: credentials)
        self.sender = SMTPClient(endpoint: endpoint, pin: pin, credentials: credentials)
        self.account = Address(name: nil, email: credentials.username)
        self.parser = reader
    }

    public func shutdown() async { await client.shutdown() }

    public func listMailboxes() async throws -> [MailboxInfo] {
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

    public func search(_ query: SearchQuery, limit: Int, offset: Int) async throws -> (items: [MessageSummary], total: Int) {
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

    public func message(_ id: MessageID, maxChars: Int) async throws -> SanitizedMessage {
        let raw = try await rawMessage(id)
        let message = try await parser.sanitize(raw, maxChars: maxChars)
        // Server names that wrote Authentication-Results headers: hostnames only, never content.
        Self.log.info("Sender verdict \(message.verdict.level.rawValue), authserv ids \(message.verdict.authservIDsSeen.joined(separator: ",")), forged \(message.verdict.forgedHeaderSeen)")
        return message
    }

    /// Reads only the header of the message, then looks for its conversation mailbox by mailbox: All Mail when it
    /// is visible, else each visible folder, so hiding one folder does not empty every conversation.
    public func thread(_ id: MessageID, in mailboxes: [String]) async throws -> [MessageSummary] {
        let message = try await parser.sanitize(try await rawHeader(id), maxChars: 100)
        var ids = message.headers.references
        if let own = message.headers.messageID { ids.append(own) }
        if let parent = message.headers.inReplyTo { ids.append(parent) }
        guard let key = SearchKeyBuilder.thread(ids: Array(Set(ids))) else { return [] }
        return try await bridge {
            try await self.client.withConnection { connection in
                var found: [MessageSummary] = []
                var seen: Set<String> = []
                for name in mailboxes {
                    guard let mailbox = try? await connection.mailbox(named: name), mailbox.selectable else { continue }
                    let status = try await connection.examine(mailbox)
                    let uids = Array(try await connection.uidSearch(key).prefix(Self.maxThreadMessages))
                    for fetched in try await connection.fetchSummaries(uids) {
                        guard let summary = Self.summary(fetched, mailbox: mailbox.raw, validity: status.uidValidity) else { continue }
                        // A message filed in a folder and in a label is listed once.
                        if seen.insert(summary.messageIDHeader ?? summary.id.opaque).inserted { found.append(summary) }
                    }
                }
                return Array(found.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }.suffix(Self.maxThreadMessages))
            }
        }
    }

    public func mailboxNames() async throws -> [String] {
        try await bridge {
            try await self.client.withConnection { connection in
                try await connection.mailboxes().filter(\.selectable).map(\.display)
            }
        }
    }

    public func displayName(ofRawMailbox raw: String) async throws -> String {
        try await bridge {
            try await self.client.withConnection { connection in
                try await connection.mailboxes().first { $0.raw == raw }?.display ?? raw
            }
        }
    }

    // MARK: Organize

    public func setFlag(_ flag: MessageFlag, on: Bool, ids: [MessageID]) async throws -> ChangeReport {
        try await bridge {
            try await self.client.withConnection { connection in
                let change: FlagChange = flag == .read ? .read(on) : .starred(on)
                return Self.report(try await Organizer(connection: connection).setFlag(change, ids: ids))
            }
        }
    }

    public func move(_ ids: [MessageID], to mailbox: String) async throws -> ChangeReport {
        try await bridge {
            try await self.client.withConnection { connection in
                let destination = try await connection.mailbox(named: mailbox)
                return Self.report(try await Organizer(connection: connection).move(ids, to: destination))
            }
        }
    }

    public func addLabel(_ ids: [MessageID], label: String) async throws -> ChangeReport {
        try await bridge {
            try await self.client.withConnection { connection in
                let target = try await connection.mailbox(named: label)
                return Self.report(try await Organizer(connection: connection).addLabel(ids, label: target))
            }
        }
    }

    public func removeLabel(_ ids: [MessageID], label: String) async throws -> ChangeReport {
        try await bridge {
            try await self.client.withConnection { connection in
                let target = try await connection.mailbox(named: label)
                return Self.report(try await Organizer(connection: connection).removeLabel(ids, label: target))
            }
        }
    }

    public func createMailbox(_ name: String) async throws -> MailboxInfo {
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

    public func ownAddress() async throws -> Address { account }

    public func hasSentTo(_ email: String) async throws -> Bool {
        try await bridge {
            try await self.client.withConnection { connection in
                _ = try await connection.examine(try await connection.mailbox(named: "Sent"))
                return !(try await connection.uidSearch(.to(ByteBuffer(string: email)))).isEmpty
            }
        }
    }

    public func saveDraft(_ message: OutgoingMessage) async throws -> MessageID {
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

    public func deleteDraft(_ id: MessageID) async throws {
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

    public func send(_ message: ApprovedMessage) async throws {
        try await bridge { try await self.sender.send(message) }
    }

    public func draftExists(_ id: MessageID) async throws -> Bool {
        try await bridge {
            try await self.client.withConnection { connection in
                let drafts = try await connection.mailbox(named: "Drafts")
                guard id.mailbox == drafts.raw else { return false }
                let status = try await connection.examine(drafts)
                guard status.uidValidity == id.uidValidity else { return false }
                return !(try await connection.fetchSummaries([id.uid])).isEmpty
            }
        }
    }

    // MARK: Attachments

    public func saveAttachment(_ id: MessageID, index: Int) async throws -> SavedAttachment {
        let raw = try await rawMessage(id)
        let file = try await parser.attachment(raw, index: index)
        return try PosternFolders.save(file.data, suggestedName: file.filename ?? "attachment-\(index)", mimeType: file.mimeType)
    }

    public func outboxAttachment(named name: String) async throws -> OutgoingAttachment {
        try PosternFolders.outboxFile(named: name)
    }

    public func attachments(of id: MessageID) async throws -> [OutgoingAttachment] {
        let raw = try await rawMessage(id)
        return try await files(of: raw, listed: try await parser.sanitize(raw, maxChars: 100).attachments)
    }

    public func outboxFiles() async throws -> [OutboxFile] { PosternFolders.outboxFiles() }

    public func readAttachment(_ id: MessageID, index: Int, maxChars: Int) async throws -> AttachmentContent {
        try await parser.readAttachment(try await rawMessage(id), index: index, maxChars: maxChars)
    }

    /// Reads the draft once from Bridge for both its text and its files.
    public func draftForSending(_ id: MessageID) async throws -> (message: SanitizedMessage, files: [OutgoingAttachment]) {
        let raw = try await rawMessage(id)
        let message = try await parser.sanitize(raw, maxChars: OutgoingMessage.maxBodyCharacters)
        return (message, try await files(of: raw, listed: message.attachments))
    }

    public func attachment(_ id: MessageID, index: Int) async throws -> OutgoingAttachment {
        let file = try await parser.attachment(try await rawMessage(id), index: index)
        let name = PosternFolders.safeName(file.filename ?? "attachment-\(index)")
        return try OutgoingAttachment.make(filename: name, data: file.data, mimeType: file.mimeType)
    }

    /// The files Bridge holds for a draft, from its structure alone: the check that follows every saved draft.
    public func attachmentCount(of id: MessageID) async throws -> Int? {
        try await bridge {
            try await self.client.withConnection { connection in
                let drafts = try await connection.mailbox(named: "Drafts")
                guard id.mailbox == drafts.raw else { return nil }
                let status = try await connection.examine(drafts)
                guard status.uidValidity == id.uidValidity else { return nil }
                return try await connection.fetchSummaries([id.uid]).first?.attachmentCount
            }
        }
    }

    private func files(of raw: Data, listed: [AttachmentInfo]) async throws -> [OutgoingAttachment] {
        var files: [OutgoingAttachment] = []
        for item in listed {
            let file = try await parser.attachment(raw, index: item.index)
            let name = PosternFolders.safeName(file.filename ?? "attachment-\(item.index)")
            files.append(try OutgoingAttachment.make(filename: name, data: file.data, mimeType: file.mimeType))
        }
        return files
    }

    // MARK: Deleting

    public func deletionItems(_ ids: [MessageID]) async throws -> [DeletionItem] {
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

    public func trash(_ approved: ApprovedDeletion) async throws -> ChangeReport {
        try await bridge {
            try await self.client.withConnection { connection in
                Self.report(try await Organizer(connection: connection).trash(approved))
            }
        }
    }

    public func erase(_ approved: ApprovedDeletion) async throws -> ChangeReport {
        try await bridge {
            try await self.client.withConnection { connection in
                Self.report(try await Organizer(connection: connection).erase(approved))
            }
        }
    }

    public static func report(_ result: OrganizeResult) -> ChangeReport {
        ChangeReport(done: result.done, failed: result.failed.map { ($0.id, $0.reason) }, verified: result.verified)
    }

    public func rawHeader(_ id: MessageID) async throws -> Data {
        try await bridge {
            try await self.client.withConnection { connection in
                guard let mailbox = try await connection.mailboxes().first(where: { $0.raw == id.mailbox }) else {
                    throw BridgeError.mailboxNotFound(id.mailbox)
                }
                let status = try await connection.examine(mailbox)
                guard status.uidValidity == id.uidValidity else { throw BridgeError.staleUIDValidity }
                return try await connection.fetchHeader(uid: id.uid)
            }
        }
    }

    public func rawMessage(_ id: MessageID) async throws -> Data {
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
            Self.log.error("Bridge operation failed: \(String(describing: error))")
            throw Self.translate(error)
        }
    }

    public static func translate(_ error: BridgeError) -> PosternError {
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
        case .commandFailed(let reply) where error.isProtonSendingBlock:
            PosternError(.protonBlocked, "Proton has blocked this account from sending for a while (\(reply.prefix(200))). It was not sent. Proton lifts such a block on its own, usually within 48 hours; send nothing more until then.")
        case .commandFailed(let reply) where error.isProtonSendingLimit:
            PosternError(.protonLimit, "Proton refused this email: the account reached Proton's own sending limit (\(reply.prefix(200))). It was not sent; Proton asks to wait an hour before sending again.")
        case .commandFailed(let reply) where reply.hasPrefix("SMTP 5"):
            PosternError(.sendRefused, "Proton refused this email (\(reply.prefix(200))). It was not sent.")
        case .commandFailed(let reply) where reply.hasPrefix("SMTP 4"):
            PosternError(.bridgeUnreachable, "Proton asked to try again later (\(reply.prefix(200))). It was not sent.")
        case .sendInterrupted:
            PosternError(.sendUncertain, "The connection to Bridge broke while the email was handed over, so it may have left. Check Sent before sending it again.")
        case .notBridge, .starttlsRefused, .tlsFailed, .commandFailed:
            PosternError(.bridgeUnreachable, "Bridge did not answer as expected. Try again in a moment.")
        }
    }

    public static func summary(_ fetched: FetchedSummary, mailbox: String, validity: UInt32) -> MessageSummary? {
        guard let uid = fetched.uid else { return nil }
        let flags = Set(fetched.flags.map { $0.lowercased() })
        return MessageSummary(
            id: MessageID(mailbox: mailbox, uidValidity: validity, uid: uid), date: fetched.date, from: fetched.from,
            to: fetched.to, cc: fetched.cc, subject: fetched.subject, unread: !flags.contains("\\seen"),
            starred: flags.contains("\\flagged"), answered: flags.contains("\\answered"), size: fetched.size ?? 0,
            attachmentCount: fetched.attachmentCount, messageIDHeader: fetched.messageID, inReplyTo: fetched.inReplyTo
        )
    }

    public static func kind(of name: String) -> MailboxInfo.Kind {
        if name.hasPrefix("Folders/") { return .folder }
        if name.hasPrefix("Labels/") { return .label }
        if ["All Mail", "Starred", "All Sent", "All Drafts", "All Scheduled"].contains(name) { return .virtual }
        return .system
    }
}

