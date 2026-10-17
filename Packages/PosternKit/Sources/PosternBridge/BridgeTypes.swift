import Foundation

/// How a Bridge port starts TLS. Bridge lets the user pick either mode for each port.
public enum TLSMode: String, Codable, Sendable {
    /// Plain greeting, then `STARTTLS`.
    case startTLS
    /// TLS from the first byte (Bridge calls it "SSL").
    case implicit
}

public struct BridgePort: Codable, Sendable, Equatable {
    public var port: Int
    public var mode: TLSMode

    public init(port: Int, mode: TLSMode) {
        self.port = port
        self.mode = mode
    }
}

public struct BridgeEndpoint: Codable, Sendable, Equatable {
    /// Always the loopback address: Postern never talks to Bridge over a network.
    public var host = "127.0.0.1"
    public var imap: BridgePort
    public var smtp: BridgePort

    public init(imap: BridgePort, smtp: BridgePort) {
        self.imap = imap
        self.smtp = smtp
    }
}

/// SHA-256 of the DER certificate Bridge presented when the user trusted it.
public struct CertificatePin: Codable, Sendable, Equatable {
    public let sha256Hex: String

    public init(sha256Hex: String) {
        self.sha256Hex = sha256Hex.lowercased().replacingOccurrences(of: ":", with: "")
    }

    /// `7F:21:93:...`, the form Bridge and openssl show.
    public var display: String {
        stride(from: 0, to: sha256Hex.count, by: 2).map { offset -> String in
            let start = sha256Hex.index(sha256Hex.startIndex, offsetBy: offset)
            return String(sha256Hex[start..<sha256Hex.index(start, offsetBy: 2)]).uppercased()
        }.joined(separator: ":")
    }
}

public struct BridgeCredentials: Codable, Sendable, Equatable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public enum BridgeError: Error, Equatable, Sendable {
    case unreachable
    case notBridge(String)
    case certificateMismatch(actual: String)
    case starttlsRefused
    case tlsFailed(String)
    case authenticationFailed
    case commandFailed(String)
    case timeout
    case mailboxNotFound(String)
    case staleUIDValidity
    case tooLarge
}
