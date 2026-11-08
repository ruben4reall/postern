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
    /// Messages a search can change in one call; they are changed a hundred at a time.
    static let maxSearched = 1000
    let renderer = UntrustedRenderer()

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
            let verb = tool == .addLabel ? "add \(label) to" : "remove \(label) from"
            let targets = try await visibleIDs(arguments)
            if let preview = targets.preview { return dryRun(preview, total: targets.total, action: verb) }
            let report = try await inChunks(targets.ids) { ids in
                tool == .addLabel ? try await backend.addLabel(ids, label: label) : try await backend.removeLabel(ids, label: label)
            }
            let done = tool == .addLabel ? "Added \(label) to" : "Removed \(label) from"
            return result(report, summary: "\(done) \(report.done.count) message(s).", mailbox: nil)
        case .createMailbox:
            return try await create(arguments)
        default:
            throw PosternError(.invalidArgument, "\(tool.rawValue) is not an organize tool.")
        }
    }

    // MARK: Tools

    private func flag(_ flag: MessageFlag, on: Bool, _ arguments: [String: Value], done: String) async throws -> CallTool.Result {
        let targets = try await visibleIDs(arguments)
        if let preview = targets.preview {
            let action = flag == .read ? (on ? "mark as read" : "mark as unread") : (on ? "star" : "unstar")
            return dryRun(preview, total: targets.total, action: action)
        }
        let report = try await inChunks(targets.ids) { ids in try await backend.setFlag(flag, on: on, ids: ids) }
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
        let targets = try await visibleIDs(arguments)
        if let preview = targets.preview { return dryRun(preview, total: targets.total, action: "move to \(destination)") }
        let report = try await inChunks(targets.ids) { ids in try await backend.move(ids, to: destination) }
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

    /// The messages to change: the ids given, or what a search finds. With dry_run, the search's messages come back
    /// to be listed instead. The whole call is refused if a message sits in a hidden mailbox.
    private func visibleIDs(_ arguments: [String: Value]) async throws -> (ids: [MessageID], preview: [MessageSummary]?, total: Int) {
        if let search = arguments["search"] {
            guard arguments["ids"] == nil, arguments["id"] == nil else {
                throw PosternError(.invalidArgument, "Give ids or search, not both.")
            }
            guard case .object(let fields) = search else { throw PosternError(.invalidArgument, "search is an object, like the arguments of search_messages.") }
            let query = try Self.query(fields)
            try ensureVisible(query.mailbox)
            let limit = min(max(int(arguments["limit"]) ?? Self.maxSearched, 1), Self.maxSearched)
            let found = try await backend.search(query, limit: limit, offset: 0)
            if bool(arguments["dry_run"]) == true { return ([], found.items, found.total) }
            return (found.items.map(\.id), nil, found.total)
        }
        if bool(arguments["dry_run"]) == true { throw PosternError(.invalidArgument, "dry_run goes with search.") }
        var texts: [String] = []
        if case .array(let values)? = arguments["ids"] {
            texts = values.compactMap { if case .string(let text) = $0 { text } else { nil } }
        } else if let single = string(arguments["id"]) {
            texts = [single]
        }
        guard !texts.isEmpty else { throw PosternError(.invalidArgument, "ids is required: message ids from search_messages. Or give search to change what a search finds.") }
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
        let unique = Array(NSOrderedSet(array: ids.map(\.opaque)).compactMap { ($0 as? String).flatMap(MessageID.init(opaque:)) })
        return (unique, nil, unique.count)
    }

    /// A search's arguments, read the way search_messages reads them.
    static func query(_ fields: [String: Value]) throws -> SearchQuery {
        func text(_ key: String) -> String? {
            guard case .string(let value)? = fields[key] else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func day(_ key: String) throws -> Date? {
            guard let value = text(key) else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            guard let date = formatter.date(from: value) else { throw PosternError(.invalidArgument, "\(key) must be a day written YYYY-MM-DD.") }
            return date
        }
        func flag(_ key: String) -> Bool? { if case .bool(let value)? = fields[key] { value } else { nil } }
        guard let mailbox = text("mailbox") else { throw PosternError(.invalidArgument, "search needs a mailbox from list_mailboxes.") }
        let query = SearchQuery(
            mailbox: mailbox, from: text("from"), to: text("to"), subject: text("subject"), text: text("text"),
            since: try day("since"), before: try day("before"), unread: flag("unread"), starred: flag("starred")
        )
        // A search that names nothing but a mailbox would change all of it: ask for at least one condition.
        guard query.from != nil || query.to != nil || query.subject != nil || query.text != nil || query.since != nil
                || query.before != nil || query.unread != nil || query.starred != nil else {
            throw PosternError(.invalidArgument, "search needs at least one condition besides the mailbox, such as from, before or unread.")
        }
        return query
    }

    /// Applies a change a hundred messages at a time and gathers the reports.
    private func inChunks(_ ids: [MessageID], _ change: ([MessageID]) async throws -> ChangeReport) async throws -> ChangeReport {
        guard !ids.isEmpty else { return ChangeReport(done: [], failed: [], verified: true) }
        var total = ChangeReport(done: [], failed: [], verified: true)
        for start in stride(from: 0, to: ids.count, by: Self.maxIDs) {
            let report = try await change(Array(ids[start..<min(start + Self.maxIDs, ids.count)]))
            total.done += report.done
            total.failed += report.failed
            total.verified = total.verified && report.verified
        }
        return total
    }

    /// What a search would change, newest first, without changing anything.
    private func dryRun(_ found: [MessageSummary], total: Int, action: String) -> CallTool.Result {
        let iso = ISO8601DateFormatter()
        var text = "Would \(action) \(found.count) message(s)"
        if total > found.count { text += "; the search finds \(total), more than the limit" }
        text += ". Nothing was changed."
        let listing = found.prefix(30).map { item in
            "- \(item.date.map { iso.string(from: $0) } ?? "no date") | from \(item.from.map(\.email).joined(separator: ", ")) | \(item.subject)"
        }.joined(separator: "\n")
        if !listing.isEmpty { text += "\n" + renderer.wrap(listing, source: "messages a change would touch") }
        return CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            structuredContent: Optional<Value>.some(.object([
                "count": .int(found.count), "found": .int(total), "dry_run": .bool(true),
                "messages": .array(found.prefix(30).map { item in
                    .object([
                        "id": .string(item.id.opaque),
                        "date": item.date.map { .string(iso.string(from: $0)) } ?? .null,
                        "untrusted_from": .string(UntrustedRenderer.defuse(item.from.first?.email ?? "")),
                        "untrusted_subject": .string(UntrustedRenderer.defuse(item.subject)),
                    ])
                }),
            ])),
            isError: false
        )
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
        // Long lists of new ids stay in the structured result.
        let ids = report.done.count > Self.maxIDs ? "" : report.done.map(\.opaque).joined(separator: "\n")
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

    private func int(_ value: Value?) -> Int? {
        switch value {
        case .int(let number)?: number
        case .double(let number)?: Int(number)
        default: nil
        }
    }
}
