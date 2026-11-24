#if os(Linux)
import CGtk
import Foundation
import PosternModel
import PosternPlatform
import PosternPolicy

/// The six panes, drawn from the model each time it changes.
extension PosternApp {
    static let tiers: [(id: String, title: String, summary: String, icon: String, style: String)] = [
        ("read", "Reading", "List, search and read. Every message is cleaned of hidden text first.", "mail-read-symbolic", ""),
        ("organize", "Organizing", "Read and unread, stars, folders, labels. Never to Trash.", "folder-symbolic", ""),
        ("draft", "Drafts", "Write and change drafts. Nothing is sent.", "document-edit-symbolic", ""),
        ("send", "Sending", "Each email waits for you in a window, and leaves only with your password or fingerprint.", "mail-send-symbolic", "send"),
        ("delete", "Deleting", "Each deletion lists every message and asks for your password or fingerprint.", "user-trash-symbolic", "delete"),
    ]

    // MARK: Overview

    func overviewPane() -> W? {
        let content = page()
        let status = model.status
        let policy = status?.policy ?? .initial

        // The state, in one sentence, with the mark.
        let hero = group()
        let mark = image("ch.rubencatalao.postern", size: 56, ["hero-mark"])
        let configured = status?.configured == true
        let headline: String
        let detail: String
        if !configured {
            headline = "Postern is not set up yet"
            detail = "Connect it to Proton Mail Bridge, then choose what your AI apps may do."
        } else if policy.paused {
            headline = "Postern is paused"
            detail = "Apps see no tool until you resume."
        } else {
            headline = "Postern watches over your mailbox"
            detail = "Apps can only use the tools you turned on. Nothing is sent or deleted without your approval."
        }
        let words = box(true, spacing: 4, [label(headline, ["title-2"]), label(detail, ["dim-label"])])
        expand(words)
        let heroBox = box(false, spacing: 18, [mark, words])
        addClass(heroBox, "hero")
        addRow(hero, heroBox)
        addGroup(content, hero)

        if let problem = status?.problem, configured {
            let warning = group()
            addRow(warning, actionRow("Postern cannot serve apps right now", subtitle: problem, icon: "dialog-warning-symbolic", lines: 4))
            addGroup(content, warning)
        }

        // One click for a sensible set of tools.
        let presets = group("Quick start", description: "A set of tools in one step. Turning tools on asks for your password or fingerprint.")
        let read = Policy.readOnly.enabledTools.union([.getMessages, .topSenders, .awaitingReply, .readAttachment, .listAddresses])
        let organize = Set(ToolID.switchable.filter { $0.tier == .organize })
        let drafts: Set<ToolID> = [.createDraft, .updateDraft, .draftReply, .draftForward]
        let send: Set<ToolID> = [.sendMessage, .replyToMessage, .forwardMessage, .sendDraft]
        let choices: [(String, String, Set<ToolID>)] = [
            ("Read only", "Search, read and summarize. Nothing changes in your mailbox.", read),
            ("Assistant", "Also sort, file and write drafts for you to send.", read.union(organize).union(drafts)),
            ("Full", "Also send, each email after your approval.", read.union(organize).union(drafts).union(send)),
        ]
        for (title, summary, tools) in choices {
            let row = actionRow(title, subtitle: summary)
            let current = policy.enabledTools == tools
            suffix(row, current ? pill("Current", "success") : button("Use", ["flat"]) { [unowned self] in
                self.update { $0.enabledTools = tools }
            })
            addRow(presets, row)
        }
        addGroup(content, presets)

        // What each tier allows.
        let tiers = group("What apps can do")
        for tier in Self.tiers {
            let total = model.tools.filter { $0.tier == tier.id }.count
            let on = model.tools.filter { $0.tier == tier.id && $0.enabled }.count
            let row = actionRow(tier.title, subtitle: tier.summary, lines: 2)
            prefix(row, image(tier.icon, size: 18, ["tier-icon"] + (tier.style.isEmpty ? [] : [tier.style])))
            let gauge = raw(gtk_level_bar_new_for_interval(0, Double(max(total, 1))))
            gtk_level_bar_set_value(cast(gauge), Double(on))
            gtk_widget_set_size_request(cast(gauge), 90, -1)
            gtk_widget_set_valign(cast(gauge), GTK_ALIGN_CENTER)
            addClass(gauge, "gauge")
            suffix(row, gauge)
            suffix(row, label(on == 0 ? "Off" : "\(on) of \(total)", ["dim-label"], wrap: false))
            gtk_list_box_row_set_activatable(cast(row), 1)
            on(row, "activated") { [unowned self] in self.select(.tools) }
            addRow(tiers, row)
        }
        addGroup(content, tiers)

        // Right now.
        let now = group("Right now")
        let apps = Set(status?.connectedApps ?? []).sorted()
        addRow(now, actionRow("Apps connected", subtitle: apps.isEmpty ? "None at the moment" : apps.joined(separator: ", ")))
        addRow(now, actionRow("Sent through Postern", subtitle: "\(status?.sendsLastHour ?? 0) in the last hour of \(policy.sendsPerHour) allowed, \(status?.sendsLastDay ?? 0) in the last day of \(policy.sendsPerDay)"))
        let running = model.batches.filter { $0.phase == "running" || $0.phase == "waiting" }
        if !running.isEmpty {
            for batch in running {
                let row = actionRow("Batch from \(batch.client): \(batch.done) of \(batch.total) \(batch.kind == "sends" ? "sent" : "saved")",
                                    subtitle: batch.reason ?? "Running", lines: 3)
                suffix(row, button("Stop", ["destructive-action"]) { [unowned self] in
                    self.ask("batches.cancel", .init(id: batch.id)) { _ in self.refresh() }
                })
                if batch.interrupted {
                    suffix(row, button("Resume", ["suggested-action"]) { [unowned self] in
                        self.ask("batches.resume", .init(id: batch.id)) { _ in self.refresh() }
                    })
                }
                addRow(now, row)
            }
        }
        if let hit = status?.protonLimits.last {
            addRow(now, actionRow("Proton's own limit", subtitle: "Proton stopped sending on \(hit.date.formatted(date: .abbreviated, time: .shortened)), after \(hit.sentInLastDay) emails in 24 hours.", lines: 2))
        }
        addGroup(content, now)
        addGroup(content, footer())
        return content
    }

    func select(_ target: Pane) {
        gtk_list_box_select_row(cast(gtk_widget_get_parent(cast(sidebarRows[target]?.row))), cast(sidebarRows[target]?.row))
    }

    func footer() -> W? {
        let note = group()
        let text = label("Postern \(CoreService.version). An independent open-source project, not affiliated with Proton AG.", ["dim-label", "caption"], xalign: 0.5)
        addRow(note, text)
        return note
    }

    // MARK: Tools

    func toolsPane() -> W? {
        let content = page()
        let intro = group(nil, description: "Each tool is one thing an app can do with your mail. Turning one on asks for your password or fingerprint; turning it off is immediate, and connected apps see the change at once.")
        addGroup(content, intro)
        for tier in Self.tiers {
            let tools = model.tools.filter { $0.tier == tier.id }
            guard !tools.isEmpty else { continue }
            let on = tools.filter(\.enabled).count
            let section = group(tier.title, description: "\(on) of \(tools.count) on. \(tier.summary)")
            let allOff = button("Turn all off", ["flat"]) { [unowned self] in
                self.update { policy in for tool in tools { if let id = ToolID(rawValue: tool.id) { policy.enabledTools.remove(id) } } }
            }
            setVisible(allOff, on > 0)
            groupSuffix(section, allOff)
            for tool in tools {
                let row = switchRow(tool.title, subtitle: "\(tool.summary)\n⚠ \(tool.risk)", active: tool.enabled) { [unowned self] active in
                    guard let id = ToolID(rawValue: tool.id), active != tool.enabled else { return }
                    self.update { policy in
                        if active { policy.enabledTools.insert(id) } else { policy.enabledTools.remove(id) }
                    }
                }
                adw_action_row_set_subtitle_lines(cast(row), 3)
                addRow(section, row)
            }
            addGroup(content, section)
        }
        return content
    }

    // MARK: Mailboxes

    func mailboxesPane() -> W? {
        let content = page()
        let intro = group("Mailboxes apps can see", description: "A hidden mailbox does not exist for apps: they cannot list, search or read it. Hiding any mailbox also hides All Mail and Starred, which show messages of every mailbox.")
        addGroup(content, intro)
        guard model.status?.configured == true else {
            addRow(intro, actionRow("Set up Postern first", subtitle: "Postern reads the list of mailboxes from Bridge."))
            return content
        }
        let kinds: [(String, String)] = [("system", "Proton"), ("folder", "Folders"), ("label", "Labels"), ("virtual", "Views")]
        for (kind, title) in kinds {
            let rows = model.mailboxes.filter { $0.kind == kind }
            guard !rows.isEmpty else { continue }
            let section = group(title)
            for mailbox in rows {
                let row = switchRow(mailbox.name, subtitle: nil, active: !mailbox.hidden) { [unowned self] visible in
                    guard visible == mailbox.hidden else { return }
                    self.update { policy in
                        if visible { policy.hiddenMailboxes.remove(mailbox.name) } else { policy.hiddenMailboxes.insert(mailbox.name) }
                    }
                }
                addRow(section, row)
            }
            addGroup(content, section)
        }
        return content
    }

    // MARK: Apps

    func appsPane() -> W? {
        let content = page()
        let connected = Set(model.status?.connectedApps ?? [])
        let live = group("Connected right now")
        if connected.isEmpty {
            addRow(live, actionRow("No app is connected", subtitle: "An app connects when it starts, once Postern is in its settings."))
        }
        for app in connected.sorted() {
            let count = (model.status?.connectedApps ?? []).filter { $0 == app }.count
            let row = actionRow(app, subtitle: count == 1 ? "1 session" : "\(count) sessions")
            prefix(row, image("emblem-ok-symbolic", size: 16))
            addRow(live, row)
        }
        addGroup(content, live)

        let apps = group("Your apps", description: "Connecting writes Postern's entry in the app's settings file: the path of postern-mcp, never a password. Restart the app afterwards. Tools stay off until you turn them on.")
        for app in model.apps {
            let row = actionRow(app.title, subtitle: app.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
            switch app.status {
            case "connected":
                suffix(row, pill("Connected", "success"))
            default:
                suffix(row, button(app.status == "connectedElsewhere" ? "Update" : "Connect", app.installed ? ["suggested-action"] : ["flat"]) { [unowned self] in
                    self.ask("apps.connect", .init(app: app.id)) { _ in
                        toast(self.overlay, "\(app.title) is connected. Restart it so it loads Postern.")
                        self.refresh()
                    }
                })
            }
            if !app.installed { suffix(row, label("Not found", ["dim-label", "caption"], wrap: false)) }
            addRow(apps, row)
        }
        addGroup(content, apps)

        let other = group("Any other app", description: "Most MCP apps take this entry in their mcpServers settings.")
        let relay = PosternPaths.program("postern-mcp")?.path ?? "/usr/bin/postern-mcp"
        let snippet = "{\n  \"mcpServers\": {\n    \"proton-mail-postern\": {\n      \"command\": \"\(relay)\",\n      \"args\": []\n    }\n  }\n}"
        let view = textView(snippet, monospace: true)
        addClass(view, "email-card")
        addRow(other, view)
        let copy = button("Copy", ["flat"]) { [unowned self] in
            copyToClipboard(self.window, snippet)
            toast(self.overlay, "Copied.")
        }
        groupSuffix(other, copy)
        addGroup(content, other)
        return content
    }

    // MARK: Activity

    func activityPane() -> W? {
        let content = page()
        let intro = group(nil, description: "What apps asked of Postern: the tool, the outcome and how many items, never the content of your mail. Kept 90 days, each line chained to the one before so an edit shows.")
        addGroup(content, intro)
        if model.activity.isEmpty {
            addRow(intro, actionRow("Nothing yet", subtitle: "Calls appear here as apps use Postern."))
            return content
        }
        let calendar = Calendar.current
        let days = Dictionary(grouping: model.activity) { calendar.startOfDay(for: $0.date) }
        for day in days.keys.sorted(by: >).prefix(14) {
            let title = calendar.isDateInToday(day) ? "Today" : calendar.isDateInYesterday(day) ? "Yesterday" : day.formatted(date: .complete, time: .omitted)
            let section = group(title)
            for entry in (days[day] ?? []).sorted(by: { $0.date > $1.date }).prefix(60) {
                let refused = entry.outcome != "ok"
                let what = entry.items.map { "\(entry.tool), \($0) item(s)" } ?? entry.tool
                let row = actionRow("\(entry.client): \(what)", subtitle: "\(entry.date.formatted(date: .omitted, time: .shortened))\(refused ? ", " + entry.outcome.replacingOccurrences(of: "_", with: " ") : "")")
                prefix(row, image(refused ? "action-unavailable-symbolic" : "emblem-ok-symbolic", size: 16))
                addRow(section, row)
            }
            addGroup(content, section)
        }
        return content
    }

    // MARK: Security

    func securityPane() -> W? {
        let content = page()
        let status = model.status
        let policy = status?.policy ?? .initial

        let approvals = group("Approvals")
        if status?.approvalsReady == true {
            addRow(approvals, actionRow("Every email and deletion asks you", subtitle: "Postern shows it in a window; after you choose Send or Delete, the system asks for your password, or your fingerprint where it is set up (polkit).", icon: "channel-secure-symbolic", lines: 3))
        } else {
            addRow(approvals, actionRow("Approvals are not available", subtitle: "polkit's actions for Postern are missing, so nothing can be sent or deleted. Install Postern from its .deb or .rpm package.", icon: "dialog-warning-symbolic", lines: 3))
        }
        addGroup(content, approvals)

        let limits = group("Sending limits", description: "Postern stops before these, whatever apps ask. Raising them asks for your password or fingerprint; lowering never does.")
        let hour = spinRow("Emails per hour", subtitle: "Up to \(Policy.maxSendsPerHour)", value: Double(policy.sendsPerHour), range: 1...Double(Policy.maxSendsPerHour))
        let day = spinRow("Emails per day", subtitle: "Up to \(Policy.maxSendsPerDay)", value: Double(policy.sendsPerDay), range: 1...Double(Policy.maxSendsPerDay), step: 10)
        addRow(limits, hour)
        addRow(limits, day)
        let save = button("Save limits", ["suggested-action"]) { [unowned self] in
            let perHour = Int(spinValue(hour))
            let perDay = Int(spinValue(day))
            self.update { policy in
                policy.sendsPerHour = perHour
                policy.sendsPerDay = perDay
            }
        }
        let maximum = button("Set to maximum", ["flat"]) { [unowned self] in
            self.update { policy in
                policy.sendsPerHour = Policy.maxSendsPerHour
                policy.sendsPerDay = Policy.maxSendsPerDay
            }
        }
        groupSuffix(limits, box(false, spacing: 6, [maximum, save]))
        addGroup(content, limits)

        let proton = group("Proton's limits", description: "Proton sets its own limits besides Postern's. Free accounts: 50 an hour and 150 a day. Paid plans have no fixed number: it follows the account's reputation. 100 recipients per email at most, each counting as one.")
        if let hits = status?.protonLimits, !hits.isEmpty {
            for hit in hits.reversed() {
                addRow(proton, actionRow("Proton said stop on \(hit.date.formatted(date: .abbreviated, time: .shortened))", subtitle: "After \(hit.sentInLastDay) emails in 24 hours through Postern."))
            }
        } else {
            addRow(proton, actionRow("Proton has not stopped Postern yet", subtitle: "If it does, the time and the number of emails sent show here: your account's real limit."))
        }
        addGroup(content, proton)

        addGroup(content, addressGroup(
            "Trusted recipients", "Emails whose every recipient is here skip the approval window. Adding one asks for your password or fingerprint.",
            policy.trustedRecipients) { policy, add, address in
                if add { policy.trustedRecipients.insert(address) } else { policy.trustedRecipients.remove(address) }
            })
        addGroup(content, addressGroup(
            "Allowed recipients", "When this list is not empty, nobody else can receive mail through Postern.",
            policy.allowedRecipients) { policy, add, address in
                if add { policy.allowedRecipients.insert(address) } else { policy.allowedRecipients.remove(address) }
            })
        addGroup(content, addressGroup(
            "Send from", "Aliases of your Proton account apps may send from, besides \(status?.account ?? "the account's address").",
            policy.senderAddresses) { policy, add, address in
                if add { policy.senderAddresses.insert(address) } else { policy.senderAddresses.remove(address) }
            })

        let account = group("Bridge")
        if status?.configured == true {
            addRow(account, actionRow(status?.account ?? "Connected", subtitle: "Proton Mail Bridge on 127.0.0.1, IMAP \(status?.imapPort ?? 0), SMTP \(status?.smtpPort ?? 0). The password stays in your desktop's keyring."))
            let forget = actionRow("Forget this setup", subtitle: "Removes the Bridge password and certificate from the keyring. Your tools and limits stay.")
            suffix(forget, button("Forget", ["destructive-action"]) { [unowned self] in
                self.ask("setup.forget") { _ in self.refresh() }
            })
            addRow(account, forget)
        } else {
            let row = actionRow("Not set up", subtitle: "Connect Postern to Proton Mail Bridge.")
            suffix(row, button("Set up", ["suggested-action"]) { [unowned self] in self.showSetup() })
            addRow(account, row)
        }
        addGroup(content, account)
        addGroup(content, footer())
        return content
    }

    func addressGroup(_ title: String, _ description: String, _ addresses: Set<String>,
                      change: @escaping (inout Policy, Bool, String) -> Void) -> W? {
        let section = group(title, description: description)
        for address in addresses.sorted() {
            let row = actionRow(address)
            suffix(row, iconButton("list-remove-symbolic", tooltip: "Remove") { [unowned self] in
                self.update { change(&$0, false, address) }
            })
            addRow(section, row)
        }
        let entry = entryRow("Add an address")
        adw_entry_row_set_show_apply_button(opaque(entry), 1)
        on(entry, "apply") { [unowned self] in
            let address = text(of: entry).trimmingCharacters(in: .whitespaces).lowercased()
            guard address.contains("@") else {
                toast(self.overlay, "Enter an email address.")
                return
            }
            self.update { change(&$0, true, address) }
        }
        addRow(section, entry)
        return section
    }
}
#endif
