import Foundation
import MCP
import PosternApproval
import PosternCompose
import PosternModel
import PosternPolicy

/// Drafts and sending. Nothing leaves without an `ApprovedMessage`, which only the approval desk produces.
struct SendTools {
    let backend: any MailBackend
    let policy: Policy
    let desk: ApprovalDesk
    let ledger: any SendLedger
    let provenance: Provenance
    let client: String
    /// The pause between two emails of a batch, so they leave at a person's pace rather than in a burst.
    var batchSpacing: Duration = .seconds(2)

    static let quoteLimit = 20_000
    static let batchLimit = 50

    func call(_ tool: ToolID, _ arguments: [String: Value]) async throws -> CallTool.Result {
        switch tool {
        case .createDraft:
            let message = try await compose(arguments)
            let id = try await backend.saveDraft(message)
            return result("Saved a draft to \(message.envelopeRecipients.joined(separator: ", ")). It waits in Drafts until someone sends it.",
                          ["draft_id": .string(id.opaque)])
        case .updateDraft:
            let id = try await draftID(arguments["id"])
            let current = try await backend.message(id, maxChars: OutgoingMessage.maxBodyCharacters)
            let kept = arguments["attachments"] == nil ? try await backend.attachments(of: id) : []
            let message = try await compose(arguments, base: current, baseFiles: kept)
            let newID = try await backend.saveDraft(message)
            try await backend.deleteDraft(id)
            return result("Updated the draft. Use the new id from now on.", ["draft_id": .string(newID.opaque)])
        case .deleteDraft:
            let id = try await draftID(arguments["id"])
            try await backend.deleteDraft(id)
            return result("Deleted the draft.", ["deleted": .string(id.opaque)])
        case .sendMessage:
            return try await deliver(try await compose(arguments), tool: tool, context: nil, extra: [:])
        case .replyToMessage:
            return try await reply(arguments)
        case .forwardMessage:
            return try await forward(arguments)
        case .sendDraft:
            let id = try await draftID(arguments["id"])
            let draft = try await backend.message(id, maxChars: OutgoingMessage.maxBodyCharacters)
            let message = try await compose([:], base: draft, baseFiles: try await backend.attachments(of: id))
            let outcome = try await deliver(message, tool: tool, context: "A draft saved in Drafts", extra: [:])
            if outcome.isError != true, case .object(let fields)? = outcome.structuredContent, fields["sent"] == .bool(true) {
                try? await backend.deleteDraft(id)
            }
            return outcome
        case .sendDrafts:
            return try await sendDrafts(arguments)
        default:
            throw PosternError(.invalidArgument, "\(tool.rawValue) is not a draft or send tool.")
        }
    }

    // MARK: Replies and forwards

    private func reply(_ arguments: [String: Value]) async throws -> CallTool.Result {
        let id = try await messageID(arguments["id"])
        guard let body = string(arguments["body"]) else { throw PosternError(.invalidArgument, "body is required.") }
        let original = try await backend.message(id, maxChars: Self.quoteLimit)
        let me = try await backend.ownAddress()
        let headers = original.headers
        var to = headers.replyTo.isEmpty ? headers.from : headers.replyTo
        var cc: [Address] = []
        if bool(arguments["reply_all"]) == true {
            cc = (headers.to + headers.cc).filter { address in
                address.email.lowercased() != me.email.lowercased()
                    && !to.contains { $0.email.lowercased() == address.email.lowercased() }
            }
        }
        to = to.filter { $0.email.lowercased() != me.email.lowercased() }
        if to.isEmpty { to = headers.from }
        let subject = headers.subject.lowercased().hasPrefix("re:") ? headers.subject : "Re: " + headers.subject
        let sender = headers.from.first.map(Self.describe) ?? "the sender"
        let date = headers.date.map { Self.dateText($0) } ?? "an earlier day"
        let quoted = "On \(date), \(sender) wrote:\n" + original.body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> " + $0 }.joined(separator: "\n")
        var references = headers.references
        if let messageID = headers.messageID { references.append(messageID) }
        let message = try OutgoingMessage.make(
            from: me, to: to, cc: cc, subject: subject, body: body, quoted: quoted,
            inReplyTo: headers.messageID, references: Array(references.suffix(20))
        )
        var extra: [String: [ApprovalBadge]] = [:]
        if let replyTo = headers.replyTo.first, let from = headers.from.first,
           replyTo.email.lowercased() != from.email.lowercased() {
            extra[replyTo.email.lowercased()] = [.replyToDiffers]
        }
        return try await deliver(message, tool: .replyToMessage, context: "Reply to \(sender): \(headers.subject)", extra: extra)
    }

    private func forward(_ arguments: [String: Value]) async throws -> CallTool.Result {
        let id = try await messageID(arguments["id"])
        let recipients = try addresses(arguments["to"])
        guard !recipients.isEmpty else { throw PosternError(.invalidArgument, "to is required.") }
        let original = try await backend.message(id, maxChars: Self.quoteLimit)
        let headers = original.headers
        let subject = headers.subject.lowercased().hasPrefix("fwd:") ? headers.subject : "Fwd: " + headers.subject
        var quoted = "---------- Forwarded message ----------\n"
        quoted += "From: \(headers.from.map(Self.describe).joined(separator: ", "))\n"
        if let date = headers.date { quoted += "Date: \(Self.dateText(date))\n" }
        quoted += "Subject: \(headers.subject)\nTo: \(headers.to.map(Self.describe).joined(separator: ", "))\n\n" + original.body
        let files = bool(arguments["include_attachments"]) == false ? [] : try await backend.attachments(of: id)
        let message: OutgoingMessage
        do {
            message = try OutgoingMessage.make(
                from: try await backend.ownAddress(), to: recipients, subject: subject, body: string(arguments["note"]) ?? "",
                quoted: quoted, attachments: files
            )
        } catch let error as ComposeError {
            throw PosternError(.invalidArgument, Self.explain(error))
        }
        let sender = headers.from.first.map(Self.describe) ?? "someone"
        return try await deliver(message, tool: .forwardMessage, context: "Forward of \(sender): \(headers.subject)", extra: [:])
    }

    // MARK: Drafts sent together

    /// One panel and one Touch ID for up to fifty drafts; each approved email stays bound to its own digest, and the
    /// limits count each one.
    private func sendDrafts(_ arguments: [String: Value]) async throws -> CallTool.Result {
        guard case .array(let list)? = arguments["ids"], (1...Self.batchLimit).contains(list.count) else {
            throw PosternError(.invalidArgument, "ids is a list of 1 to \(Self.batchLimit) draft ids.")
        }
        var ids: [MessageID] = []
        for value in list {
            let id = try await draftID(value)
            if !ids.contains(id) { ids.append(id) }
        }
        var outcomes: [MessageID: (status: String, detail: String)] = [:]
        var pending: [(id: MessageID, request: ApprovalRequest)] = []
        var room = remainingSends()
        for id in ids {
            do {
                let draft = try await backend.message(id, maxChars: OutgoingMessage.maxBodyCharacters)
                let message = try await compose([:], base: draft, baseFiles: try await backend.attachments(of: id))
                try checkRecipients(message)
                guard room > 0 else { throw PosternError(.quotaExceeded, "The sending limit the user set is reached; this draft stays in Drafts.") }
                room -= 1
                pending.append((id, try await approvalRequest(message, tool: .sendDrafts, context: "A draft saved in Drafts", extra: [:])))
            } catch let error as PosternError {
                outcomes[id] = ("refused", "\(error.code.rawValue): \(error.message)")
            } catch {
                outcomes[id] = ("refused", "\(error)")
            }
        }
        if !pending.isEmpty {
            let batch = BatchApprovalRequest(tool: ToolID.sendDrafts.rawValue, client: client, items: pending.map(\.request))
            switch await desk.reviewBatch(batch) {
            case .approved(let approved):
                var first = true
                for (id, request) in pending {
                    guard let message = approved[request.id] else {
                        outcomes[id] = ("skipped", "The user left this email out; the draft stays in Drafts.")
                        continue
                    }
                    if !first { try? await Task.sleep(for: batchSpacing) }
                    first = false
                    do {
                        try await backend.send(message)
                        ledger.recordSend(at: Date())
                        try? await backend.deleteDraft(id)
                        outcomes[id] = ("sent", "Sent to \(message.recipients.joined(separator: ", ")).")
                    } catch let error as PosternError {
                        outcomes[id] = ("failed", "\(error.code.rawValue): \(error.message)")
                    } catch {
                        outcomes[id] = ("failed", "\(error)")
                    }
                }
            case .rejected(let reason):
                throw PosternError(.approvalRejected, "The user rejected these emails, so nothing was sent" + (reason.map { ": \($0)" } ?? "."))
            case .notAuthenticated:
                throw PosternError(.approvalRejected, "The user did not confirm with Touch ID, so nothing was sent.")
            case .expired:
                throw PosternError(.approvalTimeout, "The user did not answer in time, so nothing was sent.")
            }
        }
        let sent = ids.filter { outcomes[$0]?.status == "sent" }.count
        let lines = ids.map { id in "\(id.opaque): \(outcomes[id]?.status ?? "refused"). \(outcomes[id]?.detail ?? "")" }
        let summary = sent == 0
            ? "Nothing was sent."
            : "The user approved the batch with Touch ID; \(sent) of \(ids.count) emails were sent."
        return result(([summary] + lines).joined(separator: "\n"), [
            "sent": .int(sent),
            "results": .array(ids.map { id in
                .object(["id": .string(id.opaque), "status": .string(outcomes[id]?.status ?? "refused"),
                         "detail": .string(outcomes[id]?.detail ?? "")])
            }),
        ])
    }

    // MARK: The send pipeline

    /// Checks the recipients and the quota, then asks the desk; only an approved message reaches Bridge.
    private func deliver(
        _ message: OutgoingMessage, tool: ToolID, context: String?, extra: [String: [ApprovalBadge]]
    ) async throws -> CallTool.Result {
        try checkRecipients(message)
        guard remainingSends() > 0 else {
            throw PosternError(.quotaExceeded, "The sending limit the user set is reached. Try again later.")
        }
        let request = try await approvalRequest(message, tool: tool, context: context, extra: extra)

        if let approved = await desk.approveTrusted(request, trusted: policy.trustedRecipients) {
            try await backend.send(approved)
            ledger.recordSend(at: Date())
            return result("Sent to \(approved.recipients.joined(separator: ", ")), all on the user's trusted list.", ["sent": .bool(true)])
        }
        switch await desk.review(request) {
        case .approved(let approved):
            try await backend.send(approved)
            ledger.recordSend(at: Date())
            return result("The user read the email, approved it with Touch ID, and it was sent to \(approved.recipients.joined(separator: ", ")).", ["sent": .bool(true)])
        case .saveAsDraft(let draft):
            let id = try await backend.saveDraft(draft)
            return result("The user chose to keep it as a draft instead of sending it now.", ["sent": .bool(false), "draft_id": .string(id.opaque)])
        case .rejected(let reason):
            throw PosternError(.approvalRejected, "The user rejected this email" + (reason.map { ": \($0)" } ?? "."))
        case .notAuthenticated:
            throw PosternError(.approvalRejected, "The user did not confirm with Touch ID, so nothing was sent.")
        case .expired:
            throw PosternError(.approvalTimeout, "The user did not answer within two minutes, so nothing was sent.")
        }
    }

    private func checkRecipients(_ message: OutgoingMessage) throws {
        let refused = message.envelopeRecipients.filter { !policy.mayReceive($0) }
        guard refused.isEmpty else {
            throw PosternError(.recipientNotAllowed, "The user only allows mail to their approved recipients; \(refused.joined(separator: ", ")) is not one of them.")
        }
    }

    /// How many more emails the hourly and daily limits allow right now.
    private func remainingSends() -> Int {
        let now = Date()
        let sends = ledger.recentSends()
        let hour = policy.sendsPerHour - sends.filter { now.timeIntervalSince($0) < 3600 }.count
        let day = policy.sendsPerDay - sends.filter { now.timeIntervalSince($0) < 86_400 }.count
        return max(0, min(hour, day))
    }

    /// The panel's view of a message, with a warning for each recipient that deserves a second look.
    private func approvalRequest(
        _ message: OutgoingMessage, tool: ToolID, context: String?, extra: [String: [ApprovalBadge]]
    ) async throws -> ApprovalRequest {
        var badges: [String: [ApprovalBadge]] = [:]
        for email in message.envelopeRecipients {
            var list = extra[email] ?? []
            if policy.trustedRecipients.contains(email) { list.append(.trusted) }
            if !(try await backend.hasSentTo(email)) { list.append(.firstContact) }
            if provenance.cameFromEmail(email) { list.append(.cameFromEmail) }
            badges[email] = list
        }
        return ApprovalRequest(tool: tool.rawValue, client: client, message: message, badges: badges, context: context)
    }

    // MARK: Arguments

    /// Builds the message from the arguments; a draft being changed or sent gives the fields and files left out.
    private func compose(
        _ arguments: [String: Value], base: SanitizedMessage? = nil, baseFiles: [OutgoingAttachment] = []
    ) async throws -> OutgoingMessage {
        let to = arguments["to"] == nil ? base?.headers.to ?? [] : try addresses(arguments["to"])
        let cc = arguments["cc"] == nil ? base?.headers.cc ?? [] : try addresses(arguments["cc"])
        let bcc = arguments["bcc"] == nil ? base?.headers.bcc ?? [] : try addresses(arguments["bcc"])
        let subject = string(arguments["subject"]) ?? base?.headers.subject ?? ""
        let body = arguments["body"] == nil ? base?.body ?? "" : (string(arguments["body"]) ?? "")
        let files = arguments["attachments"] == nil ? baseFiles : try await outboxFiles(arguments["attachments"])
        do {
            return try OutgoingMessage.make(
                from: try await backend.ownAddress(), to: to, cc: cc, bcc: bcc, subject: subject, body: body,
                inReplyTo: base?.headers.inReplyTo, references: base?.headers.references ?? [], attachments: files
            )
        } catch let error as ComposeError {
            throw PosternError(.invalidArgument, Self.explain(error))
        }
    }

    /// Files named by the client, taken only from the Postern outbox folder; the panel shows each one.
    private func outboxFiles(_ value: Value?) async throws -> [OutgoingAttachment] {
        guard let value else { return [] }
        guard case .array(let list) = value else { throw PosternError(.invalidArgument, "attachments is a list of file names.") }
        var files: [OutgoingAttachment] = []
        for item in list {
            guard case .string(let name) = item else { throw PosternError(.invalidArgument, "attachments is a list of file names.") }
            files.append(try await backend.outboxAttachment(named: name))
        }
        return files
    }

    private func addresses(_ value: Value?) throws -> [Address] {
        let items: [Value]
        switch value {
        case .array(let list)?: items = list
        case .string?: items = [value!]
        case nil: return []
        default: throw PosternError(.invalidArgument, "Recipients are a list of addresses.")
        }
        return try items.map { item in
            switch item {
            case .string(let text):
                guard let address = RecipientParser.parse(text) else { throw PosternError(.invalidArgument, "Empty recipient.") }
                return address
            case .object(let fields):
                guard case .string(let email)? = fields["email"] else { throw PosternError(.invalidArgument, "A recipient needs an email.") }
                if case .string(let name)? = fields["name"] { return Address(name: name, email: email) }
                return Address(name: nil, email: email)
            default:
                throw PosternError(.invalidArgument, "Recipients are addresses such as anna@example.com.")
            }
        }
    }

    private func draftID(_ value: Value?) async throws -> MessageID {
        let id = try await messageID(value)
        guard id.mailbox == "Drafts" else { throw PosternError(.invalidArgument, "This id is not a draft. Use an id from create_draft or the Drafts mailbox.") }
        return id
    }

    private func messageID(_ value: Value?) async throws -> MessageID {
        guard case .string(let text)? = value, let id = MessageID(opaque: text) else {
            throw PosternError(.invalidArgument, "id is not a Postern message id.")
        }
        guard !policy.isHidden(try await backend.displayName(ofRawMailbox: id.mailbox)) else {
            throw PosternError(.scopeHidden, "The user has hidden this mailbox from Postern.")
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

    private func result(_ text: String, _ fields: [String: Value]) -> CallTool.Result {
        CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)],
                        structuredContent: Optional<Value>.some(.object(fields)), isError: false)
    }

    static func describe(_ address: Address) -> String {
        address.name.map { "\($0) <\(address.email)>" } ?? address.email
    }

    static func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.locale(Locale(identifier: "en_US_POSIX")).weekday(.abbreviated).day().month(.abbreviated).year().hour().minute())
    }

    static func explain(_ error: ComposeError) -> String {
        switch error {
        case .noRecipient: "At least one recipient is required."
        case .tooManyRecipients: "At most \(OutgoingMessage.maxRecipients) recipients per email."
        case .invalidAddress(let address): "\(address) is not a valid email address."
        case .headerInjection: "Subjects and names cannot contain line breaks."
        case .tooLong: "The text or the attachments are too large (20 MB of attachments at most)."
        case .invalidFileName(let name): "\(name) is not a file name Postern accepts."
        }
    }
}
