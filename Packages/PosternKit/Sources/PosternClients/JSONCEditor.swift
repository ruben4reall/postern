import Foundation

/// Puts one entry into a JSON or JSONC settings file by editing its text in place: the user's comments, the order
/// of their keys, their numbers and their indentation stay exactly as they were. Every other byte of the file is
/// left alone.
enum JSONCEditor {
    /// The file with `entry` (already JSON text, on one or several lines) set under `servers` › `name`, replacing
    /// whatever was under `name` or under any of `oldNames`. Nil when the text is not an object this editor can
    /// walk; the caller then writes the file another way.
    static func setting(_ text: String, servers: String, name: String, oldNames: [String], entry: String) -> String? {
        let scanner = Scanner(Array(text.utf8))
        guard let root = scanner.object(at: scanner.skipTrivia(from: 0)) else { return nil }
        // The last one wins, as in a parser.
        guard let serversMember = root.members.last(where: { $0.key == servers }) else {
            let indent = root.memberIndent ?? scanner.indent(before: root.close) + "  "
            let block = "\(quoted(servers)): {\n\(indent)  \(quoted(name)): \(reindent(entry, by: indent + "  "))\n\(indent)}"
            return scanner.inserting(block, into: root, indent: indent)
        }
        guard let inner = scanner.object(at: serversMember.valueStart) else { return nil }
        let indent = inner.memberIndent ?? scanner.indent(before: inner.close) + "  "
        let value = reindent(entry, by: indent)
        let mine = inner.members.filter { $0.key == name || oldNames.contains($0.key) }
        guard let first = mine.first else {
            return scanner.inserting("\(quoted(name)): \(value)", into: inner, indent: indent)
        }
        // One entry, under the new name: the first is replaced, any other copy is removed.
        var bytes = scanner.bytes
        for member in mine.dropFirst().reversed() {
            bytes.replaceSubrange(scanner.removalRange(of: member, in: inner), with: [])
        }
        bytes.replaceSubrange(first.keyStart..<first.valueEnd, with: Array("\(quoted(name)): \(value)".utf8))
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func quoted(_ key: String) -> String {
        "\"" + key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Indents every line of `json` after the first by `indent`.
    private static func reindent(_ json: String, by indent: String) -> String {
        json.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .map { $0.offset == 0 ? String($0.element) : indent + $0.element }.joined(separator: "\n")
    }

    struct Member {
        let key: String
        let keyStart: Int
        let valueStart: Int
        let valueEnd: Int
        /// Just after the member and its comma, if it has one.
        let end: Int
        let hasComma: Bool
    }

    struct Object {
        let open: Int
        let close: Int
        let members: [Member]
        /// The whitespace before the first member's key, when it starts a line.
        let memberIndent: String?
    }

    struct Scanner {
        var bytes: [UInt8]
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        /// The index of the next byte that is not whitespace or a comment.
        func skipTrivia(from start: Int) -> Int {
            var at = start
            while at < bytes.count {
                let byte = bytes[at]
                if byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 0xEF || byte == 0xBB || byte == 0xBF {
                    at += 1
                } else if byte == 47, at + 1 < bytes.count, bytes[at + 1] == 47 {
                    while at < bytes.count, bytes[at] != 10 { at += 1 }
                } else if byte == 47, at + 1 < bytes.count, bytes[at + 1] == 42 {
                    at += 2
                    while at + 1 < bytes.count, !(bytes[at] == 42 && bytes[at + 1] == 47) { at += 1 }
                    at = min(at + 2, bytes.count)
                } else {
                    return at
                }
            }
            return at
        }

        /// The end of a string starting at `start` (a quote), just after its closing quote.
        func endOfString(_ start: Int) -> Int? {
            let quote = bytes[start]
            var at = start + 1
            while at < bytes.count {
                if bytes[at] == 92 { at += 2; continue }
                if bytes[at] == quote { return at + 1 }
                at += 1
            }
            return nil
        }

        /// The end of the value starting at `start`, just after it.
        func endOfValue(_ start: Int) -> Int? {
            guard start < bytes.count else { return nil }
            switch bytes[start] {
            case 34, 39: return endOfString(start)
            case 123, 91:
                var depth = 0
                var at = start
                while at < bytes.count {
                    let next = skipTrivia(from: at)
                    guard next < bytes.count else { return nil }
                    at = next
                    switch bytes[at] {
                    case 34, 39:
                        guard let end = endOfString(at) else { return nil }
                        at = end
                        continue
                    case 123, 91: depth += 1
                    case 125, 93:
                        depth -= 1
                        if depth == 0 { return at + 1 }
                    default: break
                    }
                    at += 1
                }
                return nil
            default:
                var at = start
                while at < bytes.count, ![44, 125, 93, 32, 9, 10, 13, 47].contains(bytes[at]) { at += 1 }
                return at
            }
        }

        func object(at start: Int) -> Object? {
            guard start < bytes.count, bytes[start] == 123 else { return nil }
            var members: [Member] = []
            var at = skipTrivia(from: start + 1)
            var indent: String?
            while at < bytes.count, bytes[at] != 125 {
                guard bytes[at] == 34 || bytes[at] == 39, let keyEnd = endOfString(at) else { return nil }
                if members.isEmpty { indent = lineIndent(before: at) }
                let key = (try? JSONSerialization.jsonObject(with: Data(([34] + bytes[(at + 1)..<(keyEnd - 1)] + [34])), options: .fragmentsAllowed)) as? String
                    ?? String(decoding: bytes[(at + 1)..<(keyEnd - 1)], as: UTF8.self)
                let colon = skipTrivia(from: keyEnd)
                guard colon < bytes.count, bytes[colon] == 58 else { return nil }
                let valueStart = skipTrivia(from: colon + 1)
                guard let valueEnd = endOfValue(valueStart) else { return nil }
                var next = skipTrivia(from: valueEnd)
                let comma = next < bytes.count && bytes[next] == 44
                if comma { next = skipTrivia(from: next + 1) }
                members.append(Member(key: key, keyStart: at, valueStart: valueStart, valueEnd: valueEnd,
                                      end: comma ? afterComma(from: valueEnd) : valueEnd, hasComma: comma))
                if !comma, next < bytes.count, bytes[next] != 125 { return nil }
                at = next
            }
            guard at < bytes.count else { return nil }
            return Object(open: start, close: at, members: members, memberIndent: indent)
        }

        private func afterComma(from start: Int) -> Int {
            var at = start
            while at < bytes.count, bytes[at] != 44 { at += 1 }
            return at + 1
        }

        /// The spaces and tabs between the start of the line and `index`, if only they are there.
        func lineIndent(before index: Int) -> String? {
            var at = index
            while at > 0, bytes[at - 1] == 32 || bytes[at - 1] == 9 { at -= 1 }
            guard at == 0 || bytes[at - 1] == 10 else { return nil }
            return String(decoding: bytes[at..<index], as: UTF8.self)
        }

        /// The indentation of the line `index` is on.
        func indent(before index: Int) -> String {
            var start = index
            while start > 0, bytes[start - 1] != 10 { start -= 1 }
            var end = start
            while end < bytes.count, bytes[end] == 32 || bytes[end] == 9 { end += 1 }
            return String(decoding: bytes[start..<end], as: UTF8.self)
        }

        /// The text with `member` (a `"key": value`) added as the object's last member.
        func inserting(_ member: String, into object: Object, indent: String) -> String {
            var bytes = self.bytes
            if let last = object.members.last {
                // After the last value, past a trailing comma if there is one: comments stay where they are.
                let at = last.hasComma ? last.end : last.valueEnd
                let text = (last.hasComma ? "" : ",") + "\n" + indent + member
                bytes.insert(contentsOf: Array(text.utf8), at: at)
            } else {
                let closing = "\n" + self.indent(before: object.close)
                let inside = String(decoding: bytes[(object.open + 1)..<object.close], as: UTF8.self)
                let text = (inside.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : inside) + "\n" + indent + member + closing
                bytes.replaceSubrange((object.open + 1)..<object.close, with: Array(text.utf8))
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        /// What to cut to take `member` out, with its comma, or the comma before it when it is the last.
        func removalRange(of member: Member, in object: Object) -> Range<Int> {
            var start = member.keyStart
            while start > 0, bytes[start - 1] == 32 || bytes[start - 1] == 9 { start -= 1 }
            if start > 0, bytes[start - 1] == 10 { start -= 1 }
            if member.hasComma { return start..<member.end }
            if let previous = object.members.last(where: { $0.keyStart < member.keyStart }), previous.hasComma {
                return (previous.end - 1)..<member.valueEnd
            }
            return start..<member.valueEnd
        }
    }
}
