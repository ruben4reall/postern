import PosternModel

/// What the user allows. Lives in the Keychain; only Postern's own interface changes it.
public struct Policy: Codable, Sendable, Equatable {
    public var enabledTools: Set<ToolID>
    /// Mailboxes the client never sees, by display name.
    public var hiddenMailboxes: Set<String>

    public init(enabledTools: Set<ToolID>, hiddenMailboxes: Set<String> = []) {
        self.enabledTools = enabledTools
        self.hiddenMailboxes = hiddenMailboxes
    }

    /// Nothing is allowed until the user turns tools on.
    public static let initial = Policy(enabledTools: [])

    public static let readOnly = Policy(enabledTools: Set(ToolID.allCases.filter { $0.tier == .read }))

    public func allows(_ tool: ToolID) -> Bool { enabledTools.contains(tool) }

    /// `All Mail` and `Starred` show messages from every mailbox, so hiding any mailbox hides them too.
    public func isHidden(_ mailbox: String) -> Bool {
        if hiddenMailboxes.contains(mailbox) { return true }
        if !hiddenMailboxes.isEmpty && Self.aggregateViews.contains(mailbox) { return true }
        return false
    }

    public static let aggregateViews: Set<String> = ["All Mail", "Starred"]
}
