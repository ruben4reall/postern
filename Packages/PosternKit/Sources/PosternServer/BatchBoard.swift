import Foundation
import PosternModel

/// Long batches run here, outside any one call: drafts being saved, and approved emails waiting for their turn.
/// It lives as long as the app, for every client; quitting Postern stops what is left, and nothing is lost, since a
/// draft leaves Drafts only once its email is sent.
public actor BatchBoard {
    public enum Kind: String, Sendable {
        case drafts, sends
    }

    public enum ItemStatus: String, Sendable, CaseIterable {
        /// `sending`: being handed to Bridge. `uncertain`: the connection broke as Bridge took it, so it may have left.
        case waiting, sending, saved, sent, uncertain, refused, skipped, failed, cancelled
    }

    public struct Item: Sendable {
        public let index: Int
        public let recipients: String
        public let subject: String
        public var status: ItemStatus
        public var detail: String
        /// For drafts, the draft saved; for sends, the draft the email came from.
        public var draft: MessageID?
    }

    public enum Phase: Sendable, Equatable {
        case running
        /// Waiting for the start time, the sending limits, Bridge, or the user to turn sending back on.
        case waiting(until: Date?, reason: String)
        case finished
        case cancelled
    }

    /// What the user decided on the approval panel of a send batch.
    public enum Decision: Sendable, Equatable {
        /// The drafts are being read, or the panel is open.
        case pending
        case approved
        case rejected(reason: String?)
        case notAuthenticated
        case expired
    }

    public struct Batch: Sendable, Identifiable {
        public let id: String
        public let kind: Kind
        public let client: String
        public let created: Date
        public var items: [Item]
        public var phase: Phase
        public var start: Date?
        public var spacing: TimeInterval
        /// When the last email should leave, as estimated when the batch was approved.
        public var estimate: Date?
        /// For sends: the user's answer on the panel. Drafts batches need none.
        public var decision: Decision = .pending
        /// Approved before Postern last quit, and waiting for the user to resume it with Touch ID.
        public var interrupted = false

        public var isOver: Bool { phase == .finished || phase == .cancelled }
        public func count(_ status: ItemStatus) -> Int { items.lazy.filter { $0.status == status }.count }
    }

    public typealias Recorder = @Sendable (_ client: String, _ tool: String, _ outcome: String) -> Void

    private var batches: [String: Batch] = [:]
    private var order: [String] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private let onChange: @Sendable () -> Void
    private let recorder: Recorder
    private var notifying = false
    /// Finished batches kept for batch_status and the window.
    static let kept = 20
    private let store: (any BatchStore)?
    /// The queues of approved send batches, kept on disk as they go.
    private var queues: [String: (emails: [SendTools.QueuedEmail], noAttachment: Bool)] = [:]
    /// Batches found on disk at launch, until the user resumes them.
    private var restored: [String: BatchRecord] = [:]
    private var dirty: Set<String> = []
    /// Single emails waiting for the user's answer, and those sent in the last ten minutes, by fingerprint.
    private var pendingSingles: Set<String> = []
    private var recentSingles: [String: Date] = [:]

    /// - Parameters:
    ///   - onChange: called after every change, for the window.
    ///   - record: writes one line of the activity log for each email a batch sends or fails to send.
    ///   - store: where approved send batches are kept, so they can be resumed after Postern restarts.
    public init(
        onChange: @escaping @Sendable () -> Void = {}, record: @escaping Recorder = { _, _, _ in },
        store: (any BatchStore)? = nil
    ) {
        self.onChange = onChange
        self.recorder = record
        self.store = store
    }

    // MARK: Across launches

    /// Brings back the batches approved before Postern quit. They wait for the user to resume them: an email that
    /// was being handed to Bridge at that moment may have left, so it is marked uncertain and never sent again.
    public func restore() {
        guard let store else { return }
        for record in store.load() where batches[record.id] == nil {
            let items = record.items.map { item -> Item in
                let status = ItemStatus(rawValue: item.status) ?? .failed
                return status == .sending
                    ? Item(index: item.index, recipients: item.recipients, subject: item.subject, status: .uncertain,
                           detail: "Postern stopped while this email was being handed to Bridge: it may have left. Look in Sent before sending it again.",
                           draft: item.draft.flatMap(MessageID.init(opaque:)))
                    : Item(index: item.index, recipients: item.recipients, subject: item.subject, status: status,
                           detail: item.detail, draft: item.draft.flatMap(MessageID.init(opaque:)))
            }
            var batch = Batch(id: record.id, kind: .sends, client: record.client, created: record.created, items: items,
                              phase: .waiting(until: nil, reason: "Postern restarted. Resume the batch in Postern's window to send the \(record.left) emails left."),
                              start: record.start, spacing: record.spacing, estimate: record.estimate)
            batch.decision = .approved
            batch.interrupted = true
            batches[record.id] = batch
            order.append(record.id)
            restored[record.id] = record
        }
        order.sort { (batches[$0]?.created ?? .distantPast) < (batches[$1]?.created ?? .distantPast) }
        notify()
    }

    /// The batch as kept on disk, while it waits to be resumed.
    public func interruptedRecord(_ id: String) -> BatchRecord? {
        guard batches[id]?.interrupted == true else { return nil }
        return restored[id]
    }

    /// An approved queue, kept on disk from now on.
    func keep(_ id: String, queue: [SendTools.QueuedEmail], noAttachment: Bool) {
        queues[id] = (queue, noAttachment)
        restored[id] = nil
        if var batch = batches[id], batch.interrupted {
            batch.interrupted = false
            batch.phase = .running
            batches[id] = batch
        }
        touch(id)
    }

    private func record(_ id: String) -> BatchRecord? {
        guard let batch = batches[id], let queue = queues[id] else { return nil }
        return BatchRecord(
            id: id, client: batch.client, created: batch.created, start: batch.start, spacing: batch.spacing,
            estimate: batch.estimate,
            items: batch.items.map { BatchRecord.Item(index: $0.index, recipients: $0.recipients, subject: $0.subject,
                                                      status: $0.status.rawValue, detail: $0.detail, draft: $0.draft?.opaque) },
            queue: queue.emails.map { BatchRecord.Queued(index: $0.index, draft: $0.draft.opaque, digest: $0.claim.digest,
                                                         messageID: $0.messageID, recipients: $0.recipients, sender: $0.sender) },
            noAttachment: queue.noAttachment
        )
    }

    /// Marks a batch to write to disk with the next notice.
    private func touch(_ id: String) {
        if queues[id] != nil || restored[id] != nil { dirty.insert(id) }
        notify()
    }

    private func persist() {
        guard let store else { dirty = []; return }
        for id in dirty {
            if batches[id]?.isOver ?? true {
                store.delete(id)
                queues[id] = nil
                restored[id] = nil
            } else if let record = record(id) {
                store.save(record)
            }
        }
        dirty = []
    }

    public func all() -> [Batch] { order.reversed().compactMap { batches[$0] } }

    public func batch(_ id: String) -> Batch? { batches[id] }

    /// Stops what is left of a batch. What is already saved or sent stays so; an email being handed to Bridge at
    /// that moment is stopped if it has not reached Bridge yet, and keeps `sending` until the worker knows.
    @discardableResult
    public func cancel(_ id: String) -> Batch? {
        guard var batch = batches[id] else { return nil }
        guard !batch.isOver else { return batch }
        tasks[id]?.cancel()
        for index in batch.items.indices where batch.items[index].status == .waiting {
            batch.items[index].status = .cancelled
            batch.items[index].detail = batch.kind == .sends
                ? "Cancelled before it left; the draft stays in Drafts."
                : "Cancelled before it was saved."
        }
        batch.phase = .cancelled
        batches[id] = batch
        touch(id)
        return batch
    }

    // MARK: Single emails

    /// Takes an email for its panel, or says why it should not be shown again: the same email already waits for the
    /// user, or left in the last ten minutes. An app whose call timed out while the panel was open calls again.
    func holdSingle(_ fingerprint: String, now: Date = Date()) -> String? {
        recentSingles = recentSingles.filter { now.timeIntervalSince($0.value) < 600 }
        if pendingSingles.contains(fingerprint) {
            return "This same email is already waiting for the user's answer on Postern's panel, so it is not shown twice. Wait for that answer; do not send it again."
        }
        if let sent = recentSingles[fingerprint] {
            let time = sent.formatted(date: .omitted, time: .shortened)
            return "This same email was sent at \(time). Postern does not send the same email twice within ten minutes."
        }
        pendingSingles.insert(fingerprint)
        return nil
    }

    /// The user answered: an email that left, or may have, is remembered for ten minutes.
    func releaseSingle(_ fingerprint: String, sent: Bool) {
        pendingSingles.remove(fingerprint)
        if sent { recentSingles[fingerprint] = Date() }
    }

    // MARK: For the tools

    /// Opens a batch. A send batch never takes a draft another send batch holds or sent: such an item is refused
    /// here, in the same step, so two batches approved for the same drafts cannot both send them.
    func open(
        kind: Kind, client: String, items: [Item], start: Date? = nil, spacing: TimeInterval = 0, estimate: Date? = nil,
        phase: Phase = .running
    ) -> String {
        var items = items
        if kind == .sends {
            let held = heldDrafts()
            for index in items.indices where items[index].status == .waiting {
                if let draft = items[index].draft, let other = held[draft] {
                    items[index].status = .refused
                    items[index].detail = "This draft is already in batch \(other), so it is not sent twice."
                }
            }
        }
        var id: String
        repeat { id = String(UUID().uuidString.lowercased().prefix(8)) } while batches[id] != nil
        batches[id] = Batch(id: id, kind: kind, client: client, created: Date(), items: items, phase: phase,
                            start: start, spacing: spacing, estimate: estimate)
        order.append(id)
        trim()
        notify()
        return id
    }

    /// Runs the work of a batch; the batch is finished when the work returns, unless it was cancelled.
    func run(_ id: String, _ work: @escaping @Sendable () async -> Void) {
        tasks[id] = Task {
            await work()
            self.finish(id)
        }
    }

    func status(_ id: String, _ index: Int) -> ItemStatus? {
        batches[id]?.items.first { $0.index == index }?.status
    }

    /// Takes an email waiting in a running batch for sending; false when it was cancelled or is no longer waiting.
    func claim(_ id: String, _ index: Int) -> Bool {
        guard var batch = batches[id], !batch.isOver,
              let position = batch.items.firstIndex(where: { $0.index == index }), batch.items[position].status == .waiting else {
            return false
        }
        batch.items[position].status = .sending
        batches[id] = batch
        touch(id)
        return true
    }

    /// Puts back an email that did not reach Bridge: waiting again, or cancelled if the batch was stopped meanwhile.
    func unclaim(_ id: String, _ index: Int) {
        guard let batch = batches[id], let item = batch.items.first(where: { $0.index == index }), item.status == .sending else { return }
        if batch.phase == .cancelled {
            set(id, index, .cancelled, "Stopped before it left; the draft stays in Drafts.")
        } else {
            set(id, index, .waiting, "")
        }
    }

    /// The drafts that a batch of sends holds, or has sent or may have sent, by the batch that holds each.
    func heldDrafts() -> [MessageID: String] {
        var held: [MessageID: String] = [:]
        for batch in batches.values where batch.kind == .sends {
            for item in batch.items where [.waiting, .sending, .sent, .uncertain].contains(item.status) {
                if let draft = item.draft { held[draft] = batch.id }
            }
        }
        return held
    }

    func set(_ id: String, _ index: Int, _ status: ItemStatus, _ detail: String, draft: MessageID? = nil) {
        guard var batch = batches[id], let position = batch.items.firstIndex(where: { $0.index == index }) else { return }
        batch.items[position].status = status
        batch.items[position].detail = detail
        if let draft { batch.items[position].draft = draft }
        batches[id] = batch
        touch(id)
    }

    /// Names an email once its draft is read: who it goes to and its subject.
    func describe(_ id: String, _ index: Int, recipients: String, subject: String) {
        guard var batch = batches[id], let position = batch.items.firstIndex(where: { $0.index == index }) else { return }
        batch.items[position] = Item(index: index, recipients: recipients, subject: subject,
                                     status: batch.items[position].status, detail: batch.items[position].detail,
                                     draft: batch.items[position].draft)
        batches[id] = batch
        notify()
    }

    /// Records the user's answer. Anything but an approval ends the batch: its emails stay drafts.
    func decide(_ id: String, _ decision: Decision, estimate: Date? = nil) {
        guard var batch = batches[id], !batch.isOver else { return }
        batch.decision = decision
        if let estimate { batch.estimate = estimate }
        if decision != .approved {
            let why: String = switch decision {
            case .rejected(let reason): "The user rejected the batch" + (reason.map { ": \($0)" } ?? "") + "; the draft stays in Drafts."
            case .notAuthenticated: "The user did not confirm with Touch ID; the draft stays in Drafts."
            case .expired: "The user did not answer in time; the draft stays in Drafts."
            default: "The draft stays in Drafts."
            }
            for index in batch.items.indices where batch.items[index].status == .waiting {
                batch.items[index].status = .skipped
                batch.items[index].detail = why
            }
            batch.phase = .cancelled
            tasks[id] = nil
        }
        batches[id] = batch
        touch(id)
    }

    func set(_ id: String, phase: Phase) {
        guard var batch = batches[id], !batch.isOver, batch.phase != phase else { return }
        batch.phase = phase
        batches[id] = batch
        touch(id)
    }

    func record(_ client: String, _ tool: String, _ outcome: String) {
        recorder(client, tool, outcome)
    }

    /// The batch once it is over, or as it stands after `limit`.
    func settle(_ id: String, within limit: Duration) async -> Batch? {
        let deadline = ContinuousClock.now + limit
        while let batch = batches[id], !batch.isOver, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
        }
        return batches[id]
    }

    private func finish(_ id: String) {
        tasks[id] = nil
        guard var batch = batches[id], !batch.isOver else { return }
        batch.phase = .finished
        batches[id] = batch
        touch(id)
    }

    /// Tells the window at most a few times a second, however fast a batch moves.
    private func notify() {
        guard !notifying else { return }
        notifying = true
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            self.flush()
        }
    }

    private func flush() {
        notifying = false
        persist()
        onChange()
    }

    private func trim() {
        while order.count > Self.kept, let oldest = order.first(where: { batches[$0]?.isOver ?? true }) {
            order.removeAll { $0 == oldest }
            batches[oldest] = nil
        }
    }
}
