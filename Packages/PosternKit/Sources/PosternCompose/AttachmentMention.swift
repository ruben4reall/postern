import Foundation

/// The words that say a file comes with an email, in the languages Postern's users write in. An email that says so
/// and carries no file is the mistake mail apps warn about; Postern stops it before it is saved or sent.
public enum AttachmentMention {
    /// Phrases folded to lower case without accents, matched as whole words.
    static let phrases: [String] = [
        // French
        #"pieces? jointes?"#, #"ci[- ]joint(e|s|es)?"#, #"en p\.?\s?j\.?"#, #"p\.?\s?j\.?\s*:"#, "en annexe",
        #"je (vous |te )?joins"#, #"joint(e|s|es)? (a|au|avec) (ce|cet|cette|mon|ma|le|la)( |-)?(mail|e-mail|email|message|courriel)"#,
        // English
        "attached", "attachments?", "attaching", "enclosed", #"i (have |ve |'ve )?attach(ed)?"#,
        // German
        "anbei", "im anhang", "angehangt", "beigefugt", #"als anlage"#,
        // Spanish, Portuguese
        #"adjunt(o|a|os|as)"#, #"(em|en) anexo"#, #"segue anexo"#, #"anexad[oa]s?"#,
        // Italian
        "in allegato", #"allegat[oi]"#, "allego",
        // Dutch
        "bijlage", "bijgevoegd",
    ]

    private static let pattern: NSRegularExpression = {
        let alternatives = phrases.map { "(?:\($0))" }.joined(separator: "|")
        // Letters on either side would make it part of another word.
        return try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])(?:\(alternatives))(?![\\p{L}\\p{N}])", options: [])
    }()

    /// The phrase in `text` that announces a file, as written, or nil.
    public static func found(in text: String) -> String? {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "\u{2019}", with: "'")
        let range = NSRange(folded.startIndex..., in: folded)
        guard let match = pattern.firstMatch(in: folded, range: range), let found = Range(match.range, in: folded) else {
            return nil
        }
        // Folding keeps the length of most text; when it does not, the folded words are still clear enough.
        if folded.count == text.count {
            let start = folded.distance(from: folded.startIndex, to: found.lowerBound)
            let length = folded.distance(from: found.lowerBound, to: found.upperBound)
            let lower = text.index(text.startIndex, offsetBy: start)
            return String(text[lower..<text.index(lower, offsetBy: length)])
        }
        return String(folded[found])
    }
}

extension OutgoingMessage {
    /// The words that announce a file when the email carries none: what the client wrote, not the quoted original.
    public var missingAttachment: String? {
        guard attachments.isEmpty else { return nil }
        return AttachmentMention.found(in: subject) ?? AttachmentMention.found(in: body)
    }
}
