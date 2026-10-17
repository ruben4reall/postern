import PosternAudit
import PosternBridge
import PosternClients
import PosternModel
import PosternPolicy
import SwiftUI

/// The main window, laid out like System Settings: a sidebar of panes and grouped forms.
struct ControlView: View {
    @Bindable var model: ControlModel

    var body: some View {
        NavigationSplitView {
            List(ControlModel.Pane.allCases, selection: $model.pane) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            VStack(spacing: 0) {
                if let notice = model.notice {
                    NoticeBar(text: notice) { model.notice = nil }
                }
                detail
            }
            .navigationTitle(model.pane.title)
        }
        .frame(minWidth: 780, minHeight: 540)
    }

    @ViewBuilder private var detail: some View {
        switch model.pane {
        case .overview: OverviewPane(model: model)
        case .tools: ToolsPane(model: model)
        case .mailboxes: MailboxesPane(model: model)
        case .clients: ClientsPane(model: model)
        case .activity: ActivityPane(model: model)
        case .security: SecurityPane(model: model)
        }
    }
}

private struct NoticeBar: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "info.circle").foregroundStyle(.tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss", action: dismiss).buttonStyle(.borderless)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.tint.opacity(0.08))
    }
}

// MARK: Overview

private struct OverviewPane: View {
    @Bindable var model: ControlModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: model.policy.paused ? "pause.circle.fill" : "checkmark.shield.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(model.policy.paused ? Color.orange : Color.green)
                        .symbolRenderingMode(.hierarchical)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(headline).font(.title3.weight(.semibold))
                        Text(summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(model.policy.paused ? "Resume" : "Pause") {
                        Task { await model.setPaused(!model.policy.paused) }
                    }
                    .controlSize(.large)
                    .disabled(!model.configured)
                }
                .padding(.vertical, 6)
            }
            Section("Right now") {
                LabeledContent("Apps connected", value: model.connectedApps.isEmpty ? "None" : appsText)
                LabeledContent("Tools turned on", value: "\(model.policy.enabledTools.count) of \(ToolID.allCases.count)")
                LabeledContent("Hidden mailboxes", value: model.policy.hiddenMailboxes.isEmpty ? "None" : "\(model.policy.hiddenMailboxes.count)")
                LabeledContent("Proton Mail Bridge", value: model.pin == nil ? "Not set up" : "Certificate pinned")
            }
            Section("Latest activity") {
                if model.activity.isEmpty {
                    Text("No app has used Postern yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.activity.prefix(4).enumerated()), id: \.offset) { _, record in
                        ActivityRow(record: record)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var headline: String {
        if !model.configured { return "Postern is not set up" }
        return model.policy.paused ? "Postern is paused" : "Postern is guarding your mailbox"
    }

    private var summary: String {
        if !model.configured { return "Run the setup to connect Postern to Proton Mail Bridge." }
        if model.policy.paused { return "Apps see no tool and every call is refused. Resuming asks for Touch ID." }
        return "Apps can only use the tools you turned on. Nothing is sent without your approval."
    }

    private var appsText: String {
        Dictionary(grouping: model.connectedApps, by: { $0 })
            .map { $0.value.count > 1 ? "\($0.key) (\($0.value.count))" : $0.key }
            .sorted().joined(separator: ", ")
    }
}

// MARK: Tools

private struct ToolsPane: View {
    @Bindable var model: ControlModel

    var body: some View {
        Form {
            Section {
                ForEach(ToolID.allCases.filter { $0.tier == .read }, id: \.self) { tool in
                    ToolRow(tool: tool, model: model)
                }
            } header: {
                Label("Read", systemImage: "envelope.open")
            } footer: {
                Text("Turning a tool on asks for Touch ID. Turning it off is immediate, and connected apps see the change at once.")
            }
            Section {
                ForEach(ToolID.allCases.filter { $0.tier == .organize }, id: \.self) { tool in
                    ToolRow(tool: tool, model: model)
                }
            } header: {
                Label("Organize", systemImage: "folder")
            } footer: {
                Text("Changes how your mail is sorted, never what it says. Postern moves a message from the folder it really lives in, so its labels are never lost, and reads Bridge again to confirm each change.")
            }
            Section {
                ForEach(ToolID.allCases.filter { $0.tier == .draft }, id: \.self) { tool in
                    ToolRow(tool: tool, model: model)
                }
            } header: {
                Label("Drafts", systemImage: "square.and.pencil")
            } footer: {
                Text("Drafts wait in Proton until someone sends them: you, or an app with your approval.")
            }
            Section {
                ForEach(ToolID.allCases.filter { $0.tier == .send }, id: \.self) { tool in
                    ToolRow(tool: tool, model: model)
                }
            } header: {
                Label("Send", systemImage: "paperplane")
            } footer: {
                Text("Every email waits for you on a panel that shows all of it: recipients, subject, the whole text. It leaves only after Touch ID. Limits and trusted recipients are in Security.")
            }
            UpcomingSection(title: "Delete", symbol: "trash",
                            tools: ["Move to Trash", "Delete forever"],
                            note: "Each deletion will need Touch ID.")
        }
        .formStyle(.grouped)
    }
}

private struct ToolRow: View {
    let tool: ToolID
    @Bindable var model: ControlModel

    var body: some View {
        let copy = ToolCopy.for(tool)
        Toggle(isOn: Binding(
            get: { model.policy.enabledTools.contains(tool) },
            set: { enabled in Task { await model.setTool(tool, enabled: enabled) } }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                Text(copy.title)
                Text(copy.allows).font(.callout).foregroundStyle(.secondary)
                Label(copy.risk, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .disabled(!model.configured)
    }
}

private struct UpcomingSection: View {
    let title: String
    let symbol: String
    let tools: [String]
    let note: String

    var body: some View {
        Section {
            ForEach(tools, id: \.self) { tool in
                Toggle(tool, isOn: .constant(false)).toggleStyle(.switch).disabled(true)
            }
        } header: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text("Coming in a later version").font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            Text(note)
        }
    }
}

// MARK: Mailboxes

private struct MailboxesPane: View {
    @Bindable var model: ControlModel

    var body: some View {
        Form {
            Section {
                switch model.mailboxState {
                case .idle, .loading:
                    HStack { ProgressView().controlSize(.small); Text("Reading your mailboxes from Bridge…").foregroundStyle(.secondary) }
                case .failed(let message):
                    Text(message).foregroundStyle(.secondary)
                case .loaded:
                    ForEach(model.mailboxes, id: \.name) { mailbox in
                        Toggle(isOn: Binding(
                            get: { !model.policy.isHidden(mailbox.name) },
                            set: { visible in Task { await model.setMailbox(mailbox.name, visible: visible) } }
                        )) {
                            HStack {
                                Image(systemName: symbol(for: mailbox)).foregroundStyle(.secondary).frame(width: 18)
                                Text(display(mailbox.name))
                                if let total = mailbox.total {
                                    Text("\(total)").foregroundStyle(.tertiary).monospacedDigit()
                                }
                            }
                        }
                        .toggleStyle(.switch)
                        .disabled(Policy.aggregateViews.contains(mailbox.name) && !model.policy.hiddenMailboxes.isEmpty)
                    }
                }
            } header: {
                Text("Visible to apps")
            } footer: {
                Text("A hidden mailbox doesn't exist for apps: it is missing from lists and searches, and its messages are refused. Hiding any mailbox also hides All Mail and Starred, which show every folder. Showing a mailbox again asks for Touch ID.")
            }
        }
        .formStyle(.grouped)
        .task { if model.mailboxState == .idle { await model.loadMailboxes() } }
    }

    private func display(_ name: String) -> String {
        if name == "INBOX" { return "Inbox" }
        return name.replacingOccurrences(of: "Folders/", with: "").replacingOccurrences(of: "Labels/", with: "").replacingOccurrences(of: "/", with: " › ")
    }

    private func symbol(for mailbox: MailboxInfo) -> String {
        switch mailbox.kind {
        case .label: return "tag"
        case .folder: return "folder"
        case .virtual: return mailbox.name == "Starred" ? "star" : "tray.full"
        case .system:
            switch mailbox.name {
            case "INBOX": return "tray"
            case "Sent": return "paperplane"
            case "Drafts": return "doc"
            case "Trash": return "trash"
            case "Spam": return "xmark.bin"
            case "Archive": return "archivebox"
            default: return "tray"
            }
        }
    }
}

// MARK: Apps

private struct ClientsPane: View {
    @Bindable var model: ControlModel

    var body: some View {
        Form {
            Section {
                if model.connectedApps.isEmpty {
                    Text("No app is connected right now.").foregroundStyle(.secondary)
                } else {
                    ForEach(sessionsByApp, id: \.name) { app in
                        HStack(spacing: 10) {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            Text(app.name)
                            Spacer()
                            Text(app.count == 1 ? "1 session" : "\(app.count) sessions").foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Connected now")
            }
            Section {
                ForEach(model.clients) { row in
                    LabeledContent {
                        clientAction(row)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.target.title)
                            Text(caption(row)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Add Another Claude Code Profile…") { model.addProfile() }
            } header: {
                Text("Your apps")
            } footer: {
                Text("Connecting writes one entry in the app's settings: the path of Postern's helper, never a password. Tools still stay off until you turn them on.")
            }
        }
        .formStyle(.grouped)
    }

    private var sessionsByApp: [(name: String, count: Int)] {
        Dictionary(grouping: model.connectedApps, by: { $0 }).map { ($0.key, $0.value.count) }.sorted { $0.name < $1.name }
    }

    @ViewBuilder private func clientAction(_ row: ClientRow) -> some View {
        if !row.installed {
            Text("Not on this Mac").foregroundStyle(.secondary)
        } else {
            switch row.status {
            case .connected:
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .notConnected:
                Button("Connect") { model.connect(row) }
            case .connectedElsewhere:
                Button("Update") { model.connect(row) }
            }
        }
    }

    private func caption(_ row: ClientRow) -> String {
        if case .connectedElsewhere = row.status { return "Points to an older copy of Postern" }
        return "~/" + row.target.fileURL.path.replacingOccurrences(of: ClientConnector.realHome.path + "/", with: "")
    }
}

// MARK: Activity

private struct ActivityPane: View {
    @Bindable var model: ControlModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            IntegrityBanner(integrity: model.integrity)
                .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            if model.activity.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "list.bullet.rectangle",
                                       description: Text("Every tool an app uses through Postern will appear here."))
            } else {
                Table(Array(model.activity.enumerated()).map(IndexedRecord.init)) {
                    TableColumn("Time") { Text($0.record.date.formatted(date: .abbreviated, time: .standard)) }
                        .width(min: 150, ideal: 170)
                    TableColumn("App") { Text($0.record.client) }.width(min: 90, ideal: 110)
                    TableColumn("Tool") { Text($0.record.tool) }.width(min: 110, ideal: 130)
                    TableColumn("Result") { OutcomeLabel(outcome: $0.record.outcome) }.width(min: 110, ideal: 140)
                    TableColumn("Items") { Text($0.record.items.map(String.init) ?? "").monospacedDigit() }.width(50)
                }
            }
        }
    }
}

private struct IndexedRecord: Identifiable {
    let id: Int
    let record: ActivityRecord

    init(_ pair: (offset: Int, element: ActivityRecord)) {
        id = pair.offset
        record = pair.element
    }
}

private struct IntegrityBanner: View {
    let integrity: Integrity?

    var body: some View {
        switch integrity {
        case .intact(let count)?:
            Label("Log intact, \(count) entr\(count == 1 ? "y" : "ies") kept for 90 days. Each entry is chained to the one before it.",
                  systemImage: "checkmark.seal.fill")
                .foregroundStyle(.secondary).symbolRenderingMode(.multicolor)
        case .broken(let line)?:
            Label("The log was changed outside Postern, at entry \(line).", systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
        case .headMismatch?:
            Label("Entries were removed from the log outside Postern.", systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }
}

private struct OutcomeLabel: View {
    let outcome: String

    /// Short words for the refusal codes clients receive.
    static func text(for outcome: String) -> String {
        switch outcome {
        case "policy_disabled": "Tool off"
        case "scope_hidden": "Hidden mailbox"
        case "paused": "Paused"
        case "not_configured": "Not set up"
        case "invalid_argument": "Bad request"
        case "stale_id": "Old message id"
        case "not_found": "Not found"
        case "bridge_unreachable": "Bridge offline"
        case "certificate_mismatch": "Wrong certificate"
        case "authentication_failed": "Sign-in refused"
        case "too_large": "Too large"
        case "parse_failed": "Unreadable"
        default: outcome.replacingOccurrences(of: "_", with: " ")
        }
    }

    var body: some View {
        if outcome == "ok" {
            Label("Done", systemImage: "checkmark").foregroundStyle(.secondary)
        } else {
            Label(Self.text(for: outcome), systemImage: "hand.raised").foregroundStyle(.orange)
        }
    }
}

struct ActivityRow: View {
    let record: ActivityRecord

    var body: some View {
        HStack {
            OutcomeLabel(outcome: record.outcome).labelStyle(.iconOnly).frame(width: 18)
            Text(record.client)
            Text(record.tool).foregroundStyle(.secondary)
            Spacer()
            Text(record.date.formatted(.relative(presentation: .named))).foregroundStyle(.tertiary)
        }
    }
}

// MARK: Security

private struct SecurityPane: View {
    @Bindable var model: ControlModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.policy.allowPasswordFallback },
                    set: { value in Task { await model.setPasswordFallback(value) } }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Accept my Mac password when Touch ID isn't available")
                        Text("For a closed lid or an external keyboard. Touch ID can't be typed by a program; a password can, if someone learned it.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            } header: {
                Text("Approvals")
            }
            SendingSection(model: model)
            Section {
                Toggle(isOn: Binding(
                    get: { model.policy.pauseWhenLocked },
                    set: { value in Task { await model.setPauseWhenLocked(value) } }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pause Postern when the screen locks")
                        Text("Apps lose access while you are away. You resume with Touch ID.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            } header: {
                Text("Pause")
            }
            Section {
                if let pin = model.pin {
                    LabeledContent("Certificate") {
                        Text(pin.display.split(separator: ":").prefix(8).joined(separator: " ") + " …")
                            .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                }
                if let endpoint = model.endpoint {
                    LabeledContent("Reading (IMAP)", value: "Port \(endpoint.imap.port), \(modeText(endpoint.imap.mode))")
                    LabeledContent("Sending (SMTP)", value: "Port \(endpoint.smtp.port), \(modeText(endpoint.smtp.mode))")
                }
                Button("Run Setup Again…") { model.openSetup() }
            } header: {
                Text("Proton Mail Bridge")
            } footer: {
                Text("Postern only talks to the certificate you trusted, and always encrypts before it sends your Bridge password.")
            }
        }
        .formStyle(.grouped)
    }

    private func modeText(_ mode: TLSMode) -> String {
        mode == .startTLS ? "encrypted with STARTTLS" : "encrypted from the first byte"
    }
}

// MARK: Sending settings

private struct SendingSection: View {
    @Bindable var model: ControlModel
    @State private var newTrusted = ""
    @State private var newAllowed = ""

    var body: some View {
        Section {
            Stepper(value: Binding(get: { model.policy.sendsPerHour },
                                   set: { value in Task { await model.setLimits(perHour: value, perDay: model.policy.sendsPerDay) } }),
                    in: 1...100) {
                LabeledContent("At most per hour", value: "\(model.policy.sendsPerHour) emails")
            }
            Stepper(value: Binding(get: { model.policy.sendsPerDay },
                                   set: { value in Task { await model.setLimits(perHour: model.policy.sendsPerHour, perDay: value) } }),
                    in: 1...500) {
                LabeledContent("At most per day", value: "\(model.policy.sendsPerDay) emails")
            }
        } header: {
            Text("Sending")
        } footer: {
            Text("Raising a limit asks for Touch ID. Apps hear that the limit is reached; nothing is sent.")
        }
        Section {
            AddressList(addresses: model.policy.trustedRecipients.sorted(), empty: "Nobody. Every email shows the approval panel.") { email in
                Task { await model.untrust(email) }
            }
            HStack {
                TextField("Add an address you trust", text: $newTrusted).onSubmit(addTrusted)
                Button("Trust…", action: addTrusted).disabled(newTrusted.isEmpty)
            }
        } header: {
            Text("Trusted recipients")
        } footer: {
            Text("Emails whose every recipient is trusted leave without the panel, such as notes to yourself. Adding someone asks for Touch ID.")
        }
        Section {
            AddressList(addresses: model.policy.allowedRecipients.sorted(), empty: "Anyone. Add addresses to send only to them.") { email in
                Task { await model.disallow(email) }
            }
            HStack {
                TextField("Add an address", text: $newAllowed).onSubmit(addAllowed)
                Button("Allow…", action: addAllowed).disabled(newAllowed.isEmpty)
            }
        } header: {
            Text("Only send to")
        } footer: {
            Text("When this list is not empty, apps cannot write to anyone else, even with your approval.")
        }
    }

    private func addTrusted() {
        let email = newTrusted
        newTrusted = ""
        Task { await model.trust(email) }
    }

    private func addAllowed() {
        let email = newAllowed
        newAllowed = ""
        Task { await model.allow(email) }
    }
}

private struct AddressList: View {
    let addresses: [String]
    let empty: String
    let remove: (String) -> Void

    var body: some View {
        if addresses.isEmpty {
            Text(empty).foregroundStyle(.secondary)
        } else {
            ForEach(addresses, id: \.self) { email in
                HStack {
                    Text(email)
                    Spacer()
                    Button("Remove") { remove(email) }.buttonStyle(.borderless)
                }
            }
        }
    }
}
