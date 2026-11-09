import CryptoKit
import Foundation
import MCP
import PosternApproval
import PosternModel
import PosternPolicy
import Testing
@testable import PosternServer

/// A batch of thousands of emails takes days at the user's limits: it must survive Postern quitting, and come back
/// only through the user and Touch ID, sealed against any change.
@Suite struct BatchStoreTests {
    let base = SendToolTests()

    @Test func anApprovedBatchSurvivesARestartAndGoesOnAfterTouchID() async throws {
        let backend = FakeBackend()
        _ = try base.applicationDraft(backend)
        let store = MemoryBatchStore()
        let board = BatchBoard(store: store)
        let desk = ApprovalDesk(presenter: CapturingPresenter(.send), authenticator: AlwaysAuthenticated(), timeout: .seconds(5))
        let ledger = MemoryLedger()
        let policy = Policy(enabledTools: Set(ToolID.allCases))
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let session = Session(transport: serverTransport, backend: backend, version: "test", policy: { policy }, desk: desk,
                              ledger: ledger, clientName: { "Claude Code" }, board: board, batchSpacing: .zero,
                              inlineWait: .milliseconds(300))
        try await session.start()
        let client = Client(name: "test", version: "1")
        _ = try await client.connect(transport: clientTransport)

        let start = Value.string(ISO8601DateFormatter().string(from: Date().addingTimeInterval(2)))
        let ids = base.drafts([5, 6]).map { Value.string($0.opaque) }
        let (_, structured, _) = try await base.call(client, "send_drafts", ["ids": .array(ids), "start_at": start])
        let id = try #require(base.batchID(structured))
        try await Task.sleep(for: .milliseconds(400))
        let kept = try #require(store.load().first)
        #expect(kept.id == id && kept.left == 2)

        // Postern quits before the start: what was on disk comes back after a launch.
        let disk = MemoryBatchStore()
        disk.save(kept)
        await board.cancel(id)
        let later = BatchBoard(store: disk)
        await later.restore()
        let restored = try #require(await later.batch(id))
        #expect(restored.interrupted && restored.count(.waiting) == 2 && backend.lock.withLock { backend.sent }.isEmpty)

        let refusing = ApprovalDesk(presenter: CapturingPresenter(.send), authenticator: NeverAuthenticated())
        #expect(await BatchResumer(board: later, desk: refusing, backend: backend, ledger: ledger, policy: { policy }).resume(id) == false)
        #expect(await later.batch(id)?.interrupted == true)

        #expect(await BatchResumer(board: later, desk: desk, backend: backend, ledger: ledger, policy: { policy }).resume(id))
        try await Task.sleep(for: .milliseconds(2500))
        #expect(backend.lock.withLock { backend.sent }.count == 2)
        #expect(await later.batch(id)?.phase == .finished)
        try await Task.sleep(for: .milliseconds(400))
        #expect(disk.load().isEmpty)
    }

    @Test func anEmailCaughtMidSendComesBackUncertain() async throws {
        let store = MemoryBatchStore()
        store.save(BatchRecord(
            id: "abc12345", client: "Claude Code", created: Date(), start: nil, spacing: 2, estimate: nil,
            items: [
                .init(index: 0, recipients: "a@example.com", subject: "S", status: "sending", detail: "", draft: nil),
                .init(index: 1, recipients: "b@example.com", subject: "S", status: "waiting", detail: "", draft: nil),
            ],
            queue: [], noAttachment: false
        ))
        let board = BatchBoard(store: store)
        await board.restore()
        let batch = try #require(await board.batch("abc12345"))
        #expect(batch.items.map(\.status) == [.uncertain, .waiting])
        let held = await board.heldDrafts()
        #expect(held.isEmpty)
    }

    func record(_ id: String = "deadbeef", statuses: [String] = ["waiting", "waiting"]) -> BatchRecord {
        BatchRecord(
            id: id, client: "Codex", created: Date(timeIntervalSince1970: 1_800_000_000), start: nil, spacing: 30,
            estimate: nil,
            items: statuses.enumerated().map { .init(index: $0.offset, recipients: "a@example.com", subject: "Candidature", status: $0.element, detail: "", draft: "x\($0.offset)") },
            queue: statuses.indices.map { .init(index: $0, draft: "x\($0)", digest: String(repeating: "a", count: 64), messageID: "<m\($0)@x>", recipients: ["a@example.com"], sender: "me@example.ch") },
            noAttachment: false
        )
    }

    @Test func aSealedBatchOpensOnlyWithItsKeyAndUnchanged() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("postern-batches-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = SymmetricKey(size: .bits256)
        let index = MemoryBatchIndex()
        let store = SealedBatchStore(folder: folder, key: { key }, index: index)
        store.save(record())
        #expect(store.load() == [record()])
        #expect(store.saveStatuses("deadbeef", ["sent", "waiting"]))
        #expect(store.load().first?.items.map(\.status) == ["sent", "waiting"])
        let file = folder.appendingPathComponent("deadbeef.batch")
        #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("a@example.com"))

        #expect(SealedBatchStore(folder: folder, key: { SymmetricKey(size: .bits256) }, index: index).load().isEmpty)
        store.save(record())
        var tampered = try Data(contentsOf: file)
        tampered[tampered.count / 2] ^= 0x01
        try tampered.write(to: file)
        #expect(store.load().isEmpty && !FileManager.default.fileExists(atPath: file.path))
        #expect(SealedBatchStore(folder: folder, key: { nil }, index: index).load().isEmpty)
    }

    @Test func anOlderCopyPutBackIsRefused() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("postern-batches-\(UUID().uuidString)")
        let copies = folder.appendingPathComponent("copies")
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = SymmetricKey(size: .bits256)
        let index = MemoryBatchIndex()
        let store = SealedBatchStore(folder: folder, key: { key }, index: index)
        store.save(record())
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        for kind in ["batch", "state"] {
            try FileManager.default.copyItem(at: folder.appendingPathComponent("deadbeef.\(kind)"), to: copies.appendingPathComponent("deadbeef.\(kind)"))
        }
        store.saveStatuses("deadbeef", ["sent", "uncertain"])
        for kind in ["batch", "state"] {
            let live = folder.appendingPathComponent("deadbeef.\(kind)")
            try FileManager.default.removeItem(at: live)
            try FileManager.default.copyItem(at: copies.appendingPathComponent("deadbeef.\(kind)"), to: live)
        }
        #expect(SealedBatchStore(folder: folder, key: { key }, index: index).load().isEmpty)

        // A batch that ended is gone from the index: its file put back does not come back either.
        let other = SealedBatchStore(folder: folder, key: { key }, index: index)
        other.save(record("cafe1234"))
        let saved = try Data(contentsOf: folder.appendingPathComponent("cafe1234.batch"))
        let state = try Data(contentsOf: folder.appendingPathComponent("cafe1234.state"))
        other.delete("cafe1234")
        try saved.write(to: folder.appendingPathComponent("cafe1234.batch"))
        try state.write(to: folder.appendingPathComponent("cafe1234.state"))
        #expect(SealedBatchStore(folder: folder, key: { key }, index: index).load().isEmpty)

        // While the index cannot be read, nothing loads; while it cannot be written, files still save.
        let locked = MemoryBatchIndex()
        let lockedStore = SealedBatchStore(folder: folder, key: { key }, index: locked)
        locked.writable = false
        #expect(lockedStore.save(record("beef5678")))
        locked.readable = false
        #expect(lockedStore.load().isEmpty)
    }

    @Test func resumingTwiceAtOnceRunsOneQueue() async throws {
        let backend = FakeBackend()
        _ = try base.applicationDraft(backend)
        let store = MemoryBatchStore()
        var kept = record("abcd1234", statuses: ["waiting"])
        kept = BatchRecord(id: kept.id, client: kept.client, created: kept.created, start: nil, spacing: 0, estimate: nil,
                           items: [.init(index: 0, recipients: "known@example.com", subject: "Candidature", status: "waiting", detail: "", draft: MessageID(mailbox: "Drafts", uidValidity: 1, uid: 5).opaque)],
                           queue: [.init(index: 0, draft: MessageID(mailbox: "Drafts", uidValidity: 1, uid: 5).opaque, digest: String(repeating: "a", count: 64),
                                         messageID: "<m@x>", recipients: ["known@example.com"], sender: "me@example.ch")],
                           noAttachment: false)
        store.save(kept)
        let board = BatchBoard(store: store)
        await board.restore()
        let desk = ApprovalDesk(presenter: CapturingPresenter(.send), authenticator: AlwaysAuthenticated())
        let resumer = BatchResumer(board: board, desk: desk, backend: backend, ledger: MemoryLedger(),
                                   policy: { Policy(enabledTools: Set(ToolID.allCases)) })
        async let first = resumer.resume("abcd1234")
        async let second = resumer.resume("abcd1234")
        let results = await [first, second]
        #expect(results.filter { $0 }.count == 1)
    }
}

struct NeverAuthenticated: Authenticating {
    func confirm(reason: String) async -> Bool { false }
}
