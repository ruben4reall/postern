/// Removes characters a reader cannot see but a model reads: the usual carriers of hidden instructions.
public enum UnicodeCleaner {
    /// - Parameter keepNewlines: when false, line breaks and tabs become spaces (for single-line fields).
    public static func clean(_ text: String, keepNewlines: Bool = true) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            let value = scalar.value
            switch value {
            case 0x0A, 0x2028, 0x2029:
                out.append(keepNewlines ? "\n" : " ")
            case 0x09:
                out.append(keepNewlines ? "\t" : " ")
            case 0x0D:
                // A CR followed by LF is one line break; a lone CR becomes one.
                if index + 1 < scalars.count, scalars[index + 1].value == 0x0A { continue }
                out.append(keepNewlines ? "\n" : " ")
            case 0x200D:
                if isEmoji(out.last) && isEmoji(index + 1 < scalars.count ? scalars[index + 1] : nil) {
                    out.append(scalar)
                }
            case 0xFE00...0xFE0F, 0xE0100...0xE01EF:
                if let last = out.last, !isVariationSelector(last) { out.append(scalar) }
            default:
                if !isInvisible(value) { out.append(scalar) }
            }
        }
        return String(out)
    }

    private static func isInvisible(_ value: UInt32) -> Bool {
        switch value {
        case 0x00...0x1F, 0x7F...0x9F: true                     // C0 and C1 controls (tab, LF, CR handled above)
        case 0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180E, 0x3164, 0xFFA0: true
        case 0x200B...0x200F, 0x202A...0x202E: true             // zero-width and bidi embedding
        case 0x2060...0x2064, 0x2066...0x2069, 0x206A...0x206F: true
        case 0xFEFF, 0xFFF9...0xFFFB: true
        case 0xE0000...0xE007F: true                            // tag characters
        default: false
        }
    }

    private static func isVariationSelector(_ scalar: Unicode.Scalar) -> Bool {
        (0xFE00...0xFE0F).contains(scalar.value) || (0xE0100...0xE01EF).contains(scalar.value)
    }

    private static func isEmoji(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return false }
        return scalar.value >= 0x2000 && (scalar.properties.isEmoji || isVariationSelector(scalar))
    }
}
