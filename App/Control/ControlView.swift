import AppKit
import PosternAudit
import PosternBridge
import PosternClients
import PosternModel
import PosternPolicy
import PosternServer
import SwiftUI

/// The main window, in Proton's frame: a deep purple sidebar listing the panes, a white work area of warm grey cards.
struct ControlView: View {
    @Bindable var model: ControlModel

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 232, ideal: 250, max: 300)
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
            .background(Theme.canvas)
            .navigationTitle(model.configured ? model.pane.title : "Postern")
            .navigationSubtitle(model.statusLine)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    PauseToolbarButton(model: model)
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

/// Pause in the glass toolbar; Resume stands out in Proton's purple, as Proton's active filters do.
private struct PauseToolbarButton: View {
    @Bindable var model: ControlModel

    var body: some View {
        let paused = model.policy.paused
        let button = Button {
            Task { await model.setPaused(!paused) }
        } label: {
            Label(paused ? String(localized: "Resume") : String(localized: "Pause"),
                  systemImage: paused ? "play.fill" : "pause.fill")
        }
        .help(paused ? String(localized: "Let apps use Postern again (Touch ID)") : String(localized: "Turn every tool off for all apps, right away"))
        .disabled(!model.configured)
        if paused {
            button.buttonStyle(.glassProminent).tint(Theme.interaction)
        } else {
            button
        }
    }
}

#if DEBUG
/// The sidebar and the pane side by side, without the split view, which offscreen renders cannot draw.
struct ControlSnapshot: View {
    @Bindable var model: ControlModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model).frame(width: 250).background(Theme.sidebar)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.configured ? model.pane.title : "Postern").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                    Text(model.statusLine).font(.system(size: 12)).foregroundStyle(Theme.textWeak)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                if let updates = model.updates, let version = updates.pendingVersion {
                    UpdateBar(version: version) { updates.checkForUpdates() }
                }
                Group {
                    if !model.configured {
                        WelcomePane(model: model)
                    } else {
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
            }
            .background(Theme.canvas)
        }
        .tint(Theme.accent)
    }
}
#endif

extension ControlModel {
    var statusLine: String {
        if !configured { return String(localized: "Not set up") }
        if policy.paused { return String(localized: "Paused: every tool is off") }
        let count = policy.enabledTools.count
        return count == 0 ? String(localized: "On, every tool off") : String(localized: "On, \(count) of \(ToolID.switchable.count) tools on")
    }

    var statusTint: Color {
        if !configured { return Theme.hint }
        return policy.paused ? Theme.warning : Theme.success
    }
}

extension Tier {
    /// Purple for what only reads, writes or files; Proton's warning and danger for what leaves or is lost.
    var signal: Theme.Signal {
        switch self {
        case .read, .organize, .draft: .accent
        case .send: .warning
        case .delete: .danger
        }
    }
}

// MARK: Sidebar

/// Proton's navigation: Postern's own mark and name, then one row per pane, a subtle highlight and bold label on the
/// current one, small purple counters.
private struct Sidebar: View {
    @Bindable var model: ControlModel
    @Environment(\.appearsActive) private var active

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    PosternMark().fill(.white).frame(width: 18, height: 18)
                    Text(verbatim: "Postern").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.sidebarText)
                }
                .padding(.horizontal, 12)
                .frame(height: 44, alignment: .leading)
                VStack(spacing: 2) {
                    ForEach(ControlModel.Pane.allCases) { pane in
                        SidebarRow(title: pane.title,
                                   symbol: pane == .overview && model.policy.paused ? "pause.circle" : pane.symbol,
                                   selected: model.pane == pane && model.configured) {
                            model.pane = pane
                        } trailing: {
                            trailing(for: pane)
                        }
                        .disabled(!model.configured)
                    }
                }
                if !model.connectedApps.isEmpty {
                    Rectangle().fill(Theme.sidebarBorder).frame(height: 1).padding(.horizontal, 12).padding(.vertical, 12)
                    Text("Connected now")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.sidebarTextWeak)
                        .padding(.horizontal, 12)
                        .frame(height: 32, alignment: .leading)
                    ForEach(sessionsByApp, id: \.name) { app in
                        HStack(spacing: 8) {
                            Circle().fill(Theme.success).frame(width: 8, height: 8).frame(width: 18)
                            Text(app.name).font(.system(size: 13)).foregroundStyle(Theme.sidebarText).lineLimit(1)
                            Spacer(minLength: 4)
                            if app.count > 1 { Counter(value: "\(app.count)") }
                        }
                        .padding(.leading, 12).padding(.trailing, 8)
                        .frame(height: 32)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .background(Theme.sidebar)
        .opacity(active ? 1 : 0.85)
        .saturation(active ? 1 : 0.85)
    }

    private var sessionsByApp: [(name: String, count: Int)] {
        Dictionary(grouping: model.connectedApps, by: { $0 }).map { ($0.key, $0.value.count) }.sorted { $0.name < $1.name }
    }

    @ViewBuilder private func trailing(for pane: ControlModel.Pane) -> some View {
        if model.configured {
            switch pane {
            case .overview:
                Circle().fill(model.statusTint).frame(width: 8, height: 8)
                    .accessibilityLabel(model.policy.paused ? String(localized: "Off") : String(localized: "On"))
            case .tools: Counter(value: "\(model.policy.enabledTools.count)")
            case .mailboxes: if let count = model.visibleMailboxCount { Counter(value: "\(count)") }
            case .clients: if model.appsConnectedCount > 0 { Counter(value: "\(model.appsConnectedCount)") }
            case .activity: if model.activityToday > 0 { Counter(value: "\(model.activityToday)") }
            case .security:
                if case .intact? = model.integrity {
                    Image(systemName: "checkmark.circle").font(.system(size: 13)).foregroundStyle(Theme.success)
                } else if model.integrity != nil {
                    Counter(value: "!", color: Theme.danger)
                }
            }
        }
    }
}

/// One pane in the sidebar: 36pt tall, radius 8, outline symbol, bold when current.
private struct SidebarRow<Trailing: View>: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var trailing: Trailing
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Theme.sidebarIconOn : Theme.sidebarTextWeak)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .bold : .regular))
                    .foregroundStyle(Theme.sidebarText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                trailing
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 36)
            .background(selected || hovering ? Theme.sidebarHover : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
        .buttonStyle(SidebarPress())
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SidebarPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Theme.sidebarPressed : .clear,
                                       in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

/// Proton's navigation counter: a small purple rectangle with white figures.
private struct Counter: View {
    let value: String
    var color: Color = Theme.sidebarCounter

    var body: some View {
        Text(value)
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 20, minHeight: 18)
            .background(color, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
    }
}

// MARK: Shared pieces

/// A pane's scrolling body: cards on the white canvas, blurred under the glass toolbar as it scrolls.
private struct PaneScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { content }
                .padding(24)
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(Theme.canvas)
    }
}

/// What this place is for, in one or two sentences, under a flat tinted symbol.
struct PaneHero: View {
    let symbol: String
    let tint: Color
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            SymbolTile(symbol: symbol, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
                Text(text).font(.system(size: 13)).foregroundStyle(Theme.textWeak)
                    .frame(maxWidth: 560, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct NoticeBar: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        ProtonBanner(kind: .accent, symbol: "info.circle", text: Text(text), flat: true) {
            Button("Dismiss", action: dismiss).buttonStyle(.proton(.ghost, size: .small))
        }
    }
}

/// A new version, found by a check: named at the top of every pane until it is installed or looked at.
private struct UpdateBar: View {
    let version: String
    let open: () -> Void

    var body: some View {
        ProtonBanner(kind: .accent, symbol: "arrow.down.circle",
                     text: Text("Postern \(version) is available").fontWeight(.semibold)
                         + Text(verbatim: "  ") + Text("Signed by Postern's developer. Nothing installs until you choose to."),
                     flat: true) {
            Button("See What's New…", action: open).buttonStyle(.proton(.primary, size: .small))
        }
    }
}

private struct ServiceOffBar: View {
    var body: some View {
        ProtonBanner(kind: .warning, symbol: "exclamationmark.triangle.fill",
                     text: Text("Postern's background item is turned off, so apps can't connect. Turn Postern on in Login Items."),
                     flat: true) {
            Button("Open Login Items") { SMAppServiceSettings.open() }.buttonStyle(.proton(.secondary, size: .small))
        }
    }
}

// MARK: Welcome

private struct WelcomePane: View {
    @Bindable var model: ControlModel

    var body: some View {
        VStack(spacing: 18) {
            PosternMark()
                .fill(Theme.text)
                .frame(width: 72, height: 72)
                .padding(20)
                .background(Theme.weak, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            Text("Welcome to Postern").font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.text)
            Text("Postern lets apps like Claude Code work with your Proton Mail, through Proton Mail Bridge on this Mac. You decide what they may do, and nothing leaves without you.")
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textWeak)
                .frame(maxWidth: 460)
            Button("Set Up Postern…") { model.openSetup() }
                .buttonStyle(.proton(.primary, size: .large))
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}

// MARK: Overview

private struct OverviewPane: View {
    @Bindable var model: ControlModel

    var body: some View {
        PaneScroll {
            HStack(spacing: 18) {
                ZStack(alignment: .bottomTrailing) {
                    PosternMark()
                        .fill(Theme.text)
                        .frame(width: 40, height: 40)
                        .padding(12)
                        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    Image(systemName: model.policy.paused ? "pause.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white, model.statusTint)
                        .offset(x: 6, y: 6)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.policy.paused ? String(localized: "Postern is paused") : String(localized: "Postern is guarding your mailbox"))
                        .font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
                    Text(model.policy.paused
                         ? String(localized: "Apps see no tool and every call is refused. Resuming asks for Touch ID.")
                         : String(localized: "Apps can only use the tools you turned on. Nothing is sent or deleted without your approval."))
                        .font(.system(size: 13)).foregroundStyle(Theme.textWeak).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(model.policy.paused ? String(localized: "Resume") : String(localized: "Pause")) {
                    Task { await model.setPaused(!model.policy.paused) }
                }
                .buttonStyle(.proton(model.policy.paused ? .primary : .secondary))
                .fixedSize()
            }
            .padding(20)
            .background(Theme.weak, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.border))
            if !model.batches.isEmpty {
                ProtonSection("Batches", footer: Text("Approved emails leave one by one within your sending limits, as long as Postern runs. Stopping a batch keeps the drafts of the emails not sent yet.")) {
                    ForEach(model.batches.prefix(5)) { batch in
                        BatchRow(batch: batch, cancel: { model.cancelBatch(batch.id) }, resume: { model.resumeBatch(batch.id) })
                    }
                }
            }
            ProtonSection("What apps can do") {
                ForEach(Tier.allCases, id: \.self) { tier in
                    TierSummaryRow(tier: tier, on: model.enabledCount(tier),
                                   total: ToolID.switchable.filter { $0.tier == tier }.count) {
                        model.pane = .tools
                    }
                }
            }
            ProtonSection("Right now") {
                ProtonValueRow(label: "Apps connected", value: model.connectedApps.isEmpty ? String(localized: "None") : appsText)
                ProtonValueRow(label: "Hidden mailboxes", value: model.policy.hiddenMailboxes.isEmpty ? String(localized: "None") : "\(model.policy.hiddenMailboxes.count)")
                ProtonValueRow(label: "Sending limits", value: String(localized: "\(model.policy.sendsPerHour) per hour, \(model.policy.sendsPerDay) per day"))
                ProtonValueRow(label: "Proton Mail Bridge", value: model.pin == nil ? String(localized: "Not set up") : String(localized: "Certificate pinned"))
            }
            ProtonSection(header: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Latest activity")
                    Spacer()
                    Button("Show All") { model.pane = .activity }.buttonStyle(.proton(.ghost))
                }
            }) {
                if model.activity.isEmpty {
                    ProtonRow { Text("No app has used Postern yet.").foregroundStyle(Theme.textWeak) }
                } else {
                    ForEach(Array(model.activity.prefix(5).enumerated()), id: \.offset) { _, record in
                        ProtonRow { ActivityRow(record: record) }
                    }
                }
            }
        }
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
        ProtonRow {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    SymbolTile(symbol: batch.kind == .sends ? "paperplane" : "doc.on.doc",
                               signal: batch.kind == .sends ? .warning : .accent, size: 28)
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if batch.interrupted {
                        Button("Resume with Touch ID", action: resume).buttonStyle(.proton(.primary, size: .small)).fixedSize()
                    }
                    if !batch.isOver {
                        Button("Stop", role: .destructive, action: cancel).buttonStyle(.proton(.secondary, size: .small)).fixedSize()
                    }
                }
                ProgressView(value: Double(done), total: Double(max(1, batch.items.count))).tint(Theme.interaction)
                Text(status).font(.system(size: 12)).foregroundStyle(Theme.textWeak).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var title: String {
        batch.kind == .sends
            ? String(localized: "Sending \(batch.items.count) emails for \(batch.client)")
            : String(localized: "Saving \(batch.items.count) drafts for \(batch.client)")
    }

    private var done: Int { batch.items.filter { $0.status != .waiting }.count }

    private var status: String {
        let good = batch.kind == .sends ? batch.count(.sent) : batch.count(.saved)
        let total = batch.items.count
        var parts = [batch.kind == .sends ? String(localized: "\(good) of \(total) sent") : String(localized: "\(good) of \(total) saved")]
        let other = BatchBoard.ItemStatus.allCases.filter { ![.waiting, .sent, .saved].contains($0) }
        for status in other where batch.count(status) > 0 { parts.append(Self.count(batch.count(status), status)) }
        switch batch.phase {
        case .running: parts.append(String(localized: "in progress"))
        case .finished: parts.append(String(localized: "finished"))
        case .cancelled: parts.append(String(localized: "stopped"))
        case .waiting(let until, let reason):
            let why = KitText.localize(reason)
            parts.append(until.map { String(localized: "waiting until \(Self.time($0)). \(why)") } ?? String(localized: "waiting. \(why)"))
        }
        if batch.kind == .sends, !batch.isOver, let estimate = batch.estimate {
            parts.append(String(localized: "last one around \(Self.time(estimate))"))
        }
        return parts.joined(separator: " · ")
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    }

    /// How many emails of a batch are in one state, such as "2 failed".
    private static func count(_ count: Int, _ status: BatchBoard.ItemStatus) -> String {
        switch status {
        case .sending: String(localized: "\(count) being sent", comment: "Emails of a batch")
        case .uncertain: String(localized: "\(count) uncertain", comment: "Emails of a batch whose connection broke as Bridge took them")
        case .refused: String(localized: "\(count) refused", comment: "Emails of a batch")
        case .skipped: String(localized: "\(count) skipped", comment: "Emails of a batch")
        case .failed: String(localized: "\(count) failed", comment: "Emails of a batch")
        case .cancelled: String(localized: "\(count) cancelled", comment: "Emails of a batch")
        case .waiting: String(localized: "\(count) waiting", comment: "Emails of a batch")
        case .sent: String(localized: "\(count) sent", comment: "Emails of a batch")
        case .saved: String(localized: "\(count) saved", comment: "Drafts of a batch")
        }
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
            ProtonRow(hoverable: true) {
                HStack(spacing: 12) {
                    SymbolTile(symbol: copy.symbol, signal: tier.signal)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(copy.title).foregroundStyle(Theme.text)
                        Text(copy.summary).font(.system(size: 12)).foregroundStyle(Theme.textWeak).lineLimit(1)
                    }
                    Spacer()
                    Meter(on: on, total: total, signal: tier.signal)
                    Text(on == 0 ? String(localized: "Off") : String(localized: "\(on) of \(total)"))
                        .foregroundStyle(on == 0 ? Theme.hint : Theme.textWeak)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minWidth: 52, alignment: .trailing)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.hint)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// One small segment per tool, filled in the tier's color when it is on.
private struct Meter: View {
    let on: Int
    let total: Int
    let signal: Theme.Signal

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<total, id: \.self) { index in
                Capsule().fill(index < on ? signal.solid : Theme.strong).frame(width: 10, height: 6)
            }
        }
    }
}

// MARK: Tools

private struct ToolsPane: View {
    @Bindable var model: ControlModel

    var body: some View {
        PaneScroll {
            PaneHero(symbol: "switch.2", tint: Theme.interaction, title: "Tools",
                     text: "Each tool is one thing an app may do with your mail. Turning one on asks for Touch ID; turning it off is immediate, and connected apps see the change at once.")
            ForEach(Tier.allCases, id: \.self) { tier in
                VStack(alignment: .leading, spacing: 8) {
                    ProtonSection(header: { TierHeader(tier: tier, model: model) }) {
                        ForEach(ToolID.switchable.filter { $0.tier == tier }, id: \.self) { tool in
                            ToolRow(tool: tool, model: model)
                        }
                    }
                    footer(for: tier)
                }
            }
        }
    }

    @ViewBuilder private func footer(for tier: Tier) -> some View {
        switch tier {
        case .send:
            VStack(alignment: .leading, spacing: 8) {
                Text("Every email waits for you on a panel that shows all of it: recipients, subject, the whole text, every attachment. It leaves only after Touch ID. Limits and trusted recipients are in Security.")
                HStack(spacing: 6) {
                    Text("Apps can attach only files you put in Downloads › Postern › Outbox, or in folders inside it.")
                    Button("Show Outbox") { model.showOutbox() }.buttonStyle(.proton(.ghost))
                }
            }
            .font(.system(size: 12)).foregroundStyle(Theme.textWeak).fixedSize(horizontal: false, vertical: true)
        case .delete:
            Text("Each deletion waits for you on a panel that lists every message, and happens only after Touch ID. Erasing works only on messages already in Trash or Spam.")
                .font(.system(size: 12)).foregroundStyle(Theme.textWeak).fixedSize(horizontal: false, vertical: true)
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
            SymbolTile(symbol: copy.symbol, signal: tier.signal, size: 24)
            Text(copy.title)
            Text(on == 0 ? String(localized: "Off") : String(localized: "\(on) of \(total) on"))
                .font(.system(size: 13, weight: .regular)).foregroundStyle(Theme.textWeak)
            Spacer()
            if on > 0 {
                Button("Turn All Off") { Task { await model.setTier(tier, enabled: false) } }
                    .buttonStyle(.proton(.ghost)).font(.system(size: 13, weight: .regular))
            }
            if on < total {
                Button("Turn All On…") { Task { await model.setTier(tier, enabled: true) } }
                    .buttonStyle(.proton(.ghost)).font(.system(size: 13, weight: .regular))
            }
        }
    }
}

private struct ToolRow: View {
    let tool: ToolID
    @Bindable var model: ControlModel

    var body: some View {
        let copy = ToolCopy.for(tool)
        ProtonRow {
            Toggle(isOn: Binding(
                get: { model.policy.enabledTools.contains(tool) },
                set: { enabled in Task { await model.setTool(tool, enabled: enabled) } }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(copy.title).foregroundStyle(Theme.text)
                    Text(copy.allows).font(.system(size: 12)).foregroundStyle(Theme.textWeak)
                    Label(copy.risk, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(Theme.hint)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.proton)
            .disabled(!model.configured)
        }
    }
}

// MARK: Mailboxes

private struct MailboxesPane: View {
    @Bindable var model: ControlModel

    var body: some View {
        PaneScroll {
            PaneHero(symbol: "tray.2", tint: Theme.interaction, title: "Mailboxes",
                     text: "Choose what apps can see. A hidden mailbox doesn't exist for them: missing from lists and searches, its messages refused.")
            ProtonSection("Visible to apps", footer: Text("Hiding any mailbox also hides All Mail and Starred, which show every folder. Showing a mailbox again asks for Touch ID.")) {
                switch model.mailboxState {
                case .idle, .loading:
                    ProtonRow {
                        HStack { ProgressView().controlSize(.small); Text("Reading your mailboxes from Bridge…").foregroundStyle(Theme.textWeak) }
                    }
                case .failed(let message):
                    ProtonRow { Text(message).foregroundStyle(Theme.textWeak) }
                case .loaded:
                    ForEach(model.mailboxes, id: \.name) { mailbox in
                        ProtonRow {
                            Toggle(isOn: Binding(
                                get: { !model.policy.isHidden(mailbox.name) },
                                set: { visible in Task { await model.setMailbox(mailbox.name, visible: visible) } }
                            )) {
                                HStack(spacing: 8) {
                                    Image(systemName: symbol(for: mailbox)).foregroundStyle(Theme.textWeak).frame(width: 18)
                                    Text(display(mailbox.name))
                                    if let total = mailbox.total {
                                        Text("\(total)").foregroundStyle(Theme.hint).monospacedDigit()
                                    }
                                }
                            }
                            .toggleStyle(.proton)
                            .disabled(Policy.aggregateViews.contains(mailbox.name) && !model.policy.hiddenMailboxes.isEmpty)
                        }
                    }
                }
            }
        }
        .task { if model.mailboxState == .idle { await model.loadMailboxes() } }
    }

    private func display(_ name: String) -> String { KitText.mailbox(name) }

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
        PaneScroll {
            PaneHero(symbol: "app.connected.to.app.below.fill", tint: Theme.interaction, title: "Apps",
                     text: "Connect Postern to the apps you use. Connecting only tells an app where Postern is: what it may do stays in Tools.")
            ProtonSection("Connected now") {
                if model.connectedApps.isEmpty {
                    ProtonRow { Text("No app is connected right now.").foregroundStyle(Theme.textWeak) }
                } else {
                    ForEach(sessionsByApp, id: \.name) { app in
                        ProtonRow {
                            HStack(spacing: 10) {
                                Circle().fill(Theme.success).frame(width: 8, height: 8)
                                Text(app.name)
                                Spacer()
                                Text("\(app.count) sessions").foregroundStyle(Theme.textWeak)
                            }
                        }
                    }
                }
            }
            ProtonSection("Your apps", footer: Text("Connecting writes one entry in the app's settings: the path of Postern's helper, never a password. Tools still stay off until you turn them on.")) {
                ForEach(model.clients.filter(\.installed) + model.clients.filter { !$0.installed }) { row in
                    ProtonRow {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.target.title)
                                Text(caption(row)).font(.system(size: 12)).foregroundStyle(Theme.textWeak)
                            }
                            Spacer(minLength: 12)
                            clientAction(row)
                        }
                    }
                }
                ProtonRow {
                    Button("Add Another Claude Code Profile…") { model.addProfile() }.buttonStyle(.proton(.ghost))
                }
            }
            OtherAppSection()
        }
    }

    private var sessionsByApp: [(name: String, count: Int)] {
        Dictionary(grouping: model.connectedApps, by: { $0 }).map { ($0.key, $0.value.count) }.sorted { $0.name < $1.name }
    }

    @ViewBuilder private func clientAction(_ row: ClientRow) -> some View {
        if !row.installed {
            Text("Not on this Mac").foregroundStyle(Theme.hint)
        } else {
            switch row.status {
            case .connected:
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.successStrong)
            case .notConnected:
                Button("Connect") { model.connect(row) }.buttonStyle(.proton(.primary, size: .small)).fixedSize()
            case .connectedElsewhere:
                Button("Update") { model.connect(row) }.buttonStyle(.proton(.secondary, size: .small)).fixedSize()
            }
        }
    }

    private func caption(_ row: ClientRow) -> String {
        if case .connectedElsewhere = row.status { return String(localized: "Points to an older copy of Postern") }
        return "~/" + row.target.fileURL.path.replacingOccurrences(of: ClientConnector.realHome.path + "/", with: "")
    }
}

/// Any other MCP app: the entry to paste into its settings, in the shape it expects.
private struct OtherAppSection: View {
    @State private var snippet: SetupSnippet = .json
    @State private var copied = false

    var body: some View {
        ProtonSection("Any other app", footer: Text("Every app that speaks MCP can use Postern: paste this into its MCP settings. It names Postern's helper and nothing else.")) {
            ProtonRow {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Format", selection: $snippet) {
                        ForEach(SetupSnippet.allCases) { Text($0.title).tag($0) }
                    }
                    Text(snippet.text(relayPath: ClientConnector.relayPath))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
                    HStack {
                        Spacer()
                        Button(copied ? String(localized: "Copied") : String(localized: "Copy")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(snippet.text(relayPath: ClientConnector.relayPath), forType: .string)
                            copied = true
                            Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                        }
                        .buttonStyle(.proton(.primary))
                        .fixedSize()
                    }
                }
            }
        }
    }
}

// MARK: Activity

private struct ActivityPane: View {
    @Bindable var model: ControlModel
    @State private var search = ""
    @State private var refusedOnly = false

    var body: some View {
        PaneScroll {
            PaneHero(symbol: "list.bullet.rectangle", tint: Theme.interaction, title: "Activity",
                     text: "Every call an app made through Postern, kept for 90 days. Postern never writes down what your mail says.")
            IntegrityBanner(integrity: model.integrity)
            if model.activity.isEmpty {
                ProtonSection {
                    ProtonRow { Text("Every tool an app uses through Postern will appear here.").foregroundStyle(Theme.textWeak) }
                }
            } else {
                HStack(spacing: 12) {
                    ProtonField(placeholder: "Filter by app or tool", text: $search, symbol: "magnifyingglass")
                    // Proton's glass filter chips.
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            chip("All", selected: !refusedOnly) { refusedOnly = false }
                            chip("Refused", selected: refusedOnly) { refusedOnly = true }
                        }
                    }
                }
                if days.isEmpty {
                    ProtonSection {
                        ProtonRow { Text("Nothing matches.").foregroundStyle(Theme.textWeak) }
                    }
                }
                ForEach(days, id: \.day) { group in
                    ProtonSection(header: { Text(verbatim: group.title) }) {
                        ForEach(group.records) { item in
                            ProtonRow { ActivityDetailRow(record: item.record) }
                        }
                    }
                }
            }
        }
    }

    private func chip(_ title: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).padding(.vertical, 6).padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Theme.chipSelectedText : Theme.text)
        .glassEffect(.regular.interactive().tint(selected ? Theme.chipSelected : nil), in: .capsule)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                let title = calendar.isDateInToday(day) ? String(localized: "Today")
                    : calendar.isDateInYesterday(day) ? String(localized: "Yesterday") : day.formatted(date: .complete, time: .omitted)
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
                .monospacedDigit().foregroundStyle(Theme.textWeak).frame(width: 64, alignment: .leading)
            Text(record.client).frame(width: 130, alignment: .leading).lineLimit(1)
            Text(record.tool).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textWeak).lineLimit(1)
            Spacer()
            if let items = record.items { Text("\(items) items").foregroundStyle(Theme.textWeak).monospacedDigit() }
            if record.outcome != "ok" {
                Pill(text: OutcomeLabel.text(for: record.outcome), color: Theme.warning, onColor: .black)
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
            ProtonBanner(kind: .success, symbol: "checkmark.seal",
                         text: Text("Log intact, \(count) entries kept for 90 days. Each entry is chained to the one before it."))
        case .broken(let line)?:
            ProtonBanner(kind: .danger, symbol: "exclamationmark.octagon.fill",
                         text: Text("The log was changed outside Postern, at entry \(line)."))
        case .headMismatch?:
            ProtonBanner(kind: .danger, symbol: "exclamationmark.octagon.fill",
                         text: Text("Entries were removed from the log outside Postern."))
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
        case "policy_disabled": String(localized: "Tool off", comment: "Why Postern refused a call")
        case "scope_hidden": String(localized: "Hidden mailbox", comment: "Why Postern refused a call")
        case "paused": String(localized: "Paused", comment: "Why Postern refused a call")
        case "not_configured": String(localized: "Not set up", comment: "Why Postern refused a call")
        case "invalid_argument": String(localized: "Bad request", comment: "Why Postern refused a call")
        case "stale_id": String(localized: "Old message id", comment: "Why Postern refused a call")
        case "not_found": String(localized: "Not found", comment: "Why Postern refused a call")
        case "bridge_unreachable": String(localized: "Bridge offline", comment: "Why Postern refused a call")
        case "certificate_mismatch": String(localized: "Wrong certificate", comment: "Why Postern refused a call")
        case "authentication_failed": String(localized: "Sign-in refused", comment: "Why Postern refused a call")
        case "too_large": String(localized: "Too large", comment: "Why Postern refused a call")
        case "parse_failed": String(localized: "Unreadable", comment: "Why Postern refused a call")
        default: outcome.replacingOccurrences(of: "_", with: " ")
        }
    }

    var body: some View {
        if outcome == "ok" {
            Label("Done", systemImage: "checkmark").foregroundStyle(Theme.successStrong)
        } else {
            Label(Self.text(for: outcome), systemImage: "hand.raised").foregroundStyle(Theme.dynamic(light: 0xE66300, dark: 0xFFAD33))
        }
    }
}

struct ActivityRow: View {
    let record: ActivityRecord

    var body: some View {
        HStack {
            OutcomeLabel(outcome: record.outcome).labelStyle(.iconOnly).frame(width: 18)
            Text(record.client)
            Text(record.tool).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textWeak)
            Spacer()
            Text(record.date.formatted(.relative(presentation: .named))).foregroundStyle(Theme.hint)
        }
    }
}

// MARK: Security

private struct SecurityPane: View {
    @Bindable var model: ControlModel

    var body: some View {
        PaneScroll {
            PaneHero(symbol: "lock.shield", tint: Theme.interaction, title: "Security",
                     text: "How you approve, how much apps may send, the Bridge certificate Postern trusts, and updates. Anything that gives apps more power asks for Touch ID.")
            ProtonSection("Approvals") {
                ProtonRow {
                    Toggle(isOn: Binding(
                        get: { model.policy.allowPasswordFallback },
                        set: { value in Task { await model.setPasswordFallback(value) } }
                    )) {
                        SettingLabel(title: "Accept my Mac password when Touch ID isn't available",
                                     detail: "For a closed lid or an external keyboard. Touch ID can't be typed by a program; a password can, if someone learned it.")
                    }
                    .toggleStyle(.proton)
                }
            }
            SendingSection(model: model)
            ProtonSection("Pause") {
                ProtonRow {
                    Toggle(isOn: Binding(
                        get: { model.policy.pauseWhenLocked },
                        set: { value in Task { await model.setPauseWhenLocked(value) } }
                    )) {
                        SettingLabel(title: "Pause Postern when the screen locks",
                                     detail: "Apps lose access while you are away. You resume with Touch ID.")
                    }
                    .toggleStyle(.proton)
                }
            }
            ProtonSection("Proton Mail Bridge", footer: Text("Postern only talks to the certificate you trusted, and always encrypts before it sends your Bridge password.")) {
                if let pin = model.pin {
                    ProtonRow {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Certificate")
                            Spacer(minLength: 12)
                            Text(pin.display.split(separator: ":").prefix(8).joined(separator: " ") + " …")
                                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textWeak).textSelection(.enabled)
                        }
                    }
                }
                if let endpoint = model.endpoint {
                    ProtonValueRow(label: "Reading (IMAP)", value: String(localized: "Port \(String(endpoint.imap.port)), \(modeText(endpoint.imap.mode))"))
                    ProtonValueRow(label: "Sending (SMTP)", value: String(localized: "Port \(String(endpoint.smtp.port)), \(modeText(endpoint.smtp.mode))"))
                }
                ProtonRow {
                    Button("Run Setup Again…") { model.openSetup() }.buttonStyle(.proton(.secondary)).fixedSize()
                }
            }
            if let updates = model.updates { UpdatesSection(updates: updates) }
        }
    }

    private func modeText(_ mode: TLSMode) -> String {
        mode == .startTLS ? String(localized: "encrypted with STARTTLS") : String(localized: "encrypted from the first byte")
    }
}

/// A setting's title and the sentence that explains it.
private struct SettingLabel: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).foregroundStyle(Theme.text)
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textWeak)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Updates

private struct UpdatesSection: View {
    let updates: Updates

    var body: some View {
        ProtonSection("Updates", footer: Text("Postern reads the list of versions on getpostern.vercel.app and downloads updates from GitHub. It installs only those signed by its developer. Apart from Bridge, this is the only connection Postern makes.")) {
            ProtonRow {
                Toggle(isOn: Binding(
                    get: { updates.checksAutomatically },
                    set: { updates.setChecksAutomatically($0) }
                )) {
                    SettingLabel(title: "Check for updates automatically", detail: "Once a day. Nothing is installed without asking you.")
                }
                .toggleStyle(.proton)
                .disabled(!updates.active)
            }
            ProtonValueRow(label: "Version", value: Updates.currentVersion)
            ProtonRow {
                Button(updates.menuTitle) { updates.checkForUpdates() }
                    .buttonStyle(.proton(.secondary))
                    .fixedSize()
                    .disabled(!updates.canCheck)
            }
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
        ProtonSection("Sending", footer: Text("Raising a limit asks for Touch ID. A batch waits for room when a limit is reached. Proton sets its own limits by plan and account reputation (150 a day on the free plan) and may stop an account that looks like bulk mail: raise these only as far as your use needs.")) {
            ProtonRow {
                Stepper(value: Binding(get: { model.policy.sendsPerHour },
                                       set: { value in Task { await model.setLimits(perHour: value, perDay: model.policy.sendsPerDay) } }),
                        in: 1...300) {
                    LabeledContent("At most per hour", value: String(localized: "\(model.policy.sendsPerHour) emails"))
                }
            }
            ProtonRow {
                Stepper(value: Binding(get: { model.policy.sendsPerDay },
                                       set: { value in Task { await model.setLimits(perHour: model.policy.sendsPerHour, perDay: value) } }),
                        in: 1...1000) {
                    LabeledContent("At most per day", value: String(localized: "\(model.policy.sendsPerDay) emails"))
                }
            }
        }
        ProtonSection("Trusted recipients", footer: Text("Emails whose every recipient is trusted leave without the panel, such as notes to yourself. Adding someone asks for Touch ID.")) {
            AddressList(addresses: model.policy.trustedRecipients.sorted(), empty: "Nobody. Every email shows the approval panel.") { email in
                Task { await model.untrust(email) }
            }
            ProtonRow {
                HStack {
                    ProtonField(placeholder: "Add an address you trust", text: $newTrusted, onSubmit: addTrusted)
                    Button("Trust…", action: addTrusted).buttonStyle(.proton(.secondary)).fixedSize().disabled(newTrusted.isEmpty)
                }
            }
        }
        ProtonSection("Only send to", footer: Text("When this list is not empty, apps cannot write to anyone else, even with your approval.")) {
            AddressList(addresses: model.policy.allowedRecipients.sorted(), empty: "Anyone. Add addresses to send only to them.") { email in
                Task { await model.disallow(email) }
            }
            ProtonRow {
                HStack {
                    ProtonField(placeholder: "Add an address", text: $newAllowed, onSubmit: addAllowed)
                    Button("Allow…", action: addAllowed).buttonStyle(.proton(.secondary)).fixedSize().disabled(newAllowed.isEmpty)
                }
            }
        }
        ProtonSection("Send from", footer: Text("Apps can send from your account's address and from these aliases; the panel always shows which one. Adding one asks for Touch ID. In Bridge's split mode, an alias needs its own Bridge account.")) {
            AddressList(addresses: model.policy.senderAddresses.sorted(), empty: "Only your account's address.") { email in
                Task { await model.removeSender(email) }
            }
            ProtonRow {
                HStack {
                    ProtonField(placeholder: "Add an alias of your Proton account", text: $newSender, onSubmit: addSender)
                    Button("Add…", action: addSender).buttonStyle(.proton(.secondary)).fixedSize().disabled(newSender.isEmpty)
                }
            }
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
    let empty: LocalizedStringKey
    let remove: (String) -> Void

    var body: some View {
        if addresses.isEmpty {
            ProtonRow { Text(empty).foregroundStyle(Theme.textWeak) }
        } else {
            ForEach(addresses, id: \.self) { email in
                ProtonRow {
                    HStack {
                        Text(email)
                        Spacer()
                        Button("Remove") { remove(email) }.buttonStyle(.proton(.ghost)).foregroundStyle(Theme.danger)
                    }
                }
            }
        }
    }
}
