import Foundation
import PosternMail
import PosternModel

// PosternParser.xpc: decodes and sanitizes raw messages. It runs in the App Sandbox with no entitlement at all,
// so a message crafted to exploit the parser lands in a process with no network, no Keychain and no files.

final class Parser: NSObject, ParserXPC {
    func sanitize(_ raw: Data, maxChars: Int, reply: @escaping @Sendable (Data?, String?) -> Void) {
        do {
            let message = try MessageSanitizer.sanitize(raw: raw, maxChars: maxChars)
            reply(try JSONEncoder().encode(message), nil)
        } catch {
            reply(nil, String(describing: error))
        }
    }
}

extension Parser {
    func attachment(_ raw: Data, index: Int, reply: @escaping @Sendable (Data?, String?, String?, String?) -> Void) {
        do {
            let file = try MessageSanitizer.attachment(raw: raw, index: index)
            reply(file.data, file.filename, file.mimeType, nil)
        } catch {
            reply(nil, nil, nil, String(describing: error))
        }
    }
}

final class Delegate: NSObject, NSXPCListenerDelegate {
    let parser = Parser()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(PosternXPC.teamRequirement)
        connection.exportedInterface = NSXPCInterface(with: ParserXPC.self)
        connection.exportedObject = parser
        connection.resume()
        return true
    }
}

let delegate = Delegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
