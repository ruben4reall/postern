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
/// desktop window, by importance, specificity and order, then the element's own style; invalid values dropped;
/// shorthands, custom properties and inheritance followed. From that, anything a reader would not see is left out:
/// hidden boxes, boxes moved, shrunk, clipped or faded out of sight, the inside of a closed `<details>`, text too
/// small to read or too close in color to what is behind it. Images are never fetched; links are listed with their
/// real destination. Every walk through the page is a loop, and a page built to stall the reader is not rendered.
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
    /// Selector matches past which a page takes too long to style.
    static let maxMatchingWork = 40_000_000

    private static let invisibleTags: Set<String> = [
        "script", "style", "head", "title", "template", "noscript", "iframe", "frame", "frameset", "object", "embed",
        "applet", "svg", "math", "meta", "link", "base", "canvas", "audio", "video", "source", "track", "map", "input",
        "select", "textarea", "button", "datalist", "rp", "meter", "progress", "param", "slot",
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
        if shape.styleBytes > Self.maxStyleBytes { return Self.refused("its style sheets are larger than any email's") }
        guard let document = try? SwiftSoup.parse(html) else {
            return HTMLRendering(text: "", links: [], hiddenElementsRemoved: 0, imagesOmitted: 0)
        }
        let blocks = ((try? document.select("style"))?.array() ?? []).map { $0.data() }
        let sheet = StyleSheet(blocks)
        if sheet.tooComplex { return Self.refused("its style sheets are nested or numbered beyond any email's") }
        let elementCount = (try? document.getAllElements().size()) ?? 0
        let selectors = sheet.rules.reduce(0) { $0 + $1.selectors.count }
        if selectors * elementCount > Self.maxMatchingWork { return Self.refused("its style sheets are larger than any email's") }
        if sheet.positional, Self.mostSiblings(in: document) > Self.maxSiblingsWithPositionalRules {
            return Self.refused("its style picks elements by position among thousands of siblings")
        }

        var walker = Walker(matches: sheet.match(in: document), closedDetails: Self.closedDetails(in: document))
        walker.walk(document.body() ?? document)

        var renderer = TextRenderer(hidden: walker.hidden)
        renderer.render(document.body() ?? document)
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

    /// What is behind a text: one color, or the colors of a gradient.
    enum Behind {
        case color(CSSColor)
        case gradient([CSSColor])

        func under(_ paint: CSSColor) -> Behind {
            switch self {
            case .color(let behind): .color(paint.over(behind))
            case .gradient(let stops): .gradient(stops.map { paint.over($0) })
            }
        }

        /// Whether `color` stands out from it enough to be read, somewhere.
        func shows(_ color: CSSColor) -> Bool {
            switch self {
            case .color(let behind): color.over(behind).contrast(with: behind) >= 1.2
            case .gradient(let stops): stops.contains { color.over($0).contrast(with: $0) >= 1.2 }
            }
        }
    }

    /// What paints a text clipped to its background (`background-clip: text`).
    enum ClipPaint {
        case stops([CSSColor])
        /// A picture carried in the email.
        case picture
        /// A remote picture, not loaded until the reader asks.
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
        var letterSpacingHides = false
        var behind: Behind = .color(.white)
        var clipPaint: ClipPaint?
        var custom: [String: String] = [:]

        /// Whether a text drawn with this state escapes a reader.
        var hidesText: Bool {
            if !visible || opacity <= 0.05 || fontSize * scale <= 2 || letterSpacingHides { return true }
            if fillUnknown || (fill == nil && colorUnknown) { return true }
            var stroke = strokeColor ?? color ?? .black
            stroke.alpha *= opacity
            if strokeWidth >= 0.3, behind.shows(stroke) { return false }
            var paint = fill ?? color ?? .black
            paint.alpha *= opacity
            if paint.alpha <= 0.05 {
                switch clipPaint {
                case .picture?: return false
                case .stops(let stops)?: return !stops.contains { stop in
                    var faded = stop
                    faded.alpha *= opacity
                    return behind.shows(faded)
                }
                default: return true
                }
            }
            return !behind.shows(paint)
        }
    }

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
            var stack: [(Element, State)] = []
            var rootState = State()
            if let state = style(root, from: State()) { rootState = state } else { mark(root); return }
            stack.append((root, rootState))
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
            var values = cascade(element, tag: tag)

            // Custom properties first, then every value that uses one.
            var state = parent
            for (name, value) in values where name.hasPrefix("--") {
                state.custom[name] = StyleRules.substitute(value, custom: parent.custom) ?? ""
            }
            var deferred: [(String, String)] = []
            for (name, value) in values where !name.hasPrefix("--") && value.contains("var(") {
                values[name] = nil
                if let resolved = StyleRules.substitute(value, custom: state.custom) {
                    if name.hasPrefix("@") { deferred.append((String(name.dropFirst()), resolved)) } else { values[name] = resolved }
                }
            }
            for (name, value) in deferred { StyleRules.apply(name, value, into: &values) }

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
            if let opacity = values["opacity"].flatMap(StyleRules.fraction) { state.opacity *= opacity }
            if let filter = values["filter"].flatMap(StyleRules.filterOpacity) { state.opacity *= filter }

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
                let points = spacing == "normal" ? 0 : CSSLength.length(spacing, relativeTo: fontSize, font: fontSize) ?? 0
                state.letterSpacingHides = points <= -0.3 * fontSize
            }

            let behind = StyleRules.behind(values, over: parent.behind)
            if let clip = values["background-clip"], clip.split(separator: " ").contains("text") {
                state.clipPaint = StyleRules.clipPaint(values)
            } else {
                state.behind = behind
            }
            return state
        }

        /// The element's declarations after the cascade: the old presentational attributes first, then the rules by
        /// importance, then style attribute over selectors, then specificity, then order; invalid values dropped.
        private func cascade(_ element: Element, tag: String) -> [String: String] {
            var values: [String: String] = [:]
            if element.hasAttr("hidden") { values["display"] = "none" }
            if let attribute = try? element.attr("bgcolor"), let color = CSSColor.legacy(attribute) {
                values["background-color"] = color.cssText
            }
            if let picture = try? element.attr("background"), !picture.isEmpty {
                values["background-image"] = "url(\(picture.lowercased()))"
            }
            if tag == "font" {
                if let color = (try? element.attr("color")).flatMap(CSSColor.legacy) { values["color"] = color.cssText }
                if let size = try? element.attr("size"), let points = StyleRules.fontTagSize(size) { values["font-size"] = "\(points)px" }
            }
            if tag == "body", let color = (try? element.attr("text")).flatMap(CSSColor.legacy) { values["color"] = color.cssText }

            var declared: [(important: Bool, inline: Bool, specificity: Int, order: Int, index: Int, declaration: CSSDeclaration)] = []
            for (specificity, order, declarations) in matches.byElement[ObjectIdentifier(element)] ?? [] {
                for (index, declaration) in declarations.enumerated() {
                    declared.append((declaration.important, false, specificity, order, index, declaration))
                }
            }
            if let style = try? element.attr("style"), !style.isEmpty {
                for (index, declaration) in CSSText.declarations(style).enumerated() {
                    declared.append((declaration.important, true, 0, 0, index, declaration))
                }
            }
            declared.sort {
                if $0.important != $1.important { return !$0.important }
                if $0.inline != $1.inline { return !$0.inline }
                if $0.specificity != $1.specificity { return $0.specificity < $1.specificity }
                if $0.order != $1.order { return $0.order < $1.order }
                return $0.index < $1.index
            }
            for entry in declared { StyleRules.apply(entry.declaration.name, entry.declaration.value, into: &values) }
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
/// open and close on a stack, an end tag closes the element it names or nothing, paragraphs, items and cells close
/// each other, comments and raw text such as scripts are skipped, quotes count only around attribute values.
enum NestingGuard {
    struct Shape {
        var depth = 0
        var elements = 0
        var styleBytes = 0
    }

    private static let void: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr", "param",
        "keygen", "basefont", "bgsound", "frame", "image",
    ]
    private static let rawText: Set<String> = ["script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes"]
    private static let closesParagraph: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div", "dl", "fieldset",
        "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "main",
        "menu", "nav", "ol", "p", "pre", "section", "summary", "table", "ul", "li", "dd", "dt", "listing", "xmp",
    ]
    private static let scope: Set<String> = ["html", "table", "td", "th", "caption", "marquee", "object", "applet", "template", "button"]

    static func exceeds(_ html: String, depth limit: Int) -> Bool {
        measure(html, stopAt: limit).depth > limit
    }

    static func measure(_ html: String, stopAt limit: Int) -> Shape {
        let bytes = Array(html.utf8)
        let count = bytes.count
        var shape = Shape()
        var stack: [String] = []
        var tables = 0
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
        /// Closes `targets` if one is open above any of `boundaries`, looking at most 64 elements down.
        func close(_ targets: Set<String>, within boundaries: Set<String>) {
            var position = stack.count - 1
            var looked = 0
            while position >= 0, looked < 64 {
                let open = stack[position]
                if targets.contains(open) {
                    tables -= stack[position...].lazy.filter { $0 == "table" }.count
                    stack.removeSubrange(position...)
                    return
                }
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
                    let end = [find(Array("-->".utf8), from: body, ignoringCase: false).map { $0 + 3 },
                               find(Array("--!>".utf8), from: body, ignoringCase: false).map { $0 + 4 }].compactMap { $0 }.min()
                    index = end ?? count
                } else {
                    // <!DOCTYPE …>, <!x …>: a bogus comment, to the first >.
                    index = (find([62], from: index + 2, ignoringCase: false) ?? count) + 1
                }
            } else if next == 63 {
                index = (find([62], from: index + 2, ignoringCase: false) ?? count) + 1
            } else if next == 47 {
                guard index + 2 < count, isLetter(bytes[index + 2]) else {
                    index = (find([62], from: index + 2, ignoringCase: false) ?? count) + 1
                    continue
                }
                let (tag, end) = name(at: index + 2)
                index = endOfTag(from: end)
                if !void.contains(tag) { close([tag], within: []) }
            } else if isLetter(next) {
                let (tag, end) = name(at: index + 1)
                index = endOfTag(from: end)
                if ["html", "head", "body"].contains(tag) { continue }
                // Table parts outside a table are dropped by the parser.
                if tables == 0, ["td", "th", "tr", "tbody", "thead", "tfoot", "caption", "col", "colgroup"].contains(tag) { continue }
                shape.elements += 1
                if closesParagraph.contains(tag) { close(["p"], within: scope) }
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
                if rawText.contains(tag) {
                    let end = find(Array("</\(tag)".utf8), from: index, ignoringCase: true) ?? count
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

    /// Sets the declaration on the element's values, expanding shorthands, if its value is one the property takes:
    /// a browser drops any other, and the value before it stays.
    static func apply(_ name: String, _ value: String, into values: inout [String: String]) {
        if name.hasPrefix("--") { values[name] = value; return }
        let pending = value.contains("var(")
        let shorthands: Set<String> = ["background", "font", "margin", "inset", "overflow", "-webkit-text-stroke"]
        if pending, shorthands.contains(name) { values["@" + name] = value; return }
        switch name {
        case "display":
            let words = value.split(whereSeparator: \.isWhitespace).map(String.init)
            if pending || keywords.contains(value) || (!words.isEmpty && words.allSatisfy(displayWords.contains)) { values[name] = value }
        case "visibility":
            if pending || ["visible", "hidden", "collapse"].contains(value) || keywords.contains(value) { values[name] = value }
        case "content-visibility":
            if pending || ["visible", "hidden", "auto"].contains(value) || keywords.contains(value) { values[name] = value }
        case "opacity":
            if pending || fraction(value) != nil || keywords.contains(value) { values[name] = value }
        case "color", "-webkit-text-fill-color", "background-color", "-webkit-text-stroke-color":
            if pending || CSSColor.read(value) != nil { values[name] = value }
        case "font-size":
            if pending || CSSLength.fontSize(value, inherited: CSSLength.rootFontSize) != nil { values[name] = value }
        case "font":
            if let size = fontSize(inShorthand: value) { values["font-size"] = size }
        case "background":
            let image = images(in: value)
            values["background-image"] = image.isEmpty ? "none" : image.joined(separator: ", ")
            var rest = value
            for picture in image { rest = rest.replacingOccurrences(of: picture, with: " ") }
            values["background-color"] = color(inShorthand: rest)?.cssText ?? "transparent"
            if rest.split(whereSeparator: { $0 == " " || $0 == "," }).contains("text") { values["background-clip"] = "text" }
        case "background-clip", "-webkit-background-clip":
            values["background-clip"] = value
        case "margin":
            let parts = CSSColor.splitTopLevel(value, by: " ")
            guard (1...4).contains(parts.count) else { return }
            values["margin-top"] = parts[0]
            values["margin-left"] = parts.count == 4 ? parts[3] : parts.count >= 2 ? parts[1] : parts[0]
        case "inset":
            let parts = CSSColor.splitTopLevel(value, by: " ")
            guard (1...4).contains(parts.count) else { return }
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
        case "background-image", "margin-left", "margin-top", "position", "left", "top", "right", "bottom", "height",
             "max-height", "width", "max-width", "text-indent", "white-space", "transform", "translate", "scale", "zoom",
             "filter", "clip", "clip-path", "letter-spacing", "font-size-adjust", "overflow-x", "overflow-y",
             "-webkit-text-stroke-width":
            values[name] = value
        default:
            break
        }
    }

    /// The value with each `var(--name, fallback)` replaced; nil when one names nothing and has no fallback, which
    /// makes the declaration fall back to inheriting.
    static func substitute(_ value: String, custom: [String: String], depth: Int = 0) -> String? {
        guard let start = value.range(of: "var(") else { return value }
        guard depth < 8 else { return nil }
        var level = 1
        var index = start.upperBound
        while index < value.endIndex, level > 0 {
            if value[index] == "(" { level += 1 }
            if value[index] == ")" { level -= 1 }
            if level > 0 { index = value.index(after: index) }
        }
        guard index < value.endIndex else { return nil }
        let inside = String(value[start.upperBound..<index])
        let parts = CSSColor.splitTopLevel(inside, by: ",")
        let name = parts[0].trimmingCharacters(in: .whitespaces)
        let fallback = parts.count > 1 ? parts.dropFirst().joined(separator: ",").trimmingCharacters(in: .whitespaces) : nil
        guard let replacement = custom[name].flatMap({ $0.isEmpty ? nil : $0 }) ?? fallback else { return nil }
        let replaced = String(value[..<start.lowerBound]) + replacement + String(value[value.index(after: index)...])
        return substitute(replaced, custom: custom, depth: depth + 1)
    }

    /// The pictures and gradients of a `background` value.
    static func images(in value: String) -> [String] {
        value.matches(of: #/(?:url|(?:repeating-)?(?:linear|radial|conic)-gradient|image-set|image|-webkit-gradient|-webkit-linear-gradient)\((?:[^()]|\([^()]*\))*\)/#).map { String($0.0) }
    }

    /// What is behind the element's text: its own color over what is behind it, under its gradient. Proton loads no
    /// remote picture until the reader asks, and a picture carried in the email may be anything: neither counts, so
    /// text is judged against the color shown when no picture is.
    static func behind(_ values: [String: String], over parent: HTMLSanitizer.Behind) -> HTMLSanitizer.Behind {
        var base = parent
        if let value = values["background-color"], let color = CSSColor.parse(value), color.alpha > 0.05 {
            base = color.alpha >= 0.95 ? .color(CSSColor(red: color.red, green: color.green, blue: color.blue)) : parent.under(color)
        }
        let stops = (values["background-image"].map(images(in:)) ?? []).filter { $0.contains("gradient(") }.flatMap(CSSColor.stops(inGradient:))
        guard !stops.isEmpty else { return base }
        let ground: CSSColor
        switch base {
        case .color(let color): ground = color
        case .gradient(let colors): ground = colors.first ?? .white
        }
        return .gradient(stops.map { $0.over(ground) })
    }

    /// What paints text clipped to the element's background.
    static func clipPaint(_ values: [String: String]) -> HTMLSanitizer.ClipPaint {
        let pictures = values["background-image"].map(images(in:)) ?? []
        let stops = pictures.filter { $0.contains("gradient(") }.flatMap(CSSColor.stops(inGradient:))
        if !stops.isEmpty { return .stops(stops) }
        if pictures.contains(where: { $0.range(of: #"^url\(\s*['"]?\s*(?:cid|data):"#, options: .regularExpression) != nil }) { return .picture }
        if let color = values["background-color"].flatMap(CSSColor.parse), color.alpha > 0.05 { return .stops([color]) }
        return .nothing
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
            guard let first = size.first, first.isNumber || first == "." || size.hasPrefix("calc(") || size.hasPrefix("min(") || size.hasPrefix("max(") || size.hasPrefix("clamp(") else { continue }
            if size == "0" || size.contains(where: \.isLetter) || size.hasSuffix("%") { return size }
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

    /// `0.4` or `40%` as 0.4, between 0 and 1.
    static func fraction(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let number = trimmed.hasSuffix("%") ? Double(trimmed.dropLast()).map { $0 / 100 } : Double(trimmed)
        guard let number, number.isFinite else { return nil }
        return min(max(number, 0), 1)
    }

    /// The product of the `opacity()` functions in a `filter`.
    static func filterOpacity(_ value: String) -> Double? {
        let found = value.matches(of: #/opacity\(\s*([^)\s]+)\s*\)/#).compactMap { fraction(String($0.1)) }
        return found.isEmpty ? nil : found.reduce(1, *)
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
            for match in transform.matches(of: #/(scale|scalex|scaley|scale3d|matrix)\(([^)]*)\)/#) {
                let numbers = match.2.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.compactMap(number)
                switch match.1 {
                case "scale": if let x = numbers.first { factor *= min(abs(x), abs(numbers.count > 1 ? numbers[1] : x)) }
                case "scalex", "scaley": if let x = numbers.first { factor *= abs(x) }
                case "scale3d": if numbers.count >= 2 { factor *= min(abs(numbers[0]), abs(numbers[1])) }
                default: if numbers.count == 6 { factor *= sqrt(abs(numbers[0] * numbers[3] - numbers[1] * numbers[2])) }
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
        if let display = values["display"], display.split(separator: " ").first == "none" { return true }
        if values["content-visibility"] == "hidden" { return true }
        func length(_ key: String, _ reference: Double) -> Double? {
            values[key].flatMap { CSSLength.length($0, relativeTo: reference, font: font) }
        }
        let clipped = ["overflow-x", "overflow-y"].contains { ["hidden", "clip"].contains(values[$0] ?? "") }
        if clipped {
            for key in ["height", "max-height"] where (length(key, 600) ?? 2) <= 1 { return true }
            for key in ["width", "max-width"] where (length(key, 800) ?? 2) <= 1 { return true }
        }
        if let indent = length("text-indent", 800) {
            if indent <= -500 || indent >= 2_000 || (clipped && indent >= 800) { return true }
        }
        if let position = values["position"], ["absolute", "fixed", "relative", "sticky"].contains(position) {
            if let left = length("left", 800), left <= -500 { return true }
            if let top = length("top", 600), top <= -500 { return true }
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

    /// `clip-path` shapes that leave nothing: an inset that meets itself, a circle or an ellipse of no size, a
    /// polygon whose points all fall in one place.
    private static func clipPathHides(_ value: String, font: Double) -> Bool {
        if let match = value.firstMatch(of: #/inset\(([^)]*)\)/#) {
            let parts = CSSColor.splitTopLevel(String(match.1).components(separatedBy: " round ")[0], by: " ")
            guard (1...4).contains(parts.count) else { return false }
            let top = parts[0], right = parts.count >= 2 ? parts[1] : parts[0]
            let bottom = parts.count >= 3 ? parts[2] : parts[0], left = parts.count == 4 ? parts[3] : right
            func share(_ part: String) -> Double? {
                part.hasSuffix("%") ? Double(part.dropLast()).map { $0 / 100 } : CSSLength.length(part, relativeTo: 0, font: font).map { $0 >= 2_000 ? 1 : 0 }
            }
            if let t = share(top), let b = share(bottom), t + b >= 1 { return true }
            if let l = share(left), let r = share(right), l + r >= 1 { return true }
        }
        if let match = value.firstMatch(of: #/(?:circle|ellipse)\(\s*([^)\s]*)/#), let radius = CSSLength.length(String(match.1), relativeTo: 100, font: font), radius <= 0 {
            return true
        }
        if let match = value.firstMatch(of: #/polygon\(([^)]*)\)/#) {
            let points = String(match.1).split(separator: ",").map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            if points.count >= 1, Set(points).count == 1 { return true }
        }
        return false
    }

    /// A transform that moves the box hundreds of points off the page, or turns it edge-on.
    private static func transformHides(_ value: String, font: Double) -> Bool {
        for match in value.matches(of: #/([a-z0-9]+)\(([^)]*)\)/#) {
            let arguments = match.2.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            func off(_ index: Int, _ reference: Double) -> Bool {
                index < arguments.count && (CSSLength.length(arguments[index], relativeTo: reference, font: font) ?? 0) <= -500
            }
            switch match.1 {
            case "translate", "translate3d": if off(0, 800) || off(1, 600) { return true }
            case "translatex": if off(0, 800) { return true }
            case "translatey": if off(0, 600) { return true }
            case "rotatex", "rotatey", "skew", "skewx", "skewy":
                for argument in arguments {
                    guard let degrees = angle(argument) else { continue }
                    let folded = abs(degrees.truncatingRemainder(dividingBy: 180))
                    if abs(folded - 90) < 1 { return true }
                }
            case "matrix":
                let numbers = arguments.compactMap(number)
                if numbers.count == 6, numbers[4] <= -500 || numbers[5] <= -500 { return true }
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
