import Foundation
import Testing
import PosternModel
@testable import PosternBridge

/// Organizing against a fake Bridge that follows Proton's folder and label rules.
@Suite(.serialized) struct OrganizerTests {
    let credentials = BridgeCredentials(username: "me@example.com", password: "bridge-password")

    func session(_ store: FakeMailStore) async throws -> (Organizer, IMAPConnection, FakeIMAPServer) {
        let server = try FakeIMAPServer(store: store)
        try await server.start()
        let endpoint = BridgeEndpoint(imap: BridgePort(port: server.port, mode: .startTLS), smtp: BridgePort(port: 1, mode: .implicit))
        let connection = IMAPConnection(endpoint: endpoint, pin: server.certificate.pin, credentials: credentials)
        try await connection.open()
        return (Organizer(connection: connection), connection, server)
    }

    func id(_ store: FakeMailStore, _ messageID: String, in mailbox: String) -> PosternModel.MessageID {
        let index = store.messages.firstIndex { $0.messageID == messageID }!
        return PosternModel.MessageID(mailbox: mailbox, uidValidity: 1, uid: store.uid(of: index, in: mailbox))
    }

    func mailbox(_ connection: IMAPConnection, _ display: String) async throws -> BridgeMailbox {
        try await connection.mailbox(named: display)
    }

    @Test func marksAsReadAndConfirmsIt() async throws {
        let store = FakeMailStore()
        store.add("<a@x>", folder: "INBOX")
        let (organizer, connection, server) = try await session(store)
        defer { Task { await connection.close(); await server.stop() } }
        let result = try await organizer.setFlag(.read(true), ids: [id(store, "<a@x>", in: "INBOX")])
        #expect(result.done.count == 1 && result.failed.isEmpty && result.verified)
        #expect(store.message("<a@x>")?.flags.contains("\\Seen") == true)
    }

    @Test func movingAMessageSeenThroughALabelKeepsTheLabel() async throws {
        let store = FakeMailStore()
        store.add("<a@x>", folder: "INBOX", labels: ["Labels/Work"])
        store.addMailbox("Folders/Projects")
        let (organizer, connection, server) = try await session(store)
        defer { Task { await connection.close(); await server.stop() } }
        let destination = try await mailbox(connection, "Folders/Projects")
        let result = try await organizer.move([id(store, "<a@x>", in: "Labels/Work")], to: destination)
        #expect(result.done.count == 1 && result.verified)
        #expect(store.message("<a@x>")?.folder == "Folders/Projects")
        #expect(store.message("<a@x>")?.labels == ["Labels/Work"])
        #expect(store.allCommands.contains("MOVE INBOX -> Folders/Projects"))
        #expect(!store.allCommands.contains { $0.hasPrefix("MOVE Labels/Work") })
    }

    @Test func findsTheFolderOfAMessageFromAllMail() async throws {
        let store = FakeMailStore()
        store.add("<a@x>", folder: "Folders/Old")
        let (organizer, connection, server) = try await session(store)
        defer { Task { await connection.close(); await server.stop() } }
        let result = try await organizer.move([id(store, "<a@x>", in: "All Mail")], to: try await mailbox(connection, "Archive"))
        #expect(result.done.count == 1 && result.verified)
        #expect(store.message("<a@x>")?.folder == "Archive")
        #expect(store.allCommands.contains("MOVE Folders/Old -> Archive"))
    }

    @Test func addingALabelKeepsTheFolder() async throws {
        let store = FakeMailStore()
        store.add("<a@x>", folder: "INBOX")
        store.addMailbox("Labels/Work")
        let (organizer, connection, server) = try await session(store)
        defer { Task { await connection.close(); await server.stop() } }
        let result = try await organizer.addLabel([id(store, "<a@x>", in: "INBOX")], label: try await mailbox(connection, "Labels/Work"))
        #expect(result.done.count == 1 && result.verified)
        #expect(store.message("<a@x>")?.folder == "INBOX")
        #expect(store.message("<a@x>")?.labels == ["Labels/Work"])
    }

    @Test func removingALabelMovesBackToTheSameFolder() async throws {
        let store = FakeMailStore()
        store.add("<a@x>", folder: "Archive", labels: ["Labels/Work", "Labels/Keep"])
        let (organizer, connection, server) = try await session(store)
        defer { Task { await connection.close(); await server.stop() } }
        let result = try await organizer.removeLabel([id(store, "<a@x>", in: "Labels/Keep")], label: try await mailbox(connection, "Labels/Work"))
        #expect(result.done.count == 1 && result.verified)
        #expect(store.message("<a@x>")?.folder == "Archive")
        #expect(store.message("<a@x>")?.labels == ["Labels/Keep"])
        #expect(store.allCommands.contains("MOVE Labels/Work -> Archive"))
    }

    @Test func idsReturnedAfterLabelChangesStillFindTheMessage() async throws {
        let store = FakeMailStore()
        store.add("<a@x>", folder: "INBOX", labels: ["Labels/Work"])
        let (organizer, connection, server) = try await session(store)
        defer { Task { await connection.close(); await server.stop() } }
        let removed = try await organizer.removeLabel([id(store, "<a@x>", in: "INBOX")], label: try await mailbox(connection, "Labels/Work"))
        let current = try #require(removed.done.first)
        #expect(current.mailbox == "INBOX")
        #expect(store.index(ofUID: current.uid, in: "INBOX") != nil)
        let added = try await organizer.addLabel([current], label: try await mailbox(connection, "Labels/Work"))
        let again = try #require(added.done.first)
        #expect(store.index(ofUID: again.uid, in: "INBOX") != nil)
    }

    @Test func refusesAnOutOfDateID() async throws {
        let store = FakeMailStore()
        store.add("<a@x>", folder: "INBOX")
        let (organizer, connection, server) = try await session(store)
        defer { Task { await connection.close(); await server.stop() } }
        let stale = PosternModel.MessageID(mailbox: "INBOX", uidValidity: 99, uid: 1)
        let result = try await organizer.setFlag(.starred(true), ids: [stale])
        #expect(result.done.isEmpty && result.failed.count == 1)
        #expect(store.message("<a@x>")?.flags.isEmpty == true)
    }

    @Test func createsAFolderWithAnAccentedName() async throws {
        let store = FakeMailStore()
        let (organizer, connection, server) = try await session(store)
        defer { Task { await connection.close(); await server.stop() } }
        let created = try await organizer.create(folder: ["Réunions"])
        #expect(created.display == "Folders/Réunions")
        #expect(store.allCommands.contains("CREATE Folders/R&AOk-unions"))
    }
}
