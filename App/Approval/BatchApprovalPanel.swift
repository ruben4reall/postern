import os
import PosternApproval
import PosternCompose
import PosternModel
import SwiftUI

extension PanelPresenter {
    /// One panel for a batch of drafts. The view only collects which emails stay ticked; the desk asks for Touch ID.
    func presentBatch(_ request: BatchApprovalRequest, deadline: Date) async -> BatchIntent {
        let chosen = OSAllocatedUnfairLock(initialState: Set<UUID>())
        let title = String(localized: "Approve \(request.items.count) Emails")
        let intent = await ApprovalPanelController.shared.present(title: title, height: BatchApprovalView.height(for: request)) { decide in
            AnyView(BatchApprovalView(request: request, deadline: deadline, send: { ids in
                chosen.withLock { $0 = ids }
                decide(.send)
            }, reject: { reason in
                decide(.reject(reason: reason))
            }))
        }
        switch intent {
        case .send: return .send(chosen.withLock { $0 })
        case .reject(let reason): return .reject(reason: reason)
        case .saveAsDraft: return .reject(reason: nil)
        }
    }
}

/// Every email of a batch: recipients and their warnings, subject, the start of the text and the attachments.
/// The person unticks what should wait; one Touch ID sends the rest, each email exactly as listed.
struct BatchApprovalView: View {
    let request: BatchApprovalRequest
    let deadline: Date
    let send: (Set<UUID>) -> Void
    let reject: (String?) -> Void
    @State private var chosen: Set<UUID>
    @State private var reason = ""
    @State private var filter = ""
    private let summary: String
    /// Each email's searchable words, built once: a batch can hold thousands.
    private let words: [UUID: String]
    private let unannounced: Int

    init(request: BatchApprovalRequest, deadline: Date, send: @escaping (Set<UUID>) -> Void, reject: @escaping (String?) -> Void) {
        self.request = request
        self.deadline = deadline
        self.send = send
        self.reject = reject
        _chosen = State(initialValue: Set(request.items.map(\.id)))
        summary = Self.summary(of: request)
        words = Dictionary(uniqueKeysWithValues: request.items.map { item in
            (item.id, ([item.subject] + item.recipients + (item.to + item.cc).compactMap(\.name) + item.files.map(\.filename))
                .joined(separator: " ").lowercased())
        })
        unannounced = request.items.filter { $0.missingAttachment != nil }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if request.items.count > Self.filterThreshold {
                ProtonField(placeholder: "Show only the emails to or about…", text: $filter, symbol: "magnifyingglass")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                        row(item)
                    }
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .background(Theme.lowered)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
        }
        .padding(.horizontal, 24)
        .padding(.top, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaInset(edge: .bottom, spacing: 0) { actions }
        .frame(width: 720, height: Self.height(for: request))
        .background(Theme.canvas)
        .tint(Theme.accent)
    }

    static let filterThreshold = 8

    /// Tall enough for four emails; longer batches scroll.
    static func height(for request: BatchApprovalRequest) -> CGFloat {
        let filter = request.items.count > filterThreshold ? 36 : 0
        let schedule = request.schedule == nil ? 0 : 44
        let rows = request.items.count > filterThreshold ? 3 : min(request.items.count, 4)
        return CGFloat(270 + filter + schedule + 132 * rows)
    }

    private var shown: [BatchItem] {
        let wanted = filter.lowercased().split(separator: " ").map(String.init)
        guard !wanted.isEmpty else { return request.items }
        return request.items.filter { item in
            let text = words[item.id] ?? ""
            return wanted.allSatisfy { text.contains($0) }
        }
    }

    /// Who, from where, which files and how heavy, in one line.
    static func summary(of request: BatchApprovalRequest) -> String {
        let messages = request.items
        let people = Set(messages.flatMap(\.recipients)).count
        let senders = Set(messages.map { $0.from.email })
        var parts = [String(localized: "To \(people) people")]
        parts.append(senders.count == 1 ? String(localized: "from \(senders.first!)") : String(localized: "from \(senders.count) addresses"))
        let names = messages.map { Set($0.files.map(\.filename)) }
        let shared = names.dropFirst().reduce(names.first ?? []) { $0.intersection($1) }
        let own = Set(names.flatMap { $0 }).subtracting(shared)
        if !shared.isEmpty {
            let files = shared.sorted().joined(separator: ", ")
            parts.append(messages.count > 1 ? String(localized: "\(files) in each") : files)
        }
        if !own.isEmpty { parts.append(String(localized: "\(own.count) other files")) }
        let bytes = messages.reduce(0) { $0 + $1.files.reduce(0) { $0 + $1.size } }
        if bytes > 0 { parts.append(String(localized: "\(size(bytes)) of files in all")) }
        return parts.joined(separator: " · ")
    }

    /// When the emails leave, and when the last should, at the user's limits.
    private func scheduleText(_ schedule: BatchSchedule) -> String {
        let start = schedule.start.map { String(localized: "Starts \($0.formatted(date: .abbreviated, time: .shortened))") } ?? String(localized: "Starts now")
        let pace = schedule.spacing >= 60 && schedule.spacing.truncatingRemainder(dividingBy: 60) == 0
            ? Duration.seconds(schedule.spacing).formatted(.units(allowed: [.minutes], width: .wide))
            : Duration.seconds(schedule.spacing.rounded()).formatted(.units(allowed: [.seconds], width: .wide))
        let finish = Calendar.current.isDateInToday(schedule.finish)
            ? schedule.finish.formatted(date: .omitted, time: .shortened)
            : schedule.finish.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "\(start), one every \(pace). Within your limits (\(schedule.sendsPerHour) per hour, \(schedule.sendsPerDay) per day), the last leaves around \(finish).")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(symbol: "paperplane", signal: .accent,
                        title: Text("\(request.client) wants to send \(request.items.count) emails"),
                        detail: Text("Untick any that should wait. The others leave one by one, exactly as shown, after one Touch ID."),
                        deadline: deadline, warnBelow: 60)
            HStack(alignment: .firstTextBaseline) {
                Text(summary).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(2)
                Spacer(minLength: 8)
                Button(chosen.isEmpty ? String(localized: "Tick All") : String(localized: "Untick All")) {
                    chosen = chosen.isEmpty ? Set(request.items.map(\.id)) : []
                }
                .buttonStyle(.proton(.ghost, size: .small))
                .fixedSize()
            }
            if unannounced > 0 {
                ProtonBanner(kind: .warning, symbol: "exclamationmark.triangle.fill",
                             text: Text("\(unannounced) emails mention a file but carry none."))
            }
            if let schedule = request.schedule {
                if schedule.finish.timeIntervalSinceNow > 86_400 {
                    ProtonBanner(kind: .warning, symbol: "clock", text: Text(scheduleText(schedule)))
                        .help("Postern waits for room when a limit is reached. Raise the limits in Postern's window to send faster.")
                } else {
                    Label(scheduleText(schedule), systemImage: "clock")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textWeak)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("Postern waits for room when a limit is reached. Raise the limits in Postern's window to send faster.")
                }
            }
        }
    }

    private func row(_ item: BatchItem) -> some View {
        let included = Binding(
            get: { chosen.contains(item.id) },
            set: { isOn in if isOn { chosen.insert(item.id) } else { chosen.remove(item.id) } }
        )
        let ticked = chosen.contains(item.id)
        // Proton's unread and read rows: a ticked email on white and in bold, an unticked one greyed.
        return HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: included).toggleStyle(.checkbox).labelsHidden()
            VStack(alignment: .leading, spacing: 5) {
                Text(item.subject.isEmpty ? String(localized: "(no subject)") : item.subject)
                    .font(.system(size: 13, weight: ticked ? .semibold : .regular)).foregroundStyle(Theme.text).lineLimit(1)
                HStack(spacing: 6) {
                    Text("From").foregroundStyle(Theme.textWeak).frame(minWidth: 30, alignment: .leading)
                    Text(item.from.email).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 12))
                ForEach(Array(addresses(item).enumerated()), id: \.offset) { _, entry in
                    let (kind, address) = entry
                    HStack(spacing: 6) {
                        Text(kind).foregroundStyle(Theme.textWeak).frame(minWidth: 30, alignment: .leading)
                        Text(address.name.map { "\($0) <\(address.email)>" } ?? address.email).foregroundStyle(Theme.text)
                            .lineLimit(1).truncationMode(.middle)
                        ForEach(item.badges[address.email.lowercased()] ?? [], id: \.self) { BadgeView(badge: $0) }
                    }
                    .font(.system(size: 12))
                }
                Text(preview(item.text)).font(.system(size: 12)).foregroundStyle(Theme.textWeak).lineLimit(3)
                if !item.files.isEmpty {
                    Label(item.files.map { "\($0.filename) (\(Self.size($0.size)))" }.joined(separator: " · "),
                          systemImage: "paperclip")
                        .font(.system(size: 12)).foregroundStyle(Theme.textWeak).lineLimit(2)
                }
                if let words = item.missingAttachment {
                    Label("Says “\(words)” but carries no file.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(Theme.dynamic(light: 0xB24E05, dark: 0xFFC164))
                }
            }
            .opacity(ticked ? 1 : 0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(ticked ? Theme.canvas : Theme.lowered)
    }

    private var actions: some View {
        GlassActionBar(reason: $reason) {
            Button("Send None") { reject(reason.isEmpty ? nil : reason) }.buttonStyle(.proton(.secondary, size: .large)).fixedSize()
            Button {
                send(chosen)
            } label: {
                Label("Send \(chosen.count) with Touch ID", systemImage: "touchid")
            }
            .buttonStyle(.proton(.primary, size: .large))
            .disabled(chosen.isEmpty)
            .fixedSize()
        }
    }

    private func addresses(_ item: BatchItem) -> [(String, Address)] {
        item.to.map { (String(localized: "To"), $0) } + item.cc.map { (String(localized: "Cc"), $0) } + item.bcc.map { (String(localized: "Bcc"), $0) }
    }

    private func preview(_ body: String) -> String {
        let flat = body.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 300 ? String(flat.prefix(300)) + "…" : flat
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
