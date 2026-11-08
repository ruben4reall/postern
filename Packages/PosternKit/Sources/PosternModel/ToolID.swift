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
    case createDraft = "create_draft"
    case createDrafts = "create_drafts"
    case updateDraft = "update_draft"
    case deleteDraft = "delete_draft"
    case sendMessage = "send_message"
    case replyToMessage = "reply_to_message"
    case forwardMessage = "forward_message"
    case sendDraft = "send_draft"
    case sendDrafts = "send_drafts"
    case saveAttachment = "save_attachment"
    case listAddresses = "list_addresses"
    case listOutbox = "list_outbox"
    case batchStatus = "batch_status"
    case cancelBatch = "cancel_batch"
    case trashMessages = "trash_messages"
    case deletePermanently = "delete_permanently"

    public var tier: Tier {
        switch self {
        case .listMailboxes, .searchMessages, .getMessage, .getThread, .saveAttachment, .listAddresses: .read
        case .markRead, .markUnread, .setStarred, .moveMessages, .archiveMessages, .addLabel, .removeLabel,
             .createMailbox: .organize
        case .createDraft, .createDrafts, .updateDraft, .deleteDraft, .listOutbox, .batchStatus: .draft
        case .sendMessage, .replyToMessage, .forwardMessage, .sendDraft, .sendDrafts, .cancelBatch: .send
        case .trashMessages, .deletePermanently: .delete
        }
    }

    /// A companion has no switch of its own: it is on whenever one of these tools is.
    public var companionOf: Set<ToolID>? {
        switch self {
        case .listOutbox: [.createDraft, .createDrafts, .updateDraft, .sendMessage]
        case .batchStatus, .cancelBatch: [.createDrafts, .sendDrafts]
        default: nil
        }
    }

    /// The tools the user turns on and off one by one.
    public static var switchable: [ToolID] { allCases.filter { $0.companionOf == nil } }
}
