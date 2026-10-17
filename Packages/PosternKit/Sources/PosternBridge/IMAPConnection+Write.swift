import Foundation
import NIOCore
import NIOIMAP

/// A flag change Postern can make. Read state and the star are properties of the message in Proton, so they can be
/// set from any mailbox the message appears in.
public enum FlagChange: Sendable, Equatable {
    case read(Bool)
    case starred(Bool)
}

extension IMAPConnection {
    /// Opens a mailbox for changes.
    public func select(_ mailbox: BridgeMailbox) async throws -> MailboxStatusInfo {
        let reply = try await sendCommand(.select(MailboxName(Array(mailbox.raw.utf8))))
        guard reply.isOK else { throw BridgeError.mailboxNotFound(mailbox.display) }
        return try Self.status(from: reply, mailbox: mailbox)
    }

    /// Changes a flag on messages of the selected mailbox. `.SILENT`: Bridge does not echo every flag back.
    public func store(_ change: FlagChange, uids: [UInt32]) async throws {
        guard let set = Self.uidSet(uids) else { return }
        let flags: StoreFlags = switch change {
        case .read(true): .add(silent: true, list: [.seen])
        case .read(false): .remove(silent: true, list: [.seen])
        case .starred(true): .add(silent: true, list: [.flagged])
        case .starred(false): .remove(silent: true, list: [.flagged])
        }
        let reply = try await sendCommand(.uidStore(.set(set), [], .flags(flags)))
        guard reply.isOK else { throw BridgeError.commandFailed(reply.tagged.state.text) }
    }

    /// Moves messages of the selected mailbox. Returns the new UIDs Bridge reported (COPYUID), keyed by old UID.
    public func move(uids: [UInt32], to destination: BridgeMailbox) async throws -> [UInt32: UInt32] {
        guard let set = Self.uidSet(uids) else { return [:] }
        let reply = try await sendCommand(.uidMove(.set(set), MailboxName(Array(destination.raw.utf8))))
        guard reply.isOK else { throw BridgeError.commandFailed(reply.tagged.state.text) }
        return Self.copyUIDs(in: reply)
    }

    /// Creates `Folders/...` or `Labels/...`, encoding non-ASCII names the way IMAP requires.
    public func create(path components: [String]) async throws -> BridgeMailbox {
        guard let first = components.first else { throw BridgeError.commandFailed("Empty mailbox name") }
        var path = try MailboxPath.makeRootMailbox(displayName: first, pathSeparator: "/")
        for component in components.dropFirst() { path = try path.makeSubMailbox(displayName: component) }
        let reply = try await sendCommand(.create(path.name, []))
        guard reply.isOK else { throw BridgeError.commandFailed(reply.tagged.state.text) }
        let mailboxes = try await mailboxes(refresh: true)
        let display = components.joined(separator: "/")
        guard let created = mailboxes.first(where: { $0.display == display }) else {
            throw BridgeError.mailboxNotFound(display)
        }
        return created
    }

    /// UIDs in the examined or selected mailbox whose Message-ID is `messageID`.
    public func uids(withMessageID messageID: String) async throws -> [UInt32] {
        try await uidSearch(.header("Message-ID", ByteBuffer(string: messageID)))
    }

    /// The Message-ID header of each UID, read from the envelope.
    public func messageIDs(_ uids: [UInt32]) async throws -> [UInt32: String] {
        guard let set = Self.uidSet(uids) else { return [:] }
        let reply = try await sendCommand(.uidFetch(.set(set), [.uid, .envelope], []))
        guard reply.isOK else { throw BridgeError.commandFailed(reply.tagged.state.text) }
        var result: [UInt32: String] = [:]
        for summary in FetchAssembler.summaries(from: reply.responses) {
            if let uid = summary.uid, let id = summary.messageID { result[uid] = id }
        }
        return result
    }

    static func status(from reply: CommandResult, mailbox: BridgeMailbox) throws -> MailboxStatusInfo {
        var validity: UInt32?
        var exists = 0
        for response in reply.responses {
            switch response {
            case .untagged(.conditionalState(.ok(let text))):
                if case .uidValidity(let value)? = text.code { validity = UInt32(value) }
            case .untagged(.mailboxData(.exists(let count))):
                exists = count
            default:
                break
            }
        }
        if case .ok(let text) = reply.tagged.state, case .uidValidity(let value)? = text.code { validity = UInt32(value) }
        guard let validity else { throw BridgeError.commandFailed("No UIDVALIDITY for \(mailbox.display)") }
        return MailboxStatusInfo(uidValidity: validity, exists: exists)
    }

    static func copyUIDs(in reply: CommandResult) -> [UInt32: UInt32] {
        var codes: [ResponseCodeCopy] = []
        if case .ok(let text) = reply.tagged.state, case .uidCopy(let code)? = text.code { codes.append(code) }
        for case .untagged(.conditionalState(.ok(let text))) in reply.responses {
            if case .uidCopy(let code)? = text.code { codes.append(code) }
        }
        var mapping: [UInt32: UInt32] = [:]
        for code in codes {
            let sources = code.sourceUIDs.flatMap { range in (range.lowerBound.rawValue...range.upperBound.rawValue).map { $0 } }
            let destinations = code.destinationUIDs.flatMap { range in
                (range.lowerBound.rawValue...range.upperBound.rawValue).map { $0 }
            }
            for (source, destination) in zip(sources, destinations) { mapping[source] = destination }
        }
        return mapping
    }
}

extension IMAPConnection {
    /// Saves a message as a draft (APPEND with `\Draft \Seen`). Returns its UID in Drafts when Bridge reports it.
    public func appendDraft(_ bytes: Data, to drafts: BridgeMailbox) async throws -> (validity: UInt32, uid: UInt32)? {
        try await append(bytes, to: drafts, flags: [.draft, .seen])
    }

    /// APPEND a message to a mailbox. Returns its UID when Bridge reports it (APPENDUID).
    public func append(_ bytes: Data, to mailbox: BridgeMailbox, flags: [Flag]) async throws -> (validity: UInt32, uid: UInt32)? {
        let drafts = mailbox
        let parts: [CommandStreamPart] = [
            .append(.beginMessage(message: AppendMessage(
                options: AppendOptions(flagList: flags), data: AppendData(byteCount: bytes.count)
            ))),
            .append(.messageBytes(ByteBuffer(bytes: bytes))),
            .append(.endMessage),
            .append(.finish),
        ]
        let reply = try await sendAppend(to: MailboxName(Array(drafts.raw.utf8)), parts: parts)
        guard reply.isOK else { throw BridgeError.commandFailed(reply.tagged.state.text) }
        if case .ok(let text) = reply.tagged.state, case .uidAppend(let code)? = text.code,
           let uid = code.uids.set.first {
            return (UInt32(code.uidValidity), uid.rawValue)
        }
        return nil
    }

    /// Removes drafts from Drafts: flagged deleted, then expunged by UID so no other message is touched.
    /// Only ever called on the Drafts mailbox, which must be selected.
    public func deleteDrafts(uids: [UInt32]) async throws {
        try await expunge(uids: uids)
    }

    /// Flags these UIDs of the selected mailbox deleted and expunges exactly them (UIDPLUS). Used for Drafts and for
    /// approved erasure in Trash and Spam only.
    func expunge(uids: [UInt32]) async throws {
        guard let set = Self.uidSet(uids) else { return }
        let flagged = try await sendCommand(.uidStore(.set(set), [], .flags(.add(silent: true, list: [.deleted]))))
        guard flagged.isOK else { throw BridgeError.commandFailed(flagged.tagged.state.text) }
        let expunged = try await sendCommand(.uidExpunge(.set(set)))
        guard expunged.isOK else { throw BridgeError.commandFailed(expunged.tagged.state.text) }
    }
}
