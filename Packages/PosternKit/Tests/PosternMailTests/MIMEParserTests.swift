import Foundation
import Testing
@testable import PosternMail

@Suite struct MIMEParserTests {
    @Test func parsesASimpleMessage() throws {
        let entity = try MIMEParser.parse(eml("""
        From: Alice <alice@example.com>
        Subject: =?UTF-8?Q?Caf=C3=A9?=
        Content-Type: text/plain; charset=utf-8

        Hello there
        """))
        #expect(entity.header("subject") == "=?UTF-8?Q?Caf=C3=A9?=")
        #expect(entity.text == "Hello there")
    }

    @Test func decodesQuotedPrintableAndBase64() throws {
        let qp = try MIMEParser.parse(eml("""
        Content-Type: text/plain; charset=iso-8859-1
        Content-Transfer-Encoding: quoted-printable

        Caf=E9 tr=E8s long=
         suite
        """))
        #expect(qp.text == "Café très long suite")
        let b64 = try MIMEParser.parse(eml("""
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: base64

        Qm9uam91ciDDoCB0b3Vz
        """))
        #expect(b64.text == "Bonjour à tous")
    }

    @Test func splitsMultipartAndReadsRFC2231FileNames() throws {
        let entity = try MIMEParser.parse(eml("""
        Content-Type: multipart/mixed; boundary="b1"

        --b1
        Content-Type: text/plain

        Body
        --b1
        Content-Type: application/pdf
        Content-Disposition: attachment; filename*=utf-8''Facture%20n%C2%B01.pdf
        Content-Transfer-Encoding: base64

        JVBERi0=
        --b1--
        """))
        guard case .multipart(let parts) = entity.body else { Issue.record("not multipart"); return }
        #expect(parts.count == 2)
        #expect(parts[0].text == "Body")
        #expect(parts[1].filename == "Facture n°1.pdf")
        #expect(parts[1].isAttachment)
        #expect(parts[1].decodedBody == Data("%PDF-".utf8))
    }

    @Test func rejectsTooDeepNesting() {
        var body = "Content-Type: text/plain\n\nx\n"
        for level in 0..<10 {
            body = "Content-Type: multipart/mixed; boundary=\"l\(level)\"\n\n--l\(level)\n\(body)--l\(level)--\n"
        }
        #expect(throws: MIMEError.tooDeep) { try MIMEParser.parse(eml(body)) }
    }

    @Test func rejectsTooManyParts() {
        let parts = (0..<210).map { _ in "--b\nContent-Type: text/plain\n\nx\n" }.joined()
        let body = "Content-Type: multipart/mixed; boundary=b\n\n\(parts)--b--\n"
        #expect(throws: MIMEError.tooManyParts) { try MIMEParser.parse(eml(body)) }
    }

    @Test func survivesAMissingCloseDelimiter() throws {
        let entity = try MIMEParser.parse(eml("""
        Content-Type: multipart/alternative; boundary=x

        --x
        Content-Type: text/plain

        only part
        """))
        guard case .multipart(let parts) = entity.body else { Issue.record("not multipart"); return }
        #expect(parts.count == 1)
        #expect(parts[0].text.trimmingCharacters(in: .whitespacesAndNewlines) == "only part")
    }
}
