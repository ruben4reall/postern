import AppKit
import PDFKit
import PosternApproval
import PosternCompose
import PosternModel
import SwiftUI

/// Shows each approval request in a floating panel and returns what the person chose. It never authenticates:
/// the desk asks for Touch ID itself once Send was clicked.
struct PanelPresenter: ApprovalPresenter {
    func present(_ request: ApprovalRequest, deadline: Date) async -> ApprovalIntent {
        await ApprovalPanelController.shared.present(title: String(localized: "Approve Email"), height: request.message.attachments.isEmpty ? 680 : 760) { decide in
            AnyView(ApprovalView(request: request, deadline: deadline, decide: decide))
        }
    }

    func presentDeletion(_ request: DeletionRequest, deadline: Date) async -> ApprovalIntent {
        await ApprovalPanelController.shared.present(title: request.permanent ? String(localized: "Approve Erasing") : String(localized: "Approve Trash"), height: DeletionView.height(for: request)) { decide in
            AnyView(DeletionView(request: request, deadline: deadline, decide: decide))
        }
    }
}

@MainActor
final class ApprovalPanelController {
    static let shared = ApprovalPanelController()

    private var panel: NSPanel?
    private var finish: ((ApprovalIntent) -> Void)?

    nonisolated func present(
        title: String, height: CGFloat, content: @escaping @MainActor @Sendable (@escaping (ApprovalIntent) -> Void) -> AnyView
    ) async -> ApprovalIntent {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalIntent, Never>) in
                Task { @MainActor in self.show(title: title, height: height, content: content, continuation: continuation) }
            }
        } onCancel: {
            // The desk gave up waiting: the request expired.
            Task { @MainActor in self.close(with: .reject(reason: nil)) }
        }
    }

    private func show(
        title: String, height: CGFloat, content: (@escaping (ApprovalIntent) -> Void) -> AnyView,
        continuation: CheckedContinuation<ApprovalIntent, Never>
    ) {
        var resumed = false
        finish = { intent in
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: intent)
        }
        let view = content { [weak self] intent in self?.close(with: intent) }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: height),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false
        )
        panel.title = title
        panel.backgroundColor = NSColor(Theme.canvas)
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
            PanelHeader(symbol: "paperplane", signal: .accent,
                        title: Text("\(request.client) wants to send this email"),
                        detail: Text(request.context.map(KitText.localize) ?? String(localized: "A new email. Read all of it: this is exactly what leaves.")),
                        deadline: deadline)
            if !cameFromEmail.isEmpty { warning }
            if let words = message.missingAttachment {
                ProtonBanner(kind: .warning, symbol: "paperclip.badge.ellipsis",
                             text: Text("The text says “\(words)”, but no file is attached. The app said none is meant."))
            }
            messageContainer
            if !message.attachments.isEmpty { attachmentList }
        }
        .padding(.horizontal, 24)
        .padding(.top, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaInset(edge: .bottom, spacing: 0) { actions }
        .frame(width: 620, height: message.attachments.isEmpty ? 680 : 760)
        .background(Theme.canvas)
        .tint(Theme.accent)
    }

    /// The email as Proton shows an opened message: its header band, a hairline, the text on white.
    private var messageContainer: some View {
        VStack(spacing: 0) {
            fields
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.lowered)
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollView {
                bodyText.padding(16)
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .frame(maxHeight: .infinity)
            .background(Theme.canvas)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
    }

    private var fields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            row("From") { Text(Self.describe(message.from)) }
            row("To") { recipients(message.to) }
            if !message.cc.isEmpty { row("Cc") { recipients(message.cc) } }
            if !message.bcc.isEmpty { row("Bcc") { recipients(message.bcc) } }
            row("Subject") { Text(message.subject.isEmpty ? String(localized: "(no subject)") : message.subject).fontWeight(.semibold) }
        }
        .font(.system(size: 13))
    }

    private func row(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> some View) -> some View {
        GridRow {
            Text(title).foregroundStyle(Theme.textWeak).gridColumnAlignment(.trailing)
            content().foregroundStyle(Theme.text).textSelection(.enabled)
        }
    }

    private func recipients(_ list: [Address]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(list, id: \.email) { address in
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.describe(address)).fixedSize(horizontal: false, vertical: true)
                    let badges = request.badges[address.email.lowercased()] ?? []
                    if !badges.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(badges, id: \.self) { BadgeView(badge: $0) }
                        }
                    }
                }
            }
        }
    }

    private var warning: some View {
        ProtonBanner(kind: .danger, symbol: "exclamationmark.triangle.fill", text: Text(cameFromEmail.count == 1
            ? String(localized: "\(cameFromEmail[0]) appeared inside an email the app read. Make sure you really want to write to this address.")
            : String(localized: "\(cameFromEmail.joined(separator: ", ")) appeared inside an email the app read. Make sure you really want to write to these addresses.")))
    }

    private var bodyText: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message.body.isEmpty ? String(localized: "(no text)") : message.body)
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let quoted = message.quoted, !quoted.isEmpty {
                Text("Also sent, below your text:").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textWeak)
                    .padding(.top, 4)
                HStack(spacing: 0) {
                    Rectangle().fill(Theme.quoteBar).frame(width: 3)
                    Text(quoted).font(.system(size: 13)).foregroundStyle(Theme.textWeak).padding(.leading, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
    }

    private var attachmentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(message.attachments.count) attachments leave with it", systemImage: "paperclip")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textWeak)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(message.attachments, id: \.sha256) { AttachmentCard(attachment: $0) }
                }
            }
        }
    }

    private var actions: some View {
        GlassActionBar(reason: $reason) {
            Button("Reject") { decide(.reject(reason: reason.isEmpty ? nil : reason)) }
                .buttonStyle(.proton(.secondary, size: .large)).fixedSize()
            Button("Keep as Draft") { decide(.saveAsDraft) }
                .buttonStyle(.proton(.secondary, size: .large)).fixedSize()
            Button {
                decide(.send)
            } label: {
                Label("Send with Touch ID", systemImage: "touchid")
            }
            .buttonStyle(.proton(.primary, size: .large))
            .fixedSize()
        }
    }

    static func describe(_ address: Address) -> String {
        address.name.map { "\($0) <\(address.email)>" } ?? address.email
    }
}

/// The top of every approval panel: a flat tinted symbol, who asks for what, and the time left to answer.
struct PanelHeader: View {
    let symbol: String
    let signal: Theme.Signal
    let title: Text
    let detail: Text
    let deadline: Date
    var warnBelow = 20

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SymbolTile(symbol: symbol, signal: signal, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                title.font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
                detail.font(.system(size: 13)).foregroundStyle(Theme.textWeak).lineLimit(2)
            }
            Spacer(minLength: 8)
            Countdown(deadline: deadline, warnBelow: warnBelow)
        }
    }
}

/// The time left before the request is rejected, as a Proton badge that turns orange near the end.
struct Countdown: View {
    let deadline: Date
    var warnBelow = 20

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(deadline.timeIntervalSince(context.date)))
            let urgent = remaining < warnBelow
            Text(String(format: "%d:%02d", remaining / 60, remaining % 60))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(urgent ? Color.black : Theme.textWeak)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(urgent ? Theme.warning : Theme.weak, in: Capsule())
                .help("The request is rejected when this reaches zero.")
        }
    }
}

struct BadgeView: View {
    let badge: ApprovalBadge

    var body: some View {
        Pill(text: title, color: color, onColor: badge == .firstContact || badge == .replyToDiffers ? .black : .white)
    }

    private var title: String {
        switch badge {
        case .firstContact: String(localized: "First contact", comment: "A badge next to a recipient")
        case .cameFromEmail: String(localized: "Found in an email", comment: "A badge next to a recipient")
        case .replyToDiffers: String(localized: "Reply-To differs", comment: "A badge next to a recipient")
        case .trusted: String(localized: "Trusted", comment: "A badge next to a recipient")
        }
    }

    private var color: Color {
        switch badge {
        case .firstContact, .replyToDiffers: Theme.warning
        case .cameFromEmail: Theme.danger
        case .trusted: Theme.successStrong
        }
    }
}

/// One attachment on the panel: what it is, how big, a fingerprint, and a preview for images and PDFs.
private struct AttachmentCard: View {
    let attachment: OutgoingAttachment

    var body: some View {
        HStack(spacing: 10) {
            preview.frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename).font(.system(size: 13)).foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 200, alignment: .leading)
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)) · \(attachment.mimeType)")
                    .font(.system(size: 12)).foregroundStyle(Theme.textWeak)
                Text("SHA-256 \(attachment.sha256.prefix(12))…").font(.system(size: 11).monospaced()).foregroundStyle(Theme.hint)
            }
        }
        .padding(8)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
        .help(attachment.sha256)
    }

    @ViewBuilder private var preview: some View {
        if attachment.mimeType.hasPrefix("image/"), let image = NSImage(data: attachment.data) {
            Image(nsImage: image).resizable().scaledToFill()
        } else if attachment.mimeType == "application/pdf", let page = PDFDocument(data: attachment.data)?.page(at: 0) {
            Image(nsImage: page.thumbnail(of: NSSize(width: 88, height: 88), for: .mediaBox)).resizable().scaledToFit().background(.white)
        } else {
            Image(systemName: "doc").font(.system(size: 20)).foregroundStyle(Theme.hint)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.weak)
        }
    }
}

/// Moving to Trash or erasing: every message is listed, and nothing happens without Touch ID.
struct DeletionView: View {
    let request: DeletionRequest
    let deadline: Date
    let decide: (ApprovalIntent) -> Void
    @State private var reason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PanelHeader(symbol: request.permanent ? "trash.slash" : "trash", signal: request.permanent ? .danger : .warning,
                        title: Text(title),
                        detail: Text(request.permanent
                                     ? String(localized: "Erased messages cannot be recovered, not even from Proton.")
                                     : String(localized: "They stay in Trash, where you can move them back, until Trash is emptied.")),
                        deadline: deadline)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(request.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.subject.isEmpty ? String(localized: "(no subject)") : item.subject)
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(item.from).lineLimit(1).truncationMode(.middle)
                                Text("·").foregroundStyle(Theme.hint)
                                Text(KitText.mailbox(item.mailbox))
                                if let date = item.date {
                                    Text("·").foregroundStyle(Theme.hint)
                                    Text(date.formatted(date: .abbreviated, time: .shortened))
                                }
                            }
                            .font(.system(size: 12)).foregroundStyle(Theme.textWeak)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 9)
                        .padding(.horizontal, 14)
                    }
                }
            }
            .background(Theme.canvas)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
        }
        .padding(.horizontal, 24)
        .padding(.top, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            GlassActionBar(reason: $reason) {
                Button("Keep Them") { decide(.reject(reason: reason.isEmpty ? nil : reason)) }
                    .buttonStyle(.proton(.secondary, size: .large)).fixedSize()
                // Black on Proton's orange, never white: the warning color keeps its contrast.
                Button {
                    decide(.send)
                } label: {
                    Label(request.permanent ? String(localized: "Erase with Touch ID") : String(localized: "Move to Trash with Touch ID"), systemImage: "touchid")
                }
                .buttonStyle(.proton(request.permanent ? .danger : .warning, size: .large))
                .fixedSize()
            }
        }
        .frame(width: 620, height: Self.height(for: request))
        .background(Theme.canvas)
    }

    /// Tall enough for six messages; longer lists scroll.
    static func height(for request: DeletionRequest) -> CGFloat {
        CGFloat(196 + 52 * min(request.items.count, 6))
    }

    private var title: String {
        let count = request.items.count
        return request.permanent
            ? String(localized: "\(request.client) wants to erase \(count) emails for good")
            : String(localized: "\(request.client) wants to move \(count) emails to Trash")
    }
}
