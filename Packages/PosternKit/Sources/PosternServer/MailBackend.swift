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
}
