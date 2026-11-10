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
        // A picture carried in the email may be anything, a white square too: it does not count either.
        "<p>Visible</p><div style=\"background:url(cid:hero@studio) #ffffff\"><p style=\"color:#ffffff\">SECRET</p></div>",
        "<p>Visible</p><div style=\"background-image:url('data:image/png;base64,iVBORw0KGgo=')\"><p style=\"color:#ffffff\">SECRET</p></div>",
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

    /// Found by an independent review of 0.2.0, against what browsers and Proton's own sanitizer do.
    @Test(arguments: [
        // Declarations read as a browser reads them: invalid values dropped, comments and escapes, importance,
        // specificity, shorthands in order.
        "<p>Visible</p><p style=\"display:none;display:nonee\">SECRET</p>",
        "<p>Visible</p><p style=\"color:#fff;color:bogus\">SECRET</p>",
        "<p>Visible</p><p style=\"font-size:0;font-size:16qx\">SECRET</p>",
        "<p>Visible</p><p style=\"display:/**/none\">SECRET</p>",
        "<p>Visible</p><p style=\"display/**/:none\">SECRET</p>",
        "<p>Visible</p><p style=\"displ\\61y:none\">SECRET</p>",
        "<style>p.s{color:#fff !important}</style><p>Visible</p><p class=\"s\" style=\"color:#000\">SECRET</p>",
        "<style>#a p{color:#fff} p{color:#000}</style><p>Visible</p><div id=\"a\"><p>SECRET</p></div>",
        "<style>.s{color:#fff}</style><p>Visible</p><p class=\"s\" style=\"color:bogus\">SECRET</p>",
        "<p>Visible</p><p style=\"font-size:16px;font:0/0 a\">SECRET</p>",
        "<p>Visible</p><div style=\"background:#fff;background-color:#000\"><p>SECRET</p></div>",
        // Introduced by the first version of this change.
        "<p>Visible</p><div style=\"-webkit-text-fill-color:#fff\"><p style=\"color:#000\">SECRET</p></div>",
        "<p>Visible</p><div style=\"opacity:nan\"><p style=\"color:#fff\">SECRET</p></div>",
        "<p>Visible</p><div style=\"background:linear-gradient(#fff,#fff)\"><p style=\"color:#fff\">SECRET</p></div>",
        "<p>Visible</p><div style=\"color:#fff\"><a href=\"https://x.example\" style=\"color:inherit\">SECRET</a></div>",
        "<p>Visible</p><div style=\"color:#fff\"><p style=\"color:rgb(nan nan nan)\">SECRET</p></div>",
        "<p>Visible</p><div style=\"color:#fff\"><p style=\"color:rgb(0,0 0)\">SECRET</p></div>",
        "<p>Visible</p><div style=\"color:#fff\"><p style=\"color:000\">SECRET</p></div>",
        "<p>Visible</p><font color=\"fffffff\">SECRET</font>",
        "<p>Visible</p><table bgcolor=\"0000000\"><tr><td>SECRET</td></tr></table>",
        "<p>Visible</p><p style=\"font-size:0.01cqw\">SECRET</p>",
        "<p>Visible</p><p style=\"font-size:1e-3px\">SECRET</p>",
        "<p>Visible</p><p style=\"font-size:calc(0px)\">SECRET</p>",
        "<p>Visible</p><p style=\"font-size:min(0px, 1em)\">SECRET</p>",
        "<div><style>p:nth-child(3){color:#fff}</style><p>Visible</p><p>SECRET</p></div>",
        "<style>.x + p{color:#fff}</style><p>Visible</p><span class=\"x\" hidden></span><p>SECRET</p>",
        // Rules that used to be skipped.
        "<style>.x::first-line{color:#fff}</style><p>Visible</p><p class=\"x\">SECRET</p>",
        "<style>p.s:not(:hover){display:none}</style><p>Visible</p><p class=\"s\">SECRET</p>",
        "<style>:is(p.s, p.t){display:none}</style><p>Visible</p><p class=\"t\">SECRET</p>",
        "<style>a:link{color:#fff}</style><p>Visible</p><a href=\"https://x.example\">SECRET</a>",
        "<style>p[title=\"a:b\"]{display:none}</style><p>Visible</p><p title=\"a:b\">SECRET</p>",
        "<style>@layer x{.s{display:none}}</style><p>Visible</p><p class=\"s\">SECRET</p>",
        "<style>@container (min-width:0px){.s{display:none}}</style><p>Visible</p><p class=\"s\">SECRET</p>",
        "<style>.a{.b{display:none}}</style><p>Visible</p><div class=\"a\"><p class=\"b\">SECRET</p></div>",
        "<style>@media (min-width:801px){.s{display:none}}</style><p>Visible</p><p class=\"s\">SECRET</p>",
        // Elements a browser does not show.
        "<p>Visible</p><dialog>SECRET</dialog>",
        "<p>Visible</p><datalist><option>SECRET</option></datalist>",
        "<p>Visible</p><meter value=\"1\">SECRET</meter><progress>SECRET</progress>",
        "<p>Visible</p><ruby>a<rp>SECRET</rp><rt>b</rt></ruby>",
        "<details name=\"g\" open><summary>Visible</summary></details><details name=\"g\" open><summary>Two</summary>SECRET</details>",
        // Sizes, turns, blurs and clips.
        "<p>Visible</p><p style=\"transform:scale(0.1)\">SECRET</p>",
        "<p>Visible</p><p style=\"zoom:0.1\">SECRET</p>",
        "<p>Visible</p><div style=\"zoom:0.2\"><p style=\"zoom:0.2\">SECRET</p></div>",
        "<p>Visible</p><p style=\"transform:matrix(0.01,0,0,0.01,0,0)\">SECRET</p>",
        "<p>Visible</p><p style=\"transform:rotateX(90deg)\">SECRET</p>",
        "<p>Visible</p><p style=\"filter:blur(20px)\">SECRET</p>",
        "<p>Visible</p><p style=\"letter-spacing:-1em\">SECRET</p>",
        "<p>Visible</p><p style=\"font-size-adjust:0.001\">SECRET</p>",
        "<p>Visible</p><p style=\"overflow-y:clip;max-height:0\">SECRET</p>",
        "<p>Visible</p><p style=\"clip-path:inset(100%)\">SECRET</p>",
        "<p>Visible</p><p style=\"clip-path:polygon(0 0,0 0,0 0)\">SECRET</p>",
        "<p>Visible</p><p style=\"text-indent:100%;white-space:nowrap;overflow:hidden\">SECRET</p>",
        "<p>Visible</p><p style=\"position:relative;bottom:9999px\">SECRET</p>",
        "<p>Visible</p><p style=\"translate:-100em\">SECRET</p>",
        "<style>.s{position:relative;left:-9999px}</style><p>Visible</p><p class=\"s\">SECRET</p>",
        "<style>.s{text-indent:-100em}</style><p>Visible</p><p class=\"s\">SECRET</p>",
        // Every color form.
        "<p>Visible</p><p style=\"color:canvas\">SECRET</p>",
        "<p>Visible</p><p style=\"color:oklch(1 0 0)\">SECRET</p>",
        "<p>Visible</p><p style=\"color:oklab(0.999 0 0)\">SECRET</p>",
        "<p>Visible</p><p style=\"color:color(srgb 1 1 1)\">SECRET</p>",
        "<p>Visible</p><p style=\"color:hwb(0 100% 0%)\">SECRET</p>",
        "<p>Visible</p><p style=\"color:lab(100 0 0)\">SECRET</p>",
        "<p>Visible</p><p style=\"color:lch(99.5 0 0)\">SECRET</p>",
        "<p>Visible</p><p style=\"color:color-mix(in srgb, white 99%, black)\">SECRET</p>",
        "<p>Visible</p><div style=\"--c:#fff\"><p style=\"color:var(--c)\">SECRET</p></div>",
        "<p>Visible</p><p style=\"color:superlight(1)\">SECRET</p>",
    ])
    func removesWhatTheReviewFound(_ html: String) {
        let rendering = sanitizer.render(html)
        #expect(rendering.text.contains("Visible"), "\(html)")
        #expect(!rendering.text.contains("SECRET"), "\(html)")
    }

    @Test(arguments: [
        // Gradient and outlined headlines.
        "<h1 style=\"background:linear-gradient(#f00,#00f);-webkit-background-clip:text;-webkit-text-fill-color:transparent\">Shown</h1>",
        "<p style=\"-webkit-text-fill-color:transparent;-webkit-text-stroke:1px #000\">Shown</p>",
        // Custom properties, shorthands and the cascade.
        "<div style=\"--bg:#111;background:var(--bg)\"><p style=\"color:#fff\">Shown</p></div>",
        "<div style=\"--c:#333\"><p style=\"color:var(--c)\">Shown</p></div>",
        "<p style=\"font-size:0;font:14px Arial\">Shown</p>",
        "<style>p{display:none} p.show{display:block}</style><p class=\"show\">Shown</p>",
        "<p style=\"height:1em;overflow:hidden\">Shown</p>",
        "<p aria-hidden=\"true\">Shown</p>",
        "<p style=\"color:light-dark(#111, #eee)\">Shown</p>",
        "<p style=\"color:oklch(0.3 0.1 250)\">Shown</p>",
        "<p style=\"font-size:calc(16px - 2px)\">Shown</p>",
        "<p style=\"font-size:clamp(12px, 2vw, 18px)\">Shown</p>",
        "<table><tr><td>Shown<font face=Arial>, a cell</td></tr></table>",
    ])
    func keepsWhatReadersSee(_ html: String) {
        #expect(sanitizer.render(html).text.contains("Shown"), "\(html)")
    }

    /// Inputs that crashed the parser service.
    @Test(arguments: [
        "<p style=\"color:rgb()\">x</p>", "<p style=\"color:hsl(/)\">x</p>", "<td bgcolor=\"x()\">x</td>",
        "<font size=\"+9223372036854775807\">x</font>", "<font size=\"-9223372036854775808\">x</font>",
        "<style>" + String(repeating: "@media all{", count: 500) + ".x{display:none}" + String(repeating: "}", count: 500) + "</style><p>x</p>",
        "<p style=\"font-size:calc(((((1px)))))\">x</p>", "<p style=\"color:var(--a)\">x</p>",
        "<div style=\"--a:var(--b);--b:var(--a)\"><p style=\"color:var(--a)\">x</p></div>",
    ])
    func survivesWhatCrashedIt(_ html: String) {
        _ = sanitizer.render(html)
    }

    /// What ordinary mail does with color, size and position, which a reader sees.
    @Test(arguments: [
        "<p style=\"color:#999999\">Shown</p>",
        "<p style=\"color:#cccccc\">Shown</p>",
        "<p style=\"color:lightgray\">Shown</p>",
        "<p style=\"color:#e5e5e5;background:#333333\">Shown</p>",
        "<div style=\"background:#222\"><p style=\"color:hsl(0,0%,90%)\">Shown</p></div>",
        // White text on a remote picture's dark fallback color.
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
