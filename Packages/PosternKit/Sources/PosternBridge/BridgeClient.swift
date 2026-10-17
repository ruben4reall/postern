import Foundation
import NIOCore
import NIOIMAP
import PosternModel

/// Keeps at most one IMAP session open, reopens it after a failure, and closes it after five idle minutes.
/// Postern only talks to Bridge when a client asks: no polling, no IDLE.
public actor BridgeClient {
    private let endpoint: BridgeEndpoint
    private let pin: CertificatePin
    private let credentials: BridgeCredentials
    private var connection: IMAPConnection?
    private var lastUse = Date()
    private var idleTask: Task<Void, Never>?
    public static let idleTimeout: Duration = .seconds(300)

    public init(endpoint: BridgeEndpoint, pin: CertificatePin, credentials: BridgeCredentials) {
        self.endpoint = endpoint
        self.pin = pin
        self.credentials = credentials
    }

    public func withConnection<T: Sendable>(_ body: (IMAPConnection) async throws -> T) async throws -> T {
        lastUse = Date()
        defer { scheduleIdleClose() }
        do {
            return try await body(try await openConnection())
        } catch let error as BridgeError where error == .unreachable || error == .timeout {
            // One retry on a fresh session: Bridge restarts and sleeping Macs drop loopback sessions.
            await drop()
            return try await body(try await openConnection())
        }
    }

    public func shutdown() async {
        idleTask?.cancel()
        await drop()
    }

    private func openConnection() async throws -> IMAPConnection {
        if let connection, await connection.isOpen { return connection }
        let fresh = IMAPConnection(endpoint: endpoint, pin: pin, credentials: credentials)
        try await fresh.open()
        connection = fresh
        return fresh
    }

    private func drop() async {
        await connection?.close()
        connection = nil
    }

    private func scheduleIdleClose() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: BridgeClient.idleTimeout)
            guard !Task.isCancelled else { return }
            await self?.closeIfIdle()
        }
    }

    private func closeIfIdle() async {
        if Date().timeIntervalSince(lastUse) >= 299 { await drop() }
    }
}

/// Turns Postern's search fields into an IMAP search key.
public enum SearchKeyBuilder {
    public static func key(for query: SearchQuery) -> SearchKey {
        var keys: [SearchKey] = []
        if let from = query.from, !from.isEmpty { keys.append(.from(ByteBuffer(string: from))) }
        if let to = query.to, !to.isEmpty { keys.append(.to(ByteBuffer(string: to))) }
        if let subject = query.subject, !subject.isEmpty { keys.append(.subject(ByteBuffer(string: subject))) }
        if let text = query.text, !text.isEmpty { keys.append(.text(ByteBuffer(string: text))) }
        if let since = query.since, let day = day(since) { keys.append(.since(day)) }
        if let before = query.before, let day = day(before) { keys.append(.before(day)) }
        if let unread = query.unread { keys.append(unread ? .unseen : .seen) }
        if let starred = query.starred { keys.append(starred ? .flagged : .unflagged) }
        switch keys.count {
        case 0: return .all
        case 1: return keys[0]
        default: return .and(keys)
        }
    }

    /// Messages whose Message-ID is one of `ids`, or that reference one of them.
    public static func thread(ids: [String]) -> SearchKey? {
        let keys = ids.flatMap { id -> [SearchKey] in
            [.header("Message-ID", ByteBuffer(string: id)), .header("References", ByteBuffer(string: id)),
             .header("In-Reply-To", ByteBuffer(string: id))]
        }
        guard var combined = keys.first else { return nil }
        for key in keys.dropFirst() { combined = .or(combined, key) }
        return combined
    }

    private static func day(_ date: Date) -> IMAPCalendarDay? {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return IMAPCalendarDay(year: year, month: month, day: day)
    }
}
