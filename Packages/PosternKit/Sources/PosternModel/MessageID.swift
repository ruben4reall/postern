import Foundation

/// Identifies one message for as long as its mailbox keeps the same UIDVALIDITY.
///
/// Clients only ever see the opaque form. When Bridge renumbers a mailbox, the UIDVALIDITY changes and every id
/// minted before is refused instead of silently pointing at another message.
public struct MessageID: Hashable, Sendable {
    public let mailbox: String
    public let uidValidity: UInt32
    public let uid: UInt32

    public init(mailbox: String, uidValidity: UInt32, uid: UInt32) {
        self.mailbox = mailbox
        self.uidValidity = uidValidity
        self.uid = uid
    }

    private static let version = "v1"

    /// Base64url of `v1 NUL mailbox NUL uidValidity NUL uid`, without padding.
    public var opaque: String {
        let raw = [Self.version, mailbox, String(uidValidity), String(uid)].joined(separator: "\u{0}")
        return Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(opaque: String) {
        var base64 = opaque.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let raw = String(data: data, encoding: .utf8) else { return nil }
        let fields = raw.split(separator: "\u{0}", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[0] == Self.version, !fields[1].isEmpty,
              let validity = UInt32(fields[2]), let uid = UInt32(fields[3]) else { return nil }
        self.init(mailbox: String(fields[1]), uidValidity: validity, uid: uid)
    }
}

extension MessageID: Codable {
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let id = MessageID(opaque: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid message id"))
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(opaque)
    }
}
