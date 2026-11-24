#if os(Linux)
import Foundation
import PosternModel
import PosternPlatform
import PosternPolicy

/// Sample data for screenshots: a mailbox like many, and apps at work. Nothing here comes from the core.
enum Demo {
    static func fill(_ model: Model) {
        var policy = Policy(enabledTools: Policy.readOnly.enabledTools.union([.getMessages, .topSenders, .awaitingReply, .readAttachment,
                                                                               .markRead, .archiveMessages, .moveMessages, .createDraft, .draftReply,
                                                                               .sendMessage, .replyToMessage]))
        policy.sendsPerHour = 20
        policy.sendsPerDay = 100
        policy.hiddenMailboxes = ["Folders/Health"]
        policy.trustedRecipients = ["accounting@studio.example"]
        let now = Date()
        model.status = ControlWire.Status(
            version: CoreService.version, processID: 4242, system: "linux", configured: true, problem: nil, account: "anna@proton.me",
            imapPort: 1143, smtpPort: 1025, policy: policy, sendsLastHour: 2, sendsLastDay: 9,
            connectedApps: ["Claude Code", "Claude Code", "Cursor"],
            protonLimits: [], approvalsReady: true, approvalMethod: "polkit", pendingApprovals: 0
        )
        model.tools = ToolID.switchable.map { tool in
            let text = ToolText.for(tool)
            return ControlWire.ToolInfo(id: tool.rawValue, tier: tool.tier.rawValue, title: text.title, summary: text.allows, risk: text.risk,
                                        enabled: policy.enabledTools.contains(tool))
        }
        model.mailboxes = [("INBOX", "system"), ("Drafts", "system"), ("Sent", "system"), ("Archive", "system"), ("Spam", "system"),
                           ("Trash", "system"), ("All Mail", "virtual"), ("Starred", "virtual"), ("Folders/Clients", "folder"),
                           ("Folders/Health", "folder"), ("Folders/Invoices", "folder"), ("Labels/To follow up", "label")]
            .map { ControlWire.MailboxRow(name: $0.0, kind: $0.1, hidden: policy.hiddenMailboxes.contains($0.0)) }
        model.apps = [
            ("claudeCode", "Claude Code", "~/.claude.json", true, "connected"),
            ("claudeDesktop", "Claude Desktop", "~/.config/Claude/claude_desktop_config.json", true, "notConnected"),
            ("codex", "Codex and ChatGPT", "~/.codex/config.toml", false, "notConnected"),
            ("cursor", "Cursor", "~/.cursor/mcp.json", true, "connected"),
            ("vscode", "VS Code (Copilot)", "~/.copilot/mcp-config.json", true, "notConnected"),
            ("windsurf", "Windsurf", "~/.config/devin/mcp_config.json", false, "notConnected"),
            ("geminiCLI", "Gemini CLI", "~/.gemini/settings.json", true, "notConnected"),
            ("kiro", "Kiro", "~/.kiro/settings/mcp.json", false, "notConnected"),
            ("cline", "Cline", "~/.cline/data/settings/cline_mcp_settings.json", false, "notConnected"),
        ].map { ControlWire.AppRow(id: $0.0, title: $0.1, path: $0.2, installed: $0.3, status: $0.4) }
        let calls: [(String, String, String, Int?, Double)] = [
            ("Claude Code", "search_messages", "ok", 20, 300), ("Claude Code", "get_messages", "ok", 8, 280),
            ("Cursor", "top_senders", "ok", 25, 2000), ("Claude Code", "draft_reply", "ok", nil, 3600),
            ("Claude Code", "send_message", "approval_rejected", nil, 4000), ("Claude Code", "reply_to_message", "ok", nil, 5000),
            ("Cursor", "delete_permanently", "policy_disabled", nil, 90_000), ("Claude Code", "archive_messages", "ok", 14, 92_000),
        ]
        model.activity = calls.map { ControlWire.ActivityRow(date: now.addingTimeInterval(-$0.4), client: $0.0, tool: $0.1, outcome: $0.2, items: $0.3) }
        model.batches = [ControlWire.BatchRow(id: "b7", kind: "sends", client: "Claude Code", created: now.addingTimeInterval(-900), total: 40, done: 12,
                                              waiting: 28, failed: 0, phase: "waiting", reason: "Waiting for room in the hourly limit (20 an hour).", interrupted: false)]
    }
}

/// Opens a sample approval window, for screenshots.
enum DemoApproval {
    static func schedule(_ app: PosternApp) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            onMain {
                let email = ControlWire.Email(
                    id: "e1", from: "anna@proton.me", to: ["Billing <billing@pay-studio.example>"], cc: ["team@studio.example"], bcc: [],
                    subject: "Re: Invoice for September", body: "Hello,\n\nThanks for the invoice. The transfer will leave on Monday.\n\nBest,\nAnna",
                    quoted: "On Fri 17 Oct 2026, Studio <billing@studio.example> wrote:\n> Please find the invoice attached.\n> Payment details changed, use the new account below.",
                    attachments: [ControlWire.Attachment(name: "remittance.pdf", type: "application/pdf", size: 48_210)],
                    badges: ["billing@pay-studio.example": ["replyToDiffers", "firstContact", "cameFromEmail"]], missingAttachment: nil
                )
                app.showApproval(ControlWire.Approval(id: "demo", kind: .email, client: "Claude Code", tool: "reply_to_message",
                                                      deadline: Date().addingTimeInterval(95), context: "Reply to Studio: Invoice for September",
                                                      email: email, batch: nil, deletion: nil, permanent: false))
            }
        }
    }
}
#endif
