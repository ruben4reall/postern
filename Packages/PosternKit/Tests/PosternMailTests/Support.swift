import Foundation

/// Builds a raw message with CRLF line endings from a readable multi-line literal.
func eml(_ text: String) -> Data {
    Data(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8)
}
