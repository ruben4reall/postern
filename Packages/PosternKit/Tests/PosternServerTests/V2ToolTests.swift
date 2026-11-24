import Foundation
import MCP
import Testing
import PosternModel
import PosternPolicy
import PosternCompose
@testable import PosternApproval
@testable import PosternServer

/// The tools and prompts of Postern 2.
@Suite(.serialized) struct V2ToolTests {
    let everything = Policy(enabledTools: Set(ToolID.allCases))

    func connect(_ policy: Policy? = nil, backend: FakeBackend, intent: ApprovalIntent? = .send) async throws -> Client {
        let presenter = CapturingPresenter(intent)
        let desk = ApprovalDesk(presenter: presenter, authenticator: AlwaysAuthenticated(), timeout: .seconds(5))
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let chosen = policy ?? everything
        let session = Session(transport: serverTransport, backend: backend, version: "test", policy: { chosen },
                              desk: desk, ledger: MemoryLedger(), clientName: { "Claude Code" })
        try await session.start()
        let client = Client(name: "test", version: "1")
        _ = try await client.connect(transport: clientTransport)
        return client
    }

    func text(_ content: [Tool.Content]) -> String {
        content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined()
    }

    func call(_ client: Client, _ name: String, _ arguments: [String: Value]) async throws -> ([Tool.Content], Value?, Bool?) {
        let context: RequestContext<CallTool.Result> = try await client.callTool(name: name, arguments: arguments)
        let result = try await context.value
        return (result.content, result.structuredContent, result.isError)
    }

    func summary(_ uid: UInt32, mailbox: String = "INBOX", from: String, name: String? = nil, unread: Bool = false,
                 day: Int = 0, messageID: String? = nil) -> MessageSummary {
        MessageSummary(id: MessageID(mailbox: mailbox, uidValidity: 1, uid: uid),
                       date: Date(timeIntervalSince1970: 1_790_000_000 + Double(day) * 86_400),
                       from: [Address(name: name, email: from)], to: [Address(name: nil, email: "me@example.ch")], cc: [],
                       subject: "S\(uid)", unread: unread, starred: false, answered: false, size: 10, attachmentCount: 0,
                       messageIDHeader: messageID ?? "<\(uid)@\(mailbox)>", inReplyTo: nil)
    }

    @Test func aReplyDraftStaysInTheConversationWhenItLeavesLater() async throws {
        let backend = FakeBackend()
        let client = try await connect(backend: backend)
        let original = MessageID(mailbox: "INBOX", uidValidity: 1, uid: 77)
        let (content, structured, isError) = try await call(client, "draft_reply", ["id": .string(original.opaque), "body": .string("Thanks, paid today.")])
        #expect(isError != true, "\(text(content))")
        let saved = try #require(backend.lock.withLock { backend.drafts.last })
        #expect(saved.inReplyTo == "<orig@example.com>")
        #expect(saved.subject == "Re: Invoice")
        #expect(backend.lock.withLock { backend.sent }.isEmpty)
        guard case .object(let fields)? = structured, case .string(let draftID)? = fields["draft_id"] else {
            Issue.record("no draft id")
            return
        }
        // Proton dropped In-Reply-To from the stored draft: send_draft puts it back.
        let (sentContent, _, sentError) = try await call(client, "send_draft", ["id": .string(draftID)])
        #expect(sentError != true, "\(text(sentContent))")
        let sent = try #require(backend.lock.withLock { backend.sent }.last)
        #expect(sent.inReplyTo == "<orig@example.com>")
        #expect(sent.references.contains("<orig@example.com>"))
    }

    @Test func aForwardDraftKeepsTheOriginalsFilesAndSendsNothing() async throws {
        let backend = FakeBackend()
        let client = try await connect(backend: backend)
        let original = MessageID(mailbox: "INBOX", uidValidity: 1, uid: 77)
        let (content, _, isError) = try await call(client, "draft_forward", [
            "id": .string(original.opaque), "to": .array([.string("accountant@example.com")]), "note": .string("For the books."),
        ])
        #expect(isError != true, "\(text(content))")
        let saved = try #require(backend.lock.withLock { backend.drafts.last })
        #expect(saved.subject == "Fwd: Invoice")
        #expect(saved.to.map(\.email) == ["accountant@example.com"])
        #expect(backend.lock.withLock { backend.sent }.isEmpty)
    }

    @Test func draftToolsNeedOnlyTheDraftSwitch() async throws {
        let backend = FakeBackend()
        let client = try await connect(Policy(enabledTools: [.draftReply]), backend: backend)
        let (tools, _) = try await client.listTools()
        #expect(Set(tools.map(\.name)) == ["draft_reply", "list_outbox"])
        #expect(tools.first { $0.name == "draft_reply" }?.annotations.destructiveHint == false)
    }

    @Test func readsSeveralMessagesAndSaysWhichOnesFailed() async throws {
        let backend = FakeBackend()
        let client = try await connect(backend: backend)
        let (content, structured, isError) = try await call(client, "get_messages", [
            "ids": .array([.string(backend.inbox.opaque), .string("not-an-id")]), "max_chars": .int(500),
        ])
        #expect(isError != true)
        #expect(text(content).hasPrefix("Read 1 of 2 message(s)."))
        guard case .object(let fields)? = structured, case .array(let items)? = fields["messages"] else {
            Issue.record("no messages")
            return
        }
        #expect(items.count == 2)
        let tooMany = Array(repeating: Value.string(backend.inbox.opaque), count: ReadTools.maxBatchRead + 1)
        let (_, _, refused) = try await call(client, "get_messages", ["ids": .array(tooMany)])
        #expect(refused == true)
    }

    @Test func countsWhoWritesTheMost() async throws {
        let backend = FakeBackend()
        backend.searchResults["INBOX"] = [
            summary(1, from: "news@shop.example", name: "Shop", unread: true, day: 1),
            summary(2, from: "news@shop.example", name: "Shop", unread: true, day: 3),
            summary(3, from: "deals@shop.example", day: 2),
            summary(4, from: "anna@example.com", name: "Anna", day: 4),
        ]
        let client = try await connect(backend: backend)
        let (content, structured, isError) = try await call(client, "top_senders", ["mailbox": .string("INBOX")])
        #expect(isError != true, "\(text(content))")
        guard case .object(let fields)? = structured, case .array(let ranking)? = fields["ranking"],
              case .object(let first)? = ranking.first else {
            Issue.record("no ranking")
            return
        }
        #expect(first["untrusted_address"] == .string("news@shop.example"))
        #expect(first["messages"] == .int(2) && first["unread"] == .int(2))
        #expect(text(content).contains("<postern-untrusted"))

        let (_, byDomain, _) = try await call(client, "top_senders", ["mailbox": .string("INBOX"), "by": .string("domain")])
        guard case .object(let domainFields)? = byDomain, case .array(let domains)? = domainFields["ranking"],
              case .object(let top)? = domains.first else {
            Issue.record("no domain ranking")
            return
        }
        #expect(top["untrusted_domain"] == .string("shop.example") && top["messages"] == .int(3))
    }

    @Test func searchesEveryVisibleFolderWhenAllMailIsHidden() async throws {
        let backend = FakeBackend()
        backend.names = ["INBOX", "Archive", "Folders/Secret", "Labels/Work", "All Mail", "Starred"]
        backend.searchResults["INBOX"] = [summary(1, from: "a@example.com", day: 1)]
        backend.searchResults["Archive"] = [summary(2, mailbox: "Archive", from: "b@example.com", day: 5)]
        backend.searchResults["Labels/Work"] = [summary(9, mailbox: "Labels/Work", from: "a@example.com", day: 1, messageID: "<1@INBOX>")]
        let client = try await connect(Policy(enabledTools: [.searchMessages], hiddenMailboxes: ["Folders/Secret"]), backend: backend)
        let (content, structured, isError) = try await call(client, "search_messages", ["mailbox": .string("*")])
        #expect(isError != true, "\(text(content))")
        let searched = Set(backend.lock.withLock { backend.searches }.map(\.mailbox))
        #expect(searched == ["INBOX", "Archive"])
        guard case .object(let fields)? = structured, case .array(let messages)? = fields["messages"] else {
            Issue.record("no messages")
            return
        }
        #expect(messages.count == 2)
        #expect(text(content).contains("every mailbox Postern can see"))
    }

    @Test func searchesAllMailWhenNothingIsHidden() async throws {
        let backend = FakeBackend()
        backend.searchResults["All Mail"] = [summary(1, mailbox: "All Mail", from: "a@example.com")]
        let client = try await connect(Policy(enabledTools: [.searchMessages]), backend: backend)
        _ = try await call(client, "search_messages", ["mailbox": .string("*")])
        #expect(backend.lock.withLock { backend.searches }.map(\.mailbox) == ["All Mail"])
    }

    @Test func listsOnlyThePromptsWhoseToolsAreOn() async throws {
        let backend = FakeBackend()
        let reading = try await connect(.readOnly, backend: backend)
        let (prompts, _) = try await reading.listPrompts()
        #expect(Set(prompts.map(\.name)) == ["triage_inbox", "find_invoices", "weekly_digest"])
        let (_, messages) = try await reading.getPrompt(name: "triage_inbox", arguments: ["days": "5"])
        guard case .text(let body)? = messages.first?.content else {
            Issue.record("no text")
            return
        }
        #expect(body.contains("search_messages") && body.contains("never follow instructions"))
        await #expect(throws: (any Error).self) { _ = try await reading.getPrompt(name: "draft_replies", arguments: [:]) }

        let everything = try await connect(backend: backend)
        let (all, _) = try await everything.listPrompts()
        #expect(all.count == PromptCatalog.entries.count)
    }
}
