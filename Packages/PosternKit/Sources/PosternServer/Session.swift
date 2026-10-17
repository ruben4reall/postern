import Foundation
import MCP
import PosternApproval
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
    private let onCall: @Sendable (ToolCallReport) -> Void
    private let desk: ApprovalDesk?
    private let ledger: (any SendLedger)?
    private let clientName: @Sendable () -> String
    private let provenance = Provenance()

    /// - Parameter readiness: returns why Postern cannot serve yet (not configured, paused), or nil when it can.
    public init(
        transport: any Transport, backend: any MailBackend, version: String,
        policy: @escaping @Sendable () -> Policy, readiness: @escaping @Sendable () -> PosternError? = { nil },
        onCall: @escaping @Sendable (ToolCallReport) -> Void = { _ in },
        desk: ApprovalDesk? = nil, ledger: (any SendLedger)? = nil,
        clientName: @escaping @Sendable () -> String = { "MCP client" }
    ) {
        self.transport = transport
        self.backend = backend
        self.policy = policy
        self.readiness = readiness
        self.onCall = onCall
        self.desk = desk
        self.ledger = ledger
        self.clientName = clientName
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
        let onCall = self.onCall
        let context = SendContext(desk: desk, ledger: ledger, provenance: provenance, clientName: clientName)
        await server.withMethodHandler(ListTools.self) { _ in
            guard readiness() == nil, !policy().paused else { return ListTools.Result(tools: []) }
            return ListTools.Result(tools: ToolCatalog.tools(for: policy()))
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            let result = await Self.call(parameters, backend: backend, policy: policy(), readiness: readiness(), send: context)
            onCall(ToolCallReport(tool: parameters.name, result: result))
            return result
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

    struct SendContext: Sendable {
        let desk: ApprovalDesk?
        let ledger: (any SendLedger)?
        let provenance: Provenance
        let clientName: @Sendable () -> String
    }

    static func call(
        _ parameters: CallTool.Parameters, backend: any MailBackend, policy: Policy, readiness: PosternError?,
        send: SendContext
    ) async -> CallTool.Result {
        do {
            if let readiness { throw readiness }
            if policy.paused { throw PosternError(.paused, "The user has paused Postern. Nothing can be read until they resume it.") }
            guard let tool = ToolID(rawValue: parameters.name) else {
                throw PosternError(.invalidArgument, "Postern has no tool named \(parameters.name).")
            }
            guard policy.allows(tool) else {
                throw PosternError(.policyDisabled, "The user has not enabled \(tool.rawValue) in Postern.")
            }
            let arguments = parameters.arguments ?? [:]
            switch tool.tier {
            case .read:
                return try await ReadTools(backend: backend, policy: policy, provenance: send.provenance).call(tool, arguments)
            case .organize:
                return try await OrganizeTools(backend: backend, policy: policy).call(tool, arguments)
            case .draft, .send:
                guard let desk = send.desk, let ledger = send.ledger else {
                    throw PosternError(.policyDisabled, "\(tool.rawValue) is not available here.")
                }
                return try await SendTools(
                    backend: backend, policy: policy, desk: desk, ledger: ledger, provenance: send.provenance,
                    client: send.clientName()
                ).call(tool, arguments)
            case .delete:
                throw PosternError(.policyDisabled, "\(tool.rawValue) is not available in this version.")
            }
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

/// What the activity log keeps of one call: the tool, the outcome code and how many items it returned.
public struct ToolCallReport: Sendable, Equatable {
    public let tool: String
    public let outcome: String
    public let items: Int?

    public init(tool: String, outcome: String, items: Int?) {
        self.tool = String(tool.prefix(64))
        self.outcome = outcome
        self.items = items
    }

    init(tool: String, result: CallTool.Result) {
        var outcome = "ok"
        var items: Int?
        if case .object(let object)? = result.structuredContent {
            if case .object(let error)? = object["error"], case .string(let code)? = error["code"] {
                outcome = code
            } else if case .array(let list)? = object["messages"] {
                items = list.count
            } else if case .array(let list)? = object["mailboxes"] {
                items = list.count
            } else if object["id"] != nil {
                items = 1
            }
        }
        self.init(tool: tool, outcome: outcome, items: items)
    }
}
