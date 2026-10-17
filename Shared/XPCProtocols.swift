import Foundation

/// Names and checks shared by the three processes.
enum PosternXPC {
    static let coreMachService = "D8HG34L8XK.ch.rubencatalao.postern.core"
    static let parserService = "ch.rubencatalao.postern.parser"
    /// Every XPC peer must be signed by Postern's team, in both directions.
    static let teamRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"D8HG34L8XK\""
}

/// Exported by the core app to each relay.
@objc protocol CoreXPC {
    func hello(clientName: String, reply: @escaping @Sendable (Bool) -> Void)
    /// One JSON-RPC message from the MCP client, as read on the relay's stdin.
    func deliver(_ message: Data)
}

/// Exported by the relay back to the core.
@objc protocol RelayXPC {
    /// One JSON-RPC message for the MCP client, written on the relay's stdout.
    func receive(_ message: Data)
}

/// Exported by the sandboxed parser service.
@objc protocol ParserXPC {
    /// Returns a JSON-encoded `SanitizedMessage`, or an error message.
    func sanitize(_ raw: Data, maxChars: Int, reply: @escaping @Sendable (Data?, String?) -> Void)
    /// Returns the decoded bytes, file name and type of attachment `index`, or an error message.
    func attachment(_ raw: Data, index: Int, reply: @escaping @Sendable (Data?, String?, String?, String?) -> Void)
}
