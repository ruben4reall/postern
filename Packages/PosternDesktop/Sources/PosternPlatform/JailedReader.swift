import Foundation
import PosternCore
import PosternModel

/// Reads hostile messages in `postern-parser`, a fresh process for every message. On Linux the reader locks itself
/// in (seccomp, Landlock, limits) before it reads a byte; on Windows the core starts it in an AppContainer with no
/// capability. Either way a message crafted to exploit the reader lands where it can reach nothing.
public struct JailedReader: MessageReading {
    let program: URL

    public init(program: URL) {
        self.program = program
    }

    public func sanitize(_ raw: Data, maxChars: Int) async throws -> SanitizedMessage {
        let answer = try await run(ParserRequest(operation: .sanitize, size: raw.count, maxChars: maxChars), raw, seconds: 20,
                                   timeout: "Reading this message took too long.")
        guard let message = answer.message else { throw Self.failure(answer, "This message could not be read") }
        return message
    }

    public func attachment(_ raw: Data, index: Int) async throws -> (data: Data, filename: String?, mimeType: String) {
        let answer = try await run(ParserRequest(operation: .attachment, size: raw.count, index: index), raw, seconds: 30,
                                   timeout: "Reading this attachment took too long.")
        guard let file = answer.file else { throw Self.failure(answer, "This attachment could not be read") }
        return (file.data, file.filename, file.mimeType)
    }

    public func readAttachment(_ raw: Data, index: Int, maxChars: Int) async throws -> AttachmentContent {
        let answer = try await run(ParserRequest(operation: .readAttachment, size: raw.count, maxChars: maxChars, index: index), raw,
                                   seconds: 60, timeout: "Reading this attachment took too long.")
        guard let content = answer.content else {
            throw PosternError(.parseFailed, answer.error ?? "This attachment could not be read.")
        }
        return content
    }

    static func failure(_ answer: ParserAnswer, _ text: String) -> PosternError {
        PosternError(.parseFailed, answer.error.map { "\(text) (\($0))." } ?? "\(text).")
    }

    private func run(_ request: ParserRequest, _ raw: Data, seconds: Double, timeout: String) async throws -> ParserAnswer {
        let program = self.program
        return try await ReaderCall.run(seconds: seconds, timeoutMessage: timeout) {
            try await Task.detached(priority: .userInitiated) {
                try Self.spawn(program, request: request, raw: raw, seconds: seconds)
            }.value
        }
    }

    /// Starts the reader, gives it the request, and waits for its answer. The process is killed past its time.
    static func spawn(_ program: URL, request: ParserRequest, raw: Data, seconds: Double) throws -> ParserAnswer {
        var header = try JSONEncoder().encode(request)
        header.append(0x0A)
        let process = ReaderProcess(program: program)
        let output = try process.run(input: header + raw, seconds: seconds)
        guard let answer = try? JSONDecoder().decode(ParserAnswer.self, from: output) else {
            throw PosternError(.parseFailed, "The message reader stopped. Try again.")
        }
        return answer
    }
}

/// One run of the reader process.
final class ReaderProcess: @unchecked Sendable {
    let program: URL

    init(program: URL) { self.program = program }

    func run(input: Data, seconds: Double) throws -> Data {
        #if os(Windows)
        return try AppContainerLauncher.run(program: program, input: input, seconds: seconds)
        #else
        let process = Process()
        process.executableURL = program
        process.arguments = []
        // The reader inherits nothing it does not need: no home, no display, no session bus.
        process.environment = ["LANG": "C.UTF-8", "PATH": "/usr/bin:/bin"]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate(); kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: deadline)
        defer { deadline.cancel() }
        // Write on another thread: a large message fills the pipe before the reader starts answering.
        let writer = Thread {
            // A reader that stopped early closes its end: the write fails, and the answer below says so.
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
        writer.start()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return output
        #endif
    }
}
