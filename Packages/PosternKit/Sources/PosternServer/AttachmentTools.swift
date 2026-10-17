import Foundation
import MCP
import PosternModel
import PosternPolicy

/// Saving an attachment: always into the Postern folder of Downloads, never to a path the client chooses.
struct AttachmentTools {
    let backend: any MailBackend
    let policy: Policy

    func save(_ arguments: [String: Value]) async throws -> CallTool.Result {
        guard case .string(let text)? = arguments["message_id"], let id = MessageID(opaque: text) else {
            throw PosternError(.invalidArgument, "message_id is required: an id from search_messages.")
        }
        let index: Int
        switch arguments["index"] {
        case .int(let value)?: index = value
        case .double(let value)?: index = Int(value)
        default: throw PosternError(.invalidArgument, "index is required: the attachment number from get_message.")
        }
        guard !policy.isHidden(try await backend.displayName(ofRawMailbox: id.mailbox)) else {
            throw PosternError(.scopeHidden, "The user has hidden this mailbox from Postern.")
        }
        let saved = try await backend.saveAttachment(id, index: index)
        return CallTool.Result(
            content: [.text(text: "Saved \(saved.filename) (\(saved.size) bytes) to \(saved.path). macOS marks it as downloaded, so it is checked before it opens.", annotations: nil, _meta: nil)],
            structuredContent: Optional<Value>.some(.object([
                "path": .string(saved.path), "filename": .string(UntrustedRenderer.defuse(saved.filename)),
                "mime_type": .string(saved.mimeType), "size": .int(saved.size), "sha256": .string(saved.sha256),
            ])),
            isError: false
        )
    }
}
