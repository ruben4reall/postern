import Foundation
import Testing
@testable import PosternClients

@Suite struct ClientConfiguratorTests {
    let relay = "/Applications/Postern.app/Contents/Helpers/postern-mcp"

    func json(_ data: Data?) throws -> [String: Any] {
        let bytes = try #require(data)
        return try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    @Test func addsPosternToClaudeCodeAndKeepsEverythingElse() throws {
        let original = Data(#"{"numStartups":42,"mcpServers":{"other":{"type":"http","url":"https://x.example"}},"projects":{"/a":{"x":1}}}"#.utf8)
        #expect(ClientConfigurator.status(of: original, kind: .claudeCode, relayPath: relay) == .notConnected)
        let updated = try json(try ClientConfigurator.connecting(original, kind: .claudeCode, relayPath: relay))
        #expect(updated["numStartups"] as? Int == 42)
        #expect((updated["projects"] as? [String: Any])?["/a"] != nil)
        let servers = try #require(updated["mcpServers"] as? [String: Any])
        #expect((servers["other"] as? [String: Any])?["url"] as? String == "https://x.example")
        let postern = try #require(servers["postern"] as? [String: Any])
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
        #expect(((moved["mcpServers"] as? [String: Any])?["postern"] as? [String: Any])?["command"] as? String == relay)
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
        #expect(text.contains("[mcp_servers.postern]\ncommand = \"\(relay)\"\n"))
        #expect(ClientConfigurator.status(of: updated, kind: .codex, relayPath: relay) == .connected)
        #expect(try ClientConfigurator.connecting(updated, kind: .codex, relayPath: relay) == nil)
    }

    @Test func updatesTheCodexCommandWhenPosternMoved() throws {
        let old = Data("[mcp_servers.postern]\ncommand = \"/old/postern-mcp\"\nargs = []\n".utf8)
        #expect(ClientConfigurator.status(of: old, kind: .codex, relayPath: relay) == .connectedElsewhere("/old/postern-mcp"))
        let bytes = try #require(try ClientConfigurator.connecting(old, kind: .codex, relayPath: relay))
        let updated = String(decoding: bytes, as: UTF8.self)
        #expect(updated == "[mcp_servers.postern]\ncommand = \"\(relay)\"\nargs = []\n")
    }
}
