import Foundation
import MCP
import PosternModel
import PosternPolicy

/// Saving an attachment: always into the Postern folder of Downloads, never to a path the client chooses.
struct AttachmentTools {
    let backend: any MailBackend
    let policy: Policy

    let renderer = UntrustedRenderer()

    /// The message and attachment number a call names, once the mailbox is known to be visible.
    private func target(_ arguments: [String: Value]) async throws -> (id: MessageID, index: Int) {
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
        return (id, index)
    }

    /// The text of an attachment, read in the parser's sandbox and marked as untrusted, like the email it came in.
    func read(_ arguments: [String: Value]) async throws -> CallTool.Result {
        let (id, index) = try await target(arguments)
        let maxChars: Int
        switch arguments["max_chars"] {
        case .int(let value)?: maxChars = min(max(value, 500), 100_000)
        case .double(let value)?: maxChars = min(max(Int(value), 500), 100_000)
        default: maxChars = 20_000
        }
        let content = try await backend.readAttachment(id, index: index, maxChars: maxChars)
        var notes = ["\(content.filename ?? "Attachment \(index)") (\(content.mimeType), \(content.size) bytes)"]
        if let pages = content.pages { notes.append("\(pages) page(s)") }
        if content.recognized { notes.append("text recognized on images: it may hold mistakes") }
        if content.truncated { notes.append("cut at \(maxChars) characters") }
        let body = content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(no text found)" : content.text
        let text = notes.joined(separator: ", ") + ".\n" + renderer.wrap(body, source: "attachment \(index) of \(id.opaque)")
        return CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            structuredContent: Optional<Value>.some(.object([
                "untrusted_filename": content.filename.map { .string(UntrustedRenderer.defuse($0)) } ?? .null,
                "mime_type": .string(content.mimeType), "size": .int(content.size), "kind": .string(content.kind.rawValue),
                "pages": content.pages.map(Value.int) ?? .null, "recognized": .bool(content.recognized),
                "truncated": .bool(content.truncated), "untrusted_text": .string(UntrustedRenderer.defuse(content.text)),
            ])),
            isError: false
        )
    }

    func save(_ arguments: [String: Value]) async throws -> CallTool.Result {
        let (id, index) = try await target(arguments)
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
