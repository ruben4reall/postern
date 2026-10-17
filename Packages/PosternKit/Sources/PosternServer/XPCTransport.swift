import Foundation
import Logging
import MCP

/// An MCP transport fed by the relay's XPC messages. Each JSON-RPC message arrives as one `Data`.
public actor XPCTransport: Transport {
    public nonisolated let logger: Logger
    private let sendHandler: @Sendable (Data) -> Void
    private let stream: AsyncThrowingStream<Data, any Swift.Error>
    private nonisolated let continuation: AsyncThrowingStream<Data, any Swift.Error>.Continuation

    public init(send: @escaping @Sendable (Data) -> Void) {
        self.sendHandler = send
        self.logger = Logger(label: "ch.rubencatalao.postern.transport")
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    public func connect() async throws {}

    public func disconnect() async {
        continuation.finish()
    }

    public nonisolated func finish() {
        continuation.finish()
    }

    public func send(_ data: Data) async throws {
        sendHandler(data)
    }

    public func receive() -> AsyncThrowingStream<Data, any Swift.Error> {
        stream
    }

    /// A message from the client, as the relay received it on stdin. Nonisolated so messages keep the order in
    /// which XPC delivers them.
    public nonisolated func deliver(_ data: Data) {
        continuation.yield(data)
    }
}
