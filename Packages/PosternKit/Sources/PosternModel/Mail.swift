import Foundation

public struct Address: Codable, Sendable, Hashable {
    public let name: String?
    public let email: String

    public init(name: String?, email: String) {
        self.name = name
        self.email = email
    }
}

public struct MailboxInfo: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case system, folder, label, virtual
    }

    /// The IMAP name, used to address the mailbox in other tools.
    public let name: String
    public let kind: Kind
    public let total: Int?
    public let unread: Int?

    public init(name: String, kind: Kind, total: Int?, unread: Int?) {
        self.name = name
        self.kind = kind
        self.total = total
        self.unread = unread
    }
}

public struct MessageSummary: Codable, Sendable, Hashable {
    public let id: MessageID
    public let date: Date?
    public let from: [Address]
    public let to: [Address]
    public let cc: [Address]
    public let subject: String
    public let unread: Bool
    public let starred: Bool
    public let answered: Bool
    public let size: Int
    public let attachmentCount: Int
    public let messageIDHeader: String?
    public let inReplyTo: String?

    public init(
        id: MessageID, date: Date?, from: [Address], to: [Address], cc: [Address], subject: String,
        unread: Bool, starred: Bool, answered: Bool, size: Int, attachmentCount: Int,
        messageIDHeader: String?, inReplyTo: String?
    ) {
        self.id = id
        self.date = date
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.unread = unread
        self.starred = starred
        self.answered = answered
        self.size = size
        self.attachmentCount = attachmentCount
        self.messageIDHeader = messageIDHeader
        self.inReplyTo = inReplyTo
    }
}

public struct LinkInfo: Codable, Sendable, Hashable {
    public let index: Int
    public let text: String
    public let url: String
    public let host: String?
    /// The visible text names a domain other than the real destination.
    public let textLooksLikeOtherHost: Bool
    /// Punycode or mixed-script host, or an address written as a bare IP.
    public let suspiciousHost: Bool

    public init(index: Int, text: String, url: String, host: String?, textLooksLikeOtherHost: Bool, suspiciousHost: Bool) {
        self.index = index
        self.text = text
        self.url = url
        self.host = host
        self.textLooksLikeOtherHost = textLooksLikeOtherHost
        self.suspiciousHost = suspiciousHost
    }
}

public struct AttachmentInfo: Codable, Sendable, Hashable {
    public let index: Int
    public let filename: String?
    public let mimeType: String
    public let size: Int

    public init(index: Int, filename: String?, mimeType: String, size: Int) {
        self.index = index
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
    }
}

public struct SenderVerdict: Codable, Sendable, Hashable {
    public enum Level: String, Codable, Sendable {
        /// Sent from inside Proton.
        case `internal`
        /// SPF or DKIM aligned and DMARC passed, as recorded by Proton.
        case verified
        /// No usable authentication result.
        case unverified
        /// DMARC, or both SPF and DKIM, failed.
        case failed
    }

    public let level: Level
    public let spf: String?
    public let dkim: String?
    public let dmarc: String?
    public let origin: String?
    public let reasons: [String]
    /// An Authentication-Results header claimed Proton's identity outside the block Proton writes.
    public let forgedHeaderSeen: Bool
    public let authservIDsSeen: [String]

    public init(
        level: Level, spf: String?, dkim: String?, dmarc: String?, origin: String?, reasons: [String],
        forgedHeaderSeen: Bool, authservIDsSeen: [String]
    ) {
        self.level = level
        self.spf = spf
        self.dkim = dkim
        self.dmarc = dmarc
        self.origin = origin
        self.reasons = reasons
        self.forgedHeaderSeen = forgedHeaderSeen
        self.authservIDsSeen = authservIDsSeen
    }
}

public struct SanitizedHeaders: Codable, Sendable, Hashable {
    public var from: [Address]
    public var replyTo: [Address]
    public var to: [Address]
    public var cc: [Address]
    public var bcc: [Address]
    public var date: Date?
    public var subject: String
    public var messageID: String?
    public var inReplyTo: String?
    public var references: [String]
    public var listUnsubscribe: [String]

    public init(
        from: [Address] = [], replyTo: [Address] = [], to: [Address] = [], cc: [Address] = [], bcc: [Address] = [],
        date: Date? = nil,
        subject: String = "", messageID: String? = nil, inReplyTo: String? = nil, references: [String] = [],
        listUnsubscribe: [String] = []
    ) {
        self.from = from
        self.replyTo = replyTo
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.date = date
        self.subject = subject
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.listUnsubscribe = listUnsubscribe
    }
}

/// A message after the parser service has decoded it and removed everything a human reader would not see.
public struct SanitizedMessage: Codable, Sendable, Hashable {
    public var headers: SanitizedHeaders
    public var body: String
    public var bodyTruncated: Bool
    public var bodyWasHTML: Bool
    public var hiddenElementsRemoved: Int
    public var imagesOmitted: Int
    public var links: [LinkInfo]
    public var attachments: [AttachmentInfo]
    public var verdict: SenderVerdict

    public init(
        headers: SanitizedHeaders, body: String, bodyTruncated: Bool, bodyWasHTML: Bool, hiddenElementsRemoved: Int,
        imagesOmitted: Int, links: [LinkInfo], attachments: [AttachmentInfo], verdict: SenderVerdict
    ) {
        self.headers = headers
        self.body = body
        self.bodyTruncated = bodyTruncated
        self.bodyWasHTML = bodyWasHTML
        self.hiddenElementsRemoved = hiddenElementsRemoved
        self.imagesOmitted = imagesOmitted
        self.links = links
        self.attachments = attachments
        self.verdict = verdict
    }
}
