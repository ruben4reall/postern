import Foundation
import Testing
import PosternModel
import PosternVault
@testable import PosternPolicy

@Suite struct PolicyTests {
    @Test func nothingIsAllowedInitially() {
        for tool in ToolID.allCases { #expect(!Policy.initial.allows(tool)) }
    }

    @Test func readOnlyAllowsExactlyTheReadTools() {
        #expect(Policy.readOnly.enabledTools == [.listMailboxes, .searchMessages, .getMessage, .getThread])
    }

    @Test func hidingAMailboxAlsoHidesAggregateViews() {
        let policy = Policy(enabledTools: [], hiddenMailboxes: ["Folders/Private"])
        #expect(policy.isHidden("Folders/Private"))
        #expect(policy.isHidden("All Mail"))
        #expect(policy.isHidden("Starred"))
        #expect(!policy.isHidden("INBOX"))
        #expect(!Policy.readOnly.isHidden("All Mail"))
    }

    @Test func storeRoundTripsAndFailsClosed() throws {
        let vault = MemoryVault()
        let store = PolicyStore(vault: vault)
        #expect(store.load() == .initial)
        try store.save(.readOnly)
        #expect(store.load() == .readOnly)
        try vault.set(Data("not json".utf8), for: .policy)
        #expect(store.load() == .initial)
    }
}

@Suite struct PolicyPowerTests {
    let base = Policy(enabledTools: [.listMailboxes], hiddenMailboxes: ["Folders/Private"], pauseWhenLocked: true)

    @Test func takingPowerAwayNeverNeedsTheUser() {
        var less = base
        less.enabledTools = []
        less.hiddenMailboxes.insert("Folders/Bank")
        less.paused = true
        #expect(!less.addsPower(over: base))
    }

    @Test(arguments: [
        { (p: inout Policy) in p.enabledTools.insert(.getMessage) },
        { (p: inout Policy) in p.hiddenMailboxes.remove("Folders/Private") },
        { (p: inout Policy) in p.pauseWhenLocked = false },
        { (p: inout Policy) in p.allowPasswordFallback = true },
    ] as [@Sendable (inout Policy) -> Void])
    func givingPowerNeedsTheUser(_ change: @Sendable (inout Policy) -> Void) {
        var more = base
        change(&more)
        #expect(more.addsPower(over: base))
    }

    @Test func resumingFromPauseNeedsTheUser() {
        var paused = base
        paused.paused = true
        #expect(base.addsPower(over: paused))
    }

    @Test func pauseBlocksEveryTool() {
        var paused = Policy.readOnly
        paused.paused = true
        for tool in ToolID.allCases { #expect(!paused.allows(tool)) }
    }

    @Test func aLotOnePolicyStillLoads() throws {
        let old = Data(#"{"enabledTools":["list_mailboxes"],"hiddenMailboxes":[]}"#.utf8)
        let policy = try JSONDecoder().decode(Policy.self, from: old)
        #expect(policy.enabledTools == [.listMailboxes])
        #expect(!policy.paused && !policy.allowPasswordFallback)
    }
}

@Suite struct SendingPolicyTests {
    @Test func trustingSomeoneOrRaisingLimitsNeedsTheUser() {
        let base = Policy(enabledTools: [])
        var trusted = base
        trusted.trustedRecipients = ["me@example.ch"]
        #expect(trusted.addsPower(over: base))
        var faster = base
        faster.sendsPerHour = 20
        #expect(faster.addsPower(over: base))
        var slower = base
        slower.sendsPerDay = 5
        #expect(!slower.addsPower(over: base))
    }

    @Test func restrictingRecipientsIsFreeWideningIsNot() {
        let open = Policy(enabledTools: [])
        var restricted = open
        restricted.allowedRecipients = ["anna@example.com"]
        #expect(!restricted.addsPower(over: open))
        #expect(open.addsPower(over: restricted))
        var wider = restricted
        wider.allowedRecipients.insert("bob@example.com")
        #expect(wider.addsPower(over: restricted))
        #expect(restricted.mayReceive("ANNA@example.com") && !restricted.mayReceive("bob@example.com"))
        #expect(open.mayReceive("anyone@example.com"))
    }
}
