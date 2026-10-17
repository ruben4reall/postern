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

/// Shows a request and returns the person's choice. It is cancelled when the request expires.
public protocol ApprovalPresenter: Sendable {
    func present(_ request: ApprovalRequest, deadline: Date) async -> ApprovalIntent
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

    public var envelopeFrom: String { message.from.email }
    public var recipients: [String] { message.envelopeRecipients }
    /// The bytes that leave: never the Bcc header.
    public var rfc822: Data { message.rfc822(includeBcc: false) }
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
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(presenter: any ApprovalPresenter, authenticator: any Authenticating, timeout: Duration = .seconds(120)) {
        self.presenter = presenter
        self.authenticator = authenticator
        self.timeout = timeout
    }

    public func review(_ request: ApprovalRequest) async -> ApprovalOutcome {
        await acquire()
        defer { release() }
        guard request.digest == request.message.digest else { return .rejected(reason: "The message changed.") }
        let deadline = Date().addingTimeInterval(Double(timeout.components.seconds))
        let presenter = self.presenter
        let timeout = self.timeout
        let intent: ApprovalIntent? = await withTaskGroup(of: ApprovalIntent?.self) { group in
            group.addTask { await presenter.present(request, deadline: deadline) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
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
