import Foundation

/// What a client may search on. Every field is optional; all given fields must match.
public struct SearchQuery: Codable, Sendable, Equatable {
    public var mailbox: String
    public var from: String?
    public var to: String?
    public var subject: String?
    public var text: String?
    public var since: Date?
    public var before: Date?
    public var unread: Bool?
    public var starred: Bool?

    public init(
        mailbox: String = "INBOX", from: String? = nil, to: String? = nil, subject: String? = nil, text: String? = nil,
        since: Date? = nil, before: Date? = nil, unread: Bool? = nil, starred: Bool? = nil
    ) {
        self.mailbox = mailbox
        self.from = from
        self.to = to
        self.subject = subject
        self.text = text
        self.since = since
        self.before = before
        self.unread = unread
        self.starred = starred
    }
}
