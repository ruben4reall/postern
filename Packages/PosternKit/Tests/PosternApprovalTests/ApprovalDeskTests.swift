import Foundation
import Testing
import PosternCompose
import PosternModel
@testable import PosternApproval

final class ScriptedPresenter: ApprovalPresenter, @unchecked Sendable {
    let intent: ApprovalIntent?
    let delay: Duration
    let lock = NSLock()
    var showing = 0
    var maxShowing = 0
    var shown: [UUID] = []

    init(_ intent: ApprovalIntent?, delay: Duration = .milliseconds(20)) {
        self.intent = intent
        self.delay = delay
    }

    func present(_ request: ApprovalRequest, deadline: Date) async -> ApprovalIntent {
        lock.withLock { showing += 1; maxShowing = max(maxShowing, showing); shown.append(request.id) }
        defer { lock.withLock { showing -= 1 } }
        guard let intent else {
            // Never answers: waits until the desk cancels it.
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            return .reject(reason: "cancelled")
        }
        try? await Task.sleep(for: delay)
        return intent
    }
}

struct FixedAuthenticator: Authenticating {
    let answer: Bool
    func confirm(reason: String) async -> Bool { answer }
}

@Suite struct ApprovalDeskTests {
    func request(body: String = "Hi") throws -> ApprovalRequest {
        let message = try OutgoingMessage.make(
            from: Address(name: nil, email: "me@example.ch"), to: [Address(name: nil, email: "anna@example.com")],
            subject: "Hello", body: body
        )
        return ApprovalRequest(tool: "send_message", client: "Claude Code", message: message, badges: [:], context: nil)
    }

    @Test func approvesOnlyAfterSendAndAuthentication() async throws {
        let desk = ApprovalDesk(presenter: ScriptedPresenter(.send), authenticator: FixedAuthenticator(answer: true))
        let request = try request()
        guard case .approved(let approved) = await desk.review(request) else { Issue.record("not approved"); return }
        #expect(approved.digest == request.digest)
        #expect(approved.recipients == ["anna@example.com"])
    }

    @Test func sendWithoutTouchIDSendsNothing() async throws {
        let desk = ApprovalDesk(presenter: ScriptedPresenter(.send), authenticator: FixedAuthenticator(answer: false))
        guard case .notAuthenticated = await desk.review(try request()) else { Issue.record("expected notAuthenticated"); return }
    }

    @Test func rejectAndDraftNeverAuthenticateNorApprove() async throws {
        let reject = ApprovalDesk(presenter: ScriptedPresenter(.reject(reason: "Wrong person")), authenticator: FixedAuthenticator(answer: true))
        guard case .rejected(let reason) = await reject.review(try request()) else { Issue.record("expected rejection"); return }
        #expect(reason == "Wrong person")
        let draft = ApprovalDesk(presenter: ScriptedPresenter(.saveAsDraft), authenticator: FixedAuthenticator(answer: true))
        guard case .saveAsDraft = await draft.review(try request()) else { Issue.record("expected draft"); return }
    }

    @Test func expiresWhenNobodyAnswers() async throws {
        let desk = ApprovalDesk(presenter: ScriptedPresenter(nil), authenticator: FixedAuthenticator(answer: true), timeout: .milliseconds(150))
        guard case .expired = await desk.review(try request()) else { Issue.record("expected expiry"); return }
    }

    @Test func showsOnePanelAtATime() async throws {
        let presenter = ScriptedPresenter(.reject(reason: nil), delay: .milliseconds(80))
        let desk = ApprovalDesk(presenter: presenter, authenticator: FixedAuthenticator(answer: true))
        let first = try request(body: "one")
        let second = try request(body: "two")
        async let a = desk.review(first)
        async let b = desk.review(second)
        _ = await (a, b)
        #expect(presenter.lock.withLock { presenter.maxShowing } == 1)
        #expect(presenter.lock.withLock { presenter.shown.count } == 2)
    }

    @Test func trustedRecipientsSkipThePanelOnlyWhenAllAreTrusted() async throws {
        let desk = ApprovalDesk(presenter: ScriptedPresenter(.send), authenticator: FixedAuthenticator(answer: false))
        let request = try request()
        #expect(await desk.approveTrusted(request, trusted: ["anna@example.com"]) != nil)
        #expect(await desk.approveTrusted(request, trusted: ["other@example.com"]) == nil)
        #expect(await desk.approveTrusted(request, trusted: []) == nil)
    }
}
