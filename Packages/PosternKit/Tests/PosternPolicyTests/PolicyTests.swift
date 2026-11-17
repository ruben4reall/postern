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

@Suite struct SendingLimitTests {
    @Test func keepsLimitsWithinPosternsCeilings() {
        #expect(Policy.clampedLimits(perHour: 50, perDay: 500) == (50, 500))
        #expect(Policy.clampedLimits(perHour: 5000, perDay: 99_999) == (Policy.maxSendsPerHour, Policy.maxSendsPerDay))
        #expect(Policy.clampedLimits(perHour: 0, perDay: 0) == (1, 1))
        // A day never holds fewer emails than an hour.
        #expect(Policy.clampedLimits(perHour: 200, perDay: 100) == (200, 200))
    }

    @Test func raisingEitherLimitNeedsTheUserAndLoweringNeverDoes() {
        let current = Policy(enabledTools: [.sendMessage], sendsPerHour: 10, sendsPerDay: 30)
        var both = current
        both.sendsPerHour = Policy.maxSendsPerHour
        both.sendsPerDay = Policy.maxSendsPerDay
        #expect(both.addsPower(over: current))
        var mixed = current
        mixed.sendsPerHour = 5
        mixed.sendsPerDay = 500
        #expect(mixed.addsPower(over: current))
        var lower = current
        lower.sendsPerHour = 5
        lower.sendsPerDay = 20
        #expect(!lower.addsPower(over: current))
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
        { (p: inout Policy) in p.senderAddresses.insert("pro@example.ch") },
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
