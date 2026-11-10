import Foundation
import Testing
@testable import PosternMail

/// Ways to hide words from the reader while an app still reads them: the ground prompt injection hides in. Each
/// one here passed the sanitizer before 0.2.0.
@Suite struct HiddenTextTricksTests {
    let sanitizer = HTMLSanitizer()

    @Test(arguments: [
        // Colors a reader cannot tell from the page.
        "<p>Visible</p><p style=\"color:#fefefe\">SECRET</p>",
        "<p>Visible</p><p style=\"color:whitesmoke\">SECRET</p>",
        "<p>Visible</p><p style=\"color:rgb(255 255 255)\">SECRET</p>",
        "<p>Visible</p><p style=\"color:rgb(100%, 100%, 100%)\">SECRET</p>",
        "<p>Visible</p><p style=\"color:rgba(255,255,255,1)\">SECRET</p>",
        "<p>Visible</p><p style=\"color:hsl(0, 0%, 100%)\">SECRET</p>",
        "<p>Visible</p><p style=\"color:hsl(0deg 0% 99%)\">SECRET</p>",
        "<p>Visible</p><p style=\"color:#ffffffff\">SECRET</p>",
        "<p>Visible</p><p style=\"color:#fff0\">SECRET</p>",
        "<p>Visible</p><p style=\"color:rgba(0,0,0,0.03)\">SECRET</p>",
        "<div style=\"background:url(x.png) no-repeat #123456\"><p style=\"color:#fff\">Visible</p><span style=\"color:#123456\">SECRET</span></div>",
        "<div style=\"background-color:#000\"><p style=\"color:#fff\">Visible</p><span style=\"color:#050505\">SECRET</span></div>",
        "<table><tr><td bgcolor=\"navy\"><p style=\"color:#fff\">Visible</p><font color=\"#000080\">SECRET</font></td></tr></table>",
        // Proton does not load remote images until asked: behind the text is the fallback color, or the page.
        "<p>Visible</p><div style=\"background:url(https://cdn.example/hero.jpg) #ffffff\"><p style=\"color:#ffffff\">SECRET</p></div>",
        "<p>Visible</p><div style=\"background-image:url(hero.jpg)\"><p style=\"color:#ffffff\">SECRET</p></div>",
        "<p>Visible</p><table><tr><td background=\"https://cdn.example/hero.jpg\"><span style=\"color:#fff\">SECRET</span></td></tr></table>",
        // Sizes that inherit a size of zero.
        "<p>Visible</p><div style=\"font-size:0\"><span style=\"font-size:100%\">SECRET</span></div>",
        "<p>Visible</p><div style=\"font-size:0\"><span style=\"font-size:2em\">SECRET</span></div>",
        "<p>Visible</p><div style=\"font-size:0.5px\"><p><b>SECRET</b></p></div>",
        "<p>Visible</p><p style=\"font-size:0.05vw\">SECRET</p>",
        // Boxes moved, shrunk or faded out of sight.
        "<p>Visible</p><p style=\"filter:opacity(0)\">SECRET</p>",
        "<p>Visible</p><p style=\"filter: opacity(2%)\">SECRET</p>",
        "<p>Visible</p><p style=\"transform:scale(0.01)\">SECRET</p>",
        "<p>Visible</p><p style=\"transform:scaleY(0)\">SECRET</p>",
        "<p>Visible</p><p style=\"transform:translateX(-9999px)\">SECRET</p>",
        "<p>Visible</p><p style=\"margin-left:-9999px\">SECRET</p>",
        "<p>Visible</p><p style=\"margin:0 0 0 -5000px\">SECRET</p>",
        "<p>Visible</p><p style=\"zoom:0.01\">SECRET</p>",
        "<p>Visible</p><p style=\"content-visibility:hidden\">SECRET</p>",
        // A closed disclosure: only its summary shows until someone clicks it.
        "<details><summary>Visible</summary>SECRET</details>",
        "<details><summary>Visible</summary><p>SECRET</p></details>",
        // Rules that select by position or by what an element is not.
        "<style>p:not(.keep) { display:none }</style><p class=\"keep\">Visible</p><p>SECRET</p>",
        "<style>div p:nth-child(2) { display:none }</style><div><p>Visible</p><p>SECRET</p></div>",
        "<style>div p:last-child { visibility:hidden }</style><div><p>Visible</p><p>SECRET</p></div>",
    ])
    func removesHiddenText(_ html: String) {
        let rendering = sanitizer.render(html)
        #expect(rendering.text.contains("Visible"), "\(html)")
        #expect(!rendering.text.contains("SECRET"), "\(html)")
    }

    /// What ordinary mail does with color, size and position, which a reader sees.
    @Test(arguments: [
        "<p style=\"color:#999999\">Shown</p>",
        "<p style=\"color:#cccccc\">Shown</p>",
        "<p style=\"color:lightgray\">Shown</p>",
        "<p style=\"color:#e5e5e5;background:#333333\">Shown</p>",
        "<div style=\"background:#222\"><p style=\"color:hsl(0,0%,90%)\">Shown</p></div>",
        // White text on a picture the email carries, or on a remote picture's dark fallback color.
        "<div style=\"background:url(cid:hero@studio) #ffffff\"><p style=\"color:#ffffff\">Shown</p></div>",
        "<div style=\"background-image:url('data:image/png;base64,iVBORw0KGgo=')\"><p style=\"color:#ffffff\">Shown</p></div>",
        "<table><tr><td background=\"https://cdn.example/hero.jpg\" bgcolor=\"#1a1a1a\"><span style=\"color:#fff\">Shown</span></td></tr></table>",
        "<div style=\"background:linear-gradient(#000,#333)\"><p style=\"color:#fff\">Shown</p></div>",
        // Sizes set again inside a zero-size wrapper.
        "<div style=\"font-size:0\"><span style=\"font-size:14px\">Shown</span></div>",
        "<div style=\"font-size:0\"><span style=\"font-size:1rem\">Shown</span></div>",
        "<p style=\"font-size:x-small\">Shown</p>",
        "<p style=\"font-size:0.8em\">Shown</p>",
        // Small nudges and effects.
        "<p style=\"margin-left:-10px\">Shown</p>",
        "<p style=\"transform:scale(1.2)\">Shown</p>",
        "<p style=\"transform:translateY(-4px)\">Shown</p>",
        "<p style=\"filter:opacity(80%)\">Shown</p>",
        "<p style=\"zoom:1.5\">Shown</p>",
        // An open disclosure, and rules that apply only on hover or focus.
        "<details open><summary>Title</summary>Shown</details>",
        "<style>a:hover { display:none }</style><a href=\"https://example.com\">Shown</a>",
        "<style>p:focus { visibility:hidden }</style><p>Shown</p>",
        // A rule SwiftSoup understands but no browser does.
        "<style>p:contains(Shown) { display:none }</style><p>Shown</p>",
    ])
    func keepsVisibleText(_ html: String) {
        #expect(sanitizer.render(html).text.contains("Shown"), "\(html)")
    }

    @Test func keepsTheSummaryOfAClosedDisclosure() {
        let rendering = sanitizer.render("<details><summary>Order details</summary><p>SECRET</p></details>")
        #expect(rendering.text == "Order details")
        #expect(rendering.hiddenElementsRemoved > 0)
    }
}
