import PosternModel

/// What each tool lets apps do, in the words of the interface. The Mac app has the same text, translated.
public struct ToolText: Sendable {
    public let title: String
    /// Completes "Postern is trying to let your apps …" in the system's authentication prompt.
    public let verb: String
    public let allows: String
    public let risk: String

    public static func `for`(_ tool: ToolID) -> ToolText {
        switch tool {
        case .listMailboxes: ToolText(title: "List mailboxes", verb: "list your mailboxes", allows: "See your folders and labels, with how many messages they hold.", risk: "Folder names can say a lot about your life.")
        case .searchMessages: ToolText(title: "Search messages", verb: "search your mail", allows: "Find messages by sender, recipient, subject, words or date.", risk: "The app sees the senders and subjects of what it finds.")
        case .getMessage: ToolText(title: "Read messages", verb: "read your messages", allows: "Open a message: its text, links and attachment names.", risk: "Whatever you can read in a message, the app can read.")
        case .getThread: ToolText(title: "Read conversations", verb: "read your conversations", allows: "Follow a conversation across folders.", risk: "Like reading messages, for every message of the conversation.")
        case .getMessages: ToolText(title: "Read several messages at once", verb: "read several messages at once", allows: "Read up to ten messages in one go, to summarize a list of results.", risk: "Like reading messages, ten at a time.")
        case .topSenders: ToolText(title: "See who writes the most", verb: "count who writes to you", allows: "Count the messages of a mailbox by sender, to find the newsletters that fill it.", risk: "Apps learn who writes to you and how often.")
        case .markRead: ToolText(title: "Mark as read", verb: "mark your mail as read", allows: "Mark messages as read.", risk: "You could miss a message the app marked as read.")
        case .markUnread: ToolText(title: "Mark as unread", verb: "mark your mail as unread", allows: "Mark messages as unread, to come back to them.", risk: "Your unread counts change.")
        case .setStarred: ToolText(title: "Star", verb: "star your mail", allows: "Add or remove the star on messages.", risk: "Your Starred view changes.")
        case .moveMessages: ToolText(title: "Move", verb: "move your mail", allows: "Move messages to Inbox, Archive or one of your folders. Labels stay.", risk: "A message moved to the wrong folder can be hard to find. Never to Trash or Spam.")
        case .archiveMessages: ToolText(title: "Archive", verb: "archive your mail", allows: "Move messages to Archive. Labels stay.", risk: "Archived messages leave your Inbox.")
        case .addLabel: ToolText(title: "Add labels", verb: "label your mail", allows: "Add one of your labels to messages. They stay in their folder.", risk: "Your label views change.")
        case .removeLabel: ToolText(title: "Remove labels", verb: "remove labels from your mail", allows: "Remove a label from messages. They stay in their folder.", risk: "Your label views change.")
        case .createMailbox: ToolText(title: "Create folders and labels", verb: "create folders and labels", allows: "Create a new folder or label.", risk: "New folders and labels appear in Proton on all your devices.")
        case .createDraft: ToolText(title: "Write drafts", verb: "write drafts", allows: "Save drafts in Drafts. Nothing is sent.", risk: "Drafts sync to Proton on all your devices.")
        case .createDrafts: ToolText(title: "Write drafts from a template", verb: "write several drafts at once", allows: "Save up to 5,000 drafts at once from one template or a spreadsheet in the outbox, such as one application per company with its own letter.", risk: "It fills your Drafts folder; nothing is sent.")
        case .updateDraft: ToolText(title: "Change drafts", verb: "change drafts", allows: "Rewrite a draft's recipients, subject or text.", risk: "It can change a draft you wrote yourself.")
        case .deleteDraft: ToolText(title: "Delete drafts", verb: "delete drafts", allows: "Delete a draft from Drafts.", risk: "A deleted draft is gone for good.")
        case .draftReply: ToolText(title: "Write replies as drafts", verb: "write replies as drafts", allows: "Save a reply in Drafts, in the same conversation. Nothing is sent.", risk: "Drafts sync to Proton on all your devices.")
        case .draftForward: ToolText(title: "Write forwards as drafts", verb: "write forwards as drafts", allows: "Save a forward in Drafts, with the original's attachments. Nothing is sent.", risk: "Drafts sync to Proton on all your devices.")
        case .sendMessage: ToolText(title: "Send new emails", verb: "send emails", allows: "Write and send an email. Each one waits for you on the approval panel.", risk: "Once you approve, it leaves for good.")
        case .replyToMessage: ToolText(title: "Reply", verb: "reply to your mail", allows: "Answer a message, quoting it. Each reply waits for your approval.", risk: "Replies can go to a Reply-To address; the panel shows when it differs.")
        case .forwardMessage: ToolText(title: "Forward", verb: "forward your mail", allows: "Forward a message's text to someone. Each one waits for your approval.", risk: "The forwarded text leaves your mailbox.")
        case .sendDraft: ToolText(title: "Send drafts", verb: "send drafts", allows: "Send a draft as it is, after your approval, then remove it from Drafts.", risk: "Once you approve, it leaves for good.")
        case .sendDrafts: ToolText(title: "Send drafts together", verb: "send several drafts at once", allows: "Send up to 5,000 drafts at once: one panel lists them all, you untick any, one your approval sends the rest, one by one within your limits.", risk: "One approval sends every email left ticked, even hours later when your limits make room. You can stop a batch here at any time.")
        case .readAttachment: ToolText(title: "Read attachments", verb: "read the text of your attachments", allows: "Read the text of PDFs, scans, photos of documents, spreadsheets and text files attached to your mail, without saving them.", risk: "Apps read what your attachments say, like reading the messages themselves.")
        case .awaitingReply: ToolText(title: "Find emails awaiting a reply", verb: "see who has not answered you", allows: "List the people you wrote to who have not answered yet, such as job applications to follow up.", risk: "Apps learn who you wrote to and who answered, like reading Sent.")
        case .listOutbox: ToolText(title: "See the outbox", verb: "see the files in your outbox", allows: "List the files you put in Downloads › Postern › Outbox.", risk: "Apps learn the names of those files.")
        case .batchStatus: ToolText(title: "Follow batches", verb: "follow batches", allows: "See how a batch of drafts or emails stands.", risk: "None beyond the batch tools.")
        case .cancelBatch: ToolText(title: "Stop batches", verb: "stop batches", allows: "Stop a batch before it ends.", risk: "None: stopping only takes power away.")
        case .listAddresses: ToolText(title: "See your sender addresses", verb: "see which addresses you send from", allows: "List your account's address and the aliases you added under Send from.", risk: "Apps learn your aliases.")
        case .saveAttachment: ToolText(title: "Save attachments", verb: "save attachments to your computer", allows: "Save an attachment to Downloads › Postern, marked as downloaded.", risk: "A file from a stranger lands on your computer, marked as downloaded from the internet.")
        case .trashMessages: ToolText(title: "Move to Trash", verb: "move mail to Trash", allows: "Move messages to Trash. Each time, you approve the list.", risk: "Messages leave your folders; you can move them back until Trash is emptied.")
        case .deletePermanently: ToolText(title: "Erase for good", verb: "erase mail for good", allows: "Erase messages already in Trash or Spam. Each time, you approve it.", risk: "Erased messages cannot be recovered.")
        }
    }
}
