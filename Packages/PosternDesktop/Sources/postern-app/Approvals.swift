#if os(Linux)
import CGtk
import Foundation
import PosternPlatform

/// One approval in its own window: everything that would leave or be deleted, in full, and three choices. The
/// window decides nothing: after Send or Delete, the core asks polkit, which asks for the user's password or
/// fingerprint in the desktop's own dialog.
final class ApprovalWindow {
    let window: W?
    private var closed = false
    private var countdown: W?
    private var ticker: UInt32 = 0

    init(approval: ControlWire.Approval, application: W?, decide: @escaping (ControlWire.Decision, String?, [String]?) -> Void) {
        let window = raw(adw_window_new())
        self.window = window
        gtk_window_set_application(cast(window), cast(application))
        gtk_window_set_default_size(cast(window), 640, 760)
        gtk_window_set_title(cast(window), approval.kind == .deletion ? "Approve the deletion" : "Approve the email")

        let content = box(true, spacing: 14)
        margins(content, 22)
        let what: String
        switch approval.kind {
        case .email: what = "wants to send this email"
        case .batch: what = "wants to send \(approval.batch?.count ?? 0) emails"
        case .deletion: what = approval.permanent ? "wants to erase \(approval.deletion?.count ?? 0) message(s) for good" : "wants to move \(approval.deletion?.count ?? 0) message(s) to Trash"
        }
        let icon = approval.kind == .deletion ? "user-trash-symbolic" : "mail-send-symbolic"
        let headline = label("\(approval.client) \(what)", ["title-2"])
        let countdown = label("", ["dim-label", "caption"], wrap: false)
        self.countdown = countdown
        let titles = box(true, spacing: 4, [headline, approval.context.map { label($0, ["dim-label"]) } ?? nil])
        expand(titles)
        append(content, box(false, spacing: 14, [image(icon, size: 32, ["tier-icon"] + (approval.kind == .deletion ? ["delete"] : ["send"])), titles, countdown]))

        var chosen = Set((approval.batch ?? []).map(\.id))
        let reason = entryRow("Why, for the app (optional)")
        switch approval.kind {
        case .email:
            if let email = approval.email { Self.warnings(email).forEach { append(content, $0) } }
            if let email = approval.email { append(content, Self.card(email)) }
        case .batch:
            let list = box(true, spacing: 12)
            for email in approval.batch ?? [] {
                let check = raw(gtk_check_button_new())
                gtk_check_button_set_active(cast(check), 1)
                on(check, "toggled") {
                    if gtk_check_button_get_active(cast(check)) != 0 { chosen.insert(email.id) } else { chosen.remove(email.id) }
                }
                let card = Self.card(email, compact: true)
                expand(card)
                append(list, box(false, spacing: 10, [check, card]))
            }
            append(content, scrolled(list, minHeight: 360))
        case .deletion:
            let rows = raw(gtk_list_box_new())
            addClass(rows, "boxed-list")
            gtk_list_box_set_selection_mode(cast(rows), GTK_SELECTION_NONE)
            for item in approval.deletion ?? [] {
                let row = actionRow(item.subject, subtitle: "\(item.from) · \(item.mailbox)\(item.date.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")")
                gtk_list_box_append(cast(rows), cast(row))
            }
            append(content, scrolled(rows, minHeight: 300))
            if approval.permanent {
                let warning = label("Erased messages cannot be recovered.", [])
                let notice = box(false, spacing: 8, [image("dialog-warning-symbolic"), warning])
                addClass(notice, "warning-box")
                append(content, notice)
            }
        }
        let reasonGroup = raw(gtk_list_box_new())
        addClass(reasonGroup, "boxed-list")
        gtk_list_box_set_selection_mode(cast(reasonGroup), GTK_SELECTION_NONE)
        gtk_list_box_append(cast(reasonGroup), cast(reason))
        if approval.kind != .deletion { append(content, reasonGroup) }

        var finish: ((ControlWire.Decision) -> Void)!
        let reject = button(approval.kind == .deletion ? "Keep them" : "Refuse", ["pill"]) { finish(.reject) }
        let keep = button("Keep as draft", ["pill"]) { finish(.draft) }
        let sendTitle: String
        switch approval.kind {
        case .email: sendTitle = "Send…"
        case .batch: sendTitle = "Send the ticked emails…"
        case .deletion: sendTitle = approval.permanent ? "Erase for good…" : "Move to Trash…"
        }
        let send = button(sendTitle, ["pill", approval.kind == .deletion ? "destructive-action" : "suggested-action"]) { finish(.send) }
        let spacer = box(false, spacing: 0)
        expand(spacer)
        let actions = box(false, spacing: 10, [spacer, reject] + (approval.kind == .email ? [keep] : []) + [send])
        append(content, actions)
        append(content, label("After you choose, the system asks for your password or fingerprint. Postern never takes a window's word for it.", ["dim-label", "caption"]))

        let toolbar = raw(adw_toolbar_view_new())
        adw_toolbar_view_add_top_bar(opaque(toolbar), cast(raw(adw_header_bar_new())))
        adw_toolbar_view_set_content(opaque(toolbar), cast(scrolled(content)))
        adw_window_set_content(opaque(window), cast(toolbar))

        finish = { [weak self] decision in
            guard let self, !self.closed else { return }
            let why = text(of: reason).trimmingCharacters(in: .whitespacesAndNewlines)
            decide(decision, why.isEmpty ? nil : why, approval.kind == .batch ? Array(chosen) : nil)
            self.close()
        }
        // Closing the window is a refusal.
        onClose(window) { [weak self] in
            guard let self, !self.closed else { return }
            self.closed = true
            decide(.reject, nil, nil)
        }
        tick(approval.deadline)
        ticker = every(1) { [weak self] in self?.tick(approval.deadline) }
        gtk_window_present(cast(window))
    }

    private func tick(_ deadline: Date) {
        let left = max(0, Int(deadline.timeIntervalSinceNow))
        setText(countdown, String(format: "%d:%02d", left / 60, left % 60))
    }

    func close() {
        guard !closed else { return }
        closed = true
        if ticker != 0 { g_source_remove(ticker) }
        gtk_window_destroy(cast(window))
    }

    /// Red when an address came from an email the app read, orange for a first contact or a different Reply-To.
    static func warnings(_ email: ControlWire.Email) -> [W?] {
        var boxes: [W?] = []
        for (address, badges) in email.badges.sorted(by: { $0.key < $1.key }) where badges.contains("cameFromEmail") {
            let notice = box(false, spacing: 8, [image("dialog-warning-symbolic"), label("\(address) appeared in an email the app read. Make sure you really mean to write to this address.")])
            addClass(notice, "warning-box")
            boxes.append(notice)
        }
        if let missing = email.missingAttachment {
            let notice = box(false, spacing: 8, [image("mail-attachment-symbolic"), label("The text says \"\(missing)\" but no file is attached.")])
            addClass(notice, "notice-box")
            boxes.append(notice)
        }
        return boxes
    }

    static func badgeTitle(_ badge: String) -> (String, String) {
        switch badge {
        case "cameFromEmail": ("FOUND IN AN EMAIL", "danger")
        case "firstContact": ("FIRST CONTACT", "warning")
        case "replyToDiffers": ("DIFFERENT REPLY-TO", "warning")
        case "trusted": ("TRUSTED", "success")
        default: (badge.uppercased(), "neutral")
        }
    }

    /// The email as it would leave: header fields, badges, the text, the quote, the files.
    static func card(_ email: ControlWire.Email, compact: Bool = false) -> W? {
        let head = box(true, spacing: 6)
        addClass(head, "email-head")
        func field(_ name: String, _ values: [String], bold: Bool = false) {
            guard !values.isEmpty else { return }
            for (index, value) in values.enumerated() {
                let address = value.components(separatedBy: "<").last?.trimmingCharacters(in: CharacterSet(charactersIn: "> ")).lowercased() ?? value
                var pills: [W?] = []
                for badge in email.badges[address] ?? [] {
                    let (title, style) = badgeTitle(badge)
                    pills.append(pill(title, style))
                }
                let name = label(index == 0 ? name : "", ["dim-label"], wrap: false, xalign: 1)
                gtk_widget_set_size_request(cast(name), 64, -1)
                let valueLabel = label(value, bold ? ["heading"] : [], selectable: true)
                expand(valueLabel)
                append(head, box(false, spacing: 10, [name, valueLabel] + pills))
            }
        }
        field("From", [email.from])
        field("To", email.to)
        field("Cc", email.cc)
        field("Bcc", email.bcc)
        field("Subject", [email.subject], bold: true)

        let body = box(true, spacing: 8)
        let text = textView(email.body + (email.quoted.map { "\n\nSent too, under your text:\n" + $0 } ?? ""))
        append(body, compact ? scrolled(text, minHeight: 120, maxHeight: 220) : scrolled(text, minHeight: 260))
        for file in email.attachments {
            let size = ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
            append(body, box(false, spacing: 8, [image("mail-attachment-symbolic"), label("\(file.name) · \(file.type) · \(size)", [], wrap: false)]))
        }
        margins(body, 6)
        let card = box(true, spacing: 0, [head, body])
        addClass(card, "email-card")
        return card
    }
}
#endif
