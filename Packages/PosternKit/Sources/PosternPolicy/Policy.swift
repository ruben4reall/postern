import PosternModel

/// What the user allows. Lives in the Keychain; only Postern's own interface changes it.
public struct Policy: Codable, Sendable, Equatable {
    public var enabledTools: Set<ToolID>
    /// Mailboxes the client never sees, by display name.
    public var hiddenMailboxes: Set<String>
    /// Every tool is suspended: the list is empty and calls are refused.
    public var paused: Bool
    /// Pause as soon as the screen locks.
    public var pauseWhenLocked: Bool
    /// Accept the Mac's password when Touch ID or an Apple Watch is not available.
    public var allowPasswordFallback: Bool
    /// Sends whose every recipient is here skip the approval panel. Empty by default.
    public var trustedRecipients: Set<String>
    /// When not empty, nobody else can receive mail through Postern.
    public var allowedRecipients: Set<String>
    public var sendsPerHour: Int
    public var sendsPerDay: Int

    public static let defaultSendsPerHour = 10
    public static let defaultSendsPerDay = 30

    public init(
        enabledTools: Set<ToolID>, hiddenMailboxes: Set<String> = [], paused: Bool = false,
        pauseWhenLocked: Bool = false, allowPasswordFallback: Bool = false, trustedRecipients: Set<String> = [],
        allowedRecipients: Set<String> = [], sendsPerHour: Int = Policy.defaultSendsPerHour,
        sendsPerDay: Int = Policy.defaultSendsPerDay
    ) {
        self.enabledTools = enabledTools
        self.hiddenMailboxes = hiddenMailboxes
        self.paused = paused
        self.pauseWhenLocked = pauseWhenLocked
        self.allowPasswordFallback = allowPasswordFallback
        self.trustedRecipients = Set(trustedRecipients.map { $0.lowercased() })
        self.allowedRecipients = Set(allowedRecipients.map { $0.lowercased() })
        self.sendsPerHour = sendsPerHour
        self.sendsPerDay = sendsPerDay
    }

    /// Fields added after the first release decode with their safe default, so an older policy still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabledTools = try container.decode(Set<ToolID>.self, forKey: .enabledTools)
        hiddenMailboxes = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenMailboxes) ?? []
        paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        pauseWhenLocked = try container.decodeIfPresent(Bool.self, forKey: .pauseWhenLocked) ?? false
        allowPasswordFallback = try container.decodeIfPresent(Bool.self, forKey: .allowPasswordFallback) ?? false
        trustedRecipients = try container.decodeIfPresent(Set<String>.self, forKey: .trustedRecipients) ?? []
        allowedRecipients = try container.decodeIfPresent(Set<String>.self, forKey: .allowedRecipients) ?? []
        sendsPerHour = try container.decodeIfPresent(Int.self, forKey: .sendsPerHour) ?? Self.defaultSendsPerHour
        sendsPerDay = try container.decodeIfPresent(Int.self, forKey: .sendsPerDay) ?? Self.defaultSendsPerDay
    }

    /// Whether this address may receive mail through Postern.
    public func mayReceive(_ email: String) -> Bool {
        allowedRecipients.isEmpty || allowedRecipients.contains(email.lowercased())
    }

    /// Nothing is allowed until the user turns tools on.
    public static let initial = Policy(enabledTools: [])

    /// What setup turns on: reading only. Saving attachments to disk has its own switch.
    public static let readOnly = Policy(enabledTools: [.listMailboxes, .searchMessages, .getMessage, .getThread])

    public func allows(_ tool: ToolID) -> Bool { !paused && enabledTools.contains(tool) }

    /// `All Mail` and `Starred` show messages from every mailbox, so hiding any mailbox hides them too.
    public func isHidden(_ mailbox: String) -> Bool {
        if hiddenMailboxes.contains(mailbox) { return true }
        if !hiddenMailboxes.isEmpty && Self.aggregateViews.contains(mailbox) { return true }
        return false
    }

    public static let aggregateViews: Set<String> = ["All Mail", "Starred"]

    /// True when going from `old` to this policy gives clients more than they had, or weakens the proof asked of
    /// the user. Such a change needs the user's fingerprint; a change that only takes power away never does.
    public func addsPower(over old: Policy) -> Bool {
        if !enabledTools.isSubset(of: old.enabledTools) { return true }
        if !old.hiddenMailboxes.isSubset(of: hiddenMailboxes) { return true }
        if old.paused && !paused { return true }
        if old.pauseWhenLocked && !pauseWhenLocked { return true }
        if allowPasswordFallback && !old.allowPasswordFallback { return true }
        if !trustedRecipients.isSubset(of: old.trustedRecipients) { return true }
        if !old.allowedRecipients.isEmpty && (allowedRecipients.isEmpty || !allowedRecipients.isSubset(of: old.allowedRecipients)) {
            return true
        }
        if sendsPerHour > old.sendsPerHour || sendsPerDay > old.sendsPerDay { return true }
        return false
    }
}
