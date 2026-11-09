import Foundation
import MCP
import PosternApproval
import PosternCompose
import PosternModel
import PosternPolicy

/// Drafts and sending. Nothing leaves without an `ApprovedMessage`, which only the approval desk produces.
struct SendTools {
    let backend: any MailBackend
    var policy: Policy
    let desk: ApprovalDesk
    let ledger: any SendLedger
    let provenance: Provenance
    let client: String
    /// Where long batches run, beyond this call.
    let board: BatchBoard
    /// The policy as it is now, for batches that outlive the call.
    let livePolicy: @Sendable () -> Policy
    /// The pause between two emails of a short batch, so they leave at a person's pace rather than in a burst.
    var batchSpacing: Duration = .seconds(2)
    /// How long a batch call waits for its batch before answering with its progress.
    var inlineWait: Duration = .seconds(45)

    static let quoteLimit = 20_000
    static let batchLimit = 5000

    func call(_ tool: ToolID, _ arguments: [String: Value]) async throws -> CallTool.Result {
        switch tool {
        case .createDrafts:
            return try await createDrafts(arguments)
        case .createDraft:
            let message = try await compose(arguments)
            let id = try await saveVerified(message)
            return result("Saved a draft to \(message.envelopeRecipients.joined(separator: ", "))\(Self.withFiles(message)). It waits in Drafts until someone sends it.",
                          ["draft_id": .string(id.opaque), "attachments": Self.fileList(message)])
        case .updateDraft:
            let id = try await draftID(arguments["id"])
            let current = try await backend.message(id, maxChars: OutgoingMessage.maxBodyCharacters)
            let kept = Self.givesFiles(arguments) ? [] : try await backend.attachments(of: id)
            let message = try await compose(arguments, base: current, baseFiles: kept)
            let newID = try await saveVerified(message)
            try await backend.deleteDraft(id)
            return result("Updated the draft\(Self.withFiles(message)). Use the new id from now on.",
                          ["draft_id": .string(newID.opaque), "attachments": Self.fileList(message)])
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
            let message = try await compose(arguments.filter { $0.key == "no_attachment" }, base: draft,
                                            baseFiles: try await backend.attachments(of: id))
            let outcome = try await deliver(message, tool: tool, context: "A draft saved in Drafts", extra: [:])
            if outcome.isError != true, case .object(let fields)? = outcome.structuredContent, fields["sent"] == .bool(true) {
                try? await backend.deleteDraft(id)
            }
            return outcome
        case .sendDrafts:
            return try await sendDrafts(arguments)
        case .batchStatus:
            return try await batchStatus(arguments)
        case .cancelBatch:
            return try await cancelBatch(arguments)
        case .listOutbox:
            return try await listOutbox()
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
        let mine = policy.senderAddresses.union([me.email.lowercased()])
        let headers = original.headers
        var to = headers.replyTo.isEmpty ? headers.from : headers.replyTo
        var cc: [Address] = []
        if bool(arguments["reply_all"]) == true {
            cc = (headers.to + headers.cc).filter { address in
                !mine.contains(address.email.lowercased())
                    && !to.contains { $0.email.lowercased() == address.email.lowercased() }
            }
        }
        to = to.filter { !mine.contains($0.email.lowercased()) }
        if to.isEmpty { to = headers.from }
        let subject = headers.subject.lowercased().hasPrefix("re:") ? headers.subject : "Re: " + headers.subject
        let sender = headers.from.first.map(Self.describe) ?? "the sender"
        let date = headers.date.map { Self.dateText($0) } ?? "an earlier day"
        let quoted = "On \(date), \(sender) wrote:\n" + original.body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> " + $0 }.joined(separator: "\n")
        var references = headers.references
        if let messageID = headers.messageID { references.append(messageID) }
        let message: OutgoingMessage
        do {
            message = try OutgoingMessage.make(
                from: try await self.sender(arguments["from"], preferred: headers.to + headers.cc), to: to, cc: cc,
                subject: subject, body: body, quoted: quoted,
                inReplyTo: headers.messageID, references: Array(references.suffix(20)),
                attachments: try await files(arguments)
            )
        } catch let error as ComposeError {
            throw PosternError(.invalidArgument, Self.explain(error))
        }
        try requireAnnouncedFiles(message, arguments)
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
        let originalFiles = bool(arguments["include_attachments"]) == false ? [] : try await backend.attachments(of: id)
        let message: OutgoingMessage
        do {
            message = try OutgoingMessage.make(
                from: try await sender(arguments["from"]), to: recipients, subject: subject, body: string(arguments["note"]) ?? "",
                quoted: quoted, attachments: originalFiles + (try await files(arguments))
            )
        } catch let error as ComposeError {
            throw PosternError(.invalidArgument, Self.explain(error))
        }
        try requireAnnouncedFiles(message, arguments)
        let sender = headers.from.first.map(Self.describe) ?? "someone"
        return try await deliver(message, tool: .forwardMessage, context: "Forward of \(sender): \(headers.subject)", extra: [:])
    }

    // MARK: The send pipeline

    /// Checks the recipients and the quota, then asks the desk; only an approved message reaches Bridge.
    func deliver(
        _ message: OutgoingMessage, tool: ToolID, context: String?, extra: [String: [ApprovalBadge]]
    ) async throws -> CallTool.Result {
        try checkRecipients(message)
        guard SendBudget.remaining(policy, sends: ledger.recentSends()) > 0 else {
            throw PosternError(.quotaExceeded, "The sending limit the user set is reached. Try again later.")
        }
        let fingerprint = message.contentFingerprint
        if let conflict = await board.holdSingle(fingerprint) { throw PosternError(.duplicate, conflict) }
        var left = false
        do {
            let outcome = try await review(message, tool: tool, context: context, extra: extra, left: &left)
            await board.releaseSingle(fingerprint, sent: left)
            return outcome
        } catch let error as PosternError {
            await board.releaseSingle(fingerprint, sent: left || error.code == .sendUncertain)
            throw error
        } catch {
            await board.releaseSingle(fingerprint, sent: left)
            throw error
        }
    }

    /// The panel, then Bridge. `left` turns true once the email is sent.
    private func review(
        _ message: OutgoingMessage, tool: ToolID, context: String?, extra: [String: [ApprovalBadge]], left: inout Bool
    ) async throws -> CallTool.Result {
        let request = try await approvalRequest(message, tool: tool, context: context, extra: extra)

        if let approved = await desk.approveTrusted(request, trusted: policy.trustedRecipients) {
            try await sendCounted(approved)
            left = true
            return result("Sent to \(approved.recipients.joined(separator: ", "))\(Self.withFiles(approved.message)), all on the user's trusted list.",
                          ["sent": .bool(true), "attachments": Self.fileList(approved.message)])
        }
        switch await desk.review(request) {
        case .approved(let approved):
            try await sendCounted(approved)
            left = true
            return result("The user read the email, approved it with Touch ID, and it was sent to \(approved.recipients.joined(separator: ", "))\(Self.withFiles(approved.message)).",
                          ["sent": .bool(true), "attachments": Self.fileList(approved.message)])
        case .saveAsDraft(let draft):
            let id = try await saveVerified(draft)
            return result("The user chose to keep it as a draft instead of sending it now.", ["sent": .bool(false), "draft_id": .string(id.opaque)])
        case .rejected(let reason):
            throw PosternError(.approvalRejected, "The user rejected this email" + (reason.map { ": \($0)" } ?? "."))
        case .notAuthenticated:
            throw PosternError(.approvalRejected, "The user did not confirm with Touch ID, so nothing was sent.")
        case .expired:
            throw PosternError(.approvalTimeout, "The user did not answer within two minutes, so nothing was sent.")
        }
    }

    /// Takes the email's place in the limits and sends it; the place is given back only when the email surely did
    /// not leave. A batch running at the same time cannot take the same place.
    private func sendCounted(_ approved: ApprovedMessage) async throws {
        let now = Date()
        guard ledger.reserve(at: now, allowed: { SendBudget.remaining(policy, sends: $0, now: now) > 0 }) else {
            throw PosternError(.quotaExceeded, "The sending limit the user set was reached while the email waited; it was not sent.")
        }
        do {
            try await backend.send(approved)
        } catch let error as PosternError where error.code == .sendUncertain {
            throw error
        } catch {
            ledger.release(at: now)
            throw error
        }
    }

    /// The address an email leaves from: the account's, or an alias the user added in Postern's window. A draft
    /// keeps the address it was written from, if the user allows it; a reply prefers the address it answers.
    func sender(_ value: Value?, draft: Address? = nil, preferred: [Address] = []) async throws -> Address {
        let account = try await backend.ownAddress()
        func allowed(_ address: Address) -> Bool {
            let email = address.email.lowercased()
            return email == account.email.lowercased() || policy.senderAddresses.contains(email)
        }
        func named(_ address: Address) -> Address { Address(name: address.name ?? account.name, email: address.email) }
        if let value {
            guard case .string(let text) = value, let address = RecipientParser.parse(text) else {
                throw PosternError(.invalidArgument, "from is one address, such as pro@example.com.")
            }
            guard allowed(address) else {
                throw PosternError(.senderNotAllowed, "\(address.email) is not one of the user's sender addresses; list_addresses gives them, and the user can add an alias in Postern's window.")
            }
            return named(address)
        }
        if let draft {
            guard allowed(draft) else {
                throw PosternError(.senderNotAllowed, "This draft is written from \(draft.email), which is not one of the user's sender addresses. Pass from with one of list_addresses, or the user can add it in Postern's window.")
            }
            return named(draft)
        }
        return preferred.first(where: allowed).map(named) ?? account
    }

    func checkRecipients(_ message: OutgoingMessage) throws {
        let refused = message.envelopeRecipients.filter { !policy.mayReceive($0) }
        guard refused.isEmpty else {
            throw PosternError(.recipientNotAllowed, "The user only allows mail to their approved recipients; \(refused.joined(separator: ", ")) is not one of them.")
        }
    }

    /// The panel's view of a message, with a warning for each recipient that deserves a second look.
    func approvalRequest(
        _ message: OutgoingMessage, tool: ToolID, context: String?, extra: [String: [ApprovalBadge]],
        contacted: ContactCache? = nil
    ) async throws -> ApprovalRequest {
        var badges: [String: [ApprovalBadge]] = [:]
        for email in message.envelopeRecipients {
            var list = extra[email] ?? []
            if policy.trustedRecipients.contains(email) { list.append(.trusted) }
            let known: Bool
            if let cached = contacted?.known(email) {
                known = cached
            } else {
                known = try await backend.hasSentTo(email)
                contacted?.remember(email, known)
            }
            if !known { list.append(.firstContact) }
            if provenance.cameFromEmail(email) { list.append(.cameFromEmail) }
            badges[email] = list
        }
        return ApprovalRequest(tool: tool.rawValue, client: client, message: message, badges: badges, context: context)
    }

    // MARK: Arguments

    /// Builds the message from the arguments; a draft being changed or sent gives the fields and files left out.
    func compose(
        _ arguments: [String: Value], base: SanitizedMessage? = nil, baseFiles: [OutgoingAttachment] = [],
        cache: AttachmentCache? = nil, messageID: String? = nil
    ) async throws -> OutgoingMessage {
        let to = arguments["to"] == nil ? base?.headers.to ?? [] : try addresses(arguments["to"])
        let cc = arguments["cc"] == nil ? base?.headers.cc ?? [] : try addresses(arguments["cc"])
        let bcc = arguments["bcc"] == nil ? base?.headers.bcc ?? [] : try addresses(arguments["bcc"])
        let subject = string(arguments["subject"]) ?? base?.headers.subject ?? ""
        let body = arguments["body"] == nil ? base?.body ?? "" : (string(arguments["body"]) ?? "")
        let files = Self.givesFiles(arguments) ? try await self.files(arguments, cache: cache) : baseFiles
        let from = try await sender(arguments["from"], draft: base?.headers.from.first)
        let message: OutgoingMessage
        do {
            message = try OutgoingMessage.make(
                from: from, to: to, cc: cc, bcc: bcc, subject: subject, body: body,
                inReplyTo: base?.headers.inReplyTo, references: base?.headers.references ?? [], attachments: files,
                messageID: messageID
            )
        } catch let error as ComposeError {
            throw PosternError(.invalidArgument, Self.explain(error))
        }
        try requireAnnouncedFiles(message, arguments)
        return message
    }

    /// The three ways a client gives files: outbox names, content it wrote, and attachments of emails it read.
    static let fileArguments = ["attachments", "inline_attachments", "email_attachments"]

    static func givesFiles(_ arguments: [String: Value]) -> Bool {
        fileArguments.contains { arguments[$0] != nil }
    }

    /// Every file the arguments give, in that order.
    func files(_ arguments: [String: Value], cache: AttachmentCache? = nil) async throws -> [OutgoingAttachment] {
        try await outboxFiles(arguments["attachments"], cache: cache)
            + inlineFiles(arguments["inline_attachments"])
            + emailFiles(arguments["email_attachments"], cache: cache)
    }

    /// An email whose text announces a file ("ci-joint", "attached", "anbei"…) and carries none is stopped: the
    /// client forgot the files. It passes no_attachment when the text means it.
    func requireAnnouncedFiles(_ message: OutgoingMessage, _ arguments: [String: Value]) throws {
        guard bool(arguments["no_attachment"]) != true, let words = message.missingAttachment else { return }
        throw PosternError(.attachmentMissing, "The email says \"\(words)\" but no file is attached, so nothing was done. Attach the files (attachments from the outbox, inline_attachments, or email_attachments), or pass no_attachment: true if no file is meant.")
    }

    /// Files the client wrote itself: text, or base64 for anything else, 10 MB at most in all.
    func inlineFiles(_ value: Value?) throws -> [OutgoingAttachment] {
        guard let value else { return [] }
        guard case .array(let list) = value, list.count <= 20 else {
            throw PosternError(.invalidArgument, "inline_attachments is a list of at most 20 files, each with name and text or base64.")
        }
        var total = 0
        return try list.map { item in
            guard case .object(let fields) = item, case .string(let name)? = fields["name"] else {
                throw PosternError(.invalidArgument, "Each inline attachment needs a name, such as report.csv.")
            }
            let data: Data
            switch (fields["text"], fields["base64"]) {
            case (.string(let text)?, nil):
                data = Data(text.utf8)
            case (nil, .string(let encoded)?):
                guard let decoded = Data(base64Encoded: encoded.filter { !$0.isWhitespace }) else {
                    throw PosternError(.invalidArgument, "The base64 of \(name) does not decode.")
                }
                data = decoded
            default:
                throw PosternError(.invalidArgument, "Give \(name) either text or base64.")
            }
            guard !data.isEmpty else { throw PosternError(.invalidArgument, "\(name) is empty.") }
            total += data.count
            guard total <= Self.inlineLimit else { throw PosternError(.tooLarge, "Inline attachments hold 10 MB at most; put bigger files in the outbox.") }
            do {
                return try OutgoingAttachment.make(filename: name, data: data)
            } catch let error as ComposeError {
                throw PosternError(.invalidArgument, Self.explain(error))
            }
        }
    }

    static let inlineLimit = 10_000_000

    /// Attachments of emails the client can read, by message id and the index get_message gives.
    func emailFiles(_ value: Value?, cache: AttachmentCache? = nil) async throws -> [OutgoingAttachment] {
        guard let value else { return [] }
        guard case .array(let list) = value, list.count <= 20 else {
            throw PosternError(.invalidArgument, "email_attachments is a list of at most 20 items, each with id and index.")
        }
        var files: [OutgoingAttachment] = []
        for item in list {
            guard case .object(let fields) = item, let index = Self.integer(fields["index"]) else {
                throw PosternError(.invalidArgument, "Each email attachment needs the email's id and the attachment's index from get_message.")
            }
            let id = try await messageID(fields["id"])
            let key = "email:\(id.opaque):\(index)"
            if let known = cache?.file(key) {
                files.append(known)
            } else {
                let file = try await backend.attachment(id, index: index)
                cache?.keep(file, as: key)
                files.append(file)
            }
        }
        return files
    }

    static func integer(_ value: Value?) -> Int? {
        switch value {
        case .int(let number)?: number
        case .double(let number)? where number == number.rounded(): Int(number)
        case .string(let text)?: Int(text)
        default: nil
        }
    }

    /// Saves a draft, then reads back how many files Bridge kept: a draft that lost one is removed and the call
    /// fails, so no email leaves later without the files it was written with.
    func saveVerified(_ message: OutgoingMessage) async throws -> MessageID {
        try await Self.saveVerified(message, backend: backend)
    }

    static func saveVerified(_ message: OutgoingMessage, backend: any MailBackend) async throws -> MessageID {
        let id = try await backend.saveDraft(message)
        let expected = message.attachments.count
        guard expected > 0, let count = try? await backend.attachmentCount(of: id), count < expected else { return id }
        // The structure alone can miscount: the files themselves decide.
        if let files = try? await backend.attachments(of: id), files.count >= expected { return id }
        try? await backend.deleteDraft(id)
        throw PosternError(.attachmentsLost, "Bridge kept \(count) of the \(expected) files of this draft, so the draft was removed and nothing was saved. Try again; if it happens again, attach fewer or smaller files.")
    }

    /// ", with CV.pdf (240 KB) and Letter.pdf (80 KB)", or nothing.
    static func withFiles(_ message: OutgoingMessage) -> String {
        guard !message.attachments.isEmpty else { return "" }
        let names = message.attachments.map { "\($0.filename) (\(size($0.data.count)))" }
        return ", with " + (names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!)
    }

    static func fileList(_ message: OutgoingMessage) -> Value {
        .array(message.attachments.map { .object(["name": .string($0.filename), "size": .int($0.data.count)]) })
    }

    /// Files named by the client, taken only from the Postern outbox folder; the panel shows each one. A batch
    /// reads each file once, and its drafts share the bytes.
    func outboxFiles(_ value: Value?, cache: AttachmentCache? = nil) async throws -> [OutgoingAttachment] {
        guard let value else { return [] }
        guard case .array(let list) = value else { throw PosternError(.invalidArgument, "attachments is a list of file names.") }
        var files: [OutgoingAttachment] = []
        for item in list {
            guard case .string(let name) = item else { throw PosternError(.invalidArgument, "attachments is a list of file names.") }
            if let known = cache?.file(name) {
                files.append(known)
            } else {
                let file = try await backend.outboxAttachment(named: name)
                cache?.keep(file, as: name)
                files.append(file)
            }
        }
        return files
    }

    func addresses(_ value: Value?) throws -> [Address] {
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

    func draftID(_ value: Value?) async throws -> MessageID {
        let id = try await messageID(value)
        guard id.mailbox == "Drafts" else { throw PosternError(.invalidArgument, "This id is not a draft. Use an id from create_draft or the Drafts mailbox.") }
        return id
    }

    func messageID(_ value: Value?) async throws -> MessageID {
        guard case .string(let text)? = value, let id = MessageID(opaque: text) else {
            throw PosternError(.invalidArgument, "id is not a Postern message id.")
        }
        guard !policy.isHidden(try await backend.displayName(ofRawMailbox: id.mailbox)) else {
            throw PosternError(.scopeHidden, "The user has hidden this mailbox from Postern.")
        }
        return id
    }

    func string(_ value: Value?) -> String? {
        if case .string(let text)? = value {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    func bool(_ value: Value?) -> Bool? {
        if case .bool(let flag)? = value { return flag }
        return nil
    }

    /// The text, and the same facts as fields. Several clients give the model only the fields, others only the
    /// text, so the fields carry the text too, as `summary`.
    func result(_ text: String, _ fields: [String: Value]) -> CallTool.Result {
        CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)],
                        structuredContent: Optional<Value>.some(.object(fields.merging(["summary": .string(text)]) { own, _ in own })),
                        isError: false)
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
