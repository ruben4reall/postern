import Foundation
import NIOCore
import NIOPosix
import NIOSSL
@testable import PosternBridge

/// Speaks enough SMTP to test Postern's sender, in either TLS mode, and records what it received and how.
final class FakeSMTPServer: @unchecked Sendable {
    struct Line: Equatable {
        let text: String
        let encrypted: Bool
    }

    let certificate: TestCertificate
    let mode: TLSMode
    let refuseAuth: Bool
    private let lock = NSLock()
    private var _lines: [Line] = []
    private var _data = ""
    private var channel: (any Channel)?

    var lines: [Line] { lock.withLock { _lines } }
    var data: String { lock.withLock { _data } }
    var port: Int { channel?.localAddress?.port ?? 0 }

    init(mode: TLSMode, refuseAuth: Bool = false) throws {
        certificate = try TestCertificate.make()
        self.mode = mode
        self.refuseAuth = refuseAuth
    }

    func start() async throws {
        let server = self
        channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if server.mode == .implicit { try channel.pipeline.syncOperations.addHandler(server.tlsHandler()) }
                    try channel.pipeline.syncOperations.addHandler(Session(server: server, encrypted: server.mode == .implicit))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
    }

    func stop() async { try? await channel?.close().get() }

    func tlsHandler() throws -> NIOSSLServerHandler {
        let configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(certificate.certificate)], privateKey: .privateKey(certificate.key)
        )
        return NIOSSLServerHandler(context: try NIOSSLContext(configuration: configuration))
    }

    fileprivate func record(_ text: String, encrypted: Bool) { lock.withLock { _lines.append(Line(text: text, encrypted: encrypted)) } }
    fileprivate func recordData(_ text: String) { lock.withLock { _data = text } }

    private final class Session: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let server: FakeSMTPServer
        var encrypted: Bool
        var buffer = ""
        var inData = false
        var collected: [String] = []

        init(server: FakeSMTPServer, encrypted: Bool) {
            self.server = server
            self.encrypted = encrypted
        }

        func channelActive(context: ChannelHandlerContext) {
            send(context, "220 127.0.0.1 ESMTP Fake")
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var bytes = unwrapInboundIn(data)
            buffer += bytes.readString(length: bytes.readableBytes) ?? ""
            while let range = buffer.range(of: "\r\n") {
                let line = String(buffer[..<range.lowerBound])
                buffer.removeSubrange(..<range.upperBound)
                if inData {
                    if line == "." {
                        inData = false
                        server.recordData(collected.joined(separator: "\r\n"))
                        send(context, "250 Queued")
                    } else {
                        collected.append(line)
                    }
                    continue
                }
                server.record(line, encrypted: encrypted)
                handle(line, context)
            }
        }

        private func handle(_ line: String, _ context: ChannelHandlerContext) {
            let verb = line.split(separator: " ").first.map { $0.uppercased() } ?? ""
            switch verb {
            case "EHLO":
                send(context, "250-Hello")
                if !encrypted { send(context, "250-STARTTLS") }
                send(context, "250 AUTH PLAIN LOGIN")
            case "STARTTLS":
                send(context, "220 Ready to start TLS")
                try? context.pipeline.syncOperations.addHandler(server.tlsHandler(), position: .first)
                encrypted = true
            case "AUTH":
                send(context, server.refuseAuth ? "535 Authentication failed" : "235 Authenticated")
            case "MAIL", "RCPT":
                send(context, "250 OK")
            case "DATA":
                inData = true
                send(context, "354 Go ahead")
            case "QUIT":
                send(context, "221 Bye")
            default:
                send(context, "500 Unknown")
            }
        }

        private func send(_ context: ChannelHandlerContext, _ line: String) {
            context.writeAndFlush(NIOAny(context.channel.allocator.buffer(string: line + "\r\n")), promise: nil)
        }
    }
}
