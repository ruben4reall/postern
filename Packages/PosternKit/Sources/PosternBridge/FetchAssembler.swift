import Foundation
import NIOCore
import NIOIMAP
import PosternModel
import PosternText

/// What a summary fetch returns for one message, before Postern turns it into a `MessageSummary`.
public struct FetchedSummary: Sendable {
    public var uid: UInt32?
    public var flags: [String] = []
    public var date: Date?
    public var subject = ""
    public var from: [Address] = []
    public var to: [Address] = []
    public var cc: [Address] = []
    public var messageID: String?
    public var inReplyTo: String?
    public var size: Int?
    public var attachmentCount = 0
}

/// Reassembles the streamed parts of FETCH responses into whole messages.
enum FetchAssembler {
    static func summaries(from responses: [Response]) -> [FetchedSummary] {
        var result: [FetchedSummary] = []
        var current: FetchedSummary?
        for response in responses {
            guard case .fetch(let part) = response else { continue }
            switch part {
            case .start, .startUID:
                current = FetchedSummary()
                if case .startUID(let uid) = part { current?.uid = uid.rawValue }
            case .simpleAttribute(let attribute):
                guard current != nil else { continue }
                apply(attribute, to: &current!)
            case .finish:
                if let current { result.append(current) }
                current = nil
            default:
                break
            }
        }
        return result
    }

    static func bodies(from responses: [Response]) -> [Data] {
        var result: [Data] = []
        var buffer: Data?
        for response in responses {
            guard case .fetch(let part) = response else { continue }
            switch part {
            case .streamingBegin(_, let count):
                buffer = Data()
                buffer?.reserveCapacity(count)
            case .streamingBytes(let bytes):
                buffer?.append(contentsOf: bytes.readableBytesView)
            case .streamingEnd:
                if let buffer { result.append(buffer) }
                buffer = nil
            default:
                break
            }
        }
        return result
    }

    private static func apply(_ attribute: MessageAttribute, to summary: inout FetchedSummary) {
        switch attribute {
        case .uid(let uid):
            summary.uid = uid.rawValue
        case .flags(let flags):
            summary.flags = flags.map { String(describing: $0) }
        case .rfc822Size(let size):
            summary.size = size
        case .envelope(let envelope):
            summary.date = envelope.date.flatMap { MailDate.parse(String($0)) }
            summary.subject = envelope.subject.map {
                UnicodeCleaner.clean(EncodedWords.decode(String(buffer: $0)), keepNewlines: false)
            } ?? ""
            summary.from = addresses(envelope.from)
            summary.to = addresses(envelope.to)
            summary.cc = addresses(envelope.cc)
            summary.messageID = envelope.messageID.map { String($0) }
            summary.inReplyTo = envelope.inReplyTo.map { String($0) }
        case .body(.valid(let structure), _):
            summary.attachmentCount = countAttachments(structure)
        default:
            break
        }
    }

    private static func addresses(_ list: [EmailAddressListElement]) -> [Address] {
        list.flatMap { element -> [Address] in
            switch element {
            case .singleAddress(let address):
                guard let mailbox = address.mailbox, let host = address.host else { return [] }
                let email = UnicodeCleaner.clean("\(String(buffer: mailbox))@\(String(buffer: host))", keepNewlines: false)
                let name = address.personName.map {
                    UnicodeCleaner.clean(EncodedWords.decode(String(buffer: $0)), keepNewlines: false)
                }
                return [Address(name: name?.isEmpty == false ? name : nil, email: email)]
            case .group(let group):
                return addresses(group.children)
            }
        }
    }

    private static func countAttachments(_ structure: BodyStructure) -> Int {
        switch structure {
        case .multipart(let multipart):
            return multipart.parts.reduce(0) { $0 + countAttachments($1) }
        case .singlepart(let part):
            if part.extension?.dispositionAndLanguage?.disposition?.kind == .attachment { return 1 }
            if case .basic = part.kind, part.extension?.dispositionAndLanguage?.disposition?.kind != .inline {
                return 1
            }
            return 0
        }
    }
}
