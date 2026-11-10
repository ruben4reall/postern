import Foundation
import Testing
@testable import PosternMail

/// A random source that gives the same run every time, so a failure found here can be replayed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Input built to break the parser: thousands of random messages and pages, deep nesting, broken encodings. Nothing
/// may crash, hang, or let hidden words through. The parser runs in its own sandboxed process, but a crash there
/// still leaves an email unreadable.
@Suite struct HostileInputTests {
    // MARK: Nesting

    @Test func rendersNestingAsDeepAsRealMail() async {
        // 900 levels: deeper than any real email, still read in full.
        let html = String(repeating: "<div><span>", count: 450) + "Bottom" + String(repeating: "</span></div>", count: 450)
        let rendering = await Task.detached { HTMLSanitizer().render(html) }.value
        #expect(rendering.text.contains("Bottom"))
    }

    /// Deeper than that, a page is built to stall the parser or to bury words: it is refused at once, on a
    /// secondary thread whose stack is small.
    @Test(arguments: [2_000, 100_000, 1_000_000])
    func refusesNestingNoMailNeeds(_ depth: Int) async throws {
        let html = String(repeating: "<div>", count: depth) + "Bottom" + String(repeating: "</div>", count: depth)
        let start = Date()
        let rendering = await Task.detached { HTMLSanitizer().render(html) }.value
        #expect(!rendering.text.contains("Bottom"))
        #expect(rendering.text.contains("did not show"))
        #expect(Date().timeIntervalSince(start) < 45)
    }

    @Test func nestingIsCountedAsAParserWouldCountIt() {
        // Paragraphs, items and cells close themselves; comments and scripts hold no elements.
        let flat = String(repeating: "<p>a<li>b<td>c<br><img src=x>", count: 5_000)
            + "<!--" + String(repeating: "<div>", count: 5_000) + "-->"
            + "<script>" + String(repeating: "<div>", count: 5_000) + "</script>"
        #expect(!NestingGuard.exceeds(flat, depth: 1_000))
        #expect(NestingGuard.exceeds(String(repeating: "<b>", count: 1_001), depth: 1_000))
        #expect(!NestingGuard.exceeds(String(repeating: "<b>x</b>", count: 50_000), depth: 1_000))
        // Found in review: tags that close nothing, comments that end early, quotes outside values.
        #expect(NestingGuard.exceeds(String(repeating: "<div></x>", count: 2_000), depth: 1_000))
        #expect(NestingGuard.exceeds(String(repeating: "<!--><div>", count: 2_000), depth: 1_000))
        #expect(NestingGuard.exceeds(String(repeating: "<div \"x>", count: 2_000), depth: 1_000))
        // Ordinary tables with an unclosed font in every cell.
        let rows = "<table>" + String(repeating: "<tr><td><font face=Arial>Row</td></tr>", count: 1_100) + "</table>"
        #expect(!NestingGuard.exceeds(rows, depth: 1_000))
        #expect(!NestingGuard.exceeds(String(repeating: "<p><span>text", count: 2_000), depth: 1_000))
        // Found in the second review: an end tag stops at a block, raw text ends only at its own name.
        #expect(NestingGuard.exceeds(String(repeating: "<span><div></span>", count: 1_000), depth: 1_000))
        #expect(NestingGuard.exceeds("<style></styles><!--</style>" + String(repeating: "<div>", count: 1_001), depth: 1_000))
    }

    /// Pages built to make the reader slow: each is read or refused within seconds.
    @Test(arguments: [
        "<style>p:nth-child(2){display:none}</style><div>" + String(repeating: "<p>a</p>", count: 20_000) + "</div>",
        String(repeating: "<b hidden></b>", count: 20_000) + "<p>end</p>",
        "<style>" + String(repeating: "/* ", count: 20_000) + "</style><p>end</p>",
        "<style>" + String(repeating: ".a{color:red}", count: 6_000) + "</style><p>end</p>",
    ])
    func staysFastOnPagesBuiltToStallIt(_ html: String) async {
        let start = Date()
        _ = await Task.detached { HTMLSanitizer().render(html) }.value
        #expect(Date().timeIntervalSince(start) < 45)
    }

    @Test func judgesManyDeepTextsInLinearTime() async {
        // Each level holds text, so judging every text by walking up to the top would take depth squared steps.
        let depth = 900
        let html = (0..<depth).map { "<div style=\"color:#333\">t\($0) " }.joined() + String(repeating: "</div>", count: depth)
        let start = Date()
        let rendering = await Task.detached { HTMLSanitizer().render(html) }.value
        #expect(rendering.text.contains("t899"))
        #expect(Date().timeIntervalSince(start) < 45)
    }

    @Test func nestedLinksKeepTheirText() {
        let rendering = HTMLSanitizer().render("<a href=\"https://a.example\">outer <a href=\"https://b.example\">inner</a> end</a>")
        #expect(rendering.text.contains("outer"))
        #expect(rendering.text.contains("inner"))
        #expect(!rendering.links.isEmpty)
    }

    // MARK: Random pages

    private static let shownStyles = [
        "color:#333333", "color:#1a1a1a", "background:#ffffff", "font-size:14px", "font-weight:bold", "margin:4px",
        "padding:2px 8px", "text-align:center", "line-height:1.4", "display:block", "display:inline-block",
        "font-size:1.1em", "color:navy", "border:1px solid #eeeeee",
    ]

    /// Tricks that hide what is inside, whatever is around it on a white page.
    private static let hidingStyles = [
        "display:none", "visibility:hidden", "opacity:0", "font-size:0", "font-size:1px", "color:#ffffff",
        "color:#fefefe", "color:rgb(255 255 255)", "color:hsl(0,0%,100%)", "color:transparent",
        "height:0;overflow:hidden", "max-height:0px;overflow:hidden", "position:absolute;left:-9999px",
        "text-indent:-9999px", "transform:scale(0)", "filter:opacity(0)", "margin-left:-9999px",
        "clip-path:inset(50%)", "zoom:0.01", "content-visibility:hidden",
    ]

    private static let tags = ["div", "span", "p", "b", "i", "td", "font", "section", "blockquote", "em", "li", "a"]

    /// A random page with words a reader sees and words hidden by one of the tricks, somewhere in it.
    static func randomPage(_ random: inout SeededGenerator) -> String {
        func element(_ depth: Int) -> String {
            let tag = tags.randomElement(using: &random)!
            let style = Bool.random(using: &random) ? " style=\"\(shownStyles.randomElement(using: &random)!)\"" : ""
            let href = tag == "a" ? " href=\"https://example.com/\(Int.random(in: 0..<99, using: &random))\"" : ""
            var inner = ""
            for _ in 0..<Int.random(in: 0...3, using: &random) {
                switch Int.random(in: 0..<10, using: &random) {
                case 0..<4 where depth < 12: inner += element(depth + 1)
                case 4: inner += "<span style=\"\(hidingStyles.randomElement(using: &random)!)\">HIDDENWORD</span>"
                case 5: inner += "<br>"
                default: inner += "VISIBLEWORD "
                }
            }
            let open = tag == "td" ? "<table><tr><td\(style)>" : "<\(tag)\(style)\(href)>"
            let close = tag == "td" ? "</td></tr></table>" : "</\(tag)>"
            return open + inner + close
        }
        let hidden = "<div style=\"\(hidingStyles.randomElement(using: &random)!)\">HIDDENWORD</div>"
        return "<html><body>" + element(0) + hidden + element(0) + "<p>VISIBLEWORD</p></body></html>"
    }

    @Test func randomPagesNeverShowHiddenWords() {
        var random = SeededGenerator(seed: 20_261_110)
        for round in 0..<3_000 {
            let html = Self.randomPage(&random)
            let text = HTMLSanitizer().render(html).text
            #expect(!text.contains("HIDDENWORD"), "round \(round): \(html)")
            #expect(text.contains("VISIBLEWORD"), "round \(round): \(html)")
        }
    }

    @Test func randomBytesAsHTMLNeverCrash() {
        var random = SeededGenerator(seed: 7)
        let alphabet = Array("<>/=\"' abcdefgh-:;#!&{}()[]\n\t\u{0}\u{200B}\u{202E}éß😀".unicodeScalars)
        for _ in 0..<2_000 {
            let length = Int.random(in: 0..<400, using: &random)
            let text = String(String.UnicodeScalarView((0..<length).map { _ in alphabet.randomElement(using: &random)! }))
            _ = HTMLSanitizer().render(text)
        }
    }

    // MARK: Random messages

    static let sample = eml("""
    From: Anna Keller <anna@studio.example>
    To: ruben@example.ch
    Subject: =?UTF-8?B?RmFjdHVyZSBkJ8OpdMOp?=
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="outer"

    --outer
    Content-Type: multipart/alternative; boundary="inner"

    --inner
    Content-Type: text/plain; charset=utf-8
    Content-Transfer-Encoding: quoted-printable

    Bonjour, voici la facture =C3=A9t=C3=A9.=
     Merci.
    --inner
    Content-Type: text/html; charset=utf-8

    <p>Bonjour, <b>voici</b> la facture.</p><div style="display:none">SECRET</div>
    --inner--
    --outer
    Content-Type: application/pdf; name="facture.pdf"
    Content-Disposition: attachment; filename*=UTF-8''facture%20%C3%A9t%C3%A9.pdf
    Content-Transfer-Encoding: base64

    JVBERi0xLjQKJcOkw7zDtsOfCjIgMCBvYmoKPDwvTGVuZ3RoIDMgMCBSPj4Kc3RyZWFtCg==
    --outer
    Content-Type: image/png
    Content-Disposition: inline; filename="logo.png"
    Content-Transfer-Encoding: base64

    iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==
    --outer--
    """)

    @Test func theSampleReadsAsExpected() throws {
        let message = try MessageSanitizer.sanitize(raw: Self.sample, maxChars: 10_000)
        #expect(message.body.contains("voici"))
        #expect(!message.body.contains("SECRET"))
        #expect(message.attachments.contains { $0.filename == "facture été.pdf" })
    }

    /// Byte flips, cuts, repeated and lost boundaries, stray headers: whatever comes back, nothing crashes.
    @Test func mutatedMessagesNeverCrash() {
        var random = SeededGenerator(seed: 42)
        let base = Array(Self.sample)
        let pieces: [[UInt8]] = [
            Array("--outer\r\n".utf8), Array("--inner--\r\n".utf8), Array("Content-Type: multipart/mixed; boundary=\"outer\"\r\n\r\n".utf8),
            Array("Content-Transfer-Encoding: base64\r\n".utf8), Array("=?UTF-8?Q?=C3?=".utf8), Array("=\r\n".utf8),
            Array("filename*0*=UTF-8''%E2%82; filename*1*=%AC".utf8), [0xFF, 0xFE, 0x00, 0x0D], Array("\r\n\r\n".utf8),
        ]
        for round in 0..<3_000 {
            var bytes = base
            for _ in 0..<Int.random(in: 1...6, using: &random) where !bytes.isEmpty {
                let at = Int.random(in: 0..<bytes.count, using: &random)
                switch Int.random(in: 0..<5, using: &random) {
                case 0: bytes[at] = UInt8.random(in: 0...255, using: &random)
                case 1: bytes.removeSubrange(at..<min(bytes.count, at + Int.random(in: 1...40, using: &random)))
                case 2: bytes.insert(contentsOf: pieces.randomElement(using: &random)!, at: at)
                case 3: bytes = Array(bytes.prefix(at))
                default: bytes.insert(contentsOf: bytes[at..<min(bytes.count, at + 60)], at: at)
                }
            }
            let raw = Data(bytes)
            // A flipped byte can undo the hiding itself (an open quote swallows the hiding tag, as it would in a
            // browser), so only crashes are looked for here; hidden words are the random pages' test.
            if let message = try? MessageSanitizer.sanitize(raw: raw, maxChars: 5_000) {
                for index in 1...(message.attachments.count + 1) {
                    _ = try? MessageSanitizer.attachment(raw: raw, index: index)
                }
            }
        }
    }

    @Test func deepMultipartIsRefusedNotFollowed() {
        var text = "Content-Type: text/plain\r\n\r\nend"
        for level in 0..<500 {
            text = "Content-Type: multipart/mixed; boundary=\"b\(level)\"\r\n\r\n--b\(level)\r\n" + text + "\r\n--b\(level)--\r\n"
        }
        #expect(throws: (any Error).self) { try MessageSanitizer.sanitize(raw: Data(text.utf8), maxChars: 1_000) }
    }

    // MARK: Encodings

    @Test(arguments: [
        ("QUJD", "ABC"), ("QUJD\r\n", "ABC"), ("QU\r\nJD", "ABC"), ("QUJDRA==", "ABCD"), ("QUJDRA", "ABCD"),
        // A stray character at the end used to lose the whole file.
        ("QUJDRA==X", "ABCD"), ("QUJDX", "ABC"),
        // Two encoded pieces put end to end, each with its padding.
        ("QQ==Qg==", "AB"),
    ])
    func decodesBase64AsMailClientsDo(_ input: String, _ expected: String) {
        #expect(String(decoding: TransferDecoding.base64(Data(input.utf8)), as: UTF8.self) == expected)
    }

    @Test(arguments: [("=41=42", "AB"), ("=+1", "=+1"), ("=-0x", "=-0x"), ("a=\r\nb", "ab"), ("=4", "=4")])
    func decodesQuotedPrintableStrictly(_ input: String, _ expected: String) {
        #expect(String(decoding: TransferDecoding.quotedPrintable(Data(input.utf8)), as: UTF8.self) == expected)
    }
}
