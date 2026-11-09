import AppKit
import PosternAudit
import PosternBridge
import PosternClients
import PosternModel
import PosternPolicy
import PosternServer
import SwiftUI

/// The main window: a sidebar of tiles that show the state at a glance, and one pane at a time.
struct ControlView: View {
    @Bindable var model: ControlModel

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 248, ideal: 264, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if model.backgroundServiceOff { ServiceOffBar() }
                if let updates = model.updates, let version = updates.pendingVersion {
                    UpdateBar(version: version) { updates.checkForUpdates() }
                }
                if let notice = model.notice {
                    NoticeBar(text: notice) { model.notice = nil }
                }
                if model.configured { detail } else { WelcomePane(model: model) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.canvas)
            .navigationTitle(model.configured ? model.pane.title : "Postern")
            .navigationSubtitle(model.statusLine)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.setPaused(!model.policy.paused) }
                    } label: {
                        Label(model.policy.paused ? "Resume" : "Pause",
                              systemImage: model.policy.paused ? "play.fill" : "pause.fill")
                    }
                    .help(model.policy.paused ? "Let apps use Postern again (Touch ID)" : "Turn every tool off for all apps, right away")
                    .disabled(!model.configured)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .tint(Theme.accent)
        .sheet(isPresented: $model.showingSetup) {
            if let setup = model.setup {
                OnboardingView(model: setup, cancel: model.configured ? { model.cancelSetup() } : nil)
            }
        }
        .task { if model.configured && model.mailboxState == .idle { await model.loadMailboxes() } }
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

extension ControlModel {
    var statusLine: String {
        if !configured { return "Not set up" }
        if policy.paused { return "Paused: every tool is off" }
        let count = policy.enabledTools.count
        return count == 0 ? "On, every tool off" : "On, \(count) of \(ToolID.switchable.count) tools on"
    }

    var statusTint: Color {
        if !configured { return Theme.hint }
        return policy.paused ? Theme.warning : Theme.success
    }
}

extension ControlModel.Pane {
    var tint: Color { Theme.interaction }
}

extension Tier {
    /// Purple for what only reads, writes or files; Proton's warning and danger for what leaves or is lost.
    var tint: Color {
        switch self {
        case .read, .organize, .draft: Theme.interaction
        case .send: Theme.warning
        case .delete: Theme.danger
        }
    }
}

// MARK: Sidebar

private struct Sidebar: View {
    @Bindable var model: ControlModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(ControlModel.Pane.allCases) { pane in
                        Tile(pane: pane, value: value(for: pane), tint: pane == .overview ? model.statusTint : Theme.interaction,
                             symbol: pane == .overview && model.policy.paused ? "pause.fill" : pane.symbol,
                             selected: model.pane == pane && model.configured) {
                            model.pane = pane
                        }
                        .disabled(!model.configured)
                    }
                }
                if !model.connectedApps.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connected now").font(.caption.weight(.semibold)).textCase(.uppercase).kerning(0.4)
                            .foregroundStyle(Theme.sidebarTextWeak)
                        ForEach(sessionsByApp, id: \.name) { app in
                            HStack(spacing: 8) {
                                Circle().fill(Theme.success).frame(width: 7, height: 7)
                                Text(app.name).foregroundStyle(Theme.sidebarText)
                                Spacer()
                                if app.count > 1 {
                                    Text("\(app.count)").font(.caption.weight(.semibold)).monospacedDigit()
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Theme.interaction, in: RoundedRectangle(cornerRadius: 4))
                                }
                            }
                            .font(.callout)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.sidebar)
        .environment(\.colorScheme, .dark)
    }

    private var sessionsByApp: [(name: String, count: Int)] {
        Dictionary(grouping: model.connectedApps, by: { $0 }).map { ($0.key, $0.value.count) }.sorted { $0.name < $1.name }
    }

    private func value(for pane: ControlModel.Pane) -> String {
        guard model.configured else { return "" }
        switch pane {
        case .overview: return model.policy.paused ? "Off" : "On"
        case .tools: return "\(model.policy.enabledTools.count)"
        case .mailboxes: return model.visibleMailboxCount.map(String.init) ?? ""
        case .clients: return "\(model.appsConnectedCount)"
        case .activity: return "\(model.activityToday)"
        case .security:
            if case .intact? = model.integrity { return "OK" }
            return model.integrity == nil ? "" : "!"
        }
    }
}

/// A sidebar tile, like the smart lists of Reminders and Passwords: a colored symbol, a count, a name.
private struct Tile: View {
    let pane: ControlModel.Pane
    let value: String
    let tint: Color
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? Theme.interaction : .white)
                        .frame(width: 26, height: 26)
                        .background(selected ? AnyShapeStyle(.white) : AnyShapeStyle(tint), in: Circle())
                    Spacer(minLength: 4)
                    Text(value)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Text(pane.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(selected ? .white : Theme.sidebarTextWeak)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.interaction : Theme.sidebarTile,
                        in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(.white.opacity(selected ? 0.18 : 0.06)))
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(pane.title), \(value)")
    }
}

// MARK: Shared pieces

/// The card at the top of each pane: what this place is for, in one or two sentences.
struct PaneHero: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(tint, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.weight(.semibold))
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
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
        .background(Theme.accentSoft)
    }
}

/// A new version, found by a check: named at the top of every pane until it is installed or looked at.
private struct UpdateBar: View {
    let version: String
    let open: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent).font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Postern \(version) is available").fontWeight(.semibold)
                Text("Signed by Postern's developer. Nothing installs until you choose to.").font(.callout).foregroundStyle(Theme.textWeak)
            }
            Spacer()
            Button("See What's New…", action: open).buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Theme.accentSoft)
    }
}

private struct ServiceOffBar: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            Text("Postern's background item is turned off, so apps can't connect. Turn Postern on in Login Items.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Open Login Items") { SMAppServiceSettings.open() }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Theme.warning.opacity(0.12))
    }
}

// MARK: Welcome

private struct WelcomePane: View {
    @Bindable var model: ControlModel

    var body: some View {
        VStack(spacing: 18) {
            PosternMark()
                .fill(.primary)
                .frame(width: 84, height: 84)
                .padding(18)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            Text("Welcome to Postern").font(.largeTitle.weight(.semibold))
            Text("Postern lets apps like Claude Code work with your Proton Mail, through Proton Mail Bridge on this Mac. You decide what they may do, and nothing leaves without you.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            Button("Set Up Postern…") { model.openSetup() }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Overview

private struct OverviewPane: View {
    @Bindable var model: ControlModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 18) {
                    ZStack(alignment: .bottomTrailing) {
                        PosternMark()
                            .fill(.primary)
                            .frame(width: 46, height: 46)
                            .padding(12)
                            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        Image(systemName: model.policy.paused ? "pause.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white, model.statusTint)
                            .offset(x: 6, y: 6)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.policy.paused ? "Postern is paused" : "Postern is guarding your mailbox")
                            .font(.title2.weight(.semibold))
                        Text(model.policy.paused
                             ? "Apps see no tool and every call is refused. Resuming asks for Touch ID."
                             : "Apps can only use the tools you turned on. Nothing is sent or deleted without your approval.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(model.policy.paused ? "Resume" : "Pause") {
                        Task { await model.setPaused(!model.policy.paused) }
                    }
                    .controlSize(.large)
                }
                .padding(.vertical, 8)
            }
            if !model.batches.isEmpty {
                Section {
                    ForEach(model.batches.prefix(5)) { batch in
                        BatchRow(batch: batch, cancel: { model.cancelBatch(batch.id) }, resume: { model.resumeBatch(batch.id) })
                    }
                } header: {
                    Text("Batches")
                } footer: {
                    Text("Approved emails leave one by one within your sending limits, as long as Postern runs. Stopping a batch keeps the drafts of the emails not sent yet.")
                }
            }
            Section {
                ForEach(Tier.allCases, id: \.self) { tier in
                    TierSummaryRow(tier: tier, on: model.enabledCount(tier),
                                   total: ToolID.switchable.filter { $0.tier == tier }.count) {
                        model.pane = .tools
                    }
                }
            } header: {
                Text("What apps can do")
            }
            Section {
                LabeledContent("Apps connected", value: model.connectedApps.isEmpty ? "None" : appsText)
                LabeledContent("Hidden mailboxes", value: model.policy.hiddenMailboxes.isEmpty ? "None" : "\(model.policy.hiddenMailboxes.count)")
                LabeledContent("Sending limits", value: "\(model.policy.sendsPerHour) per hour, \(model.policy.sendsPerDay) per day")
                LabeledContent("Proton Mail Bridge", value: model.pin == nil ? "Not set up" : "Certificate pinned")
            } header: {
                Text("Right now")
            }
            Section {
                if model.activity.isEmpty {
                    Text("No app has used Postern yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.activity.prefix(5).enumerated()), id: \.offset) { _, record in
                        ActivityRow(record: record)
                    }
                }
            } header: {
                HStack {
                    Text("Latest activity")
                    Spacer()
                    Button("Show All") { model.pane = .activity }.buttonStyle(.link).font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var appsText: String {
        Dictionary(grouping: model.connectedApps, by: { $0 })
            .map { $0.value.count > 1 ? "\($0.key) (\($0.value.count))" : $0.key }
            .sorted().joined(separator: ", ")
    }
}

/// One batch: what it does, how far it got, why it waits, and a way to stop it.
private struct BatchRow: View {
    let batch: BatchBoard.Batch
    let cancel: () -> Void
    var resume: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: batch.kind == .sends ? "paperplane" : "doc.on.doc")
                    .font(.body.weight(.medium))
                Spacer()
                if batch.interrupted {
                    Button("Resume with Touch ID", action: resume).buttonStyle(.borderedProminent).controlSize(.small)
                }
                if !batch.isOver {
                    Button("Stop", role: .destructive, action: cancel).controlSize(.small)
                }
            }
            ProgressView(value: Double(done), total: Double(max(1, batch.items.count))).tint(Theme.accent)
            Text(status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        let what = batch.kind == .sends ? "Sending \(batch.items.count) emails" : "Saving \(batch.items.count) drafts"
        return "\(what) for \(batch.client)"
    }

    private var done: Int { batch.items.filter { $0.status != .waiting }.count }

    private var status: String {
        let good = batch.kind == .sends ? batch.count(.sent) : batch.count(.saved)
        let word = batch.kind == .sends ? "sent" : "saved"
        var parts = ["\(good) of \(batch.items.count) \(word)"]
        let other = BatchBoard.ItemStatus.allCases.filter { ![.waiting, .sent, .saved].contains($0) }
        for status in other where batch.count(status) > 0 { parts.append("\(batch.count(status)) \(status.rawValue)") }
        switch batch.phase {
        case .running: parts.append("in progress")
        case .finished: parts.append("finished")
        case .cancelled: parts.append("stopped")
        case .waiting(let until, let reason):
            let time = until.map { " until " + $0.formatted(date: Calendar.current.isDateInToday($0) ? .omitted : .abbreviated, time: .shortened) } ?? ""
            parts.append("waiting\(time). \(reason)")
        }
        if batch.kind == .sends, !batch.isOver, let estimate = batch.estimate {
            parts.append("last one around " + estimate.formatted(date: Calendar.current.isDateInToday(estimate) ? .omitted : .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }
}

private struct TierSummaryRow: View {
    let tier: Tier
    let on: Int
    let total: Int
    let open: () -> Void

    var body: some View {
        let copy = TierCopy.for(tier)
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: copy.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(tier.tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(copy.title)
                    Text(copy.summary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Meter(on: on, total: total, tint: tier.tint)
                Text(on == 0 ? "Off" : "\(on) of \(total)")
                    .foregroundStyle(on == 0 ? .secondary : .primary)
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One small segment per tool, filled when it is on.
private struct Meter: View {
    let on: Int
    let total: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<total, id: \.self) { index in
                Capsule().fill(index < on ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary)).frame(width: 9, height: 6)
            }
        }
    }
}

// MARK: Tools

private struct ToolsPane: View {
    @Bindable var model: ControlModel

    var body: some View {
        Form {
            Section {
                PaneHero(symbol: "switch.2", tint: Theme.interaction, title: "Tools",
                         text: "Each tool is one thing an app may do with your mail. Turning one on asks for Touch ID; turning it off is immediate, and connected apps see the change at once.")
            }
            ForEach(Tier.allCases, id: \.self) { tier in
                Section {
                    ForEach(ToolID.switchable.filter { $0.tier == tier }, id: \.self) { tool in
                        ToolRow(tool: tool, model: model)
                    }
                } header: {
                    TierHeader(tier: tier, model: model)
                } footer: {
                    footer(for: tier)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func footer(for tier: Tier) -> some View {
        switch tier {
        case .send:
            VStack(alignment: .leading, spacing: 8) {
                Text("Every email waits for you on a panel that shows all of it: recipients, subject, the whole text, every attachment. It leaves only after Touch ID. Limits and trusted recipients are in Security.")
                HStack(spacing: 6) {
                    Text("Apps can attach only files you put in Downloads › Postern › Outbox, or in folders inside it.")
                    Button("Show Outbox") { model.showOutbox() }.buttonStyle(.link)
                }
            }
        case .delete:
            Text("Each deletion waits for you on a panel that lists every message, and happens only after Touch ID. Erasing works only on messages already in Trash or Spam.")
        default:
            EmptyView()
        }
    }
}

private struct TierHeader: View {
    let tier: Tier
    @Bindable var model: ControlModel

    var body: some View {
        let copy = TierCopy.for(tier)
        let on = model.enabledCount(tier)
        let total = ToolID.switchable.filter { $0.tier == tier }.count
        HStack(spacing: 8) {
            Image(systemName: copy.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(tier.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(copy.title).font(.headline)
            Text(on == 0 ? "Off" : "\(on) of \(total) on").foregroundStyle(.secondary)
            Spacer()
            if on > 0 {
                Button("Turn All Off") { Task { await model.setTier(tier, enabled: false) } }
                    .buttonStyle(.link).font(.callout)
            }
            if on < total {
                Button("Turn All On…") { Task { await model.setTier(tier, enabled: true) } }
                    .buttonStyle(.link).font(.callout)
            }
        }
        .padding(.bottom, 2)
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

// MARK: Mailboxes

private struct MailboxesPane: View {
    @Bindable var model: ControlModel

    var body: some View {
        Form {
            Section {
                PaneHero(symbol: "tray.2", tint: Theme.interaction, title: "Mailboxes",
                         text: "Choose what apps can see. A hidden mailbox doesn't exist for them: missing from lists and searches, its messages refused.")
            }
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
                Text("Hiding any mailbox also hides All Mail and Starred, which show every folder. Showing a mailbox again asks for Touch ID.")
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
                PaneHero(symbol: "app.connected.to.app.below.fill", tint: Theme.interaction, title: "Apps",
                         text: "Connect Postern to the apps you use. Connecting only tells an app where Postern is: what it may do stays in Tools.")
            }
            Section {
                if model.connectedApps.isEmpty {
                    Text("No app is connected right now.").foregroundStyle(.secondary)
                } else {
                    ForEach(sessionsByApp, id: \.name) { app in
                        HStack(spacing: 10) {
                            Circle().fill(Theme.success).frame(width: 8, height: 8)
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
                ForEach(model.clients.filter(\.installed) + model.clients.filter { !$0.installed }) { row in
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
            OtherAppSection()
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
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
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

/// Any other MCP app: the entry to paste into its settings, in the shape it expects.
private struct OtherAppSection: View {
    @State private var snippet: SetupSnippet = .json
    @State private var copied = false

    var body: some View {
        Section {
            Picker("Format", selection: $snippet) {
                ForEach(SetupSnippet.allCases) { Text($0.title).tag($0) }
            }
            Text(snippet.text(relayPath: ClientConnector.relayPath))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.lowered, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
            HStack {
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet.text(relayPath: ClientConnector.relayPath), forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                }
                .buttonStyle(.borderedProminent)
            }
        } header: {
            Text("Any other app")
        } footer: {
            Text("Every app that speaks MCP can use Postern: paste this into its MCP settings. It names Postern's helper and nothing else.")
        }
    }
}

// MARK: Activity

private struct ActivityPane: View {
    @Bindable var model: ControlModel
    @State private var search = ""
    @State private var refusedOnly = false

    var body: some View {
        Form {
            Section {
                PaneHero(symbol: "list.bullet.rectangle", tint: Theme.interaction, title: "Activity",
                         text: "Every call an app made through Postern, kept for 90 days. Postern never writes down what your mail says.")
                IntegrityBanner(integrity: model.integrity)
            }
            if model.activity.isEmpty {
                Section {
                    Text("Every tool an app uses through Postern will appear here.").foregroundStyle(.secondary)
                }
            } else {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                        TextField("Filter by app or tool", text: $search).textFieldStyle(.plain)
                        Picker("Show", selection: $refusedOnly) {
                            Text("All").tag(false)
                            Text("Refused").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 170)
                    }
                }
                if days.isEmpty {
                    Section { Text("Nothing matches.").foregroundStyle(.secondary) }
                }
                ForEach(days, id: \.day) { group in
                    Section(group.title) {
                        ForEach(group.records) { item in
                            ActivityDetailRow(record: item.record)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var days: [(day: Date, title: String, records: [IndexedRecord])] {
        let calendar = Calendar.current
        let matching = Array(model.activity.enumerated()).map(IndexedRecord.init).filter { item in
            (!refusedOnly || item.record.outcome != "ok")
                && (search.isEmpty || item.record.client.localizedCaseInsensitiveContains(search)
                    || item.record.tool.localizedCaseInsensitiveContains(search))
        }
        return Dictionary(grouping: matching) { calendar.startOfDay(for: $0.record.date) }
            .map { day, records in
                let title = calendar.isDateInToday(day) ? "Today"
                    : calendar.isDateInYesterday(day) ? "Yesterday" : day.formatted(date: .complete, time: .omitted)
                return (day, title, records)
            }
            .sorted { $0.day > $1.day }
    }
}

private struct ActivityDetailRow: View {
    let record: ActivityRecord

    var body: some View {
        HStack(spacing: 12) {
            OutcomeLabel(outcome: record.outcome).labelStyle(.iconOnly).frame(width: 18)
            Text(record.date.formatted(date: .omitted, time: .shortened))
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(record.client).frame(width: 130, alignment: .leading).lineLimit(1)
            Text(record.tool).font(.system(.body, design: .monospaced)).lineLimit(1)
            Spacer()
            if let items = record.items { Text(items == 1 ? "1 item" : "\(items) items").foregroundStyle(.secondary).monospacedDigit() }
            if record.outcome != "ok" {
                OutcomeLabel(outcome: record.outcome).labelStyle(.titleOnly)
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
                .foregroundStyle(Theme.danger)
        case .headMismatch?:
            Label("Entries were removed from the log outside Postern.", systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(Theme.danger)
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
            Label(Self.text(for: outcome), systemImage: "hand.raised").foregroundStyle(Theme.warning)
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
                PaneHero(symbol: "lock.shield", tint: Theme.interaction, title: "Security",
                         text: "How you approve, how much apps may send, the Bridge certificate Postern trusts, and updates. Anything that gives apps more power asks for Touch ID.")
            }
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
            if let updates = model.updates { UpdatesSection(updates: updates) }
        }
        .formStyle(.grouped)
    }

    private func modeText(_ mode: TLSMode) -> String {
        mode == .startTLS ? "encrypted with STARTTLS" : "encrypted from the first byte"
    }
}

// MARK: Updates

private struct UpdatesSection: View {
    let updates: Updates

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { updates.checksAutomatically },
                set: { updates.setChecksAutomatically($0) }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Check for updates automatically")
                    Text("Once a day. Nothing is installed without asking you.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(!updates.active)
            LabeledContent("Version", value: Updates.currentVersion)
            Button(updates.menuTitle) { updates.checkForUpdates() }
                .disabled(!updates.canCheck)
        } header: {
            Text("Updates")
        } footer: {
            Text("Postern reads the list of versions on getpostern.vercel.app and downloads updates from GitHub. It installs only those signed by its developer. Apart from Bridge, this is the only connection Postern makes.")
        }
    }
}

// MARK: Sending settings

private struct SendingSection: View {
    @Bindable var model: ControlModel
    @State private var newTrusted = ""
    @State private var newAllowed = ""
    @State private var newSender = ""

    var body: some View {
        Section {
            Stepper(value: Binding(get: { model.policy.sendsPerHour },
                                   set: { value in Task { await model.setLimits(perHour: value, perDay: model.policy.sendsPerDay) } }),
                    in: 1...300) {
                LabeledContent("At most per hour", value: "\(model.policy.sendsPerHour) emails")
            }
            Stepper(value: Binding(get: { model.policy.sendsPerDay },
                                   set: { value in Task { await model.setLimits(perHour: model.policy.sendsPerHour, perDay: value) } }),
                    in: 1...1000) {
                LabeledContent("At most per day", value: "\(model.policy.sendsPerDay) emails")
            }
        } header: {
            Text("Sending")
        } footer: {
            Text("Raising a limit asks for Touch ID. A batch waits for room when a limit is reached. Proton sets its own limits by plan and account reputation (150 a day on the free plan) and may stop an account that looks like bulk mail: raise these only as far as your use needs.")
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
        Section {
            AddressList(addresses: model.policy.senderAddresses.sorted(), empty: "Only your account's address.") { email in
                Task { await model.removeSender(email) }
            }
            HStack {
                TextField("Add an alias of your Proton account", text: $newSender).onSubmit(addSender)
                Button("Add…", action: addSender).disabled(newSender.isEmpty)
            }
        } header: {
            Text("Send from")
        } footer: {
            Text("Apps can send from your account's address and from these aliases; the panel always shows which one. Adding one asks for Touch ID. In Bridge's split mode, an alias needs its own Bridge account.")
        }
    }

    private func addSender() {
        let email = newSender
        newSender = ""
        Task { await model.addSender(email) }
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
