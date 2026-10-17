/// How Bridge names Proton's mailboxes: a message lives in exactly one folder (the system folders or `Folders/...`),
/// carries any number of labels (`Labels/...`), and also shows in virtual views such as All Mail and Starred.
public enum MailboxNames {
    public static let systemFolders: Set<String> = ["INBOX", "Archive", "Sent", "Drafts", "Trash", "Spam"]

    public static func isFolder(_ name: String) -> Bool {
        systemFolders.contains(name) || (name.hasPrefix("Folders/") && name.count > 8)
    }

    public static func isLabel(_ name: String) -> Bool {
        name.hasPrefix("Labels/") && name.count > 7
    }

    /// Where `move_messages` may send mail. Trash and Spam belong to the delete tools; Sent and Drafts are Proton's.
    public static func isMoveDestination(_ name: String) -> Bool {
        name == "INBOX" || name == "Archive" || (name.hasPrefix("Folders/") && name.count > 8)
    }

    /// `Work` and `Labels/Work` both name the label `Labels/Work`.
    public static func label(_ name: String) -> String {
        name.hasPrefix("Labels/") ? name : "Labels/" + name
    }
}
