import Foundation
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

        let key = ObjectIdentifier(handler)
        let state = CoreState.shared
        let session = Session(
            transport: transport, backend: LiveBackend(), version: Bundle.main.shortVersion,
            policy: { state.policy }, readiness: { state.readiness }
        )
        state.add(session, for: key)
        let stop: @Sendable () -> Void = {
            transport.finish()
            if let session = state.removeSession(for: key) { Task { await session.stop() } }
        }
        connection.invalidationHandler = stop
        connection.interruptionHandler = stop
        connection.resume()
        Task { try? await session.start() }
        return true
    }
}

/// Receives the relay's messages for one session.
final class RelayConnection: NSObject, CoreXPC, @unchecked Sendable {
    private let transport: XPCTransport
    private(set) var clientName = "MCP client"

    init(transport: XPCTransport) {
        self.transport = transport
    }

    func hello(clientName: String, reply: @escaping @Sendable (Bool) -> Void) {
        self.clientName = String(clientName.prefix(64))
        reply(true)
    }

    func deliver(_ message: Data) {
        transport.deliver(message)
    }
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
