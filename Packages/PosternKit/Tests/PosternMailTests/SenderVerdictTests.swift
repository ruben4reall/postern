import Testing
@testable import PosternMail
import PosternModel

@Suite struct SenderVerdictTests {
    let engine = SenderVerdictEngine()
    let sender = [Address(name: "Bank", email: "info@bank.example")]

    func fields(_ pairs: [(String, String)]) -> [HeaderField] { pairs.map { HeaderField(name: $0.0, value: $0.1) } }

    @Test func trustsProtonResultsAboveTheFirstReceived() {
        let verdict = engine.verdict(headers: fields([
            ("Authentication-Results", "mail.protonmail.ch; dkim=pass (2048-bit key) header.d=bank.example"),
            ("Authentication-Results", "mail.protonmail.ch; spf=pass smtp.mailfrom=bank.example"),
            ("Authentication-Results", "mail.protonmail.ch; dmarc=pass (p=reject dis=none) header.from=bank.example"),
            ("Received", "from mx.bank.example (mx.bank.example [1.2.3.4]) by mailin.protonmail.ch with ESMTPS"),
        ]), from: sender)
        #expect(verdict.level == .verified)
        #expect(verdict.dmarc == "pass")
        #expect(!verdict.forgedHeaderSeen)
    }

    @Test func ignoresAndFlagsResultsForgedBelowReceived() {
        let verdict = engine.verdict(headers: fields([
            ("Authentication-Results", "mail.protonmail.ch; dmarc=fail header.from=bank.example"),
            ("Received", "from evil.example by mailin.protonmail.ch with ESMTPS"),
            ("Authentication-Results", "mail.protonmail.ch; dmarc=pass header.from=bank.example"),
        ]), from: sender)
        #expect(verdict.level == .failed)
        #expect(verdict.forgedHeaderSeen)
    }

    @Test func ignoresResultsFromOtherServers() {
        let verdict = engine.verdict(headers: fields([
            ("Authentication-Results", "mx.google.com; dmarc=pass"),
            ("Received", "from evil.example by mailin.protonmail.ch"),
        ]), from: sender)
        #expect(verdict.level == .unverified)
        #expect(verdict.authservIDsSeen == ["mx.google.com"])
    }

    @Test func recognisesInternalMailOnlyWithoutAnExternalHop() {
        let insider = engine.verdict(headers: fields([("X-Pm-Origin", "internal")]), from: sender)
        #expect(insider.level == .internal)
        let spoofed = engine.verdict(headers: fields([
            ("Received", "from evil.example by mailin.protonmail.ch"), ("X-Pm-Origin", "internal"),
        ]), from: sender)
        #expect(spoofed.level != .internal)
    }

    @Test func flagsADisplayNameShowingAnotherAddress() {
        let verdict = engine.verdict(
            headers: [], from: [Address(name: "support@bank.example", email: "x@evil.example")]
        )
        #expect(verdict.reasons.contains { $0.contains("display name") })
    }
}
