#if os(Linux)
import CGtk
import Foundation
import PosternModel
import PosternPlatform
import PosternPolicy

/// What the window shows, read from the core and kept fresh by its events.
final class Model: @unchecked Sendable {
    var status: ControlWire.Status?
    var tools: [ControlWire.ToolInfo] = []
    var mailboxes: [ControlWire.MailboxRow] = []
    var apps: [ControlWire.AppRow] = []
    var activity: [ControlWire.ActivityRow] = []
    var batches: [ControlWire.BatchRow] = []
}

enum Pane: String, CaseIterable {
    case overview, tools, mailboxes, apps, activity, security

    var title: String {
        switch self {
        case .overview: "Overview"
        case .tools: "Tools"
        case .mailboxes: "Mailboxes"
        case .apps: "Apps"
        case .activity: "Activity"
        case .security: "Security"
        }
    }

    var icon: String {
        switch self {
        case .overview: "security-high-symbolic"
        case .tools: "preferences-system-symbolic"
        case .mailboxes: "folder-symbolic"
        case .apps: "network-workgroup-symbolic"
        case .activity: "document-open-recent-symbolic"
        case .security: "channel-secure-symbolic"
        }
    }
}

/// The Linux app: the window, its panes, the setup, and the approval windows the core asks for.
final class PosternApp {
    let application: W?
    var window: W?
    var client: ControlClient?
    let model = Model()
    let demo: Pane?
    var pane: Pane = .overview
    var stack: W?
    var overlay: W?
    var windowTitle: W?
    var pauseButton: W?
    var sidebarRows: [Pane: (row: W?, badge: W?)] = [:]
    var connectedLabel: W?
    var approvalWindows: [String: ApprovalWindow] = [:]
    var setup: SetupFlow?

    init(demo: Pane?) {
        self.demo = demo
        application = raw(adw_application_new("ch.rubencatalao.postern", G_APPLICATION_DEFAULT_FLAGS))
        on(application, "activate") { [unowned self] in self.activate() }
    }

    func run() -> Int32 {
        // GTK reads only the program name: Postern's own options never reach it.
        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup(CommandLine.arguments[0]), nil]
        defer { free(arguments[0]) }
        return g_application_run(cast(application), 1, &arguments)
    }

    func activate() {
        if let window {
            gtk_window_present(cast(window))
            return
        }
        installStyle()
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(), ADW_COLOR_SCHEME_DEFAULT)
        buildWindow()
        if let demo {
            Demo.fill(model)
            pane = demo
            render()
            select(demo)
            return
        }
        connect()
    }

    // MARK: Core

    func connect() {
        do {
            let client = try ControlClient()
            self.client = client
            client.onEvent { [weak self] event, data in
                onMain { self?.handle(event, data) }
            }
            client.onClose { [weak self] in
                onMain {
                    guard let self else { return }
                    self.client = nil
                    toast(self.overlay, "Postern's core stopped. Reconnecting…")
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { onMain { self.connect() } }
                }
            }
            refresh()
        } catch {
            showProblem("Postern's core is not running", "Start it with `systemctl --user start postern.socket`, or reinstall Postern.\n\(error)")
        }
    }

    func handle(_ event: String, _ data: ControlWire.Result?) {
        switch event {
        case "changed":
            refresh()
        case "approval":
            if let approval = data?.approval { showApproval(approval) }
        case "approval.closed":
            if let id = data?.text, let window = approvalWindows.removeValue(forKey: id) { window.close() }
        default:
            break
        }
    }

    /// Reads everything the panes show, then draws them again.
    func refresh() {
        guard let client else { return }
        Task.detached { [model] in
            let status = try? await client.call("status").status
            let tools = (try? await client.call("tools").tools) ?? []
            let apps = (try? await client.call("apps").apps) ?? []
            let activity = (try? await client.call("activity", .init(limit: 300)).activity) ?? []
            let batches = (try? await client.call("batches").batches) ?? []
            let mailboxes = status?.configured == true ? ((try? await client.call("mailboxes").mailboxes) ?? []) : []
            onMain { [weak self] in
                model.status = status
                model.tools = tools
                model.apps = apps
                model.activity = activity
                model.batches = batches
                model.mailboxes = mailboxes
                self?.render()
                if status?.configured == false { self?.showSetup() }
            }
        }
    }

    /// Asks the core, then shows its refusal as a toast. The switch the user moved goes back by the next refresh.
    func ask(_ method: String, _ params: ControlWire.Params? = nil, done: ((ControlWire.Result) -> Void)? = nil) {
        guard let client else {
            toast(overlay, "Postern's core is not running.")
            return
        }
        Task.detached {
            do {
                let result = try await client.call(method, params)
                onMain { done?(result) }
            } catch let failure as ControlWire.Failure {
                onMain { [weak self] in
                    toast(self?.overlay, failure.message)
                    self?.refresh()
                }
            } catch {
                onMain { [weak self] in self?.refresh() }
            }
        }
    }

    func update(_ change: (inout Policy) -> Void) {
        guard var policy = model.status?.policy else { return }
        change(&policy)
        ask("policy.update", .init(policy: policy)) { [weak self] _ in self?.refresh() }
    }

    // MARK: Window

    func buildWindow() {
        let window = raw(adw_application_window_new(cast(application)))
        self.window = window
        gtk_window_set_title(cast(window), "Postern")
        gtk_window_set_default_size(cast(window), 980, 680)
        gtk_widget_set_size_request(cast(window), 720, 520)

        // Sidebar: the panes, with their counts, and the apps connected right now.
        let list = raw(gtk_list_box_new())
        addClass(list, "navigation-sidebar")
        for pane in Pane.allCases {
            let badge = label("", ["count-badge"], wrap: false, xalign: 0.5)
            setVisible(badge, false)
            let title = label(pane.title, [], wrap: false)
            expand(title)
            let content = box(false, spacing: 12, [image(pane.icon, size: 16), title, badge])
            margins(content, 4)
            let row = raw(gtk_list_box_row_new())
            gtk_list_box_row_set_child(cast(row), cast(content))
            gtk_list_box_append(cast(list), cast(row))
            sidebarRows[pane] = (row, badge)
        }
        on(list, "row-selected", argument: { [unowned self] row in
            guard let row else { return }
            let index = Int(gtk_list_box_row_get_index(cast(row)))
            guard Pane.allCases.indices.contains(index) else { return }
            self.pane = Pane.allCases[index]
            self.showPane()
        })
        let connected = label("", ["dim-label", "caption"])
        margins(connected, 18)
        connectedLabel = connected
        let sidebarContent = box(true, spacing: 0, [list, connected])
        expand(list, vertical: true)
        let sidebarToolbar = raw(adw_toolbar_view_new())
        let sidebarHeader = raw(adw_header_bar_new())
        let brand = box(false, spacing: 8, [image("ch.rubencatalao.postern-symbolic", size: 18), label("Postern", ["heading"], wrap: false)])
        adw_header_bar_set_title_widget(opaque(sidebarHeader), cast(brand))
        adw_toolbar_view_add_top_bar(opaque(sidebarToolbar), cast(sidebarHeader))
        adw_toolbar_view_set_content(opaque(sidebarToolbar), cast(sidebarContent))
        addClass(sidebarToolbar, "sidebar-pane")
        let sidebarPage = adw_navigation_page_new(cast(sidebarToolbar), "Postern")

        // Content: a header with the pane's title and the state, the pane, and toasts on top.
        let stack = raw(gtk_stack_new())
        gtk_stack_set_transition_type(cast(stack), GTK_STACK_TRANSITION_TYPE_CROSSFADE)
        self.stack = stack
        let overlay = raw(adw_toast_overlay_new())
        adw_toast_overlay_set_child(opaque(overlay), cast(stack))
        self.overlay = overlay
        let header = raw(adw_header_bar_new())
        let title = raw(adw_window_title_new("Overview", ""))
        windowTitle = title
        adw_header_bar_set_title_widget(opaque(header), cast(title))
        let pause = button("Pause", ["pill"]) { [unowned self] in
            let paused = self.model.status?.policy.paused ?? false
            self.ask("pause", .init(paused: !paused)) { _ in self.refresh() }
        }
        pauseButton = pause
        adw_header_bar_pack_end(opaque(header), cast(pause))
        let contentToolbar = raw(adw_toolbar_view_new())
        adw_toolbar_view_add_top_bar(opaque(contentToolbar), cast(header))
        adw_toolbar_view_set_content(opaque(contentToolbar), cast(overlay))
        let contentPage = adw_navigation_page_new(cast(contentToolbar), "Overview")

        let split = raw(adw_navigation_split_view_new())
        adw_navigation_split_view_set_sidebar(opaque(split), contentPageCast(sidebarPage))
        adw_navigation_split_view_set_content(opaque(split), contentPageCast(contentPage))
        adw_navigation_split_view_set_min_sidebar_width(opaque(split), 230)
        adw_application_window_set_content(cast(window), cast(split))
        gtk_list_box_select_row(cast(list), cast(sidebarRows[.overview]?.row))
        gtk_window_present(cast(window))
    }

    func contentPageCast<T>(_ page: T) -> T { page }

    func showProblem(_ title: String, _ detail: String) {
        let status = raw(adw_status_page_new())
        adw_status_page_set_icon_name(opaque(status), "dialog-warning-symbolic")
        adw_status_page_set_title(opaque(status), title)
        adw_status_page_set_description(opaque(status), detail)
        replacePane(status)
    }

    /// Draws the current pane again, and the header and sidebar around it.
    func render() {
        let status = model.status
        let policy = status?.policy ?? .initial
        let state: String
        if status?.configured != true {
            state = "Not set up"
        } else if policy.paused {
            state = "Paused"
        } else {
            state = "On, \(policy.enabledTools.count) of \(ToolID.switchable.count) tools on"
        }
        adw_window_title_set_subtitle(opaque(windowTitle), state)
        gtk_button_set_label(cast(pauseButton), policy.paused ? "Resume" : "Pause")
        setVisible(pauseButton, status?.configured == true)
        setBadge(.tools, policy.enabledTools.count)
        setBadge(.mailboxes, model.mailboxes.filter { !$0.hidden }.count)
        setBadge(.apps, model.apps.filter { $0.status == "connected" }.count)
        setBadge(.activity, model.activity.filter { Calendar.current.isDateInToday($0.date) }.count)
        let apps = status?.connectedApps ?? []
        setText(connectedLabel, apps.isEmpty ? "No app connected right now" : "Connected now:\n" + Set(apps).sorted().joined(separator: "\n"))
        showPane()
    }

    func setBadge(_ pane: Pane, _ count: Int) {
        guard let badge = sidebarRows[pane]?.badge else { return }
        setText(badge, "\(count)")
        setVisible(badge, count > 0)
    }

    func showPane() {
        adw_window_title_set_title(opaque(windowTitle), pane.title)
        let content: W?
        switch pane {
        case .overview: content = overviewPane()
        case .tools: content = toolsPane()
        case .mailboxes: content = mailboxesPane()
        case .apps: content = appsPane()
        case .activity: content = activityPane()
        case .security: content = securityPane()
        }
        replacePane(content)
    }

    private var current: W?
    private var currentPane: Pane?

    /// Puts the new drawing of a pane in place. When it is the same pane drawn again after a change, it keeps where
    /// the user had scrolled, so turning on a tool at the bottom of the list does not jump back to the top.
    func replacePane(_ content: W?) {
        guard let content else { return }
        let offset = currentPane == pane ? scrollOffset(of: current) : nil
        let name = "pane-\(UUID().uuidString)"
        gtk_stack_add_named(cast(stack), cast(content), name)
        gtk_stack_set_transition_type(cast(stack), offset == nil ? GTK_STACK_TRANSITION_TYPE_CROSSFADE : GTK_STACK_TRANSITION_TYPE_NONE)
        gtk_stack_set_visible_child_name(cast(stack), name)
        if let old = current { gtk_stack_remove(cast(stack), cast(old)) }
        current = content
        currentPane = pane
        if let offset, offset > 0 {
            // Once GTK has measured the new page.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                onMain { [weak self] in
                    guard let self, self.current == content, let adjustment = self.adjustment(in: content) else { return }
                    gtk_adjustment_set_value(adjustment, offset)
                }
            }
        }
    }

    private func scrollOffset(of page: W?) -> Double? {
        adjustment(in: page).map { gtk_adjustment_get_value($0) }
    }

    /// The vertical adjustment of the first scrolled window inside a pane.
    private func adjustment(in widget: W?) -> UnsafeMutablePointer<GtkAdjustment>? {
        guard let widget else { return nil }
        if g_type_check_instance_is_a(cast(widget), gtk_scrolled_window_get_type()) != 0 {
            return gtk_scrolled_window_get_vadjustment(cast(widget))
        }
        var child = raw(gtk_widget_get_first_child(cast(widget)))
        while let current = child {
            if let found = adjustment(in: current) { return found }
            child = raw(gtk_widget_get_next_sibling(cast(current)))
        }
        return nil
    }

    // MARK: Setup and approvals

    func showSetup() {
        guard setup == nil, demo == nil, let client else { return }
        setup = SetupFlow(parent: window, client: client) { [weak self] in
            self?.setup = nil
            self?.refresh()
        }
    }

    func showApproval(_ approval: ControlWire.Approval) {
        guard approvalWindows[approval.id] == nil else { return }
        approvalWindows[approval.id] = ApprovalWindow(approval: approval, application: application) { [weak self] decision, reason, chosen in
            guard let self else { return }
            self.approvalWindows.removeValue(forKey: approval.id)
            self.ask("approval.decide", .init(id: approval.id, decision: decision, reason: reason, chosen: chosen))
        }
    }
}

#endif
