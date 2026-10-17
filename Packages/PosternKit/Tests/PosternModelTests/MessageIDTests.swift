import Foundation
import Testing
@testable import PosternModel

@Suite struct MessageIDTests {
    @Test func roundTripsThroughOpaqueForm() throws {
        let id = MessageID(mailbox: "Folders/Clients/Ünïcode & co", uidValidity: 1_700_000_001, uid: 42)
        let decoded = try #require(MessageID(opaque: id.opaque))
        #expect(decoded == id)
        #expect(!id.opaque.contains("/") && !id.opaque.contains("+") && !id.opaque.contains("="))
    }

    @Test(arguments: ["", "not base64 !", "djE", Data("v1\u{0}INBOX\u{0}x\u{0}1".utf8).base64EncodedString(),
                      Data("v2\u{0}INBOX\u{0}1\u{0}1".utf8).base64EncodedString()])
    func rejectsGarbage(_ text: String) {
        #expect(MessageID(opaque: text) == nil)
    }

    @Test func encodesAsOpaqueString() throws {
        let id = MessageID(mailbox: "INBOX", uidValidity: 7, uid: 9)
        let json = try JSONEncoder().encode(id)
        #expect(String(decoding: json, as: UTF8.self) == "\"\(id.opaque)\"")
        #expect(try JSONDecoder().decode(MessageID.self, from: json) == id)
    }
}

@Suite struct ToolIDTests {
    @Test func readToolsBelongToTheReadTier() {
        for tool in [ToolID.listMailboxes, .searchMessages, .getMessage, .getThread] {
            #expect(tool.tier == .read)
        }
    }
}
