import Testing
@testable import PosternMail

@Suite struct HTMLSanitizerTests {
    let sanitizer = HTMLSanitizer()

    @Test(arguments: [
        "<p>Visible</p><p style=\"display:none\">SECRET</p>",
        "<p>Visible</p><span style=\"visibility: hidden\">SECRET</span>",
        "<p>Visible</p><div style=\"opacity:0\">SECRET</div>",
        "<p>Visible</p><div style=\"font-size:0px\">SECRET</div>",
        "<p>Visible</p><div style=\"font-size: 1px\">SECRET</div>",
        "<p>Visible</p><div hidden>SECRET</div>",
        "<p>Visible</p><div aria-hidden=\"true\">SECRET</div>",
        "<style>.x { display: none }</style><p>Visible</p><p class=\"x\">SECRET</p>",
        "<style>/* c */ #y{visibility:hidden !important}</style><p>Visible</p><p id=\"y\">SECRET</p>",
        "<p>Visible</p><p style=\"color:#ffffff\">SECRET</p>",
        "<div style=\"background-color:#123456\"><p>Visible</p><span style=\"color:#123456\">SECRET</span></div>",
        "<p>Visible</p><font color=\"white\">SECRET</font>",
        "<p>Visible</p><div style=\"height:0;overflow:hidden\">SECRET</div>",
        "<p>Visible</p><div style=\"position:absolute;left:-9999px\">SECRET</div>",
        "<p>Visible</p><div style=\"color: rgba(0,0,0,0)\">SECRET</div>",
        "<p>Visible</p><!-- SECRET --><script>SECRET</script><noscript>SECRET</noscript>",
        "<p>Visible</p><template>SECRET</template><svg><text>SECRET</text></svg>",
    ])
    func removesHiddenText(_ html: String) {
        let rendering = sanitizer.render(html)
        #expect(rendering.text.contains("Visible"))
        #expect(!rendering.text.contains("SECRET"))
    }

    @Test func keepsWhiteTextOnADarkBackground() {
        let rendering = sanitizer.render("<table><tr><td bgcolor=\"#000000\"><span style=\"color:#fff\">Shown</span></td></tr></table>")
        #expect(rendering.text.contains("Shown"))
    }

    @Test func listsLinksWithTheirRealDestination() {
        let rendering = sanitizer.render("""
        <p>Pay at <a href="https://evil.example/login">www.paypal.com</a> or
        <a href="https://xn--pypal-4ve.com/">here</a>, or <a href="https://shop.example.com/a">example.com</a>.</p>
        <a href="javascript:alert(1)">click</a>
        """)
        #expect(rendering.links.count == 3)
        #expect(rendering.links[0].host == "evil.example")
        #expect(rendering.links[0].textLooksLikeOtherHost)
        #expect(rendering.links[1].suspiciousHost)
        #expect(!rendering.links[2].textLooksLikeOtherHost)
        #expect(rendering.text.contains("www.paypal.com [link 1]"))
        #expect(!rendering.text.contains("javascript"))
    }

    @Test func describesImagesWithoutFetchingThem() {
        let rendering = sanitizer.render("<img src=\"https://tracker.example/p.gif\" alt=\"Logo\"><img src=\"x\">")
        #expect(rendering.text == "[image: Logo]")
        #expect(rendering.imagesOmitted == 2)
    }

    @Test func keepsStructureReadable() {
        let rendering = sanitizer.render("<h1>Title</h1><p>One</p><ul><li>A</li><li>B</li></ul><p>Two<br>Three</p>")
        #expect(rendering.text == "Title\nOne\n- A\n- B\nTwo\nThree")
    }

    @Test func stripsInvisibleCharactersInsideText() {
        let rendering = sanitizer.render("<p>pay\u{200B}pal \u{202E}gnp.exe</p>")
        #expect(rendering.text == "paypal gnp.exe")
    }
}
