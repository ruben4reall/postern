import Foundation
import PosternModel
import PosternText

/// Raw RFC 822 bytes in, what a human would read out. Runs inside the sandboxed parser service.
public enum MessageSanitizer {
    public static func sanitize(raw: Data, maxChars: Int, limits: MIMELimits = MIMELimits()) throws -> SanitizedMessage {
        let root = try MIMEParser.parse(raw, limits: limits)
        let headers = sanitizedHeaders(root)

        var plain: [MIMEEntity] = []
        var html: [MIMEEntity] = []
        var attachments: [AttachmentInfo] = []
        var inlineImages = 0
        collect(root, plain: &plain, html: &html, attachments: &attachments, inlineImages: &inlineImages)

        // Prefer the HTML part when there is one: it is what Proton shows the user, and a plain-text alternative
        // can carry text the reader never sees.
        var body = ""
        var wasHTML = false
        var links: [LinkInfo] = []
        var hidden = 0
        var images = inlineImages
        if let part = html.first {
            let rendering = HTMLSanitizer().render(part.text)
            body = rendering.text
            links = rendering.links
            hidden = rendering.hiddenElementsRemoved
            images += rendering.imagesOmitted
            wasHTML = true
        } else if let part = plain.first {
            body = UnicodeCleaner.clean(part.text).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let truncated = body.count > maxChars
        if truncated { body = String(body.prefix(maxChars)) }

        let verdict = SenderVerdictEngine().verdict(headers: root.headers, from: headers.from)
        return SanitizedMessage(
            headers: headers, body: body, bodyTruncated: truncated, bodyWasHTML: wasHTML,
            hiddenElementsRemoved: hidden, imagesOmitted: images, links: links, attachments: attachments,
            verdict: verdict
        )
    }

    private static func collect(
        _ entity: MIMEEntity, plain: inout [MIMEEntity], html: inout [MIMEEntity],
        attachments: inout [AttachmentInfo], inlineImages: inout Int
    ) {
        switch entity.body {
        case .multipart(let parts):
            for part in parts {
                collect(part, plain: &plain, html: &html, attachments: &attachments, inlineImages: &inlineImages)
            }
        case .leaf:
            if entity.isAttachment {
                if entity.contentType.type == "image" && entity.disposition != "attachment"
                    && entity.header("Content-ID") != nil {
                    inlineImages += 1
                    return
                }
                attachments.append(AttachmentInfo(
                    index: attachments.count + 1, filename: entity.filename,
                    mimeType: entity.contentType.mimeType, size: entity.decodedBody.count
                ))
            } else if entity.contentType.mimeType == "text/html" {
                html.append(entity)
            } else if entity.contentType.type == "text" {
                plain.append(entity)
            }
        }
    }

    static func sanitizedHeaders(_ root: MIMEEntity) -> SanitizedHeaders {
        func single(_ name: String) -> String? {
            root.header(name).map { UnicodeCleaner.clean(EncodedWords.decode($0), keepNewlines: false) }
        }
        func addresses(_ name: String) -> [Address] {
            root.headers(named: name).flatMap { AddressParser.parse($0) }
        }
        func ids(_ value: String?) -> [String] {
            guard let value else { return [] }
            return value.matches(of: #/<[^<>\s]+>/#).map { String($0.0) }
        }
        let unsubscribe = root.header("List-Unsubscribe").map { value in
            value.matches(of: #/<([^<>]+)>/#).map { UnicodeCleaner.clean(String($0.1), keepNewlines: false) }
        } ?? []
        return SanitizedHeaders(
            from: addresses("From"), replyTo: addresses("Reply-To"), to: addresses("To"), cc: addresses("Cc"),
            date: single("Date").flatMap(DateParser.parse), subject: single("Subject") ?? "",
            messageID: ids(root.header("Message-ID")).first, inReplyTo: ids(root.header("In-Reply-To")).first,
            references: ids(root.header("References")), listUnsubscribe: unsubscribe
        )
    }
}

/// RFC 5322 address lists, tolerant of what real mail contains.
public enum AddressParser {
    public static func parse(_ value: String) -> [Address] {
        var items: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        var commentDepth = 0
        for character in value {
            switch character {
            case "\"" where commentDepth == 0: inQuotes.toggle()
            case "(" where !inQuotes: commentDepth += 1
            case ")" where !inQuotes && commentDepth > 0: commentDepth -= 1
            case "<" where !inQuotes && commentDepth == 0: inAngle = true
            case ">" where !inQuotes && commentDepth == 0: inAngle = false
            case "," where !inQuotes && !inAngle && commentDepth == 0:
                items.append(current); current = ""; continue
            case ";" where !inQuotes && !inAngle && commentDepth == 0:
                items.append(current); current = ""; continue
            default: break
            }
            current.append(character)
        }
        items.append(current)

        return items.compactMap { item -> Address? in
            var text = item.trimmingCharacters(in: .whitespaces)
            // Group syntax: "Team: a@b.c, d@e.f;"
            if let colon = text.firstIndex(of: ":"), !text.contains("<"), !text[..<colon].contains("@") {
                text = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            guard !text.isEmpty else { return nil }
            if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
                let email = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                var name = String(text[..<open]).replacing(#/\([^()]*\)/#, with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"\t"))
                name = UnicodeCleaner.clean(EncodedWords.decode(name), keepNewlines: false)
                guard email.contains("@") else { return nil }
                return Address(name: name.isEmpty ? nil : name, email: UnicodeCleaner.clean(email, keepNewlines: false))
            }
            let bare = text.replacing(#/\([^()]*\)/#, with: "").trimmingCharacters(in: .whitespaces)
            guard bare.contains("@") else { return nil }
            return Address(name: nil, email: UnicodeCleaner.clean(bare, keepNewlines: false))
        }
    }
}

enum DateParser {
    private static let formats = [
        "EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss zzz",
        "d MMM yyyy HH:mm Z",
    ]

    static func parse(_ value: String) -> Date? {
        let cleaned = value.replacing(#/\s*\([^()]*\)\s*$/#, with: "").trimmingCharacters(in: .whitespaces)
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }
}
