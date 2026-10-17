import Darwin
import Foundation

// postern-mcp: what MCP clients launch. It holds no secret and makes no decision: it carries JSON-RPC lines
// between stdin/stdout and the Postern app over XPC, and both sides check each other's code signature.

let output = DispatchQueue(label: "ch.rubencatalao.postern.mcp.stdout")

func write(_ data: Data) {
    output.sync {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

/// Answers a request the client is waiting for when the app cannot be reached, so the client shows a reason.
final class PendingRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [Any] = []

    func note(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["method"] != nil, let id = object["id"] else { return }
        lock.withLock { ids.append(id) }
    }

    func failAll(_ message: String) {
        let pending = lock.withLock { ids }
        for id in pending {
            let error: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": message]]
            if let data = try? JSONSerialization.data(withJSONObject: error) { write(data) }
        }
    }
}

final class Receiver: NSObject, RelayXPC {
    func receive(_ message: Data) { write(message) }
}

func parentName() -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    let length = proc_name(getppid(), &buffer, UInt32(buffer.count))
    guard length > 0 else { return "MCP client" }
    return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

let pending = PendingRequests()
let unreachable = "Postern is not running or not set up. Open Postern from your Applications folder, then try again."

let connection = NSXPCConnection(machServiceName: PosternXPC.coreMachService, options: [])
connection.setCodeSigningRequirement(PosternXPC.teamRequirement)
connection.remoteObjectInterface = NSXPCInterface(with: CoreXPC.self)
connection.exportedInterface = NSXPCInterface(with: RelayXPC.self)
connection.exportedObject = Receiver()
connection.interruptionHandler = { @Sendable in
    pending.failAll(unreachable)
    exit(1)
}
connection.invalidationHandler = { @Sendable in
    pending.failAll(unreachable)
    exit(1)
}
connection.resume()

let core = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in
    pending.failAll(unreachable)
    exit(1)
} as! CoreXPC

core.hello(clientName: parentName()) { @Sendable _ in }

DispatchQueue.global(qos: .userInitiated).async {
    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty else { continue }
        let data = Data(line.utf8)
        pending.note(data)
        core.deliver(data)
    }
    // The client closed stdin: the session is over.
    exit(0)
}

dispatchMain()
