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
/// (by attribute, inline style, or `<style>` rules that apply to a desktop window), the inside of a closed
/// `<details>`, boxes moved, shrunk or faded out of sight, text too small to read or too close to the color behind
/// it. Images are never fetched; links are listed with their real destination. Every walk through the page is a
/// loop, never a recursion, and a page nested deeper than any real email is not rendered at all.
public struct HTMLSanitizer: Sendable {
    public init() {}

    /// Deeper than any real email (Outlook's nested tables reach about a hundred): such a page is built to slow
    /// the parser down or to bury words, and is not rendered.
    static let maxDepth = 1_000

    private static let invisibleTags = [
        "script", "style", "head", "title", "template", "noscript", "iframe", "frame", "frameset", "object", "embed",
        "applet", "svg", "math", "meta", "link", "base", "canvas", "audio", "video", "source", "track", "map", "input",
        "select", "textarea", "button",
    ].joined(separator: ", ")

    static let blockTags: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "table", "tbody", "thead", "tfoot", "tr",
        "blockquote", "section", "article", "header", "footer", "li", "pre", "address", "center", "dl", "dt", "dd",
        "form", "fieldset", "figure", "figcaption", "main", "nav", "aside", "body", "html", "caption", "details",
        "summary",
    ]

    public func render(_ html: String) -> HTMLRendering {
        if NestingGuard.exceeds(html, depth: Self.maxDepth) {
            return HTMLRendering(
                text: "[Postern did not show this email's text: its HTML nests elements more than \(Self.maxDepth) levels deep, which no ordinary email does and which can bury hidden words. Open it in Proton Mail to read it.]",
                links: [], hiddenElementsRemoved: 1, imagesOmitted: 0
            )
        }
        guard let document = try? SwiftSoup.parse(html) else {
            return HTMLRendering(text: "", links: [], hiddenElementsRemoved: 0, imagesOmitted: 0)
        }
        var removed = 0
        let sheet = StyleSheet(document)
        removed += removeStyleSheetHiddenElements(document, sheet: sheet)
        if let invisible = try? document.select(Self.invisibleTags) {
            for element in invisible.array() { try? element.remove() }
        }
        removed += removeClosedDisclosures(document)
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

    /// A `<details>` without `open` shows its summary and nothing else until someone clicks it.
    private func removeClosedDisclosures(_ document: Document) -> Int {
        guard let disclosures = try? document.select("details") else { return 0 }
        var removed = 0
        for disclosure in disclosures.array() where !disclosure.hasAttr("open") && disclosure.parent() != nil {
            var keptSummary = false
            for child in disclosure.getChildNodes() {
                if !keptSummary, let element = child as? Element, element.tagName() == "summary" {
                    keptSummary = true
                    continue
                }
                if let text = child as? TextNode, text.isBlank() { continue }
                try? child.remove()
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

    /// What a text inherits from the elements around it.
    private struct Inherited {
        var fontSize = CSSLength.rootFontSize
        /// Nil until an element sets one: the default is black.
        var color: CSSColor?
        /// Nil when a picture or a gradient is behind the text: its color cannot be told.
        var background: CSSColor? = .white
        var opacity = 1.0
    }

    /// Text too small to read, faded out, or too close to the color behind it. Size, color, background and opacity
    /// are worked out once per element from the top of the page down, so each text is judged by what a browser
    /// would draw: a wrapper with a zero font size whose blocks set their own size is a common layout trick and
    /// its text stays, while `font-size: 100%` inside it is still zero.
    private func removeHiddenText(_ document: Document, sheet: StyleSheet) -> Int {
        let matched = sheet.declarationsByElement(in: document)
        let root: Element = document.body() ?? document
        var hidden: [TextNode] = []
        var stack: [(Element, Inherited)] = [(root, inherited(root, from: Inherited(), matched: matched))]
        while let (element, state) = stack.popLast() {
            for child in element.getChildNodes() {
                if let text = child as? TextNode {
                    if !text.isBlank(), Self.hides(state) { hidden.append(text) }
                } else if let child = child as? Element {
                    stack.append((child, inherited(child, from: state, matched: matched)))
                }
            }
        }
        for text in hidden { try? text.remove() }
        return hidden.count
    }

    private static func hides(_ state: Inherited) -> Bool {
        if state.opacity <= 0.05 || state.fontSize <= 2 { return true }
        var color = state.color ?? .black
        color.alpha *= state.opacity
        if color.alpha <= 0.05 { return true }
        guard let background = state.background else { return false }
        return color.over(background).contrast(with: background) < 1.2
    }

    private func inherited(_ element: Element, from parent: Inherited, matched: [ObjectIdentifier: [String: String]]) -> Inherited {
        var values = matched[ObjectIdentifier(element)] ?? [:]
        values.merge(StyleRules.declarations((try? element.attr("style")) ?? "")) { _, inline in inline }
        let tag = element.tagName()
        var state = parent

        if let size = values["font-size"] ?? StyleRules.fontSize(inShorthand: values["font"]) {
            state.fontSize = CSSLength.fontSize(size, inherited: parent.fontSize) ?? parent.fontSize
        } else if tag == "font", let size = try? element.attr("size"), let points = StyleRules.fontTagSize(size, inherited: parent.fontSize) {
            state.fontSize = points
        } else if tag == "small" {
            state.fontSize = parent.fontSize / 1.2
        }

        if let fill = values["-webkit-text-fill-color"].flatMap(CSSColor.parse) {
            state.color = fill
        } else if let color = values["color"].flatMap(CSSColor.parse) {
            state.color = color
        } else if tag == "font", let color = (try? element.attr("color")).flatMap(CSSColor.parse) {
            state.color = color
        } else if tag == "body", let color = (try? element.attr("text")).flatMap(CSSColor.parse) {
            state.color = color
        } else if tag == "a", element.hasAttr("href") {
            // Browsers draw links in their own blue unless a rule says otherwise.
            state.color = CSSColor(red: 0, green: 0, blue: 0.93)
        }

        switch StyleRules.background(values, attributes: element) {
        case .none: break
        case .image: state.background = nil
        case .color(let color):
            if color.alpha >= 0.95 {
                state.background = CSSColor(red: color.red, green: color.green, blue: color.blue)
            } else if color.alpha > 0.05 {
                state.background = parent.background.map { color.over($0) }
            }
        }

        if let opacity = values["opacity"].flatMap(StyleRules.fraction) { state.opacity *= opacity }
        if let filter = values["filter"].flatMap(StyleRules.filterOpacity) { state.opacity *= filter }
        return state
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

    /// Writes the page as text, with a loop and a stack of steps so that nesting cannot exhaust the thread's stack.
    private struct TextRenderer {
        var output = ""
        var links: [LinkInfo] = []
        var images = 0

        private enum Step {
            case node(Node)
            /// After a block, a list item or a table cell.
            case close(String)
            /// After a link, whose text starts at this UTF-8 offset of the output.
            case closeLink(Element, Int)
        }

        mutating func render(_ root: Node) {
            var steps: [Step] = root.getChildNodes().reversed().map { .node($0) }
            var inLink = false
            func push(_ element: Element, _ steps: inout [Step]) {
                steps.append(contentsOf: element.getChildNodes().reversed().map { .node($0) })
            }
            while let step = steps.popLast() {
                switch step {
                case .node(let node):
                    if let text = node as? TextNode {
                        output += text.text()
                        continue
                    }
                    guard let element = node as? Element else { continue }
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
                    case "a" where !inLink:
                        inLink = true
                        steps.append(.closeLink(element, output.utf8.count))
                        push(element, &steps)
                    case "td", "th":
                        steps.append(.close(tag))
                        push(element, &steps)
                    case "li":
                        newline(); output += "- "
                        steps.append(.close(tag))
                        push(element, &steps)
                    default:
                        if HTMLSanitizer.blockTags.contains(tag) {
                            newline()
                            steps.append(.close(tag))
                        }
                        push(element, &steps)
                    }
                case .close(let tag):
                    if tag == "td" || tag == "th" { output += "  " } else { newline() }
                case .closeLink(let element, let start):
                    inLink = false
                    let from = output.utf8.index(output.utf8.startIndex, offsetBy: start)
                    let inner = String(output[from...])
                    output.removeSubrange(from...)
                    let text = inner.replacing(#/\s+/#, with: " ").trimmingCharacters(in: .whitespaces)
                    let href = ((try? element.attr("href")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    output += text
                    if let link = LinkInspector.inspect(href: href, text: text, index: links.count + 1) {
                        links.append(link)
                        output += " [link \(link.index)]"
                    }
                }
            }
        }

        private mutating func newline() {
            if !output.hasSuffix("\n") && !output.isEmpty { output += "\n" }
        }
    }
}

/// Measures how deep a page nests before it is parsed, in one pass over its bytes, the way a parser would see it:
/// comments and raw text such as scripts are skipped, and elements that close themselves or are closed by their
/// next sibling (`<br>`, `<p>`, `<li>`, `<td>`…) do not count.
enum NestingGuard {
    private static let flat: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr", "param",
        "keygen", "p", "li", "dt", "dd", "tr", "td", "th", "option", "optgroup", "thead", "tbody", "tfoot", "colgroup",
        "caption", "rb", "rt", "rtc", "rp", "html", "head", "body",
    ]
    private static let rawText: Set<String> = ["script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes", "plaintext"]

    static func exceeds(_ html: String, depth limit: Int) -> Bool {
        let bytes = Array(html.utf8)
        let count = bytes.count
        var index = 0
        var depth = 0

        func isLetter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
        func name(at start: Int) -> (String, Int) {
            var end = start
            while end < count, isLetter(bytes[end]) || (48...57).contains(bytes[end]) || bytes[end] == 45 { end += 1 }
            return (String(decoding: bytes[start..<end], as: UTF8.self).lowercased(), end)
        }
        /// The index after the `>` that ends the tag, past quoted attribute values.
        func endOfTag(from start: Int) -> Int {
            var at = start
            var quote: UInt8?
            while at < count {
                let byte = bytes[at]
                if let open = quote {
                    if byte == open { quote = nil }
                } else if byte == 34 || byte == 39 {
                    quote = byte
                } else if byte == 62 {
                    return at + 1
                }
                at += 1
            }
            return count
        }
        func find(_ needle: [UInt8], from start: Int, ignoringCase: Bool) -> Int? {
            guard needle.count <= count else { return nil }
            var at = start
            while at + needle.count <= count {
                var matches = true
                for offset in 0..<needle.count {
                    var byte = bytes[at + offset]
                    if ignoringCase, (65...90).contains(byte) { byte += 32 }
                    if byte != needle[offset] { matches = false; break }
                }
                if matches { return at }
                at += 1
            }
            return nil
        }

        while index < count {
            guard bytes[index] == 60, index + 1 < count else { index += 1; continue }
            let next = bytes[index + 1]
            if next == 33 {
                // <!-- comment -->, <!DOCTYPE …>, <![CDATA[ … ]]>
                if index + 3 < count, bytes[index + 2] == 45, bytes[index + 3] == 45 {
                    index = (find(Array("-->".utf8), from: index + 4, ignoringCase: false) ?? count) + 3
                } else {
                    index = endOfTag(from: index + 2)
                }
            } else if next == 47 {
                let (tag, end) = name(at: index + 2)
                if !tag.isEmpty, !flat.contains(tag), depth > 0 { depth -= 1 }
                index = endOfTag(from: end)
            } else if isLetter(next) {
                let (tag, end) = name(at: index + 1)
                index = endOfTag(from: end)
                if rawText.contains(tag) {
                    index = find(Array("</\(tag)".utf8), from: index, ignoringCase: true) ?? count
                } else if !flat.contains(tag) {
                    depth += 1
                    if depth > limit { return true }
                }
            } else {
                index += 1
            }
        }
        return false
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

    /// Pseudo-classes that depend only on where an element sits, which SwiftSoup and browsers read the same way.
    /// Rules for hover, focus or a visited link, and SwiftSoup's own `:contains`, never apply to a page at rest.
    private static let structural: Set<String> = [
        "not", "nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type", "first-child", "last-child",
        "first-of-type", "last-of-type", "only-child", "only-of-type", "empty", "root",
    ]

    static func applies(selector: String) -> Bool {
        if selector.contains("::") { return false }
        return selector.matches(of: #/:([a-zA-Z-]+)/#).allSatisfy { structural.contains($0.1.lowercased()) }
    }

    /// The elements a rule selects, for the selectors SwiftSoup understands as a browser would.
    func elements(matching rule: Rule, in document: Document) -> [Element] {
        rule.selectors.flatMap { selector -> [Element] in
            guard Self.applies(selector: selector), let elements = try? document.select(selector) else { return [] }
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

    enum Background {
        case none
        case color(CSSColor)
        /// A picture or a gradient: what is behind the text cannot be told.
        case image
    }

    /// What an element paints behind its text, from its styles and the old `bgcolor` and `background` attributes.
    /// Proton does not load remote images until the user asks, so a picture from the web is not behind the text: its
    /// fallback color is, or what is behind the element. A gradient, or a picture carried in the email itself, is.
    static func background(_ values: [String: String], attributes element: Element) -> Background {
        if let image = values["background-image"], shown(image) { return .image }
        if let shorthand = values["background"] {
            if shown(shorthand) { return .image }
            if let color = color(inShorthand: shorthand.replacing(#/url\([^)]*\)/#, with: "")) { return .color(color) }
        }
        if let color = values["background-color"].flatMap(CSSColor.parse) { return .color(color) }
        if let picture = try? element.attr("background"), shown("url(\(picture))") { return .image }
        if let attribute = try? element.attr("bgcolor"), let color = CSSColor.parse(attribute) { return .color(color) }
        return .none
    }

    /// Whether a background value paints something a reader sees before loading remote images.
    private static func shown(_ value: String) -> Bool {
        if value.contains("gradient(") { return true }
        return value.matches(of: #/url\(\s*['"]?\s*([a-z]+):/#).contains { ["cid", "data"].contains(String($0.1)) }
    }

    /// The color in a `background` shorthand such as `#fff no-repeat` or `rgb(0 0 0) center`.
    static func color(inShorthand value: String) -> CSSColor? {
        if let whole = CSSColor.parse(value) { return whole }
        if let function = value.firstMatch(of: #/(?:rgba?|hsla?)\([^)]*\)/#), let color = CSSColor.parse(String(function.0)) {
            return color
        }
        for word in value.split(whereSeparator: \.isWhitespace) {
            let word = String(word)
            if word.hasPrefix("#") || CSSColor.named[word] != nil || word == "transparent", let color = CSSColor.parse(word) {
                return color
            }
        }
        return nil
    }

    /// The size in a `font` shorthand: `bold 0/0 a` gives `0`. A number without a unit is a weight, unless it is 0.
    static func fontSize(inShorthand value: String?) -> String? {
        guard let value else { return nil }
        for word in value.split(whereSeparator: \.isWhitespace) {
            let size = word.split(separator: "/").first.map(String.init) ?? ""
            guard let first = size.first, first.isNumber || first == "." else { continue }
            if size == "0" || size.contains(where: \.isLetter) || size.hasSuffix("%") { return size }
        }
        return nil
    }

    /// The size an old `<font size>` gives, from 1 (small) to 7 (large), or relative as `+1` or `-2`.
    static func fontTagSize(_ raw: String, inherited: Double) -> Double? {
        let sizes = [10.0, 13, 16, 18, 24, 32, 48]
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard let number = Int(value.replacingOccurrences(of: "+", with: "")) else { return nil }
        let step = value.hasPrefix("+") || value.hasPrefix("-") ? 3 + number : number
        return sizes[min(max(step, 1), 7) - 1]
    }

    /// `0.4` or `40%` as 0.4.
    static func fraction(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("%") { return Double(trimmed.dropLast()).map { min(max($0 / 100, 0), 1) } }
        return Double(trimmed).map { min(max($0, 0), 1) }
    }

    /// The product of the `opacity()` functions in a `filter`.
    static func filterOpacity(_ value: String) -> Double? {
        let found = value.matches(of: #/opacity\(\s*([0-9.]+%?)\s*\)/#).compactMap { fraction(String($0.1)) }
        return found.isEmpty ? nil : found.reduce(1, *)
    }

    /// Whether these declarations hide an element and everything in it, whatever its children say. Font size and
    /// color are judged on the text itself, since children can set their own.
    static func hidesBox(_ values: [String: String]) -> Bool {
        if values.isEmpty { return false }
        if values["display"] == "none" { return true }
        if let visibility = values["visibility"], visibility == "hidden" || visibility == "collapse" { return true }
        if values["content-visibility"] == "hidden" { return true }
        if let opacity = values["opacity"], let number = fraction(opacity), number <= 0.05 { return true }
        if let filter = values["filter"], let number = filterOpacity(filter), number <= 0.05 { return true }
        let overflowHidden = values["overflow"] == "hidden" || values["overflow-y"] == "hidden"
            || values["overflow-x"] == "hidden" || values["overflow"] == "clip"
        for key in ["height", "max-height", "width", "max-width"] {
            if overflowHidden, let value = values[key], let n = number(value), n <= 1 { return true }
        }
        if let indent = values["text-indent"], let n = number(indent), n <= -500 { return true }
        if let position = values["position"], position == "absolute" || position == "fixed" {
            for key in ["left", "top", "right"] {
                if let value = values[key], let n = number(value), n <= -500 { return true }
            }
        }
        if offsetOutOfSight(values) { return true }
        if let clip = values["clip"], clip.hasPrefix("rect(0") { return true }
        if let clipPath = values["clip-path"], clipPath.contains("inset(50%") || clipPath.contains("circle(0") {
            return true
        }
        if shrunkOutOfSight(values) { return true }
        if let zoom = values["zoom"], let n = fraction(zoom.hasSuffix("%") ? zoom : zoom), n > 0, n <= 0.05 { return true }
        return false
    }

    /// A negative margin or a translation that puts the box hundreds of points off the page.
    private static func offsetOutOfSight(_ values: [String: String]) -> Bool {
        for key in ["margin-left", "margin-top"] {
            if let value = values[key], let n = number(value), n <= -500 { return true }
        }
        if let margin = values["margin"] {
            let parts = margin.split(whereSeparator: \.isWhitespace).map { number(String($0)) }
            // top right bottom left: the first and, when there are four, the last.
            let top = parts.first ?? nil
            let left: Double?? = parts.count == 4 ? parts[3] : parts.count >= 2 ? parts[1] : top
            if let top, top <= -500 { return true }
            if let left = left ?? nil, left <= -500 { return true }
        }
        var moves: [String] = []
        if let transform = values["transform"] {
            for match in transform.matches(of: #/translate(x|y|3d)?\(([^)]*)\)/#) {
                let arguments = match.2.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                switch match.1 {
                case "x"?, "y"?: moves += arguments.prefix(1)
                default: moves += arguments.prefix(2)
                }
            }
        }
        if let translate = values["translate"] { moves += translate.split(whereSeparator: \.isWhitespace).prefix(2).map(String.init) }
        return moves.contains { number($0).map { $0 <= -500 } ?? false }
    }

    /// A scale that shrinks the box to nothing.
    private static func shrunkOutOfSight(_ values: [String: String]) -> Bool {
        var factors: [String] = []
        if let transform = values["transform"] {
            for match in transform.matches(of: #/scale(x|y|z|3d)?\(([^)]*)\)/#) {
                let arguments = match.2.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                switch match.1 {
                case "z"?: continue
                case "x"?, "y"?: factors += arguments.prefix(1)
                default: factors += arguments.prefix(2)
                }
            }
        }
        if let scale = values["scale"] { factors += scale.split(whereSeparator: \.isWhitespace).prefix(2).map(String.init) }
        return factors.contains { fraction($0).map { abs($0) <= 0.05 } ?? false }
    }

    static func sameColor(_ a: String, _ b: String) -> Bool {
        guard let left = CSSColor.parse(a), let right = CSSColor.parse(b) else { return false }
        return left.contrast(with: right) < 1.2
    }

    static func isTransparent(_ color: String) -> Bool {
        (CSSColor.parse(color)?.alpha ?? 1) <= 0.05
    }

    static func isTiny(_ size: String) -> Bool {
        guard let points = CSSLength.fontSize(size, inherited: CSSLength.rootFontSize) else { return false }
        return points <= 2
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
