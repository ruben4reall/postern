import AppKit
import ServiceManagement

// `Postern --register-agent` registers the launch agent and exits, for scripts that install a build.
if CommandLine.arguments.contains("--register-agent") {
    let agent = SMAppService.agent(plistName: "ch.rubencatalao.postern.core.plist")
    do { try agent.register() } catch { print("register failed: \(error)") }
    print("agent status: \(agent.status.rawValue)")
    exit(0)
}

#if DEBUG
// `Postern --snapshot-setup` draws every setup step offscreen, for review and documentation.
if let index = CommandLine.arguments.firstIndex(of: "--hold-control-window"), index + 2 < CommandLine.arguments.count {
    let arguments = CommandLine.arguments
    MainActor.assumeIsolated {
        SetupSnapshots.holdControlWindow(pane: arguments[index + 1], dark: arguments[index + 2] == "dark", seconds: 6)
    }
    exit(0)
}
if CommandLine.arguments.contains("--snapshot-setup") {
    MainActor.assumeIsolated { SetupSnapshots.write() }
    exit(0)
}
#endif

let delegate = AppDelegate()
let application = NSApplication.shared
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
