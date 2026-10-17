import NIOCore
import NIOEmbedded
import NIOIMAP
import PosternModel
import Testing
@testable import PosternBridge

/// What Postern actually writes on the wire for each command it sends Bridge.
@Suite struct CommandEncodingTests {
    func encode(_ command: Command) throws -> String {
        let channel = EmbeddedChannel(handler: IMAPClientHandler())
        try channel.writeOutbound(IMAPClientHandler.Message.part(.tagged(TaggedCommand(tag: "P1", command: command))))
        var output = ""
        while var buffer = try channel.readOutbound(as: ByteBuffer.self) {
            output += buffer.readString(length: buffer.readableBytes) ?? ""
        }
        return output
    }

    @Test func listQuotesTheEmptyReference() throws {
        let line = try encode(IMAPConnection.listAllCommand)
        print("LIST:", line.debugDescription)
        #expect(line == "P1 LIST \"\" \"*\"\r\n")
    }

    /// Bridge speaks IMAP4rev1 with few extensions: every command must use the base syntax.
    @Test func readCommandsUseBaseIMAPSyntax() throws {
        let inbox = MailboxName(Array("INBOX".utf8))
        let set = try #require(IMAPConnection.uidSet([7, 3]))
        let lines = [
            try encode(.examine(inbox)),
            try encode(.status(inbox, [.messageCount, .unseenCount])),
            try encode(.uidSearch(key: SearchKeyBuilder.key(for: .init(from: "bank", unread: true)))),
            try encode(.uidFetch(.set(set), [.uid, .flags, .envelope, .rfc822Size, .bodyStructure(extensions: true)], [])),
            try encode(.uidFetch(.set(set), [.uid, .bodySection(peek: true, .complete, nil)], [])),
        ]
        for line in lines { print("CMD:", line.debugDescription) }
        #expect(lines[0] == "P1 EXAMINE \"INBOX\"\r\n" || lines[0] == "P1 EXAMINE INBOX\r\n")
        #expect(lines[1].hasPrefix("P1 STATUS ") && lines[1].contains("(MESSAGES UNSEEN)"))
        #expect(lines[2] == "P1 UID SEARCH FROM \"bank\" UNSEEN\r\n")
        #expect(lines[3].hasPrefix("P1 UID FETCH 3,7 (UID FLAGS ENVELOPE RFC822.SIZE BODYSTRUCTURE)"))
        #expect(lines[4].hasPrefix("P1 UID FETCH 3,7 (UID BODY.PEEK[])"))
    }
}
