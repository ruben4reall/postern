import CryptoKit
import Foundation

/// One tool call, as the user sees it in the activity view. Metadata only: never a subject, an address or content.
public struct ActivityRecord: Codable, Sendable, Equatable {
    public let date: Date
    public let client: String
    public let tool: String
    /// `ok` or the error code returned to the client.
    public let outcome: String
    public let items: Int?
    /// SHA-256 of the previous line, which chains the log.
    public let previous: String

    public init(date: Date, client: String, tool: String, outcome: String, items: Int?, previous: String) {
        self.date = date
        self.client = client
        self.tool = tool
        self.outcome = outcome
        self.items = items
        self.previous = previous
    }
}

public enum Integrity: Equatable, Sendable {
    case intact(count: Int)
    /// The line, counted from 1, whose `previous` no longer matches the line before it.
    case broken(line: Int)
    /// The last line is not the one Postern wrote last: lines were removed from the end, or the file replaced.
    case headMismatch
}

/// Where the hash of the last line is kept. The app keeps it in the Keychain, out of the file's reach.
public protocol HeadStore: Sendable {
    func load() -> String?
    func save(_ hash: String)
}

/// An append-only log in which each line carries the hash of the one before, and the hash of the last line lives
/// elsewhere. Editing, removing or reordering lines is detected; nothing in a line is secret.
public final class ActivityLog: @unchecked Sendable {
    private let fileURL: URL
    private let head: any HeadStore
    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static let genesis = String(repeating: "0", count: 64)

    public init(fileURL: URL, head: any HeadStore) {
        self.fileURL = fileURL
        self.head = head
    }

    public func append(client: String, tool: String, outcome: String, items: Int?) throws {
        try lock.withLock {
            let previous = head.load() ?? Self.genesis
            let record = ActivityRecord(
                date: Date(), client: String(client.prefix(64)), tool: tool, outcome: outcome, items: items,
                previous: previous
            )
            var line = try encoder.encode(record)
            line.append(0x0A)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            head.save(Self.hash(line.dropLast()))
        }
    }

    /// Newest first.
    public func records(limit: Int) throws -> [ActivityRecord] {
        try lock.withLock {
            try lines().suffix(limit).reversed().compactMap { try? decoder.decode(ActivityRecord.self, from: $0) }
        }
    }

    public func verify() throws -> Integrity {
        try lock.withLock {
            let lines = try lines()
            for index in lines.indices.dropFirst() {
                guard let record = try? decoder.decode(ActivityRecord.self, from: lines[index]),
                      record.previous == Self.hash(lines[index - 1]) else {
                    return .broken(line: index + 1)
                }
            }
            let expected = head.load()
            guard let last = lines.last else {
                return expected == nil || expected == Self.genesis ? .intact(count: 0) : .headMismatch
            }
            return Self.hash(last) == expected ? .intact(count: lines.count) : .headMismatch
        }
    }

    /// Drops records older than `date`. The first kept line keeps its link to a removed line; the chain is checked
    /// from there on.
    public func prune(olderThan date: Date) throws {
        try lock.withLock {
            let kept = try lines().filter { line in
                guard let record = try? decoder.decode(ActivityRecord.self, from: line) else { return true }
                return record.date >= date
            }
            var data = Data()
            for line in kept { data.append(line); data.append(0x0A) }
            try data.write(to: fileURL, options: .atomic)
            if kept.isEmpty { head.save(Self.genesis) }
        }
    }

    private func lines() throws -> [Data] {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else { return [] }
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
    }

    static func hash(_ data: some DataProtocol) -> String {
        SHA256.hash(data: Data(data)).map { String(format: "%02x", $0) }.joined()
    }
}
