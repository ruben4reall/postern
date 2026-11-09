import Foundation
import MCP
import PosternApproval
import PosternModel
import PosternPolicy

/// Resumes a send batch approved before Postern quit, from Postern's window: the user confirms again with Touch
/// ID, and the emails left go on as they would have, each composed again from its draft and sent only if it is the
/// one approved.
public struct BatchResumer: Sendable {
    let board: BatchBoard
    let desk: ApprovalDesk
    let backend: any MailBackend
    let ledger: any SendLedger
    let policy: @Sendable () -> Policy

    public init(board: BatchBoard, desk: ApprovalDesk, backend: any MailBackend, ledger: any SendLedger,
                policy: @escaping @Sendable () -> Policy) {
        self.board = board
        self.desk = desk
        self.backend = backend
        self.ledger = ledger
        self.policy = policy
    }

    /// True once the batch goes on; false when it cannot, or the user did not confirm.
    @discardableResult
    public func resume(_ id: String) async -> Bool {
        guard let record = await board.beginResume(id) else { return false }
        let resumed = await go(id, record)
        await board.endResume(id)
        return resumed
    }

    private func go(_ id: String, _ record: BatchRecord) async -> Bool {
        guard let batch = await board.batch(id) else { return false }
        let waiting = Set(batch.items.filter { $0.status == .waiting }.map(\.index))
        let entries = record.queue.filter { waiting.contains($0.index) }
        guard !entries.isEmpty else {
            await board.cancel(id)
            return false
        }
        let day = record.created.formatted(date: .abbreviated, time: .shortened)
        let reason = entries.count == 1
            ? "resume sending 1 email approved on \(day)"
            : "resume sending \(entries.count) emails approved on \(day)"
        guard let claims = await desk.resume(entries.map(\.digest), reason: reason) else { return false }
        let queue = zip(entries, claims).compactMap { entry, claim -> SendTools.QueuedEmail? in
            guard let draft = MessageID(opaque: entry.draft) else { return nil }
            return SendTools.QueuedEmail(index: entry.index, draft: draft, claim: claim, messageID: entry.messageID,
                                         recipients: entry.recipients, sender: entry.sender)
        }
        let flags: [String: Value] = record.noAttachment ? ["no_attachment": .bool(true)] : [:]
        let tools = SendTools(backend: backend, policy: policy(), desk: desk, ledger: ledger, provenance: Provenance(),
                              client: record.client, board: board, livePolicy: policy)
        // Cancelled while Touch ID was asked: nothing goes on.
        guard let current = await board.batch(id), !current.isOver else { return false }
        await board.keep(id, queue: queue, noAttachment: record.noAttachment)
        await board.run(id) { await tools.runQueue(queue, batch: id, spacing: record.spacing, start: record.start, flags: flags) }
        return true
    }
}
