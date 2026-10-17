import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import PosternApproval

/// Sends approved mail through Bridge's SMTP port.
///
/// It accepts nothing but an `ApprovedMessage`, which only the approval desk can create. Like the IMAP client, it
/// pins Bridge's certificate and never writes the password before TLS is up.
public struct SMTPClient: Sendable {
    private let endpoint: BridgeEndpoint
    private let pin: CertificatePin
    private let credentials: BridgeCredentials

    public init(endpoint: BridgeEndpoint, pin: CertificatePin, credentials: BridgeCredentials) {
        self.endpoint = endpoint
        self.pin = pin
        self.credentials = credentials
    }

    public func send(_ approved: ApprovedMessage) async throws {
        let recorder = PeerCertificateRecorder()
        let reader = SMTPReader()
        let port = endpoint.smtp
        let pin = self.pin
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(5))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if port.mode == .implicit {
                        try channel.pipeline.syncOperations.addHandler(PinnedTLS.clientHandler(pin: pin, recorder: recorder))
                    }
                    try channel.pipeline.syncOperations.addHandler(reader)
                }
            }
        let channel: any Channel
        do {
            channel = try await bootstrap.connect(host: endpoint.host, port: port.port).get()
        } catch {
            throw BridgeError.unreachable
        }
        defer { channel.close(promise: nil) }
        do {
            try await reader.expect(220, on: channel)
            if port.mode == .startTLS {
                try await reader.command("EHLO postern", expect: 250, on: channel)
                try await reader.command("STARTTLS", expect: 220, on: channel)
                let handshake = channel.eventLoop.makePromise(of: Void.self)
                try await channel.eventLoop.submit {
                    let tls = try PinnedTLS.clientHandler(pin: pin, recorder: recorder)
                    try channel.pipeline.syncOperations.addHandler(tls, position: .first)
                    reader.expectHandshake(handshake)
                }.get()
                try await handshake.futureResult.get()
            }
            try await reader.command("EHLO postern", expect: 250, on: channel)
            let token = Data(("\u{0}" + credentials.username + "\u{0}" + credentials.password).utf8).base64EncodedString()
            do {
                try await reader.command("AUTH PLAIN " + token, expect: 235, on: channel, secret: true)
            } catch BridgeError.commandFailed {
                throw BridgeError.authenticationFailed
            }
            try await reader.command("MAIL FROM:<\(approved.envelopeFrom)>", expect: 250, on: channel)
            for recipient in approved.recipients {
                try await reader.command("RCPT TO:<\(recipient)>", expect: 250, on: channel)
            }
            try await reader.command("DATA", expect: 354, on: channel)
            try await reader.data(Self.dotStuffed(approved.rfc822), expect: 250, on: channel)
            try? await reader.command("QUIT", expect: 221, on: channel)
        } catch {
            if let seen = recorder.seenHash, seen != pin.sha256Hex { throw BridgeError.certificateMismatch(actual: seen) }
            if error is BridgeError { throw error }
            throw BridgeError.unreachable
        }
    }

    /// RFC 5321 transparency: a line that starts with a dot gets a second one, and the data ends with CRLF.CRLF.
    static func dotStuffed(_ data: Data) -> Data {
        var text = String(decoding: data, as: UTF8.self)
        if !text.hasSuffix("\r\n") { text += "\r\n" }
        let lines = text.components(separatedBy: "\r\n").map { $0.hasPrefix(".") ? "." + $0 : $0 }
        return Data((lines.joined(separator: "\r\n") + ".\r\n").utf8)
    }
}

/// Reads SMTP replies (`250-` continuation lines, `250 ` final line). Confined to the channel's event loop.
final class SMTPReader: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var buffer = ""
    private var lines: [String] = []
    private var waiter: EventLoopPromise<(Int, String)>?
    private var handshake: EventLoopPromise<Void>?
    private var failure: (any Error)?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data)
        buffer += bytes.readString(length: bytes.readableBytes) ?? ""
        buffer = buffer.replacingOccurrences(of: "\r\n", with: "\n")
        while let newline = buffer.firstIndex(of: "\n") {
            lines.append(String(buffer[..<newline]))
            buffer.removeSubrange(...newline)
        }
        deliver()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event {
            handshake?.succeed(())
            handshake = nil
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(BridgeError.unreachable)
        context.fireChannelInactive()
    }

    func expectHandshake(_ promise: EventLoopPromise<Void>) {
        if let failure { promise.fail(failure) } else { handshake = promise }
    }

    func expect(_ code: Int, on channel: any Channel) async throws {
        let reply = try await nextReply(on: channel)
        guard reply.0 == code else { throw BridgeError.commandFailed("SMTP \(reply.0) \(reply.1)") }
    }

    func command(_ line: String, expect code: Int, on channel: any Channel, secret: Bool = false) async throws {
        write(line + "\r\n", on: channel)
        let reply = try await nextReply(on: channel)
        guard reply.0 == code || (code == 250 && reply.0 == 251) else {
            throw BridgeError.commandFailed(secret ? "SMTP \(reply.0)" : "SMTP \(reply.0) \(reply.1)")
        }
    }

    func data(_ payload: Data, expect code: Int, on channel: any Channel) async throws {
        channel.eventLoop.execute {
            channel.writeAndFlush(channel.allocator.buffer(bytes: payload), promise: nil)
        }
        let reply = try await nextReply(on: channel)
        guard reply.0 == code else { throw BridgeError.commandFailed("SMTP \(reply.0) \(reply.1)") }
    }

    private func write(_ text: String, on channel: any Channel) {
        channel.eventLoop.execute {
            channel.writeAndFlush(channel.allocator.buffer(string: text), promise: nil)
        }
    }

    private func nextReply(on channel: any Channel) async throws -> (Int, String) {
        let promise = channel.eventLoop.makePromise(of: (Int, String).self)
        channel.eventLoop.execute {
            if let failure = self.failure { promise.fail(failure); return }
            self.waiter = promise
            self.deliver()
        }
        let timer = channel.eventLoop.scheduleTask(in: .seconds(60)) {
            if let waiter = self.waiter, waiter.futureResult === promise.futureResult {
                self.waiter = nil
                promise.fail(BridgeError.timeout)
            }
        }
        defer { timer.cancel() }
        return try await promise.futureResult.get()
    }

    /// Completes the waiter with the next complete reply: continuation lines up to the final `NNN ` line.
    private func deliver() {
        guard let waiter, let finalIndex = lines.firstIndex(where: { $0.count >= 4 && $0[$0.index($0.startIndex, offsetBy: 3)] != "-" }) else {
            return
        }
        let reply = Array(lines[...finalIndex])
        lines.removeSubrange(...finalIndex)
        self.waiter = nil
        let code = Int(reply.last!.prefix(3)) ?? 0
        waiter.succeed((code, reply.map { String($0.dropFirst(4)) }.joined(separator: " ")))
    }

    private func fail(_ error: any Error) {
        if failure == nil { failure = error }
        waiter?.fail(error)
        waiter = nil
        handshake?.fail(error)
        handshake = nil
    }
}
