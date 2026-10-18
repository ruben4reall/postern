import AppKit
import PosternPolicy
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// launchd starts Postern when an app connects, and when a copy opened from the Finder or the Dock hands over.
    /// Otherwise this copy runs alone because the background agent can't, and it says so.
    let launchedByAgent: Bool
    private let listener = CoreListener()
    private lazy var appListener = AppListener { [weak self] in self?.showMain() }
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private let control = ControlModel()
    /// Started once launched, in the copy that keeps running: the copies that hand over and quit never check.
    private(set) lazy var updates = Updates()

    static let showsMenuBarIconKey = "ShowsMenuBarIcon"

    init(launchedByAgent: Bool) {
        self.launchedByAgent = launchedByAgent
        UserDefaults.standard.register(defaults: [Self.showsMenuBarIconKey: true])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        control.backgroundServiceOff = !launchedByAgent
        CoreState.shared.onChange = { [weak self] in
            Task { @MainActor in self?.control.refresh() }
        }
        PosternFolders.prepare()
        control.updates = updates
        updates.willRelaunch = { [weak self] in self?.closeModalsForUpdate() }
        CoreState.shared.reload()
        if launchedByAgent {
            listener.start()
            appListener.start()
        }
        NSApp.mainMenu = MainMenu.make(delegate: self)
        updateStatusItem()
        observeScreenLock()
        if !launchedByAgent { showMain() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain()
        return true
    }

    /// Closing the window keeps Postern serving apps in the background; it leaves the Dock until the next opening.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !launchedByAgent }

    // MARK: Main window

    func showMain() {
        control.refresh()
        if mainWindow == nil {
            let host = NSHostingController(rootView: ControlView(model: control))
            host.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: host)
            window.title = "Postern"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 940, height: 640))
            window.contentMinSize = NSSize(width: 820, height: 560)
            window.center()
            window.setFrameAutosaveName("PosternMain")
            mainWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
        mainWindow?.orderFrontRegardless()
        if !control.configured {
            control.showingSetup = true
        } else if !control.showingSetup, let window = mainWindow {
            updates.askAboutAutomaticChecks(in: window)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard launchedByAgent, (notification.object as? NSWindow) === mainWindow else { return }
        // Back to the background: no Dock icon while no window is open.
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }

    @objc func openMain() { showMain() }

    @objc func showPane(_ sender: NSMenuItem) {
        guard let pane = ControlModel.Pane.allCases[safe: sender.tag] else { return }
        control.pane = pane
        showMain()
    }

    @objc func togglePause() {
        Task { await control.setPaused(!CoreState.shared.policy.paused) }
    }

    @objc func toggleMenuBarIcon() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: Self.showsMenuBarIconKey), forKey: Self.showsMenuBarIconKey)
        updateStatusItem()
    }

    @objc func openAbout() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        let credits = NSAttributedString(
            string: "An open-source gate between your mailbox and the apps you connect to it.\nIndependent project, not affiliated with Proton AG.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// Sparkle downloads, checks the EdDSA signature, then waits for "Install and Relaunch". It quits this copy (the
    /// launch agent, or the copy running alone), replaces the app, and opens the new one, which registers the agent
    /// again if its plist changed and hands over to it (main.swift, AppHandoff).
    @objc func checkForUpdates() { updates.checkForUpdates() }

    /// AppKit refuses to quit while a sheet or a modal panel is open: the setup, the question about automatic checks,
    /// the folder picker of Connect. Sparkle's request to quit would beep and the update would wait. Close them first.
    private func closeModalsForUpdate() {
        if NSApp.modalWindow != nil { NSApp.abortModal() }
        control.showingSetup = false
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
    }

    @objc func openWebsite() { NSWorkspace.shared.open(Links.repository) }
    @objc func openSecurityPolicy() { NSWorkspace.shared.open(Links.securityPolicy) }

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

    // MARK: Menu bar

    func updateStatusItem() {
        let shows = UserDefaults.standard.bool(forKey: Self.showsMenuBarIconKey)
        if shows, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let image = NSImage(named: "MenuBarIcon")
            image?.isTemplate = true
            image?.accessibilityDescription = "Postern"
            item.button?.image = image
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        } else if !shows, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    var statusText: String {
        let state = CoreState.shared
        if state.backend == nil { return "Not set up" }
        if state.policy.paused { return "Paused" }
        let count = state.policy.enabledTools.count
        return count == 0 ? "On, every tool off" : "On, \(count) tool\(count == 1 ? "" : "s") on"
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === NSApp.mainMenu?.items.first?.submenu {
            MainMenu.refreshAppMenu(menu, delegate: self)
            return
        }
        menu.removeAllItems()
        let state = CoreState.shared
        let header = NSMenuItem(title: "Postern: \(statusText)", action: nil, keyEquivalent: "")
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
        }
        let open = NSMenuItem(title: state.backend == nil ? "Set Up Postern…" : "Open Postern", action: #selector(openMain), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let update = NSMenuItem(title: updates.menuTitle, action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Postern", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(checkForUpdates) ? updates.canCheck : true
    }
}

enum Links {
    static let repository = URL(string: "https://github.com/ruben4reall/postern")!
    static let securityPolicy = URL(string: "https://github.com/ruben4reall/postern/security/policy")!
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
