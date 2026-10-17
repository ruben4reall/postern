import Foundation
import Testing
@testable import PosternBridge

@Suite(.serialized) struct IMAPConnectionSecurityTests {
    let credentials = BridgeCredentials(username: "me@example.com", password: "bridge-password")

    func endpoint(_ port: Int) -> BridgeEndpoint {
        BridgeEndpoint(imap: BridgePort(port: port, mode: .startTLS), smtp: BridgePort(port: 1, mode: .implicit))
    }

    @Test func sendsTheBridgePasswordOnlyAfterAPinnedHandshake() async throws {
        let server = try FakeIMAPServer()
        try await server.start()
        defer { Task { await server.stop() } }
        let connection = IMAPConnection(endpoint: endpoint(server.port), pin: server.certificate.pin, credentials: credentials)
        try await connection.open()
        await connection.close()
        #expect(server.plainLines.count == 1)
        #expect(server.plainLines.first?.hasSuffix("STARTTLS") == true)
        #expect(!server.plainLines.joined().contains("bridge-password"))
        #expect(server.tlsLines.contains { $0.contains("LOGIN") })
    }

    @Test func refusesAnotherCertificateAndNeverSendsThePassword() async throws {
        let server = try FakeIMAPServer()
        try await server.start()
        defer { Task { await server.stop() } }
        let wrongPin = CertificatePin(sha256Hex: String(repeating: "ab", count: 32))
        let connection = IMAPConnection(endpoint: endpoint(server.port), pin: wrongPin, credentials: credentials)
        await #expect(throws: BridgeError.certificateMismatch(actual: server.certificate.pin.sha256Hex)) {
            try await connection.open()
        }
        #expect(!(server.plainLines + server.tlsLines).joined().contains("bridge-password"))
    }

    @Test func stopsWhenStartTLSIsRefused() async throws {
        let server = try FakeIMAPServer(behavior: .refuseStartTLS)
        try await server.start()
        defer { Task { await server.stop() } }
        let connection = IMAPConnection(endpoint: endpoint(server.port), pin: server.certificate.pin, credentials: credentials)
        await #expect(throws: BridgeError.starttlsRefused) { try await connection.open() }
        #expect(!server.plainLines.joined().contains("LOGIN"))
    }

    @Test func reportsAnUnreachableBridge() async throws {
        let connection = IMAPConnection(endpoint: endpoint(1), pin: CertificatePin(sha256Hex: "00"), credentials: credentials)
        await #expect(throws: BridgeError.unreachable) { try await connection.open() }
    }
}

/// Runs against the Bridge installed on this Mac. Opt in with `POSTERN_LIVE_BRIDGE=1`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["POSTERN_LIVE_BRIDGE"] == "1"))
struct LiveBridgeProbeTests {
    @Test func detectsModesAndTheSameCertificateOnBothPorts() async throws {
        let imap = try await BridgeProbe.inspect(port: 1143, service: .imap)
        let smtp = try await BridgeProbe.inspect(port: 1025, service: .smtp)
        print("imap:", imap.mode, imap.pin.display, imap.greeting)
        print("smtp:", smtp.mode, smtp.pin.display, smtp.greeting)
        #expect(imap.greeting.contains("Proton Mail Bridge"))
        #expect(imap.pin == smtp.pin)
    }
}
