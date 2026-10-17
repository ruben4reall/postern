import Foundation
import LocalAuthentication
import Observation
import PosternBridge
import PosternModel
import PosternPolicy
import PosternVault

@MainActor @Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable { case detect, trust, signIn, allow, done }

    var step: Step = .detect
    var working = false
    var error: String?
    var bridgeVersion: String?
    var imap: PortIdentity?
    var smtp: PortIdentity?
    var username = ""
    var password = ""

    private let finish: () -> Void
    private let vault = CoreState.shared.vault

    init(finish: @escaping () -> Void) {
        self.finish = finish
    }

    func detect() async {
        working = true
        error = nil
        defer { working = false }
        do {
            let imap = try await BridgeProbe.inspect(port: 1143, service: .imap)
            let smtp = try await BridgeProbe.inspect(port: 1025, service: .smtp)
            guard imap.pin == smtp.pin else {
                error = "Bridge shows a different certificate on each port. Restart Bridge and try again."
                return
            }
            self.imap = imap
            self.smtp = smtp
            bridgeVersion = imap.greeting.firstMatch(of: /Proton Mail Bridge ([0-9.]+)/).map { String($0.1) }
            step = .trust
        } catch {
            self.error = "Proton Mail Bridge isn't answering on this Mac. Open Bridge, sign in, then try again."
        }
    }

    func trust() {
        step = .signIn
    }

    func connect() async {
        guard let imap, let smtp else { step = .detect; return }
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !password.isEmpty else {
            error = "Enter the username and password that Bridge shows for your account."
            return
        }
        working = true
        error = nil
        defer { working = false }
        let endpoint = BridgeEndpoint(imap: BridgePort(port: 1143, mode: imap.mode), smtp: BridgePort(port: 1025, mode: smtp.mode))
        let credentials = BridgeCredentials(username: name, password: password)
        let connection = IMAPConnection(endpoint: endpoint, pin: imap.pin, credentials: credentials)
        do {
            try await connection.open()
            await connection.close()
            try vault.write(endpoint, for: .bridgeEndpoint)
            try vault.write(imap.pin, for: .certificatePin)
            try vault.write(credentials, for: .bridgeCredentials)
            password = ""
            CoreState.shared.reload()
            step = .allow
        } catch BridgeError.authenticationFailed {
            error = "Bridge refused this username or password. Copy them again from Bridge."
        } catch BridgeError.certificateMismatch {
            error = "Bridge's certificate changed while setting up. Start again from the first step."
            step = .detect
        } catch {
            self.error = "Postern couldn't sign in to Bridge. Make sure Bridge is running and try again."
        }
    }

    func allowReading() async {
        error = nil
        let context = LAContext()
        var policy = LAPolicy.deviceOwnerAuthenticationWithBiometricsOrWatch
        if !context.canEvaluatePolicy(policy, error: nil) { policy = .deviceOwnerAuthentication }
        do {
            try await context.evaluatePolicy(policy, localizedReason: "let your MCP clients read your mail")
            try PolicyStore(vault: vault).save(.readOnly)
            CoreState.shared.reload()
            step = .done
        } catch let error as LAError where error.code == .userCancel || error.code == .appCancel {
            self.error = nil
        } catch {
            self.error = "Postern couldn't save this choice. Try again."
        }
    }

    func close() {
        finish()
    }
}
