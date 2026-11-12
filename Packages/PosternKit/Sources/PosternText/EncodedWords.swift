import Foundation

/// RFC 2047 encoded words in header values, such as `=?UTF-8?B?...?=`.
public enum EncodedWords {
    private static var word: Regex<(Substring, Substring, Substring, Substring)> { #/=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?=/# }

    /// Unfolds the header and decodes every encoded word. Words that cannot be decoded stay as written.
    public static func decode(_ header: String) -> String {
        let unfolded = header.replacingOccurrences(of: "\r\n", with: "\n").replacing(#/\n[ \t]+/#, with: " ")
        var output = ""
        var cursor = unfolded.startIndex
        var previousWasEncoded = false
        for match in unfolded.matches(of: word) {
            let gap = unfolded[cursor..<match.range.lowerBound]
            let decoded = decodeWord(charset: String(match.1), encoding: String(match.2), text: String(match.3))
            // Whitespace between two encoded words is folding, not content.
            if !(previousWasEncoded && decoded != nil && gap.allSatisfy(\.isWhitespace)) {
                output += gap
            }
            output += decoded ?? String(unfolded[match.range])
            previousWasEncoded = decoded != nil
            cursor = match.range.upperBound
        }
        output += unfolded[cursor...]
        return output
    }

    private static func decodeWord(charset: String, encoding: String, text: String) -> String? {
        let name = charset.split(separator: "*").first.map(String.init) ?? charset
        guard let stringEncoding = Charsets.encoding(named: name) else { return nil }
        let bytes: Data?
        switch encoding.uppercased() {
        case "B":
            var padded = text
            padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
            bytes = Data(base64Encoded: padded)
        default:
            bytes = decodeQ(text)
        }
        guard let bytes else { return nil }
        return String(data: bytes, encoding: stringEncoding)
    }

    private static func decodeQ(_ text: String) -> Data? {
        var out = Data()
        var iterator = Array(text.utf8).makeIterator()
        while let byte = iterator.next() {
            switch byte {
            case UInt8(ascii: "_"):
                out.append(UInt8(ascii: " "))
            case UInt8(ascii: "="):
                guard let high = iterator.next(), let low = iterator.next(),
                      let value = UInt8(String(decoding: [high, low], as: UTF8.self), radix: 16) else { return nil }
                out.append(value)
            default:
                out.append(byte)
            }
        }
        return out
    }
}

/// Maps IANA charset names found in mail to Foundation encodings.
public enum Charsets {
    public static func encoding(named name: String) -> String.Encoding? {
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased()
        switch trimmed {
        case "utf-8", "utf8": return .utf8
        case "us-ascii", "ascii": return .ascii
        case "iso-8859-1", "latin1": return .isoLatin1
        default:
            #if canImport(Darwin)
            let cf = CFStringConvertIANACharSetNameToEncoding(trimmed as CFString)
            guard cf != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            #else
            return portable[trimmed].map { String.Encoding(rawValue: $0) }
            #endif
        }
    }

    /// The charsets mail uses most, by IANA name, as Foundation's encoding numbers, for systems without
    /// CoreFoundation's own table.
    static let portable: [String: UInt] = [
        "iso-8859-2": 9, "latin2": 9, "iso-8859-15": 0x8000_020F, "latin-9": 0x8000_020F,
        "windows-1250": 15, "windows-1251": 11, "windows-1252": 12, "windows-1253": 13, "windows-1254": 14,
        "cp1250": 15, "cp1251": 11, "cp1252": 12,
        "utf-16": 10, "utf-16be": 0x9000_0100, "utf-16le": 0x9400_0100,
        "shift_jis": 8, "shift-jis": 8, "sjis": 8, "euc-jp": 3, "iso-2022-jp": 21,
        "gb2312": 0x8000_0930, "gbk": 0x8000_0631, "gb18030": 0x8000_0632, "big5": 0x8000_0A03,
        "euc-kr": 0x8000_0940, "ks_c_5601-1987": 0x8000_0940, "koi8-r": 0x8000_0A02, "koi8-u": 0x8000_0A08,
        "iso-8859-5": 0x8000_0205, "iso-8859-7": 0x8000_0207, "iso-8859-9": 0x8000_0209,
    ]
}
