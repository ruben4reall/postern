import Foundation

/// RFC 5322 dates, with the variations real mail carries.
public enum MailDate {
    private static let formats = [
        "EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss zzz",
        "d MMM yyyy HH:mm Z", "EEE, d MMM yy HH:mm:ss Z",
    ]

    public static func parse(_ value: String) -> Date? {
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
