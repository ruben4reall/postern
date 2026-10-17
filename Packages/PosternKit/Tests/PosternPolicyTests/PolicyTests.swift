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
