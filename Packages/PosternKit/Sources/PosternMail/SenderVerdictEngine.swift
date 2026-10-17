import Foundation
import PosternModel
import PosternText

/// Decides how far the sender of a message can be trusted, from what Proton recorded on delivery.
///
/// Only `Authentication-Results` headers that carry Proton's identity and sit above the first `Received` header
/// count: a receiving server prepends its results, so anything below was already in the message when it arrived
/// and may have been written by the sender.
public struct SenderVerdictEngine: Sendable {
    /// Confirmed on a real message in lot 1; kept in one place so a correction is one line.
    public static let authservID = "mail.protonmail.ch"

    public init() {}

    public func verdict(headers: [HeaderField], from: [Address]) -> SenderVerdict {
        var reasons: [String] = []
        var seenIDs: [String] = []
        var forged = false
        var results: [String: [String]] = [:]
        var reachedReceived = false
        var externalHop = false

        for field in headers {
            let name = field.name.lowercased()
            if name == "received" {
                reachedReceived = true
                if Self.isExternalHop(field.value) { externalHop = true }
                continue
            }
            guard name == "authentication-results" else { continue }
            let parsed = Self.parseAuthenticationResults(field.value)
            if !seenIDs.contains(parsed.id) { seenIDs.append(parsed.id) }
            guard parsed.id == Self.authservID else { continue }
            if reachedReceived {
                forged = true
                continue
            }
            for (method, result) in parsed.results { results[method, default: []].append(result) }
        }

        func best(_ method: String) -> String? {
            guard let values = results[method] else { return nil }
            if values.contains("pass") { return "pass" }
            return values.first
        }
        let spf = best("spf")
        let dkim = best("dkim")
        let dmarc = best("dmarc")
        let origin = headers.first { $0.name.lowercased() == "x-pm-origin" }?.value.lowercased()

        if forged { reasons.append("An Authentication-Results header claiming Proton was written by the sender.") }

        let level: SenderVerdict.Level
        if origin == "internal" && !externalHop {
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
