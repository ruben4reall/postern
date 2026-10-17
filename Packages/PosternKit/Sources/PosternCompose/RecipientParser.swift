import Foundation
import PosternModel

/// Reads the recipients a client gives: `anna@example.com` or `Anna <anna@example.com>`.
public enum RecipientParser {
    public static func parse(_ text: String) -> Address? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
            let email = String(trimmed[trimmed.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            let name = String(trimmed[..<open]).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            return Address(name: name.isEmpty ? nil : name, email: email)
        }
        return trimmed.isEmpty ? nil : Address(name: nil, email: trimmed)
    }
}
