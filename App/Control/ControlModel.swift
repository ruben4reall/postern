import AppKit
import Foundation
import Observation
import PosternAudit
import PosternBridge
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
            case .overview: "Overview"
            case .tools: "Tools"
            case .mailboxes: "Mailboxes"
            case .clients: "Apps"
            case .activity: "Activity"
            case .security: "Security"
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
            mailboxState = .failed(error.message)
        } catch {
            mailboxState = .failed("Postern couldn't list your mailboxes.")
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
                notice = "Touch ID isn't available right now. Open the lid or connect your Apple Watch, or allow the Mac password in Security."
                refresh()
                return
            }
        }
        do {
            try PolicyStore(vault: CoreState.shared.vault).save(new)
            notice = nil
        } catch {
            notice = "Postern couldn't save this change."
        }
        CoreState.shared.reloadPolicy()
        refresh()
    }

    /// Turns a whole tier on or off at once: one Touch ID for all of it.
    func setTier(_ tier: Tier, enabled: Bool) async {
        let tools = ToolID.switchable.filter { $0.tier == tier }
        await update("let your apps \(TierCopy.for(tier).verb)") { policy in
            if enabled { policy.enabledTools.formUnion(tools) } else { policy.enabledTools.subtract(tools) }
        }
    }

    func setTool(_ tool: ToolID, enabled: Bool) async {
        await update("let your apps \(ToolCopy.for(tool).verb)") { policy in
            if enabled { policy.enabledTools.insert(tool) } else { policy.enabledTools.remove(tool) }
        }
    }

    func setMailbox(_ name: String, visible: Bool) async {
        await update("show \(name) to your apps") { policy in
            if visible { policy.hiddenMailboxes.remove(name) } else { policy.hiddenMailboxes.insert(name) }
        }
    }

    func setPaused(_ paused: Bool) async {
        await update("resume Postern") { $0.paused = paused }
    }

    func setPauseWhenLocked(_ value: Bool) async {
        await update("stop pausing Postern when the screen locks") { $0.pauseWhenLocked = value }
    }

    func setLimits(perHour: Int, perDay: Int) async {
        await update("let your apps send more emails") { policy in
            policy.sendsPerHour = max(1, min(perHour, 300))
            policy.sendsPerDay = max(policy.sendsPerHour, min(perDay, 1000))
        }
    }

    func trust(_ email: String) async {
        let address = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard Self.looksLikeAnAddress(address) else { notice = "\(email) is not an email address."; return }
        await update("send to \(address) without asking") { $0.trustedRecipients.insert(address) }
    }

    func untrust(_ email: String) async {
        await update("") { $0.trustedRecipients.remove(email) }
    }

    func allow(_ email: String) async {
        let address = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard Self.looksLikeAnAddress(address) else { notice = "\(email) is not an email address."; return }
        await update("let your apps send to \(address)") { $0.allowedRecipients.insert(address) }
    }

    func disallow(_ email: String) async {
        await update("let your apps send to anyone") { $0.allowedRecipients.remove(email) }
    }

    func addSender(_ email: String) async {
        let address = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard Self.looksLikeAnAddress(address) else { notice = "\(email) is not an email address."; return }
        await update("let your apps send from \(address)") { $0.senderAddresses.insert(address) }
    }

    func removeSender(_ email: String) async {
        await update("") { $0.senderAddresses.remove(email) }
    }

    static func looksLikeAnAddress(_ text: String) -> Bool {
        text.wholeMatch(of: #/[^@\s]+@[^@\s]+\.[A-Za-z]{2,}/#) != nil
    }

    func setPasswordFallback(_ value: Bool) async {
        await update("allow your Mac password for Postern") { $0.allowPasswordFallback = value }
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
            notice = "\(row.target.title) is connected. Restart it, or open a new session, to see Postern."
        } catch {
            notice = "Postern couldn't update \(row.target.title)'s settings."
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
        case .read: TierCopy(title: "Read", verb: "read your mail", symbol: "envelope.open",
                             summary: "List, search and read. Every message is cleaned first.")
        case .organize: TierCopy(title: "Organize", verb: "organize your mail", symbol: "folder",
                                 summary: "Flags, folders, labels. Never to Trash or Spam.")
        case .draft: TierCopy(title: "Drafts", verb: "write drafts", symbol: "square.and.pencil",
                              summary: "Write and change drafts. Nothing is sent.")
        case .send: TierCopy(title: "Send", verb: "send email", symbol: "paperplane",
                             summary: "Every email waits for you on a panel, and leaves only after Touch ID.")
        case .delete: TierCopy(title: "Delete", verb: "delete mail", symbol: "trash",
                               summary: "Each deletion lists every message and needs Touch ID.")
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
            ToolCopy(title: "List mailboxes", verb: "list your mailboxes",
                     allows: "See your folders and labels, with how many messages they hold.",
                     risk: "Folder names can say a lot about your life.")
        case .searchMessages:
            ToolCopy(title: "Search messages", verb: "search your mail",
                     allows: "Find messages by sender, recipient, subject, words or date.",
                     risk: "The app sees the senders and subjects of what it finds.")
        case .getMessage:
            ToolCopy(title: "Read messages", verb: "read your messages",
                     allows: "Open a message: its text, links and attachment names.",
                     risk: "Whatever you can read in a message, the app can read.")
        case .getThread:
            ToolCopy(title: "Read conversations", verb: "read your conversations",
                     allows: "Follow a conversation across folders.",
                     risk: "Like reading messages, for every message of the conversation.")
        case .markRead:
            ToolCopy(title: "Mark as read", verb: "mark your mail as read",
                     allows: "Mark messages as read.",
                     risk: "You could miss a message the app marked as read.")
        case .markUnread:
            ToolCopy(title: "Mark as unread", verb: "mark your mail as unread",
                     allows: "Mark messages as unread, to come back to them.",
                     risk: "Your unread counts change.")
        case .setStarred:
            ToolCopy(title: "Star", verb: "star your mail",
                     allows: "Add or remove the star on messages.",
                     risk: "Your Starred view changes.")
        case .moveMessages:
            ToolCopy(title: "Move", verb: "move your mail",
                     allows: "Move messages to Inbox, Archive or one of your folders. Labels stay.",
                     risk: "A message moved to the wrong folder can be hard to find. Never to Trash or Spam.")
        case .archiveMessages:
            ToolCopy(title: "Archive", verb: "archive your mail",
                     allows: "Move messages to Archive. Labels stay.",
                     risk: "Archived messages leave your Inbox.")
        case .addLabel:
            ToolCopy(title: "Add labels", verb: "label your mail",
                     allows: "Add one of your labels to messages. They stay in their folder.",
                     risk: "Your label views change.")
        case .removeLabel:
            ToolCopy(title: "Remove labels", verb: "remove labels from your mail",
                     allows: "Remove a label from messages. They stay in their folder.",
                     risk: "Your label views change.")
        case .createMailbox:
            ToolCopy(title: "Create folders and labels", verb: "create folders and labels",
                     allows: "Create a new folder or label.",
                     risk: "New folders and labels appear in Proton on all your devices.")
        case .createDraft:
            ToolCopy(title: "Write drafts", verb: "write drafts",
                     allows: "Save drafts in Drafts. Nothing is sent.",
                     risk: "Drafts sync to Proton on all your devices.")
        case .createDrafts:
            ToolCopy(title: "Write drafts from a template", verb: "write several drafts at once",
                     allows: "Save up to 500 drafts at once from one template or a spreadsheet in the outbox, such as one application per company with its own letter.",
                     risk: "It fills your Drafts folder; nothing is sent.")
        case .updateDraft:
            ToolCopy(title: "Change drafts", verb: "change drafts",
                     allows: "Rewrite a draft's recipients, subject or text.",
                     risk: "It can change a draft you wrote yourself.")
        case .deleteDraft:
            ToolCopy(title: "Delete drafts", verb: "delete drafts",
                     allows: "Delete a draft from Drafts. Claude Code also asks you each time.",
                     risk: "A deleted draft is gone for good.")
        case .sendMessage:
            ToolCopy(title: "Send new emails", verb: "send emails",
                     allows: "Write and send an email. Each one waits for you on the approval panel.",
                     risk: "Once you approve, it leaves for good.")
        case .replyToMessage:
            ToolCopy(title: "Reply", verb: "reply to your mail",
                     allows: "Answer a message, quoting it. Each reply waits for your approval.",
                     risk: "Replies can go to a Reply-To address; the panel shows when it differs.")
        case .forwardMessage:
            ToolCopy(title: "Forward", verb: "forward your mail",
                     allows: "Forward a message's text to someone. Each one waits for your approval.",
                     risk: "The forwarded text leaves your mailbox.")
        case .sendDraft:
            ToolCopy(title: "Send drafts", verb: "send drafts",
                     allows: "Send a draft as it is, after your approval, then remove it from Drafts.",
                     risk: "Once you approve, it leaves for good.")
        case .sendDrafts:
            ToolCopy(title: "Send drafts together", verb: "send several drafts at once",
                     allows: "Send up to 5,000 drafts at once: one panel lists them all, you untick any, one Touch ID sends the rest, one by one within your limits.",
                     risk: "One approval sends every email left ticked, even hours later when your limits make room. You can stop a batch here at any time.")
        case .readAttachment:
            ToolCopy(title: "Read attachments", verb: "read the text of your attachments",
                     allows: "Read the text of PDFs, scans, photos of documents, spreadsheets and text files attached to your mail, without saving them.",
                     risk: "Apps read what your attachments say, like reading the messages themselves.")
        case .awaitingReply:
            ToolCopy(title: "Find emails awaiting a reply", verb: "see who has not answered you",
                     allows: "List the people you wrote to who have not answered yet, such as job applications to follow up.",
                     risk: "Apps learn who you wrote to and who answered, like reading Sent.")
        case .listOutbox:
            ToolCopy(title: "See the outbox", verb: "see the files in your outbox",
                     allows: "List the files you put in Downloads › Postern › Outbox.",
                     risk: "Apps learn the names of those files.")
        case .batchStatus:
            ToolCopy(title: "Follow batches", verb: "follow batches",
                     allows: "See how a batch of drafts or emails stands.",
                     risk: "None beyond the batch tools.")
        case .cancelBatch:
            ToolCopy(title: "Stop batches", verb: "stop batches",
                     allows: "Stop a batch before it ends.",
                     risk: "None: stopping only takes power away.")
        case .listAddresses:
            ToolCopy(title: "See your sender addresses", verb: "see which addresses you send from",
                     allows: "List your account's address and the aliases you added under Send from.",
                     risk: "Apps learn your aliases.")
        case .saveAttachment:
            ToolCopy(title: "Save attachments", verb: "save attachments to your Mac",
                     allows: "Save an attachment to Downloads › Postern, marked as downloaded.",
                     risk: "A file from a stranger lands on your Mac. macOS checks it before it opens.")
        case .trashMessages:
            ToolCopy(title: "Move to Trash", verb: "move mail to Trash",
                     allows: "Move messages to Trash. Each time, you approve the list with Touch ID.",
                     risk: "Messages leave your folders; you can move them back until Trash is emptied.")
        case .deletePermanently:
            ToolCopy(title: "Erase for good", verb: "erase mail for good",
                     allows: "Erase messages already in Trash or Spam. Each time, with Touch ID.",
                     risk: "Erased messages cannot be recovered.")
        }
    }
}
