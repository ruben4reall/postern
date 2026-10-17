import Foundation
import Testing
@testable import PosternMail
import PosternModel

@Suite struct MessageSanitizerTests {
    @Test func prefersTheHTMLPartAUserSees() throws {
        let message = try MessageSanitizer.sanitize(raw: eml("""
        From: "Shop" <news@shop.example>
        To: ruben@example.ch
        Subject: Offer
        Content-Type: multipart/alternative; boundary=alt

        --alt
        Content-Type: text/plain

        SECRET INSTRUCTION only in the plain part
        --alt
        Content-Type: text/html

        <p>Big sale</p>
        --alt--
        """), maxChars: 10_000)
        #expect(message.body == "Big sale")
        #expect(message.bodyWasHTML)
    }

    @Test func decodesHeadersAndAddresses() throws {
        let message = try MessageSanitizer.sanitize(raw: eml("""
        From: =?UTF-8?Q?Andr=C3=A9?= <andre@example.com>
        To: "Doe, Jane" <jane@example.com>, bob@example.com (Bob)
        Cc: Team: carol@example.com, dan@example.com;
        Subject: =?UTF-8?B?UsOpdW5pb24=?= demain
        Date: Fri, 16 Oct 2026 09:30:00 +0200
        Message-ID: <abc@example.com>
        References: <one@example.com> <two@example.com>

        Hi
        """), maxChars: 100)
        #expect(message.headers.from == [Address(name: "André", email: "andre@example.com")])
        #expect(message.headers.to.map(\.email) == ["jane@example.com", "bob@example.com"])
        #expect(message.headers.to.first?.name == "Doe, Jane")
        #expect(message.headers.cc.map(\.email) == ["carol@example.com", "dan@example.com"])
        #expect(message.headers.subject == "Réunion demain")
        #expect(message.headers.messageID == "<abc@example.com>")
        #expect(message.headers.references == ["<one@example.com>", "<two@example.com>"])
        #expect(message.headers.date != nil)
    }

    @Test func listsAttachmentsAndTruncates() throws {
        let message = try MessageSanitizer.sanitize(raw: eml("""
        Content-Type: multipart/mixed; boundary=m

        --m
        Content-Type: text/plain

        0123456789
        --m
        Content-Type: image/png; name="photo.png"
        Content-Transfer-Encoding: base64

        iVBORw0KGgo=
        --m--
        """), maxChars: 4)
        #expect(message.body == "0123")
        #expect(message.bodyTruncated)
        #expect(message.attachments == [AttachmentInfo(index: 1, filename: "photo.png", mimeType: "image/png", size: 8)])
    }

    @Test func cleansInvisibleCharactersInSubject() throws {
        let message = try MessageSanitizer.sanitize(raw: eml("Subject: Ur\u{200B}gent\u{E0041}\n\nx"), maxChars: 10)
        #expect(message.headers.subject == "Urgent")
    }
}

@Suite struct AttachmentExtractionTests {
    @Test func returnsTheDecodedBytesOfTheListedAttachment() throws {
        let raw = eml("""
        Content-Type: multipart/mixed; boundary=m

        --m
        Content-Type: text/plain

        Body
        --m
        Content-Type: text/plain; name="notes.txt"
        Content-Disposition: attachment; filename="notes.txt"
        Content-Transfer-Encoding: base64

        aGVsbG8gd29ybGQ=
        --m--
        """)
        let listed = try MessageSanitizer.sanitize(raw: raw, maxChars: 100).attachments
        #expect(listed.map(\.filename) == ["notes.txt"])
        let file = try MessageSanitizer.attachment(raw: raw, index: 1)
        #expect(file.filename == "notes.txt" && file.data == Data("hello world".utf8))
        #expect(throws: MIMEError.self) { try MessageSanitizer.attachment(raw: raw, index: 2) }
    }
}
