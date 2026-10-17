/// Stable error codes a client can rely on, each with a sentence it can show to the user.
public enum PosternErrorCode: String, Codable, Sendable {
    case policyDisabled = "policy_disabled"
    case scopeHidden = "scope_hidden"
    case staleID = "stale_id"
    case notFound = "not_found"
    case bridgeUnreachable = "bridge_unreachable"
    case certificateMismatch = "certificate_mismatch"
    case notConfigured = "not_configured"
    case authenticationFailed = "authentication_failed"
    case parseFailed = "parse_failed"
    case invalidArgument = "invalid_argument"
    case tooLarge = "too_large"
    case paused
}

public struct PosternError: Error, Codable, Sendable, Equatable {
    public let code: PosternErrorCode
    public let message: String

    public init(_ code: PosternErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}
