import LocalAuthentication

/// Proof that the person at the Mac wants a change that gives apps more power.
enum Authenticator {
    enum Outcome: Equatable {
        case confirmed
        case cancelled
        /// No Touch ID or Apple Watch right now, and the password is not allowed.
        case unavailable
    }

    static func confirm(_ reason: String, allowPassword: Bool) async -> Outcome {
        let context = LAContext()
        var policy = LAPolicy.deviceOwnerAuthenticationWithBiometricsOrWatch
        if !context.canEvaluatePolicy(policy, error: nil) {
            // A Mac without any biometric hardware has only its password; elsewhere the user must have allowed it.
            guard allowPassword || context.biometryType == .none else { return .unavailable }
            policy = .deviceOwnerAuthentication
        }
        do {
            return try await context.evaluatePolicy(policy, localizedReason: reason) ? .confirmed : .cancelled
        } catch {
            return .cancelled
        }
    }
}
