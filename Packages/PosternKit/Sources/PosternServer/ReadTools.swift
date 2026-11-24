import Foundation
import MCP
import PosternModel
import PosternPolicy

/// Runs the read tools. Every result has a structured form and a text form; mail-derived content is marked untrusted
/// in both.
struct ReadTools {
    let backend: any MailBackend
    let policy: Policy
    var provenance = Provenance()
    let renderer = UntrustedRenderer()

    static let defaultLimit = 20
    static let maxLimit = 50
    static let defaultMaxChars = 20_000
    /// get_messages reads at most this many at once.
    static let maxBatchRead = 10
    /// top_senders counts at most this many messages, the newest.
    static let maxCounted = 1000
    /// The mailbox name that means every mailbox the user lets Postern see.
    static let everyMailbox = "*"

    func call(_ tool: ToolID, _ arguments: [String: Value]) async throws -> CallTool.Result {
        switch tool {
        case .listMailboxes: try await listMailboxes()
        case .searchMessages: try await search(arguments)
        case .getMessage: try await getMessage(arguments)
        case .getThread: try await getThread(arguments)
        case .getMessages: try await getMessages(arguments)
        case .topSenders: try await topSenders(arguments)
        case .listAddresses: try await listAddresses()
        default: throw PosternError(.invalidArgument, "\(tool.rawValue) is not a read tool.")
        }
    }

    // MARK: Tools

    private func listMailboxes() async throws -> CallTool.Result {
        let visible = try await backend.listMailboxes().filter { !policy.isHidden($0.name) }
            .sorted { Self.order($0) < Self.order($1) }
        let structured: Value = .object(["mailboxes": .array(visible.map { mailbox in
            .object([
                "name": .string(mailbox.name), "kind": .string(mailbox.kind.rawValue),
                "total": mailbox.total.map(Value.int) ?? .null, "unread": mailbox.unread.map(Value.int) ?? .null,
            ])
        })])
        let lines = visible.map { mailbox -> String in
            let counts = [mailbox.unread.map { "\($0) unread" }, mailbox.total.map { "\($0) total" }]
                .compactMap { $0 }.joined(separator: ", ")
            return "- \(mailbox.name) [\(mailbox.kind.rawValue)]" + (counts.isEmpty ? "" : " (\(counts))")
        }
        return result(text: lines.isEmpty ? "No mailbox is visible." : lines.joined(separator: "\n"), structured)
    }

    private func search(_ arguments: [String: Value]) async throws -> CallTool.Result {
        var query = SearchQuery(mailbox: string(arguments["mailbox"]) ?? "INBOX")
        guard query.mailbox == Self.everyMailbox || !policy.isHidden(query.mailbox) else {
            throw PosternError(.scopeHidden, "The user has hidden \"\(query.mailbox)\" from Postern.")
        }
        query.from = string(arguments["from"])
        query.to = string(arguments["to"])
        query.subject = string(arguments["subject"])
        query.text = string(arguments["text"])
        query.since = try day(arguments["since"], field: "since")
        query.before = try day(arguments["before"], field: "before")
        query.unread = bool(arguments["unread"])
        query.starred = bool(arguments["starred"])
        let limit = min(max(int(arguments["limit"]) ?? Self.defaultLimit, 1), Self.maxLimit)
        let offset = string(arguments["cursor"]).flatMap(Int.init) ?? 0
        guard offset >= 0 else { throw PosternError(.invalidArgument, "cursor is not valid.") }

        let page = try await searchVisible(query, limit: limit, offset: offset)
        for item in page.items { provenance.record(item.from + item.to + item.cc) }
        let nextOffset = offset + page.items.count
        let next: Value = nextOffset < page.total ? .string(String(nextOffset)) : .null
        let structured: Value = .object([
            "mailbox": .string(query.mailbox), "total": .int(page.total), "next_cursor": next,
            "messages": .array(page.items.map(summaryValue)),
        ])
        let listing = page.items.map(summaryLine).joined(separator: "\n")
        let place = query.mailbox == Self.everyMailbox ? "every mailbox Postern can see" : query.mailbox
        var text = "\(page.total) message(s) in \(place)"
        if case .string(let cursor) = next { text += ", more with cursor \(cursor)" }
        text += "."
        if !listing.isEmpty { text += "\n" + renderer.wrap(listing, source: "message list") }
        return result(text: text, structured)
    }

    private func getMessage(_ arguments: [String: Value]) async throws -> CallTool.Result {
        let id = try messageID(arguments["id"])
        try await ensureVisible(id)
        let maxChars = min(max(int(arguments["max_chars"]) ?? Self.defaultMaxChars, 500), 100_000)
        let message = try await backend.message(id, maxChars: maxChars)
        let headers = message.headers
        provenance.record(headers.from + headers.replyTo + headers.to + headers.cc)
        provenance.record(text: message.body + " " + message.links.map(\.url).joined(separator: " "))
        let verdict = message.verdict
        let structured: Value = .object([
            "id": .string(id.opaque),
            "date": headers.date.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            "untrusted_from": addresses(headers.from), "untrusted_reply_to": addresses(headers.replyTo),
            "untrusted_to": addresses(headers.to), "untrusted_cc": addresses(headers.cc),
            "untrusted_subject": .string(UntrustedRenderer.defuse(headers.subject)),
            "untrusted_body": .string(UntrustedRenderer.defuse(message.body)),
            "body_truncated": .bool(message.bodyTruncated),
            "hidden_elements_removed": .int(message.hiddenElementsRemoved),
            "images_omitted": .int(message.imagesOmitted),
            "untrusted_links": .array(message.links.map { link in
                .object([
                    "index": .int(link.index), "text": .string(UntrustedRenderer.defuse(link.text)),
                    "url": .string(UntrustedRenderer.defuse(link.url)), "host": link.host.map(Value.string) ?? .null,
                    "text_names_another_site": .bool(link.textLooksLikeOtherHost),
                    "suspicious_host": .bool(link.suspiciousHost),
                ])
            }),
            "attachments": .array(message.attachments.map { attachment in
                .object([
                    "index": .int(attachment.index),
                    "untrusted_filename": attachment.filename.map { .string(UntrustedRenderer.defuse($0)) } ?? .null,
                    "mime_type": .string(attachment.mimeType), "size": .int(attachment.size),
                ])
            }),
            "sender_verdict": .object([
                "level": .string(verdict.level.rawValue), "spf": verdict.spf.map(Value.string) ?? .null,
                "dkim": verdict.dkim.map(Value.string) ?? .null, "dmarc": verdict.dmarc.map(Value.string) ?? .null,
                "reasons": .array(verdict.reasons.map(Value.string)),
            ]),
            "unsubscribe": .array(headers.listUnsubscribe.map { .string(UntrustedRenderer.defuse($0)) }),
        ])

        var header = "Sender verdict: \(verdict.level.rawValue)"
        if !verdict.reasons.isEmpty { header += " (" + verdict.reasons.joined(separator: " ") + ")" }
        var mail = "From: \(format(headers.from))\n"
        if !headers.replyTo.isEmpty { mail += "Reply-To: \(format(headers.replyTo))\n" }
        mail += "To: \(format(headers.to))\n"
        if !headers.cc.isEmpty { mail += "Cc: \(format(headers.cc))\n" }
        if let date = headers.date { mail += "Date: \(ISO8601DateFormatter().string(from: date))\n" }
        mail += "Subject: \(headers.subject)\n\n\(message.body)"
        if message.bodyTruncated { mail += "\n[truncated]" }
        if !message.links.isEmpty {
            mail += "\n\nLinks:\n" + message.links.map { link in
                var line = "[link \(link.index)] \(link.url)"
                if link.textLooksLikeOtherHost { line += " (its text names another site: \(link.text))" }
                if link.suspiciousHost { line += " (suspicious address)" }
                return line
            }.joined(separator: "\n")
        }
        if !message.attachments.isEmpty {
            mail += "\n\nAttachments:\n" + message.attachments.map {
                "- \($0.filename ?? "unnamed") (\($0.mimeType), \($0.size) bytes)"
            }.joined(separator: "\n")
        }
        var notes: [String] = []
        if message.hiddenElementsRemoved > 0 { notes.append("\(message.hiddenElementsRemoved) hidden element(s) removed") }
        if message.imagesOmitted > 0 { notes.append("\(message.imagesOmitted) image(s) not loaded") }
        let text = ([header] + (notes.isEmpty ? [] : [notes.joined(separator: ", ") + "."]) + [renderer.wrap(mail, source: "email \(id.opaque)")])
            .joined(separator: "\n")
        return result(text: text, structured)
    }

    private func getThread(_ arguments: [String: Value]) async throws -> CallTool.Result {
        let id = try messageID(arguments["id"])
        try await ensureVisible(id)
        let names = try await backend.mailboxNames().filter { !policy.isHidden($0) }
        let searched = names.contains("All Mail") ? ["All Mail"] : names.filter { !Self.notSearchedForThreads($0) }
        var visible: [MessageSummary] = []
        for summary in try await backend.thread(id, in: searched) {
            if !policy.isHidden(try await backend.displayName(ofRawMailbox: summary.id.mailbox)) { visible.append(summary) }
        }
        for item in visible { provenance.record(item.from + item.to + item.cc) }
        let structured: Value = .object(["messages": .array(visible.map(summaryValue))])
        let listing = visible.map(summaryLine).joined(separator: "\n")
        let text = "\(visible.count) message(s) in this conversation.\n" + renderer.wrap(listing, source: "conversation")
        return result(text: text, structured)
    }

    /// Without All Mail, a conversation is looked for in the real folders: labels and Starred only repeat them,
    /// and Trash and Spam hold what the user put aside.
    static func notSearchedForThreads(_ name: String) -> Bool {
        name.hasPrefix("Labels/") || ["All Mail", "Starred", "Trash", "Spam"].contains(name)
    }

    /// One mailbox, or with `*` every mailbox the user lets Postern see: All Mail when it is visible, else each
    /// real folder (labels and Starred only repeat them), merged newest first, each message once.
    func searchVisible(_ query: SearchQuery, limit: Int, offset: Int) async throws -> (items: [MessageSummary], total: Int) {
        guard query.mailbox == Self.everyMailbox else { return try await backend.search(query, limit: limit, offset: offset) }
        let names = try await backend.mailboxNames().filter { !policy.isHidden($0) }
        if names.contains("All Mail") {
            var all = query
            all.mailbox = "All Mail"
            return try await backend.search(all, limit: limit, offset: offset)
        }
        var merged: [MessageSummary] = []
        var seen: Set<String> = []
        var total = 0
        for name in names where !Self.notSearchedForThreads(name) || name == "Trash" || name == "Spam" {
            var each = query
            each.mailbox = name
            let page = try await backend.search(each, limit: offset + limit, offset: 0)
            total += page.total
            for item in page.items where seen.insert(item.messageIDHeader ?? item.id.opaque).inserted { merged.append(item) }
        }
        merged.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return (Array(merged.dropFirst(offset).prefix(limit)), max(total, merged.count))
    }

    /// Several messages at once, each as get_message gives it, read one after the other.
    private func getMessages(_ arguments: [String: Value]) async throws -> CallTool.Result {
        guard case .array(let list)? = arguments["ids"], !list.isEmpty else {
            throw PosternError(.invalidArgument, "ids is a list of message ids from search_messages.")
        }
        guard list.count <= Self.maxBatchRead else {
            throw PosternError(.invalidArgument, "get_messages reads at most \(Self.maxBatchRead) messages at once.")
        }
        let maxChars = min(max(int(arguments["max_chars"]) ?? 4000, 200), 20_000)
        var texts: [String] = []
        var items: [Value] = []
        for value in list {
            let id = string(value) ?? ""
            do {
                let one = try await getMessage(["id": .string(id), "max_chars": .int(maxChars)])
                if let structured = one.structuredContent { items.append(structured) }
                for case .text(let text, _, _) in one.content { texts.append(text) }
            } catch let error as PosternError {
                items.append(.object(["id": .string(UntrustedRenderer.defuse(id)), "error": .object([
                    "code": .string(error.code.rawValue), "message": .string(error.message),
                ])]))
                texts.append("Message \(UntrustedRenderer.defuse(id)): \(error.code.rawValue): \(error.message)")
            }
        }
        let read = items.filter { if case .object(let fields) = $0 { fields["error"] == nil } else { false } }.count
        let text = "Read \(read) of \(list.count) message(s).\n\n" + texts.joined(separator: "\n\n")
        return result(text: text, .object(["messages": .array(items)]))
    }

    /// The newest messages a search finds, counted by sender, sender domain or recipient.
    private func topSenders(_ arguments: [String: Value]) async throws -> CallTool.Result {
        var query = SearchQuery(mailbox: string(arguments["mailbox"]) ?? "INBOX")
        guard query.mailbox == Self.everyMailbox || !policy.isHidden(query.mailbox) else {
            throw PosternError(.scopeHidden, "The user has hidden \"\(query.mailbox)\" from Postern.")
        }
        query.since = try day(arguments["since"], field: "since")
        query.unread = bool(arguments["unread"])
        let by = string(arguments["by"]) ?? "sender"
        guard ["sender", "domain", "recipient"].contains(by) else {
            throw PosternError(.invalidArgument, "by is sender, domain or recipient.")
        }
        let top = min(max(int(arguments["limit"]) ?? 25, 1), 100)
        let page = try await searchVisible(query, limit: Self.maxCounted, offset: 0)

        struct Tally { var count = 0; var unread = 0; var latest: Date?; var names: [String: Int] = [:] }
        var tallies: [String: Tally] = [:]
        for item in page.items {
            let people = by == "recipient" ? item.to + item.cc : Array(item.from.prefix(1))
            provenance.record(people)
            for person in people {
                let email = person.email.lowercased()
                let key = by == "domain" ? String(email.split(separator: "@").last ?? Substring(email)) : email
                var tally = tallies[key] ?? Tally()
                tally.count += 1
                if item.unread { tally.unread += 1 }
                if let date = item.date, date > (tally.latest ?? .distantPast) { tally.latest = date }
                if by != "domain", let name = person.name, !name.isEmpty { tally.names[name, default: 0] += 1 }
                tallies[key] = tally
            }
        }
        let ranked = tallies.sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }.prefix(top)
        let iso = ISO8601DateFormatter()
        let rows: [Value] = ranked.map { key, tally in
            let name = tally.names.max { $0.value < $1.value }?.key
            return .object([
                "untrusted_\(by == "domain" ? "domain" : "address")": .string(UntrustedRenderer.defuse(key)),
                "untrusted_name": name.map { .string(UntrustedRenderer.defuse($0)) } ?? .null,
                "messages": .int(tally.count), "unread": .int(tally.unread),
                "latest": tally.latest.map { .string(iso.string(from: $0)) } ?? .null,
            ])
        }
        let lines = ranked.enumerated().map { index, entry -> String in
            let (key, tally) = entry
            let top: String? = tally.names.max { $0.value < $1.value }?.key
            let name = top.map { "\($0) " } ?? ""
            let latest = tally.latest.map { ", latest " + iso.string(from: $0) } ?? ""
            return "\(index + 1). \(name)<\(key)>: \(tally.count) message(s), \(tally.unread) unread\(latest)"
        }
        let place = query.mailbox == Self.everyMailbox ? "every mailbox Postern can see" : query.mailbox
        let counted = page.items.count
        let scope = counted < page.total ? "the newest \(counted) of \(page.total)" : "\(counted)"
        var text = "Counted \(scope) message(s) in \(place), by \(by)."
        if !lines.isEmpty { text += "\n" + renderer.wrap(lines.joined(separator: "\n"), source: "sender counts") }
        return result(text: text, .object([
            "mailbox": .string(query.mailbox), "by": .string(by), "counted": .int(counted), "total": .int(page.total),
            "ranking": .array(rows),
        ]))
    }

    // MARK: Helpers

    private func ensureVisible(_ id: MessageID) async throws {
        let name = try await backend.displayName(ofRawMailbox: id.mailbox)
        guard !policy.isHidden(name) else { throw PosternError(.scopeHidden, "The user has hidden this mailbox from Postern.") }
    }

    /// The account's address and the aliases the user added in Postern's window; nothing else can send.
    private func listAddresses() async throws -> CallTool.Result {
        let account = try await backend.ownAddress()
        let aliases = policy.senderAddresses.subtracting([account.email.lowercased()]).sorted()
        let structured: Value = .object(["addresses": .array(
            [.object(["email": .string(account.email), "kind": "account"])]
                + aliases.map { .object(["email": .string($0), "kind": "alias"]) }
        )])
        let text = aliases.isEmpty
            ? "Postern can send from \(account.email), the account's address. The user can add aliases in Postern's window."
            : "Postern can send from \(account.email), the account's address, and from \(aliases.joined(separator: ", "))."
        return result(text: text, structured)
    }

    private func result(text: String, _ structured: Value) -> CallTool.Result {
        CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: Optional<Value>.some(structured), isError: false)
    }

    private func summaryValue(_ summary: MessageSummary) -> Value {
        .object([
            "id": .string(summary.id.opaque),
            "date": summary.date.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            "untrusted_from": addresses(summary.from), "untrusted_to": addresses(summary.to),
            "untrusted_subject": .string(UntrustedRenderer.defuse(summary.subject)),
            "unread": .bool(summary.unread), "starred": .bool(summary.starred),
            "attachment_count": .int(summary.attachmentCount), "size": .int(summary.size),
        ])
    }

    private func summaryLine(_ summary: MessageSummary) -> String {
        let date = summary.date.map { ISO8601DateFormatter().string(from: $0) } ?? "no date"
        var flags: [String] = []
        if summary.unread { flags.append("unread") }
        if summary.starred { flags.append("starred") }
        if summary.attachmentCount > 0 { flags.append("\(summary.attachmentCount) attachment(s)") }
        let suffix = flags.isEmpty ? "" : " [" + flags.joined(separator: ", ") + "]"
        return "- id \(summary.id.opaque) | \(date) | from \(format(summary.from)) | \(summary.subject)\(suffix)"
    }

    private func addresses(_ list: [Address]) -> Value {
        .array(list.map { address in
            .object([
                "name": address.name.map { .string(UntrustedRenderer.defuse($0)) } ?? .null,
                "email": .string(UntrustedRenderer.defuse(address.email)),
            ])
        })
    }

    private func format(_ list: [Address]) -> String {
        list.map { address in address.name.map { "\($0) <\(address.email)>" } ?? address.email }
            .joined(separator: ", ")
    }

    private func messageID(_ value: Value?) throws -> MessageID {
        guard let text = string(value), let id = MessageID(opaque: text) else {
            throw PosternError(.invalidArgument, "id is not a Postern message id. Use an id from search_messages.")
        }
        return id
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
        case .string(let text)?: Int(text)
        default: nil
        }
    }

    private func day(_ value: Value?, field: String) throws -> Date? {
        guard let text = string(value) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: text) else {
            throw PosternError(.invalidArgument, "\(field) must be a day written YYYY-MM-DD.")
        }
        return date
    }

    private static func order(_ mailbox: MailboxInfo) -> String {
        let rank: Int = switch mailbox.kind {
        case .system: mailbox.name == "INBOX" ? 0 : 1
        case .virtual: 2
        case .folder: 3
        case .label: 4
        }
        return "\(rank)\(mailbox.name.lowercased())"
    }
}
