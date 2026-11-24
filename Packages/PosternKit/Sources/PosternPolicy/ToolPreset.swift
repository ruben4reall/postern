import PosternModel

/// A set of tools in one step, the same on every system: what most people want, without reading 34 switches.
/// Mass mailing, saving files to disk and deleting are left out: they stay one switch each.
public enum ToolPreset: String, CaseIterable, Codable, Sendable {
    /// Search, read and summarize. Nothing changes in the mailbox.
    case read
    /// Also sort, file, and write drafts for the user to send.
    case assistant
    /// Also send, each email after the user's approval.
    case full

    public var tools: Set<ToolID> {
        let read: Set<ToolID> = [.listMailboxes, .searchMessages, .getMessage, .getThread, .getMessages, .topSenders,
                                 .awaitingReply, .readAttachment, .listAddresses]
        let organize = Set(ToolID.switchable.filter { $0.tier == .organize })
        let drafts: Set<ToolID> = [.createDraft, .updateDraft, .draftReply, .draftForward]
        let send: Set<ToolID> = [.sendMessage, .replyToMessage, .forwardMessage, .sendDraft]
        switch self {
        case .read: return read
        case .assistant: return read.union(organize).union(drafts)
        case .full: return read.union(organize).union(drafts).union(send)
        }
    }

    /// The preset these tools are exactly, if any.
    public static func matching(_ tools: Set<ToolID>) -> ToolPreset? {
        allCases.first { $0.tools == tools }
    }
}
