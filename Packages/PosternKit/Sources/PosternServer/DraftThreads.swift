import Foundation

/// The conversation a reply saved as a draft belongs to. Proton keeps a draft's Message-ID but drops In-Reply-To
/// and References when Bridge stores it, so a reply sent later from Drafts would start a new conversation in the
/// recipient's mailbox. Postern remembers them by the draft's Message-ID and puts them back when the draft leaves.
public struct ThreadReference: Codable, Sendable, Equatable {
    public let inReplyTo: String
    public let references: [String]

    public init(inReplyTo: String, references: [String]) {
        self.inReplyTo = inReplyTo
        self.references = Array(references.suffix(20))
    }
}

/// The remembered conversations of reply drafts, by the draft's Message-ID. The core keeps them in its secret store;
/// without one (tests) they live in memory.
public final class DraftThreads: @unchecked Sendable {
    public static let shared = DraftThreads()
    static let capacity = 500

    private let lock = NSLock()
    private var entries: [String: ThreadReference] = [:]
    private var order: [String] = []
    private var loaded = false
    private var load: (@Sendable () -> [String: ThreadReference]?)?
    private var save: (@Sendable ([String: ThreadReference]) -> Void)?

    public init() {}

    /// Where the core keeps them. Call once at start-up, before any session opens.
    public func persist(load: @escaping @Sendable () -> [String: ThreadReference]?,
                        save: @escaping @Sendable ([String: ThreadReference]) -> Void) {
        lock.withLock {
            self.load = load
            self.save = save
            loaded = false
        }
    }

    public func remember(_ messageID: String, _ reference: ThreadReference) {
        lock.withLock {
            loadIfNeeded()
            if entries[messageID] == nil { order.append(messageID) }
            entries[messageID] = reference
            while order.count > Self.capacity { entries.removeValue(forKey: order.removeFirst()) }
            save?(entries)
        }
    }

    public func reference(for messageID: String) -> ThreadReference? {
        lock.withLock {
            loadIfNeeded()
            return entries[messageID]
        }
    }

    /// Forgets a draft once it has left or was deleted.
    public func forget(_ messageID: String) {
        lock.withLock {
            loadIfNeeded()
            guard entries.removeValue(forKey: messageID) != nil else { return }
            order.removeAll { $0 == messageID }
            save?(entries)
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let stored = load?() else { return }
        entries = stored
        order = Array(stored.keys).sorted()
    }
}
