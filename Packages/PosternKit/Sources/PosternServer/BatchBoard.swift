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

    /// - Parameters:
    ///   - onChange: called after every change, for the window.
    ///   - record: writes one line of the activity log for each email a batch sends or fails to send.
    public init(onChange: @escaping @Sendable () -> Void = {}, record: @escaping Recorder = { _, _, _ in }) {
        self.onChange = onChange
        self.recorder = record
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
        notify()
        return batch
    }

    // MARK: For the tools

    /// Opens a batch. A send batch never takes a draft another send batch holds or sent: such an item is refused
    /// here, in the same step, so two batches approved for the same drafts cannot both send them.
    func open(
        kind: Kind, client: String, items: [Item], start: Date? = nil, spacing: TimeInterval = 0, estimate: Date? = nil
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
        batches[id] = Batch(id: id, kind: kind, client: client, created: Date(), items: items, phase: .running,
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
        notify()
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
        notify()
    }

    func set(_ id: String, phase: Phase) {
        guard var batch = batches[id], !batch.isOver, batch.phase != phase else { return }
        batch.phase = phase
        batches[id] = batch
        notify()
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
        notify()
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
        onChange()
    }

    private func trim() {
        while order.count > Self.kept, let oldest = order.first(where: { batches[$0]?.isOver ?? true }) {
            order.removeAll { $0 == oldest }
            batches[oldest] = nil
        }
    }
}
