import Foundation
import SwiftSoup
import Testing
@testable import PosternMail

/// The one-pass matcher against SwiftSoup's own, on random pages and selectors small enough for SwiftSoup to
/// match quickly: any element one finds and the other does not is a rule that hides, or shows, the wrong text.
@Suite struct SelectorMatchingTests {
    static let tags = ["div", "p", "span", "b", "a", "td"]
    static let classes = ["x", "y", "z"]

    static func page(_ random: inout SeededGenerator) -> String {
        func element(_ depth: Int) -> String {
            let tag = ["div", "p", "span", "b", "a", "section"].randomElement(using: &random)!
            let names = classes.filter { _ in Int.random(in: 0..<3, using: &random) == 0 }
            let attribute = names.isEmpty ? "" : " class=\"\(names.joined(separator: " "))\""
            var inner = ""
            for _ in 0..<Int.random(in: 0...3, using: &random) where depth < 6 { inner += element(depth + 1) }
            return "<\(tag)\(attribute)>t\(inner)</\(tag)>"
        }
        return "<div>" + (0..<Int.random(in: 1...4, using: &random)).map { _ in element(0) }.joined() + "</div>"
    }

    static func selector(_ random: inout SeededGenerator) -> String {
        func compound() -> String {
            var text = Int.random(in: 0..<3, using: &random) == 0 ? "*" : ["div", "p", "span", "b", "a", "section"].randomElement(using: &random)!
            if Bool.random(using: &random) { text += "." + classes.randomElement(using: &random)! }
            switch Int.random(in: 0..<6, using: &random) {
            case 0: text += ":first-child"
            case 1: text += ":not(.\(classes.randomElement(using: &random)!))"
            case 2: text += ":last-child"
            default: break
            }
            return text
        }
        var text = compound()
        for _ in 0..<Int.random(in: 0...3, using: &random) {
            text += [" ", " > ", " + ", " ~ "].randomElement(using: &random)! + compound()
        }
        return text
    }

    @Test func findsWhatSwiftSoupFinds() throws {
        var random = SeededGenerator(seed: 1_110)
        var compared = 0
        for round in 0..<1_500 {
            let html = Self.page(&random)
            let selector = Self.selector(&random)
            let document = try SwiftSoup.parse(html)
            let sheet = StyleSheet(["\(selector){color:red}"])
            let found = try #require(sheet.match(in: document), "round \(round)")
            let mine = Set(found.byElement.keys)
            // SwiftSoup counts the document node as an element, and as the parent of <html>; a browser does neither.
            let expected = Set(try document.select(selector).array().filter {
                !($0 is Document) && !($0.tagName() == "html" && !mine.contains(ObjectIdentifier($0)) && selector.contains(where: { " >+~".contains($0) }))
            }.map { ObjectIdentifier($0) })
            #expect(mine == expected, "round \(round): \(selector) on \(html)")
            compared += 1
        }
        #expect(compared == 1_500)
    }
}
