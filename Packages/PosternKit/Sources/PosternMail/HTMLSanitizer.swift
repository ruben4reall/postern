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
/// (by attribute, inline style, or `<style>` rules that apply to a desktop window), text too small to read or drawn
/// in the color of its background. Images are never fetched; links are listed with their real destination.
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
        let sheet = StyleSheet(document)
        removed += removeStyleSheetHiddenElements(document, sheet: sheet)
        if let invisible = try? document.select(Self.invisibleTags) {
            for element in invisible.array() { try? element.remove() }
        }
        removed += removeInlineHiddenElements(document)
        removed += removeHiddenText(document, sheet: sheet)

        var renderer = TextRenderer()
        renderer.render(document.body() ?? document)
        let text = Self.normalize(renderer.output)
        return HTMLRendering(
            text: text, links: renderer.links, hiddenElementsRemoved: removed, imagesOmitted: renderer.images
        )
    }

    // MARK: Hidden content

    /// Applies `display:none`-like rules from `<style>` blocks for selectors SwiftSoup understands.
    private func removeStyleSheetHiddenElements(_ document: Document, sheet: StyleSheet) -> Int {
        var removed = 0
        for rule in sheet.rules where StyleRules.hidesBox(rule.values) {
            for element in sheet.elements(matching: rule, in: document) where element.parent() != nil {
                try? element.remove()
                removed += 1
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
        return StyleRules.hidesBox(StyleRules.declarations((try? element.attr("style")) ?? ""))
    }

    /// Text too small to read, transparent, or in the color of what is behind it. Font size and color are inherited,
    /// so each text is judged by the nearest element that sets them: a wrapper with a zero font size, whose blocks
    /// set their own size, is a common layout trick and its text stays.
    private func removeHiddenText(_ document: Document, sheet: StyleSheet) -> Int {
        let matched = sheet.declarationsByElement(in: document)
        func value(_ property: String, of element: Element) -> String? {
            if let inline = StyleRules.declarations((try? element.attr("style")) ?? "")[property] { return inline }
            if property == "color", element.tagName() == "font", let color = try? element.attr("color"), !color.isEmpty {
                return color
            }
            return matched[ObjectIdentifier(element)]?[property]
        }
        func background(of element: Element) -> String? {
            let inline = StyleRules.declarations((try? element.attr("style")) ?? "")
            if let color = StyleRules.backgroundColor(in: inline) { return color }
            if let attribute = try? element.attr("bgcolor"), !attribute.isEmpty { return attribute }
            return matched[ObjectIdentifier(element)].flatMap(StyleRules.backgroundColor(in:))
        }
        func isHidden(_ text: TextNode) -> Bool {
            var size: String?
            var color: String?
            var behind: String?
            var current = text.parent() as? Element
            while let element = current, size == nil || color == nil || behind == nil {
                if size == nil { size = value("font-size", of: element) }
                if color == nil { color = value("color", of: element) }
                if behind == nil { behind = background(of: element) }
                current = element.parent()
            }
            if let size, StyleRules.isTiny(size) { return true }
            guard let color else { return false }
            return StyleRules.isTransparent(color) || StyleRules.sameColor(color, behind ?? "#ffffff")
        }
        var hidden: [TextNode] = []
        func collect(_ node: Node) {
            for child in node.getChildNodes() {
                if let text = child as? TextNode {
                    if !text.isBlank(), isHidden(text) { hidden.append(text) }
                } else {
                    collect(child)
                }
            }
        }
        collect(document.body() ?? document)
        for text in hidden { try? text.remove() }
        return hidden.count
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

/// The rules of a message's `<style>` blocks that apply in a desktop window, the way Proton shows mail. Rules for
/// small screens, print or dark mode are left out: they hide the desktop layout on a phone, not on a Mac.
struct StyleSheet {
    struct Rule {
        let selectors: [String]
        let values: [String: String]
    }

    static let viewportWidth = 800.0
    private(set) var rules: [Rule] = []

    init(_ document: Document) {
        guard let styles = try? document.select("style") else { return }
        for style in styles.array() {
            let css = style.data().replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
            rules += Self.rules(in: Substring(css))
        }
    }

    /// The elements a rule selects, for the selectors SwiftSoup understands; pseudo-classes are skipped.
    func elements(matching rule: Rule, in document: Document) -> [Element] {
        rule.selectors.flatMap { selector -> [Element] in
            guard !selector.contains(":"), let elements = try? document.select(selector) else { return [] }
            return elements.array()
        }
    }

    /// For each element, what the rules set on it, later rules winning.
    func declarationsByElement(in document: Document) -> [ObjectIdentifier: [String: String]] {
        var result: [ObjectIdentifier: [String: String]] = [:]
        for rule in rules where !rule.values.isEmpty {
            for element in elements(matching: rule, in: document) {
                result[ObjectIdentifier(element), default: [:]].merge(rule.values) { _, new in new }
            }
        }
        return result
    }

    static func rules(in css: Substring) -> [Rule] {
        var rules: [Rule] = []
        var index = css.startIndex
        var prelude = ""
        while index < css.endIndex {
            let character = css[index]
            if character == ";" {
                prelude = ""
            } else if character == "{" {
                var depth = 1
                var end = css.index(after: index)
                while end < css.endIndex, depth > 0 {
                    if css[end] == "{" { depth += 1 } else if css[end] == "}" { depth -= 1 }
                    if depth > 0 { end = css.index(after: end) }
                }
                let block = css[css.index(after: index)..<end]
                let head = prelude.trimmingCharacters(in: .whitespacesAndNewlines)
                let lowered = head.lowercased()
                if lowered.hasPrefix("@media") {
                    if applies(media: String(lowered.dropFirst(6))) { rules += Self.rules(in: block) }
                } else if lowered.hasPrefix("@supports") {
                    rules += Self.rules(in: block)
                } else if !head.hasPrefix("@"), !head.isEmpty {
                    let selectors = head.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    rules.append(Rule(selectors: selectors, values: StyleRules.declarations(String(block))))
                }
                prelude = ""
                index = end < css.endIndex ? css.index(after: end) : end
                continue
            } else if character != "}" {
                prelude.append(character)
            }
            index = css.index(after: index)
        }
        return rules
    }

    /// Whether a media query list matches a screen 800 points wide in light mode.
    static func applies(media list: String) -> Bool {
        let width = #/(min|max)-(?:device-)?width\s*:\s*([0-9.]+)\s*(px|em|rem)?/#
        return list.split(separator: ",").contains { query in
            let query = query.trimmingCharacters(in: .whitespaces)
            if query.hasPrefix("not ") { return true }
            if query.contains("print") || query.contains("speech") { return false }
            if query.contains("prefers-color-scheme") && query.contains("dark") { return false }
            for match in query.matches(of: width) {
                guard var value = Double(match.2) else { continue }
                if match.3 == "em" || match.3 == "rem" { value *= 16 }
                if match.1 == "max" && viewportWidth > value { return false }
                if match.1 == "min" && viewportWidth < value { return false }
            }
            return true
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
        backgroundColor(in: declarations(style))
    }

    static func backgroundColor(in values: [String: String]) -> String? {
        if let color = values["background-color"] { return color }
        if let background = values["background"], let first = background.split(separator: " ").first {
            return String(first)
        }
        return nil
    }

    /// Whether these declarations hide an element and everything in it, whatever its children say. Font size and
    /// color are judged on the text itself, since children can set their own.
    static func hidesBox(_ values: [String: String]) -> Bool {
        if values.isEmpty { return false }
        if values["display"] == "none" { return true }
        if let visibility = values["visibility"], visibility == "hidden" || visibility == "collapse" { return true }
        if let opacity = values["opacity"], let number = number(opacity), number <= 0.05 { return true }
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

    static func isTransparent(_ color: String) -> Bool {
        if color == "transparent" { return true }
        if color.hasPrefix("rgba("), let alpha = color.dropLast().split(separator: ",").last,
           let number = Double(alpha.trimmingCharacters(in: .whitespaces)), number <= 0.05 {
            return true
        }
        return false
    }

    static func isTiny(_ size: String) -> Bool {
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
