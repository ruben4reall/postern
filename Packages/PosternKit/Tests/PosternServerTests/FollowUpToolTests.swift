import Foundation
import MCP
import Testing
import PosternModel
import PosternPolicy
@testable import PosternServer

@Suite struct FollowUpToolTests {
    let base = SendToolTests()
    var uid: UInt32 = 0

    func message(
        _ mailbox: String, _ uid: UInt32, from: String, to: String = "me@example.ch", daysAgo: Double, subject: String = "S",
        messageID: String? = nil, inReplyTo: String? = nil
    ) -> MessageSummary {
        MessageSummary(
            id: MessageID(mailbox: mailbox, uidValidity: 1, uid: uid), date: Date().addingTimeInterval(-daysAgo * 86_400),
            from: [Address(name: nil, email: from)], to: [Address(name: nil, email: to)], cc: [], subject: subject,
            unread: false, starred: false, answered: false, size: 10, attachmentCount: 0, messageIDHeader: messageID, inReplyTo: inReplyTo
        )
    }

    @Test func listsThePeopleWhoHaveNotAnswered() async throws {
        let backend = FakeBackend()
        let me = "me@example.ch"
        backend.lock.withLock {
            backend.names = ["INBOX", "Sent", "All Mail", "Spam"]
            backend.searchResults["Sent"] = [
                message("Sent", 7, from: me, to: "new@hooli.example", daysAgo: 2),
                message("Sent", 6, from: me, to: "hr@initech.example", daysAgo: 8, subject: "Relance"),
                message("Sent", 5, from: me, to: "someone@gmail.com", daysAgo: 9),
                message("Sent", 4, from: me, to: "rh@acme.example", daysAgo: 10, messageID: "<a1@example.ch>"),
                message("Sent", 3, from: me, to: "contact@globex.example", daysAgo: 12),
                message("Sent", 2, from: me, to: "hr@initech.example", daysAgo: 15, subject: "Candidature"),
                message("Sent", 1, from: me, to: "hr@umbrella.example", daysAgo: 20, messageID: "<u1@example.ch>"),
            ]
            backend.searchResults["All Mail"] = [
                message("All Mail", 40, from: "jobs@acme.example", daysAgo: 9, inReplyTo: "<A1@example.ch>"),
                message("All Mail", 41, from: "noreply@careers.globex.example", daysAgo: 11, subject: "Accusé de réception"),
                message("All Mail", 42, from: "other@gmail.com", daysAgo: 5),
                message("All Mail", 43, from: me, to: "hr@initech.example", daysAgo: 8, inReplyTo: "<x@initech.example>"),
            ]
            backend.searchResults["Spam"] = [message("Spam", 50, from: "x@umbrella.example", daysAgo: 18, inReplyTo: "<u1@example.ch>")]
        }
        let (client, _) = try await base.connect(policy: Policy(enabledTools: [.awaitingReply]), backend: backend)
        let (content, structured, isError) = try await base.call(client, "awaiting_reply", [:])
        #expect(isError != true, "\(base.text(content))")
        #expect(emails(structured) == ["someone@gmail.com", "hr@initech.example"])
        #expect(base.text(content).contains("5 people") && base.text(content).contains("2 without any answer"))
        #expect(base.text(content).contains("1 more were written to in the last 7 days"))
        #expect(backend.lock.withLock { backend.searches }.map(\.mailbox) == ["Sent", "All Mail", "Spam"])

        let (_, everyone, _) = try await base.call(client, "awaiting_reply", ["include_answered": .bool(true)])
        #expect(answers(everyone) == [
            "hr@umbrella.example": "replied", "contact@globex.example": "heard_from_domain", "rh@acme.example": "replied",
            "someone@gmail.com": "no_reply", "hr@initech.example": "no_reply",
        ])
    }

    @Test func companiesAreDomainsButPublicProvidersAreNot() {
        #expect(FollowUpTools.company(of: "jobs@careers.acme.ch") == "acme.ch")
        #expect(FollowUpTools.company(of: "a@shop.co.uk") == "shop.co.uk")
        #expect(FollowUpTools.company(of: "a@gmail.com") == nil)
        #expect(FollowUpTools.company(of: "a@hotmail.fr") == nil)
        #expect(FollowUpTools.company(of: "a@bluewin.ch") == nil)
    }

    func contacts(_ structured: Value?) -> [[String: Value]] {
        guard case .object(let fields)? = structured, case .array(let list)? = fields["contacts"] else { return [] }
        return list.compactMap { if case .object(let item) = $0 { item } else { nil } }
    }

    func emails(_ structured: Value?) -> [String] {
        contacts(structured).compactMap { if case .string(let email)? = $0["email"] { email } else { nil } }
    }

    func answers(_ structured: Value?) -> [String: String] {
        var result: [String: String] = [:]
        for contact in contacts(structured) {
            if case .string(let email)? = contact["email"], case .string(let answer)? = contact["answer"] { result[email] = answer }
        }
        return result
    }
}

@Suite struct ReadAttachmentToolTests {
    let base = SendToolTests()

    @Test func readsAnAttachmentAsUntrustedText() async throws {
        let backend = FakeBackend()
        let (client, _) = try await base.connect(policy: Policy(enabledTools: [.readAttachment]), backend: backend)
        let (content, structured, isError) = try await base.call(client, "read_attachment", [
            "message_id": .string(backend.inbox.opaque), "index": .int(1),
        ])
        #expect(isError != true)
        #expect(base.text(content).contains("<<postern-untrusted:") && base.text(content).contains("Total CHF 42.00"))
        guard case .object(let fields)? = structured else { Issue.record("No result"); return }
        #expect(fields["kind"] == "pdf" && fields["pages"] == .int(1))
        let (hidden, hiddenError) = try await client.callTool(name: "read_attachment", arguments: [
            "message_id": .string(backend.secret.opaque), "index": .int(1),
        ])
        #expect(hiddenError != true || base.text(hidden).hasPrefix("scope_hidden"))
    }
}
