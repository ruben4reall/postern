import Foundation
import NIOCore
import NIOIMAP
import NIOPosix
import NIOSSL
import PosternModel
import PosternText

/// A mailbox as Bridge names it: the raw IMAP name for commands, a readable name for people.
public struct BridgeMailbox: Sendable, Hashable {
    public let raw: String
    public let display: String
    public let selectable: Bool
}

public struct MailboxStatusInfo: Sendable {
    public let uidValidity: UInt32
    public let exists: Int
}

/// One authenticated IMAP session with Bridge.
///
/// Opening it always establishes TLS against the pinned certificate before the password is written, whatever
/// Bridge advertises: Bridge offers `AUTH=PLAIN` on the plain-text greeting, and a naive client would use it.
public actor IMAPConnection {
    private let endpoint: BridgeEndpoint
    private let pin: CertificatePin
    private let credentials: BridgeCredentials
    private var channel: (any Channel)?
    private var router: ResponseRouter?
    private var nextTag = 0
    private var mailboxCache: [String: BridgeMailbox] = [:]

    public init(endpoint: BridgeEndpoint, pin: CertificatePin, credentials: BridgeCredentials) {
        self.endpoint = endpoint
        self.pin = pin
        self.credentials = credentials
    }

    public var isOpen: Bool { channel?.isActive ?? false }

    // MARK: Lifecycle

    public func open() async throws {
        let recorder = PeerCertificateRecorder()
        let router = ResponseRouter()
        let port = endpoint.imap
        let pin = self.pin
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(5))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if port.mode == .implicit {
                        try channel.pipeline.syncOperations.addHandler(
                            PinnedTLS.clientHandler(pin: pin, recorder: recorder)
                        )
                    }
                    try channel.pipeline.syncOperations.addHandler(IMAPClientHandler())
                    try channel.pipeline.syncOperations.addHandler(router)
                }
            }
        let channel: any Channel
        do {
            channel = try await bootstrap.connect(host: endpoint.host, port: port.port).get()
        } catch {
            throw BridgeError.unreachable
        }
        self.channel = channel
        self.router = router

        do {
            let greetingPromise = channel.eventLoop.makePromise(of: Response.self)
            channel.eventLoop.execute { router.expectGreeting(greetingPromise) }
            let greeting = try await withDeadline(channel, seconds: 10, greetingPromise)
            guard case .untagged(.conditionalState(.ok)) = greeting else {
                throw BridgeError.notBridge("Unexpected greeting")
            }
            if port.mode == .startTLS {
                let reply = try await send(.startTLS)
                guard reply.isOK else { throw BridgeError.starttlsRefused }
                let handshake = channel.eventLoop.makePromise(of: Void.self)
                try await channel.eventLoop.submit {
                    let tls = try PinnedTLS.clientHandler(pin: pin, recorder: recorder)
                    try channel.pipeline.syncOperations.addHandler(tls, position: .first)
                    router.expectHandshake(handshake)
                }.get()
                try await withDeadline(channel, seconds: 10, handshake)
            }
            let login = try await send(.login(username: credentials.username, password: credentials.password))
            guard login.isOK else { throw BridgeError.authenticationFailed }
        } catch {
            await close()
            if let seen = recorder.seenHash, seen != pin.sha256Hex {
                throw BridgeError.certificateMismatch(actual: seen)
            }
            if error is BridgeError { throw error }
            if error is NIOSSLError || error is BoringSSLError { throw BridgeError.tlsFailed(String(describing: error)) }
            throw BridgeError.unreachable
        }
    }

    public func close() async {
        guard let channel else { return }
        self.channel = nil
        self.router = nil
        if channel.isActive {
            _ = try? await send(on: channel, .logout, timeout: .seconds(2))
            try? await channel.close().get()
        }
    }

    // MARK: Commands

    public func mailboxes(refresh: Bool = false) async throws -> [BridgeMailbox] {
        if !refresh, !mailboxCache.isEmpty { return Array(mailboxCache.values) }
        let reply = try await send(Self.listAllCommand)
        guard reply.isOK else { throw BridgeError.commandFailed(reply.tagged.state.text) }
        var found: [String: BridgeMailbox] = [:]
        for case .untagged(.mailboxData(.list(let info))) in reply.responses {
            let raw = String(decoding: info.path.name.bytes, as: UTF8.self)
            let separator = info.path.pathSeparator.map(String.init) ?? "/"
            let display = UnicodeCleaner.clean(
                info.path.displayStringComponents().joined(separator: separator), keepNewlines: false
            )
            let selectable = !info.attributes.contains(.noSelect)
            found[display] = BridgeMailbox(raw: raw, display: display, selectable: selectable)
        }
        mailboxCache = found
        return Array(found.values)
    }

    public func mailbox(named display: String) async throws -> BridgeMailbox {
        if let cached = mailboxCache[display] { return cached }
        _ = try await mailboxes(refresh: true)
        guard let found = mailboxCache[display] ?? mailboxCache.values.first(where: { $0.raw == display }) else {
            throw BridgeError.mailboxNotFound(display)
        }
        return found
    }

    public func status(_ mailbox: BridgeMailbox) async throws -> (total: Int?, unread: Int?) {
        let reply = try await send(.status(MailboxName(Array(mailbox.raw.utf8)), [.messageCount, .unseenCount]))
        guard reply.isOK else { return (nil, nil) }
        for case .untagged(.mailboxData(.status(_, let status))) in reply.responses {
            return (status.messageCount, status.unseenCount)
        }
        return (nil, nil)
    }

    public func examine(_ mailbox: BridgeMailbox) async throws -> MailboxStatusInfo {
        let reply = try await send(.examine(MailboxName(Array(mailbox.raw.utf8))))
        guard reply.isOK else { throw BridgeError.mailboxNotFound(mailbox.display) }
        return try Self.status(from: reply, mailbox: mailbox)
    }

    /// UIDs matching `key` in the examined mailbox, newest first.
    public func uidSearch(_ key: SearchKey) async throws -> [UInt32] {
        let reply = try await send(.uidSearch(key: key))
        guard reply.isOK else { throw BridgeError.commandFailed(reply.tagged.state.text) }
        var uids: [UInt32] = []
        for case .untagged(.mailboxData(.search(let ids, _))) in reply.responses {
            uids.append(contentsOf: ids.map { UID($0).rawValue })
        }
        return uids.sorted(by: >)
    }

    public func fetchSummaries(_ uids: [UInt32]) async throws -> [FetchedSummary] {
        guard let set = Self.uidSet(uids) else { return [] }
        let reply = try await send(.uidFetch(.set(set), [.uid, .flags, .envelope, .rfc822Size, .bodyStructure(extensions: true)], []))
        guard reply.isOK else { throw BridgeError.commandFailed(reply.tagged.state.text) }
        return FetchAssembler.summaries(from: reply.responses)
    }

    /// The complete raw message, refused above `maxBytes` before any byte of it is downloaded.
    public func fetchRaw(uid: UInt32, maxBytes: Int) async throws -> Data {
        guard let set = Self.uidSet([uid]) else { throw BridgeError.commandFailed("Empty UID") }
        let sizeReply = try await send(.uidFetch(.set(set), [.uid, .rfc822Size], []))
        guard sizeReply.isOK else { throw BridgeError.commandFailed(sizeReply.tagged.state.text) }
        let sizes = FetchAssembler.summaries(from: sizeReply.responses)
        guard let size = sizes.first?.size else { throw BridgeError.mailboxNotFound("message \(uid)") }
        guard size <= maxBytes else { throw BridgeError.tooLarge }
        let reply = try await send(.uidFetch(.set(set), [.uid, .bodySection(peek: true, .complete, nil)], []), timeout: .seconds(60))
        guard reply.isOK else { throw BridgeError.commandFailed(reply.tagged.state.text) }
        guard let body = FetchAssembler.bodies(from: reply.responses).first else {
            throw BridgeError.mailboxNotFound("message \(uid)")
        }
        return body
    }

    // MARK: Plumbing

    func sendCommand(_ command: Command, timeout: TimeAmount = .seconds(30)) async throws -> CommandResult {
        try await send(command, timeout: timeout)
    }

    private func send(_ command: Command, timeout: TimeAmount = .seconds(30)) async throws -> CommandResult {
        guard let channel else { throw BridgeError.unreachable }
        return try await send(on: channel, command, timeout: timeout)
    }

    private func send(on channel: any Channel, _ command: Command, timeout: TimeAmount) async throws -> CommandResult {
        guard let router else { throw BridgeError.unreachable }
        nextTag += 1
        let tag = "P\(nextTag)"
        let promise = channel.eventLoop.makePromise(of: CommandResult.self)
        let part = CommandStreamPart.tagged(TaggedCommand(tag: tag, command: command))
        channel.eventLoop.execute {
            router.expect(tag: tag, promise)
            channel.writeAndFlush(IMAPClientHandler.Message.part(part), promise: nil)
        }
        let timer = channel.eventLoop.scheduleTask(in: timeout) { router.timeOut(tag: tag) }
        defer { timer.cancel() }
        do {
            return try await promise.futureResult.get()
        } catch BridgeError.timeout {
            try? await channel.close().get()
            throw BridgeError.timeout
        }
    }

    private func withDeadline<T: Sendable>(
        _ channel: any Channel, seconds: Int64, _ promise: EventLoopPromise<T>
    ) async throws -> T {
        let timer = channel.eventLoop.scheduleTask(in: .seconds(seconds)) {
            channel.close(promise: nil)
        }
        defer { timer.cancel() }
        return try await promise.futureResult.get()
    }

    /// `LIST "" "*"`. The `.pattern` form writes `("*")`, an RFC 5258 extension that Bridge rejects.
    static let listAllCommand = Command.list(nil, reference: MailboxName(ByteBuffer()), .mailbox(ByteBuffer(string: "*")))

    static func uidSet(_ uids: [UInt32]) -> MessageIdentifierSetNonEmpty<UID>? {
        let ranges = uids.map { MessageIdentifierRange<UID>(UID(rawValue: $0)...UID(rawValue: $0)) }
        return MessageIdentifierSetNonEmpty(set: MessageIdentifierSet<UID>(ranges))
    }
}

extension TaggedResponse.State {
    var text: String {
        switch self {
        case .ok(let text), .no(let text), .bad(let text): text.text
        }
    }
}
