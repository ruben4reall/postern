import Foundation

/// Names and checks shared by the three processes.
enum PosternXPC {
    static let coreMachService = "D8HG34L8XK.ch.rubencatalao.postern.core"
    /// The app's window service. Opening Postern from the Finder or the Dock starts a second copy, which asks the copy
    /// launchd runs to show its window and quits, so there is only ever one Postern.
    static let appMachService = "D8HG34L8XK.ch.rubencatalao.postern.app"
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

/// Exported by the core app to a copy of itself the user opened.
@objc protocol AppXPC {
    /// The core's process id, so the opener can hand it the focus.
    func processIdentifier(reply: @escaping @Sendable (Int32) -> Void)
    func showWindow(reply: @escaping @Sendable (Bool) -> Void)
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
