import CryptoKit
import Foundation
import UniformTypeIdentifiers
import PosternModel
import PosternText

public enum ComposeError: Error, Equatable, Sendable {
    case noRecipient
    case tooManyRecipients
    case invalidAddress(String)
    /// A line break in a header field: it would add headers the user never saw.
    case headerInjection
    case tooLong
    case invalidFileName(String)
}

/// A file attached to an outgoing message. Its bytes are part of the digest the user approves.
public struct OutgoingAttachment: Codable, Sendable, Equatable {
    public let filename: String
    public let mimeType: String
    public let data: Data

    public var sha256: String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Refuses names that could escape a folder or hide something: path separators, line breaks, invisible
    /// characters, leading dots.
    public static func make(filename: String, data: Data, mimeType: String? = nil) throws -> OutgoingAttachment {
        let name = UnicodeCleaner.clean(filename, keepNewlines: false).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name == filename.trimmingCharacters(in: .whitespaces), !name.hasPrefix("."),
              name.count <= 200, !name.contains(where: { "/\\:".contains($0) }),
              !OutgoingMessage.hasLineBreak(filename) else {
            throw ComposeError.invalidFileName(filename)
        }
        let type = mimeType ?? UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        return OutgoingAttachment(filename: name, mimeType: type, data: data)
    }
}

/// A message about to leave, in its final form. It is rendered from this value alone, so the digest an approval
/// binds to covers every byte that is sent and every recipient of the envelope.
public struct OutgoingMessage: Codable, Sendable, Equatable {
    public var from: Address
    public var to: [Address]
    public var cc: [Address]
    public var bcc: [Address]
    public var subject: String
    /// The text the client wrote.
    public var body: String
    /// For replies and forwards: the original text, appended below the body and shown apart on the panel.
    public var quoted: String?
    public var inReplyTo: String?
    public var references: [String]
    public var attachments: [OutgoingAttachment]
    public let messageID: String
    public let date: Date

    public static let maxRecipients = 50
    public static let maxBodyCharacters = 200_000
    public static let maxAttachmentBytes = 20_000_000

    /// Validates and cleans what a client asked for. Invisible characters are removed here, so the approval panel
    /// shows exactly the text that leaves.
    public static func make(
        from: Address, to: [Address], cc: [Address] = [], bcc: [Address] = [], subject: String, body: String,
        quoted: String? = nil, inReplyTo: String? = nil, references: [String] = [],
        attachments: [OutgoingAttachment] = []
    ) throws -> OutgoingMessage {
        let all = to + cc + bcc
        guard !all.isEmpty else { throw ComposeError.noRecipient }
        guard all.count <= maxRecipients else { throw ComposeError.tooManyRecipients }
        guard !hasLineBreak(subject) else { throw ComposeError.headerInjection }
        guard body.count + (quoted?.count ?? 0) <= maxBodyCharacters else { throw ComposeError.tooLong }
        guard attachments.reduce(0, { $0 + $1.data.count }) <= maxAttachmentBytes else { throw ComposeError.tooLong }
        let clean = { (list: [Address]) in try list.map(cleanAddress) }
        let sender = try cleanAddress(from)
        let domain = sender.email.split(separator: "@").last.map(String.init) ?? "postern.invalid"
        return OutgoingMessage(
            from: sender, to: try clean(to), cc: try clean(cc), bcc: try clean(bcc),
            subject: UnicodeCleaner.clean(subject, keepNewlines: false),
            body: UnicodeCleaner.clean(body), quoted: quoted.map { UnicodeCleaner.clean($0) },
            inReplyTo: try inReplyTo.map(cleanMessageID), references: try references.map(cleanMessageID),
            attachments: attachments, messageID: "<\(UUID().uuidString.lowercased())@\(domain)>", date: Date()
        )
    }

    /// Everyone the SMTP envelope reaches, Bcc included, each once.
    public var envelopeRecipients: [String] {
        var seen = Set<String>()
        return (to + cc + bcc).map { $0.email.lowercased() }.filter { seen.insert($0).inserted }
    }

    /// The whole text that leaves: what the client wrote, then the quoted original.
    public var fullText: String {
        guard let quoted, !quoted.isEmpty else { return body }
        return body + "\n\n" + quoted
    }

    /// SHA-256 of the rendered message with Bcc and of the envelope: any change makes a new digest.
    public var digest: String {
        var data = rfc822(includeBcc: true)
        data.append(Data(("\n" + envelopeRecipients.joined(separator: ",")).utf8))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// RFC 5322 bytes with CRLF line endings. Drafts keep the Bcc header; sent mail never shows it.
    public func rfc822(includeBcc: Bool) -> Data {
        var headers: [String] = ["From: " + Self.format(from)]
        if !to.isEmpty { headers.append("To: " + to.map(Self.format).joined(separator: ", ")) }
        if !cc.isEmpty { headers.append("Cc: " + cc.map(Self.format).joined(separator: ", ")) }
        if includeBcc && !bcc.isEmpty { headers.append("Bcc: " + bcc.map(Self.format).joined(separator: ", ")) }
        headers.append("Subject: " + Self.encodeWord(subject))
        headers.append("Date: " + Self.dateFormatter.string(from: date))
        headers.append("Message-ID: " + messageID)
        if let inReplyTo { headers.append("In-Reply-To: " + inReplyTo) }
        if !references.isEmpty { headers.append("References: " + references.joined(separator: " ")) }
        headers.append("MIME-Version: 1.0")
        let textPart = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
            + QuotedPrintable.encode(fullText) + "\r\n"
        guard !attachments.isEmpty else {
            return Data((headers.joined(separator: "\r\n") + "\r\n" + textPart).utf8)
        }
        // The boundary derives from the Message-ID, so the same message always renders to the same bytes.
        let boundary = "postern-" + SHA256.hash(data: Data(messageID.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        headers.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
        var text = headers.joined(separator: "\r\n") + "\r\n\r\n--\(boundary)\r\n" + textPart
        for attachment in attachments {
            let ascii = Self.asciiFileName(attachment.filename)
            let encoded = attachment.filename.addingPercentEncoding(withAllowedCharacters: Self.attributeCharacters) ?? ascii
            text += "--\(boundary)\r\n"
            text += "Content-Type: \(attachment.mimeType); name=\"\(ascii)\"\r\n"
            text += "Content-Disposition: attachment; filename=\"\(ascii)\"; filename*=utf-8''\(encoded)\r\n"
            text += "Content-Transfer-Encoding: base64\r\n\r\n"
            text += attachment.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
            text += "\r\n"
        }
        text += "--\(boundary)--\r\n"
        return Data(text.utf8)
    }

    // MARK: Validation

    private static var addressPattern: Regex<(Substring, Substring?)> { #/^[A-Za-z0-9!#$%&'*+/=?^_`{|}~.-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$/# }

    static func cleanAddress(_ address: Address) throws -> Address {
        let email = address.email.trimmingCharacters(in: .whitespaces)
        guard email.wholeMatch(of: addressPattern) != nil else { throw ComposeError.invalidAddress(address.email) }
        if let name = address.name, hasLineBreak(name) { throw ComposeError.headerInjection }
        let name = address.name.map { UnicodeCleaner.clean($0, keepNewlines: false).trimmingCharacters(in: .whitespaces) }
        return Address(name: name?.isEmpty == false ? name : nil, email: email.lowercased())
    }

    /// Checks scalars, not Characters: Swift treats CRLF as a single Character that equals neither CR nor LF.
    static func hasLineBreak(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0 == "\r" || $0 == "\n" || $0 == "\u{2028}" || $0 == "\u{2029}" || $0 == "\u{85}" }
    }

    static func cleanMessageID(_ id: String) throws -> String {
        guard id.wholeMatch(of: #/<[^<>\s]+>/#) != nil else { throw ComposeError.headerInjection }
        return id
    }

    // MARK: Encoding

    /// RFC 2231 attribute characters: everything else is percent-encoded.
    static let attributeCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~")

    static func asciiFileName(_ name: String) -> String {
        String(name.unicodeScalars.filter { $0.isASCII && $0.value >= 32 && $0 != "\"" && $0 != "\\" }.map(Character.init))
    }

    static func format(_ address: Address) -> String {
        guard let name = address.name else { return address.email }
        let plain = name.allSatisfy { $0.isASCII && !"\"\\".contains($0) && !$0.isNewline }
        return (plain ? "\"\(name)\"" : encodeWord(name)) + " <\(address.email)>"
    }

    /// RFC 2047: ASCII stays as it is; anything else becomes base64 words of at most 75 characters.
    static func encodeWord(_ text: String) -> String {
        if text.allSatisfy({ $0.isASCII }) { return text }
        var words: [String] = []
        var chunk = ""
        for character in text {
            if (chunk + String(character)).utf8.count > 45 {
                words.append(chunk)
                chunk = ""
            }
            chunk.append(character)
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    static var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter
    }
}

/// Quoted-printable for UTF-8 text: hard line breaks become CRLF, lines are cut at 76 with soft breaks.
enum QuotedPrintable {
    static func encode(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n").map(encodeLine).joined(separator: "\r\n")
    }

    private static func encodeLine(_ line: String) -> String {
        let bytes = Array(line.utf8)
        var tokens: [String] = []
        for (index, byte) in bytes.enumerated() {
            let isLast = index == bytes.count - 1
            switch byte {
            case 33...60, 62...126: tokens.append(String(UnicodeScalar(byte)))
            case 32, 9 where !isLast: tokens.append(String(UnicodeScalar(byte)))
            default: tokens.append(String(format: "=%02X", byte))
            }
        }
        var output: [String] = []
        var current = ""
        for token in tokens {
            if current.count + token.count > 75 {
                output.append(current + "=")
                current = ""
            }
            current += token
        }
        output.append(current)
        return output.joined(separator: "\r\n")
    }
}
