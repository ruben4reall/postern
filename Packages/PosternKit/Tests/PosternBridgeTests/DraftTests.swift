import Foundation
import Testing
import PosternCompose
import PosternModel
@testable import PosternBridge

@Suite(.serialized) struct DraftTests {
    @Test func appendsADraftAndDeletesOnlyThatOne() async throws {
        let store = FakeMailStore()
        store.add("<keep@x>", folder: "Drafts", flags: ["\\Draft"])
        let server = try FakeIMAPServer(store: store)
        try await server.start()
        defer { Task { await server.stop() } }
        let endpoint = BridgeEndpoint(imap: BridgePort(port: server.port, mode: .startTLS), smtp: BridgePort(port: 1, mode: .implicit))
        let connection = IMAPConnection(endpoint: endpoint, pin: server.certificate.pin, credentials: BridgeCredentials(username: "me@example.ch", password: "p"))
        try await connection.open()
        defer { Task { await connection.close() } }

        let message = try OutgoingMessage.make(
            from: Address(name: nil, email: "me@example.ch"), to: [Address(name: nil, email: "anna@example.com")],
            bcc: [Address(name: nil, email: "copy@example.org")], subject: "Draft", body: "Not sent yet"
        )
        let drafts = try await connection.mailbox(named: "Drafts")
        let appended = try #require(try await connection.appendDraft(message.rfc822(includeBcc: true), to: drafts))
        #expect(store.message(message.messageID)?.folder == "Drafts")
        #expect(store.message(message.messageID)?.flags.contains("\\Draft") == true)

        _ = try await connection.select(drafts)
        try await connection.deleteDrafts(uids: [appended.uid])
        #expect(store.message(message.messageID)?.folder == "(removed)")
        #expect(store.message("<keep@x>")?.folder == "Drafts")
    }
}
