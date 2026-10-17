import Foundation
import NIOCore
import NIOIMAP
import Testing
import PosternModel
@testable import PosternBridge

@Suite struct SearchKeyBuilderTests {
    @Test func emptyQueryMatchesEverything() {
        #expect(SearchKeyBuilder.key(for: SearchQuery()) == .all)
    }

    @Test func combinesFields() {
        let key = SearchKeyBuilder.key(for: SearchQuery(from: "bank", unread: true))
        #expect(key == .and([.from(ByteBuffer(string: "bank")), .unseen]))
    }

    @Test func uidSetsAreNeverEmpty() {
        #expect(IMAPConnection.uidSet([]) == nil)
        #expect(IMAPConnection.uidSet([3, 1]) != nil)
    }
}
