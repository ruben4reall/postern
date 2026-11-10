import Foundation
import SwiftSoup

/// One declaration as written in a style: a property, its value, and whether it is `!important`.
struct CSSDeclaration: Equatable {
    let name: String
    let value: String
    let important: Bool
}

/// CSS text read the way a browser reads it: comments removed, escapes decoded, declarations split where the
/// parser would split them.
enum CSSText {
    /// The text without its comments, outside strings. A comment never closed runs to the end.
    static func stripComments(_ css: String) -> String {
        let scalars = Array(css.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        var quote: Unicode.Scalar?
        while index < scalars.count {
            let scalar = scalars[index]
            if let open = quote {
                output.append(scalar)
                if scalar == "\\", index + 1 < scalars.count { output.append(scalars[index + 1]); index += 2; continue }
                if scalar == open || scalar == "\n" { quote = nil }
                index += 1
            } else if scalar == "\"" || scalar == "'" {
                quote = scalar
                output.append(scalar)
                index += 1
            } else if scalar == "\\", index + 1 < scalars.count {
                output.append(scalar)
                output.append(scalars[index + 1])
                index += 2
            } else if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "*" {
                index += 2
                while index + 1 < scalars.count, !(scalars[index] == "*" && scalars[index + 1] == "/") { index += 1 }
                index = min(index + 2, scalars.count)
                output.append(" ")
            } else {
                output.append(scalar)
                index += 1
            }
        }
        return String(output)
    }

    /// `displ\61y` is `display`, `\:` is `:`.
    static func decodeEscapes(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "\\", index + 1 < scalars.count else { output.append(scalar); index += 1; continue }
            var end = index + 1
            var hex = ""
            while end < scalars.count, hex.count < 6, scalars[end].properties.isASCIIHexDigit {
                hex.unicodeScalars.append(scalars[end])
                end += 1
            }
            if hex.isEmpty {
                if scalars[index + 1] != "\n" { output.append(scalars[index + 1]) }
                index += 2
                continue
            }
            if end < scalars.count, scalars[end] == " " || scalars[end] == "\t" || scalars[end] == "\n" { end += 1 }
            let value = UInt32(hex, radix: 16) ?? 0xFFFD
            output.append(Unicode.Scalar(value == 0 || value > 0x10FFFF ? 0xFFFD : value) ?? "\u{FFFD}")
            index = end
        }
        return String(output)
    }

    /// The declarations of a style attribute or of a rule's block, in order. Custom property names keep their case,
    /// and so does a value that uses one, until it is substituted.
    static func declarations(_ block: String) -> [CSSDeclaration] {
        CSSColor.splitTopLevel(stripComments(block), by: ";").compactMap { part in
            guard let colon = part.firstIndex(of: ":") else { return nil }
            var name = decodeEscapes(String(part[..<colon])).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = decodeEscapes(String(part[part.index(after: colon)...])).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
            if !name.hasPrefix("--") { name = name.lowercased() }
            var important = false
            if let flag = value.range(of: #"!\s*important\s*$"#, options: [.regularExpression, .caseInsensitive]) {
                important = true
                value = String(value[..<flag.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !value.isEmpty || name.hasPrefix("--") else { return nil }
            let keepCase = name.hasPrefix("--") || value.contains("var(")
            return CSSDeclaration(name: name, value: keepCase ? value : value.lowercased(), important: important)
        }
    }
}

/// A rule of a `<style>` block: its selectors, each with its specificity, and whether it sits in a cascade layer,
/// which ranks it below every rule outside layers.
struct StyleRule {
    let selectors: [(text: String, specificity: Int)]
    let declarations: [CSSDeclaration]
    let order: Int
    let layered: Bool
}

/// The rules of a message's `<style>` blocks that apply in a desktop window, the way Proton shows mail: rules for
/// small screens, print or dark mode are left out, nesting and the `@supports`, `@layer` and `@container` blocks are
/// read through, and selectors that depend on hover or focus never apply. What cannot be read is not dropped: a
/// rule whose selector holds a pseudo-class this reader does not know applies as if it were true, and a page whose
/// styles go past what can be read safely is refused.
struct StyleSheet {
    /// The widths of Proton's reading pane on a Mac: a rule for any of them applies.
    static let widths = 800.0...1600.0
    static let maxRules = 5_000
    static let maxDepth = 32

    private(set) var rules: [StyleRule] = []
    /// Nested deeper, or with more rules or longer selectors, than any real stylesheet.
    private(set) var tooComplex = false
    /// A selector picks elements by their position among their siblings, which SwiftSoup works out slowly.
    private(set) var positional = false

    init(_ blocks: [String]) {
        for block in blocks {
            parse(Array(CSSText.stripComments(block)), selectors: nil, layered: false, depth: 0)
            if tooComplex { return }
        }
    }

    /// The index just past the block that opens at `start`, counting parentheses, brackets and strings as the
    /// tokenizer does: a brace inside parentheses or a string closes nothing.
    private static func endOfBlock(_ text: [Character], from start: Int) -> Int {
        var index = start
        var braces = 1
        var nested = 0
        var quote: Character?
        while index < text.count {
            let character = text[index]
            if character == "\\" { index += 2; continue }
            if let open = quote {
                if character == open || character == "\n" { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "(" || character == "[" {
                nested += 1
            } else if character == ")" || character == "]" {
                nested = max(0, nested - 1)
            } else if nested == 0, character == "{" {
                braces += 1
            } else if nested == 0, character == "}" {
                braces -= 1
                if braces == 0 { return index }
            }
            index += 1
        }
        return text.count
    }

    private mutating func parse(_ text: [Character], selectors: [String]?, layered: Bool, depth: Int) {
        guard depth <= Self.maxDepth, rules.count <= Self.maxRules else { tooComplex = true; return }
        var declarationText = ""
        var segment = ""
        var index = 0
        var quote: Character?
        var nested = 0
        while index < text.count {
            let character = text[index]
            if character == "\\", index + 1 < text.count {
                segment.append(character)
                segment.append(text[index + 1])
                index += 2
                continue
            }
            if let open = quote {
                segment.append(character)
                if character == open || character == "\n" { quote = nil }
                index += 1
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
                segment.append(character)
            case "(", "[":
                nested += 1
                segment.append(character)
            case ")", "]":
                nested = max(0, nested - 1)
                segment.append(character)
            case ";" where nested == 0:
                // A declaration inside a rule; at the top level, an at-rule statement such as @import.
                if selectors != nil { declarationText += segment + ";" }
                segment = ""
            case "{" where nested == 0:
                let end = Self.endOfBlock(text, from: index + 1)
                let prelude = segment.replacingOccurrences(of: "<!--", with: " ").replacingOccurrences(of: "-->", with: " ")
                block(prelude: prelude.trimmingCharacters(in: .whitespacesAndNewlines), body: Array(text[(index + 1)..<end]),
                      selectors: selectors, layered: layered, depth: depth)
                if tooComplex { return }
                segment = ""
                index = end + 1
                continue
            case "}" where nested == 0:
                segment = ""
            default:
                segment.append(character)
            }
            index += 1
        }
        if selectors != nil { declarationText += segment }
        if let selectors, !declarationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(selectors, CSSText.declarations(declarationText), layered: layered)
        }
    }

    private mutating func block(prelude: String, body: [Character], selectors: [String]?, layered: Bool, depth: Int) {
        let lowered = prelude.lowercased()
        if lowered.hasPrefix("@") {
            let name = lowered.dropFirst().prefix { $0.isLetter || $0 == "-" }
            let condition = String(lowered.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
            switch name {
            case "media":
                if Self.applies(media: condition) { parse(body, selectors: selectors, layered: layered, depth: depth + 1) }
            case "supports":
                // Proton runs in a current browser: a feature test holds, unless it asks for what is missing.
                if !condition.hasPrefix("not") { parse(body, selectors: selectors, layered: layered, depth: depth + 1) }
            case "layer":
                parse(body, selectors: selectors, layered: true, depth: depth + 1)
            case "container", "scope", "document", "-moz-document", "starting-style":
                parse(body, selectors: selectors, layered: layered, depth: depth + 1)
            default:
                // @font-face, @keyframes, @page and the like hold no rules for elements.
                break
            }
            return
        }
        let written = CSSColor.splitTopLevel(prelude, by: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !written.isEmpty else { return }
        var combined: [String] = []
        if let parents = selectors {
            for parent in parents {
                for selector in written {
                    combined.append(selector.contains("&") ? selector.replacingOccurrences(of: "&", with: ":is(\(parent))") : parent + " " + selector)
                }
            }
        } else {
            combined = written.map { $0.replacingOccurrences(of: ":scope", with: ":root") }
        }
        guard combined.count <= 256 else { tooComplex = true; return }
        parse(body, selectors: combined, layered: layered, depth: depth + 1)
    }

    private mutating func add(_ selectors: [String], _ declarations: [CSSDeclaration], layered: Bool) {
        guard !declarations.isEmpty else { return }
        var usable: [(String, Int)] = []
        for selector in selectors {
            guard let alternatives = Self.rewrite(selector) else { tooComplex = true; return }
            let specificity = Self.specificity(of: selector)
            for alternative in alternatives {
                usable.append((alternative, specificity))
                if alternative.contains(":nth-") || alternative.contains(":first-") || alternative.contains(":last-")
                    || alternative.contains(":only-") {
                    positional = true
                }
            }
        }
        guard !usable.isEmpty else { return }
        rules.append(StyleRule(selectors: usable, declarations: declarations, order: rules.count, layered: layered))
        if rules.count > Self.maxRules { tooComplex = true }
    }

    // MARK: Selectors

    /// Pseudo-classes SwiftSoup reads as a browser does.
    private static let structural: Set<String> = [
        "not", "nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type", "first-child", "last-child",
        "first-of-type", "last-of-type", "only-child", "only-of-type", "empty", "root", "has",
    ]
    /// Pseudo-classes browsers know that every element of a page at rest matches, or that this reader reads as
    /// matching rather than risk missing a rule that hides.
    private static let trueAtRest: Set<String> = [
        "read-only", "defined", "dir", "lang", "enabled", "optional", "valid", "in-range", "default", "scope",
        "local-link", "indeterminate", "blank", "host", "host-context", "-webkit-any-link", "-moz-any-link",
    ]
    /// Pseudo-classes never true on a page at rest, nobody hovering or typing.
    private static let atRestFalse = [
        "hover", "focus", "focus-within", "focus-visible", "active", "visited", "target", "target-within", "playing",
        "paused", "fullscreen", "modal", "picture-in-picture", "popover-open", "current", "past", "future", "autofill",
        "-webkit-autofill", "user-invalid", "user-valid", "open", "read-write", "placeholder-shown", "dir\\(rtl\\)",
    ].joined(separator: "|")
    /// Pseudo-elements that style something other than the element's own text.
    private static let otherPseudoElements = #"::?(?:before|after|marker|placeholder|selection|backdrop|file-selector-button|cue|grammar-error|spelling-error|target-text|highlight\([^)]*\)|part\([^)]*\)|slotted\([^)]*\)|-webkit-[\w-]+|-moz-[\w-]+|-ms-[\w-]+)"#

    /// A selector as SwiftSoup can match it on a page at rest, in one or more alternatives; an empty list when it
    /// never applies then, nil when it is too complex to read safely. `:not(:hover)` is always true, `:hover`
    /// never; `:link` is every link; `:is()` and `:where()` become their alternatives; a rule for `::first-line` is
    /// read as a rule for the element; a pseudo-class this reader does not know is read as true.
    static func rewrite(_ selector: String) -> [String]? {
        var text = selector
        // What attribute values and strings say is not selector syntax.
        let bare = text.replacingOccurrences(of: #"\[[^\]]*\]|"[^"]*"|'[^']*'"#, with: "[]", options: .regularExpression)
        if bare.range(of: otherPseudoElements, options: [.regularExpression, .caseInsensitive]) != nil { return [] }
        for (pattern, replacement) in [
            (#"::?first-(?:line|letter)"#, ""),
            (":not\\(\\s*:(?:\(atRestFalse))\\s*\\)", ""),
            (#":(?:any-)?link\b"#, "[href]"),
            (#":checked\b"#, "[checked]"),
            (#":disabled\b"#, "[disabled]"),
            (#":required\b"#, "[required]"),
            (#":-(?:webkit|moz)-any\("#, ":is("),
            (#":matches\("#, ":is("),
        ] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        if text.replacingOccurrences(of: #"\[[^\]]*\]|"[^"]*"|'[^']*'"#, with: "[]", options: .regularExpression)
            .range(of: ":(?:\(atRestFalse))(?![\\w-])", options: [.regularExpression, .caseInsensitive]) != nil {
            return []
        }
        var alternatives = [text]
        // :is(a, b) and :where(a, b), expanded into one selector per argument.
        var rounds = 0
        while let open = alternatives.first(where: { $0.range(of: #":(?:is|where)\("#, options: .regularExpression) != nil }) {
            rounds += 1
            guard rounds <= 64 else { return nil }
            alternatives.removeAll { $0 == open }
            guard let start = open.range(of: #":(?:is|where)\("#, options: .regularExpression),
                  let close = matchingParenthesis(in: open, from: start.upperBound) else { return nil }
            let inside = String(open[start.upperBound..<close])
            for argument in CSSColor.splitTopLevel(inside, by: ",") {
                alternatives.append(String(open[..<start.lowerBound]) + argument.trimmingCharacters(in: .whitespaces) + String(open[open.index(after: close)...]))
            }
            if alternatives.count > 64 { return nil }
        }
        return alternatives.compactMap { candidate in
            var result = candidate
            // Pseudo-classes browsers know that hold for every element at rest, such as :read-only, :defined or
            // :lang(), are read as true. One no browser knows makes the selector invalid, and browsers drop it.
            let bare = result.replacingOccurrences(of: #"\[[^\]]*\]|"[^"]*"|'[^']*'"#, with: "[]", options: .regularExpression)
            for match in bare.matches(of: #/:([a-zA-Z-]+)(\([^()]*\))?/#) where !structural.contains(match.1.lowercased()) {
                guard trueAtRest.contains(match.1.lowercased()) else { return nil }
                result = result.replacingOccurrences(of: String(match.0), with: "")
            }
            result = result.replacingOccurrences(of: #":not\(\s*\)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if result.isEmpty || result.hasSuffix(">") || result.hasSuffix("+") || result.hasSuffix("~") { result += "*" }
            return result.contains("&") ? nil : result
        }
    }

    private static func matchingParenthesis(in text: String, from start: String.Index) -> String.Index? {
        var depth = 1
        var index = start
        while index < text.endIndex {
            if text[index] == "(" { depth += 1 }
            if text[index] == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Ids, then classes, attributes and pseudo-classes, then element names, as one number to sort by. `:is()`,
    /// `:not()` and `:has()` count as their most specific argument, `:where()` as nothing.
    static func specificity(of selector: String, depth: Int = 0) -> Int {
        guard depth < 8 else { return 0 }
        var text = selector.replacingOccurrences(of: #""[^"]*"|'[^']*'"#, with: "", options: .regularExpression)
        var extra = 0
        // Functional pseudo-classes, innermost first by repetition.
        while let start = text.range(of: #":(?:is|not|has|where|matches|-webkit-any|-moz-any)\("#, options: [.regularExpression, .caseInsensitive]),
              let close = matchingParenthesis(in: text, from: start.upperBound) {
            let name = text[start].lowercased()
            let inside = String(text[start.upperBound..<close])
            if !name.contains("where") {
                extra += CSSColor.splitTopLevel(inside, by: ",").map { specificity(of: $0, depth: depth + 1) }.max() ?? 0
            }
            text.replaceSubrange(start.lowerBound...close, with: " ")
        }
        let attributes = text.matches(of: #/\[[^\]]*\]/#).count
        text = text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        let ids = text.matches(of: #/#[\w-]+/#).count
        let classes = text.matches(of: #/\.[\w-]+/#).count
        let pseudoElements = text.matches(of: #/::[\w-]+/#).count
        text = text.replacingOccurrences(of: #"::[\w-]+"#, with: " ", options: .regularExpression)
        let pseudoClasses = text.matches(of: #/:[\w-]+/#).count
        let types = text.matches(of: #/(?:^|[\s>+~(,])([a-zA-Z][\w-]*)/#).count
        return min(ids, 99) * 10_000 + min(classes + attributes + pseudoClasses, 99) * 100 + min(types + pseudoElements, 99) + extra
    }

    // MARK: Media

    /// Whether a media query list matches Proton's reading pane on a Mac: a screen in light mode, between 800 and
    /// 1,600 points wide, with a mouse.
    static func applies(media list: String) -> Bool {
        let queries = CSSColor.splitTopLevel(list, by: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if queries.allSatisfy(\.isEmpty) { return true }
        return queries.contains { query in
            if query.hasPrefix("not ") { return !matches(String(query.dropFirst(4))) }
            return matches(query.hasPrefix("only ") ? String(query.dropFirst(5)) : query)
        }
    }

    /// One query: a media type, then conditions joined by `and`, each possibly negated with `not`.
    private static func matches(_ query: String) -> Bool {
        var lower = widths.lowerBound
        var upper = widths.upperBound
        for raw in query.components(separatedBy: " and ") {
            var condition = raw.trimmingCharacters(in: .whitespaces)
            if condition.isEmpty { continue }
            var negated = false
            while true {
                while condition.hasPrefix("("), condition.hasSuffix(")") { condition = String(condition.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces) }
                guard condition.hasPrefix("not ") || condition.hasPrefix("not(") else { break }
                negated.toggle()
                condition = String(condition.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
            if !condition.contains(":"), !condition.contains("<"), !condition.contains(">"), !condition.contains("=") {
                // A media type, or a feature named alone such as (hover).
                let holds = ["screen", "all", "hover", "any-hover", "pointer", "any-pointer", "color", "grid", "update"].contains(condition)
                    || !["print", "speech", "tty", "braille", "embossed", "handheld", "projection", "tv"].contains(condition)
                if holds == negated { return false }
                continue
            }
            if let bounds = widthBounds(condition) {
                // A width outside reach is ignored when negated: the complement of a range is two ranges.
                if !negated {
                    lower = max(lower, bounds.lowerBound)
                    upper = min(upper, bounds.upperBound)
                }
                continue
            }
            let parts = condition.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let holds: Bool
            switch parts[0] {
            case "prefers-color-scheme": holds = parts[1] != "dark"
            case "orientation": holds = parts[1] == "landscape"
            case "hover", "any-hover": holds = parts[1] != "none"
            case "pointer", "any-pointer": holds = parts[1] == "fine"
            case "prefers-reduced-motion", "prefers-contrast", "forced-colors", "inverted-colors", "prefers-reduced-transparency":
                holds = ["no-preference", "none"].contains(parts[1])
            default: holds = true
            }
            if holds == negated { return false }
        }
        return lower <= upper
    }

    /// The widths a width condition allows; nil when the condition is not about width. Units relative to the
    /// window, such as `100vw`, allow every width.
    private static func widthBounds(_ condition: String) -> ClosedRange<Double>? {
        func points(_ text: Substring) -> Double? {
            let value = text.trimmingCharacters(in: .whitespaces)
            if ["vw", "vh", "vmin", "vmax", "%", "dvw", "svw", "lvw"].contains(where: value.hasSuffix) { return nil }
            return CSSLength.length(value, relativeTo: 0)
        }
        let all = 0.0...Double.greatestFiniteMagnitude
        if let match = condition.firstMatch(of: #/^(min|max)-(?:device-)?width\s*:\s*(.+)$/#) {
            guard let value = points(match.2) else { return all }
            return match.1 == "min" ? value...Double.greatestFiniteMagnitude : 0...max(0, value)
        }
        if let match = condition.firstMatch(of: #/^(?:device-)?width\s*(>=|<=|>|<|=)\s*(.+)$/#) {
            guard let value = points(match.2) else { return all }
            switch match.1 {
            case ">=", ">": return value...Double.greatestFiniteMagnitude
            case "=": return value...value
            default: return 0...max(0, value)
            }
        }
        if let match = condition.firstMatch(of: #/^(.+?)\s*(<=|<|>=|>)\s*(?:device-)?width(?:\s*(<=|<)\s*(.+))?$/#) {
            guard let value = points(match.1) else { return all }
            var range: ClosedRange<Double> = match.2.hasPrefix("<") ? value...Double.greatestFiniteMagnitude : 0...max(0, value)
            if let high = match.4, let top = points(high) { range = range.lowerBound...max(range.lowerBound, top) }
            return range
        }
        return nil
    }

    // MARK: Matching

    /// What each element gets from the rules, worked out once on the page as it came, before anything is hidden.
    struct Matches {
        fileprivate(set) var byElement: [ObjectIdentifier: [(specificity: Int, order: Int, layered: Bool, declarations: [CSSDeclaration])]] = [:]
        /// Holds the matched elements so their identifiers stay theirs.
        fileprivate var elements: [Element] = []
    }

    /// A selector cut into compounds joined by combinators, read from the left.
    private struct Compiled {
        enum Combinator { case descendant, child, adjacent, sibling }
        struct Compound {
            let evaluator: Evaluator
            let tag: String?
            let id: String?
            let classes: [String]
        }
        let compounds: [Compound]
        let combinators: [Combinator]
        let rule: Int
        let specificity: Int
    }

    /// Matches every rule in one pass from the top of the page, remembering for each element how far along each
    /// selector its ancestors and earlier siblings got, the way browsers avoid the exponential cost of matching
    /// `div div div` against deep nesting. Nil when the page needs more work than any real email.
    func match(in document: Document, budget: Int = 4_000_000) -> Matches? {
        var compiled: [Compiled] = []
        for (index, rule) in rules.enumerated() {
            for (selector, specificity) in rule.selectors {
                switch Self.compile(selector, rule: index, specificity: specificity) {
                case .ready(let selector): compiled.append(selector)
                case .invalid: continue
                case .tooComplex: return nil
                }
            }
        }
        var matches = Matches()
        guard !compiled.isEmpty else { return matches }
        var spent = 0
        let count = compiled.count
        // Each element: what it achieved (bit k: compounds 0…k match, ending on it) and what its ancestors did.
        var stack: [(element: Element, own: [UInt32], ancestors: [UInt32])] = [(document, Array(repeating: 0, count: count), Array(repeating: 0, count: count))]
        while let frame = stack.popLast() {
            let inherited = zip(frame.ancestors, frame.own).map { $0 | $1 }
            var previous = [UInt32](repeating: 0, count: count)
            var earlier = [UInt32](repeating: 0, count: count)
            var children: [(Element, [UInt32])] = []
            for child in frame.element.children().array() {
                let tag = child.tagName()
                let id = child.id()
                var achieved = [UInt32](repeating: 0, count: count)
                for (position, selector) in compiled.enumerated() {
                    var mask: UInt32 = 0
                    for (k, compound) in selector.compounds.enumerated() {
                        if k > 0 {
                            let bit = UInt32(1) << UInt32(k - 1)
                            let reached: Bool
                            switch selector.combinators[k - 1] {
                            case .descendant: reached = inherited[position] & bit != 0
                            case .child: reached = frame.own[position] & bit != 0
                            case .adjacent: reached = previous[position] & bit != 0
                            case .sibling: reached = earlier[position] & bit != 0
                            }
                            guard reached else { continue }
                        }
                        if let required = compound.tag, required != tag { continue }
                        if let required = compound.id, required != id { continue }
                        if !compound.classes.allSatisfy({ child.hasClass($0) }) { continue }
                        spent += 1
                        if spent > budget { return nil }
                        if (try? compound.evaluator.matches(document, child)) == true { mask |= UInt32(1) << UInt32(k) }
                    }
                    achieved[position] = mask
                    if mask & (UInt32(1) << UInt32(selector.compounds.count - 1)) != 0 {
                        let key = ObjectIdentifier(child)
                        if matches.byElement[key] == nil { matches.elements.append(child) }
                        let rule = rules[selector.rule]
                        matches.byElement[key, default: []].append((selector.specificity, rule.order, rule.layered, rule.declarations))
                    }
                }
                for position in 0..<count { earlier[position] |= achieved[position] }
                previous = achieved
                children.append((child, achieved))
            }
            for (child, achieved) in children.reversed() { stack.append((child, achieved, inherited)) }
        }
        return matches
    }

    private enum Compilation {
        case ready(Compiled)
        /// SwiftSoup cannot read it, nor can a browser: the rule is dropped.
        case invalid
        /// Longer, or with more nested `:has()`, than matching can afford: the page is refused.
        case tooComplex
    }

    /// Cuts a selector at its combinators, outside brackets, parentheses and strings.
    private static func compile(_ selector: String, rule: Int, specificity: Int) -> Compilation {
        var compounds: [String] = []
        var combinators: [Compiled.Combinator] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var pending: Compiled.Combinator?
        func close() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                if !compounds.isEmpty { combinators.append(pending ?? .descendant) }
                compounds.append(trimmed)
                pending = nil
            }
            current = ""
        }
        for character in selector {
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character; current.append(character)
            case "(", "[": depth += 1; current.append(character)
            case ")", "]": depth = max(0, depth - 1); current.append(character)
            case " " where depth == 0, "\t" where depth == 0, "\n" where depth == 0: close()
            case ">" where depth == 0: close(); pending = .child
            case "+" where depth == 0: close(); pending = .adjacent
            case "~" where depth == 0: close(); pending = .sibling
            default: current.append(character)
            }
        }
        close()
        guard !compounds.isEmpty else { return .invalid }
        if compounds.count > 32 || selector.matches(of: #/:has\(/#).count > 1 { return .tooComplex }
        var parsed: [Compiled.Compound] = []
        for compound in compounds {
            guard let evaluator = try? QueryParser.parse(compound) else { return .invalid }
            let outside = compound.replacingOccurrences(of: #"\([^()]*\)|\[[^\]]*\]"#, with: "", options: .regularExpression)
            let tag = outside.firstMatch(of: #/^([a-zA-Z][\w-]*)/#).map { String($0.1).lowercased() }
            let id = outside.firstMatch(of: #/#([\w-]+)/#).map { String($0.1) }
            let classes = outside.matches(of: #/\.([\w-]+)/#).map { String($0.1) }
            parsed.append(.init(evaluator: evaluator, tag: tag, id: id, classes: classes))
        }
        return .ready(Compiled(compounds: parsed, combinators: combinators, rule: rule, specificity: specificity))
    }
}
