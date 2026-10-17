import Foundation
import Testing
import PosternModel
@testable import PosternApproval
@testable import PosternBridge

@Suite(.serialized) struct DeletionTests {
    func session(_ store: FakeMailStore) async throws -> (Organizer, IMAPConnection, FakeIMAPServer) {
        let server = try FakeIMAPServer(store: store)
        try await server.start()
        let endpoint = BridgeEndpoint(imap: BridgePort(port: server.port, mode: .startTLS), smtp: BridgePort(port: 1, mode: .implicit))
        let connection = IMAPConnection(endpoint: endpoint, pin: server.certificate.pin, credentials: BridgeCredentials(username: "me@example.ch", password: "p"))
        try await connection.open()
        return (Organizer(connection: connection), connection, server)
    }

    func approval(_ ids: [MessageID], permanent: Bool) -> ApprovedDeletion {
        let items = ids.map { DeletionItem(id: $0, mailbox: $0.mailbox, from: "", subject: "", date: nil) }
        return ApprovedDeletion(DeletionRequest(tool: "t", client: "c", items: items, permanent: permanent))
    }

    func id(_ store: FakeMailStore, _ messageID: String, in mailbox: String) -> MessageID {
        let index = store.messages.firstIndex { $0.messageID == messageID }!
        return MessageID(mailbox: mailbox, uidValidity: 1, uid: store.uid(of: index, in: mailbox))
    }

    @Test func trashesFromTheRealFolderEvenWhenSeenThroughALabel() async throws {
        let store = FakeMailStore()
        store.add("<a@x>", folder: "Archive", labels: ["Labels/Work"])
        store.add("<keep@x>", folder: "Archive")
        let (organizer, connection, server) = try await session(store)
        defer { Task { await connection.close(); await server.stop() } }
        let result = try await organizer.trash(approval([id(store, "<a@x>", in: "Labels/Work")], permanent: false))
        #expect(result.done.count == 1 && result.verified)
        #expect(store.message("<a@x>")?.folder == "Trash")
        #expect(store.message("<keep@x>")?.folder == "Archive")
        #expect(store.allCommands.contains("MOVE Archive -> Trash"))
    }

    /// A message sent to yourself is one message, shown in Inbox and in Sent. Passing both views must trash it
    /// once: a second move, from the view Bridge has not updated yet, would erase it for good.
    @Test func aMessageSeenInTwoMailboxesIsTrashedOnce() async throws {
        let store = FakeMailStore()
        store.add("<self@x>", folder: "INBOX", alsoIn: ["Sent"])
        let (organizer, connection, server) = try await session(store)
        defer { Task { await connection.close(); await server.stop() } }
        let both = [id(store, "<self@x>", in: "INBOX"), id(store, "<self@x>", in: "Sent")]
        let result = try await organizer.trash(approval(both, permanent: false))
        #expect(store.message("<self@x>")?.folder == "Trash")
        #expect(result.done.count == 1)
        #expect(result.failed.map(\.reason) == ["Already in Trash."])
        #expect(store.allCommands.filter { $0.hasPrefix("MOVE") }.count == 1)
    }

    @Test func anOutOfDateViewOfATrashedMessageIsLeftAlone() async throws {
        let store = FakeMailStore()
        store.add("<self@x>", folder: "INBOX", alsoIn: ["Sent"])
        let (organizer, connection, server) = try await session(store)
        defer { Task { await connection.close(); await server.stop() } }
        let sent = id(store, "<self@x>", in: "Sent")
        _ = try await organizer.trash(approval([id(store, "<self@x>", in: "INBOX")], permanent: false))
        // Bridge still lists the message in Sent; trashing it from there must not touch it.
        #expect(store.members(of: "Sent").count == 1)
        let again = try await organizer.trash(approval([sent], permanent: false))
        #expect(store.message("<self@x>")?.folder == "Trash")
        #expect(again.done.isEmpty && again.failed.map(\.reason) == ["Already in Trash."])
        #expect(!store.allCommands.contains("MOVE Sent -> Trash"))
    }

    @Test func erasesOnlyFromTrashOrSpam() async throws {
        let store = FakeMailStore()
        store.add("<old@x>", folder: "Trash")
        store.add("<inbox@x>", folder: "INBOX")
        let (organizer, connection, server) = try await session(store)
        defer { Task { await connection.close(); await server.stop() } }
        let refused = try await organizer.erase(approval([id(store, "<inbox@x>", in: "INBOX")], permanent: true))
        #expect(refused.done.isEmpty && refused.failed.count == 1)
        #expect(store.message("<inbox@x>")?.folder == "INBOX")
        let erased = try await organizer.erase(approval([id(store, "<old@x>", in: "Trash")], permanent: true))
        #expect(erased.done.count == 1 && erased.verified)
        #expect(store.message("<old@x>")?.folder == "(removed)")
    }

    @Test func anApprovalForOneActionCannotDoTheOther() async throws {
        let store = FakeMailStore()
        store.add("<a@x>", folder: "Trash")
        let (organizer, connection, server) = try await session(store)
        defer { Task { await connection.close(); await server.stop() } }
        let trashApproval = approval([id(store, "<a@x>", in: "Trash")], permanent: false)
        await #expect(throws: BridgeError.self) { try await organizer.erase(trashApproval) }
        #expect(store.message("<a@x>")?.folder == "Trash")
    }
}
