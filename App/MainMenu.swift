import AppKit

/// The menu bar of the app while its window is open.
@MainActor
enum MainMenu {
    static func make(delegate: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "Postern")
        app.delegate = delegate
        refreshAppMenu(app, delegate: delegate)
        main.addItem(withTitle: "Postern", action: nil, keyEquivalent: "").submenu = app

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let view = NSMenu(title: "View")
        for (index, pane) in ControlModel.Pane.allCases.enumerated() {
            let item = NSMenuItem(title: pane.title, action: #selector(AppDelegate.showPane(_:)), keyEquivalent: "\(index + 1)")
            item.tag = index
            item.target = delegate
            view.addItem(item)
        }
        view.addItem(.separator())
        let sidebar = NSMenuItem(title: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        view.addItem(sidebar)
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = view

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        let site = NSMenuItem(title: "Postern on GitHub", action: #selector(AppDelegate.openWebsite), keyEquivalent: "")
        site.target = delegate
        help.addItem(site)
        let security = NSMenuItem(title: "Report a Security Issue", action: #selector(AppDelegate.openSecurityPolicy), keyEquivalent: "")
        security.target = delegate
        help.addItem(security)
        main.addItem(withTitle: "Help", action: nil, keyEquivalent: "").submenu = help
        NSApp.helpMenu = help
        return main
    }

    /// The app menu changes with the state: Pause or Resume, a waiting update, and the menu bar icon setting.
    static func refreshAppMenu(_ menu: NSMenu, delegate: AppDelegate) {
        menu.removeAllItems()
        let about = NSMenuItem(title: "About Postern", action: #selector(AppDelegate.openAbout), keyEquivalent: "")
        about.target = delegate
        menu.addItem(about)
        let update = NSMenuItem(title: delegate.updates.menuTitle, action: #selector(AppDelegate.checkForUpdates), keyEquivalent: "")
        update.target = delegate
        menu.addItem(update)
        menu.addItem(.separator())
        if CoreState.shared.backend != nil {
            let paused = CoreState.shared.policy.paused
            let pause = NSMenuItem(title: paused ? "Resume Postern…" : "Pause Postern", action: #selector(AppDelegate.togglePause), keyEquivalent: "")
            pause.target = delegate
            menu.addItem(pause)
        }
        let icon = NSMenuItem(title: "Show in Menu Bar", action: #selector(AppDelegate.toggleMenuBarIcon), keyEquivalent: "")
        icon.target = delegate
        icon.state = UserDefaults.standard.bool(forKey: AppDelegate.showsMenuBarIconKey) ? .on : .off
        menu.addItem(icon)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Postern", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = menu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Postern", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
}
