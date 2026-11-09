import Foundation
import MCP
import PosternModel
import PosternPolicy

/// Which emails the user sent got no answer: the follow-ups to write. Each recipient is checked three ways, from
/// the surest: a reply in the conversation, then any later email from the same address, then from the same company
/// domain (not for addresses at public providers such as gmail.com).
struct FollowUpTools {
    let backend: any MailBackend
    let policy: Policy
    let provenance: Provenance
    let renderer = UntrustedRenderer()

    static let maxSent = 500
    static let maxReceived = 5000

    enum Answer: String {
        case noReply = "no_reply"
        case replied
        case heardFromAddress = "heard_from_address"
        case heardFromDomain = "heard_from_domain"
    }

    struct Contact {
        let email: String
        var sent: [MessageSummary]
        var answer: Answer = .noReply
        var heard: (summary: MessageSummary, mailbox: String)?

        var last: MessageSummary { sent[0] }
    }

    func awaitingReply(_ arguments: [String: Value]) async throws -> CallTool.Result {
        let now = Date()
        let since = try day(arguments["since"], field: "since") ?? now.addingTimeInterval(-30 * 86_400)
        let quietDays = min(max(int(arguments["quiet_days"]) ?? 7, 0), 365)
        let limit = min(max(int(arguments["limit"]) ?? 50, 1), 200)
        let includeAnswered = bool(arguments["include_answered"]) == true
        let names = try await backend.mailboxNames().filter { !policy.isHidden($0) }
        guard names.contains("Sent") else { throw PosternError(.scopeHidden, "The user has hidden Sent from Postern.") }

        // What the user sent since then, grouped by its first recipient, newest first.
        let query = SearchQuery(mailbox: "Sent", to: string(arguments["to"]), subject: string(arguments["subject"]), since: since)
        let sent = try await backend.search(query, limit: Self.maxSent, offset: 0)
        let cutoff = now.addingTimeInterval(-Double(quietDays) * 86_400)
        var contacts: [String: Contact] = [:]
        var order: [String] = []
        for item in sent.items {
            guard let first = (item.to + item.cc).first else { continue }
            let email = first.email.lowercased()
            if contacts[email] == nil {
                contacts[email] = Contact(email: email, sent: [])
                order.append(email)
            }
            contacts[email]?.sent.append(item)
        }

        // Everything received since, in All Mail when visible, else folder by folder; Spam too, where a reply may hide.
        let me = try await backend.ownAddress()
        let mine = policy.senderAddresses.union([me.email.lowercased()])
        var searched = names.contains("All Mail") ? ["All Mail"] : names.filter { !ReadTools.notSearchedForThreads($0) && $0 != "Sent" && $0 != "Drafts" }
        if names.contains("Spam") { searched.append("Spam") }
        var received: [(summary: MessageSummary, mailbox: String)] = []
        var partial = sent.total > Self.maxSent
        for name in searched {
            let page = try await backend.search(SearchQuery(mailbox: name, since: since), limit: Self.maxReceived, offset: 0)
            if page.total > Self.maxReceived { partial = true }
            for item in page.items where !item.from.contains(where: { mine.contains($0.email.lowercased()) }) {
                received.append((item, name))
            }
        }
        received.sort { ($0.summary.date ?? .distantPast) < ($1.summary.date ?? .distantPast) }

        var byParent: [String: (MessageSummary, String)] = [:]
        var byAddress: [String: [(MessageSummary, String)]] = [:]
        var byDomain: [String: [(MessageSummary, String)]] = [:]
        for entry in received {
            if let parent = entry.summary.inReplyTo.map(Self.normalized), byParent[parent] == nil { byParent[parent] = entry }
            for address in entry.summary.from {
                let email = address.email.lowercased()
                byAddress[email, default: []].append(entry)
                if let domain = Self.company(of: email) { byDomain[domain, default: []].append(entry) }
            }
        }

        for email in order {
            guard var contact = contacts[email] else { continue }
            let first = contact.sent.last?.date ?? .distantPast
            let ids = Set(contact.sent.compactMap { $0.messageIDHeader.map(Self.normalized) })
            func after(_ list: [(MessageSummary, String)]?) -> (MessageSummary, String)? {
                list?.first { ($0.0.date ?? .distantPast) >= first }
            }
            if let reply = ids.lazy.compactMap({ byParent[$0] }).first {
                contact.answer = .replied
                contact.heard = (reply.0, reply.1)
            } else if let heard = after(byAddress[email]) {
                contact.answer = .heardFromAddress
                contact.heard = (heard.0, heard.1)
            } else if let domain = Self.company(of: email), let heard = after(byDomain[domain]) {
                contact.answer = .heardFromDomain
                contact.heard = (heard.0, heard.1)
            }
            contacts[email] = contact
        }

        // Someone written to in the last quiet days is not due a follow-up yet, whatever the answer.
        let everyone = order.compactMap { contacts[$0] }
        let all = everyone.filter { ($0.last.date ?? now) <= cutoff }
        let recent = everyone.count - all.count
        let waiting = all.filter { $0.answer == .noReply }
        // The longest wait first.
        let shown = Array((includeAnswered ? all : waiting).sorted { ($0.last.date ?? now) < ($1.last.date ?? now) }.prefix(limit))
        for contact in shown { if let heard = contact.heard { provenance.record(heard.summary.from) } }

        var lines = ["\(all.count) people written to since \(Self.dayText(since)), last more than \(quietDays) days ago: \(waiting.count) without any answer, \(all.count - waiting.count) answered or heard from."]
        if recent > 0 { lines.append("\(recent) more were written to in the last \(quietDays) days and are left out.") }
        if partial { lines.append("Only the newest messages were checked; narrow the dates for a full answer.") }
        let listing = shown.map { contact -> String in
            let days = Int(now.timeIntervalSince(contact.last.date ?? now) / 86_400)
            var line = "- \(contact.email): \(contact.sent.count) sent, last \(days) days ago, id \(contact.last.id.opaque), \"\(contact.last.subject)\""
            if let heard = contact.heard {
                let date = heard.summary.date.map(Self.dayText) ?? "no date"
                line += " | \(contact.answer.rawValue): \(date) from \(heard.summary.from.first?.email ?? "?") in \(heard.mailbox), id \(heard.summary.id.opaque), \"\(heard.summary.subject)\""
            }
            return line
        }.joined(separator: "\n")
        if !listing.isEmpty { lines.append(renderer.wrap(listing, source: "sent messages and their answers")) }

        let iso = ISO8601DateFormatter()
        let structured: Value = .object([
            "summary": .string(lines.prefix(listing.isEmpty ? lines.count : lines.count - 1).joined(separator: " ")),
            "people": .int(all.count), "without_answer": .int(waiting.count), "written_recently": .int(recent),
            "partial": .bool(partial),
            "contacts": .array(shown.map { contact in
                var fields: [String: Value] = [
                    "email": .string(UntrustedRenderer.defuse(contact.email)), "sent_count": .int(contact.sent.count),
                    "last_sent": contact.last.date.map { .string(iso.string(from: $0)) } ?? .null,
                    "days_waiting": .int(Int(now.timeIntervalSince(contact.last.date ?? now) / 86_400)),
                    "last_sent_id": .string(contact.last.id.opaque),
                    "untrusted_subject": .string(UntrustedRenderer.defuse(contact.last.subject)),
                    "answer": .string(contact.answer.rawValue),
                ]
                if let heard = contact.heard {
                    fields["heard"] = .object([
                        "id": .string(heard.summary.id.opaque), "mailbox": .string(heard.mailbox),
                        "date": heard.summary.date.map { .string(iso.string(from: $0)) } ?? .null,
                        "untrusted_from": .string(UntrustedRenderer.defuse(heard.summary.from.first?.email ?? "")),
                        "untrusted_subject": .string(UntrustedRenderer.defuse(heard.summary.subject)),
                        "in_spam": .bool(heard.mailbox == "Spam"),
                    ])
                }
                return .object(fields)
            }),
        ])
        return CallTool.Result(content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)],
                               structuredContent: Optional<Value>.some(structured), isError: false)
    }

    // MARK: Matching

    /// A Message-ID without its angle brackets, in lower case.
    static func normalized(_ id: String) -> String {
        id.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t")).lowercased()
    }

    /// The company behind an address: its domain without subdomains, or nil for a public provider, where the
    /// domain says nothing about who answers.
    static func company(of email: String) -> String? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        let labels = email[email.index(after: at)...].lowercased().split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        let short = ["co", "com", "org", "net", "ac", "gov", "edu"].contains(labels[labels.count - 2]) && labels.count >= 3
            && labels[labels.count - 1].count == 2
        let domain = labels.suffix(short ? 3 : 2).joined(separator: ".")
        let provider = domain.split(separator: ".").first.map(String.init) ?? domain
        guard !publicProviders.contains(domain), !publicProviderNames.contains(provider) else { return nil }
        return domain
    }

    static let publicProviders: Set<String> = [
        "pm.me", "me.com", "mac.com", "mail.com", "web.de", "free.fr", "sfr.fr", "laposte.net", "wanadoo.fr",
        "orange.fr", "bluewin.ch", "sunrise.ch", "hispeed.ch", "gmx.ch", "gmx.net", "gmx.de", "gmx.fr", "aol.com",
    ]
    static let publicProviderNames: Set<String> = [
        "gmail", "googlemail", "hotmail", "outlook", "live", "msn", "yahoo", "icloud", "proton", "protonmail", "yandex",
        "gmx", "zoho", "tutanota", "tuta",
    ]

    // MARK: Arguments

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

    static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
