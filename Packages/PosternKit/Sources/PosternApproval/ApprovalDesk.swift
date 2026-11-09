import CryptoKit
import Foundation
import PosternCompose
import PosternModel

/// Why a recipient deserves a second look on the approval panel.
public enum ApprovalBadge: String, Codable, Sendable, CaseIterable {
    /// The address never appears in Sent.
    case firstContact
    /// The address appeared inside an email the client read during this session.
    case cameFromEmail
    /// Replies go to a Reply-To address that is not the sender's.
    case replyToDiffers
    /// On the user's trusted list.
    case trusted
}

/// Everything the panel shows. The digest binds the approval to these exact bytes and recipients.
public struct ApprovalRequest: Sendable, Identifiable {
    public let id = UUID()
    public let tool: String
    public let client: String
    public let message: OutgoingMessage
    public let badges: [String: [ApprovalBadge]]
    /// For replies and forwards: what the message answers, in a few words.
    public let context: String?
    public let digest: String

    public init(tool: String, client: String, message: OutgoingMessage, badges: [String: [ApprovalBadge]], context: String?) {
        self.tool = tool
        self.client = client
        self.message = message
        self.badges = badges
        self.context = context
        self.digest = message.digest
    }
}

/// What the person chose on the panel.
public enum ApprovalIntent: Sendable, Equatable {
    case send
    case reject(reason: String?)
    case saveAsDraft
}

/// A file as a batch panel lists it: its name, type and size, and the digest of its bytes.
public struct FileSummary: Sendable, Hashable {
    public let filename: String
    public let mimeType: String
    public let size: Int
    public let sha256: String
}

/// One email of a batch as its panel shows it: who it goes to, from whom, its text and its files, but not the bytes
/// of the files. It is made from the whole message and keeps that message's digest, so a batch of thousands of
/// emails is reviewed without holding thousands of messages in memory.
public struct BatchItem: Sendable, Identifiable {
    public let id = UUID()
    public let from: Address
    public let to: [Address]
    public let cc: [Address]
    public let bcc: [Address]
    /// Everyone the email reaches, Bcc included.
    public let recipients: [String]
    public let subject: String
    /// The start of the text that leaves, as the panel shows it: 2,000 characters at most, so thousands of emails
    /// do not fill memory. The digest covers all of it.
    public let text: String
    public let files: [FileSummary]
    public let badges: [String: [ApprovalBadge]]
    public let context: String?
    /// The words announcing a file when the email has none.
    public let missingAttachment: String?
    public let digest: String

    public init(message: OutgoingMessage, badges: [String: [ApprovalBadge]], context: String?) {
        from = message.from
        to = message.to
        cc = message.cc
        bcc = message.bcc
        recipients = message.envelopeRecipients
        subject = message.subject
        text = String(message.fullText.prefix(2000))
        files = message.attachments.map { FileSummary(filename: $0.filename, mimeType: $0.mimeType, size: $0.data.count, sha256: $0.sha256) }
        self.badges = badges
        self.context = context
        missingAttachment = message.missingAttachment
        digest = message.digest
    }
}

/// Several emails reviewed on one panel and approved with one Touch ID. Each keeps its own digest: approving the
/// batch approves those exact messages, never others.
public struct BatchApprovalRequest: Sendable, Identifiable {
    public let id = UUID()
    public let tool: String
    public let client: String
    public let items: [BatchItem]
    /// When and how fast the emails leave.
    public let schedule: BatchSchedule?

    public init(tool: String, client: String, items: [BatchItem], schedule: BatchSchedule? = nil) {
        self.tool = tool
        self.client = client
        self.items = items
        self.schedule = schedule
    }
}

/// The pace a batch keeps, as the panel tells it: a start time, a pause between two emails, the user's limits, and
/// when the last one should leave if every email is approved.
public struct BatchSchedule: Sendable, Equatable {
    /// Nil to start at once.
    public let start: Date?
    public let spacing: TimeInterval
    public let sendsPerHour: Int
    public let sendsPerDay: Int
    public let finish: Date

    public init(start: Date?, spacing: TimeInterval, sendsPerHour: Int, sendsPerDay: Int, finish: Date) {
        self.start = start
        self.spacing = spacing
        self.sendsPerHour = sendsPerHour
        self.sendsPerDay = sendsPerDay
        self.finish = finish
    }
}

/// What the person chose on a batch panel: the emails left ticked, by request id, or none of them.
public enum BatchIntent: Sendable, Equatable {
    case send(Set<UUID>)
    case reject(reason: String?)
}

public enum BatchOutcome: Sendable {
    /// The approved emails, keyed by the id of their item. The ones the person unticked are absent.
    case approved([UUID: ApprovedClaim])
    case rejected(reason: String?)
    case expired
    case notAuthenticated
}

/// One message a deletion request would move to Trash or erase, as the panel lists it.
public struct DeletionItem: Sendable, Equatable {
    public let id: MessageID
    public let mailbox: String
    public let from: String
    public let subject: String
    public let date: Date?

    public init(id: MessageID, mailbox: String, from: String, subject: String, date: Date?) {
        self.id = id
        self.mailbox = mailbox
        self.from = from
        self.subject = subject
        self.date = date
    }
}

/// Moving messages to Trash, or erasing them from Trash for good.
public struct DeletionRequest: Sendable, Identifiable {
    public let id = UUID()
    public let tool: String
    public let client: String
    public let items: [DeletionItem]
    public let permanent: Bool
    /// Binds the approval to these exact messages.
    public let digest: String

    public init(tool: String, client: String, items: [DeletionItem], permanent: Bool) {
        self.tool = tool
        self.client = client
        self.items = items
        self.permanent = permanent
        self.digest = Self.digest(items.map(\.id), permanent: permanent)
    }

    static func digest(_ ids: [MessageID], permanent: Bool) -> String {
        let text = (permanent ? "erase:" : "trash:") + ids.map(\.opaque).joined(separator: ",")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A deletion the user approved. Only `ApprovalDesk` makes one; the Bridge layer deletes nothing else.
public struct ApprovedDeletion: Sendable {
    public let ids: [MessageID]
    public let permanent: Bool

    init(_ request: DeletionRequest) {
        ids = request.items.map(\.id)
        permanent = request.permanent
    }
}

public enum DeletionOutcome: Sendable {
    case approved(ApprovedDeletion)
    case rejected(reason: String?)
    case expired
    case notAuthenticated
}

/// Shows a request and returns the person's choice. It is cancelled when the request expires.
public protocol ApprovalPresenter: Sendable {
    func present(_ request: ApprovalRequest, deadline: Date) async -> ApprovalIntent
    /// `.send` means "delete"; `.saveAsDraft` is not offered.
    func presentDeletion(_ request: DeletionRequest, deadline: Date) async -> ApprovalIntent
    func presentBatch(_ request: BatchApprovalRequest, deadline: Date) async -> BatchIntent
}

/// Proof that the person at the Mac is the user (Touch ID or Apple Watch, the password only if allowed).
public protocol Authenticating: Sendable {
    func confirm(reason: String) async -> Bool
}

/// A message the user approved. Only `ApprovalDesk` can make one, and the SMTP client sends nothing else.
public struct ApprovedMessage: Sendable {
    public let message: OutgoingMessage
    public let digest: String

    init(_ message: OutgoingMessage) {
        self.message = message
        self.digest = message.digest
    }

    /// The same approved email, dated when it leaves. The digest leaves the Date header out, so it does not change.
    public func leaving(at date: Date) -> ApprovedMessage { ApprovedMessage(message.dated(date)) }

    public var envelopeFrom: String { message.from.email }
    public var recipients: [String] { message.envelopeRecipients }
    /// The bytes that leave: never the Bcc header.
    public var rfc822: Data { message.rfc822(includeBcc: false) }
}

/// An email of a batch the user approved, kept as its digest alone. `redeem` gives back an `ApprovedMessage` for
/// that exact message, composed again when its turn comes, and for no other. Only `ApprovalDesk` makes one.
public struct ApprovedClaim: Sendable, Hashable {
    public let digest: String

    init(digest: String) { self.digest = digest }

    /// The approved email, if `message` is the one the user approved: same bytes but the Date, same envelope.
    public func redeem(_ message: OutgoingMessage) -> ApprovedMessage? {
        message.digest == digest ? ApprovedMessage(message) : nil
    }
}

public enum ApprovalOutcome: Sendable {
    case approved(ApprovedMessage)
    case rejected(reason: String?)
    case saveAsDraft(OutgoingMessage)
    case expired
    /// The person chose Send but did not pass Touch ID.
    case notAuthenticated
}

/// Turns requests into approved messages, one at a time.
///
/// The panel only collects the person's choice; the proof of identity is asked here, after they chose Send, so no
/// interface code can produce an approval without it. Approvals are never cached or reused.
public actor ApprovalDesk {
    private let presenter: any ApprovalPresenter
    private let authenticator: any Authenticating
    private let timeout: Duration
    /// Reading fifty emails takes longer than reading one.
    private let batchTimeout: Duration
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(
        presenter: any ApprovalPresenter, authenticator: any Authenticating, timeout: Duration = .seconds(120),
        batchTimeout: Duration = .seconds(900)
    ) {
        self.presenter = presenter
        self.authenticator = authenticator
        self.timeout = timeout
        self.batchTimeout = batchTimeout
    }

    public func review(_ request: ApprovalRequest) async -> ApprovalOutcome {
        await acquire()
        defer { release() }
        guard request.digest == request.message.digest else { return .rejected(reason: "The message changed.") }
        let presenter = self.presenter
        let intent = await choice { deadline in await presenter.present(request, deadline: deadline) }
        switch intent {
        case .send?:
            let count = request.message.envelopeRecipients.count
            let reason = count == 1
                ? "send this email to \(request.message.envelopeRecipients[0])"
                : "send this email to \(count) people"
            guard await authenticator.confirm(reason: reason) else { return .notAuthenticated }
            return .approved(ApprovedMessage(request.message))
        case .reject(let reason)?:
            return .rejected(reason: reason)
        case .saveAsDraft?:
            return .saveAsDraft(request.message)
        case nil:
            return .expired
        }
    }

    public func reviewDeletion(_ request: DeletionRequest) async -> DeletionOutcome {
        await acquire()
        defer { release() }
        guard !request.items.isEmpty,
              request.digest == DeletionRequest.digest(request.items.map(\.id), permanent: request.permanent) else {
            return .rejected(reason: "Nothing to delete.")
        }
        let presenter = self.presenter
        let intent = await choice { deadline in await presenter.presentDeletion(request, deadline: deadline) }
        switch intent {
        case .send?:
            let count = request.items.count
            let what = count == 1 ? "1 email" : "\(count) emails"
            let reason = request.permanent ? "erase \(what) for good" : "move \(what) to Trash"
            guard await authenticator.confirm(reason: reason) else { return .notAuthenticated }
            return .approved(ApprovedDeletion(request))
        case .reject(let reason)?:
            return .rejected(reason: reason)
        case .saveAsDraft?:
            return .rejected(reason: nil)
        case nil:
            return .expired
        }
    }

    /// Shows every email on one panel; one Touch ID approves the ones left ticked, each bound to its own digest.
    public func reviewBatch(_ request: BatchApprovalRequest) async -> BatchOutcome {
        await acquire()
        defer { release() }
        guard !request.items.isEmpty else { return .rejected(reason: "Nothing to send.") }
        let presenter = self.presenter
        // Fifteen minutes, and a second more per email past 900, up to an hour: thousands take longer to look over.
        let limit = max(batchTimeout, .seconds(min(3600, request.items.count)))
        let intent = await choice(within: limit) { deadline in await presenter.presentBatch(request, deadline: deadline) }
        switch intent {
        case .send(let chosen)?:
            let approved = request.items.filter { chosen.contains($0.id) }
            guard !approved.isEmpty else { return .rejected(reason: nil) }
            let reason = approved.count == 1 ? "send 1 email" : "send \(approved.count) emails"
            guard await authenticator.confirm(reason: reason) else { return .notAuthenticated }
            return .approved(Dictionary(uniqueKeysWithValues: approved.map { ($0.id, ApprovedClaim(digest: $0.digest)) }))
        case .reject(let reason)?:
            return .rejected(reason: reason)
        case nil:
            return .expired
        }
    }

    /// Gives back the approvals of a batch the user approved before Postern quit, once they confirm again with
    /// Touch ID: the same digests, read from the batch Postern sealed on disk, and no others.
    public func resume(_ digests: [String], reason: String) async -> [ApprovedClaim]? {
        await acquire()
        defer { release() }
        guard !digests.isEmpty, await authenticator.confirm(reason: reason) else { return nil }
        return digests.map { ApprovedClaim(digest: $0) }
    }

    /// The person's choice, or nil when the request expired first.
    private func choice<Intent: Sendable>(
        within limit: Duration? = nil, _ present: @escaping @Sendable (Date) async -> Intent
    ) async -> Intent? {
        let timeout = limit ?? self.timeout
        let deadline = Date().addingTimeInterval(Double(timeout.components.seconds))
        return await withTaskGroup(of: Intent?.self) { group in
            group.addTask { await present(deadline) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Approves without a panel when every recipient is on the user's trusted list, which the user can only
    /// extend with Touch ID. Returns nil otherwise.
    public func approveTrusted(_ request: ApprovalRequest, trusted: Set<String>) -> ApprovedMessage? {
        guard !trusted.isEmpty, request.digest == request.message.digest,
              request.message.envelopeRecipients.allSatisfy({ trusted.contains($0.lowercased()) }) else { return nil }
        return ApprovedMessage(request.message)
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
