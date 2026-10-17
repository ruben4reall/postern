import Foundation
import NIOCore
import NIOPosix
import NIOSSL
@testable import PosternBridge

/// A throwaway self-signed certificate, generated with the system openssl for each test run, so no private key
/// ever lives in the repository.
struct TestCertificate {
    let certificate: NIOSSLCertificate
    let key: NIOSSLPrivateKey
    let pin: CertificatePin

    static func make() throws -> TestCertificate {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=127.0.0.1",
                             "-keyout", directory.appendingPathComponent("key.pem").path,
                             "-out", directory.appendingPathComponent("cert.pem").path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let certificate = try NIOSSLCertificate(file: directory.appendingPathComponent("cert.pem").path, format: .pem)
        let key = try NIOSSLPrivateKey(file: directory.appendingPathComponent("key.pem").path, format: .pem)
        return TestCertificate(certificate: certificate, key: key, pin: CertificatePin(sha256Hex: PinnedTLS.sha256(certificate)!))
    }
}

/// Speaks just enough IMAP to test how Postern opens a session, and records every line it received in clear.
final class FakeIMAPServer: @unchecked Sendable {
    enum Behavior { case normal, refuseStartTLS }

    private let lock = NSLock()
    private var _plainLines: [String] = []
    private var _tlsLines: [String] = []
    private var channel: (any Channel)?
    let certificate: TestCertificate
    let behavior: Behavior

    var plainLines: [String] { lock.withLock { _plainLines } }
    var tlsLines: [String] { lock.withLock { _tlsLines } }
    var port: Int { channel?.localAddress?.port ?? 0 }

    init(behavior: Behavior = .normal) throws {
        certificate = try TestCertificate.make()
        self.behavior = behavior
    }

    func start() async throws {
        let server = self
        channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(Session(server: server))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
    }

    func stop() async { try? await channel?.close().get() }

    fileprivate func record(_ line: String, encrypted: Bool) {
        lock.withLock { encrypted ? _tlsLines.append(line) : _plainLines.append(line) }
    }

    private final class Session: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let server: FakeIMAPServer
        var buffer = ""
        var encrypted = false

        init(server: FakeIMAPServer) { self.server = server }

        func channelActive(context: ChannelHandlerContext) {
            send(context, "* OK [CAPABILITY AUTH=PLAIN IMAP4rev1 STARTTLS] Fake Bridge ready")
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var bytes = unwrapInboundIn(data)
            buffer += bytes.readString(length: bytes.readableBytes) ?? ""
            while let range = buffer.range(of: "\r\n") {
                let line = String(buffer[..<range.lowerBound])
                buffer.removeSubrange(..<range.upperBound)
                server.record(line, encrypted: encrypted)
                handle(line, context)
            }
        }

        private func handle(_ line: String, _ context: ChannelHandlerContext) {
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return }
            let tag = parts[0]
            switch parts[1].uppercased() {
            case "STARTTLS":
                if server.behavior == .refuseStartTLS {
                    send(context, "\(tag) NO STARTTLS unavailable")
                    return
                }
                send(context, "\(tag) OK Begin TLS negotiation now")
                let configuration = TLSConfiguration.makeServerConfiguration(
                    certificateChain: [.certificate(server.certificate.certificate)],
                    privateKey: .privateKey(server.certificate.key)
                )
                let tls = try! NIOSSLServerHandler(context: NIOSSLContext(configuration: configuration))
                try? context.pipeline.syncOperations.addHandler(tls, position: .first)
                encrypted = true
            case "LOGIN":
                send(context, "\(tag) OK LOGIN completed")
            case "LOGOUT":
                send(context, "* BYE")
                send(context, "\(tag) OK LOGOUT completed")
            default:
                send(context, "\(tag) BAD unknown")
            }
        }

        private func send(_ context: ChannelHandlerContext, _ line: String) {
            context.writeAndFlush(NIOAny(context.channel.allocator.buffer(string: line + "\r\n")), promise: nil)
        }
    }
}
