import Foundation

/// Wraps text that came from an email so a client can tell data from instructions.
///
/// The markers carry a random nonce, fresh for every response: a sender cannot predict it, so text inside an
/// email cannot close the envelope early. Any marker-like sequence in the content is defused as well.
public struct UntrustedRenderer: Sendable {
    public let nonce: String

    public init(nonce: String = UntrustedRenderer.randomNonce()) {
        self.nonce = nonce
    }

    public static func randomNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    public static func defuse(_ text: String) -> String {
        text.replacingOccurrences(of: "<<postern", with: "< <postern")
    }

    public func wrap(_ text: String, source: String) -> String {
        "<<postern-untrusted:\(nonce) source=\"\(source)\">>\n\(Self.defuse(text))\n<<postern-end:\(nonce)>>"
    }
}
