import Foundation
import MCP
import PosternModel
import PosternPolicy

/// Runs the organize tools. They change how mail is sorted, never what it says, and refuse anything that touches a
/// mailbox the user hid.
struct OrganizeTools {
    let backend: any MailBackend
    let policy: Policy

    static let maxIDs = 100
    static let maxNameLength = 100

    func call(_ tool: ToolID, _ arguments: [String: Value]) async throws -> CallTool.Result {
        switch tool {
        case .markRead:
            return try await flag(.read, on: true, arguments, done: "Marked %d message(s) as read.")
        case .markUnread:
            return try await flag(.read, on: false, arguments, done: "Marked %d message(s) as unread.")
        case .setStarred:
            let starred = bool(arguments["starred"]) ?? true
            return try await flag(.starred, on: starred, arguments,
                                  done: starred ? "Starred %d message(s)." : "Removed the star from %d message(s).")
        case .moveMessages:
            guard let destination = string(arguments["destination"]) else {
                throw PosternError(.invalidArgument, "destination is required: a folder from list_mailboxes.")
            }
            return try await move(arguments, to: destination)
        case .archiveMessages:
            return try await move(arguments, to: "Archive")
        case .addLabel, .removeLabel:
            guard let name = string(arguments["label"]) else {
                throw PosternError(.invalidArgument, "label is required: a label from list_mailboxes.")
            }
            let label = MailboxNames.label(name)
            try ensureVisible(label)
            let ids = try await visibleIDs(arguments)
            let report = tool == .addLabel
                ? try await backend.addLabel(ids, label: label)
                : try await backend.removeLabel(ids, label: label)
            let verb = tool == .addLabel ? "Added \(label) to" : "Removed \(label) from"
            return result(report, summary: "\(verb) \(report.done.count) message(s).", mailbox: nil)
        case .createMailbox:
            return try await create(arguments)
        default:
            throw PosternError(.invalidArgument, "\(tool.rawValue) is not an organize tool.")
        }
    }

    // MARK: Tools

    private func flag(_ flag: MessageFlag, on: Bool, _ arguments: [String: Value], done: String) async throws -> CallTool.Result {
        let ids = try await visibleIDs(arguments)
        let report = try await backend.setFlag(flag, on: on, ids: ids)
        return result(report, summary: String(format: done, report.done.count), mailbox: nil)
    }

    private func move(_ arguments: [String: Value], to destination: String) async throws -> CallTool.Result {
        guard MailboxNames.isMoveDestination(destination) else {
            let hint = destination == "Trash" || destination == "Spam"
                ? "Moving to \(destination) belongs to the delete tools."
                : "Messages can be moved to Inbox, Archive or a folder under Folders/. Use add_label for labels."
            throw PosternError(.invalidArgument, hint)
        }
        try ensureVisible(destination)
        let ids = try await visibleIDs(arguments)
        let report = try await backend.move(ids, to: destination)
        return result(report, summary: "Moved \(report.done.count) message(s) to \(destination).", mailbox: destination)
    }

    private func create(_ arguments: [String: Value]) async throws -> CallTool.Result {
        guard let kind = string(arguments["kind"]), kind == "folder" || kind == "label" else {
            throw PosternError(.invalidArgument, "kind must be folder or label.")
        }
        guard let raw = string(arguments["name"]) else { throw PosternError(.invalidArgument, "name is required.") }
        let components = raw.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let valid = !components.contains(where: \.isEmpty) && raw.count <= Self.maxNameLength
            && !raw.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }
            && (kind == "folder" || components.count == 1)
        guard valid else {
            throw PosternError(.invalidArgument, kind == "label"
                ? "A label name is one word or phrase without slashes, up to 100 characters."
                : "A folder name is up to 100 characters; use / to create it inside another folder.")
        }
        let name = (kind == "folder" ? "Folders/" : "Labels/") + components.joined(separator: "/")
        let created = try await backend.createMailbox(name)
        let structured: Value = .object(["created": .string(created.name), "kind": .string(created.kind.rawValue)])
        return CallTool.Result(
            content: [.text(text: "Created \(created.name).", annotations: nil, _meta: nil)],
            structuredContent: Optional<Value>.some(structured), isError: false
        )
    }

    // MARK: Helpers

    /// The ids to change, refusing the whole call if any of them sits in a hidden mailbox.
    private func visibleIDs(_ arguments: [String: Value]) async throws -> [MessageID] {
        var texts: [String] = []
        if case .array(let values)? = arguments["ids"] {
            texts = values.compactMap { if case .string(let text) = $0 { text } else { nil } }
        } else if let single = string(arguments["id"]) {
            texts = [single]
        }
        guard !texts.isEmpty else { throw PosternError(.invalidArgument, "ids is required: message ids from search_messages.") }
        guard texts.count <= Self.maxIDs else {
            throw PosternError(.invalidArgument, "At most \(Self.maxIDs) messages per call.")
        }
        let ids = texts.compactMap(MessageID.init(opaque:))
        guard ids.count == texts.count else {
            throw PosternError(.invalidArgument, "\(texts.count - ids.count) id(s) are not Postern message ids.")
        }
        for mailbox in Set(ids.map(\.mailbox)) {
            try ensureVisible(try await backend.displayName(ofRawMailbox: mailbox))
        }
        return Array(NSOrderedSet(array: ids.map(\.opaque)).compactMap { ($0 as? String).flatMap(MessageID.init(opaque:)) })
    }

    private func ensureVisible(_ mailbox: String) throws {
        guard !policy.isHidden(mailbox) else {
            throw PosternError(.scopeHidden, "The user has hidden \(mailbox) from Postern.")
        }
    }

    private func result(_ report: ChangeReport, summary: String, mailbox: String?) -> CallTool.Result {
        var text = summary
        if !report.failed.isEmpty {
            text += " Not done for \(report.failed.count): " + Set(report.failed.map(\.reason)).sorted().joined(separator: " ")
        }
        text += report.verified
            ? " Postern read Bridge again and saw the change."
            : " Bridge accepted it, but Postern could not see every change yet; check again in a moment."
        if !report.done.isEmpty && mailbox != nil { text += " Use the new ids below for further changes." }
        let structured: Value = .object([
            "count": .int(report.done.count),
            "messages": .array(report.done.map { .object(["id": .string($0.opaque)]) }),
            "not_done": .array(report.failed.map { .object(["id": .string($0.id.opaque), "reason": .string($0.reason)]) }),
            "verified": .bool(report.verified),
        ])
        let ids = report.done.map(\.opaque).joined(separator: "\n")
        return CallTool.Result(
            content: [.text(text: ids.isEmpty ? text : text + "\n" + ids, annotations: nil, _meta: nil)],
            structuredContent: Optional<Value>.some(structured), isError: false
        )
    }

    private func string(_ value: Value?) -> String? {
        if case .string(let text)? = value {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private func bool(_ value: Value?) -> Bool? {
        if case .bool(let flag)? = value { return flag }
        return nil
    }
}
