import NIOCore
import NIOIMAP
import NIOTLS

struct CommandResult: Sendable {
    let tagged: TaggedResponse
    let responses: [Response]

    var isOK: Bool {
        if case .ok = tagged.state { return true }
        return false
    }
}

/// Collects the responses of the single command in flight and completes it on its tagged reply.
///
/// Confined to the channel's event loop: every method is called from the loop, which is why the type can be
/// marked `@unchecked Sendable` to cross into the loop's closures.
final class ResponseRouter: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Response

    private var greetingPromise: EventLoopPromise<Response>?
    private var greeting: Response?
    private var pending: (tag: String, promise: EventLoopPromise<CommandResult>)?
    private var collected: [Response] = []
    private var handshakePromise: EventLoopPromise<Void>?
    private var handshakeDone = false
    private var failure: (any Error)?

    func expectGreeting(_ promise: EventLoopPromise<Response>) {
        if let greeting { promise.succeed(greeting) } else if let failure { promise.fail(failure) } else {
            greetingPromise = promise
        }
    }

    /// Whether the command may be written: a refused one has already failed its promise.
    func expect(tag: String, _ promise: EventLoopPromise<CommandResult>) -> Bool {
        if let failure { promise.fail(failure); return false }
        // Replacing the command in flight would leave it waiting forever: its reply and its timeout both look
        // for the pending tag. Refuse the newcomer instead.
        if let pending {
            promise.fail(BridgeError.commandFailed("\(tag) sent while \(pending.tag) was still waiting"))
            return false
        }
        pending = (tag, promise)
        collected = []
        return true
    }

    func expectHandshake(_ promise: EventLoopPromise<Void>) {
        if handshakeDone { promise.succeed(()) } else if let failure { promise.fail(failure) } else {
            handshakePromise = promise
        }
    }

    /// Fails the command with this tag if it is still waiting.
    func timeOut(tag: String) {
        guard let pending, pending.tag == tag else { return }
        self.pending = nil
        pending.promise.fail(BridgeError.timeout)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        if greeting == nil, pending == nil, case .untagged = response {
            greeting = response
            greetingPromise?.succeed(response)
            greetingPromise = nil
            return
        }
        if case .tagged(let tagged) = response, let current = pending, tagged.tag == current.tag {
            pending = nil
            let result = CommandResult(tagged: tagged, responses: collected)
            collected = []
            current.promise.succeed(result)
            return
        }
        if case .fatal(let text) = response {
            failAll(BridgeError.commandFailed(text.text))
            context.close(promise: nil)
            return
        }
        collected.append(response)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event {
            handshakeDone = true
            handshakePromise?.succeed(())
            handshakePromise = nil
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        failAll(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAll(BridgeError.unreachable)
        context.fireChannelInactive()
    }

    private func failAll(_ error: any Error) {
        if failure == nil { failure = error }
        greetingPromise?.fail(error)
        greetingPromise = nil
        pending?.promise.fail(error)
        pending = nil
        handshakePromise?.fail(error)
        handshakePromise = nil
    }
}
