import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let listener = CoreListener()
    private var statusItem: NSStatusItem?
    private var setupWindow: NSWindow?

    /// launchd starts Postern on demand when a client connects; that launch must stay silent.
    private var launchedByAgent: Bool { ProcessInfo.processInfo.environment["POSTERN_AGENT"] == "1" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        CoreState.shared.reload()
        listener.start()
        installStatusItem()
        if !launchedByAgent {
            registerAgent()
            if CoreState.shared.backend == nil { showSetup() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if CoreState.shared.backend == nil { showSetup() }
        return true
    }

    private func registerAgent() {
        let agent = SMAppService.agent(plistName: "ch.rubencatalao.postern.core.plist")
        if agent.status != .enabled { try? agent.register() }
    }

    // MARK: Menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "envelope.badge.shield.half.filled", accessibilityDescription: "Postern")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    @objc func openSetup() { showSetup() }

    func showSetup() {
        if setupWindow == nil {
            let model = OnboardingModel { [weak self] in self?.setupWindow?.close() }
            let window = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView(model: model)))
            window.title = "Set Up Postern"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            setupWindow = window
        }
        NSApp.activate()
        setupWindow?.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = CoreState.shared
        let status: String
        if state.backend == nil {
            status = "Not set up"
        } else if state.policy.enabledTools.isEmpty {
            status = "Ready, no tool enabled"
        } else {
            status = "Ready, reading allowed"
        }
        let header = NSMenuItem(title: "Postern: \(status)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let clients = state.sessionCount
        let connected = NSMenuItem(title: clients == 1 ? "1 client connected" : "\(clients) clients connected", action: nil, keyEquivalent: "")
        connected.isEnabled = false
        menu.addItem(connected)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: state.backend == nil ? "Set Up Postern…" : "Run Setup Again…", action: #selector(openSetup), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Postern", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action == #selector(openSetup) { item.target = self }
    }
}
