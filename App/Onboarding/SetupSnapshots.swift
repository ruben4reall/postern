#if DEBUG
import AppKit
import PosternApproval
import PosternAudit
import PosternCompose
import PosternBridge
import PosternClients
import PosternModel
import PosternPolicy
import SwiftUI

/// Renders each setup step in a window that is never put on screen. The sandbox keeps the app out of the rest of
/// the disk, so the images go to stdout as `name<TAB>base64` lines.
@MainActor
enum SetupSnapshots {
    static func write() {
        _ = NSApplication.shared
        writeSetup()
    }

    private static func render(_ root: some View, size: NSSize, appearance: NSAppearance.Name, name: String) {
        let view = NSHostingView(rootView: root.background(Color(nsColor: .windowBackgroundColor)))
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            print("\(name)\t\(png.base64EncodedString())")
        }
    }

    /// Puts the real control window outside every display, prints its window number, and keeps it there for the
    /// given time so `screencapture -l` can take it. Nothing appears on screen and focus is not taken.
    static func holdControlWindow(pane: String, dark: Bool, seconds: Double) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let model = sampleModel(pane: ControlModel.Pane(rawValue: pane) ?? .overview)
        if pane == "welcome" { model.configured = false }
        let host = NSHostingController(rootView: ControlView(model: model))
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.title = "Postern"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(NSSize(width: 940, height: 640))
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.orderFrontRegardless()
        print(window.windowNumber)
        fflush(stdout)
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The approval panel with a sample reply, kept outside every display for `screencapture -l`.
    static func holdApprovalPanel(dark: Bool, kind: String, seconds: Double) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let rootView: AnyView
        let title: String
        switch kind {
        case "trash", "erase":
            let erase = kind == "erase"
            let items = [
                DeletionItem(id: MessageID(mailbox: "INBOX", uidValidity: 1, uid: 4120), mailbox: erase ? "Trash" : "INBOX",
                             from: "Weekly Digest <news@digest.example>", subject: "Your week in review",
                             date: Date(timeIntervalSince1970: 1_792_051_200)),
                DeletionItem(id: MessageID(mailbox: "INBOX", uidValidity: 1, uid: 4121), mailbox: erase ? "Spam" : "INBOX",
                             from: "Flash Sale <deals@shop.example>", subject: "48 hours only: 30% off",
                             date: Date(timeIntervalSince1970: 1_792_137_600)),
                DeletionItem(id: MessageID(mailbox: "Archive", uidValidity: 1, uid: 88), mailbox: erase ? "Trash" : "Archive",
                             from: "noreply@tickets.example", subject: "Your receipt", date: Date(timeIntervalSince1970: 1_791_878_400)),
            ]
            let request = DeletionRequest(tool: kind == "erase" ? "delete_permanently" : "trash_messages",
                                          client: "Claude Code", items: items, permanent: kind == "erase")
            rootView = AnyView(DeletionView(request: request, deadline: Date().addingTimeInterval(97)) { _ in })
            title = kind == "erase" ? "Approve Erasing" : "Approve Trash"
        default:
            rootView = AnyView(ApprovalView(request: sampleApproval(attachments: kind == "attachments"),
                                            deadline: Date().addingTimeInterval(97)) { _ in })
            title = "Approve Email"
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: rootView))
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.title = title
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.orderFrontRegardless()
        print(window.windowNumber)
        fflush(stdout)
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func sampleApproval(attachments: Bool) -> ApprovalRequest {
        let files = attachments ? [
            try! OutgoingAttachment.make(filename: "Invoice September.pdf", data: samplePDF()),
            try! OutgoingAttachment.make(filename: "Site photo.png", data: SelfTestRun.png()),
        ] : []
        let message = try! OutgoingMessage.make(
            from: Address(name: nil, email: "ruben@example.ch"),
            to: [Address(name: "Billing", email: "billing@pay-studio.example")],
            cc: [Address(name: nil, email: "team@studio.example")],
            subject: "Re: Invoice for September",
            body: "Hello Anna,\n\nThanks for the invoice. The transfer will leave on Monday.\n\nBest,\nRuben",
            quoted: "On Fri 17 Oct 2026, Anna Keller <anna@studio.example> wrote:\n> Please find the invoice attached.\n> Payment details changed, use the new account below.",
            inReplyTo: "<abc@studio.example>", attachments: files
        )
        return ApprovalRequest(
            tool: "reply_to_message", client: "Claude Code", message: message,
            badges: ["billing@pay-studio.example": [.replyToDiffers, .firstContact, .cameFromEmail], "team@studio.example": []],
            context: "Reply to Anna Keller <anna@studio.example>: Invoice for September"
        )
    }

    static func samplePDF() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 420, height: 595)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        context.beginPDFPage(nil)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(box)
        context.setFillColor(gray: 0.15, alpha: 1)
        for line in 0..<14 { context.fill(CGRect(x: 40, y: 520 - line * 30, width: line % 4 == 3 ? 180 : 340, height: 9)) }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    static func sampleModel(pane: ControlModel.Pane) -> ControlModel {
        let pin = CertificatePin(sha256Hex: "7F2193528AB83E4142D113FCB7C8623A64EB7066AFBBC3650BF1F1A010547168")
        let home = ClientConnector.realHome
        do {
            do {
                let model = ControlModel(live: false)
                model.pane = pane
                model.configured = true
                model.policy = Policy(enabledTools: [.listMailboxes, .searchMessages, .getMessage, .markRead, .archiveMessages, .createDraft, .sendMessage, .replyToMessage],
                                      hiddenMailboxes: ["Folders/Health"], pauseWhenLocked: true,
                                      trustedRecipients: ["ruben@example.ch"])
                model.connectedApps = ["Claude Code", "Claude Code", "Codex"]
                model.pin = pin
                model.endpoint = BridgeEndpoint(imap: BridgePort(port: 1143, mode: .startTLS), smtp: BridgePort(port: 1025, mode: .implicit))
                model.mailboxState = .loaded
                model.mailboxes = [
                    MailboxInfo(name: "INBOX", kind: .system, total: 140, unread: 12),
                    MailboxInfo(name: "Archive", kind: .system, total: 1052, unread: 0),
                    MailboxInfo(name: "Sent", kind: .system, total: 627, unread: 0),
                    MailboxInfo(name: "All Mail", kind: .virtual, total: 3563, unread: 12),
                    MailboxInfo(name: "Folders/Health", kind: .folder, total: 31, unread: 0),
                    MailboxInfo(name: "Folders/Invoices", kind: .folder, total: 69, unread: 2),
                    MailboxInfo(name: "Folders/Travel", kind: .folder, total: 18, unread: 0),
                    MailboxInfo(name: "Labels/To pay", kind: .label, total: 4, unread: 1),
                ]
                model.clients = [
                    ClientRow(target: ClientTarget(id: "a", title: "Claude Code", kind: .claudeCode, fileURL: home.appendingPathComponent(".claude.json"), bookmark: nil), installed: true, status: .connected),
                    ClientRow(target: ClientTarget(id: "b", title: "Claude Desktop", kind: .claudeDesktop, fileURL: home.appendingPathComponent(ClientKind.claudeDesktop.relativePath), bookmark: nil), installed: true, status: .notConnected),
                    ClientRow(target: ClientTarget(id: "c", title: "Codex", kind: .codex, fileURL: home.appendingPathComponent(".codex/config.toml"), bookmark: nil), installed: true, status: .connected),
                ]
                let now = Date()
                model.activity = [
                    ActivityRecord(date: now.addingTimeInterval(-40), client: "Claude Code", tool: "get_message", outcome: "ok", items: 1, previous: ""),
                    ActivityRecord(date: now.addingTimeInterval(-55), client: "Claude Code", tool: "search_messages", outcome: "ok", items: 8, previous: ""),
                    ActivityRecord(date: now.addingTimeInterval(-300), client: "Codex", tool: "get_thread", outcome: "policy_disabled", items: nil, previous: ""),
                    ActivityRecord(date: now.addingTimeInterval(-900), client: "Claude Code", tool: "search_messages", outcome: "scope_hidden", items: nil, previous: ""),
                    ActivityRecord(date: now.addingTimeInterval(-3600), client: "Claude Code", tool: "list_mailboxes", outcome: "ok", items: 30, previous: ""),
                ]
                model.integrity = .intact(count: 128)
                return model
            }
        }
    }

    private static func writeSetup() {
        let pin = CertificatePin(sha256Hex: "7F2193528AB83E4142D113FCB7C8623A64EB7066AFBBC3650BF1F1A010547168")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for step in OnboardingModel.Step.allCases {
                let model = OnboardingModel {}
                model.step = step
                model.bridgeVersion = "03.27.01"
                model.imap = PortIdentity(mode: .startTLS, greeting: "", pin: pin)
                if step == .signIn { model.username = "ruben@example.ch" }
                let view = NSHostingView(rootView: OnboardingView(model: model).background(Color(nsColor: .windowBackgroundColor)))
                view.frame = NSRect(x: 0, y: 0, width: 540, height: 500)
                let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .fullSizeContentView],
                                      backing: .buffered, defer: false)
                window.titlebarAppearsTransparent = true
                window.appearance = NSAppearance(named: appearance)
                window.contentView = view
                view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let name = "\(step.rawValue + 1)-\(step)-\(appearance == .aqua ? "light" : "dark").png"
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    print("\(name)\t\(png.base64EncodedString())")
                }
            }
        }
    }
}
#endif
