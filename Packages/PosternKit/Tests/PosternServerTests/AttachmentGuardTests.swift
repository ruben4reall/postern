import Foundation
import MCP
import PosternApproval
import PosternCompose
import PosternModel
import PosternPolicy
import Testing
@testable import PosternServer

/// Files that must leave with their email: the text that announces one, files written by the app or taken from
/// another email, drafts Bridge saved without all their files, and drafts changed after the user approved them.
@Suite struct AttachmentGuardTests {
    let base = SendToolTests()

    @Test func anEmailThatAnnouncesAFileButHasNoneIsStopped() async throws {
        let (client, presenter) = try await base.connect()
        let email: [String: Value] = [
            "to": .array([.string("known@example.com")]), "subject": .string("Candidature"),
            "body": .string("Bonjour,\n\nVous trouverez ci-joint mon CV.\n\nRuben"),
        ]
        let (content, _, isError) = try await base.call(client, "send_message", email)
        #expect(isError == true && base.text(content).hasPrefix("attachment_missing"))
        #expect(base.text(content).contains("ci-joint"))
        #expect(presenter.lock.withLock { presenter.requests }.isEmpty)

        let (draft, _, draftError) = try await base.call(client, "create_draft", email)
        #expect(draftError == true && base.text(draft).hasPrefix("attachment_missing"))

        let (meant, _, meantError) = try await base.call(client, "send_message", email.merging(["no_attachment": .bool(true)]) { $1 })
        #expect(meantError != true, "\(base.text(meant))")
        #expect(presenter.lock.withLock { presenter.requests }.count == 1)
    }

    @Test func aReplyThatAnnouncesAFileNeedsOne() async throws {
        let (client, _) = try await base.connect()
        let (content, _, isError) = try await base.call(client, "reply_to_message", [
            "id": .string(MessageID(mailbox: "INBOX", uidValidity: 1, uid: 77).opaque),
            "body": .string("Please find the invoice attached."),
        ])
        #expect(isError == true && base.text(content).hasPrefix("attachment_missing"))

        let (sent, _, sentError) = try await base.call(client, "reply_to_message", [
            "id": .string(MessageID(mailbox: "INBOX", uidValidity: 1, uid: 77).opaque),
            "body": .string("Please find the invoice attached."),
            "email_attachments": .array([.object(["id": .string(MessageID(mailbox: "INBOX", uidValidity: 1, uid: 10).opaque), "index": .int(2)])]),
        ])
        #expect(sentError != true, "\(base.text(sent))")
        #expect(base.text(sent).contains("facture.pdf"))
    }

    @Test func filesTheAppWroteAndFilesOfOtherEmailsAreAttached() async throws {
        let backend = FakeBackend()
        let (client, _) = try await base.connect(backend: backend)
        let csv = "date,amount\n2026-11-01,42.00\n"
        let pdf = Data("%PDF-1.7 tiny".utf8)
        let (content, structured, isError) = try await base.call(client, "create_draft", [
            "to": .array([.string("compta@example.com")]), "subject": .string("Relevé"),
            "body": .string("Voici le relevé et la facture en pièce jointe."),
            "inline_attachments": .array([
                .object(["name": .string("releve.csv"), "text": .string(csv)]),
                .object(["name": .string("note.pdf"), "base64": .string(pdf.base64EncodedString())]),
            ]),
            "email_attachments": .array([.object(["id": .string(backend.inbox.opaque), "index": .int(2)])]),
        ])
        #expect(isError != true, "\(base.text(content))")
        let saved = try #require(backend.lock.withLock { backend.drafts.last })
        #expect(saved.attachments.map(\.filename) == ["releve.csv", "note.pdf", "facture.pdf"])
        #expect(saved.attachments[0].data == Data(csv.utf8) && saved.attachments[1].data == pdf)
        #expect(base.text(content).contains("releve.csv"))
        guard case .object(let fields)? = structured, case .array(let files)? = fields["attachments"] else {
            Issue.record("No attachment list")
            return
        }
        #expect(files.count == 3)
    }

    @Test func refusesUnsafeOrBrokenInlineFiles() async throws {
        let (client, _) = try await base.connect()
        let email: [String: Value] = ["to": .array([.string("a@example.com")]), "subject": .string("S"), "body": .string("B")]
        for file in [
            Value.object(["name": .string("../escape.txt"), "text": .string("x")]),
            .object(["name": .string("a.pdf"), "base64": .string("%%%")]),
            .object(["name": .string("a.txt")]),
            .object(["name": .string("a.txt"), "text": .string("x"), "base64": .string("eA==")]),
        ] {
            let (content, _, isError) = try await base.call(client, "create_draft", email.merging(["inline_attachments": .array([file])]) { $1 })
            #expect(isError == true && base.text(content).hasPrefix("invalid_argument"), "\(base.text(content))")
        }
    }

    @Test func aDraftBridgeSavedWithoutAllItsFilesIsRemoved() async throws {
        let backend = FakeBackend()
        backend.lock.withLock { backend.keptFiles = 1 }
        let (client, _) = try await base.connect(backend: backend)
        let (content, _, isError) = try await base.call(client, "create_draft", [
            "to": .array([.string("a@example.com")]), "subject": .string("Deux fichiers"), "body": .string("Les voici."),
            "inline_attachments": .array([
                .object(["name": .string("a.txt"), "text": .string("a")]),
                .object(["name": .string("b.txt"), "text": .string("b")]),
            ]),
        ])
        #expect(isError == true && base.text(content).hasPrefix("attachments_lost"), "\(base.text(content))")
        #expect(backend.lock.withLock { backend.deletedDrafts }.count == 1)
    }

    @Test func aDraftChangedAfterApprovalDoesNotLeave() async throws {
        let backend = FakeBackend()
        _ = try base.applicationDraft(backend)
        let (client, _) = try await base.connect(backend: backend)
        let ids = base.drafts([5, 6])
        let edit = Task {
            try await Task.sleep(for: .milliseconds(700))
            backend.lock.withLock { backend.editedDrafts[ids[0]] = "Bonjour, voici ma candidature, et un lien." }
        }
        let start = Value.string(ISO8601DateFormatter().string(from: Date().addingTimeInterval(2)))
        let (_, structured, _) = try await base.call(client, "send_drafts", ["ids": .array(ids.map { .string($0.opaque) }), "start_at": start])
        try await edit.value
        #expect(base.statuses(structured) == ["refused", "sent"])
        let sent = backend.lock.withLock { backend.sent }
        #expect(sent.count == 1 && sent.first?.body == "Bonjour, voici ma candidature.")
        #expect(sent.first?.attachments.count == 3)
    }

    @Test func aBatchStillOnThePanelAnswersAtOnceAndHoldsItsDrafts() async throws {
        let backend = FakeBackend()
        _ = try base.applicationDraft(backend)
        let (client, presenter) = try await base.connect(backend: backend, inlineWait: .milliseconds(300), batchDelay: .milliseconds(1200))
        let ids = base.drafts([5, 6]).map { Value.string($0.opaque) }
        let (content, structured, isError) = try await base.call(client, "send_drafts", ["ids": .array(ids)])
        #expect(isError != true && base.text(content).contains("approval panel"))
        guard case .object(let fields)? = structured, fields["decision"] == "pending", let batch = base.batchID(structured) else {
            Issue.record("No pending batch: \(base.text(content))")
            return
        }
        let (again, second, _) = try await base.call(client, "send_drafts", ["ids": .array(ids)])
        #expect(base.statuses(second) == ["refused", "refused"] && base.text(again).contains("already in batch"))
        try await Task.sleep(for: .milliseconds(1500))
        let (_, status, _) = try await base.call(client, "batch_status", ["id": .string(batch)])
        guard case .object(let after)? = status, case .object(let counts)? = after["counts"] else {
            Issue.record("No status")
            return
        }
        #expect(counts["sent"] == .int(2) && after["phase"] == "finished")
        #expect(presenter.lock.withLock { presenter.batches.count } == 1)
        #expect(backend.lock.withLock { backend.sent }.count == 2)
    }

    @Test func aBatchRejectedLaterLeavesItsDraftsFree() async throws {
        let backend = FakeBackend()
        _ = try base.applicationDraft(backend)
        let (client, _) = try await base.connect(intent: .reject(reason: nil), backend: backend, inlineWait: .milliseconds(200), batchDelay: .milliseconds(600))
        let ids = base.drafts([5]).map { Value.string($0.opaque) }
        let (_, structured, _) = try await base.call(client, "send_drafts", ["ids": .array(ids)])
        let batch = try #require(base.batchID(structured))
        try await Task.sleep(for: .milliseconds(900))
        let (_, status, _) = try await base.call(client, "batch_status", ["id": .string(batch)])
        guard case .object(let after)? = status else { Issue.record("No status"); return }
        #expect(after["phase"] == "cancelled")
        #expect(backend.lock.withLock { backend.sent }.isEmpty)
        let (_, retry, _) = try await base.call(client, "send_drafts", ["ids": .array(ids)])
        #expect(!base.statuses(retry).contains("refused"))
    }
}
