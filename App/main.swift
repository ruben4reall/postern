import AppKit
import ServiceManagement

// `Postern --register-agent` registers the launch agent and exits, for scripts that install a build.
if CommandLine.arguments.contains("--register-agent") {
    // A new build may change the plist: register again from scratch.
    let agent = SMAppService.agent(plistName: "ch.rubencatalao.postern.core.plist")
    try? agent.unregister()
    UserDefaults.standard.removeObject(forKey: AppHandoff.agentVersionKey)
    AppHandoff.registerAgent()
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
if let index = CommandLine.arguments.firstIndex(of: "--hold-approval-panel"), index + 1 < CommandLine.arguments.count {
    let dark = CommandLine.arguments[index + 1] == "dark"
    let kind = index + 2 < CommandLine.arguments.count ? CommandLine.arguments[index + 2] : "email"
    MainActor.assumeIsolated { SetupSnapshots.holdApprovalPanel(dark: dark, kind: kind, seconds: 6) }
    exit(0)
}
if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.runBlocking())
}
if let index = CommandLine.arguments.firstIndex(of: "--selftest-status"), index + 1 < CommandLine.arguments.count {
    let stamp = "[selftest \(CommandLine.arguments[index + 1])]"
    exit(SelfTest.runBlocking { await SelfTest.status(stamp: stamp) })
}
if let index = CommandLine.arguments.firstIndex(of: "--selftest-cleanup"), index + 1 < CommandLine.arguments.count {
    let stamp = "[selftest \(CommandLine.arguments[index + 1])]"
    exit(SelfTest.runBlocking { await SelfTest.cleanUp(stamp: stamp) })
}
if CommandLine.arguments.contains("--snapshot-setup") {
    MainActor.assumeIsolated { SetupSnapshots.write() }
    exit(0)
}
#endif

let launchedByAgent = ProcessInfo.processInfo.environment["POSTERN_AGENT"] == "1"
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
if !launchedByAgent {
    // Opened by the user, or by Sparkle after an update: make sure the background agent is registered, then let it
    // show the window. If it can't run (turned off in Login Items), this copy shows the window itself and says so.
    AppHandoff.registerAgent()
    if MainActor.assumeIsolated({ AppHandoff.handOver() }) { exit(0) }
}
let delegate = AppDelegate(launchedByAgent: launchedByAgent)
application.delegate = delegate
application.run()
