import AppKit
import ServiceManagement

/// Opening Postern from the Finder or the Dock starts a second copy of the app. That copy asks the one launchd runs
/// (launchd starts it if needed) to show its window, hands it the focus and quits: one Postern, one menu bar icon,
/// one policy in memory.
enum AppHandoff {
    /// Raised whenever the launch agent's plist changes: launchd keeps the plist it read at registration, so a new
    /// one (a new Mach service) only applies after registering again.
    static let agentVersion = 2
    static let agentVersionKey = "LaunchAgentVersion"

    /// Registers the background agent, or registers it again when its plist changed since the last time.
    static func registerAgent() {
        let agent = SMAppService.agent(plistName: "ch.rubencatalao.postern.core.plist")
        let defaults = UserDefaults.standard
        if agent.status == .enabled, defaults.integer(forKey: agentVersionKey) == agentVersion { return }
        if agent.status == .enabled { try? agent.unregister() }
        do {
            try agent.register()
            defaults.set(agentVersion, forKey: agentVersionKey)
        } catch {
            // Turned off in Login Items, or waiting for approval: the window says so.
        }
    }

    /// True when the core took over and this copy can quit.
    @MainActor static func handOver(timeout: TimeInterval = 10) -> Bool {
        let connection = NSXPCConnection(machServiceName: PosternXPC.appMachService)
        connection.setCodeSigningRequirement(PosternXPC.teamRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: AppXPC.self)
        connection.resume()
        defer { connection.invalidate() }
        let box = ReplyBox()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable _ in box.fail() }) as? AppXPC else { return false }
        proxy.processIdentifier { @Sendable pid in box.answer(Int(pid)) }
        guard let pid = box.wait(timeout), let core = NSRunningApplication(processIdentifier: pid_t(pid)) else { return false }
        NSApp.yieldActivation(to: core)
        let shown = ReplyBox()
        proxy.showWindow { @Sendable ok in shown.answer(ok ? 1 : 0) }
        return shown.wait(timeout) == 1
    }
}

/// The first answer of an XPC call, or nil on failure or timeout.
final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var value: Int?
    private var finished = false

    func answer(_ value: Int) { finish(value) }
    func fail() { finish(nil) }

    private func finish(_ value: Int?) {
        let first = lock.withLock { () -> Bool in
            guard !finished else { return false }
            finished = true
            self.value = value
            return true
        }
        if first { done.signal() }
    }

    func wait(_ timeout: TimeInterval) -> Int? {
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return lock.withLock { value }
    }
}

/// The core's side: shows the window when another copy asks. Only copies signed by Postern's team are answered.
final class AppListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener = NSXPCListener(machServiceName: PosternXPC.appMachService)
    private let show: @MainActor () -> Void

    init(show: @escaping @MainActor () -> Void) {
        self.show = show
    }

    func start() {
        listener.delegate = self
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(PosternXPC.teamRequirement)
        connection.exportedInterface = NSXPCInterface(with: AppXPC.self)
        connection.exportedObject = AppService(show: show)
        connection.resume()
        return true
    }
}

private final class AppService: NSObject, AppXPC, @unchecked Sendable {
    private let show: @MainActor () -> Void

    init(show: @escaping @MainActor () -> Void) {
        self.show = show
    }

    func processIdentifier(reply: @escaping @Sendable (Int32) -> Void) {
        reply(ProcessInfo.processInfo.processIdentifier)
    }

    func showWindow(reply: @escaping @Sendable (Bool) -> Void) {
        let show = self.show
        DispatchQueue.main.async {
            MainActor.assumeIsolated { show() }
            reply(true)
        }
    }
}
