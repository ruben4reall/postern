import CryptoKit
import Foundation
import NIOCore
import NIOSSL

/// Records what the peer presented, so a failed handshake can say whether the certificate changed.
final class PeerCertificateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var hash: String?

    var seenHash: String? { lock.withLock { hash } }

    func record(_ value: String) { lock.withLock { hash = value } }
}

enum PinnedTLS {
    static func sha256(_ certificate: NIOSSLCertificate) -> String? {
        guard let der = try? certificate.toDERBytes() else { return nil }
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// A client handler that accepts exactly one certificate: the pinned one. No hostname or CA check applies;
    /// the pin is the whole trust decision. When `pin` is nil the handler accepts anything and only records the
    /// hash: used once, by the onboarding probe, which never sends a credential.
    static func clientHandler(pin: CertificatePin?, recorder: PeerCertificateRecorder) throws -> NIOSSLClientHandler {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = .noHostnameVerification
        configuration.minimumTLSVersion = .tlsv12
        let context = try NIOSSLContext(configuration: configuration)
        let expected = pin?.sha256Hex
        return try NIOSSLClientHandler(context: context, serverHostname: nil) { certificates, promise in
            guard let leaf = certificates.first, let hash = sha256(leaf) else {
                promise.succeed(.failed)
                return
            }
            recorder.record(hash)
            if let expected {
                promise.succeed(hash == expected ? .certificateVerified : .failed)
            } else {
                promise.succeed(.certificateVerified)
            }
        }
    }
}
