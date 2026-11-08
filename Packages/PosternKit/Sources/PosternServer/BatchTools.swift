import Foundation
import MCP
import PosternApproval
import PosternCompose
import PosternModel
import PosternPolicy

/// Batches: up to 500 drafts written from a template or a spreadsheet, and up to 500 drafts sent after one panel
/// and one Touch ID, at a pace the user's limits allow. Both run on the board, so a call never has to last as long
/// as the batch.
extension SendTools {
    static let templateFields: Set<String> = ["subject", "body", "attachments", "from", "cc", "bcc"]
    /// A batch answer lists every item up to this many; longer batches list only the items that need attention.
    static let listedItems = 50
    /// How long a batch waits before trying an email Bridge did not take again: then every ten minutes.
    static let retryDelays: [TimeInterval] = [30, 120, 600]
    /// Failures that say nothing about the email itself: the batch holds instead of failing every email in turn.
    static let holdingCodes: Set<PosternErrorCode> = [.bridgeUnreachable, .authenticationFailed, .certificateMismatch, .notConfigured]

    // MARK: Drafts from a template

    /// Each draft is checked before any is saved: one draft with a problem stops the batch, unless the client asks
    /// to skip such drafts. Nothing leaves, so nothing asks the user.
    func createDrafts(_ arguments: [String: Value]) async throws -> CallTool.Result {
        let template = try templateArgument(arguments["template"])
        let rows = try await draftRows(arguments)
        let cache = AttachmentCache()
        var prepared: [(index: Int, message: OutgoingMessage)] = []
        var problems: [Int: String] = [:]
        for (index, row) in rows.enumerated() {
            do {
                prepared.append((index, try await draftMessage(template: template, row: row, cache: cache)))
            } catch {
                problems[index] = Self.detail(error)
            }
        }
        if bool(arguments["dry_run"]) == true {
            return dryRun(total: rows.count, prepared: prepared.map(\.message), problems: problems)
        }
        if !problems.isEmpty && bool(arguments["skip_invalid"]) != true {
            let listed = problems.sorted { $0.key < $1.key }.prefix(20).map { "\($0.key + 1). \($0.value)" }
            throw PosternError(.invalidArgument, (
                ["\(problems.count) of \(rows.count) drafts have a problem, so none was saved. Fix them, or pass skip_invalid to save the others."]
                    + listed
            ).joined(separator: "\n"))
        }
        let messages = Dictionary(uniqueKeysWithValues: prepared.map { ($0.index, $0.message) })
        let items = rows.indices.map { index in
            BatchBoard.Item(
                index: index, recipients: messages[index]?.envelopeRecipients.joined(separator: ", ") ?? "",
                subject: messages[index]?.subject ?? "", status: messages[index] == nil ? .refused : .waiting,
                detail: problems[index] ?? "", draft: nil
            )
        }
        let id = await board.open(kind: .drafts, client: client, items: items)
        let backend = self.backend
        let board = self.board
        let work = prepared
        await board.run(id) { await Self.saveDrafts(work, batch: id, board: board, backend: backend) }
        guard let batch = await board.settle(id, within: inlineWait) else {
            throw PosternError(.notFound, "The batch disappeared.")
        }
        return draftsAnswer(batch)
    }

    private func templateArgument(_ value: Value?) throws -> [String: Value] {
        switch value {
        case .object(let fields)?: return fields.filter { Self.templateFields.contains($0.key) }
        case nil: return [:]
        default: throw PosternError(.invalidArgument, "template is an object with subject, body, attachments, from, cc and bcc.")
        }
    }

    /// The drafts given inline, or the rows of a spreadsheet in the outbox, as fields and values.
    private func draftRows(_ arguments: [String: Value]) async throws -> [(fields: [String: Value], values: [String: String])] {
        switch (arguments["drafts"], arguments["data_file"]) {
        case (let given?, nil):
            guard case .array(let list) = given, (1...Self.batchLimit).contains(list.count) else {
                throw PosternError(.invalidArgument, "drafts is a list of 1 to \(Self.batchLimit) drafts.")
            }
            return try list.map { item in
                guard case .object(var fields) = item else {
                    throw PosternError(.invalidArgument, "Each draft is an object with to, and values for the template.")
                }
                var values: [String: String] = [:]
                if case .object(let given)? = fields.removeValue(forKey: "values") {
                    for case (let key, .string(let text)) in given { values[key] = text }
                }
                return (fields, values)
            }
        case (nil, let given?):
            guard case .string(let name) = given else { throw PosternError(.invalidArgument, "data_file is the name of a file in the outbox.") }
            let file = try await backend.outboxAttachment(named: name)
            return try DataTable.rows(from: file.data, named: name, limit: Self.batchLimit).map(Self.draftFields)
        case (nil, nil):
            throw PosternError(.invalidArgument, "Give drafts, or data_file with a spreadsheet from the outbox.")
        default:
            throw PosternError(.invalidArgument, "Give drafts or data_file, not both.")
        }
    }

    /// A spreadsheet row: the columns named like a draft field fill that field, and every column is a value.
    static func draftFields(_ row: [String: String]) -> (fields: [String: Value], values: [String: String]) {
        var fields: [String: Value] = [:]
        for (column, cell) in row {
            let text = cell.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            switch column.lowercased() {
            case "to", "cc", "bcc":
                fields[column.lowercased()] = .array(DataTable.split(text, separators: [",", ";"]).map { .string($0) })
            case "attachments":
                fields["attachments"] = .array(DataTable.split(text, separators: [";", "|"]).map { .string($0) })
            case "from", "subject":
                fields[column.lowercased()] = .string(text)
            case "body":
                fields["body"] = .string(cell)
            default:
                break
            }
        }
        return (fields, row)
    }

    private func draftMessage(
        template: [String: Value], row: (fields: [String: Value], values: [String: String]), cache: AttachmentCache
    ) async throws -> OutgoingMessage {
        var merged = template.merging(row.fields) { _, own in own }
        for key in ["subject", "body"] {
            if case .string(let text)? = merged[key] { merged[key] = .string(try Self.fill(text, row.values)) }
        }
        if case .array(let names)? = merged["attachments"] {
            merged["attachments"] = .array(try names.map { name in
                guard case .string(let text) = name else { return name }
                return .string(try Self.fill(text, row.values))
            })
        }
        guard merged["to"] != nil else { throw PosternError(.invalidArgument, "This draft has no recipient.") }
        return try await compose(merged, cache: cache)
    }

    /// Replaces each {{name}} with its value. A name without a value refuses the draft, so none says "Dear {{name}}".
    static func fill(_ text: String, _ values: [String: String]) throws -> String {
        var missing: [String] = []
        let filled = text.replacing(#/\{\{\s*([^{}\s]+)\s*\}\}/#) { match in
            let key = String(match.1)
            guard let value = values[key] else {
                missing.append("{{\(key)}}")
                return ""
            }
            return value
        }
        guard missing.isEmpty else { throw PosternError(.invalidArgument, "No value for \(missing.joined(separator: ", ")).") }
        return filled
    }

    private func dryRun(total: Int, prepared: [OutgoingMessage], problems: [Int: String]) -> CallTool.Result {
        var lines = ["Checked \(total) drafts: \(prepared.count) ready, \(problems.count) with a problem. Nothing was saved."]
        lines += problems.sorted { $0.key < $1.key }.prefix(Self.listedItems).map { "\($0.key + 1). \($0.value)" }
        let bytes = prepared.reduce(0) { total, message in total + message.attachments.reduce(0) { $0 + $1.data.count } }
        var fields: [String: Value] = [
            "ready": .int(prepared.count),
            "attachment_bytes": .int(bytes),
            "problems": .array(problems.sorted { $0.key < $1.key }.map { .object(["index": .int($0.key), "detail": .string($0.value)]) }),
        ]
        if let first = prepared.first {
            let files = first.attachments.map { "\($0.filename) (\(Self.size($0.data.count)))" }
            lines.append("")
            lines.append("The first one reads:")
            lines.append("From: \(Self.describe(first.from))")
            lines.append("To: \(first.envelopeRecipients.joined(separator: ", "))")
            lines.append("Subject: \(first.subject)")
            if !files.isEmpty { lines.append("Attachments: \(files.joined(separator: ", "))") }
            lines.append("")
            lines.append(first.body.count > 1500 ? String(first.body.prefix(1500)) + "…" : first.body)
            fields["preview"] = .object([
                "from": .string(first.from.email), "to": .array(first.envelopeRecipients.map { .string($0) }),
                "subject": .string(first.subject), "body": .string(String(first.body.prefix(1500))),
                "attachments": .array(first.attachments.map { .object(["name": .string($0.filename), "size": .int($0.data.count)]) }),
            ])
        }
        return result(lines.joined(separator: "\n"), fields)
    }

    static func saveDrafts(
        _ prepared: [(index: Int, message: OutgoingMessage)], batch id: String, board: BatchBoard, backend: any MailBackend
    ) async {
        for entry in prepared {
            if Task.isCancelled { return }
            var attempt = 0
            while true {
                do {
                    let draft = try await backend.saveDraft(entry.message)
                    await board.set(id, entry.index, .saved, "Saved in Drafts.", draft: draft)
                    break
                } catch let error as PosternError where error.code == .bridgeUnreachable && attempt < 2 {
                    attempt += 1
                    do { try await Task.sleep(for: .seconds(5 * attempt)) } catch { return }
                } catch {
                    await board.set(id, entry.index, .failed, Self.detail(error))
                    break
                }
            }
        }
    }

    private func draftsAnswer(_ batch: BatchBoard.Batch) -> CallTool.Result {
        let saved = batch.count(.saved)
        let total = batch.items.count
        var lines: [String]
        if batch.isOver {
            lines = ["Saved \(saved) of \(total) drafts in Drafts. Nothing was sent."]
            if saved > 0 { lines.append("send_drafts with batch \"\(batch.id)\" sends them after one approval.") }
        } else {
            lines = [
                "Saving \(total) drafts: \(saved) saved so far; the others follow in the background. Nothing is sent.",
                "batch_status with id \"\(batch.id)\" follows them; once it says finished, send_drafts with batch \"\(batch.id)\" sends them after one approval.",
            ]
        }
        let listed = total <= Self.listedItems ? batch.items : batch.items.filter { $0.status != .saved && $0.status != .waiting }
        lines += listed.prefix(Self.listedItems).map { item in
            switch item.status {
            case .saved: "\(item.index + 1). Saved for \(item.recipients): \(item.draft?.opaque ?? "")"
            case .waiting: "\(item.index + 1). Not saved yet."
            default: "\(item.index + 1). Not saved. \(item.detail)"
            }
        }
        return result(lines.joined(separator: "\n"), [
            "batch": .string(batch.id), "finished": .bool(batch.isOver), "saved": .int(saved), "total": .int(total),
            "results": .array(listed.prefix(Self.listedItems).map { item in
                var fields: [String: Value] = ["index": .int(item.index), "status": .string(item.status.rawValue)]
                if let draft = item.draft { fields["draft_id"] = .string(draft.opaque) }
                if !item.detail.isEmpty && item.status != .saved { fields["detail"] = .string(item.detail) }
                return .object(fields)
            }),
        ])
    }

    // MARK: Drafts sent together

    /// One panel and one Touch ID for up to 500 drafts; each approved email stays bound to its own digest. They
    /// leave one by one, spaced out and within the user's limits, waiting for room when a limit is reached.
    func sendDrafts(_ arguments: [String: Value]) async throws -> CallTool.Result {
        let ids = try await batchDraftIDs(arguments)
        let spacing = try spacingArgument(arguments["spacing_seconds"], count: ids.count)
        let start = try startArgument(arguments["start_at"])
        var refused: [MessageID: String] = [:]
        var pending: [(id: MessageID, request: ApprovalRequest)] = []
        let pool = DataPool()
        let contacted = ContactCache()
        let held = await board.heldDrafts()
        for id in ids {
            if let other = held[id] {
                refused[id] = "This draft is already in batch \(other), so it is not sent twice."
                continue
            }
            do {
                let draft = try await backend.draftForSending(id)
                let message = try await compose([:], base: draft.message, baseFiles: draft.files.map(pool.intern))
                try checkRecipients(message)
                pending.append((id, try await approvalRequest(message, tool: .sendDrafts, context: "A draft saved in Drafts", extra: [:], contacted: contacted)))
            } catch {
                refused[id] = Self.detail(error)
            }
        }
        guard !pending.isEmpty else {
            return sendsAnswer(nil, ids: ids, statuses: ids.map { (.refused, refused[$0] ?? "") })
        }
        let sends = ledger.recentSends()
        let schedule = BatchSchedule(
            start: start, spacing: spacing, sendsPerHour: policy.sendsPerHour, sendsPerDay: policy.sendsPerDay,
            finish: SendBudget.finish(count: pending.count, start: start ?? Date(), spacing: spacing, policy: policy, sends: sends)
        )
        let request = BatchApprovalRequest(tool: ToolID.sendDrafts.rawValue, client: client, items: pending.map(\.request), schedule: schedule)
        switch await desk.reviewBatch(request) {
        case .approved(let approved):
            var queue: [QueuedEmail] = []
            var items: [BatchBoard.Item] = []
            let requests = Dictionary(uniqueKeysWithValues: pending.map { ($0.id, $0.request) })
            for (index, id) in ids.enumerated() {
                let message = requests[id]?.message
                var item = BatchBoard.Item(
                    index: index, recipients: message?.envelopeRecipients.joined(separator: ", ") ?? "",
                    subject: message?.subject ?? "", status: .waiting, detail: "", draft: id
                )
                if let reason = refused[id] {
                    item.status = .refused
                    item.detail = reason
                } else if let request = requests[id], let email = approved[request.id] {
                    queue.append(QueuedEmail(index: index, draft: id, message: email))
                } else {
                    item.status = .skipped
                    item.detail = "The user left this email out; the draft stays in Drafts."
                }
                items.append(item)
            }
            let estimate = SendBudget.finish(count: queue.count, start: start ?? Date(), spacing: spacing, policy: policy, sends: ledger.recentSends())
            let id = await board.open(kind: .sends, client: client, items: items, start: start, spacing: spacing, estimate: estimate)
            let (board, backend, ledger, live, client) = (self.board, self.backend, self.ledger, self.livePolicy, self.client)
            let emails = queue
            let account = try await backend.ownAddress().email.lowercased()
            await board.run(id) {
                await Self.sendQueue(emails, batch: id, board: board, backend: backend, ledger: ledger, policy: live,
                                     account: account, spacing: spacing, start: start, client: client)
            }
            let batch = await board.settle(id, within: inlineWait)
            return sendsAnswer(batch, ids: ids, statuses: (batch?.items ?? items).map { ($0.status, $0.detail) })
        case .rejected(let reason):
            throw PosternError(.approvalRejected, "The user rejected these emails, so nothing was sent" + (reason.map { ": \($0)" } ?? "."))
        case .notAuthenticated:
            throw PosternError(.approvalRejected, "The user did not confirm with Touch ID, so nothing was sent.")
        case .expired:
            throw PosternError(.approvalTimeout, "The user did not answer in time, so nothing was sent.")
        }
    }

    /// The draft ids given, or every draft a create_drafts batch saved.
    private func batchDraftIDs(_ arguments: [String: Value]) async throws -> [MessageID] {
        var texts: [String] = []
        switch (arguments["ids"], arguments["batch"]) {
        case (.array(let list)?, nil):
            guard (1...Self.batchLimit).contains(list.count) else {
                throw PosternError(.invalidArgument, "ids is a list of 1 to \(Self.batchLimit) draft ids.")
            }
            texts = try list.map { value in
                guard case .string(let text) = value else { throw PosternError(.invalidArgument, "ids is a list of draft ids.") }
                return text
            }
        case (nil, .string(let name)?):
            guard let batch = await board.batch(name) else {
                throw PosternError(.notFound, "No batch \(name). Batches last until Postern quits; pass the draft ids instead.")
            }
            guard batch.kind == .drafts else { throw PosternError(.invalidArgument, "Batch \(name) sends emails; it holds no drafts.") }
            guard batch.isOver else {
                throw PosternError(.invalidArgument, "Batch \(name) is still saving drafts (\(batch.count(.saved)) of \(batch.items.count)). Try again once batch_status says it is finished.")
            }
            texts = batch.items.compactMap { $0.status == .saved ? $0.draft?.opaque : nil }
            guard !texts.isEmpty else { throw PosternError(.notFound, "Batch \(name) saved no draft.") }
        case (nil, nil):
            throw PosternError(.invalidArgument, "Give ids, or batch with the id create_drafts returned.")
        default:
            throw PosternError(.invalidArgument, "Give ids or batch, not both.")
        }
        var ids: [MessageID] = []
        var seen: Set<MessageID> = []
        var checked: Set<String> = []
        for text in texts {
            guard let id = MessageID(opaque: text) else { throw PosternError(.invalidArgument, "\(text) is not a Postern message id.") }
            guard id.mailbox == "Drafts" else {
                throw PosternError(.invalidArgument, "\(text) is not a draft. Use an id from create_draft or the Drafts mailbox.")
            }
            if checked.insert(id.mailbox).inserted, policy.isHidden(try await backend.displayName(ofRawMailbox: id.mailbox)) {
                throw PosternError(.scopeHidden, "The user has hidden this mailbox from Postern.")
            }
            if seen.insert(id).inserted { ids.append(id) }
        }
        return ids
    }

    /// The pause between two emails: given, or two seconds for a short batch and thirty for a long one, so a long
    /// batch does not reach Proton as a burst.
    private func spacingArgument(_ value: Value?, count: Int) throws -> TimeInterval {
        let base = Double(batchSpacing.components.seconds) + Double(batchSpacing.components.attoseconds) / 1e18
        switch value {
        case nil: return count <= 20 ? base : base * 15
        case .int(let seconds)? where (1...3600).contains(seconds): return Double(seconds)
        case .double(let seconds)? where seconds >= 1 && seconds <= 3600: return seconds
        default: throw PosternError(.invalidArgument, "spacing_seconds is a number of seconds from 1 to 3600.")
        }
    }

    /// A start time within the next thirty days, or nil to start at once.
    private func startArgument(_ value: Value?) throws -> Date? {
        guard let value else { return nil }
        guard case .string(let text) = value, let date = Self.date(text) else {
            throw PosternError(.invalidArgument, "start_at is a date and time such as 2026-11-10T08:00 (the Mac's time zone) or 2026-11-10T08:00:00+01:00.")
        }
        let wait = date.timeIntervalSinceNow
        guard wait > -60 else { throw PosternError(.invalidArgument, "start_at is in the past.") }
        guard wait < 30 * 86_400 else { throw PosternError(.invalidArgument, "start_at is more than thirty days away.") }
        return wait > 0 ? date : nil
    }

    static func date(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = options
            if let date = iso.date(from: trimmed) { return date }
        }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let date = local.date(from: trimmed) { return date }
        }
        return nil
    }

    private func sendsAnswer(
        _ batch: BatchBoard.Batch?, ids: [MessageID], statuses: [(status: BatchBoard.ItemStatus, detail: String)]
    ) -> CallTool.Result {
        let sent = statuses.filter { $0.status == .sent }.count
        let waiting = statuses.filter { $0.status == .waiting }.count
        var lines: [String]
        if let batch, !batch.isOver {
            let approved = sent + waiting + statuses.filter { $0.status == .failed }.count
            var plan = "The others leave one every \(Self.seconds(batch.spacing)) within the user's limits (\(livePolicy().sendsPerHour) per hour, \(livePolicy().sendsPerDay) per day)"
            if let start = batch.start, start > Date() { plan += ", starting \(Self.dateText(start))" }
            if let estimate = batch.estimate { plan += "; the last should leave around \(Self.dateText(estimate))" }
            lines = [
                "The user approved \(approved) emails with Touch ID. \(sent) sent so far. \(plan).",
                "batch_status with id \"\(batch.id)\" follows them; cancel_batch stops the ones not sent yet, and their drafts stay in Drafts.",
            ]
        } else {
            lines = [sent == 0 ? "Nothing was sent." : "The user approved the batch with Touch ID; \(sent) of \(ids.count) emails were sent."]
        }
        let listed = ids.indices.filter { index in
            ids.count <= Self.listedItems || (statuses[index].status != .sent && statuses[index].status != .waiting)
        }.prefix(Self.listedItems)
        lines += listed.map { "\(ids[$0].opaque): \(statuses[$0].status.rawValue). \(statuses[$0].detail)" }
        var fields: [String: Value] = [
            "sent": .int(sent), "waiting": .int(waiting),
            "results": .array(listed.map { index in
                .object(["id": .string(ids[index].opaque), "status": .string(statuses[index].status.rawValue),
                         "detail": .string(statuses[index].detail)])
            }),
        ]
        if let batch { fields["batch"] = .string(batch.id) }
        return result(lines.joined(separator: "\n"), fields)
    }

    struct QueuedEmail: Sendable {
        let index: Int
        let draft: MessageID?
        let message: ApprovedMessage
    }

    /// Sends the approved emails in order, each after the pause, the start time and room in the limits; holds while
    /// Postern is paused, send_drafts is off or Bridge cannot take mail. Before each email it checks again that its
    /// recipients and sender are still allowed and that its draft is still in Drafts (deleting the draft holds the
    /// email back), reserves its place in the limits, and dates it with the time it leaves.
    static func sendQueue(
        _ queue: [QueuedEmail], batch id: String, board: BatchBoard, backend: any MailBackend, ledger: any SendLedger,
        policy: @escaping @Sendable () -> Policy, account: String, spacing: TimeInterval, start: Date?, client: String
    ) async {
        let tool = ToolID.sendDrafts.rawValue
        do {
            if let start, start > Date() {
                await board.set(id, phase: .waiting(until: start, reason: "The batch starts at the time the user approved."))
                try await sleep(until: start)
            }
            var last: Date?
            for email in queue {
                try Task.checkCancellation()
                guard await board.status(id, email.index) == .waiting else { continue }
                if let last, spacing > 0 { try await sleep(until: last.addingTimeInterval(spacing)) }
                var attempt = 0
                func hold(_ error: PosternError) async throws {
                    // Bridge, the sign-in or the setup is at fault, not this email: wait, then every ten minutes.
                    let delay = retryDelays[min(attempt, retryDelays.count - 1)]
                    attempt += 1
                    await board.set(id, phase: .waiting(until: Date().addingTimeInterval(delay), reason: "The next email could not be handed to Bridge; Postern tries again. \(error.message)"))
                    try await sleep(until: Date().addingTimeInterval(delay))
                }
                while true {
                    try await waitForTurn(id, board: board, ledger: ledger, policy: policy)
                    let live = policy()
                    if let barred = email.message.recipients.first(where: { !live.mayReceive($0) }) {
                        await board.set(id, email.index, .refused, "\(barred) is no longer among the user's approved recipients; the draft stays in Drafts.")
                        await board.record(client, tool, PosternErrorCode.recipientNotAllowed.rawValue)
                        break
                    }
                    let sender = email.message.envelopeFrom.lowercased()
                    guard sender == account || live.senderAddresses.contains(sender) else {
                        await board.set(id, email.index, .refused, "\(sender) is no longer one of the user's sender addresses; the draft stays in Drafts.")
                        await board.record(client, tool, PosternErrorCode.senderNotAllowed.rawValue)
                        break
                    }
                    if let draft = email.draft {
                        do {
                            guard try await backend.draftExists(draft) else {
                                await board.set(id, email.index, .skipped, "Its draft was deleted from Drafts, so this email did not leave.")
                                break
                            }
                        } catch let error as PosternError where holdingCodes.contains(error.code) {
                            try await hold(error)
                            continue
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            await board.set(id, email.index, .failed, detail(error) + " The draft stays in Drafts.")
                            break
                        }
                    }
                    // The place in the limits is taken in the same step as it is checked: no other send can take it.
                    let now = Date()
                    guard ledger.reserve(at: now, allowed: { SendBudget.remaining(live, sends: $0, now: now) > 0 }) else { continue }
                    guard await board.claim(id, email.index) else {
                        ledger.release(at: now)
                        break
                    }
                    do {
                        try await backend.send(email.message.leaving(at: now))
                        last = now
                        var detail = "Sent to \(email.message.recipients.joined(separator: ", "))."
                        if let draft = email.draft {
                            do { try await backend.deleteDraft(draft) } catch {
                                detail += " Its draft could not be removed from Drafts: delete it there so it is not sent twice."
                            }
                        }
                        await board.set(id, email.index, .sent, detail)
                        await board.record(client, tool, "ok")
                        break
                    } catch is CancellationError {
                        // Stopped before the message was handed over: it did not leave.
                        ledger.release(at: now)
                        await board.unclaim(id, email.index)
                        throw CancellationError()
                    } catch let error as PosternError where error.code == .sendUncertain {
                        // It may have left: it stays counted, and no batch sends its draft again.
                        last = now
                        await board.set(id, email.index, .uncertain, error.message)
                        await board.record(client, tool, error.code.rawValue)
                        break
                    } catch let error as PosternError where holdingCodes.contains(error.code) {
                        ledger.release(at: now)
                        await board.unclaim(id, email.index)
                        try await hold(error)
                    } catch {
                        ledger.release(at: now)
                        last = now
                        await board.set(id, email.index, .failed, detail(error) + " The draft stays in Drafts.")
                        await board.record(client, tool, (error as? PosternError)?.code.rawValue ?? "failed")
                        break
                    }
                }
            }
        } catch {
            // Cancelled: the board has marked what was left.
        }
    }

    /// Returns when the next email may leave: Postern on, send_drafts on, and room in the limits.
    private static func waitForTurn(
        _ id: String, board: BatchBoard, ledger: any SendLedger, policy: @Sendable () -> Policy
    ) async throws {
        while true {
            try Task.checkCancellation()
            let current = policy()
            if !current.allows(.sendDrafts) {
                let reason = current.paused
                    ? "Postern is paused; the batch goes on when the user resumes it."
                    : "send_drafts is off in Postern; the batch goes on when the user turns it back on."
                await board.set(id, phase: .waiting(until: nil, reason: reason))
                try await Task.sleep(for: .seconds(15))
                continue
            }
            if let room = SendBudget.nextRoom(current, sends: ledger.recentSends()) {
                await board.set(id, phase: .waiting(until: room, reason: "The user's sending limit is reached (\(current.sendsPerHour) per hour, \(current.sendsPerDay) per day)."))
                try await Task.sleep(for: .seconds(max(1, min(60, room.timeIntervalSinceNow))))
                continue
            }
            await board.set(id, phase: .running)
            return
        }
    }

    /// Sleeps until a wall-clock time, a minute at most at a time, so a Mac that slept or a changed clock is seen.
    static func sleep(until date: Date) async throws {
        while true {
            let wait = date.timeIntervalSinceNow
            guard wait > 0 else { return }
            try await Task.sleep(for: .seconds(min(wait, 60)))
        }
    }

    // MARK: Following a batch

    func batchStatus(_ arguments: [String: Value]) async throws -> CallTool.Result {
        guard let id = string(arguments["id"]) else {
            let batches = await board.all()
            let lines = batches.isEmpty
                ? ["No batch since Postern started."]
                : batches.map { "\($0.id): \(Self.summary($0))" }
            return result(lines.joined(separator: "\n"), ["batches": .array(batches.map { .object(Self.fields($0)) })])
        }
        guard let batch = await board.batch(id) else {
            throw PosternError(.notFound, "No batch \(id). Batches last until Postern quits.")
        }
        let offset = max(0, int(arguments["offset"]) ?? 0)
        let limit = min(100, max(1, int(arguments["limit"]) ?? 100))
        let items = bool(arguments["all"]) == true
            ? Array(batch.items.dropFirst(offset).prefix(limit))
            : Array(batch.items.filter { [.refused, .failed, .uncertain, .skipped, .cancelled].contains($0.status) }.prefix(limit))
        var lines = ["\(batch.id): \(Self.summary(batch))"]
        lines += items.map { item in
            let draft = item.draft.map { " Draft \($0.opaque)." } ?? ""
            return "\(item.index + 1). \(item.recipients.isEmpty ? "(no recipient)" : item.recipients), \(item.status.rawValue). \(item.detail)\(draft)"
        }
        var fields = Self.fields(batch)
        fields["items"] = .array(items.map { item in
            var entry: [String: Value] = [
                "index": .int(item.index), "recipients": .string(item.recipients), "subject": .string(item.subject),
                "status": .string(item.status.rawValue), "detail": .string(item.detail),
            ]
            if let draft = item.draft { entry["draft_id"] = .string(draft.opaque) }
            return .object(entry)
        })
        return result(lines.joined(separator: "\n"), fields)
    }

    func cancelBatch(_ arguments: [String: Value]) async throws -> CallTool.Result {
        guard let id = string(arguments["id"]) else { throw PosternError(.invalidArgument, "id is the batch to stop.") }
        guard let before = await board.batch(id) else { throw PosternError(.notFound, "No batch \(id). Batches last until Postern quits.") }
        if before.isOver { return result("Batch \(id) was already over: \(Self.summary(before)).", Self.fields(before)) }
        let batch = await board.cancel(id) ?? before
        var text = batch.kind == .sends
            ? "Stopped batch \(id): \(batch.count(.sent)) sent before, \(batch.count(.cancelled)) will not leave; their drafts stay in Drafts."
            : "Stopped batch \(id): \(batch.count(.saved)) drafts saved before, \(batch.count(.cancelled)) not saved."
        if batch.count(.sending) > 0 {
            text += " 1 email was being handed to Bridge at that moment: it leaves only if Bridge already had it; batch_status tells."
        }
        return result(text, Self.fields(batch))
    }

    static func summary(_ batch: BatchBoard.Batch) -> String {
        let what = batch.kind == .sends ? "sending \(batch.items.count) drafts" : "saving \(batch.items.count) drafts"
        let counts = BatchBoard.ItemStatus.allCases.compactMap { status in
            let count = batch.count(status)
            return count == 0 ? nil : "\(count) \(status.rawValue)"
        }.joined(separator: ", ")
        let phase: String = switch batch.phase {
        case .running: "running"
        case .finished: "finished"
        case .cancelled: "cancelled"
        case .waiting(let until, let reason): "waiting" + (until.map { " until \(dateText($0))" } ?? "") + ". \(reason)"
        }
        return "\(what) for \(batch.client), \(counts); \(phase)"
    }

    static func fields(_ batch: BatchBoard.Batch) -> [String: Value] {
        let iso = ISO8601DateFormatter()
        var fields: [String: Value] = [
            "id": .string(batch.id), "kind": .string(batch.kind.rawValue), "client": .string(batch.client),
            "created": .string(iso.string(from: batch.created)), "total": .int(batch.items.count),
            "counts": .object(Dictionary(uniqueKeysWithValues: BatchBoard.ItemStatus.allCases.map { ($0.rawValue, .int(batch.count($0))) })),
        ]
        switch batch.phase {
        case .running: fields["phase"] = "running"
        case .finished: fields["phase"] = "finished"
        case .cancelled: fields["phase"] = "cancelled"
        case .waiting(let until, let reason):
            fields["phase"] = "waiting"
            fields["reason"] = .string(reason)
            if let until { fields["waiting_until"] = .string(iso.string(from: until)) }
        }
        if batch.kind == .sends {
            fields["spacing_seconds"] = .double(batch.spacing)
            if let start = batch.start { fields["start_at"] = .string(iso.string(from: start)) }
            if let estimate = batch.estimate { fields["estimated_finish"] = .string(iso.string(from: estimate)) }
        }
        return fields
    }

    // MARK: The outbox

    func listOutbox() async throws -> CallTool.Result {
        let files = try await backend.outboxFiles()
        let iso = ISO8601DateFormatter()
        let shown = files.prefix(1000)
        var lines = [files.isEmpty
            ? "The outbox (~/Downloads/Postern/Outbox) is empty. The user puts there the files apps may attach."
            : "\(files.count) files in the outbox (~/Downloads/Postern/Outbox). Attach them by these names."]
        lines += shown.map { "\($0.path) (\(Self.size($0.size)))" }
        return result(lines.joined(separator: "\n"), ["files": .array(shown.map { file in
            var entry: [String: Value] = ["name": .string(file.path), "size": .int(file.size)]
            if let modified = file.modified { entry["modified"] = .string(iso.string(from: modified)) }
            return .object(entry)
        })])
    }

    // MARK: Helpers

    static func detail(_ error: any Error) -> String {
        (error as? PosternError).map { "\($0.code.rawValue): \($0.message)" } ?? "Postern could not complete this one."
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func seconds(_ interval: TimeInterval) -> String {
        interval < 60 ? "\(Int(interval)) s" : interval.truncatingRemainder(dividingBy: 60) == 0
            ? "\(Int(interval / 60)) min" : "\(Int(interval)) s"
    }

    private func int(_ value: Value?) -> Int? {
        switch value {
        case .int(let number)?: number
        case .double(let number)?: Int(number)
        default: nil
        }
    }
}

/// The outbox files a batch has read, by name, so each is read once and its bytes are shared by every draft.
final class AttachmentCache: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: OutgoingAttachment] = [:]

    func file(_ name: String) -> OutgoingAttachment? { lock.withLock { files[name] } }
    func keep(_ file: OutgoingAttachment, as name: String) { lock.withLock { files[name] = file } }
}

/// Whether Sent holds mail to an address, asked once per address in a batch.
final class ContactCache: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: Bool] = [:]

    func known(_ email: String) -> Bool? { lock.withLock { answers[email] } }
    func remember(_ email: String, _ known: Bool) { lock.withLock { answers[email] = known } }
}

/// Identical attachments of many drafts held once in memory: a CV attached to 500 drafts takes the room of one.
final class DataPool: @unchecked Sendable {
    private let lock = NSLock()
    private var pool: [String: Data] = [:]

    func intern(_ file: OutgoingAttachment) -> OutgoingAttachment {
        let key = file.sha256
        let data = lock.withLock { () -> Data in
            if let known = pool[key] { return known }
            pool[key] = file.data
            return file.data
        }
        return (try? OutgoingAttachment.make(filename: file.filename, data: data, mimeType: file.mimeType)) ?? file
    }
}
