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
}

/// Where approved batches are kept between launches.
public protocol BatchStore: Sendable {
    func save(_ record: BatchRecord)
    func delete(_ id: String)
    func load() -> [BatchRecord]
}

/// Each batch in its own file, sealed with ChaCha20-Poly1305 under a key that only Postern can read from the
/// Keychain: no other program can read who the emails go to, nor change what a resumed batch would send.
public final class SealedBatchStore: BatchStore, @unchecked Sendable {
    private let folder: URL
    private let key: @Sendable () -> SymmetricKey?
    private let lock = NSLock()

    /// - Parameter key: the sealing key, nil while the Keychain cannot be read (nothing is written then).
    public init(folder: URL, key: @escaping @Sendable () -> SymmetricKey?) {
        self.folder = folder
        self.key = key
    }

    public func save(_ record: BatchRecord) {
        guard let key = key(), let plain = try? JSONEncoder().encode(record),
              let sealed = try? ChaChaPoly.seal(plain, using: key, authenticating: Data(record.id.utf8)).combined else { return }
        lock.withLock {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try? sealed.write(to: file(record.id), options: .atomic)
        }
    }

    public func delete(_ id: String) {
        lock.withLock { try? FileManager.default.removeItem(at: file(id)) }
    }

    /// Every batch that opens with the key and names itself; a file that does not is left out and removed.
    public func load() -> [BatchRecord] {
        guard let key = key() else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return names.filter { $0.pathExtension == "batch" }.compactMap { url in
            let id = url.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: url), let box = try? ChaChaPoly.SealedBox(combined: data),
                  let plain = try? ChaChaPoly.open(box, using: key, authenticating: Data(id.utf8)),
                  let record = try? JSONDecoder().decode(BatchRecord.self, from: plain), record.id == id else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return record
        }
    }

    private func file(_ id: String) -> URL {
        folder.appendingPathComponent(id.filter { $0.isLetter || $0.isNumber } + ".batch")
    }
}

/// A store for tests, and for when nothing should outlive the app.
public final class MemoryBatchStore: BatchStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: BatchRecord] = [:]

    public init() {}

    public func save(_ record: BatchRecord) { lock.withLock { records[record.id] = record } }
    public func delete(_ id: String) { lock.withLock { _ = records.removeValue(forKey: id) } }
    public func load() -> [BatchRecord] { lock.withLock { Array(records.values) } }
}
