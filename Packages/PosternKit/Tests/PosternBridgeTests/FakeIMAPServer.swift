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
    let store: FakeMailStore

    var plainLines: [String] { lock.withLock { _plainLines } }
    var tlsLines: [String] { lock.withLock { _tlsLines } }
    var port: Int { channel?.localAddress?.port ?? 0 }

    init(behavior: Behavior = .normal, store: FakeMailStore = FakeMailStore()) throws {
        certificate = try TestCertificate.make()
        self.behavior = behavior
        self.store = store
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
        var selected = ""

        init(server: FakeIMAPServer) { self.server = server }

        func channelActive(context: ChannelHandlerContext) {
            send(context, "* OK [CAPABILITY AUTH=PLAIN IMAP4rev1 STARTTLS] Fake Bridge ready")
        }

        var bytes: [UInt8] = []
        var literalRemaining = 0
        var literal: [UInt8] = []
        var appendTag: String?
        var appendMailbox = ""

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var incoming = unwrapInboundIn(data)
            bytes += incoming.readBytes(length: incoming.readableBytes) ?? []
            while true {
                if literalRemaining > 0 {
                    guard !bytes.isEmpty else { return }
                    let take = min(literalRemaining, bytes.count)
                    literal += bytes.prefix(take)
                    bytes.removeFirst(take)
                    literalRemaining -= take
                    continue
                }
                guard let end = bytes.indices.first(where: { $0 + 1 < bytes.count && bytes[$0] == 13 && bytes[$0 + 1] == 10 }) else { return }
                let line = String(decoding: bytes[..<end], as: UTF8.self)
                bytes.removeFirst(end + 2)
                if let tag = appendTag {
                    appendTag = nil
                    finishAppend(tag: tag, context)
                    continue
                }
                server.record(line, encrypted: encrypted)
                handle(line, context)
            }
        }

        private func finishAppend(tag: String, _ context: ChannelHandlerContext) {
            let text = String(decoding: literal, as: UTF8.self)
            let messageID = text.firstMatch(of: #/Message-ID: (<[^>]+>)/#).map { String($0.1) } ?? "<none>"
            server.store.record("APPEND \(appendMailbox) \(messageID)")
            server.store.add(messageID, folder: appendMailbox, flags: ["\\Draft", "\\Seen"])
            let index = server.store.messages.count - 1
            let uid = server.store.uid(of: index, in: appendMailbox)
            literal = []
            send(context, "\(tag) OK [APPENDUID 1 \(uid)] APPEND completed")
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
            case "LIST":
                for name in server.store.mailboxNames {
                    let attributes = name == "Folders" || name == "Labels" ? "\\Noselect" : "\\HasNoChildren"
                    send(context, "* LIST (\(attributes)) \"/\" \"\(name)\"")
                }
                send(context, "\(tag) OK LIST completed")
            case "EXAMINE", "SELECT":
                selected = Self.quoted(parts[2]).first ?? parts[2]
                server.store.record("\(parts[1].uppercased()) \(selected)")
                send(context, "* \(server.store.members(of: selected).count) EXISTS")
                send(context, "* OK [UIDVALIDITY 1] UIDs valid")
                send(context, "\(tag) OK completed")
            case "APPEND":
                appendMailbox = Self.quoted(parts[2]).first ?? "Drafts"
                literalRemaining = Int(parts[2].firstMatch(of: #/\{(\d+)\}$/#).map { String($0.1) } ?? "0") ?? 0
                appendTag = tag
                send(context, "+ Ready for literal data")
            case "CREATE":
                let name = Self.quoted(parts[2]).first ?? parts[2]
                server.store.record("CREATE \(name)")
                server.store.addMailbox(name)
                send(context, "\(tag) OK CREATE completed")
            case "UID":
                handleUID(tag: tag, line: parts[2], context)
            case "LOGOUT":
                send(context, "* BYE")
                send(context, "\(tag) OK LOGOUT completed")
            default:
                send(context, "\(tag) BAD unknown")
            }
        }

        private func handleUID(tag: String, line: String, _ context: ChannelHandlerContext) {
            let words = line.split(separator: " ", maxSplits: 2).map(String.init)
            let store = server.store
            switch words[0].uppercased() {
            case "SEARCH":
                let ids = Self.quoted(line)
                let members = store.members(of: selected).filter { ids.isEmpty || ids.contains(store.messages[$0].messageID) }
                send(context, "* SEARCH " + members.map { String(store.uid(of: $0, in: selected)) }.joined(separator: " "))
                send(context, "\(tag) OK SEARCH completed")
            case "FETCH":
                for (sequence, uid) in Self.uids(words[1]).enumerated() {
                    guard let index = store.index(ofUID: uid, in: selected) else { continue }
                    let message = store.messages[index]
                    let flags = message.flags.sorted().joined(separator: " ")
                    send(context, "* \(sequence + 1) FETCH (UID \(uid) FLAGS (\(flags)) ENVELOPE (NIL NIL NIL NIL NIL NIL NIL NIL NIL \"\(message.messageID)\"))")
                }
                send(context, "\(tag) OK FETCH completed")
            case "STORE":
                store.record("STORE \(selected) \(words[1]) \(words[2])")
                let on = words[2].hasPrefix("+")
                let flag = words[2].contains("Seen") ? "\\Seen" : words[2].contains("Deleted") ? "\\Deleted" : "\\Flagged"
                for uid in Self.uids(words[1]) {
                    if let index = store.index(ofUID: uid, in: selected) { store.setFlag(flag, on: on, index: index) }
                }
                send(context, "\(tag) OK STORE completed")
            case "MOVE":
                let destination = Self.quoted(words[2]).first ?? words[2]
                store.record("MOVE \(selected) -> \(destination)")
                var sources: [UInt32] = []
                var targets: [UInt32] = []
                for uid in Self.uids(words[1]) {
                    guard let index = store.index(ofUID: uid, in: selected) else { continue }
                    sources.append(uid)
                    targets.append(store.move(index: index, from: selected, to: destination))
                }
                if !sources.isEmpty {
                    let list = { (values: [UInt32]) in values.map(String.init).joined(separator: ",") }
                    send(context, "* OK [COPYUID 1 \(list(sources)) \(list(targets))] Moved")
                }
                send(context, "\(tag) OK MOVE completed")
            case "EXPUNGE":
                store.record("EXPUNGE \(selected) \(words[1])")
                for uid in Self.uids(words[1]) {
                    if let index = store.index(ofUID: uid, in: selected), store.messages[index].flags.contains("\\Deleted") {
                        store.remove(index: index)
                    }
                }
                send(context, "\(tag) OK EXPUNGE completed")
            default:
                send(context, "\(tag) BAD unknown")
            }
        }

        static func quoted(_ text: String) -> [String] {
            text.matches(of: #/"([^"]*)"/#).map { String($0.1) }.filter { $0.lowercased() != "message-id" }
        }

        static func uids(_ text: String) -> [UInt32] {
            text.split(separator: ",").flatMap { part -> [UInt32] in
                let bounds = part.split(separator: ":").compactMap { UInt32($0) }
                guard let first = bounds.first else { return [] }
                return Array(first...(bounds.last ?? first))
            }
        }

        private func send(_ context: ChannelHandlerContext, _ line: String) {
            context.writeAndFlush(NIOAny(context.channel.allocator.buffer(string: line + "\r\n")), promise: nil)
        }
    }
}
