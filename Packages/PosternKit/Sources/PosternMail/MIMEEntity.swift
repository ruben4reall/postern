import Foundation
import PosternText

/// Bounds that stop a crafted message from exhausting memory or time.
public struct MIMELimits: Sendable {
    public var maxBytes = 25_000_000
    public var maxDepth = 8
    public var maxParts = 200
    public var maxHeaderBytes = 256_000

    public init() {}
}

public enum MIMEError: Error, Equatable, Sendable {
    case tooLarge
    case tooDeep
    case tooManyParts
    case headerTooLarge
}

/// A parsed header field, in the order it appeared.
public struct HeaderField: Sendable, Hashable {
    public let name: String
    /// Unfolded, still encoded (RFC 2047 words are decoded by the reader that needs them).
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// `type/subtype; key=value` with parameters already decoded, RFC 2231 included.
public struct ContentType: Sendable, Hashable {
    public var type: String
    public var subtype: String
    public var parameters: [String: String]

    public var mimeType: String { "\(type)/\(subtype)" }

    public static let defaultText = ContentType(type: "text", subtype: "plain", parameters: ["charset": "us-ascii"])
}

public struct MIMEEntity: Sendable {
    public enum Body: Sendable {
        case leaf(Data)
        case multipart([MIMEEntity])
    }

    public let headers: [HeaderField]
    public let contentType: ContentType
    public let transferEncoding: String
    public let disposition: String?
    public let dispositionParameters: [String: String]
    public let body: Body

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public func headers(named name: String) -> [String] {
        headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    /// The body after base64 or quoted-printable decoding.
    public var decodedBody: Data {
        guard case .leaf(let raw) = body else { return Data() }
        switch transferEncoding {
        case "base64": return TransferDecoding.base64(raw)
        case "quoted-printable": return TransferDecoding.quotedPrintable(raw)
        default: return raw
        }
    }

    /// The decoded body as text, in its declared charset, falling back to UTF-8 then Windows-1252.
    public var text: String {
        let data = decodedBody
        if let name = contentType.parameters["charset"], let encoding = Charsets.encoding(named: name),
           let string = String(data: data, encoding: encoding) {
            return string
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
    }

    /// File name from the disposition or, failing that, the content type.
    public var filename: String? {
        let raw = dispositionParameters["filename"] ?? contentType.parameters["name"]
        return raw.map { UnicodeCleaner.clean(EncodedWords.decode($0), keepNewlines: false) }
    }

    public var isAttachment: Bool {
        if disposition == "attachment" { return true }
        if contentType.type == "multipart" || contentType.type == "message" { return false }
        if contentType.type == "text" && filename == nil { return false }
        return filename != nil || (contentType.type != "text")
    }
}
