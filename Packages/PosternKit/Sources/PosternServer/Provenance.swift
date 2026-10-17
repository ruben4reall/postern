import Foundation
import PosternModel

/// Addresses a client has seen inside mail during its session. An address that only ever appeared in someone
/// else's email, and that the user never wrote to, is how a planted instruction would pick its recipient.
public final class Provenance: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: Set<String> = []

    public init() {}

    public func record(_ addresses: [Address]) {
        lock.withLock { for address in addresses { seen.insert(address.email.lowercased()) } }
    }

    /// Picks addresses written in free text, such as a body asking to "send it to x@y".
    public func record(text: String) {
        let found = text.matches(of: #/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/#).map { String($0.0).lowercased() }
        lock.withLock { seen.formUnion(found) }
    }

    public func cameFromEmail(_ email: String) -> Bool {
        lock.withLock { seen.contains(email.lowercased()) }
    }
}
