import Foundation
import PosternModel

/// The rows of a mail merge: a CSV (comma, semicolon or tab, as spreadsheets export it) or a JSON list of objects.
/// Each row maps a column name to its text.
enum DataTable {
    static let maxBytes = 5_000_000

    static func rows(from data: Data, named name: String, limit: Int) throws -> [[String: String]] {
        guard data.count <= maxBytes else {
            throw PosternError(.tooLarge, "\(name) is larger than 5 MB.")
        }
        let rows: [[String: String]]
        if name.lowercased().hasSuffix(".json") {
            rows = try json(data, name: name)
        } else {
            rows = try csv(text(data), name: name)
        }
        guard !rows.isEmpty else { throw PosternError(.invalidArgument, "\(name) has no rows.") }
        guard rows.count <= limit else {
            throw PosternError(.invalidArgument, "\(name) has \(rows.count) rows; at most \(limit) at a time.")
        }
        return rows
    }

    /// UTF-8 or UTF-16 with its mark, else the Windows encoding older spreadsheets use.
    static func text(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16) ?? ""
        }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        if let text = String(data: bytes, encoding: .utf8) { return text }
        return String(data: bytes, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
    }

    static func json(_ data: Data, name: String) throws -> [[String: String]] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw PosternError(.invalidArgument, "\(name) is not a JSON list of objects.")
        }
        return list.map { object in
            object.compactMapValues { value -> String? in
                switch value {
                case let text as String: text
                case let number as NSNumber: number.stringValue
                case let items as [Any]: items.map { "\($0)" }.joined(separator: "; ")
                default: nil
                }
            }
        }.filter { !$0.values.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    }

    /// RFC 4180 with the delimiter guessed from the header line. Quoted cells may hold delimiters, quotes ("")
    /// and line breaks. Empty lines are skipped.
    static func csv(_ text: String, name: String) throws -> [[String: String]] {
        let records = parse(text, delimiter: delimiter(of: text))
        guard let header = records.first else { throw PosternError(.invalidArgument, "\(name) is empty.") }
        let columns = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard columns.contains(where: { !$0.isEmpty }) else { throw PosternError(.invalidArgument, "\(name) has no header line.") }
        var seen: Set<String> = []
        for column in columns where !column.isEmpty {
            guard seen.insert(column.lowercased()).inserted else {
                throw PosternError(.invalidArgument, "\(name) has two columns named \(column).")
            }
        }
        return records.dropFirst().compactMap { record in
            guard record.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
            var row: [String: String] = [:]
            for (index, column) in columns.enumerated() where !column.isEmpty && index < record.count {
                row[column] = record[index]
            }
            return row
        }
    }

    static func delimiter(of text: String) -> Character {
        var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0]
        var quoted = false
        for character in text {
            if character == "\"" { quoted.toggle() }
            if !quoted && (character == "\n" || character == "\r\n" || character == "\r") { break }
            if !quoted, counts[character] != nil { counts[character, default: 0] += 1 }
        }
        if counts["\t", default: 0] > 0 && counts["\t", default: 0] >= counts[",", default: 0] { return "\t" }
        return counts[";", default: 0] > counts[",", default: 0] ? ";" : ","
    }

    static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var cell = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending: Character?
        while let character = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { cell.append("\"") } else { quoted = false; pending = next }
                    } else {
                        quoted = false
                    }
                } else {
                    cell.append(character)
                }
                continue
            }
            switch character {
            case "\"" where cell.isEmpty:
                quoted = true
            case delimiter:
                record.append(cell)
                cell = ""
            case "\n", "\r\n", "\r":
                record.append(cell)
                records.append(record)
                record = []
                cell = ""
            default:
                cell.append(character)
            }
        }
        if !cell.isEmpty || !record.isEmpty {
            record.append(cell)
            records.append(record)
        }
        return records
    }

    /// A cell that lists several things: addresses separated by commas, semicolons or line breaks; file names by
    /// semicolons, vertical bars or line breaks.
    static func split(_ cell: String, separators: Set<Character>) -> [String] {
        cell.split(whereSeparator: { separators.contains($0) || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
