import Foundation
import PosternCore
import PosternModel
import PosternServer

/// Accepts relays on the Mach service and runs one MCP session per relay.
final class CoreListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener = NSXPCListener(machServiceName: PosternXPC.coreMachService)

    func start() {
        listener.delegate = self
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(PosternXPC.teamRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: RelayXPC.self)
        let relay = RelayProxy(connection.remoteObjectProxyWithErrorHandler { @Sendable _ in } as! RelayXPC)
        let transport = XPCTransport { data in relay.proxy.receive(data) }
        let handler = RelayConnection(transport: transport)
        connection.exportedInterface = NSXPCInterface(with: CoreXPC.self)
        connection.exportedObject = handler

        let session = CoreState.shared.openSession(transport: transport, connection: handler)
        let stop: @Sendable () -> Void = {
            transport.finish()
            session.close()
        }
        connection.invalidationHandler = stop
        connection.interruptionHandler = stop
        connection.resume()
        return true
    }
}

/// Receives the relay's messages for one session.
final class RelayConnection: NSObject, CoreXPC, ClientConnection, @unchecked Sendable {
    private let transport: XPCTransport
    private let lock = NSLock()
    private var name = "MCP client"

    var clientName: String { lock.withLock { name } }

    init(transport: XPCTransport) {
        self.transport = transport
    }

    func hello(clientName: String, reply: @escaping @Sendable (Bool) -> Void) {
        let label = Self.label(for: clientName)
        lock.withLock { name = label }
        CoreState.shared.changed()
        reply(true)
    }

    func deliver(_ message: Data) {
        transport.deliver(message)
    }

    /// A readable name for the process that launched the relay.
    static func label(for process: String) -> String { ClientNames.label(forProcess: process) }
}

/// XPC proxies are safe to message from any thread; this box says so to the compiler.
final class RelayProxy: @unchecked Sendable {
    let proxy: RelayXPC

    init(_ proxy: RelayXPC) {
        self.proxy = proxy
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
}
