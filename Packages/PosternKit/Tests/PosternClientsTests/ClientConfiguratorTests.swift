import Foundation
import Testing
@testable import PosternClients

@Suite struct ClientConfiguratorTests {
    let relay = "/Applications/Postern.app/Contents/Helpers/postern-mcp"
    let name = "proton-mail-postern"

    func json(_ data: Data?) throws -> [String: Any] {
        let bytes = try #require(data)
        return try #require(JSONSerialization.jsonObject(with: bytes, options: .json5Allowed) as? [String: Any])
    }

    @Test func addsPosternToClaudeCodeAndKeepsEverythingElse() throws {
        let original = Data(#"{"numStartups":42,"mcpServers":{"other":{"type":"http","url":"https://x.example"}},"projects":{"/a":{"x":1}}}"#.utf8)
        #expect(ClientConfigurator.status(of: original, kind: .claudeCode, relayPath: relay) == .notConnected)
        let updated = try json(try ClientConfigurator.connecting(original, kind: .claudeCode, relayPath: relay))
        #expect(updated["numStartups"] as? Int == 42)
        #expect((updated["projects"] as? [String: Any])?["/a"] != nil)
        let servers = try #require(updated["mcpServers"] as? [String: Any])
        #expect((servers["other"] as? [String: Any])?["url"] as? String == "https://x.example")
        let postern = try #require(servers[name] as? [String: Any])
        #expect(postern["type"] as? String == "stdio")
        #expect(postern["command"] as? String == relay)
    }

    @Test func connectingTwiceChangesNothing() throws {
        let once = try ClientConfigurator.connecting(Data("{}".utf8), kind: .claudeDesktop, relayPath: relay)
        #expect(ClientConfigurator.status(of: once, kind: .claudeDesktop, relayPath: relay) == .connected)
        #expect(try ClientConfigurator.connecting(once, kind: .claudeDesktop, relayPath: relay) == nil)
    }

    @Test func pointsAnOldEntryAtTheNewPath() throws {
        let old = try ClientConfigurator.connecting(nil, kind: .claudeCode, relayPath: "/old/postern-mcp")
        #expect(ClientConfigurator.status(of: old, kind: .claudeCode, relayPath: relay) == .connectedElsewhere("/old/postern-mcp"))
        let moved = try json(try ClientConfigurator.connecting(old, kind: .claudeCode, relayPath: relay))
        #expect(((moved["mcpServers"] as? [String: Any])?[name] as? [String: Any])?["command"] as? String == relay)
    }

    @Test func refusesAFileThatIsNotJSON() {
        #expect(throws: ClientConfiguratorError.unreadable) {
            try ClientConfigurator.connecting(Data("not json".utf8), kind: .claudeCode, relayPath: relay)
        }
    }

    @Test func addsASectionToCodexOnce() throws {
        let original = Data("model = \"gpt\"\n\n[mcp_servers.other]\ncommand = \"x\"\n".utf8)
        #expect(ClientConfigurator.status(of: original, kind: .codex, relayPath: relay) == .notConnected)
        let updated = try #require(try ClientConfigurator.connecting(original, kind: .codex, relayPath: relay))
        let text = String(decoding: updated, as: UTF8.self)
        #expect(text.hasPrefix("model = \"gpt\"\n\n[mcp_servers.other]\ncommand = \"x\"\n"))
        #expect(text.contains("[mcp_servers.proton-mail-postern]\ncommand = \"\(relay)\"\n"))
        #expect(ClientConfigurator.status(of: updated, kind: .codex, relayPath: relay) == .connected)
        #expect(try ClientConfigurator.connecting(updated, kind: .codex, relayPath: relay) == nil)
    }

    @Test func updatesTheCodexCommandWhenPosternMoved() throws {
        let old = Data("[mcp_servers.postern]\ncommand = \"/old/postern-mcp\"\nargs = []\n".utf8)
        #expect(ClientConfigurator.status(of: old, kind: .codex, relayPath: relay) == .connectedElsewhere("/old/postern-mcp"))
        let bytes = try #require(try ClientConfigurator.connecting(old, kind: .codex, relayPath: relay))
        let updated = String(decoding: bytes, as: UTF8.self)
        #expect(updated == "[mcp_servers.proton-mail-postern]\ncommand = \"\(relay)\"\nargs = []\n")
    }

    @Test func addsPosternToEveryJSONClientInItsOwnShape() throws {
        for kind in ClientKind.allCases where kind != .codex {
            let updated = try json(try ClientConfigurator.connecting(Data("{\"theme\": \"dark\"}".utf8), kind: kind, relayPath: relay))
            #expect(updated["theme"] as? String == "dark", "\(kind)")
            let servers = try #require(updated[kind == .vscode ? "servers" : "mcpServers"] as? [String: Any], "\(kind)")
            #expect((servers[name] as? [String: Any])?["command"] as? String == relay, "\(kind)")
            #expect(try ClientConfigurator.connecting(JSONSerialization.data(withJSONObject: updated), kind: kind, relayPath: relay) == nil)
        }
        let cursor = try json(try ClientConfigurator.connecting(nil, kind: .cursor, relayPath: relay))
        #expect(((cursor["mcpServers"] as? [String: Any])?[name] as? [String: Any])?["type"] as? String == "stdio")
    }

    @Test func readsVSCodeFilesWithCommentsAndTrailingCommas() throws {
        let original = Data("{\n  // my servers\n  \"servers\": {\n    \"other\": {\"type\": \"stdio\", \"command\": \"x\"},\n  },\n}".utf8)
        let updated = try json(try ClientConfigurator.connecting(original, kind: .vscode, relayPath: relay))
        let servers = try #require(updated["servers"] as? [String: Any])
        #expect(servers["other"] != nil && (servers[name] as? [String: Any])?["type"] as? String == "stdio")
    }

    /// The file is edited, not rewritten: the user's comments, key order, numbers and spacing stay byte for byte.
    @Test func keepsTheRestOfTheFileExactlyAsItWas() throws {
        let original = """
        {
          // Copilot servers, kept by hand
          "inputs": [],
          "servers": {
            /* the GitHub one */
            "github": { "type": "http", "url": "https://api.example/mcp/" },
            "ratio": 1.10,
          },
          "z": 1e3
        }
        """
        let bytes = try #require(try ClientConfigurator.connecting(Data(original.utf8), kind: .vscode, relayPath: relay))
        let updated = String(decoding: bytes, as: UTF8.self)
        var rest = Substring(updated)
        for line in original.split(separator: "\n") {
            let found = try #require(rest.range(of: line), "lost: \(line)")
            rest = rest[found.upperBound...]
        }
        #expect(updated.contains("    \"proton-mail-postern\": {\n      \"command\": \"\(relay)\",\n      \"type\": \"stdio\"\n    }"))
        #expect(ClientConfigurator.status(of: bytes, kind: .vscode, relayPath: relay) == .connected)
    }

    @Test func addsTheServersBlockWhenThereIsNone() throws {
        let bytes = try #require(try ClientConfigurator.connecting(Data("{\n  \"theme\": \"dark\" // mine\n}\n".utf8), kind: .cursor, relayPath: relay))
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.hasPrefix("{\n  \"theme\": \"dark\","))
        #expect(text.contains("// mine"))
        let servers = try #require(try json(bytes)["mcpServers"] as? [String: Any])
        #expect((servers[name] as? [String: Any])?["command"] as? String == relay)
    }

    @Test func fillsAnEmptyServersObject() throws {
        let bytes = try #require(try ClientConfigurator.connecting(Data("{\"mcpServers\": {}}".utf8), kind: .claudeDesktop, relayPath: relay))
        #expect(((try json(bytes)["mcpServers"] as? [String: Any])?[name] as? [String: Any])?["command"] as? String == relay)
    }

    /// Postern was listed as `postern` before 0.2.0: that entry still counts, and connecting again renames it in
    /// place, without a second copy.
    @Test func knowsAndRenamesTheFormerName() throws {
        let current = Data("{\"mcpServers\": {\"a\": 1, \"postern\": {\"command\": \"\(relay)\"}, \"b\": 2}}".utf8)
        #expect(ClientConfigurator.status(of: current, kind: .claudeCode, relayPath: relay) == .connected)
        #expect(try ClientConfigurator.connecting(current, kind: .claudeCode, relayPath: relay) == nil)

        let moved = Data("{\"mcpServers\": {\"a\": 1, \"postern\": {\"command\": \"/old/postern-mcp\"}, \"b\": 2}}".utf8)
        let bytes = try #require(try ClientConfigurator.connecting(moved, kind: .claudeCode, relayPath: relay))
        let text = String(decoding: bytes, as: UTF8.self)
        let servers = try #require(try json(bytes)["mcpServers"] as? [String: Any])
        #expect(servers["postern"] == nil && servers["a"] != nil && servers["b"] != nil)
        #expect((servers[name] as? [String: Any])?["command"] as? String == relay)
        #expect(text.range(of: "\"a\"")!.lowerBound < text.range(of: name)!.lowerBound && text.range(of: name)!.lowerBound < text.range(of: "\"b\"")!.lowerBound)

        let codex = Data("[mcp_servers.postern]\ncommand = \"\(relay)\"\n".utf8)
        #expect(ClientConfigurator.status(of: codex, kind: .codex, relayPath: relay) == .connected)
    }

    @Test func removesASecondCopyUnderTheFormerName() throws {
        let both = Data("{\n  \"mcpServers\": {\n    \"proton-mail-postern\": {\"command\": \"/old\"},\n    \"postern\": {\"command\": \"/older\"}\n  }\n}".utf8)
        let bytes = try #require(try ClientConfigurator.connecting(both, kind: .claudeCode, relayPath: relay))
        let servers = try #require(try json(bytes)["mcpServers"] as? [String: Any])
        #expect(servers.count == 1 && (servers[name] as? [String: Any])?["command"] as? String == relay)
    }

    /// Found in review: three copies used to leave a trailing comma, which `JSON.parse` refuses in ~/.claude.json.
    @Test func removesEveryCopyWithoutATrailingComma() throws {
        let copies = "{\n  \"mcpServers\": {\n    \"other\": {\"command\": \"x\"},\n    \"postern\": {\"command\": \"/a\"},\n    \"proton-mail-postern\": {\"command\": \"/b\"},\n    \"postern\": {\"command\": \"/c\"}\n  },\n  \"tail\": 1\n}\n"
        let bytes = try #require(try ClientConfigurator.connecting(Data(copies.utf8), kind: .claudeCode, relayPath: relay))
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!JSONCEditor.hasTrailingComma(text), "\(text)")
        #expect(text.contains("\"tail\": 1"))
        #expect(JSONCEditor.serverKeys(in: text, servers: "mcpServers") == ["other", name])
        #expect(try JSONSerialization.jsonObject(with: bytes) is [String: Any])
    }

    /// Found in review: a comma inside a comment after the last value.
    @Test func ignoresACommaWrittenInAComment() throws {
        let original = "{\n  \"servers\": {\n    \"a\": {\"command\": \"x\"} /* one, two */\n  }\n}\n"
        let bytes = try #require(try ClientConfigurator.connecting(Data(original.utf8), kind: .vscode, relayPath: relay))
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.contains("/* one, two */"))
        #expect(JSONCEditor.command(in: text, servers: "servers", name: name) == relay)
    }

    /// Apps read the last of two keys with the same name; the entry goes there and the other stays as it was.
    @Test func writesWhereAppsReadADuplicateKey() throws {
        let original = "{\"mcpServers\": {\"a\": {\"command\": \"x\"}}, \"mcpServers\": {\"b\": {\"command\": \"y\"}}}"
        let bytes = try #require(try ClientConfigurator.connecting(Data(original.utf8), kind: .claudeCode, relayPath: relay))
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.hasPrefix("{\"mcpServers\": {\"a\": {\"command\": \"x\"}}, \"mcpServers\": {\"b\""))
        #expect(JSONCEditor.serverKeys(in: text, servers: "mcpServers") == ["b", name])
    }

    @Test func renamesCodexSubTablesToo() throws {
        let old = Data("[mcp_servers.postern]\ncommand = \"/old/postern-mcp\"\n\n[mcp_servers.postern.env]\nA = \"1\"\n".utf8)
        let text = String(decoding: try #require(try ClientConfigurator.connecting(old, kind: .codex, relayPath: relay)), as: UTF8.self)
        #expect(text == "[mcp_servers.proton-mail-postern]\ncommand = \"\(relay)\"\n\n[mcp_servers.proton-mail-postern.env]\nA = \"1\"\n")
    }

    @Test func everySnippetNamesTheRelay() {
        for snippet in SetupSnippet.allCases {
            #expect(snippet.text(relayPath: relay).contains(relay), "\(snippet)")
        }
        let json = SetupSnippet.json.text(relayPath: relay)
        #expect((try? JSONSerialization.jsonObject(with: Data(json.utf8))) != nil)
    }
}
