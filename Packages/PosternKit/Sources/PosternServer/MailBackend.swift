import Foundation
import PosternModel

/// The mailbox as the MCP tools see it. The app implements it over Bridge and the parser service.
public protocol MailBackend: Sendable {
    func listMailboxes() async throws -> [MailboxInfo]
    /// Newest first. `offset` skips that many matches.
    func search(_ query: SearchQuery, limit: Int, offset: Int) async throws -> (items: [MessageSummary], total: Int)
    func message(_ id: MessageID, maxChars: Int) async throws -> SanitizedMessage
    func thread(_ id: MessageID) async throws -> [MessageSummary]
    /// The display name of a raw IMAP mailbox name, to apply the user's hidden mailboxes.
    func displayName(ofRawMailbox raw: String) async throws -> String

    // Organize. Each returns the messages changed, with their current ids, and what could not be done.
    func setFlag(_ flag: MessageFlag, on: Bool, ids: [MessageID]) async throws -> ChangeReport
    func move(_ ids: [MessageID], to mailbox: String) async throws -> ChangeReport
    func addLabel(_ ids: [MessageID], label: String) async throws -> ChangeReport
    func removeLabel(_ ids: [MessageID], label: String) async throws -> ChangeReport
    func createMailbox(_ name: String) async throws -> MailboxInfo
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
