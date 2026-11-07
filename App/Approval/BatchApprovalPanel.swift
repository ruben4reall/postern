import os
import PosternApproval
import PosternCompose
import PosternModel
import SwiftUI

extension PanelPresenter {
    /// One panel for a batch of drafts. The view only collects which emails stay ticked; the desk asks for Touch ID.
    func presentBatch(_ request: BatchApprovalRequest, deadline: Date) async -> BatchIntent {
        let chosen = OSAllocatedUnfairLock(initialState: Set<UUID>())
        let title = "Approve \(request.items.count) Emails"
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

    init(request: BatchApprovalRequest, deadline: Date, send: @escaping (Set<UUID>) -> Void, reject: @escaping (String?) -> Void) {
        self.request = request
        self.deadline = deadline
        self.send = send
        self.reject = reject
        _chosen = State(initialValue: Set(request.items.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(request.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        row(item)
                    }
                }
            }
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            actions
        }
        .padding(.horizontal, 24)
        .padding(.top, 36)
        .padding(.bottom, 20)
        .frame(width: 680, height: Self.height(for: request))
    }

    /// Tall enough for four emails; longer batches scroll.
    static func height(for request: BatchApprovalRequest) -> CGFloat {
        CGFloat(210 + 132 * min(request.items.count, 4))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "paperplane.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(request.client) wants to send \(request.items.count) emails").font(.title3.weight(.semibold))
                Text("Untick any that should wait. The others leave one by one, exactly as shown, after one Touch ID.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(deadline.timeIntervalSince(context.date)))
                    Text(String(format: "%d:%02d", remaining / 60, remaining % 60))
                        .font(.callout.monospacedDigit()).foregroundStyle(remaining < 60 ? .orange : .secondary)
                }
                Button(chosen.isEmpty ? "Tick All" : "Untick All") {
                    chosen = chosen.isEmpty ? Set(request.items.map(\.id)) : []
                }
                .buttonStyle(.link)
            }
        }
    }

    private func row(_ item: ApprovalRequest) -> some View {
        let message = item.message
        let included = Binding(
            get: { chosen.contains(item.id) },
            set: { isOn in if isOn { chosen.insert(item.id) } else { chosen.remove(item.id) } }
        )
        return HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: included).toggleStyle(.checkbox).labelsHidden()
            VStack(alignment: .leading, spacing: 5) {
                Text(message.subject.isEmpty ? "(no subject)" : message.subject).fontWeight(.medium).lineLimit(1)
                ForEach(Array(addresses(message).enumerated()), id: \.offset) { _, entry in
                    let (kind, address) = entry
                    HStack(spacing: 6) {
                        Text(kind).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                        Text(address.name.map { "\($0) <\(address.email)>" } ?? address.email).lineLimit(1).truncationMode(.middle)
                        ForEach(item.badges[address.email.lowercased()] ?? [], id: \.self) { BadgeView(badge: $0) }
                    }
                    .font(.callout)
                }
                Text(preview(message.body)).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                if !message.attachments.isEmpty {
                    Label(message.attachments.map { "\($0.filename) (\(Self.size($0.data.count)))" }.joined(separator: " · "),
                          systemImage: "paperclip")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .opacity(chosen.contains(item.id) ? 1 : 0.45)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            TextField("Why, for the app (optional)", text: $reason)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 210)
            Spacer()
            Button("Send None") { reject(reason.isEmpty ? nil : reason) }
            Button {
                send(chosen)
            } label: {
                Label(chosen.count == 1 ? "Send 1 with Touch ID" : "Send \(chosen.count) with Touch ID", systemImage: "touchid")
            }
            .buttonStyle(.borderedProminent)
            .disabled(chosen.isEmpty)
        }
        .controlSize(.large)
    }

    private func addresses(_ message: OutgoingMessage) -> [(String, Address)] {
        message.to.map { ("To", $0) } + message.cc.map { ("Cc", $0) } + message.bcc.map { ("Bcc", $0) }
    }

    private func preview(_ body: String) -> String {
        let flat = body.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 300 ? String(flat.prefix(300)) + "…" : flat
    }

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
