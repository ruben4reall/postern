/// The groups of tools the user switches on, from the least to the most powerful.
public enum Tier: String, Codable, Sendable, CaseIterable {
    case read, organize, draft, send, delete
}

/// Every tool Postern can expose. A tool that is not enabled in the policy is never listed to a client.
public enum ToolID: String, Codable, Sendable, CaseIterable {
    case listMailboxes = "list_mailboxes"
    case searchMessages = "search_messages"
    case getMessage = "get_message"
    case getThread = "get_thread"
    case markRead = "mark_read"
    case markUnread = "mark_unread"
    case setStarred = "set_starred"
    case moveMessages = "move_messages"
    case archiveMessages = "archive_messages"
    case addLabel = "add_label"
    case removeLabel = "remove_label"
    case createMailbox = "create_mailbox"

    public var tier: Tier {
        switch self {
        case .listMailboxes, .searchMessages, .getMessage, .getThread: .read
        case .markRead, .markUnread, .setStarred, .moveMessages, .archiveMessages, .addLabel, .removeLabel,
             .createMailbox: .organize
        }
    }
}
