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

    public var tier: Tier {
        switch self {
        case .listMailboxes, .searchMessages, .getMessage, .getThread: .read
        }
    }
}
