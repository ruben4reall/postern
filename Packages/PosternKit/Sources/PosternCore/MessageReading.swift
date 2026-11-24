import Foundation
import PosternModel

/// Decodes and cleans raw messages somewhere hostile input cannot reach Postern's secrets: the XPC service in its
/// empty sandbox on the Mac, a jailed process on Linux and Windows. The core never parses a message body itself.
public protocol MessageReading: Sendable {
    func sanitize(_ raw: Data, maxChars: Int) async throws -> SanitizedMessage
    func attachment(_ raw: Data, index: Int) async throws -> (data: Data, filename: String?, mimeType: String)
    func readAttachment(_ raw: Data, index: Int, maxChars: Int) async throws -> AttachmentContent
}

/// Runs a reader's work with a time limit, and turns any failure into an error a client can explain.
public enum ReaderCall {
    public static func run<T: Sendable>(
        seconds: Double, timeoutMessage: String, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw PosternError(.parseFailed, timeoutMessage)
            }
            guard let first = try await group.next() else { throw PosternError(.parseFailed, timeoutMessage) }
            group.cancelAll()
            return first
        }
    }
}
