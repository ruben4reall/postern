import Foundation
import Testing
import PosternModel
@testable import PosternCompose

@Suite struct OutgoingMessageTests {
    let me = Address(name: "Ruben", email: "ruben@example.ch")

    func make(
        to: [Address] = [Address(name: "Anna", email: "anna@example.com")], cc: [Address] = [],
        bcc: [Address] = [], subject: String = "Hello", body: String = "Hi Anna"
    ) throws -> OutgoingMessage {
        try OutgoingMessage.make(from: me, to: to, cc: cc, bcc: bcc, subject: subject, body: body)
    }

    func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    @Test func rendersHeadersAndAQuotedPrintableBody() throws {
        let message = try make(subject: "Réunion demain", body: "Café à 10 h ?\nÀ demain")
        let raw = text(message.rfc822(includeBcc: false))
        #expect(raw.contains("From: \"Ruben\" <ruben@example.ch>\r\n"))
        #expect(raw.contains("To: \"Anna\" <anna@example.com>\r\n"))
        #expect(raw.contains("Subject: =?UTF-8?B?"))
        #expect(raw.contains("Content-Type: text/plain; charset=utf-8\r\n"))
        #expect(raw.contains("Content-Transfer-Encoding: quoted-printable\r\n"))
        #expect(raw.contains("Caf=C3=A9 =C3=A0 10 h ?\r\n=C3=80 demain"))
        #expect(raw.contains("Message-ID: <") && raw.contains("@example.ch>\r\n"))
        #expect(!raw.contains("\n\n") || raw.contains("\r\n\r\n"))
    }

    @Test func keepsBccOutOfTheSentHeadersButInTheEnvelope() throws {
        let message = try make(bcc: [Address(name: nil, email: "hidden@example.org")])
        #expect(!text(message.rfc822(includeBcc: false)).contains("hidden@example.org"))
        #expect(text(message.rfc822(includeBcc: true)).contains("Bcc: hidden@example.org\r\n"))
        #expect(message.envelopeRecipients == ["anna@example.com", "hidden@example.org"])
    }

    @Test func refusesHeaderInjection() {
        #expect(throws: ComposeError.headerInjection) { try make(subject: "Hi\r\nBcc: evil@example.com") }
        #expect(throws: ComposeError.self) {
            try make(to: [Address(name: "A\nBcc: x@y.z", email: "a@example.com")])
        }
    }

    @Test(arguments: ["no-at-sign", "a@b", "a b@example.com", "<a@example.com>", "a@example.com\r\n", "a,b@example.com"])
    func refusesInvalidAddresses(_ email: String) {
        #expect(throws: ComposeError.self) { try make(to: [Address(name: nil, email: email)]) }
    }

    @Test func needsARecipient() {
        #expect(throws: ComposeError.noRecipient) { try make(to: []) }
    }

    @Test func removesInvisibleCharactersSoThePanelShowsWhatLeaves() throws {
        let message = try make(subject: "Pay\u{200B}ment", body: "Total\u{202E} 100")
        #expect(message.subject == "Payment")
        #expect(message.body == "Total 100")
    }

    @Test func theDigestCoversEveryByteAndEveryRecipient() throws {
        let message = try make()
        var changed = message
        changed.body += "."
        #expect(message.digest != changed.digest)
        var moreRecipients = message
        moreRecipients.bcc.append(Address(name: nil, email: "x@example.net"))
        #expect(message.digest != moreRecipients.digest)
        #expect(message.digest == message.digest)
        #expect(message.digest.count == 64)
    }

    @Test func wrapsLongLinesWithSoftBreaks() throws {
        let message = try make(body: String(repeating: "a", count: 200))
        let lines = text(message.rfc822(includeBcc: false)).components(separatedBy: "\r\n")
        #expect(lines.allSatisfy { $0.utf8.count <= 998 })
        let body = lines.drop { !$0.isEmpty }.dropFirst()
        #expect(body.allSatisfy { $0.count <= 76 })
        #expect(body.first?.hasSuffix("=") == true)
    }
}

@Suite struct OutgoingAttachmentTests {
    let me = Address(name: nil, email: "me@example.ch")
    let anna = Address(name: nil, email: "anna@example.com")

    func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    @Test func rendersAMultipartMessageWithBase64Attachments() throws {
        let file = try OutgoingAttachment.make(filename: "Facture n°1.pdf", data: Data("%PDF-1.7 test".utf8))
        let message = try OutgoingMessage.make(from: me, to: [anna], subject: "Invoice", body: "Here it is", attachments: [file])
        let raw = text(message.rfc822(includeBcc: false))
        #expect(raw.contains("Content-Type: multipart/mixed; boundary=\""))
        #expect(raw.contains("Content-Type: application/pdf; name=\"Facture n1.pdf\""))
        #expect(raw.contains("Content-Disposition: attachment; filename=\"Facture n1.pdf\"; filename*=utf-8''Facture%20n%C2%B01.pdf"))
        #expect(raw.contains(Data("%PDF-1.7 test".utf8).base64EncodedString()))
        #expect(raw.contains("Here it is"))
        #expect(file.mimeType == "application/pdf")
        #expect(file.sha256.count == 64)
    }

    @Test func theDigestCoversTheAttachmentBytes() throws {
        let one = try OutgoingAttachment.make(filename: "a.txt", data: Data("one".utf8))
        let two = try OutgoingAttachment.make(filename: "a.txt", data: Data("two".utf8))
        let first = try OutgoingMessage.make(from: me, to: [anna], subject: "S", body: "B", attachments: [one])
        var second = first
        second.attachments = [two]
        #expect(first.digest != second.digest)
        #expect(first.digest == first.digest)
    }

    @Test(arguments: ["../secret", "a/b.txt", "a\\b", "bad\nname.txt", "", ".hidden"])
    func refusesUnsafeFileNames(_ name: String) {
        #expect(throws: ComposeError.self) { try OutgoingAttachment.make(filename: name, data: Data("x".utf8)) }
    }

    @Test func refusesMoreThanTheSizeLimit() throws {
        let big = try OutgoingAttachment.make(filename: "big.bin", data: Data(count: OutgoingMessage.maxAttachmentBytes + 1))
        #expect(throws: ComposeError.tooLong) {
            try OutgoingMessage.make(from: me, to: [anna], subject: "S", body: "B", attachments: [big])
        }
    }
}
