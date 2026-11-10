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
/// The styles of the page are worked out the way a browser works them out: the `<style>` rules that apply in a
/// desktop window, by importance, layer, specificity and order, then the element's own style; invalid values
/// dropped, shorthands, custom properties and inheritance followed. From that, anything a reader would not see is
/// left out: hidden boxes, boxes moved, shrunk, clipped or faded out of sight, the inside of a closed `<details>`,
/// text too small to read or too close in color to what is behind it. What this reader cannot work out, such as a
/// filter, a mask or a blend it does not know, counts as hiding: the model may miss a word a reader sees, never the
/// other way round. Images are never fetched; links are listed with their real destination. Every walk through the
/// page is a loop, and a page built to stall the reader is not rendered.
public struct HTMLSanitizer: Sendable {
    public init() {}

    /// Deeper than any real email (Outlook's nested tables reach about a hundred).
    static let maxDepth = 1_000
    /// More elements than any real email, even a long report.
    static let maxElements = 150_000
    /// More style text than any real email.
    static let maxStyleBytes = 2_000_000
    /// Siblings past which SwiftSoup's positional selectors grow too slow.
    static let maxSiblingsWithPositionalRules = 3_000
    /// Selectors times elements past which matching takes too much time or memory.
    static let maxMatchingWork = 12_000_000

    private static let invisibleTags: Set<String> = [
        "script", "style", "head", "title", "template", "noscript", "iframe", "frame", "frameset", "object", "embed",
        "applet", "svg", "math", "meta", "link", "base", "canvas", "audio", "video", "source", "track", "map", "input",
        "select", "textarea", "button", "datalist", "rp", "meter", "progress", "param", "slot", "noembed", "noframes",
    ]

    static let blockTags: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "table", "tbody", "thead", "tfoot", "tr",
        "blockquote", "section", "article", "header", "footer", "li", "pre", "address", "center", "dl", "dt", "dd",
        "form", "fieldset", "figure", "figcaption", "main", "nav", "aside", "body", "html", "caption", "details",
        "summary", "dialog",
    ]

    public func render(_ html: String) -> HTMLRendering {
        let shape = NestingGuard.measure(html, stopAt: Self.maxDepth)
        if shape.depth > Self.maxDepth {
            return Self.refused("its HTML nests elements more than \(Self.maxDepth) levels deep")
        }
        if shape.elements > Self.maxElements { return Self.refused("its HTML holds more than \(Self.maxElements) elements") }
        if shape.formatting > NestingGuard.maxFormatting || shape.rebuilding > NestingGuard.maxRebuilding {
            return Self.refused("its HTML leaves styles of text open across thousands of paragraphs")
        }
        if shape.styleBytes > Self.maxStyleBytes { return Self.refused("its style sheets are larger than any email's") }
        guard let document = try? SwiftSoup.parse(html) else {
            return HTMLRendering(text: "", links: [], hiddenElementsRemoved: 0, imagesOmitted: 0)
        }
        let blocks = ((try? document.select("style"))?.array() ?? []).map { $0.data() }
        let sheet = StyleSheet(blocks)
        if sheet.tooComplex { return Self.refused("its style sheets are nested or numbered beyond any email's") }
        let elementCount = (try? document.getAllElements().size()) ?? 0
        if elementCount > Self.maxElements { return Self.refused("its HTML holds more than \(Self.maxElements) elements") }
        let selectors = sheet.rules.reduce(0) { $0 + $1.selectors.count }
        if selectors * elementCount > Self.maxMatchingWork { return Self.refused("its style sheets are larger than any email's") }
        if sheet.positional, Self.mostSiblings(in: document) > Self.maxSiblingsWithPositionalRules {
            return Self.refused("its style picks elements by position among thousands of siblings")
        }
        guard let matches = sheet.match(in: document) else {
            return Self.refused("its style takes more work to apply than any email's")
        }

        let root: Element = document.children().first() ?? document
        var walker = Walker(matches: matches, closedDetails: Self.closedDetails(in: document))
        walker.walk(root)

        var renderer = TextRenderer(hidden: walker.hidden)
        renderer.render(root)
        return HTMLRendering(
            text: Self.normalize(renderer.output), links: renderer.links, hiddenElementsRemoved: walker.removed,
            imagesOmitted: renderer.images
        )
    }

    private static func refused(_ reason: String) -> HTMLRendering {
        HTMLRendering(
            text: "[Postern did not show this email's text: \(reason), which no ordinary email does and which can stall the reader or bury hidden words. Open it in Proton Mail to read it.]",
            links: [], hiddenElementsRemoved: 1, imagesOmitted: 0
        )
    }

    private static func mostSiblings(in document: Document) -> Int {
        var most = 0
        var stack: [Element] = [document]
        while let element = stack.popLast() {
            let children = element.children().array()
            most = max(most, children.count)
            stack.append(contentsOf: children)
        }
        return most
    }

    /// The `<details>` a reader sees closed: those without `open`, and in a group sharing a `name`, every open one
    /// after the first, which browsers close.
    private static func closedDetails(in document: Document) -> Set<ObjectIdentifier> {
        var closed: Set<ObjectIdentifier> = []
        var openNames: Set<String> = []
        for details in (try? document.select("details"))?.array() ?? [] {
            let name = (try? details.attr("name")) ?? ""
            if !details.hasAttr("open") || (!name.isEmpty && openNames.contains(name)) {
                closed.insert(ObjectIdentifier(details))
            } else if !name.isEmpty {
                openNames.insert(name)
            }
        }
        return closed
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

    // MARK: Styles

    /// What is behind a text.
    indirect enum Behind {
        case color(CSSColor)
        /// The text may sit on any of these, as when a box too small for its text lets it overflow onto its parent:
        /// it is read only if it shows on every one.
        case all([Behind])

        func under(_ paint: CSSColor) -> Behind {
            switch self {
            case .color(let behind): .color(paint.over(behind))
            case .all(let grounds): .all(grounds.map { $0.under(paint) })
            }
        }

        /// Whether `color` stands out from it enough to be read.
        func shows(_ color: CSSColor) -> Bool {
            switch self {
            case .color(let behind): color.over(behind).contrast(with: behind) >= 1.2
            case .all(let grounds): grounds.allSatisfy { $0.shows(color) }
            }
        }
    }

    /// What paints a text clipped to its background (`background-clip: text`).
    enum ClipPaint {
        case color(CSSColor)
        /// Nothing this reader can see: a picture, loaded or not.
        case nothing
    }

    /// What an element passes down to its text and its children.
    struct State {
        var fontSize = CSSLength.rootFontSize
        /// The product of the zooms and scale transforms above.
        var scale = 1.0
        var color: CSSColor?
        var colorUnknown = false
        var fill: CSSColor?
        var fillUnknown = false
        var strokeWidth = 0.0
        var strokeColor: CSSColor?
        var visible = true
        var opacity = 1.0
        /// In points, as inherited: a spacing set in `em` is fixed where it is set.
        var letterSpacing = 0.0
        /// A filter, mask or blend above that this reader cannot work out, or text drawn as bullets.
        var obscured = false
        var behind: Behind = .color(.white)
        var clipPaint: ClipPaint?
        var custom: [String: String] = [:]
        /// The element's own values of properties that do not inherit, for a child that asks for `inherit`.
        var own: [String: String] = [:]

        /// Whether a text drawn with this state escapes a reader.
        var hidesText: Bool {
            if !visible || obscured || opacity <= 0.05 || fontSize * scale <= 2 || letterSpacing <= -0.3 * fontSize { return true }
            if fillUnknown || (fill == nil && colorUnknown) { return true }
            var stroke = strokeColor ?? color ?? .black
            stroke.alpha *= opacity
            if strokeWidth * scale >= 0.3, behind.shows(stroke) { return false }
            var paint = fill ?? color ?? .black
            paint.alpha *= opacity
            if paint.alpha <= 0.05 {
                guard case .color(var drawn)? = clipPaint else { return true }
                drawn.alpha *= opacity
                return !behind.shows(drawn)
            }
            return !behind.shows(paint)
        }
    }

    /// Properties that do not inherit and that this reader evaluates: `inherit` on them takes the parent's value.
    static let nonInherited: Set<String> = [
        "opacity", "transform", "translate", "scale", "zoom", "filter", "clip-path", "mix-blend-mode", "mask",
        "mask-image", "background-color", "background-image", "overflow-x", "overflow-y", "height", "max-height",
        "width", "max-width", "position", "left", "top", "right", "bottom", "margin-left", "margin-top", "clip",
        "box-shadow", "background-size", "background-clip",
    ]

    /// Walks the page once, from the top, working out each element's style and marking what a reader would not see.
    struct Walker {
        let matches: StyleSheet.Matches
        let closedDetails: Set<ObjectIdentifier>
        private(set) var hidden: Set<ObjectIdentifier> = []
        private(set) var removed = 0

        init(matches: StyleSheet.Matches, closedDetails: Set<ObjectIdentifier>) {
            self.matches = matches
            self.closedDetails = closedDetails
        }

        mutating func walk(_ root: Element) {
            guard let rootState = style(root, from: State()) else { mark(root); return }
            var stack: [(Element, State)] = [(root, rootState)]
            while let (element, state) = stack.popLast() {
                let closed = closedDetails.contains(ObjectIdentifier(element))
                var summaryKept = false
                for child in element.getChildNodes() {
                    if closed {
                        if !summaryKept, let summary = child as? Element, summary.tagName() == "summary" {
                            summaryKept = true
                        } else {
                            if let text = child as? TextNode, text.isBlank() { continue }
                            mark(child)
                            continue
                        }
                    }
                    if let text = child as? TextNode {
                        if !text.isBlank(), state.hidesText { mark(text) }
                    } else if let element = child as? Element {
                        if HTMLSanitizer.invisibleTags.contains(element.tagName()) {
                            hidden.insert(ObjectIdentifier(element))
                        } else if let childState = style(element, from: state) {
                            stack.append((element, childState))
                        } else {
                            mark(element)
                        }
                    }
                }
            }
        }

        private mutating func mark(_ node: Node) {
            hidden.insert(ObjectIdentifier(node))
            removed += 1
        }

        /// The element's state, or nil when the element and everything in it are out of sight.
        private func style(_ element: Element, from parent: State) -> State? {
            let tag = element.tagName()
            if tag == "dialog", !element.hasAttr("open") { return nil }
            var state = parent
            var values = cascade(element, tag: tag, parent: parent, state: &state)
            for key in HTMLSanitizer.nonInherited where values[key] == "inherit" { values[key] = parent.own[key] }
            state.own = values.filter { HTMLSanitizer.nonInherited.contains($0.key) }

            var fontSize = values["font-size"].flatMap { CSSLength.fontSize($0, inherited: parent.fontSize) } ?? parent.fontSize
            if let adjust = values["font-size-adjust"].flatMap(Double.init), adjust.isFinite, adjust > 0, adjust < 0.5 {
                fontSize *= adjust / 0.5
            }
            if StyleRules.hidesBox(values, font: fontSize) { return nil }

            state.fontSize = fontSize
            state.scale = parent.scale * StyleRules.scale(values) * StyleRules.zoom(values["zoom"])
            switch values["visibility"] {
            case "hidden"?, "collapse"?: state.visible = false
            case "visible"?: state.visible = true
            default: break
            }
            if let opacity = values["opacity"] { state.opacity *= StyleRules.fraction(opacity) ?? 0 }
            if StyleRules.obscures(values) { state.obscured = true }
            if let filter = values["filter"] { state.opacity *= StyleRules.filterOpacity(filter) ?? 1 }

            if let value = values["color"] {
                switch CSSColor.read(value) {
                case .color(let color)?: state.color = color; state.colorUnknown = false
                case .unknown?: state.colorUnknown = true
                default: break
                }
            } else if tag == "a", element.hasAttr("href") {
                // Browsers draw links in their own blue unless a rule says otherwise.
                state.color = CSSColor(red: 0, green: 0, blue: 0.93)
                state.colorUnknown = false
            }
            if let value = values["-webkit-text-fill-color"] {
                switch value {
                case "currentcolor", "initial": state.fill = nil; state.fillUnknown = false
                default:
                    switch CSSColor.read(value) {
                    case .color(let color)?: state.fill = color; state.fillUnknown = false
                    case .unknown?: state.fillUnknown = true
                    default: break
                    }
                }
            }
            if let width = values["-webkit-text-stroke-width"] {
                state.strokeWidth = CSSLength.length(width, relativeTo: fontSize, font: fontSize) ?? (["thin", "medium", "thick"].contains(width) ? 1 : 0)
            }
            if let color = values["-webkit-text-stroke-color"] {
                state.strokeColor = color == "currentcolor" ? nil : CSSColor.parse(color)
            }
            if let spacing = values["letter-spacing"] {
                state.letterSpacing = spacing == "normal" ? 0 : CSSLength.length(spacing, relativeTo: fontSize, font: fontSize) ?? parent.letterSpacing
            }

            let current = state.color ?? .black
            let ownGround = StyleRules.behind(values, over: parent.behind, current: current)
            if let clip = values["background-clip"], clip.split(separator: " ").contains("text") {
                state.clipPaint = StyleRules.clipPaint(values, current: current)
            } else if StyleRules.sizeCapped(values, font: fontSize) {
                // The text may overflow a box sized below it, onto what is behind the box.
                state.behind = .all([ownGround, parent.behind])
            } else {
                state.behind = ownGround
            }
            return state
        }

        /// The element's declarations after the cascade: the old presentational attributes first, then the rules
        /// by importance, then style attribute over selectors, then cascade layer, specificity and order. Custom
        /// properties are worked out first, then every value that uses one; invalid values are dropped.
        private func cascade(_ element: Element, tag: String, parent: State, state: inout State) -> [String: String] {
            var values: [String: String] = [:]
            if element.hasAttr("hidden") || element.hasAttr("popover") { values["display"] = "none" }
            if ["body", "table", "tr", "td", "th", "thead", "tbody", "tfoot", "marquee"].contains(tag),
               let attribute = try? element.attr("bgcolor"), let color = CSSColor.legacy(attribute) {
                values["background-color"] = color.cssText
            }
            if ["body", "table", "tr", "td", "th", "thead", "tbody", "tfoot"].contains(tag),
               let picture = try? element.attr("background"), !picture.isEmpty {
                values["background-image"] = "url(\(picture.lowercased()))"
            }
            if tag == "font" {
                if let color = (try? element.attr("color")).flatMap(CSSColor.legacy) { values["color"] = color.cssText }
                if let size = try? element.attr("size"), let points = StyleRules.fontTagSize(size) { values["font-size"] = "\(points)px" }
            }
            if tag == "body", let color = (try? element.attr("text")).flatMap(CSSColor.legacy) { values["color"] = color.cssText }

            typealias Entry = (important: Bool, inline: Bool, layer: Int, specificity: Int, order: Int, index: Int, declaration: CSSDeclaration)
            var declared: [Entry] = []
            for (specificity, order, layered, declarations) in matches.byElement[ObjectIdentifier(element)] ?? [] {
                for (index, declaration) in declarations.enumerated() {
                    // Outside a layer beats inside for normal declarations; the other way round for important ones.
                    let layer = declaration.important ? (layered ? 1 : 0) : (layered ? 0 : 1)
                    declared.append((declaration.important, false, layer, specificity, order, index, declaration))
                }
            }
            if let style = try? element.attr("style"), !style.isEmpty {
                for (index, declaration) in CSSText.declarations(style).enumerated() {
                    declared.append((declaration.important, true, 2, 0, 0, index, declaration))
                }
            }
            declared.sort {
                if $0.important != $1.important { return !$0.important }
                if $0.inline != $1.inline { return !$0.inline }
                if $0.layer != $1.layer { return $0.layer < $1.layer }
                if $0.specificity != $1.specificity { return $0.specificity < $1.specificity }
                if $0.order != $1.order { return $0.order < $1.order }
                return $0.index < $1.index
            }

            var raw: [String: String] = [:]
            for entry in declared where entry.declaration.name.hasPrefix("--") { raw[entry.declaration.name] = entry.declaration.value }
            state.custom = StyleRules.resolve(raw, inherited: parent.custom)

            for entry in declared where !entry.declaration.name.hasPrefix("--") {
                var value = entry.declaration.value
                if value.contains("var(") {
                    // A value that names a missing property falls back to unset, not to the value before it.
                    value = StyleRules.substitute(value, custom: state.custom)?.lowercased() ?? "unset"
                }
                StyleRules.apply(entry.declaration.name, value, into: &values)
            }
            return values
        }
    }

    // MARK: Text rendering

    /// Writes the page as text, with a loop and a stack of steps so that nesting cannot exhaust the thread's stack,
    /// leaving out what the walker marked.
    private struct TextRenderer {
        let hidden: Set<ObjectIdentifier>
        var output = ""
        var links: [LinkInfo] = []
        var images = 0

        init(hidden: Set<ObjectIdentifier>) { self.hidden = hidden }

        private enum Step {
            case node(Node)
            /// After a block, a list item or a table cell.
            case close(String)
            /// After a link, whose text starts at this UTF-8 offset of the output.
            case closeLink(Element, Int)
        }

        mutating func render(_ root: Node) {
            var steps: [Step] = []
            var inLink = false
            let hidden = self.hidden
            func push(_ node: Node, _ steps: inout [Step]) {
                steps.append(contentsOf: node.getChildNodes().reversed().filter { !hidden.contains(ObjectIdentifier($0)) }.map { .node($0) })
            }
            if hidden.contains(ObjectIdentifier(root)) { return }
            push(root, &steps)
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

extension CSSColor {
    /// The color written as CSS, to carry an old attribute's color through the cascade.
    var cssText: String {
        func byte(_ c: Double) -> Int { Int((min(max(c, 0), 1) * 255).rounded()) }
        return "rgb(\(byte(red)) \(byte(green)) \(byte(blue)) / \(alpha))"
    }
}

/// Measures a page before it is parsed, in one pass over its bytes, the way the HTML parser builds it: elements
/// open and close on a stack, an end tag closes the element it names, unless a block such as a `<div>` stands in
/// the way; paragraphs, items and cells close each other; table parts outside a table are dropped; text styles left
/// open are rebuilt in every later block; comments and raw text such as scripts are skipped; quotes count only
/// around attribute values.
enum NestingGuard {
    struct Shape {
        var depth = 0
        var elements = 0
        var styleBytes = 0
        /// The most text styles (`<b>`, `<font>`…) left open at once, each rebuilt in every later block.
        var formatting = 0
        /// What rebuilding them costs SwiftSoup, which grows with the square of the blocks that follow.
        var rebuilding = 0
    }

    /// Rebuilding past this takes SwiftSoup seconds (about a second per million on a Mac, in a debug build).
    static let maxRebuilding = 4_000_000

    /// Text styles left open past this make the parser rebuild them over and over.
    static let maxFormatting = 64

    private static let void: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr", "param",
        "keygen", "basefont", "bgsound", "frame", "image",
    ]
    private static let rawText: Set<String> = ["script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes"]
    private static let formatting: Set<String> = ["a", "b", "big", "code", "em", "font", "i", "nobr", "s", "small", "strike", "strong", "tt", "u"]
    private static let closesParagraph: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div", "dl", "fieldset",
        "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "main",
        "menu", "nav", "ol", "p", "pre", "section", "summary", "table", "ul", "li", "dd", "dt", "listing", "xmp", "search",
    ]
    private static let scope: Set<String> = ["html", "table", "td", "th", "caption", "marquee", "object", "applet", "template", "button"]
    /// Elements an end tag for an ordinary element does not close through.
    private static let special: Set<String> = [
        "address", "applet", "area", "article", "aside", "base", "basefont", "bgsound", "blockquote", "body", "br",
        "button", "caption", "center", "col", "colgroup", "dd", "details", "dir", "div", "dl", "dt", "embed", "fieldset",
        "figcaption", "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head",
        "header", "hgroup", "hr", "html", "iframe", "img", "input", "keygen", "li", "link", "listing", "main",
        "marquee", "menu", "meta", "nav", "noembed", "noframes", "noscript", "object", "ol", "p", "param", "plaintext",
        "pre", "script", "search", "section", "select", "source", "style", "summary", "table", "tbody", "td",
        "template", "textarea", "tfoot", "th", "thead", "title", "tr", "track", "ul", "wbr", "xmp",
    ]

    static func exceeds(_ html: String, depth limit: Int) -> Bool {
        measure(html, stopAt: limit).depth > limit
    }

    static func measure(_ html: String, stopAt limit: Int) -> Shape {
        let bytes = Array(html.utf8)
        let count = bytes.count
        var shape = Shape()
        var stack: [String] = []
        var tables = 0
        var openFormatting = 0
        var blocksSinceFormatting = 0
        var index = 0

        func isLetter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
        func isSpace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 12 || byte == 13 }
        func name(at start: Int) -> (String, Int) {
            var end = start
            while end < count, !isSpace(bytes[end]), bytes[end] != 47, bytes[end] != 62 { end += 1 }
            return (String(decoding: bytes[start..<end], as: UTF8.self).lowercased(), end)
        }
        /// Past the `>` that ends a tag: a quote opens a value only right after `=`.
        func endOfTag(from start: Int) -> Int {
            var at = start
            while at < count {
                let byte = bytes[at]
                if byte == 62 { return at + 1 }
                if byte == 61 {
                    at += 1
                    while at < count, isSpace(bytes[at]) { at += 1 }
                    if at < count, bytes[at] == 34 || bytes[at] == 39 {
                        let quote = bytes[at]
                        at += 1
                        while at < count, bytes[at] != quote { at += 1 }
                    }
                }
                at += 1
            }
            return count
        }
        func find(_ needle: [UInt8], from start: Int) -> Int? {
            guard needle.count <= count else { return nil }
            var at = start
            while at + needle.count <= count {
                if bytes[at] == needle[0], Array(bytes[at..<(at + needle.count)]) == needle { return at }
                at += 1
            }
            return nil
        }
        /// The `</tag` that ends raw text: the name, then a space, `/` or `>`, in any case.
        func endOfRawText(_ tag: String, from start: Int) -> Int {
            let needle = Array("</\(tag)".utf8)
            var at = start
            while at + needle.count <= count {
                var matches = true
                for offset in 0..<needle.count {
                    var byte = bytes[at + offset]
                    if (65...90).contains(byte) { byte += 32 }
                    if byte != needle[offset] { matches = false; break }
                }
                if matches {
                    let after = at + needle.count
                    if after >= count || isSpace(bytes[after]) || bytes[after] == 47 || bytes[after] == 62 { return at }
                }
                at += 1
            }
            return count
        }
        func pop(from position: Int) {
            tables -= stack[position...].lazy.filter { $0 == "table" }.count
            stack.removeSubrange(position...)
        }
        /// Closes `targets` if one is open above any of `boundaries`, looking at most 64 elements down.
        func close(_ targets: Set<String>, within boundaries: Set<String>) {
            var position = stack.count - 1
            var looked = 0
            while position >= 0, looked < 64 {
                let open = stack[position]
                if targets.contains(open) { pop(from: position); return }
                if boundaries.contains(open) { return }
                position -= 1
                looked += 1
            }
        }

        while index < count {
            guard bytes[index] == 60, index + 1 < count else { index += 1; continue }
            let next = bytes[index + 1]
            if next == 33 {
                if index + 3 < count, bytes[index + 2] == 45, bytes[index + 3] == 45 {
                    // <!-->, <!--->, then a comment that ends at --> or --!>.
                    let body = index + 4
                    if body < count, bytes[body] == 62 { index = body + 1; continue }
                    if body + 1 < count, bytes[body] == 45, bytes[body + 1] == 62 { index = body + 2; continue }
                    let end = [find(Array("-->".utf8), from: body).map { $0 + 3 },
                               find(Array("--!>".utf8), from: body).map { $0 + 4 }].compactMap { $0 }.min()
                    index = end ?? count
                } else {
                    // <!DOCTYPE …>, <!x …>: a bogus comment, to the first >.
                    index = (find([62], from: index + 2) ?? count) + 1
                }
            } else if next == 63 {
                index = (find([62], from: index + 2) ?? count) + 1
            } else if next == 47 {
                guard index + 2 < count, isLetter(bytes[index + 2]) else {
                    index = (find([62], from: index + 2) ?? count) + 1
                    continue
                }
                let (tag, end) = name(at: index + 2)
                index = endOfTag(from: end)
                if void.contains(tag) { continue }
                if formatting.contains(tag) {
                    // The adoption agency reaches through blocks to close a text style.
                    if openFormatting > 0 { openFormatting -= 1 }
                    if openFormatting == 0 { blocksSinceFormatting = 0 }
                    close([tag], within: [])
                } else if special.contains(tag) {
                    close([tag], within: scope)
                } else {
                    // Any other end tag closes the element it names, unless a special element stands in the way.
                    close([tag], within: special)
                }
            } else if isLetter(next) {
                let (tag, end) = name(at: index + 1)
                index = endOfTag(from: end)
                if ["html", "head", "body"].contains(tag) { continue }
                // Table parts outside a table are dropped by the parser.
                if tables == 0, ["td", "th", "tr", "tbody", "thead", "tfoot", "caption", "col", "colgroup"].contains(tag) { continue }
                shape.elements += 1
                if closesParagraph.contains(tag) {
                    close(["p"], within: scope)
                    // Text styles left open are rebuilt inside the new block.
                    shape.elements += openFormatting
                    if openFormatting > 0 {
                        blocksSinceFormatting += 1
                        shape.rebuilding += openFormatting * blocksSinceFormatting
                        if shape.rebuilding > maxRebuilding { return shape }
                    }
                }
                switch tag {
                case "li": close(["li"], within: scope.union(["ul", "ol"]))
                case "dd", "dt": close(["dd", "dt"], within: scope.union(["dl"]))
                case "tr": close(["tr"], within: ["table"])
                case "td", "th": close(["td", "th"], within: ["tr", "table"])
                case "tbody", "thead", "tfoot": close(["tbody", "thead", "tfoot"], within: ["table"])
                case "option": close(["option"], within: ["select", "datalist", "optgroup"])
                case "optgroup": close(["option", "optgroup"], within: ["select"])
                case "h1", "h2", "h3", "h4", "h5", "h6":
                    if let top = stack.last, ["h1", "h2", "h3", "h4", "h5", "h6"].contains(top) { stack.removeLast() }
                case "a": close(["a"], within: scope)
                case "nobr": close(["nobr"], within: scope)
                default: break
                }
                if formatting.contains(tag) {
                    openFormatting += 1
                    shape.formatting = max(shape.formatting, openFormatting)
                }
                if rawText.contains(tag) {
                    let end = endOfRawText(tag, from: index)
                    if tag == "style" { shape.styleBytes += end - index }
                    index = end
                    continue
                }
                if tag == "plaintext" { break }
                if !void.contains(tag) {
                    stack.append(tag)
                    if tag == "table" { tables += 1 }
                    shape.depth = max(shape.depth, stack.count)
                    if stack.count > limit { return shape }
                }
            } else {
                index += 1
            }
        }
        return shape
    }
}

/// Reads CSS values for the tricks used to hide text from a reader.
enum StyleRules {
    private static let keywords: Set<String> = ["inherit", "initial", "unset", "revert", "revert-layer"]
    /// The words `display` takes; any other value is dropped by browsers.
    private static let displayWords: Set<String> = [
        "none", "block", "inline", "inline-block", "flex", "inline-flex", "grid", "inline-grid", "table",
        "inline-table", "table-row", "table-cell", "table-column", "table-row-group", "table-column-group",
        "table-header-group", "table-footer-group", "table-caption", "list-item", "contents", "flow", "flow-root",
        "run-in", "ruby", "ruby-base", "ruby-text", "ruby-base-container", "ruby-text-container", "math",
        "-webkit-box", "-webkit-inline-box", "-webkit-flex", "-webkit-inline-flex", "-ms-flexbox",
        "-ms-inline-flexbox", "-moz-box", "-moz-inline-box", "inline-list-item",
    ]
    /// Prefixed properties and the logical ones that stand for a longhand in a page written left to right.
    private static let aliases: [String: String] = [
        "margin-inline-start": "margin-left", "margin-block-start": "margin-top", "inset-inline-start": "left",
        "inset-block-start": "top", "inset-inline-end": "right", "inset-block-end": "bottom",
        "-webkit-background-clip": "background-clip", "-webkit-mask-image": "mask-image", "-webkit-mask": "mask",
        "-webkit-filter": "filter", "-webkit-transform": "transform", "-ms-transform": "transform",
        "-moz-transform": "transform",
    ]
    private static let plain: Set<String> = [
        "background-image", "margin-left", "margin-top", "position", "left", "top", "right", "bottom", "height",
        "max-height", "width", "max-width", "text-indent", "white-space", "transform", "translate", "scale", "zoom",
        "filter", "clip", "clip-path", "letter-spacing", "font-size-adjust", "overflow-x", "overflow-y",
        "-webkit-text-stroke-width", "mix-blend-mode", "mask", "mask-image", "-webkit-text-security", "line-height",
        "background-size", "box-shadow", "background-clip",
    ]

    /// Sets the declaration on the element's values, expanding shorthands, if its value is one the property takes:
    /// a browser drops any other, and the value before it stays.
    static func apply(_ written: String, _ value: String, into values: inout [String: String]) {
        let name = aliases[written] ?? written
        switch name {
        case "display":
            let words = value.split(whereSeparator: \.isWhitespace).map(String.init)
            if keywords.contains(value) || (!words.isEmpty && words.allSatisfy(displayWords.contains)) { values[name] = value }
        case "visibility":
            if ["visible", "hidden", "collapse"].contains(value) || keywords.contains(value) { values[name] = value }
        case "content-visibility":
            if ["visible", "hidden", "auto"].contains(value) || keywords.contains(value) { values[name] = value }
        case "opacity":
            if fraction(value) != nil || keywords.contains(value) || value.contains("(") { values[name] = value }
        case "color", "-webkit-text-fill-color", "background-color", "-webkit-text-stroke-color":
            if CSSColor.read(value) != nil { values[name] = value }
        case "font-size":
            if CSSLength.fontSize(value, inherited: CSSLength.rootFontSize) != nil || value.contains("(") { values[name] = value }
        case "font":
            if let size = fontSize(inShorthand: value) { values["font-size"] = size }
        case "background":
            let image = images(in: value)
            values["background-image"] = image.isEmpty ? "none" : image.joined(separator: ", ")
            var rest = value
            for picture in image { rest = rest.replacingOccurrences(of: picture, with: " ") }
            values["background-color"] = color(inShorthand: rest)?.cssText ?? "transparent"
            if rest.split(whereSeparator: { $0 == " " || $0 == "," }).contains("text") { values["background-clip"] = "text" }
        case "margin", "margin-inline", "margin-block":
            let parts = CSSColor.splitTopLevel(value, by: " ")
            guard (1...4).contains(parts.count) else { return }
            if name == "margin-inline" { values["margin-left"] = parts[0]; return }
            if name == "margin-block" { values["margin-top"] = parts[0]; return }
            values["margin-top"] = parts[0]
            values["margin-left"] = parts.count == 4 ? parts[3] : parts.count >= 2 ? parts[1] : parts[0]
        case "inset", "inset-inline", "inset-block":
            let parts = CSSColor.splitTopLevel(value, by: " ")
            guard (1...4).contains(parts.count) else { return }
            if name == "inset-inline" { values["left"] = parts[0]; values["right"] = parts.last; return }
            if name == "inset-block" { values["top"] = parts[0]; values["bottom"] = parts.last; return }
            values["top"] = parts[0]
            values["right"] = parts.count >= 2 ? parts[1] : parts[0]
            values["bottom"] = parts.count >= 3 ? parts[2] : parts[0]
            values["left"] = parts.count == 4 ? parts[3] : parts.count >= 2 ? parts[1] : parts[0]
        case "overflow":
            let parts = CSSColor.splitTopLevel(value, by: " ")
            guard (1...2).contains(parts.count) else { return }
            values["overflow-x"] = parts[0]
            values["overflow-y"] = parts.last
        case "-webkit-text-stroke":
            for part in CSSColor.splitTopLevel(value, by: " ") {
                if CSSLength.length(part, relativeTo: 16) != nil || ["thin", "medium", "thick"].contains(part) {
                    values["-webkit-text-stroke-width"] = part
                } else if CSSColor.read(part) != nil {
                    values["-webkit-text-stroke-color"] = part
                }
            }
        default:
            if plain.contains(name) { values[name] = value }
        }
    }

    /// Each element's custom properties, worked out from its own declarations and what it inherits: a property that
    /// names another is resolved through it; a cycle, or a value longer than 16 KB, is invalid and counts as unset.
    static func resolve(_ raw: [String: String], inherited: [String: String]) -> [String: String] {
        guard !raw.isEmpty else { return inherited }
        var resolved = inherited
        var done: [String: String?] = [:]
        func value(of name: String, visiting: Set<String>) -> String? {
            if let finished = done[name] { return finished }
            guard let written = raw[name] else { return inherited[name] }
            guard !visiting.contains(name), visiting.count < 32 else { return nil }
            let result = substitute(written, lookup: { value(of: $0, visiting: visiting.union([name])) })
            done[name] = .some(result)
            return result
        }
        for name in raw.keys {
            if let result = value(of: name, visiting: []), !result.isEmpty { resolved[name] = result } else { resolved[name] = nil }
        }
        return resolved
    }

    static func substitute(_ value: String, custom: [String: String]) -> String? {
        substitute(value, lookup: { custom[$0] })
    }

    /// The value with each `var(--name, fallback)` replaced, left to right, as many times as a replacement brings in
    /// another; nil when one names nothing and has no fallback, or when the result grows past 16 KB or takes more
    /// than 256 replacements.
    static func substitute(_ value: String, lookup: (String) -> String?) -> String? {
        var text = value
        var replacements = 0
        while let start = text.range(of: "var(") {
            replacements += 1
            guard replacements <= 256, text.utf8.count <= 16_384 else { return nil }
            var level = 1
            var index = start.upperBound
            while index < text.endIndex, level > 0 {
                if text[index] == "(" { level += 1 }
                if text[index] == ")" { level -= 1 }
                if level > 0 { index = text.index(after: index) }
            }
            guard index < text.endIndex else { return nil }
            let inside = String(text[start.upperBound..<index])
            let parts = CSSColor.splitTopLevel(inside, by: ",")
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let fallback = parts.count > 1 ? parts.dropFirst().joined(separator: ",").trimmingCharacters(in: .whitespaces) : nil
            guard let replacement = lookup(name).flatMap({ $0.isEmpty ? nil : $0 }) ?? fallback else { return nil }
            text = String(text[..<start.lowerBound]) + replacement + String(text[text.index(after: index)...])
        }
        return text.utf8.count <= 16_384 ? text : nil
    }

    /// The pictures and gradients of a `background` value.
    static func images(in value: String) -> [String] {
        value.matches(of: #/(?:url|(?:repeating-)?(?:linear|radial|conic)-gradient|image-set|image|-webkit-gradient|-webkit-(?:repeating-)?(?:linear|radial)-gradient|cross-fade|element|paint)\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)/#).map { String($0.0) }
    }

    /// What is behind the element's text: its own color over what is behind it, under the color covering most of
    /// its gradient, or the color an inset shadow paints over it. Proton loads no remote picture until the reader
    /// asks, and a picture carried in the email may be anything: neither counts.
    static func behind(_ values: [String: String], over parent: HTMLSanitizer.Behind, current: CSSColor) -> HTMLSanitizer.Behind {
        var base = parent
        if let value = values["background-color"] {
            let color: CSSColor?
            switch CSSColor.read(value) {
            case .color(let read)?: color = read
            case .inherit?: color = value == "currentcolor" ? current : nil
            default: color = nil
            }
            if let color, color.alpha > 0.05 {
                base = color.alpha >= 0.95 ? .color(CSSColor(red: color.red, green: color.green, blue: color.blue)) : parent.under(color)
            }
        }
        let size = values["background-size"] ?? ""
        let painted = !CSSColor.splitTopLevel(size, by: " ").contains { CSSLength.length($0, relativeTo: 100) == 0 }
        if painted, let gradient = (values["background-image"].map(images(in:)) ?? []).first(where: { $0.contains("gradient(") }),
           let dominant = CSSColor.dominant(inGradient: gradient) {
            base = base.under(dominant)
        }
        if let shadow = values["box-shadow"], shadow.contains("inset") {
            let words = CSSColor.splitTopLevel(shadow, by: " ")
            let lengths = words.compactMap { CSSLength.length($0, relativeTo: 0) }
            if lengths.count >= 4, lengths[3] >= 50, let color = words.lazy.compactMap({ CSSColor.parse($0) }).first, color.alpha > 0.05 {
                base = base.under(color)
            }
        }
        return base
    }

    /// What paints text clipped to the element's background: the color covering most of its gradient, or its
    /// color. A picture, remote or carried in the email, paints nothing this reader can see.
    static func clipPaint(_ values: [String: String], current: CSSColor) -> HTMLSanitizer.ClipPaint {
        let pictures = values["background-image"].map(images(in:)) ?? []
        if let gradient = pictures.first(where: { $0.contains("gradient(") }), let dominant = CSSColor.dominant(inGradient: gradient) {
            return .color(dominant)
        }
        if !pictures.isEmpty { return .nothing }
        if let value = values["background-color"] {
            if value == "currentcolor" { return .color(current) }
            if let color = CSSColor.parse(value), color.alpha > 0.05 { return .color(color) }
        }
        return .nothing
    }

    /// A box given a height or maximum height under a line of its text, without clipping: the text shows over what
    /// is behind the box.
    static func sizeCapped(_ values: [String: String], font: Double) -> Bool {
        for key in ["height", "max-height"] {
            if let value = values[key], let points = CSSLength.length(value, relativeTo: 600, font: font), points < font * 1.2 { return true }
        }
        return false
    }

    /// The color in a `background` shorthand such as `#fff no-repeat` or `rgb(0 0 0) center`.
    static func color(inShorthand value: String) -> CSSColor? {
        for word in CSSColor.splitTopLevel(value.replacingOccurrences(of: ",", with: " "), by: " ") {
            if let color = CSSColor.parse(word) { return color }
        }
        return nil
    }

    /// The size in a `font` shorthand: `bold 0/0 a` gives `0`. A number without a unit is a weight, unless it is 0.
    static func fontSize(inShorthand value: String?) -> String? {
        guard let value else { return nil }
        for word in CSSColor.splitTopLevel(value, by: " ") {
            let size = CSSColor.splitTopLevel(word, by: "/").first ?? ""
            guard let first = size.first, first.isNumber || ".+-".contains(first) || ["calc(", "min(", "max(", "clamp("].contains(where: size.hasPrefix) else { continue }
            if size == "0" || size == "+0" || size == "-0" || size.contains(where: \.isLetter) || size.hasSuffix("%") { return size }
        }
        return nil
    }

    /// The size an old `<font size>` gives, from 1 (small) to 7 (large), or relative as `+1` or `-2`.
    static func fontTagSize(_ raw: String) -> Double? {
        let sizes = [10.0, 13, 16, 18, 24, 32, 48]
        let value = raw.trimmingCharacters(in: .whitespaces)
        let digits = value.drop { $0 == "+" || $0 == "-" }.prefix { $0.isNumber }.prefix(3)
        guard let number = Int(digits) else { return nil }
        let step = value.hasPrefix("+") ? 3 + number : value.hasPrefix("-") ? 3 - number : number
        return sizes[min(max(step, 1), 7) - 1]
    }

    /// `0.4`, `40%` or `calc(0.4)` as 0.4, between 0 and 1. Nil when it cannot be told.
    static func fraction(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let number: Double?
        if ["calc(", "min(", "max(", "clamp("].contains(where: trimmed.hasPrefix) {
            number = CSSLength.length(trimmed, relativeTo: 1)
        } else if trimmed.hasSuffix("%") {
            number = Double(trimmed.dropLast()).map { $0 / 100 }
        } else if keywords.contains(trimmed) {
            number = 1
        } else {
            number = Double(trimmed)
        }
        guard let number, number.isFinite else { return nil }
        return min(max(number, 0), 1)
    }

    /// The product of the `opacity()` functions in a `filter`.
    static func filterOpacity(_ value: String) -> Double? {
        let found = value.matches(of: #/opacity\(\s*([^)\s]+)\s*\)/#).map { fraction(String($0.1)) ?? 0 }
        return found.isEmpty ? nil : found.reduce(1, *)
    }

    /// A filter, mask or blend this reader cannot see through, or text drawn as bullets: what it does to the text
    /// cannot be told, so the text counts as hidden.
    static func obscures(_ values: [String: String]) -> Bool {
        let neutral: Set<String> = ["none", "normal", "initial", "unset", "inherit", "revert"]
        if let blend = values["mix-blend-mode"], !neutral.contains(blend) { return true }
        for key in ["mask", "mask-image"] {
            if let mask = values[key], !neutral.contains(mask) { return true }
        }
        if let security = values["-webkit-text-security"], !neutral.contains(security) { return true }
        if let filter = values["filter"], !neutral.contains(filter) {
            if filter.contains("url(") { return true }
            for match in filter.matches(of: #/([a-z-]+)\(([^()]*(?:\([^()]*\))?[^()]*)\)/#) {
                let amount = fraction(String(match.2)) ?? 1
                switch match.1 {
                case "opacity", "blur", "drop-shadow", "grayscale", "sepia", "saturate", "hue-rotate": continue
                case "brightness", "contrast": if amount <= 0.1 { return true }
                case "invert": if amount >= 0.3 { return true }
                default: return true
                }
            }
        }
        return false
    }

    /// How much `zoom` shrinks the element. Zero, `normal` and `reset` mean no zoom.
    static func zoom(_ value: String?) -> Double {
        guard let value else { return 1 }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let number = trimmed.hasSuffix("%") ? Double(trimmed.dropLast()).map { $0 / 100 } : Double(trimmed)
        guard let number, number.isFinite, number > 0 else { return 1 }
        return number
    }

    /// How much `transform` and `scale` shrink the element: the smaller of the two directions.
    static func scale(_ values: [String: String]) -> Double {
        var factor = 1.0
        if let transform = values["transform"] {
            for match in transform.matches(of: #/(scale|scalex|scaley|scale3d|matrix|matrix3d)\(([^)]*)\)/#) {
                let numbers = match.2.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.compactMap(number)
                switch match.1 {
                case "scale": if let x = numbers.first { factor *= min(abs(x), abs(numbers.count > 1 ? numbers[1] : x)) }
                case "scalex", "scaley": if let x = numbers.first { factor *= abs(x) }
                case "scale3d": if numbers.count >= 2 { factor *= min(abs(numbers[0]), abs(numbers[1])) }
                case "matrix": if numbers.count == 6 { factor *= sqrt(abs(numbers[0] * numbers[3] - numbers[1] * numbers[2])) }
                default: if numbers.count == 16 { factor *= sqrt(abs(numbers[0] * numbers[5] - numbers[1] * numbers[4])) }
                }
            }
        }
        if let scale = values["scale"], scale != "none" {
            let numbers = CSSColor.splitTopLevel(scale, by: " ").prefix(2).compactMap(number)
            if let x = numbers.first { factor *= min(abs(x), abs(numbers.count > 1 ? numbers[1] : x)) }
        }
        return factor.isFinite ? factor : 1
    }

    /// A number, or a percentage as a fraction.
    private static func number(_ text: String) -> Double? {
        let value = text.hasSuffix("%") ? Double(text.dropLast()).map { $0 / 100 } : Double(text)
        guard let value, value.isFinite else { return nil }
        return value
    }

    /// Whether these declarations hide an element and everything in it, whatever its children say. Size, color and
    /// opacity are judged on the text itself, since children can set their own.
    static func hidesBox(_ values: [String: String], font: Double) -> Bool {
        if values.isEmpty { return false }
        if let display = values["display"] {
            let first = display.split(separator: " ").first.map(String.init) ?? ""
            if ["none", "table-column", "table-column-group"].contains(first) { return true }
        }
        if values["content-visibility"] == "hidden" { return true }
        func length(_ key: String, _ reference: Double) -> Double? {
            values[key].flatMap { CSSLength.length($0, relativeTo: reference, font: font) }
        }
        let clipped = ["overflow-x", "overflow-y"].contains { ["hidden", "clip", "scroll", "auto", "overlay"].contains(values[$0] ?? "") }
        if clipped {
            for key in ["height", "max-height"] where (length(key, 600) ?? 2) <= 1 { return true }
            for key in ["width", "max-width"] where (length(key, 800) ?? 2) <= 1 { return true }
            if values["height"] == nil, let line = values["line-height"],
               let points = CSSLength.length(line, relativeTo: font, font: font) ?? Double(line).map({ $0 * font }), points <= 1 {
                return true
            }
        }
        if let indent = length("text-indent", 800) {
            if indent <= -500 || indent >= 2_000 || (clipped && indent >= 800) { return true }
        }
        if let position = values["position"], ["absolute", "fixed", "relative", "sticky"].contains(position) {
            let reach = position == "relative" || position == "sticky" ? -500.0 : -200.0
            if let left = length("left", 800), left <= reach { return true }
            if let top = length("top", 600), top <= reach { return true }
            if let right = length("right", 800), right >= 2_000 { return true }
            if let bottom = length("bottom", 600), bottom >= 2_000 { return true }
        }
        if let margin = length("margin-left", 800), margin <= -500 { return true }
        if let margin = length("margin-top", 600), margin <= -500 { return true }
        if let clip = values["clip"], clipsToNothing(clip, font: font) { return true }
        if let path = values["clip-path"], clipPathHides(path, font: font) { return true }
        if let transform = values["transform"], transformHides(transform, font: font) { return true }
        if let translate = values["translate"],
           CSSColor.splitTopLevel(translate, by: " ").prefix(2).contains(where: { (CSSLength.length($0, relativeTo: 800, font: font) ?? 0) <= -500 }) {
            return true
        }
        if scale(values) <= 0.05 { return true }
        if zoom(values["zoom"]) <= 0.05 { return true }
        if let filter = values["filter"] {
            if (filterOpacity(filter) ?? 1) <= 0.05 { return true }
            for match in filter.matches(of: #/blur\(\s*([^)]+)\)/#) {
                if let radius = CSSLength.length(String(match.1), relativeTo: font, font: font), radius >= max(4, font * 0.5) { return true }
            }
        }
        return false
    }

    /// `clip: rect(…)` with no area left.
    private static func clipsToNothing(_ value: String, font: Double) -> Bool {
        guard value.hasPrefix("rect("), value.hasSuffix(")") else { return false }
        let parts = value.dropFirst(5).dropLast().split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        guard parts.count == 4 else { return false }
        let numbers = parts.map { CSSLength.length($0, relativeTo: 0, font: font) }
        if let top = numbers[0], let bottom = numbers[2], bottom - top <= 1 { return true }
        if let right = numbers[1], let left = numbers[3], right - left <= 1 { return true }
        return false
    }

    /// `clip-path` shapes that leave nothing, or that this reader cannot draw: an inset that meets itself, a circle
    /// or an ellipse with a radius under a point, a polygon whose points all fall in one place, a path or a link.
    private static func clipPathHides(_ value: String, font: Double) -> Bool {
        if ["none", "initial", "unset", "inherit"].contains(value) { return false }
        if value.contains("url(") || value.contains("path(") || value.contains("shape(") { return true }
        func share(_ part: String) -> Double? {
            part.hasSuffix("%") ? Double(part.dropLast()).map { $0 / 100 } : CSSLength.length(part, relativeTo: 0, font: font).map { $0 >= 2_000 ? 1 : 0 }
        }
        if let match = value.firstMatch(of: #/inset\(([^)]*)\)/#) {
            let parts = CSSColor.splitTopLevel(String(match.1).components(separatedBy: " round ")[0], by: " ")
            guard (1...4).contains(parts.count) else { return false }
            let top = parts[0], right = parts.count >= 2 ? parts[1] : parts[0]
            let bottom = parts.count >= 3 ? parts[2] : parts[0], left = parts.count == 4 ? parts[3] : right
            if let t = share(top), let b = share(bottom), t + b >= 1 { return true }
            if let l = share(left), let r = share(right), l + r >= 1 { return true }
        }
        if let match = value.firstMatch(of: #/(?:xywh|rect)\(([^)]*)\)/#) {
            let parts = CSSColor.splitTopLevel(String(match.1).components(separatedBy: " round ")[0], by: " ")
            let sizes = parts.compactMap { CSSLength.length($0, relativeTo: 100, font: font) }
            if value.contains("xywh("), sizes.count >= 4, sizes[2] <= 1 || sizes[3] <= 1 { return true }
            if value.contains("rect("), sizes.count == 4, sizes[2] - sizes[0] <= 1 || sizes[1] - sizes[3] <= 1 { return true }
        }
        if let match = value.firstMatch(of: #/(circle|ellipse)\(([^)]*)\)/#) {
            let radii = CSSColor.splitTopLevel(String(match.2).components(separatedBy: " at ")[0], by: " ")
            for radius in radii.prefix(match.1 == "circle" ? 1 : 2) {
                if let points = CSSLength.length(radius, relativeTo: 100, font: font), points < 1 { return true }
            }
        }
        if let match = value.firstMatch(of: #/polygon\(([^)]*)\)/#) {
            let points = String(match.1).split(separator: ",").map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            if points.count >= 1, Set(points).count == 1 { return true }
        }
        return false
    }

    /// A transform that moves the box hundreds of points off the page, turns it edge-on, or that this reader
    /// cannot work out, such as a perspective with a depth.
    private static func transformHides(_ value: String, font: Double) -> Bool {
        if ["none", "initial", "unset", "inherit"].contains(value) { return false }
        let known: Set<String> = [
            "translate", "translatex", "translatey", "translate3d", "translatez", "scale", "scalex", "scaley", "scalez",
            "scale3d", "rotate", "rotatez", "rotatex", "rotatey", "skew", "skewx", "skewy", "matrix", "matrix3d",
            "perspective", "rotate3d",
        ]
        let functions = value.matches(of: #/([a-z0-9]+)\(([^)]*)\)/#)
        let hasPerspective = functions.contains { $0.1 == "perspective" }
        for match in functions {
            let arguments = match.2.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard known.contains(String(match.1)) else { return true }
            func off(_ index: Int, _ reference: Double) -> Bool {
                index < arguments.count && (CSSLength.length(arguments[index], relativeTo: reference, font: font) ?? 0) <= -500
            }
            func depth(_ index: Int) -> Bool {
                index < arguments.count && (CSSLength.length(arguments[index], relativeTo: 0, font: font) ?? 0) != 0
            }
            switch match.1 {
            case "translate": if off(0, 800) || off(1, 600) { return true }
            case "translate3d": if off(0, 800) || off(1, 600) || (hasPerspective && depth(2)) { return true }
            case "translatez": if hasPerspective && depth(0) { return true }
            case "translatex": if off(0, 800) { return true }
            case "translatey": if off(0, 600) { return true }
            case "rotate3d": return true
            case "rotatex", "rotatey", "skew", "skewx", "skewy":
                for argument in arguments {
                    guard let degrees = angle(argument) else { continue }
                    let folded = abs(degrees.truncatingRemainder(dividingBy: 180))
                    if abs(folded - 90) < 1 { return true }
                }
            case "matrix":
                let numbers = arguments.compactMap(number)
                if numbers.count == 6, numbers[4] <= -500 || numbers[5] <= -500 { return true }
            case "matrix3d":
                let numbers = arguments.compactMap(number)
                guard numbers.count == 16 else { return true }
                // A perspective term, or a move hundreds of points off the page.
                if numbers[3] != 0 || numbers[7] != 0 || numbers[11] != 0 || numbers[12] <= -500 || numbers[13] <= -500 { return true }
            default: break
            }
        }
        return false
    }

    private static func angle(_ text: String) -> Double? {
        for (unit, factor) in [("deg", 1.0), ("grad", 0.9), ("rad", 180 / Double.pi), ("turn", 360.0)] where text.hasSuffix(unit) {
            return Double(text.dropLast(unit.count)).map { $0 * factor }
        }
        return text == "0" ? 0 : nil
    }
}

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
