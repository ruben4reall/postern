#if os(Linux)
import CGtk
import Foundation
import PosternModel
import PosternPlatform
import PosternPolicy

/// The first steps, one per screen: find Bridge, trust its certificate, sign in, let apps read, connect an app.
final class SetupFlow {
    let window: W?
    let client: ControlClient
    let finished: () -> Void
    private let stack: W?
    private let overlay: W?
    private var detection: ControlWire.Detection?
    private var done = false

    init(parent: W?, client: ControlClient, finished: @escaping () -> Void) {
        self.client = client
        self.finished = finished
        let window = raw(adw_window_new())
        self.window = window
        gtk_window_set_title(cast(window), "Set up Postern")
        gtk_window_set_modal(cast(window), 1)
        gtk_window_set_transient_for(cast(window), cast(parent))
        gtk_window_set_default_size(cast(window), 560, 560)
        stack = raw(gtk_stack_new())
        gtk_stack_set_transition_type(cast(stack), GTK_STACK_TRANSITION_TYPE_SLIDE_LEFT)
        overlay = raw(adw_toast_overlay_new())
        adw_toast_overlay_set_child(opaque(overlay), cast(stack))
        let toolbar = raw(adw_toolbar_view_new())
        adw_toolbar_view_add_top_bar(opaque(toolbar), cast(raw(adw_header_bar_new())))
        adw_toolbar_view_set_content(opaque(toolbar), cast(overlay))
        adw_window_set_content(opaque(window), cast(toolbar))
        onClose(window) { [weak self] in self?.finish() }
        showDetect()
        gtk_window_present(cast(window))
    }

    func finish() {
        guard !done else { return }
        done = true
        finished()
    }

    func step(_ icon: String, _ title: String, _ text: String, _ rows: [W?], _ action: W?, secondary: W? = nil) {
        let status = raw(adw_status_page_new())
        adw_status_page_set_icon_name(opaque(status), icon)
        adw_status_page_set_title(opaque(status), title)
        adw_status_page_set_description(opaque(status), text)
        let list = raw(gtk_list_box_new())
        addClass(list, "boxed-list")
        gtk_list_box_set_selection_mode(cast(list), GTK_SELECTION_NONE)
        for row in rows { gtk_list_box_append(cast(list), cast(row)) }
        let spacer = box(false, spacing: 0)
        expand(spacer)
        let buttons = box(false, spacing: 10, [secondary, spacer, action])
        let column = box(true, spacing: 18, (rows.isEmpty ? [] : [list]) + [buttons])
        gtk_widget_set_size_request(cast(column), 420, -1)
        gtk_widget_set_halign(cast(column), GTK_ALIGN_CENTER)
        adw_status_page_set_child(opaque(status), cast(column))
        let name = UUID().uuidString
        gtk_stack_add_named(cast(stack), cast(status), name)
        gtk_stack_set_visible_child_name(cast(stack), name)
    }

    func call(_ method: String, _ params: ControlWire.Params?, then: @escaping (ControlWire.Result) -> Void) {
        let client = self.client
        Task.detached {
            do {
                let result = try await client.call(method, params)
                onMain { then(result) }
            } catch let failure as ControlWire.Failure {
                onMain { [weak self] in toast(self?.overlay, failure.message) }
            } catch {
                onMain { [weak self] in toast(self?.overlay, "\(error)") }
            }
        }
    }

    func showDetect() {
        let imap = spinRow("IMAP port", subtitle: "Bridge › Settings › IMAP", value: 1143, range: 1...65535)
        let smtp = spinRow("SMTP port", subtitle: "Bridge › Settings › SMTP", value: 1025, range: 1...65535)
        let find = button("Find Bridge", ["pill", "suggested-action"]) { [unowned self] in
            self.call("setup.detect", .init(imapPort: Int(spinValue(imap)), smtpPort: Int(spinValue(smtp)))) { result in
                self.detection = result.detection
                self.showTrust()
            }
        }
        step("ch.rubencatalao.postern", "Welcome to Postern",
             "Postern lets your AI apps use your Proton Mail through Proton Mail Bridge, within the limits you set. Open Bridge and sign in to your account first.",
             [imap, smtp], find)
    }

    func showTrust() {
        guard let detection else { return showDetect() }
        let version = actionRow("Proton Mail Bridge \(detection.bridgeVersion ?? "")", subtitle: "On 127.0.0.1, IMAP \(detection.imapPort) (\(detection.imapMode)), SMTP \(detection.smtpPort) (\(detection.smtpMode))")
        let print = actionRow("Certificate", subtitle: detection.fingerprint, lines: 3)
        let trust = button("Trust this certificate", ["pill", "suggested-action"]) { [unowned self] in self.showSignIn() }
        let back = button("Back", ["pill"]) { [unowned self] in self.showDetect() }
        step("channel-secure-symbolic", "Is this your Bridge?",
             "Postern talks to Bridge over an encrypted connection and remembers its certificate, so no other program can pretend to be Bridge. Bridge shows its certificate under Settings › Advanced.",
             [version, print], trust, secondary: back)
    }

    func showSignIn() {
        let username = entryRow("Bridge username")
        let password = entryRow("Bridge password", password: true)
        let connect = button("Connect", ["pill", "suggested-action"]) { [unowned self] in
            guard let detection = self.detection else { return }
            self.call("setup.connect", .init(imapPort: detection.imapPort, smtpPort: detection.smtpPort, username: text(of: username),
                                             password: text(of: password), fingerprint: detection.fingerprint)) { _ in
                gtk_editable_set_text(opaque(password), "")
                self.showAllow()
            }
        }
        step("dialog-password-symbolic", "Sign in to Bridge",
             "Use the username and password that Bridge shows for your account (Bridge › your account › Mailbox details), not your Proton password. Postern keeps them in your desktop's keyring.",
             [username, password], connect)
    }

    func showAllow() {
        let allow = button("Let apps read my mail", ["pill", "suggested-action"]) { [unowned self] in
            self.call("status", nil) { result in
                guard var policy = result.status?.policy else { return }
                policy.enabledTools.formUnion(ToolPreset.read.tools)
                self.call("policy.update", .init(policy: policy)) { _ in self.showApps() }
            }
        }
        let later = button("Later", ["pill"]) { [unowned self] in self.showApps() }
        step("mail-read-symbolic", "Let apps read your mail?",
             "Apps will be able to list your mailboxes, search and read messages, cleaned of hidden text first. Nothing else until you turn more tools on. The system asks for your password or fingerprint.",
             [], allow, secondary: later)
    }

    func showApps() {
        call("apps", nil) { [unowned self] result in
            var rows: [W?] = []
            for app in (result.apps ?? []).filter(\.installed) {
                let row = actionRow(app.title, subtitle: app.status == "connected" ? "Connected" : nil)
                if app.status != "connected" {
                    suffix(row, button("Connect", ["flat"]) { [unowned self] in
                        self.call("apps.connect", .init(app: app.id)) { _ in toast(self.overlay, "\(app.title) is connected. Restart it.") }
                    })
                }
                rows.append(row)
            }
            let close = button("Done", ["pill", "suggested-action"]) { [unowned self] in
                gtk_window_destroy(cast(self.window))
                self.finish()
            }
            self.step("network-workgroup-symbolic", "Connect your AI apps",
                      rows.isEmpty ? "No app was found on this computer. Any MCP app can use Postern: its Apps pane shows the entry to copy." : "Postern adds itself to their settings. Restart each app afterwards.",
                      rows, close)
        }
    }
}
#endif
