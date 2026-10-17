import AppKit
import PosternApproval
import PosternCompose
import PosternModel
import SwiftUI

/// Shows each approval request in a floating panel and returns what the person chose. It never authenticates:
/// the desk asks for Touch ID itself once Send was clicked.
struct PanelPresenter: ApprovalPresenter {
    func present(_ request: ApprovalRequest, deadline: Date) async -> ApprovalIntent {
        await ApprovalPanelController.shared.present(request, deadline: deadline)
    }
}

@MainActor
final class ApprovalPanelController {
    static let shared = ApprovalPanelController()

    private var panel: NSPanel?
    private var finish: ((ApprovalIntent) -> Void)?

    nonisolated func present(_ request: ApprovalRequest, deadline: Date) async -> ApprovalIntent {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalIntent, Never>) in
                Task { @MainActor in self.show(request, deadline: deadline, continuation: continuation) }
            }
        } onCancel: {
            // The desk gave up waiting: the request expired.
            Task { @MainActor in self.close(with: .reject(reason: nil)) }
        }
    }

    private func show(_ request: ApprovalRequest, deadline: Date, continuation: CheckedContinuation<ApprovalIntent, Never>) {
        var resumed = false
        finish = { intent in
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: intent)
        }
        let view = ApprovalView(request: request, deadline: deadline) { [weak self] intent in self?.close(with: intent) }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false
        )
        panel.title = "Approve Email"
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentViewController = NSHostingController(rootView: view)
        panel.center()
        panel.delegate = PanelCloser.shared
        PanelCloser.shared.onClose = { [weak self] in self?.close(with: .reject(reason: nil)) }
        self.panel = panel
        NSSound(named: "Glass")?.play()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func close(with intent: ApprovalIntent) {
        let finish = self.finish
        self.finish = nil
        PanelCloser.shared.onClose = nil
        panel?.orderOut(nil)
        panel = nil
        finish?(intent)
    }
}

/// Closing the panel with its close button counts as a rejection.
private final class PanelCloser: NSObject, NSWindowDelegate {
    @MainActor static let shared = PanelCloser()
    @MainActor var onClose: (() -> Void)?

    @MainActor func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

struct ApprovalView: View {
    let request: ApprovalRequest
    let deadline: Date
    let decide: (ApprovalIntent) -> Void
    @State private var reason = ""

    private var message: OutgoingMessage { request.message }
    private var cameFromEmail: [String] {
        request.badges.filter { $0.value.contains(.cameFromEmail) }.map(\.key).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            fields
            if !cameFromEmail.isEmpty { warning }
            bodyText
            actions
        }
        .padding(.horizontal, 24)
        .padding(.top, 36)
        .padding(.bottom, 20)
        .frame(width: 620, height: 680)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "paperplane.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(request.client) wants to send this email").font(.title3.weight(.semibold))
                Text(request.context ?? "A new email. Read all of it: this is exactly what leaves.")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(deadline.timeIntervalSince(context.date)))
                Text(String(format: "%d:%02d", remaining / 60, remaining % 60))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(remaining < 20 ? .orange : .secondary)
                    .help("The request is rejected when this reaches zero.")
            }
        }
    }

    private var fields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            row("From") { Text(Self.describe(message.from)) }
            row("To") { recipients(message.to) }
            if !message.cc.isEmpty { row("Cc") { recipients(message.cc) } }
            if !message.bcc.isEmpty { row("Bcc") { recipients(message.bcc) } }
            row("Subject") { Text(message.subject.isEmpty ? "(no subject)" : message.subject).fontWeight(.medium) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            content().textSelection(.enabled)
        }
    }

    private func recipients(_ list: [Address]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(list, id: \.email) { address in
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.describe(address)).fixedSize(horizontal: false, vertical: true)
                    let badges = request.badges[address.email.lowercased()] ?? []
                    if !badges.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(badges, id: \.self) { BadgeView(badge: $0) }
                        }
                    }
                }
            }
        }
    }

    private var warning: some View {
        Label {
            Text("\(cameFromEmail.joined(separator: ", ")) appeared inside an email the app read. Make sure you really want to write to \(cameFromEmail.count == 1 ? "this address" : "these addresses").")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.red)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var bodyText: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(message.body.isEmpty ? "(no text)" : message.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let quoted = message.quoted, !quoted.isEmpty {
                    Divider()
                    Text("Also sent, below your text:").font(.caption).foregroundStyle(.secondary)
                    Text(quoted).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textSelection(.enabled)
            .padding(14)
        }
        .frame(maxHeight: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    private var actions: some View {
        HStack(spacing: 10) {
            TextField("Why, for the app (optional)", text: $reason)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 210)
            Spacer()
            Button("Reject") { decide(.reject(reason: reason.isEmpty ? nil : reason)) }
            Button("Keep as Draft") { decide(.saveAsDraft) }
            Button {
                decide(.send)
            } label: {
                Label("Send with Touch ID", systemImage: "touchid")
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
    }

    static func describe(_ address: Address) -> String {
        address.name.map { "\($0) <\(address.email)>" } ?? address.email
    }
}

private struct BadgeView: View {
    let badge: ApprovalBadge

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }

    private var title: String {
        switch badge {
        case .firstContact: "First contact"
        case .cameFromEmail: "Found in an email"
        case .replyToDiffers: "Reply-To differs"
        case .trusted: "Trusted"
        }
    }

    private var color: Color {
        switch badge {
        case .firstContact, .replyToDiffers: .orange
        case .cameFromEmail: .red
        case .trusted: .green
        }
    }
}
