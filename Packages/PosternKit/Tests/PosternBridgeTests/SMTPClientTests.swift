import Foundation
import Testing
import PosternCompose
import PosternModel
@testable import PosternApproval
@testable import PosternBridge

@Suite(.serialized) struct SMTPClientTests {
    let credentials = BridgeCredentials(username: "me@example.ch", password: "bridge-password")

    func approved() throws -> ApprovedMessage {
        let message = try OutgoingMessage.make(
            from: Address(name: "Me", email: "me@example.ch"), to: [Address(name: "Anna", email: "anna@example.com")],
            bcc: [Address(name: nil, email: "hidden@example.org")], subject: "Plan", body: "Line one\n.\nLast line"
        )
        return ApprovedMessage(message)
    }

    func client(_ server: FakeSMTPServer, pin: CertificatePin? = nil) -> SMTPClient {
        let endpoint = BridgeEndpoint(imap: BridgePort(port: 1, mode: .startTLS), smtp: BridgePort(port: server.port, mode: server.mode))
        return SMTPClient(endpoint: endpoint, pin: pin ?? server.certificate.pin, credentials: credentials)
    }

    @Test(arguments: [TLSMode.implicit, .startTLS])
    func sendsTheApprovedBytesOverPinnedTLS(_ mode: TLSMode) async throws {
        let server = try FakeSMTPServer(mode: mode)
        try await server.start()
        defer { Task { await server.stop() } }
        try await client(server).send(try approved())
        let plain = server.lines.filter { !$0.encrypted }.map(\.text)
        #expect(plain.allSatisfy { $0.hasPrefix("EHLO") || $0 == "STARTTLS" })
        #expect(server.lines.contains { $0.text.hasPrefix("AUTH PLAIN") && $0.encrypted })
        let commands = server.lines.map(\.text)
        #expect(commands.contains("MAIL FROM:<me@example.ch>"))
        #expect(commands.contains("RCPT TO:<anna@example.com>") && commands.contains("RCPT TO:<hidden@example.org>"))
        #expect(!server.data.contains("hidden@example.org"))
        #expect(server.data.contains("\r\n..\r\n"))
        #expect(server.data.contains("Last line"))
    }

    @Test func refusesAnotherCertificateBeforeAnyPassword() async throws {
        let server = try FakeSMTPServer(mode: .implicit)
        try await server.start()
        defer { Task { await server.stop() } }
        let wrong = CertificatePin(sha256Hex: String(repeating: "cd", count: 32))
        await #expect(throws: BridgeError.certificateMismatch(actual: server.certificate.pin.sha256Hex)) {
            try await client(server, pin: wrong).send(try approved())
        }
        #expect(!server.lines.contains { $0.text.hasPrefix("AUTH") })
    }

    @Test func reportsARefusedPassword() async throws {
        let server = try FakeSMTPServer(mode: .implicit, refuseAuth: true)
        try await server.start()
        defer { Task { await server.stop() } }
        await #expect(throws: BridgeError.authenticationFailed) { try await client(server).send(try approved()) }
        #expect(!server.lines.contains { $0.text.hasPrefix("MAIL FROM") })
    }

    @Test func dotStuffingKeepsLinesThatStartWithADot() {
        let stuffed = String(decoding: SMTPClient.dotStuffed(Data("a\r\n.\r\n.b\r\nc".utf8)), as: UTF8.self)
        #expect(stuffed == "a\r\n..\r\n..b\r\nc\r\n.\r\n")
    }
}
