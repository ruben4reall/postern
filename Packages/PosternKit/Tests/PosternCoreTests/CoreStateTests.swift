import Foundation
import MCP
import Testing
import PosternApproval
import PosternModel
import PosternPolicy
import PosternServer
import PosternVault
@testable import PosternCore

/// A reader that is never reached: the core must not parse anything in these tests.
struct UnreachableReader: MessageReading {
    func sanitize(_ raw: Data, maxChars: Int) async throws -> SanitizedMessage { throw PosternError(.parseFailed, "not here") }
    func attachment(_ raw: Data, index: Int) async throws -> (data: Data, filename: String?, mimeType: String) {
        throw PosternError(.parseFailed, "not here")
    }
    func readAttachment(_ raw: Data, index: Int, maxChars: Int) async throws -> AttachmentContent {
        throw PosternError(.parseFailed, "not here")
    }
}

struct RefusingPresenter: ApprovalPresenter {
    func present(_ request: ApprovalRequest, deadline: Date) async -> ApprovalIntent { .reject(reason: nil) }
    func presentDeletion(_ request: DeletionRequest, deadline: Date) async -> ApprovalIntent { .reject(reason: nil) }
    func presentBatch(_ request: BatchApprovalRequest, deadline: Date) async -> BatchIntent { .reject(reason: nil) }
}

struct NoProof: Authenticating {
    func confirm(reason: String) async -> Bool { false }
}

final class NamedClient: ClientConnection, @unchecked Sendable {
    let clientName: String
    init(_ name: String) { clientName = name }
}

/// A secret store that refuses every read, like a locked keyring.
struct ClosedVault: SecretStore {
    func data(for key: VaultKey) throws -> Data? { throw VaultError.keychain(-25308) }
    func set(_ data: Data, for key: VaultKey) throws { throw VaultError.keychain(-25308) }
    func remove(_ key: VaultKey) throws { throw VaultError.keychain(-25308) }
}

func makeCore(vault: any SecretStore = MemoryVault()) -> CoreState {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("postern-core-\(UUID().uuidString)")
    return CoreState(platform: CorePlatform(
        vault: vault, reader: UnreachableReader(), presenter: RefusingPresenter(), authenticator: NoProof(),
        supportFolder: folder, version: "2.0.0-test",
        storeClosedMessage: "The keyring is locked.", notConfiguredMessage: "Set up Postern first."
    ))
}

@Suite struct CoreStateTests {
    @Test func aCoreWithoutSettingsSaysWhatToDo() {
        let core = makeCore()
        core.reload()
        #expect(!core.isConfigured)
        #expect(core.readiness?.message == "Set up Postern first.")
    }

    @Test func aClosedStoreIsToldApartFromAMissingSetup() {
        let core = makeCore(vault: ClosedVault())
        core.reload()
        #expect(core.readiness?.message == "The keyring is locked.")
    }

    @Test func anAppSeesNoToolUntilPosternIsSetUpAndListsWhoIsConnected() async throws {
        let core = makeCore()
        try core.save(.readOnly)
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let handle = core.openSession(transport: serverTransport, connection: NamedClient("Claude Code"))
        let client = Client(name: "test", version: "1")
        _ = try await client.connect(transport: clientTransport)
        let (tools, _) = try await client.listTools()
        #expect(tools.isEmpty)
        #expect(core.connectedApps == ["Claude Code"])
        handle.close()
        #expect(core.connectedApps.isEmpty)
    }

    @Test func savingAPolicyTellsEveryInterface() throws {
        let core = makeCore()
        let seen = Counter()
        core.onChange { seen.add() }
        try core.save(.readOnly)
        #expect(core.policy == .readOnly)
        #expect(seen.value >= 1)
    }

    @Test func theBatchKeyIsMadeOnceAndKept() {
        let vault = MemoryVault()
        let first = makeCore(vault: vault).batchKey()
        let second = makeCore(vault: vault).batchKey()
        #expect(first != nil)
        #expect(first == second)
    }

    @Test func theLedgerKeepsCountingWhenTheStoreCloses() {
        let vault = MemoryVault()
        let ledger = VaultLedger(vault: vault)
        #expect(ledger.reserve(at: Date(), allowed: { $0.count < 2 }))
        #expect(ledger.reserve(at: Date().addingTimeInterval(1), allowed: { $0.count < 2 }))
        #expect(!ledger.reserve(at: Date().addingTimeInterval(2), allowed: { $0.count < 2 }))
        #expect(VaultLedger(vault: vault).recentSends().count == 2)
    }

    @Test func protonsOwnLimitIsRememberedOncePerHour() {
        let log = ProtonLimitLog(vault: MemoryVault())
        let start = Date()
        log.record(sentToday: 212, at: start)
        log.record(sentToday: 213, at: start.addingTimeInterval(60))
        log.record(sentToday: 40, at: start.addingTimeInterval(7200))
        #expect(log.hits.map(\.sentInLastDay) == [212, 40])
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Suite(.serialized) struct FoldersTests {
    func withDownloads(_ body: (URL) throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("postern-dl-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        PosternFolders.downloadsOverride = root
        defer {
            PosternFolders.downloadsOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        PosternFolders.prepare()
        try body(root)
    }

    @Test func namesLoseTheirPathAndHiddenDots() {
        #expect(PosternFolders.safeName("../../etc/passwd") == "etcpasswd")
        #expect(PosternFolders.safeName("...hidden") == "hidden")
        #expect(PosternFolders.safeName("a\u{202E}gpj.exe") == "agpj.exe")
        #expect(PosternFolders.safeName("") == "attachment")
    }

    @Test func attachesAPlainFileFromTheOutboxAndNothingElse() throws {
        try withDownloads { _ in
            let letter = PosternFolders.outbox.appendingPathComponent("Letters", isDirectory: true)
            try FileManager.default.createDirectory(at: letter, withIntermediateDirectories: true)
            try Data("%PDF-1.7 hello".utf8).write(to: letter.appendingPathComponent("Acme.pdf"))
            let file = try PosternFolders.outboxFile(named: "Letters/Acme.pdf")
            #expect(file.filename == "Acme.pdf")
            #expect(PosternFolders.outboxFiles().map(\.path) == ["Letters/Acme.pdf"])
            #expect(throws: PosternError.self) { try PosternFolders.outboxFile(named: "../Acme.pdf") }
            #expect(throws: PosternError.self) { try PosternFolders.outboxFile(named: "Letters/Missing.pdf") }
        }
    }

    #if !os(Windows)
    @Test func refusesALinkPutInTheOutbox() throws {
        try withDownloads { root in
            let secret = root.appendingPathComponent("secret.txt")
            try Data("token".utf8).write(to: secret)
            try FileManager.default.createSymbolicLink(at: PosternFolders.outbox.appendingPathComponent("link.txt"), withDestinationURL: secret)
            #expect(throws: PosternError.self) { try PosternFolders.outboxFile(named: "link.txt") }
            #expect(PosternFolders.outboxFiles().isEmpty)
        }
    }
    #endif

    @Test func savedAttachmentsNeverOverwriteEachOther() throws {
        try withDownloads { _ in
            let first = try PosternFolders.save(Data("a".utf8), suggestedName: "invoice.pdf", mimeType: "application/pdf")
            let second = try PosternFolders.save(Data("b".utf8), suggestedName: "invoice.pdf", mimeType: "application/pdf")
            #expect(first.filename == "invoice.pdf")
            #expect(second.filename == "invoice 2.pdf")
            #expect(first.sha256 != second.sha256)
        }
    }
}
