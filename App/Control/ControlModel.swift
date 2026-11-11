import AppKit
import Foundation
import Observation
import PosternAudit
import PosternBridge
import PosternClients
import PosternModel
import PosternPolicy
import PosternServer
import PosternVault

/// What the control window shows, and the only place that changes the policy.
@MainActor @Observable
final class ControlModel {
    enum Pane: String, CaseIterable, Identifiable {
        case overview, tools, mailboxes, clients, activity, security

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: String(localized: "Overview")
            case .tools: String(localized: "Tools")
            case .mailboxes: String(localized: "Mailboxes")
            case .clients: String(localized: "Apps")
            case .activity: String(localized: "Activity")
            case .security: String(localized: "Security")
            }
        }

        var symbol: String {
            switch self {
            case .overview: "shield.lefthalf.filled"
            case .tools: "switch.2"
            case .mailboxes: "tray.2"
            case .clients: "app.connected.to.app.below.fill"
            case .activity: "list.bullet.rectangle"
            case .security: "lock"
            }
        }
    }

    enum MailboxState: Equatable {
        case idle, loading, loaded, failed(String)
    }

    var pane: Pane = .overview
    /// The setup sheet, over the main window.
    var showingSetup = false {
        didSet { if showingSetup && setup == nil { setup = OnboardingModel { [weak self] in self?.finishSetup() } } }
    }
    private(set) var setup: OnboardingModel?
    /// This copy runs on its own because the background agent is turned off: apps can't connect.
    var backgroundServiceOff = false
    /// Sparkle, in the running app. Snapshots and previews have none.
    var updates: Updates?
    var policy: Policy = .initial
    var configured = false
    var connectedApps: [String] = []
    var mailboxes: [MailboxInfo] = []
    var mailboxState: MailboxState = .idle
    var clients: [ClientRow] = []
    var activity: [ActivityRecord] = []
    /// Batches of drafts and sends since the app started, newest first.
    var batches: [BatchBoard.Batch] = []
    var integrity: Integrity?
    var pin: CertificatePin?
    var endpoint: BridgeEndpoint?
    var notice: String?

    /// Snapshots and previews fill the model by hand and never touch the system.
    let isLive: Bool

    init(live: Bool = true) {
        isLive = live
    }

    func openSetup() { showingSetup = true }

    func finishSetup() {
        showingSetup = false
        setup = nil
        CoreState.shared.reload()
        refresh()
        Task { await loadMailboxes() }
    }

    func cancelSetup() {
        showingSetup = false
        setup = nil
    }

    // MARK: Counts for the sidebar

    var activityToday: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return activity.filter { $0.date >= start }.count
    }

    var visibleMailboxCount: Int? {
        guard mailboxState == .loaded else { return nil }
        return mailboxes.filter { !policy.isHidden($0.name) }.count
    }

    var appsConnectedCount: Int { Set(connectedApps).count }

    func enabledCount(_ tier: Tier) -> Int { policy.enabledTools.filter { $0.tier == tier }.count }

    // MARK: Loading

    func refresh() {
        guard isLive else { return }
        let state = CoreState.shared
        policy = state.policy
        configured = state.backend != nil
        connectedApps = state.connectedApps
        activity = (try? state.activity.records(limit: 200)) ?? []
        integrity = try? state.activity.verify()
        pin = try? state.vault.read(.certificatePin, as: CertificatePin.self)
        endpoint = try? state.vault.read(.bridgeEndpoint, as: BridgeEndpoint.self)
        clients = ClientConnector.rows()
        Task { batches = await state.board.all() }
    }

    /// Stops a batch at once: taking power away needs no Touch ID.
    /// Goes on with a batch approved before Postern quit, after Touch ID.
    func resumeBatch(_ id: String) {
        Task {
            let state = CoreState.shared
            await BatchResumer(board: state.board, desk: state.desk, backend: LiveBackend(), ledger: state.ledger,
                               policy: { CoreState.shared.policy }).resume(id)
            batches = await state.board.all()
        }
    }

    func cancelBatch(_ id: String) {
        Task {
            await CoreState.shared.board.cancel(id)
            batches = await CoreState.shared.board.all()
        }
    }

    func loadMailboxes() async {
        guard isLive, let backend = CoreState.shared.backend else { return }
        mailboxState = .loading
        do {
            mailboxes = try await backend.listMailboxes().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            mailboxState = .loaded
        } catch let error as PosternError {
            mailboxState = .failed(KitText.error(error))
        } catch {
            mailboxState = .failed(String(localized: "Postern couldn't list your mailboxes."))
        }
    }

    // MARK: Policy

    /// Applies a change. Anything that gives apps more power waits for Touch ID first; taking power away is
    /// immediate.
    func update(_ reason: String, _ change: (inout Policy) -> Void) async {
        guard isLive else { return }
        let old = CoreState.shared.policy
        var new = old
        change(&new)
        guard new != old else { return }
        if new.addsPower(over: old) {
            switch await Authenticator.confirm(reason, allowPassword: old.allowPasswordFallback) {
            case .confirmed: break
            case .cancelled: refresh(); return
            case .unavailable:
                notice = String(localized: "Touch ID isn't available right now. Open the lid or connect your Apple Watch, or allow the Mac password in Security.")
                refresh()
                return
            }
        }
        do {
            try PolicyStore(vault: CoreState.shared.vault).save(new)
            notice = nil
        } catch {
            notice = String(localized: "Postern couldn't save this change.")
        }
        CoreState.shared.reloadPolicy()
        refresh()
    }

    /// Turns a whole tier on or off at once: one Touch ID for all of it.
    func setTier(_ tier: Tier, enabled: Bool) async {
        let tools = ToolID.switchable.filter { $0.tier == tier }
        await update(String(localized: "let your apps \(TierCopy.for(tier).verb)", comment: "Touch ID: “Postern” is trying to …")) { policy in
            if enabled { policy.enabledTools.formUnion(tools) } else { policy.enabledTools.subtract(tools) }
        }
    }

    func setTool(_ tool: ToolID, enabled: Bool) async {
        await update(String(localized: "let your apps \(ToolCopy.for(tool).verb)", comment: "Touch ID: “Postern” is trying to …")) { policy in
            if enabled { policy.enabledTools.insert(tool) } else { policy.enabledTools.remove(tool) }
        }
    }

    func setMailbox(_ name: String, visible: Bool) async {
        await update(String(localized: "show \(name) to your apps", comment: "Touch ID: “Postern” is trying to … (a mailbox name)")) { policy in
            if visible { policy.hiddenMailboxes.remove(name) } else { policy.hiddenMailboxes.insert(name) }
        }
    }

    func setPaused(_ paused: Bool) async {
        await update(String(localized: "resume Postern", comment: "Touch ID: “Postern” is trying to …")) { $0.paused = paused }
    }

    func setPauseWhenLocked(_ value: Bool) async {
        await update(String(localized: "stop pausing Postern when the screen locks", comment: "Touch ID: “Postern” is trying to …")) { $0.pauseWhenLocked = value }
    }

    func setLimits(perHour: Int, perDay: Int) async {
        await update(String(localized: "let your apps send more emails", comment: "Touch ID: “Postern” is trying to …")) { policy in
            policy.sendsPerHour = max(1, min(perHour, 300))
            policy.sendsPerDay = max(policy.sendsPerHour, min(perDay, 1000))
        }
    }

    func trust(_ email: String) async {
        let address = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard Self.looksLikeAnAddress(address) else { notice = String(localized: "\(email) is not an email address."); return }
        await update(String(localized: "send to \(address) without asking", comment: "Touch ID: “Postern” is trying to …")) { $0.trustedRecipients.insert(address) }
    }

    func untrust(_ email: String) async {
        await update("") { $0.trustedRecipients.remove(email) }
    }

    func allow(_ email: String) async {
        let address = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard Self.looksLikeAnAddress(address) else { notice = String(localized: "\(email) is not an email address."); return }
        await update(String(localized: "let your apps send to \(address)", comment: "Touch ID: “Postern” is trying to …")) { $0.allowedRecipients.insert(address) }
    }

    func disallow(_ email: String) async {
        await update(String(localized: "let your apps send to anyone", comment: "Touch ID: “Postern” is trying to …")) { $0.allowedRecipients.remove(email) }
    }

    func addSender(_ email: String) async {
        let address = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard Self.looksLikeAnAddress(address) else { notice = String(localized: "\(email) is not an email address."); return }
        await update(String(localized: "let your apps send from \(address)", comment: "Touch ID: “Postern” is trying to …")) { $0.senderAddresses.insert(address) }
    }

    func removeSender(_ email: String) async {
        await update("") { $0.senderAddresses.remove(email) }
    }

    static func looksLikeAnAddress(_ text: String) -> Bool {
        text.wholeMatch(of: #/[^@\s]+@[^@\s]+\.[A-Za-z]{2,}/#) != nil
    }

    func setPasswordFallback(_ value: Bool) async {
        await update(String(localized: "allow your Mac password for Postern", comment: "Touch ID: “Postern” is trying to …")) { $0.allowPasswordFallback = value }
    }

    func showOutbox() {
        guard isLive else { return }
        PosternFolders.prepare()
        NSWorkspace.shared.activateFileViewerSelecting([PosternFolders.outbox])
    }

    // MARK: Apps

    func connect(_ row: ClientRow) {
        guard isLive else { return }
        do {
            try ClientConnector.connect(row.target)
            notice = String(localized: "\(row.target.title) is connected. Restart it, or open a new session, to see Postern.")
        } catch {
            // The sandbox lets Postern write each app's settings file, but not create a folder or a file it cannot
            // reach: the entry goes to the clipboard instead, to paste by hand.
            let snippet: SetupSnippet = switch row.target.kind {
            case .codex: .toml
            case .vscode: .vscode
            default: .json
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(snippet.text(relayPath: ClientConnector.relayPath), forType: .string)
            let path = "~/" + row.target.fileURL.path.replacingOccurrences(of: ClientConnector.realHome.path + "/", with: "")
            notice = String(localized: "Postern couldn't write \(row.target.title)'s settings. Its entry is on the clipboard: paste it into \(path).")
        }
        refresh()
    }

    func addProfile() {
        guard isLive, ClientConnector.addProfile() != nil else { return }
        refresh()
    }
}

/// How each tier is described: a name, a symbol and a color that stay the same everywhere.
struct TierCopy {
    let title: String
    let verb: String
    let symbol: String
    let summary: String

    static func `for`(_ tier: Tier) -> TierCopy {
        switch tier {
        case .read: TierCopy(title: String(localized: "tier.read", defaultValue: "Read", comment: "A tier of tools, as a heading"), verb: String(localized: "read your mail", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"), symbol: "envelope.open",
                             summary: String(localized: "List, search and read. Every message is cleaned first."))
        case .organize: TierCopy(title: String(localized: "tier.organize", defaultValue: "Organize", comment: "A tier of tools, as a heading"), verb: String(localized: "organize your mail", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"), symbol: "folder",
                                 summary: String(localized: "Flags, folders, labels. Never to Trash or Spam."))
        case .draft: TierCopy(title: String(localized: "tier.draft", defaultValue: "Drafts", comment: "A tier of tools, as a heading"), verb: String(localized: "write drafts", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"), symbol: "square.and.pencil",
                              summary: String(localized: "Write and change drafts. Nothing is sent."))
        case .send: TierCopy(title: String(localized: "tier.send", defaultValue: "Send", comment: "A tier of tools, as a heading"), verb: String(localized: "send email", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"), symbol: "paperplane",
                             summary: String(localized: "Every email waits for you on a panel, and leaves only after Touch ID."))
        case .delete: TierCopy(title: String(localized: "tier.delete", defaultValue: "Delete", comment: "A tier of tools, as a heading"), verb: String(localized: "delete mail", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"), symbol: "trash",
                               summary: String(localized: "Each deletion lists every message and needs Touch ID."))
        }
    }
}

/// How each tool is described to the user: what it lets an app do, and what could go wrong.
struct ToolCopy {
    let title: String
    let verb: String
    let allows: String
    let risk: String

    static func `for`(_ tool: ToolID) -> ToolCopy {
        switch tool {
        case .listMailboxes:
            ToolCopy(title: String(localized: "List mailboxes"), verb: String(localized: "list your mailboxes", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "See your folders and labels, with how many messages they hold."),
                     risk: String(localized: "Folder names can say a lot about your life."))
        case .searchMessages:
            ToolCopy(title: String(localized: "Search messages"), verb: String(localized: "search your mail", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "Find messages by sender, recipient, subject, words or date."),
                     risk: String(localized: "The app sees the senders and subjects of what it finds."))
        case .getMessage:
            ToolCopy(title: String(localized: "Read messages"), verb: String(localized: "read your messages", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "Open a message: its text, links and attachment names."),
                     risk: String(localized: "Whatever you can read in a message, the app can read."))
        case .getThread:
            ToolCopy(title: String(localized: "Read conversations"), verb: String(localized: "read your conversations", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "Follow a conversation across folders."),
                     risk: String(localized: "Like reading messages, for every message of the conversation."))
        case .markRead:
            ToolCopy(title: String(localized: "Mark as read"), verb: String(localized: "mark your mail as read", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "Mark messages as read."),
                     risk: String(localized: "You could miss a message the app marked as read."))
        case .markUnread:
            ToolCopy(title: String(localized: "Mark as unread"), verb: String(localized: "mark your mail as unread", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "Mark messages as unread, to come back to them."),
                     risk: String(localized: "Your unread counts change."))
        case .setStarred:
            ToolCopy(title: String(localized: "tool.star", defaultValue: "Star", comment: "A tool's name, as an action"), verb: String(localized: "star your mail", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "Add or remove the star on messages."),
                     risk: String(localized: "Your Starred view changes."))
        case .moveMessages:
            ToolCopy(title: String(localized: "tool.move", defaultValue: "Move", comment: "A tool's name, as an action"), verb: String(localized: "move your mail", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "Move messages to Inbox, Archive or one of your folders. Labels stay."),
                     risk: String(localized: "A message moved to the wrong folder can be hard to find. Never to Trash or Spam."))
        case .archiveMessages:
            ToolCopy(title: String(localized: "tool.archive", defaultValue: "Archive", comment: "A tool's name, as an action"), verb: String(localized: "archive your mail", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "Move messages to Archive. Labels stay."),
                     risk: String(localized: "Archived messages leave your Inbox."))
        case .addLabel:
            ToolCopy(title: String(localized: "Add labels"), verb: String(localized: "label your mail", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "Add one of your labels to messages. They stay in their folder."),
                     risk: String(localized: "Your label views change."))
        case .removeLabel:
            ToolCopy(title: String(localized: "Remove labels"), verb: String(localized: "remove labels from your mail", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "Remove a label from messages. They stay in their folder."),
                     risk: String(localized: "Your label views change."))
        case .createMailbox:
            ToolCopy(title: String(localized: "Create folders and labels"), verb: String(localized: "create folders and labels", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "Create a new folder or label."),
                     risk: String(localized: "New folders and labels appear in Proton on all your devices."))
        case .createDraft:
            ToolCopy(title: String(localized: "Write drafts"), verb: String(localized: "write drafts", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "Save drafts in Drafts. Nothing is sent."),
                     risk: String(localized: "Drafts sync to Proton on all your devices."))
        case .createDrafts:
            ToolCopy(title: String(localized: "Write drafts from a template"), verb: String(localized: "write several drafts at once", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "Save up to 500 drafts at once from one template or a spreadsheet in the outbox, such as one application per company with its own letter."),
                     risk: String(localized: "It fills your Drafts folder; nothing is sent."))
        case .updateDraft:
            ToolCopy(title: String(localized: "Change drafts"), verb: String(localized: "change drafts", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "Rewrite a draft's recipients, subject or text."),
                     risk: String(localized: "It can change a draft you wrote yourself."))
        case .deleteDraft:
            ToolCopy(title: String(localized: "Delete drafts"), verb: String(localized: "delete drafts", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "Delete a draft from Drafts. Claude Code also asks you each time."),
                     risk: String(localized: "A deleted draft is gone for good."))
        case .sendMessage:
            ToolCopy(title: String(localized: "Send new emails"), verb: String(localized: "send emails", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "Write and send an email. Each one waits for you on the approval panel."),
                     risk: String(localized: "Once you approve, it leaves for good."))
        case .replyToMessage:
            ToolCopy(title: String(localized: "tool.reply", defaultValue: "Reply", comment: "A tool's name, as an action"), verb: String(localized: "reply to your mail", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "Answer a message, quoting it. Each reply waits for your approval."),
                     risk: String(localized: "Replies can go to a Reply-To address; the panel shows when it differs."))
        case .forwardMessage:
            ToolCopy(title: String(localized: "tool.forward", defaultValue: "Forward", comment: "A tool's name, as an action"), verb: String(localized: "forward your mail", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "Forward a message's text to someone. Each one waits for your approval."),
                     risk: String(localized: "The forwarded text leaves your mailbox."))
        case .sendDraft:
            ToolCopy(title: String(localized: "Send drafts"), verb: String(localized: "send drafts", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "Send a draft as it is, after your approval, then remove it from Drafts."),
                     risk: String(localized: "Once you approve, it leaves for good."))
        case .sendDrafts:
            ToolCopy(title: String(localized: "Send drafts together"), verb: String(localized: "send several drafts at once", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "Send up to 5,000 drafts at once: one panel lists them all, you untick any, one Touch ID sends the rest, one by one within your limits."),
                     risk: String(localized: "One approval sends every email left ticked, even hours later when your limits make room. You can stop a batch here at any time."))
        case .readAttachment:
            ToolCopy(title: String(localized: "Read attachments"), verb: String(localized: "read the text of your attachments", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "Read the text of PDFs, scans, photos of documents, spreadsheets and text files attached to your mail, without saving them."),
                     risk: String(localized: "Apps read what your attachments say, like reading the messages themselves."))
        case .awaitingReply:
            ToolCopy(title: String(localized: "Find emails awaiting a reply"), verb: String(localized: "see who has not answered you", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "List the people you wrote to who have not answered yet, such as job applications to follow up."),
                     risk: String(localized: "Apps learn who you wrote to and who answered, like reading Sent."))
        case .listOutbox:
            ToolCopy(title: String(localized: "See the outbox"), verb: String(localized: "see the files in your outbox", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "List the files you put in Downloads › Postern › Outbox."),
                     risk: String(localized: "Apps learn the names of those files."))
        case .batchStatus:
            ToolCopy(title: String(localized: "Follow batches"), verb: String(localized: "follow batches", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "See how a batch of drafts or emails stands."),
                     risk: String(localized: "None beyond the batch tools."))
        case .cancelBatch:
            ToolCopy(title: String(localized: "Stop batches"), verb: String(localized: "stop batches", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "Stop a batch before it ends."),
                     risk: String(localized: "None: stopping only takes power away."))
        case .listAddresses:
            ToolCopy(title: String(localized: "See your sender addresses"), verb: String(localized: "see which addresses you send from", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "List your account's address and the aliases you added under Send from."),
                     risk: String(localized: "Apps learn your aliases."))
        case .saveAttachment:
            ToolCopy(title: String(localized: "Save attachments"), verb: String(localized: "save attachments to your Mac", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "Save an attachment to Downloads › Postern, marked as downloaded."),
                     risk: String(localized: "A file from a stranger lands on your Mac. macOS checks it before it opens."))
        case .trashMessages:
            ToolCopy(title: String(localized: "Move to Trash"), verb: String(localized: "move mail to Trash", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "Move messages to Trash. Each time, you approve the list with Touch ID."),
                     risk: String(localized: "Messages leave your folders; you can move them back until Trash is emptied."))
        case .deletePermanently:
            ToolCopy(title: String(localized: "Erase for good"), verb: String(localized: "erase mail for good", comment: "Completes the Touch ID sentence “Postern” is trying to let your apps …"),
                     allows: String(localized: "Erase messages already in Trash or Spam. Each time, with Touch ID."),
                     risk: String(localized: "Erased messages cannot be recovered."))
        }
    }
}
