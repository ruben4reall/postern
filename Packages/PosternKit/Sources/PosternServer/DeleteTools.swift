import Foundation
import MCP
import PosternApproval
import PosternModel
import PosternPolicy

/// Moving to Trash and erasing. Each call waits for the user on the panel and Touch ID; the Bridge layer acts only
/// on an `ApprovedDeletion`.
struct DeleteTools {
    let backend: any MailBackend
    let policy: Policy
    let desk: ApprovalDesk
    let client: String

    func call(_ tool: ToolID, _ arguments: [String: Value]) async throws -> CallTool.Result {
        let ids = try await visibleIDs(arguments)
        let permanent = tool == .deletePermanently
        if permanent {
            for id in ids {
                let name = try await backend.displayName(ofRawMailbox: id.mailbox)
                guard name == "Trash" || name == "Spam" else {
                    throw PosternError(.invalidArgument, "Only messages already in Trash or Spam can be erased. Use trash_messages first.")
                }
            }
        }
        let items = try await backend.deletionItems(ids)
        let request = DeletionRequest(tool: tool.rawValue, client: client, items: items, permanent: permanent)
        switch await desk.reviewDeletion(request) {
        case .approved(let approved):
            let report = permanent ? try await backend.erase(approved) : try await backend.trash(approved)
            var text = permanent
                ? "The user approved with Touch ID; \(report.done.count) message(s) erased for good."
                : "The user approved with Touch ID; \(report.done.count) message(s) moved to Trash."
            if !report.failed.isEmpty {
                text += " Not done for \(report.failed.count): " + Set(report.failed.map(\.reason)).sorted().joined(separator: " ")
            }
            if !report.verified { text += " Bridge accepted it, but Postern could not see every change yet." }
            return CallTool.Result(
                content: [.text(text: text, annotations: nil, _meta: nil)],
                structuredContent: Optional<Value>.some(.object([
                    "count": .int(report.done.count),
                    "messages": .array(report.done.map { .object(["id": .string($0.opaque)]) }),
                    "verified": .bool(report.verified),
                ])),
                isError: false
            )
        case .rejected(let reason):
            throw PosternError(.approvalRejected, "The user refused this deletion" + (reason.map { ": \($0)" } ?? "."))
        case .notAuthenticated:
            throw PosternError(.approvalRejected, "The user did not confirm with Touch ID, so nothing was deleted.")
        case .expired:
            throw PosternError(.approvalTimeout, "The user did not answer within two minutes, so nothing was deleted.")
        }
    }

    private func visibleIDs(_ arguments: [String: Value]) async throws -> [MessageID] {
        guard case .array(let values)? = arguments["ids"] else {
            throw PosternError(.invalidArgument, "ids is required: message ids from search_messages.")
        }
        let texts = values.compactMap { if case .string(let text) = $0 { text } else { nil } }
        guard !texts.isEmpty, texts.count <= 100 else { throw PosternError(.invalidArgument, "Between 1 and 100 ids per call.") }
        let ids = texts.compactMap(MessageID.init(opaque:))
        guard ids.count == texts.count else { throw PosternError(.invalidArgument, "Some ids are not Postern message ids.") }
        for mailbox in Set(ids.map(\.mailbox)) {
            guard !policy.isHidden(try await backend.displayName(ofRawMailbox: mailbox)) else {
                throw PosternError(.scopeHidden, "The user has hidden this mailbox from Postern.")
            }
        }
        return Array(Dictionary(ids.map { ($0.opaque, $0) }, uniquingKeysWith: { first, _ in first }).values)
            .sorted { $0.opaque < $1.opaque }
    }
}
