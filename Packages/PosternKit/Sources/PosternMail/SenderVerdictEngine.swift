import Foundation
import PosternModel
import PosternText

/// Decides how far the sender of a message can be trusted, from what Proton recorded on delivery.
///
/// Bridge rebuilds the header block, so position proves nothing: on real messages, Proton's own `Received` comes
/// first, then the sender's `Received` headers, then one `Authentication-Results` header per method (dmarc, spf, arc,
/// dkim) written by Proton, and Bridge's `X-Pm-*` headers last. Proton writes each method exactly once, so a second
/// header for the same method under Proton's name can only have come from the sender: the message is then treated as
/// failed and the forgery reported.
public struct SenderVerdictEngine: Sendable {
    /// Confirmed on real messages served by Bridge 03.27.01 (17.10.2026).
    public static let authservID = "mail.protonmail.ch"

    public init() {}

    public func verdict(headers: [HeaderField], from: [Address]) -> SenderVerdict {
        var reasons: [String] = []
        var seenIDs: [String] = []
        var results: [String: [String]] = [:]
        var headersPerMethod: [String: Int] = [:]
        var externalHop = false

        for field in headers {
            let name = field.name.lowercased()
            if name == "received" {
                if Self.isExternalHop(field.value) { externalHop = true }
                continue
            }
            guard name == "authentication-results" else { continue }
            let parsed = Self.parseAuthenticationResults(field.value)
            if !seenIDs.contains(parsed.id) { seenIDs.append(parsed.id) }
            guard parsed.id == Self.authservID else { continue }
            for method in Set(parsed.results.map(\.0)) { headersPerMethod[method, default: 0] += 1 }
            for (method, result) in parsed.results { results[method, default: []].append(result) }
        }
        let forged = headersPerMethod.values.contains { $0 > 1 }

        func best(_ method: String) -> String? {
            guard let values = results[method] else { return nil }
            if values.contains("pass") { return "pass" }
            return values.first
        }
        let spf = best("spf")
        let dkim = best("dkim")
        let dmarc = best("dmarc")
        // Bridge appends its X-Pm headers after the message's own: the last one is Bridge's.
        let origin = headers.last { $0.name.lowercased() == "x-pm-origin" }?.value.lowercased()
            .trimmingCharacters(in: .whitespaces)

        if forged { reasons.append("An Authentication-Results header claiming Proton was written by the sender.") }

        let level: SenderVerdict.Level
        if forged {
            level = .failed
        } else if origin == "internal" && !externalHop {
            level = .internal
        } else if dmarc == "pass" {
            level = .verified
        } else if dmarc == "fail" || (Self.isFailure(spf) && Self.isFailure(dkim)) {
            level = .failed
            reasons.append("The sender's domain did not authenticate this message.")
        } else {
            level = .unverified
            reasons.append("No authentication result proves the sender's domain.")
        }

        for address in from {
            if let name = address.name, let shown = name.firstMatch(of: #/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/#),
               String(shown.0).lowercased() != address.email.lowercased() {
                reasons.append("The display name shows another address (\(shown.0)) than the real sender.")
            }
            let domain = address.email.split(separator: "@").last.map(String.init) ?? ""
            if domain.split(separator: ".").contains(where: { $0.hasPrefix("xn--") })
                || domain.unicodeScalars.contains(where: { !$0.isASCII }) {
                reasons.append("The sender's domain uses look-alike characters.")
            }
        }

        return SenderVerdict(
            level: level, spf: spf, dkim: dkim, dmarc: dmarc, origin: origin, reasons: reasons,
            forgedHeaderSeen: forged, authservIDsSeen: seenIDs
        )
    }

    static func isFailure(_ result: String?) -> Bool {
        guard let result else { return false }
        return ["fail", "softfail", "none", "permerror", "temperror", "neutral"].contains(result)
    }

    /// A `Received` header whose `from` part names a host outside Proton.
    static func isExternalHop(_ value: String) -> Bool {
        let lowered = value.lowercased()
        guard let fromRange = lowered.range(of: "from ") else { return false }
        let afterFrom = lowered[fromRange.upperBound...]
        let fromPart = afterFrom.range(of: " by ").map { afterFrom[..<$0.lowerBound] } ?? afterFrom
        return !(fromPart.contains("protonmail.ch") || fromPart.contains("proton.me") || fromPart.contains("protonmail.com"))
    }

    static func parseAuthenticationResults(_ value: String) -> (id: String, results: [(String, String)]) {
        let withoutComments = value.replacing(#/\([^()]*\)/#, with: "")
        let sections = withoutComments.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        // The identity may carry a version number: "mail.protonmail.ch 1".
        let id = sections.first?.split(separator: " ").first.map { String($0).lowercased() } ?? ""
        var results: [(String, String)] = []
        for section in sections.dropFirst() {
            guard let first = section.split(separator: " ").first else { continue }
            let pair = first.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            results.append((pair[0].lowercased(), pair[1].lowercased()))
        }
        return (id, results)
    }
}
