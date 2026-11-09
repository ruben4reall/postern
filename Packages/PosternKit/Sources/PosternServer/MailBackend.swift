import Foundation
import PosternApproval
import PosternCompose
import PosternModel

/// The mailbox as the MCP tools see it. The app implements it over Bridge and the parser service.
public protocol MailBackend: Sendable {
    func listMailboxes() async throws -> [MailboxInfo]
    /// Newest first. `offset` skips that many matches.
    func search(_ query: SearchQuery, limit: Int, offset: Int) async throws -> (items: [MessageSummary], total: Int)
    func message(_ id: MessageID, maxChars: Int) async throws -> SanitizedMessage
    /// The messages of a conversation, oldest first, looked up in these mailboxes (display names).
    func thread(_ id: MessageID, in mailboxes: [String]) async throws -> [MessageSummary]
    /// The display names of every mailbox, without counting their messages.
    func mailboxNames() async throws -> [String]
    /// The display name of a raw IMAP mailbox name, to apply the user's hidden mailboxes.
    func displayName(ofRawMailbox raw: String) async throws -> String

    // Organize. Each returns the messages changed, with their current ids, and what could not be done.
    func setFlag(_ flag: MessageFlag, on: Bool, ids: [MessageID]) async throws -> ChangeReport
    func move(_ ids: [MessageID], to mailbox: String) async throws -> ChangeReport
    func addLabel(_ ids: [MessageID], label: String) async throws -> ChangeReport
    func removeLabel(_ ids: [MessageID], label: String) async throws -> ChangeReport
    func createMailbox(_ name: String) async throws -> MailboxInfo

    // Drafts and sending.
    /// The address mail is sent from: the Bridge account.
    func ownAddress() async throws -> Address
    /// Whether Sent holds a message to this address.
    func hasSentTo(_ email: String) async throws -> Bool
    /// Saves a draft in Drafts and returns its id.
    func saveDraft(_ message: OutgoingMessage) async throws -> MessageID
    /// Deletes one message of the Drafts mailbox.
    func deleteDraft(_ id: MessageID) async throws
    /// Sends an approved message through Bridge.
    func send(_ message: ApprovedMessage) async throws

    // Attachments.
    /// Writes attachment `index` of a message into the Postern folder of Downloads, quarantined like any download.
    func saveAttachment(_ id: MessageID, index: Int) async throws -> SavedAttachment
    /// A file the user put in the Postern outbox folder: the only place attachments can come from.
    func outboxAttachment(named name: String) async throws -> OutgoingAttachment
    /// The attachments of a message, to forward them.
    func attachments(of id: MessageID) async throws -> [OutgoingAttachment]
    /// Whether a draft is still in Drafts: deleting it there holds back an email waiting in a batch.
    func draftExists(_ id: MessageID) async throws -> Bool
    /// The text of attachment `index` (from 1), read in the parser's sandbox.
    func readAttachment(_ id: MessageID, index: Int, maxChars: Int) async throws -> AttachmentContent
    /// The files of the outbox folder and its subfolders, by path inside it.
    func outboxFiles() async throws -> [OutboxFile]
    /// A draft's text and files at once, to send it.
    func draftForSending(_ id: MessageID) async throws -> (message: SanitizedMessage, files: [OutgoingAttachment])
    /// Attachment `index` (as get_message lists it) of a message, to attach it to another email.
    func attachment(_ id: MessageID, index: Int) async throws -> OutgoingAttachment
    /// How many files Bridge holds for a message, read from its structure alone; nil when it cannot tell.
    func attachmentCount(of id: MessageID) async throws -> Int?

    // Deleting.
    /// What the deletion panel lists for these messages.
    func deletionItems(_ ids: [MessageID]) async throws -> [DeletionItem]
    func trash(_ approved: ApprovedDeletion) async throws -> ChangeReport
    func erase(_ approved: ApprovedDeletion) async throws -> ChangeReport
}

extension MailBackend {
    public func draftForSending(_ id: MessageID) async throws -> (message: SanitizedMessage, files: [OutgoingAttachment]) {
        (try await message(id, maxChars: OutgoingMessage.maxBodyCharacters), try await attachments(of: id))
    }

    public func attachment(_ id: MessageID, index: Int) async throws -> OutgoingAttachment {
        let listed = try await message(id, maxChars: 100).attachments
        let files = try await attachments(of: id)
        guard let position = listed.firstIndex(where: { $0.index == index }), position < files.count else {
            throw PosternError(.notFound, "This email has no attachment \(index); get_message lists them.")
        }
        return files[position]
    }

    public func attachmentCount(of id: MessageID) async throws -> Int? { nil }
}

/// One file waiting in the outbox folder.
public struct OutboxFile: Sendable, Equatable {
    /// The path inside the outbox, such as `CV.pdf` or `Letters/Acme.pdf`.
    public let path: String
    public let size: Int
    public let modified: Date?

    public init(path: String, size: Int, modified: Date?) {
        self.path = path
        self.size = size
        self.modified = modified
    }
}

public struct SavedAttachment: Sendable, Equatable {
    public let path: String
    public let filename: String
    public let mimeType: String
    public let size: Int
    public let sha256: String

    public init(path: String, filename: String, mimeType: String, size: Int, sha256: String) {
        self.path = path
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.sha256 = sha256
    }
}

/// Where recent sends are counted, out of the client's reach.
public protocol SendLedger: Sendable {
    func recentSends() -> [Date]
    /// Records a send at `date` only if `allowed` finds room among the sends so far, in one step, so two sends
    /// running at once cannot both take the last place.
    func reserve(at date: Date, allowed: ([Date]) -> Bool) -> Bool
    /// Takes back a reservation whose email did not leave.
    func release(at date: Date)
}

public enum MessageFlag: String, Sendable {
    case read, starred
}

/// What an organize call changed.
public struct ChangeReport: Sendable, Equatable {
    public var done: [MessageID]
    public var failed: [(id: MessageID, reason: String)]
    /// Postern read Bridge again and saw every change applied.
    public var verified: Bool

    public init(done: [MessageID], failed: [(id: MessageID, reason: String)], verified: Bool) {
        self.done = done
        self.failed = failed
        self.verified = verified
    }

    public static func == (lhs: ChangeReport, rhs: ChangeReport) -> Bool {
        lhs.done == rhs.done && lhs.verified == rhs.verified
            && lhs.failed.map(\.id) == rhs.failed.map(\.id) && lhs.failed.map(\.reason) == rhs.failed.map(\.reason)
    }
}
