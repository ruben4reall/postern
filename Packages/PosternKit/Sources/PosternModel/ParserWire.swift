import Foundation

/// What the core asks the message reader, when the reader is a separate process (Linux and Windows). The Mac app
/// speaks to its XPC service instead. One request per process: the reader starts, reads one request on its standard
/// input, answers on its standard output and exits, so nothing of one message survives into the next.
///
/// On the wire: one line of JSON (the request), then exactly `size` bytes of the raw message. The answer is one JSON
/// object (`ParserAnswer`).
public struct ParserRequest: Codable, Sendable, Equatable {
    public enum Operation: String, Codable, Sendable {
        /// The message as the tools show it: headers, cleaned text, links, attachment list, sender verdict.
        case sanitize
        /// The decoded bytes of one attachment.
        case attachment
        /// The text of one attachment.
        case readAttachment
    }

    public let operation: Operation
    public let size: Int
    public let maxChars: Int
    public let index: Int

    public init(operation: Operation, size: Int, maxChars: Int = 0, index: Int = 0) {
        self.operation = operation
        self.size = size
        self.maxChars = maxChars
        self.index = index
    }

    /// No raw message is larger: Bridge messages are capped at 25 MB before they reach the reader.
    public static let maxSize = 26_000_000
}

/// The reader's answer. Exactly one of `message`, `content`, `file` or `error` is set.
public struct ParserAnswer: Codable, Sendable, Equatable {
    public struct File: Codable, Sendable, Equatable {
        public let data: Data
        public let filename: String?
        public let mimeType: String

        public init(data: Data, filename: String?, mimeType: String) {
            self.data = data
            self.filename = filename
            self.mimeType = mimeType
        }
    }

    public var message: SanitizedMessage?
    public var content: AttachmentContent?
    public var file: File?
    public var error: String?

    public init(message: SanitizedMessage? = nil, content: AttachmentContent? = nil, file: File? = nil, error: String? = nil) {
        self.message = message
        self.content = content
        self.file = file
        self.error = error
    }
}
