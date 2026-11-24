import Foundation
import PosternCore
import PosternModel

/// Talks to the sandboxed parser service. The connection is recreated after any failure.
final class ParserClient: MessageReading, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    func proxy(onError: @escaping @Sendable (any Error) -> Void) -> ParserXPC {
        lock.withLock {
            if connection == nil {
                let fresh = NSXPCConnection(serviceName: PosternXPC.parserService)
                fresh.setCodeSigningRequirement(PosternXPC.teamRequirement)
                fresh.remoteObjectInterface = NSXPCInterface(with: ParserXPC.self)
                fresh.invalidationHandler = { [weak self] in self?.reset() }
                fresh.interruptionHandler = { [weak self] in self?.reset() }
                fresh.resume()
                connection = fresh
            }
            return connection!.remoteObjectProxyWithErrorHandler(onError) as! ParserXPC
        }
    }

    private func reset() { lock.withLock { connection = nil } }

    func sanitize(_ raw: Data, maxChars: Int) async throws -> SanitizedMessage {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SanitizedMessage, any Error>) in
            let once = OnceFlag()
            let fail: @Sendable (String) -> Void = { message in
                if once.claim() { continuation.resume(throwing: PosternError(.parseFailed, message)) }
            }
            let parser = proxy { _ in fail("The message reader stopped. Try again.") }
            parser.sanitize(raw, maxChars: maxChars) { data, error in
                guard let data, let message = try? JSONDecoder().decode(SanitizedMessage.self, from: data) else {
                    fail(error.map { "This message could not be read (\($0))." } ?? "This message could not be read.")
                    return
                }
                if once.claim() { continuation.resume(returning: message) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { fail("Reading this message took too long.") }
        }
    }
}

extension ParserClient {
    func attachment(_ raw: Data, index: Int) async throws -> (data: Data, filename: String?, mimeType: String) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(data: Data, filename: String?, mimeType: String), any Error>) in
            let once = OnceFlag()
            let fail: @Sendable (String) -> Void = { message in
                if once.claim() { continuation.resume(throwing: PosternError(.parseFailed, message)) }
            }
            let parser = proxy { _ in fail("The message reader stopped. Try again.") }
            parser.attachment(raw, index: index) { data, filename, mimeType, error in
                guard let data, let mimeType else {
                    fail(error == nil ? "This attachment could not be read." : "There is no attachment \(index) in this message.")
                    return
                }
                if once.claim() { continuation.resume(returning: (data, filename, mimeType)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { fail("Reading this attachment took too long.") }
        }
    }
}

extension ParserClient {
    func readAttachment(_ raw: Data, index: Int, maxChars: Int) async throws -> AttachmentContent {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AttachmentContent, any Error>) in
            let once = OnceFlag()
            let fail: @Sendable (String) -> Void = { message in
                if once.claim() { continuation.resume(throwing: PosternError(.parseFailed, message)) }
            }
            let parser = proxy { _ in fail("The attachment reader stopped. Try again.") }
            parser.readAttachment(raw, index: index, maxChars: maxChars) { data, error in
                guard let data, let content = try? JSONDecoder().decode(AttachmentContent.self, from: data) else {
                    fail(error ?? "This attachment could not be read.")
                    return
                }
                if once.claim() { continuation.resume(returning: content) }
            }
            // Recognizing the text of ten scanned pages takes a while.
            DispatchQueue.global().asyncAfter(deadline: .now() + 90) { fail("Reading this attachment took too long.") }
        }
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
