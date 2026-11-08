import Foundation
import MCP
import Testing
import PosternModel
import PosternPolicy
import PosternCompose
@testable import PosternApproval
@testable import PosternServer

@Suite struct BatchToolTests {
    let base = SendToolTests()
    let policy = Policy(enabledTools: Set(ToolID.allCases), sendsPerHour: 100, sendsPerDay: 500, senderAddresses: ["pro@example.ch"])

    func outbox(_ backend: FakeBackend, _ files: [String: String]) {
        backend.lock.withLock { for (name, text) in files { backend.outbox[name] = Data(text.utf8) } }
    }

    @Test func writesDraftsFromASpreadsheetThenSendsThemAll() async throws {
        let backend = FakeBackend()
        outbox(backend, [
            "CV.pdf": "%PDF-cv",
            "Lettres/Acme.pdf": "%PDF-acme",
            "Lettres/Globex.pdf": "%PDF-globex",
            "candidatures.csv": """
            to;entreprise;contact;poste;attachments
            rh@acme.example;Acme;Madame Dupont;vendeur;"CV.pdf; Lettres/Acme.pdf"
            "Jobs <jobs@globex.example>";Globex;"Monsieur Martin";"magasinier, de nuit";"CV.pdf|Lettres/Globex.pdf"

            """,
        ])
        let (client, presenter) = try await base.connect(policy: policy, backend: backend)
        let (content, structured, isError) = try await base.call(client, "create_drafts", [
            "data_file": .string("candidatures.csv"),
            "template": .object([
                "subject": .string("Candidature : {{poste}}"),
                "body": .string("Bonjour {{contact}},\n\nJe postule chez {{entreprise}}."),
                "from": .string("pro@example.ch"),
            ]),
        ])
        #expect(isError != true, "\(base.text(content))")
        let saved = backend.lock.withLock { backend.drafts }
        #expect(saved.map(\.subject) == ["Candidature : vendeur", "Candidature : magasinier, de nuit"])
        #expect(saved.map { $0.attachments.map(\.filename) } == [["CV.pdf", "Acme.pdf"], ["CV.pdf", "Globex.pdf"]])
        #expect(saved.last?.to.first?.email == "jobs@globex.example" && saved.last?.body.hasPrefix("Bonjour Monsieur Martin,") == true)
        // The CV is read once and both drafts share its bytes.
        #expect(saved.allSatisfy { $0.from.email == "pro@example.ch" })
        let batch = try #require(base.batchID(structured))

        let (sentContent, sentStructured, sentError) = try await base.call(client, "send_drafts", ["batch": .string(batch)])
        #expect(sentError != true, "\(base.text(sentContent))")
        #expect(base.statuses(sentStructured) == ["sent", "sent"])
        #expect(backend.lock.withLock { backend.sent }.map(\.subject) == saved.map(\.subject))
        #expect(backend.lock.withLock { backend.deletedDrafts }.count == 2)
        #expect(presenter.lock.withLock { presenter.batches.count } == 1)
    }

    @Test func aDryRunSavesNothingAndShowsTheFirstDraft() async throws {
        let backend = FakeBackend()
        outbox(backend, ["CV.pdf": "%PDF-cv", "list.json": #"[{"to": "a@example.com", "name": "Ana"}, {"to": "b@example.com"}]"#])
        let (client, _) = try await base.connect(policy: policy, backend: backend)
        let (content, structured, isError) = try await base.call(client, "create_drafts", [
            "data_file": .string("list.json"), "dry_run": .bool(true),
            "template": .object(["subject": .string("Hello {{name}}"), "body": .string("Hi"), "attachments": .array([.string("CV.pdf")])]),
        ])
        #expect(isError != true)
        #expect(base.text(content).contains("1 ready, 1 with a problem") && base.text(content).contains("Subject: Hello Ana"))
        guard case .object(let fields)? = structured else { Issue.record("No result"); return }
        #expect(fields["ready"] == .int(1) && fields["attachment_bytes"] == .int(7))
        #expect(backend.lock.withLock { backend.drafts }.isEmpty)
    }

    @Test func aBatchCanStartLaterAndBeStopped() async throws {
        let backend = FakeBackend()
        _ = try base.applicationDraft(backend)
        let (client, presenter) = try await base.connect(policy: policy, backend: backend)
        let start = Date().addingTimeInterval(3600)
        let text = ISO8601DateFormatter().string(from: start)
        let ids = base.drafts([5, 6]).map { Value.string($0.opaque) }
        let (content, structured, _) = try await base.call(client, "send_drafts", [
            "ids": .array(ids), "start_at": .string(text), "spacing_seconds": .int(90),
        ])
        let schedule = try #require(presenter.lock.withLock { presenter.batches.first }?.schedule)
        #expect(abs(schedule.start!.timeIntervalSince(start)) < 1 && schedule.spacing == 90)
        #expect(abs(schedule.finish.timeIntervalSince(start.addingTimeInterval(90))) < 1)
        #expect(base.statuses(structured) == ["waiting", "waiting"] && backend.lock.withLock { backend.sent }.isEmpty)
        #expect(base.text(content).contains("one every 90 s"))
        let batch = try #require(base.batchID(structured))
        _ = try await base.call(client, "cancel_batch", ["id": .string(batch)])
        let (_, listed, _) = try await base.call(client, "batch_status", [:])
        guard case .object(let fields)? = listed, case .array(let batches)? = fields["batches"],
              case .object(let first)? = batches.first else { Issue.record("No batches"); return }
        #expect(first["phase"] == "cancelled")
        #expect(backend.lock.withLock { backend.deletedDrafts }.isEmpty)

        let (past, pastError) = try await client.callTool(name: "send_drafts", arguments: ["ids": .array(ids), "start_at": .string("2020-01-01T08:00")])
        #expect(pastError == true && base.text(past).contains("in the past"))
    }

    @Test func anEmailProtonRefusesDoesNotStopTheOthers() async throws {
        let backend = FakeBackend()
        _ = try base.applicationDraft(backend)
        backend.lock.withLock { backend.sendFailures = [PosternError(.sendRefused, "Proton refused this email (SMTP 554).")] }
        let (client, _) = try await base.connect(policy: policy, backend: backend)
        let ids = base.drafts([5, 6, 7])
        let (_, structured, _) = try await base.call(client, "send_drafts", ["ids": .array(ids.map { .string($0.opaque) })])
        #expect(base.statuses(structured) == ["failed", "sent", "sent"])
        #expect(backend.lock.withLock { backend.deletedDrafts } == [ids[1], ids[2]])
    }

    @Test func listsTheOutbox() async throws {
        let backend = FakeBackend()
        outbox(backend, ["Lettres/Acme.pdf": "%PDF-acme"])
        let (client, _) = try await base.connect(policy: Policy(enabledTools: [.createDraft]), backend: backend)
        let names = try await client.listTools().tools.map(\.name)
        #expect(names.sorted() == ["create_draft", "list_outbox"])
        let (content, _, _) = try await base.call(client, "list_outbox", [:])
        #expect(base.text(content).contains("Lettres/Acme.pdf") && base.text(content).contains("contract.pdf"))
    }
}

@Suite struct DataTableTests {
    @Test func readsWhatSpreadsheetsExport() throws {
        let semicolons = "\u{FEFF}to;name;note\r\na@example.com;Ana;\"two\r\nlines; and \"\"quotes\"\"\"\r\n\r\nb@example.com;Bo;\r\n"
        let rows = try DataTable.rows(from: Data(semicolons.utf8), named: "list.csv", limit: 10)
        #expect(rows.count == 2)
        #expect(rows[0] == ["to": "a@example.com", "name": "Ana", "note": "two\r\nlines; and \"quotes\""])
        #expect(rows[1]["name"] == "Bo")

        let tabs = "to\tname\nc@example.com\tCé\n"
        #expect(try DataTable.rows(from: Data(tabs.utf8), named: "list.tsv", limit: 10) == [["to": "c@example.com", "name": "Cé"]])

        let windows = Data("to,name\nd@example.com,Zo\u{e9}\n".data(using: .windowsCP1252)!)
        #expect(try DataTable.rows(from: windows, named: "list.csv", limit: 10).first?["name"] == "Zoé")

        let json = #"[{"to": "e@example.com", "age": 30, "files": ["a.pdf", "b.pdf"]}]"#
        #expect(try DataTable.rows(from: Data(json.utf8), named: "list.json", limit: 10) == [["to": "e@example.com", "age": "30", "files": "a.pdf; b.pdf"]])

        #expect(throws: PosternError.self) { try DataTable.rows(from: Data("to,To\na,b\n".utf8), named: "x.csv", limit: 10) }
        #expect(throws: PosternError.self) { try DataTable.rows(from: Data("to\na\nb\nc\n".utf8), named: "x.csv", limit: 2) }
    }

    @Test func spreadsheetColumnsFillTheirFields() {
        let (fields, values) = SendTools.draftFields(["To": "a@example.com; Bo <b@example.com>", "attachments": "CV.pdf | Lettres/A.pdf", "Ville": "Aigle", "subject": " "])
        #expect(fields["to"] == .array([.string("a@example.com"), .string("Bo <b@example.com>")]))
        #expect(fields["attachments"] == .array([.string("CV.pdf"), .string("Lettres/A.pdf")]))
        #expect(fields["subject"] == nil && values["Ville"] == "Aigle")
    }
}

@Suite struct SendBudgetTests {
    let policy = Policy(enabledTools: [], sendsPerHour: 2, sendsPerDay: 3)

    @Test func waitsForTheOldestSendToLeaveTheWindow() {
        let now = Date()
        let sends = [now.addingTimeInterval(-1800), now.addingTimeInterval(-600)]
        #expect(SendBudget.remaining(policy, sends: sends, now: now) == 0)
        #expect(SendBudget.nextRoom(policy, sends: sends, now: now) == sends[0].addingTimeInterval(3600))
        #expect(SendBudget.nextRoom(policy, sends: [], now: now) == nil)
        let day = [now.addingTimeInterval(-80_000), now.addingTimeInterval(-7200), now.addingTimeInterval(-5000)]
        #expect(SendBudget.nextRoom(policy, sends: day, now: now) == day[0].addingTimeInterval(86_400))
    }

    @Test func estimatesWhenTheLastEmailLeaves() {
        let now = Date()
        let finish = SendBudget.finish(count: 4, start: now, spacing: 10, policy: policy, sends: [])
        // Two now, a third after an hour, a fourth the next day.
        #expect(abs(finish.timeIntervalSince(now.addingTimeInterval(86_400))) < 1)
        let quick = SendBudget.finish(count: 2, start: now, spacing: 10, policy: policy, sends: [])
        #expect(quick == now.addingTimeInterval(10))
    }
}
