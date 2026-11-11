#if canImport(CryptoKit)
import CryptoKit
#else
// Apple's own implementation of the same API, for Linux and Windows.
import Crypto
#endif
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
    private let fullCheckInterval: TimeInterval
    /// The hash of the last line, as last written; read from the store once.
    private var lastHead: String?
    /// What the last check proved: the first `size` bytes chain correctly, hold `count` lines and end with a line
    /// hashed `lastHash`. Later checks read only what was appended since, except one full pass every
    /// `fullCheckInterval`, which catches an edit to an earlier line.
    private var checked: (size: UInt64, count: Int, lastHash: String?, fullPassAt: Date)?
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

    public init(fileURL: URL, head: any HeadStore, fullCheckInterval: TimeInterval = 300) {
        self.fileURL = fileURL
        self.head = head
        self.fullCheckInterval = fullCheckInterval
    }

    public func append(client: String, tool: String, outcome: String, items: Int?) throws {
        try lock.withLock {
            let previous = lastHead ?? head.load() ?? Self.genesis
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
            let hash = Self.hash(line.dropLast())
            head.save(hash)
            lastHead = hash
        }
    }

    /// Newest first. Reads only the end of the file.
    public func records(limit: Int) throws -> [ActivityRecord] {
        try lock.withLock {
            try lastLines(limit).reversed().compactMap { try? decoder.decode(ActivityRecord.self, from: $0) }
        }
    }

    public func verify() throws -> Integrity {
        try lock.withLock {
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
            var start: UInt64 = 0
            var count = 0
            var last: String?
            var fullPassAt = Date()
            if let checked, size >= checked.size, Date().timeIntervalSince(checked.fullPassAt) < fullCheckInterval {
                (start, count, last, fullPassAt) = (checked.size, checked.count, checked.lastHash, checked.fullPassAt)
            }
            self.checked = nil
            for line in try lines(from: start) {
                count += 1
                if let last {
                    guard let record = try? decoder.decode(ActivityRecord.self, from: line), record.previous == last else {
                        return .broken(line: count)
                    }
                }
                last = Self.hash(line)
            }
            let expected = head.load()
            guard let last else {
                return expected == nil || expected == Self.genesis ? .intact(count: 0) : .headMismatch
            }
            guard last == expected else { return .headMismatch }
            self.checked = (size, count, last, fullPassAt)
            return .intact(count: count)
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
            checked = nil
            if kept.isEmpty {
                head.save(Self.genesis)
                lastHead = Self.genesis
            }
        }
    }

    private func lines(from offset: UInt64 = 0) throws -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
    }

    /// The last `count` lines, read from the end in growing chunks.
    private func lastLines(_ count: Int) throws -> [Data] {
        guard count > 0, let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        var chunk: UInt64 = 64 * 1024
        while true {
            let start = size > chunk ? size - chunk : 0
            try handle.seek(toOffset: start)
            var lines = (try handle.readToEnd() ?? Data()).split(separator: 0x0A, omittingEmptySubsequences: true)
            // A chunk that starts inside the file may start inside a line.
            if start > 0 { lines.removeFirst() }
            if lines.count >= count || start == 0 { return lines.suffix(count).map { Data($0) } }
            chunk *= 4
        }
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    static func hash(_ data: some DataProtocol) -> String {
        var hex: [UInt8] = []
        hex.reserveCapacity(64)
        for byte in SHA256.hash(data: Data(data)) {
            hex.append(hexDigits[Int(byte >> 4)])
            hex.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: hex, as: UTF8.self)
    }
}
