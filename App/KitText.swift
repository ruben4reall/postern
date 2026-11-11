import Foundation
import PosternModel

/// Postern's core writes its messages in English, for the apps that read them. The window, the panels and the Touch ID
/// prompt show the ones it knows in the user's language, and any other as it is.
enum KitText {
    static func localize(_ text: String) -> String {
        for rule in rules {
            if let result = rule(text) { return result }
        }
        return text
    }

    /// A sentence for the user from an error, in their language when Postern knows the code.
    static func error(_ error: PosternError) -> String {
        switch error.code {
        case .bridgeUnreachable:
            String(localized: "Postern can't reach Proton Mail Bridge. Open Bridge on this Mac, then try again.")
        case .certificateMismatch:
            String(localized: "Bridge answered with a certificate Postern doesn't trust. Run setup again if you reinstalled Bridge.")
        case .authenticationFailed:
            String(localized: "Bridge refused the password Postern has. Run setup again with the password Bridge shows now.")
        case .notConfigured:
            String(localized: "Postern isn't set up yet.")
        default:
            localize(error.message)
        }
    }

    /// A mailbox as Proton names it in the user's language: its own folders as they are, without the prefix.
    static func mailbox(_ name: String) -> String {
        switch name {
        case "INBOX": return String(localized: "mailbox.inbox", defaultValue: "Inbox", comment: "Proton's folder, as Proton names it")
        case "Sent": return String(localized: "mailbox.sent", defaultValue: "Sent", comment: "Proton's folder, as Proton names it")
        case "Drafts": return String(localized: "mailbox.drafts", defaultValue: "Drafts", comment: "Proton's folder, as Proton names it")
        case "Archive": return String(localized: "mailbox.archive", defaultValue: "Archive", comment: "Proton's folder, as Proton names it")
        case "Trash": return String(localized: "mailbox.trash", defaultValue: "Trash", comment: "Proton's folder, as Proton names it")
        case "Spam": return String(localized: "mailbox.spam", defaultValue: "Spam", comment: "Proton's folder, as Proton names it")
        case "All Mail": return String(localized: "mailbox.all", defaultValue: "All Mail", comment: "Proton's view, as Proton names it")
        case "Starred": return String(localized: "mailbox.starred", defaultValue: "Starred", comment: "Proton's view, as Proton names it")
        default: break
        }
        return name.replacingOccurrences(of: "Folders/", with: "").replacingOccurrences(of: "Labels/", with: "").replacingOccurrences(of: "/", with: " › ")
    }

    private static let rules: [@Sendable (String) -> String?] = [
        // The Touch ID prompt, completing "“Postern” is trying to …".
        { text in
            text.wholeMatch(of: #/send this email to (\d+) people/#).flatMap { Int($0.1) }.map {
                String(localized: "send this email to \($0) people", comment: "Touch ID: “Postern” is trying to …")
            }
        },
        { text in
            text.wholeMatch(of: #/send this email to (.+)/#).map {
                String(localized: "send this email to \(String($0.1))", comment: "Touch ID: “Postern” is trying to … (an address)")
            }
        },
        { text in
            count(text, #/erase (\d+) emails? for good/#).map {
                String(localized: "erase \($0) emails for good", comment: "Touch ID: “Postern” is trying to …")
            }
        },
        { text in
            count(text, #/move (\d+) emails? to Trash/#).map {
                String(localized: "move \($0) emails to Trash", comment: "Touch ID: “Postern” is trying to …")
            }
        },
        { text in
            count(text, #/send (\d+) emails?/#).map {
                String(localized: "send \($0) emails", comment: "Touch ID: “Postern” is trying to …")
            }
        },
        { text in
            text.wholeMatch(of: #/resume sending (\d+) emails? approved on (.+)/#).flatMap { match in
                Int(match.1).map {
                    String(localized: "resume sending \($0) emails approved on \(String(match.2))",
                           comment: "Touch ID: “Postern” is trying to … (a count, then a date)")
                }
            }
        },
        // What an email on the approval panel is.
        { text in
            text == "A draft saved in Drafts" ? String(localized: "A draft saved in Drafts") : nil
        },
        { text in
            text.wholeMatch(of: #/Reply to (.+?): (.*)/#).map {
                String(localized: "Reply to \(String($0.1)): \(String($0.2))", comment: "On the approval panel: the sender, then the subject")
            }
        },
        { text in
            text.wholeMatch(of: #/Forward of (.+?): (.*)/#).map {
                String(localized: "Forward of \(String($0.1)): \(String($0.2))", comment: "On the approval panel: the sender, then the subject")
            }
        },
        // Why a batch waits.
        { text in
            count(text, #/Postern restarted\. Resume the batch in Postern's window to send the (\d+) emails? left\./#).map {
                String(localized: "Postern restarted. Resume the batch to send the \($0) emails left.")
            }
        },
        { text in
            text == "Postern is reading the drafts for the approval panel."
                ? String(localized: "Postern is reading the drafts for the approval panel.") : nil
        },
        { text in
            count(text, #/The approval panel is open on the Mac: (\d+) emails? wait for the user's answer\./#).map {
                String(localized: "The approval panel is open: \($0) emails wait for your answer.")
            }
        },
        { text in
            text == "The batch starts at the time the user approved."
                ? String(localized: "The batch starts at the time you approved.") : nil
        },
        { text in
            text.wholeMatch(of: #/The next email could not be handed to Bridge; Postern tries again\.\s*(.*)/#).map {
                let detail = String($0.1)
                let sentence = String(localized: "The next email could not be handed to Bridge; Postern tries again.")
                return detail.isEmpty ? sentence : sentence + " " + detail
            }
        },
        { text in
            text == "Postern is paused; the batch goes on when the user resumes it."
                ? String(localized: "Postern is paused; the batch goes on when you resume it.") : nil
        },
        { text in
            text == "send_drafts is off in Postern; the batch goes on when the user turns it back on."
                ? String(localized: "Send drafts together is off; the batch goes on when you turn it back on.") : nil
        },
        { text in
            text.wholeMatch(of: #/The user's sending limit is reached \((\d+) per hour, (\d+) per day\)\./#).flatMap { match in
                guard let hour = Int(match.1), let day = Int(match.2) else { return nil }
                return String(localized: "Your sending limit is reached (\(hour) per hour, \(day) per day).")
            }
        },
    ]

    private static func count(_ text: String, _ pattern: Regex<(Substring, Substring)>) -> Int? {
        text.wholeMatch(of: pattern).flatMap { Int($0.1) }
    }
}
