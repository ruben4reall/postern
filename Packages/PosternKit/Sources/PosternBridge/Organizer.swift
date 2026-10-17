import Foundation
import NIOCore
import NIOIMAP
import PosternModel

/// What a change did, message by message, and whether Postern saw the result when it read Bridge again.
public struct OrganizeResult: Sendable, Equatable {
    public struct Failure: Sendable, Equatable {
        public let id: PosternModel.MessageID
        public let reason: String
    }

    /// The messages changed, with the id that finds them now.
    public var done: [PosternModel.MessageID] = []
    public var failed: [Failure] = []
    /// Bridge acknowledges some changes before Proton applies them: Postern reads the result back.
    public var verified = true

    public init() {}
}

/// Bridge's mailbox roles, from `MailboxNames`.
public enum MailboxRole {
    public static func isFolder(_ display: String) -> Bool { MailboxNames.isFolder(display) }
    public static func isLabel(_ display: String) -> Bool { MailboxNames.isLabel(display) }
    public static func isMoveDestination(_ display: String) -> Bool { MailboxNames.isMoveDestination(display) }
}

/// Organizes mail through Bridge without side effects on labels.
///
/// In Bridge, moving a message out of a label mailbox removes that label (Proton's documented behavior). So every
/// change starts from the folder where the message really lives, found by its Message-ID when the client's id points
/// at a label or a virtual view. Removing a label moves the message from the label back to its own folder, the one
/// documented way that keeps everything else in place. Each change is read back afterwards.
public struct Organizer: Sendable {
    let connection: IMAPConnection

    public init(connection: IMAPConnection) {
        self.connection = connection
    }

    // MARK: Flags

    public func setFlag(_ change: FlagChange, ids: [PosternModel.MessageID]) async throws -> OrganizeResult {
        var result = OrganizeResult()
        for (mailbox, group) in try await groups(ids, into: &result) {
            let status = try await connection.select(mailbox)
            let (valid, stale) = group.partitioned { $0.uidValidity == status.uidValidity }
            result.failed += stale.map { .init(id: $0, reason: "Out of date: search again.") }
            guard !valid.isEmpty else { continue }
            try await connection.store(change, uids: valid.map(\.uid))
            let flags = try await connection.flags(valid.map(\.uid))
            for id in valid {
                result.done.append(id)
                let current = flags[id.uid] ?? []
                let applied: Bool = switch change {
                case .read(let read): current.contains("\\seen") == read
                case .starred(let starred): current.contains("\\flagged") == starred
                }
                if !applied { result.verified = false }
            }
        }
        return result
    }

    // MARK: Moving

    public func move(_ ids: [PosternModel.MessageID], to destination: BridgeMailbox) async throws -> OrganizeResult {
        var result = OrganizeResult()
        let located = try await locate(ids, into: &result)
        let destinationStatus = try await connection.examine(destination)
        var bySource: [BridgeMailbox: [(PosternModel.MessageID, UInt32, String?)]] = [:]
        for item in located {
            if item.folder == destination {
                result.done.append(PosternModel.MessageID(mailbox: destination.raw, uidValidity: destinationStatus.uidValidity, uid: item.uid))
            } else {
                bySource[item.folder, default: []].append((item.id, item.uid, item.messageID))
            }
        }
        for (source, items) in bySource {
            _ = try await connection.select(source)
            let mapping = try await connection.move(uids: items.map(\.1), to: destination)
            for item in items {
                if let uid = mapping[item.1] {
                    result.done.append(PosternModel.MessageID(mailbox: destination.raw, uidValidity: destinationStatus.uidValidity, uid: uid))
                } else {
                    result.done.append(item.0)
                }
            }
        }
        // Read back: every moved message must now be in the destination.
        _ = try await connection.examine(destination)
        for item in located where item.folder != destination {
            guard let messageID = item.messageID else { continue }
            if try await connection.uids(withMessageID: messageID).isEmpty { result.verified = false }
        }
        return result
    }

    // MARK: Labels

    /// Applies a label by moving the message from its folder into the label: Proton keeps it in the folder too.
    public func addLabel(_ ids: [PosternModel.MessageID], label: BridgeMailbox) async throws -> OrganizeResult {
        var result = OrganizeResult()
        let located = try await locate(ids, into: &result)
        for (folder, items) in Dictionary(grouping: located, by: \.folder) {
            _ = try await connection.select(folder)
            _ = try await connection.move(uids: items.map(\.uid), to: label)
            result.done += items.map(\.id)
        }
        // Read back: in the label, and still in its folder.
        for item in located {
            guard let messageID = item.messageID else { continue }
            _ = try await connection.examine(label)
            let inLabel = try await connection.uids(withMessageID: messageID)
            _ = try await connection.examine(item.folder)
            let inFolder = try await connection.uids(withMessageID: messageID)
            if inLabel.isEmpty || inFolder.isEmpty { result.verified = false }
        }
        return result
    }

    /// Removes a label by moving the message from the label back to its own folder.
    public func removeLabel(_ ids: [PosternModel.MessageID], label: BridgeMailbox) async throws -> OrganizeResult {
        var result = OrganizeResult()
        let located = try await locate(ids, into: &result)
        _ = try await connection.examine(label)
        var inLabel: [(item: Located, labelUID: UInt32)] = []
        for item in located {
            guard let messageID = item.messageID,
                  let uid = try await connection.uids(withMessageID: messageID).first else {
                result.done.append(item.id)
                continue
            }
            inLabel.append((item, uid))
        }
        for (folder, entries) in Dictionary(grouping: inLabel, by: \.item.folder) {
            _ = try await connection.select(label)
            _ = try await connection.move(uids: entries.map(\.labelUID), to: folder)
            result.done += entries.map(\.item.id)
        }
        // Read back: gone from the label, still in its folder.
        for entry in inLabel {
            guard let messageID = entry.item.messageID else { continue }
            _ = try await connection.examine(label)
            let stillLabelled = try await connection.uids(withMessageID: messageID)
            _ = try await connection.examine(entry.item.folder)
            let inFolder = try await connection.uids(withMessageID: messageID)
            if !stillLabelled.isEmpty || inFolder.isEmpty { result.verified = false }
        }
        return result
    }

    public func create(folder components: [String]) async throws -> BridgeMailbox {
        try await connection.create(path: ["Folders"] + components)
    }

    public func create(label name: String) async throws -> BridgeMailbox {
        try await connection.create(path: ["Labels", name])
    }

    // MARK: Locating

    struct Located: Sendable {
        let id: PosternModel.MessageID
        let folder: BridgeMailbox
        let uid: UInt32
        let messageID: String?
    }

    /// The ids grouped by the mailbox they point at, dropping ids whose mailbox no longer exists.
    func groups(
        _ ids: [PosternModel.MessageID], into result: inout OrganizeResult
    ) async throws -> [(BridgeMailbox, [PosternModel.MessageID])] {
        let mailboxes = try await connection.mailboxes()
        var groups: [BridgeMailbox: [PosternModel.MessageID]] = [:]
        for id in ids {
            guard let mailbox = mailboxes.first(where: { $0.raw == id.mailbox }) else {
                result.failed.append(.init(id: id, reason: "Its mailbox no longer exists."))
                continue
            }
            groups[mailbox, default: []].append(id)
        }
        return groups.map { ($0.key, $0.value) }.sorted { $0.0.display < $1.0.display }
    }

    /// Finds the folder each message lives in. Ids already pointing at a folder are taken as they are; the others
    /// are found by Message-ID, folder by folder, Inbox and Archive first.
    func locate(_ ids: [PosternModel.MessageID], into result: inout OrganizeResult) async throws -> [Located] {
        let mailboxes = try await connection.mailboxes()
        var located: [Located] = []
        var pending: [(id: PosternModel.MessageID, messageID: String)] = []
        for (mailbox, group) in try await groups(ids, into: &result) {
            let status = try await connection.examine(mailbox)
            let (valid, stale) = group.partitioned { $0.uidValidity == status.uidValidity }
            result.failed += stale.map { .init(id: $0, reason: "Out of date: search again.") }
            guard !valid.isEmpty else { continue }
            let messageIDs = try await connection.messageIDs(valid.map(\.uid))
            for id in valid {
                if MailboxRole.isFolder(mailbox.display) {
                    located.append(Located(id: id, folder: mailbox, uid: id.uid, messageID: messageIDs[id.uid]))
                } else if let messageID = messageIDs[id.uid] {
                    pending.append((id, messageID))
                } else {
                    result.failed.append(.init(id: id, reason: "This message has no Message-ID, so its folder can't be found."))
                }
            }
        }
        guard !pending.isEmpty else { return located }
        let order = mailboxes.filter { MailboxRole.isFolder($0.display) }.sorted { rank($0.display) < rank($1.display) }
        for folder in order where !pending.isEmpty {
            _ = try await connection.examine(folder)
            guard let key = SearchKeyBuilder.messageIDs(pending.map(\.messageID)) else { break }
            let uids = try await connection.uidSearch(key)
            guard !uids.isEmpty else { continue }
            let found = try await connection.messageIDs(uids)
            pending.removeAll { entry in
                guard let uid = found.first(where: { $0.value == entry.messageID })?.key else { return false }
                located.append(Located(id: entry.id, folder: folder, uid: uid, messageID: entry.messageID))
                return true
            }
        }
        result.failed += pending.map { .init(id: $0.id, reason: "Postern couldn't find the folder this message is in.") }
        return located
    }

    private func rank(_ display: String) -> Int {
        switch display {
        case "INBOX": 0
        case "Archive": 1
        case "Sent": 3
        case "Drafts": 4
        case "Spam": 5
        case "Trash": 6
        default: 2
        }
    }
}

extension IMAPConnection {
    /// Lowercased flags of each UID in the selected mailbox.
    public func flags(_ uids: [UInt32]) async throws -> [UInt32: Set<String>] {
        guard let set = Self.uidSet(uids) else { return [:] }
        let reply = try await sendCommand(.uidFetch(.set(set), [.uid, .flags], []))
        guard reply.isOK else { throw BridgeError.commandFailed(reply.tagged.state.text) }
        var result: [UInt32: Set<String>] = [:]
        for summary in FetchAssembler.summaries(from: reply.responses) {
            if let uid = summary.uid { result[uid] = Set(summary.flags.map { $0.lowercased() }) }
        }
        return result
    }
}

extension SearchKeyBuilder {
    /// Any of these Message-IDs.
    public static func messageIDs(_ ids: [String]) -> SearchKey? {
        let keys = ids.map { SearchKey.header("Message-ID", ByteBuffer(string: $0)) }
        guard var combined = keys.first else { return nil }
        for key in keys.dropFirst() { combined = .or(combined, key) }
        return combined
    }
}

extension Array {
    func partitioned(_ isIncluded: (Element) -> Bool) -> ([Element], [Element]) {
        var included: [Element] = []
        var excluded: [Element] = []
        for element in self {
            if isIncluded(element) { included.append(element) } else { excluded.append(element) }
        }
        return (included, excluded)
    }
}
