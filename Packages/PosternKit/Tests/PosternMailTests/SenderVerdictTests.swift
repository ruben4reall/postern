import Testing
@testable import PosternMail
import PosternModel

@Suite struct SenderVerdictTests {
    let engine = SenderVerdictEngine()
    let sender = [Address(name: "Bank", email: "info@bank.example")]

    func fields(_ pairs: [(String, String)]) -> [HeaderField] { pairs.map { HeaderField(name: $0.0, value: $0.1) } }

    /// The layout Bridge serves, read on real messages: Proton's Received, the sender's Received headers, then one
    /// Authentication-Results header per method written by Proton, and Bridge's X-Pm headers last.
    func bridgeLayout(dmarc: String = "pass", extra: [(String, String)] = [], origin: String = "external") -> [HeaderField] {
        fields([
            ("Received", "from out-1.smtp.sender.example (out-1.smtp.sender.example [1.2.3.4]) by mailin042.protonmail.ch with ESMTPS"),
            ("Received", "from localhost (localhost [127.0.0.1]) by smtp.sender.example (Postfix)"),
            ("Authentication-Results", "mail.protonmail.ch; dmarc=\(dmarc) (p=reject dis=none) header.from=bank.example"),
            ("Authentication-Results", "mail.protonmail.ch; spf=pass smtp.mailfrom=bank.example"),
            ("Authentication-Results", "mail.protonmail.ch; arc=none smtp.remote-ip=1.2.3.4"),
            ("Authentication-Results", "mail.protonmail.ch; dkim=pass (2048-bit key) header.d=bank.example; dkim=pass header.d=esp.example"),
        ] + extra + [("X-Pm-Origin", origin), ("X-Pm-Spam-Action", "inbox")])
    }

    @Test func trustsTheBridgeLayout() {
        let verdict = engine.verdict(headers: bridgeLayout(), from: sender)
        #expect(verdict.level == .verified)
        #expect(verdict.dmarc == "pass" && verdict.spf == "pass" && verdict.dkim == "pass")
        #expect(!verdict.forgedHeaderSeen)
    }

    @Test func reportsAFailedDMARC() {
        #expect(engine.verdict(headers: bridgeLayout(dmarc: "fail"), from: sender).level == .failed)
    }

    @Test func catchesAResultTheSenderWroteUnderProtonsName() {
        // The sender's copy sits among its own headers; Proton's real result says fail.
        let forged = bridgeLayout(dmarc: "fail", extra: [("Authentication-Results", "mail.protonmail.ch; dmarc=pass header.from=bank.example")])
        let verdict = engine.verdict(headers: forged, from: sender)
        #expect(verdict.forgedHeaderSeen)
        #expect(verdict.level == .failed)
    }

    @Test func catchesAForgedCopyEvenWhenProtonAlsoSaysPass() {
        let forged = bridgeLayout(extra: [("Authentication-Results", "mail.protonmail.ch 1; dkim=pass header.d=bank.example")])
        let verdict = engine.verdict(headers: forged, from: sender)
        #expect(verdict.forgedHeaderSeen)
        #expect(verdict.level == .failed)
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
        #expect(engine.verdict(headers: bridgeLayout(origin: "internal"), from: sender).level != .internal)
    }

    @Test func readsTheXPmHeaderBridgeAppendsNotTheSendersCopy() {
        let headers = fields([("X-Pm-Origin", "internal")]) + bridgeLayout()
        let verdict = engine.verdict(headers: headers, from: sender)
        #expect(verdict.origin == "external")
        #expect(verdict.level == .verified)
    }

    @Test func flagsADisplayNameShowingAnotherAddress() {
        let verdict = engine.verdict(
            headers: [], from: [Address(name: "support@bank.example", email: "x@evil.example")]
        )
        #expect(verdict.reasons.contains { $0.contains("display name") })
    }
}
