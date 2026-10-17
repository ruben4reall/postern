import AppKit
import PosternPolicy
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let listener = CoreListener()
    private var statusItem: NSStatusItem?
    private var setupWindow: NSWindow?
    private var controlWindow: NSWindow?
    private let control = ControlModel()

    /// launchd starts Postern on demand when a client connects; that launch must stay silent.
    private var launchedByAgent: Bool { ProcessInfo.processInfo.environment["POSTERN_AGENT"] == "1" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        control.openSetup = { [weak self] in self?.showSetup() }
        CoreState.shared.onChange = { [weak self] in
            Task { @MainActor in self?.control.refresh() }
        }
        PosternFolders.prepare()
        CoreState.shared.reload()
        listener.start()
        installStatusItem()
        observeScreenLock()
        if !launchedByAgent {
            registerAgent()
            if CoreState.shared.backend == nil { showSetup() } else { showControl() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if CoreState.shared.backend == nil { showSetup() } else { showControl() }
        return true
    }

    /// Pauses Postern when the screen locks, if the user asked for it. Pausing takes power away, so it needs no
    /// proof; resuming does.
    private func observeScreenLock() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                let state = CoreState.shared
                guard state.policy.pauseWhenLocked, !state.policy.paused else { return }
                var policy = state.policy
                policy.paused = true
                try? PolicyStore(vault: state.vault).save(policy)
                state.reloadPolicy()
            }
        }
    }

    @objc func openControl() { showControl() }

    @objc func togglePause() {
        Task { await control.setPaused(!CoreState.shared.policy.paused) }
    }

    func showControl() {
        control.refresh()
        if controlWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ControlView(model: control)))
            window.title = "Postern"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 820, height: 580))
            window.center()
            window.setFrameAutosaveName("PosternControl")
            controlWindow = window
        }
        NSApp.activate()
        controlWindow?.makeKeyAndOrderFront(nil)
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
            let model = OnboardingModel { [weak self] in
                self?.setupWindow?.close()
                self?.setupWindow = nil
                self?.showControl()
            }
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
        } else if state.policy.paused {
            status = "Paused"
        } else if state.policy.enabledTools.isEmpty {
            status = "On, no tool turned on"
        } else {
            status = "On, \(state.policy.enabledTools.count) tools turned on"
        }
        let header = NSMenuItem(title: "Postern: \(status)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let apps = state.connectedApps
        let connected = NSMenuItem(title: apps.isEmpty ? "No app connected" : "Connected: \(Set(apps).sorted().joined(separator: ", "))", action: nil, keyEquivalent: "")
        connected.isEnabled = false
        menu.addItem(connected)
        menu.addItem(.separator())
        if state.backend != nil {
            let pause = NSMenuItem(title: state.policy.paused ? "Resume Postern…" : "Pause Postern", action: #selector(togglePause), keyEquivalent: "")
            pause.target = self
            menu.addItem(pause)
            let open = NSMenuItem(title: "Open Postern…", action: #selector(openControl), keyEquivalent: ",")
            open.target = self
            menu.addItem(open)
        } else {
            let setup = NSMenuItem(title: "Set Up Postern…", action: #selector(openSetup), keyEquivalent: "")
            setup.target = self
            menu.addItem(setup)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Postern", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}
