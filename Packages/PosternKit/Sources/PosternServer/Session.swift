import Foundation
import MCP
import PosternModel
import PosternPolicy

/// One MCP client connected through the relay. The policy is read on every call, so a switch turned off in the
/// app takes effect immediately, and the tool list is pushed again when it changes.
public actor Session {
    public static let serverName = "postern"

    private let server: Server
    private let transport: any Transport
    private let backend: any MailBackend
    private let policy: @Sendable () -> Policy
    private let readiness: @Sendable () -> PosternError?

    /// - Parameter readiness: returns why Postern cannot serve yet (not configured, paused), or nil when it can.
    public init(
        transport: any Transport, backend: any MailBackend, version: String,
        policy: @escaping @Sendable () -> Policy, readiness: @escaping @Sendable () -> PosternError? = { nil }
    ) {
        self.transport = transport
        self.backend = backend
        self.policy = policy
        self.readiness = readiness
        self.server = Server(
            name: Self.serverName, version: version, title: "Postern",
            instructions: ServerInstructions.text,
            capabilities: Server.Capabilities(tools: .init(listChanged: true))
        )
    }

    public func start() async throws {
        let policy = self.policy
        let readiness = self.readiness
        let backend = self.backend
        await server.withMethodHandler(ListTools.self) { _ in
            guard readiness() == nil else { return ListTools.Result(tools: []) }
            return ListTools.Result(tools: ToolCatalog.tools(for: policy()))
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            await Self.call(parameters, backend: backend, policy: policy(), readiness: readiness())
        }
        try await server.start(transport: transport)
    }

    public func stop() async {
        await server.stop()
    }

    /// Tells the client to fetch the tool list again.
    public func toolsChanged() async {
        try? await server.notify(ToolListChangedNotification.message())
    }

    static func call(
        _ parameters: CallTool.Parameters, backend: any MailBackend, policy: Policy, readiness: PosternError?
    ) async -> CallTool.Result {
        do {
            if let readiness { throw readiness }
            guard let tool = ToolID(rawValue: parameters.name) else {
                throw PosternError(.invalidArgument, "Postern has no tool named \(parameters.name).")
            }
            guard policy.allows(tool) else {
                throw PosternError(.policyDisabled, "The user has not enabled \(tool.rawValue) in Postern.")
            }
            return try await ReadTools(backend: backend, policy: policy).call(tool, parameters.arguments ?? [:])
        } catch let error as PosternError {
            return failure(error)
        } catch {
            return failure(PosternError(.parseFailed, "Postern could not complete this request."))
        }
    }

    static func failure(_ error: PosternError) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: "\(error.code.rawValue): \(error.message)", annotations: nil, _meta: nil)],
            structuredContent: Optional<Value>.some(.object(["error": .object([
                "code": .string(error.code.rawValue), "message": .string(error.message),
            ])])),
            isError: true
        )
    }
}
