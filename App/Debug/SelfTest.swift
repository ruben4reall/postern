#if DEBUG
import AppKit
import CryptoKit
import Foundation
import NIOCore
import PosternApproval
import PosternBridge
import PosternCompose
import PosternModel
import PosternServer
import PosternVault

/// `Postern --selftest` checks attachments and Trash against the real Bridge, on messages it creates itself and on
/// nothing else. It never erases.
///
/// Debug builds only. Its approval desk approves without a panel, but only messages it created: each one carries
/// a subject stamped for this run, and the desk refuses anything else.
enum SelfTest {
    static func runBlocking(_ body: @escaping @Sendable () async -> Int32 = { await run() }) -> Int32 {
        let result = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            result.code = await body()
            done.signal()
        }
        done.wait()
        return result.code
    }

    private final class ResultBox: @unchecked Sendable { var code: Int32 = 1 }

    static func say(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    /// Where a past run's messages are now, by mailbox. Reads counts only.
    static func status(stamp: String) async -> Int32 {
        guard let run = makeRun(stamp: stamp) else { return 1 }
        let names = (try? await run.client.withConnection { try await $0.mailboxes(refresh: true).filter(\.selectable).map(\.display) }) ?? []
        for mailbox in names {
            guard let subjects = try? await run.subjects(in: mailbox) else { say("\(mailbox): error"); continue }
            if !subjects.isEmpty { say("\(mailbox): \(subjects.sorted().joined(separator: " | "))") }
        }
        return 0
    }

    /// Puts a past run's messages in Trash, the same way a run ends.
    static func cleanUp(stamp: String) async -> Int32 {
        guard let run = makeRun(stamp: stamp) else { return 1 }
        do {
            try await run.trashEverything()
            say("PASS nothing of \(stamp) is left outside Trash")
            return 0
        } catch {
            say("FAIL \(error)")
            return 1
        }
    }

    static func makeRun(stamp: String? = nil) -> SelfTestRun? {
        let vault = KeychainVault(accessGroup: CoreState.accessGroup)
        guard let endpoint = try? vault.read(.bridgeEndpoint, as: BridgeEndpoint.self),
              let pin = try? vault.read(.certificatePin, as: CertificatePin.self),
              let credentials = try? vault.read(.bridgeCredentials, as: BridgeCredentials.self) else {
            say("FAIL Postern is not set up in this Keychain.")
            return nil
        }
        return SelfTestRun(
            backend: BridgeBackend(endpoint: endpoint, pin: pin, credentials: credentials),
            client: BridgeClient(endpoint: endpoint, pin: pin, credentials: credentials),
            account: Address(name: "Postern", email: credentials.username), stamp: stamp
        )
    }

    static func run() async -> Int32 {
        let vault = KeychainVault(accessGroup: CoreState.accessGroup)
        guard let endpoint = try? vault.read(.bridgeEndpoint, as: BridgeEndpoint.self),
              let pin = try? vault.read(.certificatePin, as: CertificatePin.self),
              let credentials = try? vault.read(.bridgeCredentials, as: BridgeCredentials.self) else {
            say("FAIL Postern is not set up in this Keychain.")
            return 1
        }
        let backend = BridgeBackend(endpoint: endpoint, pin: pin, credentials: credentials)
        let client = BridgeClient(endpoint: endpoint, pin: pin, credentials: credentials)
        let run = SelfTestRun(backend: backend, client: client, account: Address(name: "Postern", email: credentials.username))
        defer { Task { await backend.shutdown(); await client.shutdown() } }
        do {
            try await run.all()
            say("PASS every check")
            return 0
        } catch {
            say("FAIL \(error)")
            await run.cleanUp()
            return 1
        }
    }
}

struct SelfTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Approves only deletions and sends of this run's own messages.
private struct OwnMessagesPresenter: ApprovalPresenter {
    let stamp: String
    let account: String

    func present(_ request: ApprovalRequest, deadline: Date) async -> ApprovalIntent {
        let message = request.message
        guard message.subject.hasSuffix(stamp), message.envelopeRecipients == [account.lowercased()] else {
            return .reject(reason: "Not a self-test message.")
        }
        return .send
    }

    func presentDeletion(_ request: DeletionRequest, deadline: Date) async -> ApprovalIntent {
        guard !request.permanent, request.items.allSatisfy({ $0.subject.hasSuffix(stamp) }) else {
            return .reject(reason: "Not a self-test message.")
        }
        return .send
    }
}

private struct NoTouchID: Authenticating {
    func confirm(reason: String) async -> Bool { true }
}

final class SelfTestRun: @unchecked Sendable {
    let backend: BridgeBackend
    let client: BridgeClient
    let account: Address
    let stamp: String
    let desk: ApprovalDesk
    let files: [OutgoingAttachment]
    /// Every message this run created, to put in Trash at the end even after a failure.
    private var created: [String] = []

    init(backend: BridgeBackend, client: BridgeClient, account: Address, stamp: String? = nil) {
        self.backend = backend
        self.client = client
        self.account = account
        self.stamp = stamp ?? "[selftest " + UUID().uuidString.prefix(8).lowercased() + "]"
        desk = ApprovalDesk(presenter: OwnMessagesPresenter(stamp: self.stamp, account: account.email), authenticator: NoTouchID())
        files = [
            try! OutgoingAttachment.make(filename: "Postern check.png", data: Self.png()),
            try! OutgoingAttachment.make(filename: "Notes été.txt", data: Data("Postern self-test, accents: é à ü, emoji: ✉️\n".utf8)),
        ]
    }

    func message(_ title: String) throws -> OutgoingMessage {
        try OutgoingMessage.make(
            from: account, to: [account], subject: "Postern \(title) \(stamp)",
            body: "This message was written by Postern's self-test and goes to Trash a moment later.",
            attachments: files
        )
    }

    func all() async throws {
        SelfTest.say("Run \(stamp)")

        // 1. A message created in Inbox by APPEND, with two attachments.
        let imported = try message("import check")
        let inboxID = try await append(imported, to: "INBOX")
        created.append(imported.subject)
        SelfTest.say("ok  created a message in Inbox")
        try await checkAttachments(of: inboxID, where: "Inbox")
        try await checkSaving(inboxID)

        // 2. A draft with the same attachments.
        let draft = try message("draft check")
        let draftID = try await backend.saveDraft(draft)
        created.append(draft.subject)
        SelfTest.say("ok  saved a draft")
        try await checkAttachments(of: draftID, where: "Drafts")

        // 3. A real send to the account's own address, approved by this run's desk only.
        let sent = try message("send check")
        let request = ApprovalRequest(tool: "send_message", client: "Postern self-test", message: sent, badges: [:], context: nil)
        guard case .approved(let approved) = await desk.review(request) else { throw SelfTestFailure("the send was not approved") }
        try await backend.send(approved)
        created.append(sent.subject)
        SelfTest.say("ok  sent a message to the account's own address")
        let receivedID = try await waitFor(subject: sent.subject, in: "INBOX", seconds: 120)
        SelfTest.say("ok  the sent message arrived in Inbox")
        try await checkAttachments(of: receivedID, where: "the received copy")

        // 4. Everything this run created goes to Trash, through the approval desk.
        try await trashEverything()
        SelfTest.say("ok  this run left nothing outside Trash")
    }

    // MARK: Checks

    func checkAttachments(of id: MessageID, where place: String) async throws {
        let read = try await backend.message(id, maxChars: 2_000)
        guard read.attachments.count == files.count else {
            throw SelfTestFailure("\(place): \(read.attachments.count) attachments listed, expected \(files.count)")
        }
        let names = Set(read.attachments.compactMap(\.filename))
        guard names == Set(files.map(\.filename)) else { throw SelfTestFailure("\(place): names changed to \(names.sorted())") }
        let fetched = try await backend.attachments(of: id)
        guard Set(fetched.map(\.sha256)) == Set(files.map(\.sha256)) else {
            throw SelfTestFailure("\(place): attachment bytes changed")
        }
        SelfTest.say("ok  \(place): both attachments intact (names, types, SHA-256)")
    }

    func checkSaving(_ id: MessageID) async throws {
        let read = try await backend.message(id, maxChars: 200)
        for info in read.attachments {
            let saved = try await backend.saveAttachment(id, index: info.index)
            defer { try? FileManager.default.removeItem(atPath: saved.path) }
            let url = URL(fileURLWithPath: saved.path)
            guard url.deletingLastPathComponent().standardizedFileURL == PosternFolders.saved.standardizedFileURL else {
                throw SelfTestFailure("saved outside Downloads › Postern: \(saved.path)")
            }
            let data = try Data(contentsOf: url)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hash == saved.sha256, files.contains(where: { $0.sha256 == hash }) else {
                throw SelfTestFailure("saved file differs from the original")
            }
            guard getxattr(saved.path, "com.apple.quarantine", nil, 0, 0, 0) > 0 else {
                throw SelfTestFailure("saved file is not marked as downloaded")
            }
        }
        SelfTest.say("ok  saved both attachments to Downloads › Postern, intact and quarantined (then removed)")
    }

    // MARK: Trash

    func trashEverything() async throws {
        for mailbox in ["INBOX", "Drafts", "Sent"] {
            let ids = try await ids(in: mailbox)
            guard !ids.isEmpty else { continue }
            let items = try await backend.deletionItems(ids)
            let request = DeletionRequest(tool: "trash_messages", client: "Postern self-test", items: items, permanent: false)
            guard case .approved(let approved) = await desk.reviewDeletion(request) else {
                throw SelfTestFailure("the desk refused to trash this run's messages")
            }
            let report = try await backend.trash(approved)
            // A message sent to yourself is one message in Inbox and Sent: once trashed from Inbox, Bridge still
            // lists it in Sent for a moment, and Postern must leave it alone.
            let refused = report.failed.filter { $0.reason != "Already in Trash." }
            guard refused.isEmpty else { throw SelfTestFailure("\(refused.count) messages did not reach Trash: \(refused.map(\.reason))") }
            SelfTest.say("ok  moved \(report.done.count) from \(mailbox) to Trash" + (report.failed.isEmpty ? "" : ", \(report.failed.count) already there"))
        }
        // Bridge updates its other views when Proton's event arrives.
        var left: [String] = []
        for _ in 0..<30 {
            left = []
            for mailbox in ["INBOX", "Drafts", "Sent"] where !(try await ids(in: mailbox)).isEmpty { left.append(mailbox) }
            if left.isEmpty { break }
            try await Task.sleep(for: .seconds(4))
        }
        guard left.isEmpty else { throw SelfTestFailure("a message of this run is still in \(left.joined(separator: ", "))") }
        let trashed = try await subjects(in: "Trash")
        guard trashed.count == 3 else { throw SelfTestFailure("\(trashed.count) messages of this run in Trash, expected 3") }
        SelfTest.say("ok  Trash holds the run's 3 messages: \(trashed.map { $0.replacingOccurrences(of: " " + stamp, with: "") }.sorted().joined(separator: ", "))")
    }

    /// After a failure, puts whatever this run created in Trash, ignoring errors.
    func cleanUp() async {
        try? await trashEverything()
    }

    // MARK: Bridge

    func append(_ message: OutgoingMessage, to name: String) async throws -> MessageID {
        let bytes = message.rfc822(includeBcc: false)
        return try await client.withConnection { connection in
            let mailbox = try await connection.mailbox(named: name)
            _ = try await connection.append(bytes, to: mailbox, flags: [.seen])
            let status = try await connection.examine(mailbox)
            guard let uid = try await connection.uidSearch(.subject(ByteBuffer(string: message.subject))).first else {
                throw SelfTestFailure("the new message is not in \(name)")
            }
            return MessageID(mailbox: mailbox.raw, uidValidity: status.uidValidity, uid: uid)
        }
    }

    /// This run's messages in a mailbox, found by the stamp in their subject.
    func ids(in name: String) async throws -> [MessageID] {
        let stamp = self.stamp
        return try await client.withConnection { connection in
            let mailbox = try await connection.mailbox(named: name)
            let status = try await connection.examine(mailbox)
            let uids = try await connection.uidSearch(.subject(ByteBuffer(string: stamp)))
            // Bridge's search is broad; keep only exact stamps.
            let summaries = try await connection.fetchSummaries(uids)
            return summaries.compactMap { summary in
                guard let uid = summary.uid, summary.subject.hasSuffix(stamp) else { return nil }
                return MessageID(mailbox: mailbox.raw, uidValidity: status.uidValidity, uid: uid)
            }
        }
    }

    func subjects(in name: String) async throws -> [String] {
        let stamp = self.stamp
        return try await client.withConnection { connection in
            let mailbox = try await connection.mailbox(named: name)
            _ = try await connection.examine(mailbox)
            let uids = try await connection.uidSearch(.subject(ByteBuffer(string: stamp)))
            return try await connection.fetchSummaries(uids).map(\.subject).filter { $0.hasSuffix(stamp) }
        }
    }

    func waitFor(subject: String, in name: String, seconds: Int) async throws -> MessageID {
        for _ in 0..<(seconds / 4) {
            let found = try await client.withConnection { connection -> MessageID? in
                let mailbox = try await connection.mailbox(named: name)
                let status = try await connection.examine(mailbox)
                let uids = try await connection.uidSearch(.subject(ByteBuffer(string: subject)))
                return uids.first.map { MessageID(mailbox: mailbox.raw, uidValidity: status.uidValidity, uid: $0) }
            }
            if let found { return found }
            try await Task.sleep(for: .seconds(4))
        }
        throw SelfTestFailure("the sent message did not arrive in \(seconds) s")
    }

    static func png() -> Data {
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor(red: 0.07, green: 0.07, blue: 0.06, alpha: 1).setFill()
            rect.fill()
            NSColor(red: 0.95, green: 0.93, blue: 0.89, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 18, dy: 14), xRadius: 14, yRadius: 14).fill()
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }
}
#endif
