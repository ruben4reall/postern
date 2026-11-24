import Foundation

/// The interface's end of the control channel: the app and the command line ask the core, and hear its events.
public final class ControlClient: @unchecked Sendable {
    private let connection: LocalConnection
    private let lock = NSLock()
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<ControlWire.Message, Never>] = [:]
    private var handler: (@Sendable (String, ControlWire.Result?) -> Void)?
    private var closedHandler: (@Sendable () -> Void)?

    /// Connects to this user's core, starting it when none answers.
    public init(startCore: Bool = true) throws {
        if let connection = try? LocalChannel.connect() {
            self.connection = connection
        } else {
            guard startCore, let core = PosternPaths.program("postern-core") else {
                throw LocalChannelError.unavailable("Postern's core is not running.")
            }
            CoreStarter.start(core)
            var found: LocalConnection?
            for _ in 0..<50 where found == nil {
                Thread.sleep(forTimeInterval: 0.1)
                found = try? LocalChannel.connect()
            }
            guard let found else { throw LocalChannelError.unavailable("Postern's core did not start.") }
            connection = found
        }
        connection.write(try ControlWire.encoder.encode(ControlWire.Hello(postern: .control)))
        Thread.detachNewThread { [weak self] in self?.readLoop() }
    }

    /// Events from the core: `changed`, `approval`, `approval.closed`.
    public func onEvent(_ handler: @escaping @Sendable (String, ControlWire.Result?) -> Void) {
        lock.withLock { self.handler = handler }
    }

    /// Called once if the core goes away.
    public func onClose(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { closedHandler = handler }
    }

    public func call(_ method: String, _ params: ControlWire.Params? = nil) async throws -> ControlWire.Result {
        let id = lock.withLock { () -> Int in
            defer { nextID += 1 }
            return nextID
        }
        let request = try ControlWire.encoder.encode(ControlWire.Request(id: id, method: method, params: params))
        let answer = await withCheckedContinuation { continuation in
            lock.withLock { waiting[id] = continuation }
            if !connection.write(request) {
                let gone = lock.withLock { waiting.removeValue(forKey: id) }
                gone?.resume(returning: ControlWire.Message(id: id, error: .init("closed", "Postern's core went away.")))
            }
        }
        if let error = answer.error { throw error }
        return answer.result ?? ControlWire.Result()
    }

    public func close() { connection.close() }

    private func readLoop() {
        while let line = connection.readLine() {
            guard let message = try? ControlWire.decoder.decode(ControlWire.Message.self, from: line) else { continue }
            if let event = message.event {
                lock.withLock { handler }?(event, message.data)
            } else if let id = message.id, let continuation = lock.withLock({ waiting.removeValue(forKey: id) }) {
                continuation.resume(returning: message)
            }
        }
        let pending = lock.withLock { () -> [CheckedContinuation<ControlWire.Message, Never>] in
            defer { waiting.removeAll() }
            return Array(waiting.values)
        }
        for continuation in pending { continuation.resume(returning: ControlWire.Message(error: .init("closed", "Postern's core went away."))) }
        lock.withLock { closedHandler }?()
    }
}
