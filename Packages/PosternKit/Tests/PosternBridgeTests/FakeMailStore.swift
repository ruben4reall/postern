import Foundation

/// A mailbox that behaves like Proton through Bridge: each message lives in one folder, carries labels, and shows
/// in label and virtual mailboxes. Moving out of a label removes it; moving into a label adds it and keeps the folder.
final class FakeMailStore: @unchecked Sendable {
    struct Message {
        let messageID: String
        var folder: String
        var labels: Set<String>
        var flags: Set<String>
    }

    private let lock = NSLock()
    private(set) var messages: [Message] = []
    private(set) var mailboxNames: [String] = ["INBOX", "Archive", "Sent", "Drafts", "Trash", "Spam", "All Mail", "Starred", "Folders", "Labels"]
    private var uids: [String: [Int: UInt32]] = [:]
    private var nextUID: [String: UInt32] = [:]
    private(set) var commands: [String] = []

    func add(_ messageID: String, folder: String, labels: Set<String> = [], flags: Set<String> = []) {
        lock.withLock {
            messages.append(Message(messageID: messageID, folder: folder, labels: labels, flags: flags))
            for name in [folder] + Array(labels) where !mailboxNames.contains(name) { mailboxNames.append(name) }
        }
    }

    func addMailbox(_ name: String) { lock.withLock { if !mailboxNames.contains(name) { mailboxNames.append(name) } } }

    func message(_ messageID: String) -> Message? { lock.withLock { messages.first { $0.messageID == messageID } } }

    func record(_ command: String) { lock.withLock { commands.append(command) } }

    var allCommands: [String] { lock.withLock { commands } }

    /// Indexes of the messages a mailbox shows.
    func members(of mailbox: String) -> [Int] {
        lock.withLock { membersLocked(mailbox) }
    }

    private func membersLocked(_ mailbox: String) -> [Int] {
        messages.indices.filter { index in
            let message = messages[index]
            switch mailbox {
            case "All Mail": return true
            case "Starred": return message.flags.contains("\\Flagged")
            default: return message.folder == mailbox || message.labels.contains(mailbox)
            }
        }
    }

    /// The UID of message `index` in `mailbox`, assigned on first sight.
    func uid(of index: Int, in mailbox: String) -> UInt32 {
        lock.withLock { uidLocked(index, mailbox) }
    }

    private func uidLocked(_ index: Int, _ mailbox: String) -> UInt32 {
        if let uid = uids[mailbox]?[index] { return uid }
        let uid = (nextUID[mailbox] ?? 0) + 1
        nextUID[mailbox] = uid
        uids[mailbox, default: [:]][index] = uid
        return uid
    }

    func index(ofUID uid: UInt32, in mailbox: String) -> Int? {
        lock.withLock {
            membersLocked(mailbox).first { uidLocked($0, mailbox) == uid }
        }
    }

    /// Removes a message for good. Indexes of later messages shift, so UID maps are rebuilt for them.
    func remove(index: Int) {
        lock.withLock {
            messages[index].folder = "(removed)"
            messages[index].labels = []
            messages[index].flags = []
        }
    }

    func setFlag(_ flag: String, on: Bool, index: Int) {
        lock.withLock {
            if on { messages[index].flags.insert(flag) } else { messages[index].flags.remove(flag) }
        }
    }

    /// Bridge's MOVE, as Proton documents it. Returns the destination UID.
    func move(index: Int, from source: String, to destination: String) -> UInt32 {
        lock.withLock {
            let isLabel = { (name: String) in name.hasPrefix("Labels/") }
            if isLabel(source) { messages[index].labels.remove(source) }
            // Bridge removes every label from a message added to Trash.
            if destination == "Trash" { messages[index].labels = [] }
            if isLabel(destination) {
                messages[index].labels.insert(destination)
            } else {
                messages[index].folder = destination
            }
            // Like Bridge, a message moved into a mailbox gets a new UID there, even if it was already visible in it.
            uids[destination]?[index] = nil
            return uidLocked(index, destination)
        }
    }
}
