import Foundation
import PosternModel
import PosternText
import SwiftSoup

/// What a reader would see of an HTML body, as plain text.
public struct HTMLRendering: Sendable {
    public var text: String
    public var links: [LinkInfo]
    public var hiddenElementsRemoved: Int
    public var imagesOmitted: Int
}

/// Turns hostile HTML into the text a human would actually see.
///
/// Anything a mail client would not display is removed before conversion: scripts, styles, hidden elements
/// (by attribute, inline style, or simple `<style>` rules), text drawn in the background color. Images are
/// never fetched; links are listed with their real destination.
public struct HTMLSanitizer: Sendable {
    public init() {}

    private static let invisibleTags = [
        "script", "style", "head", "title", "template", "noscript", "iframe", "frame", "frameset", "object", "embed",
        "applet", "svg", "math", "meta", "link", "base", "canvas", "audio", "video", "source", "track", "map", "input",
        "select", "textarea", "button",
    ].joined(separator: ", ")

    private static let blockTags: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "table", "tbody", "thead", "tfoot", "tr",
        "blockquote", "section", "article", "header", "footer", "li", "pre", "address", "center", "dl", "dt", "dd",
        "form", "fieldset", "figure", "figcaption", "main", "nav", "aside", "body", "html", "caption",
    ]

    public func render(_ html: String) -> HTMLRendering {
        guard let document = try? SwiftSoup.parse(html) else {
            return HTMLRendering(text: "", links: [], hiddenElementsRemoved: 0, imagesOmitted: 0)
        }
        var removed = 0
        removed += removeStyleSheetHiddenElements(document)
        if let invisible = try? document.select(Self.invisibleTags) {
            for element in invisible.array() { try? element.remove() }
        }
        removed += removeInlineHiddenElements(document)

        var renderer = TextRenderer()
        renderer.render(document.body() ?? document)
        let text = Self.normalize(renderer.output)
        return HTMLRendering(
            text: text, links: renderer.links, hiddenElementsRemoved: removed, imagesOmitted: renderer.images
        )
    }

    // MARK: Hidden content

    /// Applies `display:none`-like rules from `<style>` blocks for selectors SwiftSoup understands.
    private func removeStyleSheetHiddenElements(_ document: Document) -> Int {
        guard let styles = try? document.select("style") else { return 0 }
        var removed = 0
        let rule = #/([^{}]+)\{([^{}]*)\}/#
        for style in styles.array() {
            let css = style.data().replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
            for match in css.matches(of: rule) where StyleRules.hides(String(match.2), background: nil) {
                for selector in match.1.split(separator: ",") {
                    let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, !trimmed.contains(":"), !trimmed.hasPrefix("@") else { continue }
                    guard let elements = try? document.select(trimmed) else { continue }
                    for element in elements.array() where element.parent() != nil {
                        try? element.remove()
                        removed += 1
                    }
                }
            }
        }
        return removed
    }

    private func removeInlineHiddenElements(_ document: Document) -> Int {
        guard let all = try? document.getAllElements() else { return 0 }
        var hidden: [Element] = []
        for element in all.array() where isHidden(element) {
            hidden.append(element)
        }
        var removed = 0
        for element in hidden where element.parent() != nil {
            try? element.remove()
            removed += 1
        }
        return removed
    }

    private func isHidden(_ element: Element) -> Bool {
        if element.hasAttr("hidden") { return true }
        if (try? element.attr("aria-hidden"))?.lowercased() == "true" { return true }
        let style = (try? element.attr("style")) ?? ""
        let fontColor = element.tagName() == "font" ? (try? element.attr("color")) : nil
        let background = effectiveBackground(of: element.parent())
        if StyleRules.hides(style, background: background) { return true }
        if let fontColor, !fontColor.isEmpty, StyleRules.sameColor(fontColor, background) { return true }
        return false
    }

    /// The nearest declared background, or white, which is how Proton shows a message.
    private func effectiveBackground(of start: Element?) -> String {
        var element = start
        while let current = element {
            let style = (try? current.attr("style")) ?? ""
            if let color = StyleRules.backgroundColor(in: style) { return color }
            if let attribute = try? current.attr("bgcolor"), !attribute.isEmpty { return attribute }
            element = current.parent()
        }
        return "#ffffff"
    }

    private static func normalize(_ text: String) -> String {
        let lines = UnicodeCleaner.clean(text).split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.replacing(#/[ \t]+/#, with: " ").trimmingCharacters(in: .whitespaces)
        }
        var output: [String] = []
        var blank = 0
        for line in lines {
            if line.isEmpty {
                blank += 1
                if blank > 1 { continue }
            } else {
                blank = 0
            }
            output.append(line)
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Text rendering

    private struct TextRenderer {
        var output = ""
        var links: [LinkInfo] = []
        var images = 0

        mutating func render(_ node: Node) {
            for child in node.getChildNodes() {
                if let text = child as? TextNode {
                    output += text.text()
                } else if let element = child as? Element {
                    renderElement(element)
                }
            }
        }

        private mutating func renderElement(_ element: Element) {
            let tag = element.tagName()
            switch tag {
            case "br":
                output += "\n"
            case "hr":
                newline(); output += "---"; newline()
            case "img":
                images += 1
                let alt = UnicodeCleaner.clean((try? element.attr("alt")) ?? "", keepNewlines: false)
                    .trimmingCharacters(in: .whitespaces)
                if !alt.isEmpty { output += "[image: \(alt.prefix(100))]" }
            case "a":
                var inner = TextRenderer()
                inner.images = 0
                inner.render(element)
                images += inner.images
                let text = inner.output.replacing(#/\s+/#, with: " ").trimmingCharacters(in: .whitespaces)
                let href = ((try? element.attr("href")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                output += text
                if let link = LinkInspector.inspect(href: href, text: text, index: links.count + 1) {
                    links.append(link)
                    output += " [link \(link.index)]"
                }
            case "td", "th":
                render(element)
                output += "  "
            case "li":
                newline(); output += "- "; render(element); newline()
            default:
                if HTMLSanitizer.blockTags.contains(tag) {
                    newline(); render(element); newline()
                } else {
                    render(element)
                }
            }
        }

        private mutating func newline() {
            if !output.hasSuffix("\n") && !output.isEmpty { output += "\n" }
        }
    }
}

/// Reads CSS declarations for the tricks used to hide text from a reader.
enum StyleRules {
    static func declarations(_ style: String) -> [String: String] {
        var result: [String: String] = [:]
        for declaration in style.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].replacingOccurrences(of: "!important", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            result[key] = value
        }
        return result
    }

    static func backgroundColor(in style: String) -> String? {
        let values = declarations(style)
        if let color = values["background-color"] { return color }
        if let background = values["background"], let first = background.split(separator: " ").first {
            return String(first)
        }
        return nil
    }

    static func hides(_ style: String, background: String?) -> Bool {
        let values = declarations(style)
        if values.isEmpty { return false }
        if values["display"] == "none" { return true }
        if let visibility = values["visibility"], visibility == "hidden" || visibility == "collapse" { return true }
        if let opacity = values["opacity"], let number = number(opacity), number <= 0.05 { return true }
        if let size = values["font-size"], isTiny(size) { return true }
        if let color = values["color"], isTransparent(color) { return true }
        let overflowHidden = values["overflow"] == "hidden" || values["overflow-y"] == "hidden"
            || values["overflow-x"] == "hidden"
        for key in ["height", "max-height", "width", "max-width"] {
            if overflowHidden, let value = values[key], let n = number(value), n <= 1 { return true }
        }
        if let indent = values["text-indent"], let n = number(indent), n <= -500 { return true }
        if let position = values["position"], position == "absolute" || position == "fixed" {
            for key in ["left", "top", "right"] {
                if let value = values[key], let n = number(value), n <= -500 { return true }
            }
        }
        if let clip = values["clip"], clip.hasPrefix("rect(0") { return true }
        if let clipPath = values["clip-path"], clipPath.contains("inset(50%") || clipPath.contains("circle(0") {
            return true
        }
        if let transform = values["transform"], transform.contains("scale(0)") || transform.contains("scale(0,") {
            return true
        }
        if let color = values["color"] {
            let own = backgroundColor(in: style) ?? background
            if let own, sameColor(color, own) { return true }
        }
        return false
    }

    static func sameColor(_ a: String, _ b: String) -> Bool {
        guard let left = canonical(a), let right = canonical(b) else { return false }
        return left == right
    }

    private static func canonical(_ color: String) -> String? {
        let value = color.trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "white": return "#ffffff"
        case "black": return "#000000"
        default: break
        }
        if value.hasPrefix("#") {
            let hex = value.dropFirst()
            if hex.count == 3 { return "#" + hex.map { "\($0)\($0)" }.joined() }
            if hex.count == 6 { return value }
            return nil
        }
        if value.hasPrefix("rgb(") {
            let numbers = value.dropFirst(4).dropLast().split(separator: ",").compactMap {
                Int($0.trimmingCharacters(in: .whitespaces))
            }
            guard numbers.count == 3 else { return nil }
            return String(format: "#%02x%02x%02x", numbers[0], numbers[1], numbers[2])
        }
        return nil
    }

    private static func isTransparent(_ color: String) -> Bool {
        if color == "transparent" { return true }
        if color.hasPrefix("rgba("), let alpha = color.dropLast().split(separator: ",").last,
           let number = Double(alpha.trimmingCharacters(in: .whitespaces)), number <= 0.05 {
            return true
        }
        return false
    }

    private static func isTiny(_ size: String) -> Bool {
        guard let n = number(size) else { return false }
        if size.hasSuffix("em") || size.hasSuffix("rem") { return n <= 0.1 }
        if size.hasSuffix("%") { return n <= 10 }
        return n <= 1
    }

    private static func number(_ value: String) -> Double? {
        let digits = value.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(digits)
    }
}

/// Lists a link with its real destination and the signs of a disguised one.
enum LinkInspector {
    static func inspect(href: String, text: String, index: Int) -> LinkInfo? {
        let lowered = href.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("mailto:") else {
            return nil
        }
        let cleanURL = UnicodeCleaner.clean(href, keepNewlines: false)
        let components = URLComponents(string: cleanURL)
        let host = components?.host?.lowercased()
        let cleanText = UnicodeCleaner.clean(text, keepNewlines: false)

        var mismatch = false
        if let host, let textDomain = domain(in: cleanText) {
            mismatch = !(host == textDomain || host.hasSuffix("." + textDomain))
        }

        var suspicious = false
        if let host {
            suspicious = host.split(separator: ".").contains { $0.hasPrefix("xn--") }
                || host.unicodeScalars.contains { !$0.isASCII }
                || host.allSatisfy { $0.isNumber || $0 == "." }
                || host.contains(":")
        }
        if components?.user != nil { suspicious = true }

        return LinkInfo(
            index: index, text: String(cleanText.prefix(200)), url: String(cleanURL.prefix(2000)), host: host,
            textLooksLikeOtherHost: mismatch, suspiciousHost: suspicious
        )
    }

    private static func domain(in text: String) -> String? {
        guard let match = text.lowercased().firstMatch(of: #/((?:[a-z0-9-]+\.)+[a-z]{2,})/#) else { return nil }
        var domain = String(match.1)
        if domain.hasPrefix("www.") { domain.removeFirst(4) }
        return domain
    }
}
