import Foundation
import PosternPlatform
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import WinSDK
#endif

// postern-mcp: what MCP apps launch. It holds no secret and makes no decision: it carries JSON-RPC lines between
// its standard input and output and this user's Postern core, which it starts when none answers.

#if !os(Windows)
signal(SIGPIPE, SIG_IGN)
#endif

let output = NSLock()

func emit(_ data: Data) {
    output.withLock {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

/// Answers the requests the app is waiting for when the core cannot be reached, so the app shows a reason.
final class Pending: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [Any] = []

    func note(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["method"] != nil, let id = object["id"] else { return }
        lock.withLock { ids.append(id) }
    }

    func failAll(_ message: String) {
        for id in lock.withLock({ ids }) {
            let error: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": message]]
            if let data = try? JSONSerialization.data(withJSONObject: error) { emit(data) }
        }
    }
}

let unreachable = "Postern is not running or not set up. Open Postern, or run `postern setup`, then try again."

/// The name of the program that launched the relay, such as claude, cursor or code.
func parentName() -> String {
    #if os(Linux)
    let name = (try? String(contentsOfFile: "/proc/\(getppid())/comm", encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return name.flatMap { $0.isEmpty ? nil : $0 } ?? "MCP client"
    #elseif os(Windows)
    return WindowsProcess.parentName() ?? "MCP client"
    #else
    var buffer = [CChar](repeating: 0, count: 256)
    let length = proc_name(getppid(), &buffer, UInt32(buffer.count))
    guard length > 0 else { return "MCP client" }
    return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    #endif
}

/// Connects to the core, starting it once when nothing answers.
func connectToCore() -> LocalConnection? {
    if let connection = try? LocalChannel.connect() { return connection }
    guard let core = PosternPaths.program("postern-core") else { return nil }
    CoreStarter.start(core)
    for _ in 0..<50 {
        Thread.sleep(forTimeInterval: 0.1)
        if let connection = try? LocalChannel.connect() { return connection }
    }
    return nil
}

let pending = Pending()
guard let connection = connectToCore() else {
    // Answer what the app asks, then leave: the app shows the reason.
    while let line = readLine(strippingNewline: true) {
        pending.note(Data(line.utf8))
        pending.failAll(unreachable)
        break
    }
    exit(1)
}

let hello = try ControlWire.encoder.encode(ControlWire.Hello(postern: .relay, client: parentName()))
connection.write(hello)

Thread.detachNewThread {
    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty else { continue }
        let data = Data(line.utf8)
        pending.note(data)
        if !connection.write(data) { break }
    }
    // The app closed stdin: the session is over.
    connection.close()
    exit(0)
}

while let message = connection.readLine() {
    emit(message)
}
pending.failAll(unreachable)
exit(1)
