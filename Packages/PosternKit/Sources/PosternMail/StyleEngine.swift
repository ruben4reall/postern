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
                if scalar == open { quote = nil }
                index += 1
            } else if scalar == "\"" || scalar == "'" {
                quote = scalar
                output.append(scalar)
                index += 1
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

    /// The declarations of a style attribute or of a rule's block, in order.
    static func declarations(_ block: String) -> [CSSDeclaration] {
        CSSColor.splitTopLevel(stripComments(block), by: ";").compactMap { part in
            guard let colon = part.firstIndex(of: ":") else { return nil }
            let name = decodeEscapes(String(part[..<colon])).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = decodeEscapes(String(part[part.index(after: colon)...])).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
            var important = false
            if let flag = value.range(of: #"!\s*important\s*$"#, options: [.regularExpression, .caseInsensitive]) {
                important = true
                value = String(value[..<flag.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !value.isEmpty else { return nil }
            return CSSDeclaration(name: name, value: name.hasPrefix("--") ? value : value.lowercased(), important: important)
        }
    }
}

/// A rule of a `<style>` block: its selectors, rewritten for SwiftSoup, each with its specificity.
struct StyleRule {
    let selectors: [(text: String, specificity: Int)]
    let declarations: [CSSDeclaration]
    let order: Int
}

/// The rules of a message's `<style>` blocks that apply in a desktop window, the way Proton shows mail: rules for
/// small screens, print or dark mode are left out, nesting and the `@supports`, `@layer` and `@container` blocks are
/// read through, and selectors that depend on hover or focus never apply.
struct StyleSheet {
    /// The widths of Proton's reading pane on a Mac: a rule for any of them applies.
    static let widths = 800.0...1600.0
    static let maxRules = 5_000
    static let maxDepth = 32

    private(set) var rules: [StyleRule] = []
    /// Nested deeper than any real stylesheet, or with more rules than any real email.
    private(set) var tooComplex = false
    /// A selector picks elements by their position among their siblings, which SwiftSoup works out slowly.
    private(set) var positional = false

    init(_ blocks: [String]) {
        for block in blocks {
            parse(Substring(CSSText.stripComments(block)), selectors: nil, depth: 0)
            if tooComplex { return }
        }
    }

    private mutating func parse(_ text: Substring, selectors: [String]?, depth: Int) {
        guard depth <= Self.maxDepth, rules.count <= Self.maxRules else { tooComplex = true; return }
        var declarationText = ""
        var segment = ""
        var index = text.startIndex
        var quote: Character?
        var parentheses = 0
        while index < text.endIndex {
            let character = text[index]
            if let open = quote {
                segment.append(character)
                if character == open { quote = nil }
                index = text.index(after: index)
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
                segment.append(character)
            case "(":
                parentheses += 1
                segment.append(character)
            case ")":
                parentheses = max(0, parentheses - 1)
                segment.append(character)
            case ";" where parentheses == 0:
                // A declaration inside a rule; at the top level, an at-rule statement such as @import.
                if selectors != nil { declarationText += segment + ";" }
                segment = ""
            case "{" where parentheses == 0:
                let blockStart = text.index(after: index)
                var end = blockStart
                var level = 1
                var inner: Character?
                while end < text.endIndex {
                    let c = text[end]
                    if let open = inner {
                        if c == open { inner = nil }
                    } else if c == "\"" || c == "'" {
                        inner = c
                    } else if c == "{" {
                        level += 1
                    } else if c == "}" {
                        level -= 1
                        if level == 0 { break }
                    }
                    end = text.index(after: end)
                }
                block(prelude: segment.trimmingCharacters(in: .whitespacesAndNewlines), body: text[blockStart..<end],
                      selectors: selectors, depth: depth)
                if tooComplex { return }
                segment = ""
                index = end < text.endIndex ? text.index(after: end) : end
                continue
            case "}" where parentheses == 0:
                segment = ""
            default:
                segment.append(character)
            }
            index = text.index(after: index)
        }
        if selectors != nil { declarationText += segment }
        if let selectors, !declarationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(selectors, CSSText.declarations(declarationText))
        }
    }

    private mutating func block(prelude: String, body: Substring, selectors: [String]?, depth: Int) {
        let lowered = prelude.lowercased()
        if lowered.hasPrefix("@") {
            let name = lowered.dropFirst().prefix { $0.isLetter || $0 == "-" }
            switch name {
            case "media":
                if Self.applies(media: String(lowered.dropFirst(6))) { parse(body, selectors: selectors, depth: depth + 1) }
            case "supports", "layer", "container", "scope", "document", "-moz-document", "starting-style":
                parse(body, selectors: selectors, depth: depth + 1)
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
                    combined.append(selector.contains("&") ? selector.replacingOccurrences(of: "&", with: parent) : parent + " " + selector)
                }
            }
        } else {
            combined = written
        }
        guard combined.count <= 256 else { tooComplex = true; return }
        parse(body, selectors: combined, depth: depth + 1)
    }

    private mutating func add(_ selectors: [String], _ declarations: [CSSDeclaration]) {
        guard !declarations.isEmpty else { return }
        var usable: [(String, Int)] = []
        for selector in selectors {
            for alternative in Self.rewrite(selector) {
                usable.append((alternative, Self.specificity(of: selector)))
                if alternative.contains(":nth-") || alternative.contains(":first-") || alternative.contains(":last-")
                    || alternative.contains(":only-") {
                    positional = true
                }
            }
        }
        guard !usable.isEmpty else { return }
        rules.append(StyleRule(selectors: usable, declarations: declarations, order: rules.count))
        if rules.count > Self.maxRules { tooComplex = true }
    }

    // MARK: Selectors

    private static let structural: Set<String> = [
        "not", "nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type", "first-child", "last-child",
        "first-of-type", "last-of-type", "only-child", "only-of-type", "empty", "root", "has",
    ]
    private static let dynamic = "hover|focus|focus-within|focus-visible|active|visited|target|target-within|checked|invalid|user-invalid|valid|user-valid"

    /// A selector as SwiftSoup can match it on a page at rest, in one or more alternatives, or none when it never
    /// applies then. `:not(:hover)` is always true, `:hover` never; `:link` is every link; `:is()` and `:where()`
    /// become their alternatives; a rule for `::first-line` is read as a rule for the element.
    static func rewrite(_ selector: String) -> [String] {
        var text = selector
        let lowered = text.lowercased()
        for skipped in ["::before", "::after", "::marker", "::placeholder", "::selection", "::backdrop", "::file-selector-button", "::-webkit", "::-moz", ":before", ":after"]
        where lowered.contains(skipped) {
            return []
        }
        for (pattern, replacement) in [
            (#"::?first-(?:line|letter)"#, ""),
            (":not\\(\\s*:(?:\(dynamic))\\s*\\)", ""),
            (#":(?:any-)?link\b"#, "[href]"),
        ] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        var alternatives = [text]
        // :is(a, b) and :where(a, b), expanded into one selector per argument.
        for _ in 0..<8 {
            guard let open = alternatives.first(where: { $0.range(of: #":(?:is|where)\("#, options: .regularExpression) != nil }) else { break }
            alternatives.removeAll { $0 == open }
            guard let start = open.range(of: #":(?:is|where)\("#, options: .regularExpression),
                  let close = matchingParenthesis(in: open, from: start.upperBound) else { return [] }
            let inside = String(open[start.upperBound..<close])
            for argument in CSSColor.splitTopLevel(inside, by: ",") {
                alternatives.append(String(open[..<start.lowerBound]) + argument.trimmingCharacters(in: .whitespaces) + String(open[open.index(after: close)...]))
            }
            if alternatives.count > 32 { return [] }
        }
        return alternatives.filter { candidate in
            let bare = candidate.replacingOccurrences(of: #"\[[^\]]*\]|"[^"]*"|'[^']*'"#, with: "[]", options: .regularExpression)
            if bare.contains("&") || bare.contains("::") { return false }
            return bare.matches(of: #/:([a-zA-Z-]+)/#).allSatisfy { structural.contains($0.1.lowercased()) }
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

    /// Ids, then classes, attributes and pseudo-classes, then element names, as one number to sort by.
    static func specificity(of selector: String) -> Int {
        var text = selector.replacingOccurrences(of: #""[^"]*"|'[^']*'"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #":where\([^)]*\)"#, with: "", options: .regularExpression)
        let attributes = text.matches(of: #/\[[^\]]*\]/#).count
        text = text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        let ids = text.matches(of: #/#[\w-]+/#).count
        let classes = text.matches(of: #/\.[\w-]+/#).count
        let pseudoElements = text.matches(of: #/::[\w-]+/#).count
        text = text.replacingOccurrences(of: #"::[\w-]+"#, with: " ", options: .regularExpression)
        let pseudoClasses = text.matches(of: #/:(?!not\(|is\(|has\()[\w-]+/#).count
        let types = text.matches(of: #/(?:^|[\s>+~(,])([a-zA-Z][\w-]*)/#).count
        return min(ids, 99) * 10_000 + min(classes + attributes + pseudoClasses, 99) * 100 + min(types + pseudoElements, 99)
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

    private static func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).map(String.init)
        if let type = words.first, ["print", "speech", "tty", "braille", "embossed", "handheld", "projection", "tv"].contains(type) {
            return false
        }
        if query.contains("prefers-color-scheme") && query.contains("dark") { return false }
        if query.contains("orientation") && query.contains("portrait") { return false }
        if query.range(of: #"\(\s*(?:any-)?hover\s*:\s*none"#, options: .regularExpression) != nil { return false }
        if query.range(of: #"\(\s*(?:any-)?pointer\s*:\s*(?:coarse|none)"#, options: .regularExpression) != nil { return false }
        var lower = widths.lowerBound
        var upper = widths.upperBound
        func points(_ number: Substring, _ unit: Substring?) -> Double? {
            guard let value = Double(number) else { return nil }
            return unit == "em" || unit == "rem" ? value * 16 : value
        }
        for match in query.matches(of: #/(min|max)-(?:device-)?width\s*:\s*([0-9.]+)\s*(px|em|rem)?/#) {
            guard let value = points(match.2, match.3) else { continue }
            if match.1 == "min" { lower = max(lower, value) } else { upper = min(upper, value) }
        }
        for match in query.matches(of: #/(?:device-)?width\s*(>=|<=|>|<)\s*([0-9.]+)\s*(px|em|rem)?/#) {
            guard let value = points(match.2, match.3) else { continue }
            switch match.1 {
            case ">=": lower = max(lower, value)
            case ">": lower = max(lower, value + 0.01)
            case "<=": upper = min(upper, value)
            default: upper = min(upper, value - 0.01)
            }
        }
        for match in query.matches(of: #/([0-9.]+)\s*(px|em|rem)?\s*(<=|<|>=|>)\s*(?:device-)?width/#) {
            guard let value = points(match.1, match.2) else { continue }
            switch match.3 {
            case "<=": lower = max(lower, value)
            case "<": lower = max(lower, value + 0.01)
            case ">=": upper = min(upper, value)
            default: upper = min(upper, value - 0.01)
            }
        }
        return lower <= upper
    }

    // MARK: Matching

    /// What each element gets from the rules, worked out once on the page as it came, before anything is hidden.
    struct Matches {
        fileprivate(set) var byElement: [ObjectIdentifier: [(specificity: Int, order: Int, declarations: [CSSDeclaration])]] = [:]
        /// Holds the matched elements so their identifiers stay theirs.
        fileprivate var elements: [Element] = []
    }

    func match(in document: Document) -> Matches {
        var matches = Matches()
        for rule in rules {
            for (selector, specificity) in rule.selectors {
                guard let found = try? document.select(selector) else { continue }
                for element in found.array() {
                    let key = ObjectIdentifier(element)
                    if matches.byElement[key] == nil { matches.elements.append(element) }
                    matches.byElement[key, default: []].append((specificity, rule.order, rule.declarations))
                }
            }
        }
        return matches
    }
}
