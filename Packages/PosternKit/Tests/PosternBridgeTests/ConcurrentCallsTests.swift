import Foundation
import NIOCore
import NIOEmbedded
import NIOIMAP
import Testing
@testable import PosternBridge

/// Clients call several tools at once, and Postern keeps a single IMAP session: each operation must get the
/// session to itself, from its first command to its last.
@Suite(.serialized) struct ConcurrentCallsTests {
    let credentials = BridgeCredentials(username: "me@example.com", password: "bridge-password")

    /// Seen on the real mailbox: two reads sent their EXAMINE in the same millisecond, and one of them never
    /// returned, so the client waited for its own 30-minute limit.
    @Test func parallelOperationsEachFinishOnTheirOwnMailbox() async throws {
        let folders = ["INBOX", "Archive", "Sent", "Drafts", "Spam", "Trash"]
        let store = FakeMailStore()
        for (number, folder) in folders.enumerated() { store.add("<m\(number)@x>", folder: folder) }
        let server = try FakeIMAPServer(store: store)
        try await server.start()
        let endpoint = BridgeEndpoint(imap: BridgePort(port: server.port, mode: .startTLS), smtp: BridgePort(port: 1, mode: .implicit))
        let client = BridgeClient(endpoint: endpoint, pin: server.certificate.pin, credentials: credentials)
        // An open session with its mailbox list, as after the first call of the day.
        _ = try await client.withConnection { try await $0.mailboxes(refresh: true) }

        let results = Results()
        for folder in folders {
            Task {
                let found = try await client.withConnection { connection in
                    let mailbox = try await connection.mailbox(named: folder)
                    _ = try await connection.examine(mailbox)
                    let uids = try await connection.uidSearch(.all)
                    return try await connection.fetchSummaries(uids).compactMap(\.messageID)
                }
                await results.add(folder, found)
            }
        }

        // A lost reply never resolves, so wait against a deadline rather than on the tasks themselves.
        let finished = await results.wait(for: folders.count, seconds: 10)
        #expect(finished.count == folders.count)
        for (number, folder) in folders.enumerated() {
            #expect(finished[folder] == ["<m\(number)@x>"], "\(folder) answered with another mailbox's messages")
        }
        await client.shutdown()
        await server.stop()
    }

    @Test func aSecondCommandNeverReplacesTheOneWaiting() throws {
        let channel = EmbeddedChannel()
        let router = ResponseRouter()
        try channel.pipeline.syncOperations.addHandler(router)
        let first = channel.eventLoop.makePromise(of: CommandResult.self)
        let second = channel.eventLoop.makePromise(of: CommandResult.self)
        let firstResult = Outcome()
        let secondResult = Outcome()
        first.futureResult.whenComplete { firstResult.set($0) }
        second.futureResult.whenComplete { secondResult.set($0) }

        #expect(router.expect(tag: "P1", first))
        #expect(!router.expect(tag: "P2", second), "a refused command must not be written to Bridge")
        try channel.writeInbound(Response.tagged(TaggedResponse(tag: "P1", state: .ok(ResponseText(text: "done")))))

        guard case .failure = secondResult.value else {
            Issue.record("the second command was not refused")
            return
        }
        guard case .success(let result) = firstResult.value else {
            Issue.record("the first command lost its reply")
            return
        }
        #expect(result.tagged.tag == "P1" && result.isOK)
    }
}

private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<CommandResult, any Error>?

    var value: Result<CommandResult, any Error>? { lock.withLock { stored } }

    func set(_ result: Result<CommandResult, any Error>) { lock.withLock { stored = result } }
}

private actor Results {
    private var found: [String: [String]] = [:]

    func add(_ folder: String, _ messageIDs: [String]) { found[folder] = messageIDs }

    func wait(for count: Int, seconds: Int) async -> [String: [String]] {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while found.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return found
    }
}
