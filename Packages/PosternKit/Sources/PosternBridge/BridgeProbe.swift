import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS

/// What one Bridge port showed when Postern looked at it, before anything is trusted.
public struct PortIdentity: Sendable, Equatable {
    public let mode: TLSMode
    public let greeting: String
    public let pin: CertificatePin

    public init(mode: TLSMode, greeting: String, pin: CertificatePin) {
        self.mode = mode
        self.greeting = greeting
        self.pin = pin
    }
}

/// Looks at a Bridge port without logging in: detects the TLS mode, completes a handshake and records the
/// certificate's fingerprint for the user to confirm. No credential is ever sent here.
public enum BridgeProbe {
    public enum Service: Sendable { case imap, smtp }

    public static func inspect(host: String = "127.0.0.1", port: Int, service: Service) async throws -> PortIdentity {
        let recorder = PeerCertificateRecorder()
        let handler = ProbeHandler()
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(3))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(handler) }
            }
        let channel: any Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            throw BridgeError.unreachable
        }
        defer { channel.close(promise: nil) }

        // A server that speaks first within 1.5 s is in STARTTLS mode; silence means it waits for a TLS hello.
        let plainGreeting = try? await handler.waitForLine(on: channel, seconds: 1.5) { _ in true }
        let mode: TLSMode = plainGreeting == nil ? .implicit : .startTLS

        if mode == .startTLS {
            switch service {
            case .imap:
                handler.write("P1 STARTTLS\r\n", on: channel)
                _ = try await handler.waitForLine(on: channel, seconds: 5) { $0.hasPrefix("P1 ") }
            case .smtp:
                handler.write("EHLO postern\r\n", on: channel)
                _ = try await handler.waitForLine(on: channel, seconds: 5) { $0.hasPrefix("250 ") }
                handler.write("STARTTLS\r\n", on: channel)
                _ = try await handler.waitForLine(on: channel, seconds: 5) { $0.hasPrefix("220") }
            }
        }

        let handshake = channel.eventLoop.makePromise(of: Void.self)
        try await channel.eventLoop.submit {
            let tls = try PinnedTLS.clientHandler(pin: nil, recorder: recorder)
            try channel.pipeline.syncOperations.addHandler(tls, position: .first)
            handler.expectHandshake(handshake)
        }.get()
        let timer = channel.eventLoop.scheduleTask(in: .seconds(5)) { handshake.fail(BridgeError.timeout) }
        defer { timer.cancel() }
        try await handshake.futureResult.get()

        let greeting: String
        if mode == .implicit {
            greeting = (try? await handler.waitForLine(on: channel, seconds: 3) { _ in true }) ?? ""
        } else {
            greeting = plainGreeting ?? ""
        }
        guard let hash = recorder.seenHash else { throw BridgeError.tlsFailed("No certificate presented") }
        return PortIdentity(mode: mode, greeting: greeting, pin: CertificatePin(sha256Hex: hash))
    }
}

/// Line reader for the probe. Confined to the channel's event loop.
private final class ProbeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var buffer = ""
    private var lines: [String] = []
    private var waiter: (predicate: (String) -> Bool, promise: EventLoopPromise<String>)?
    private var handshake: EventLoopPromise<Void>?

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
        handshake?.fail(error)
        handshake = nil
        waiter?.promise.fail(error)
        waiter = nil
        context.close(promise: nil)
    }

    func expectHandshake(_ promise: EventLoopPromise<Void>) { handshake = promise }

    func write(_ text: String, on channel: any Channel) {
        channel.eventLoop.execute {
            channel.writeAndFlush(channel.allocator.buffer(string: text), promise: nil)
        }
    }

    func waitForLine(
        on channel: any Channel, seconds: Double, _ predicate: @escaping @Sendable (String) -> Bool
    ) async throws -> String {
        let promise = channel.eventLoop.makePromise(of: String.self)
        channel.eventLoop.execute {
            self.waiter = (predicate, promise)
            self.deliver()
        }
        let timer = channel.eventLoop.scheduleTask(in: .milliseconds(Int64(seconds * 1000))) {
            if self.waiter?.promise.futureResult === promise.futureResult {
                self.waiter = nil
                promise.fail(BridgeError.timeout)
            }
        }
        defer { timer.cancel() }
        return try await promise.futureResult.get()
    }

    private func deliver() {
        guard let current = waiter else { return }
        while !lines.isEmpty {
            let line = lines.removeFirst()
            if current.predicate(line) {
                waiter = nil
                current.promise.succeed(line)
                return
            }
        }
    }
}
