import CryptoKit
import Foundation
import PosternModel

/// An approved send batch as it is kept on disk, so a batch of thousands of emails that takes days survives a
/// restart of the Mac or of Postern. It holds what the queue needs to go on, and never the emails: each one is
/// composed again from its draft when its turn comes, and leaves only if it is still the one the user approved.
public struct BatchRecord: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        let index: Int
        let recipients: String
        let subject: String
        let status: String
        let detail: String
        let draft: String?
    }

    public struct Queued: Codable, Sendable, Equatable {
        let index: Int
        let draft: String
        let digest: String
        let messageID: String
        let recipients: [String]
        let sender: String
    }

    public let id: String
    public let client: String
    public let created: Date
    let start: Date?
    let spacing: TimeInterval
    let estimate: Date?
    let items: [Item]
    let queue: [Queued]
    let noAttachment: Bool

    /// How many emails are still to leave.
    public var left: Int { items.filter { $0.status == BatchBoard.ItemStatus.waiting.rawValue }.count }

    /// The same batch with the statuses written since, one per item in order.
    func with(statuses: [String]) -> BatchRecord {
        guard statuses.count == items.count else { return self }
        let updated = zip(items, statuses).map { item, status in
            Item(index: item.index, recipients: item.recipients, subject: item.subject, status: status,
                 detail: status == item.status ? item.detail : "", draft: item.draft)
        }
        return BatchRecord(id: id, client: client, created: created, start: start, spacing: spacing, estimate: estimate,
                           items: updated, queue: queue, noAttachment: noAttachment)
    }
}

/// Where approved batches are kept between launches.
public protocol BatchStore: Sendable {
    /// False when the record could not be written.
    @discardableResult func save(_ record: BatchRecord) -> Bool
    /// The status of every item, in the record's order: a few kilobytes, written as each email goes.
    @discardableResult func saveStatuses(_ id: String, _ statuses: [String]) -> Bool
    func delete(_ id: String)
    func load() -> [BatchRecord]
}

/// The digest of the latest sealed file of each batch, kept where only Postern can write: a copy of an older file
/// put back, or a file of a batch that ended, does not match and is refused.
public protocol BatchIndex: Sendable {
    /// Nil while it cannot be read.
    func read() -> [String: String]?
    @discardableResult func write(_ index: [String: String]) -> Bool
}

/// Each batch in its own file, sealed with ChaCha20-Poly1305 under a key that only Postern can read from the
/// Keychain: no other program can read who the emails go to, nor change what a resumed batch would send.
public final class SealedBatchStore: BatchStore, @unchecked Sendable {
    private let folder: URL
    private let key: @Sendable () -> SymmetricKey?
    private let index: any BatchIndex
    private let lock = NSLock()
    /// The digests written in this run, so a moment when the index cannot be written loses nothing still running.
    private var known: [String: (batch: String, state: String)] = [:]

    /// - Parameters:
    ///   - key: the sealing key, nil while the Keychain cannot be read (nothing is written then).
    ///   - index: the digest of each batch's latest file. While it cannot be written (a locked Mac), files are
    ///     still saved, and a restart then finds them out of date and drops them: no email leaves twice, and the
    ///     drafts left wait in Drafts.
    public init(folder: URL, key: @escaping @Sendable () -> SymmetricKey?, index: any BatchIndex) {
        self.folder = folder
        self.key = key
        self.index = index
    }

    /// Writes the whole batch once, then only its statuses as it goes: thousands of emails do not mean thousands of
    /// full rewrites.
    @discardableResult
    public func save(_ record: BatchRecord) -> Bool {
        guard let key = key(), let plain = try? JSONEncoder().encode(record),
              let sealed = try? ChaChaPoly.seal(plain, using: key, authenticating: Data(record.id.utf8)).combined else { return false }
        return lock.withLock {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            guard (try? sealed.write(to: file(record.id, "batch"), options: .atomic)) != nil else { return false }
            known[record.id] = (Self.digest(sealed), known[record.id]?.state ?? "")
            return writeStatesLocked(record.id, record.items.map(\.status), key: key)
        }
    }

    @discardableResult
    public func saveStatuses(_ id: String, _ statuses: [String]) -> Bool {
        guard let key = key() else { return false }
        return lock.withLock {
            guard known[id] != nil else { return false }
            return writeStatesLocked(id, statuses, key: key)
        }
    }

    private func writeStatesLocked(_ id: String, _ statuses: [String], key: SymmetricKey) -> Bool {
        guard let plain = try? JSONEncoder().encode(statuses),
              let sealed = try? ChaChaPoly.seal(plain, using: key, authenticating: Data((id + ":state").utf8)).combined,
              (try? sealed.write(to: file(id, "state"), options: .atomic)) != nil, let batch = known[id]?.batch else { return false }
        known[id] = (batch, Self.digest(sealed))
        var stored = index.read() ?? [:]
        for (name, digests) in known { stored[name] = digests.batch + ":" + digests.state }
        index.write(stored)
        return true
    }

    public func delete(_ id: String) {
        lock.withLock {
            try? FileManager.default.removeItem(at: file(id, "batch"))
            try? FileManager.default.removeItem(at: file(id, "state"))
            known[id] = nil
            if var stored = index.read() {
                stored[id] = nil
                index.write(stored)
            }
        }
    }

    /// Every batch whose files open with the key, name themselves, and are the latest ones written. Files that do
    /// not are removed. Nothing is loaded while the index cannot be read: the app asks again once it can.
    public func load() -> [BatchRecord] {
        guard let key = key(), let stored = index.read() else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let ids = Set(names.filter { ["batch", "state"].contains($0.pathExtension) }.map { $0.deletingPathExtension().lastPathComponent })
        let records = ids.compactMap { id -> BatchRecord? in
            let batchURL = file(id, "batch"), stateURL = file(id, "state")
            guard let data = try? Data(contentsOf: batchURL), let state = try? Data(contentsOf: stateURL),
                  stored[id] == Self.digest(data) + ":" + Self.digest(state),
                  let plain = try? ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: key, authenticating: Data(id.utf8)),
                  let record = try? JSONDecoder().decode(BatchRecord.self, from: plain), record.id == id,
                  let statePlain = try? ChaChaPoly.open(ChaChaPoly.SealedBox(combined: state), using: key, authenticating: Data((id + ":state").utf8)),
                  let statuses = try? JSONDecoder().decode([String].self, from: statePlain) else {
                try? FileManager.default.removeItem(at: batchURL)
                try? FileManager.default.removeItem(at: stateURL)
                return nil
            }
            return record.with(statuses: statuses)
        }
        let live = Set(records.map(\.id))
        if stored.keys.contains(where: { !live.contains($0) }) { index.write(stored.filter { live.contains($0.key) }) }
        return records
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func file(_ id: String, _ kind: String) -> URL {
        folder.appendingPathComponent(id.filter { $0.isLetter || $0.isNumber } + "." + kind)
    }
}

/// A store for tests, and for when nothing should outlive the app.
public final class MemoryBatchStore: BatchStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: BatchRecord] = [:]

    public init() {}

    @discardableResult
    public func save(_ record: BatchRecord) -> Bool { lock.withLock { records[record.id] = record }; return true }

    @discardableResult
    public func saveStatuses(_ id: String, _ statuses: [String]) -> Bool {
        lock.withLock {
            guard let record = records[id] else { return false }
            records[id] = record.with(statuses: statuses)
            return true
        }
    }
    public func delete(_ id: String) { lock.withLock { _ = records.removeValue(forKey: id) } }
    public func load() -> [BatchRecord] { lock.withLock { Array(records.values) } }
}

/// An index in memory, for tests.
public final class MemoryBatchIndex: BatchIndex, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String]? = [:]
    public var readable = true
    public var writable = true

    public init() {}

    public func read() -> [String: String]? { lock.withLock { readable ? stored : nil } }

    @discardableResult
    public func write(_ index: [String: String]) -> Bool {
        lock.withLock {
            guard writable else { return false }
            stored = index
            return true
        }
    }
}
