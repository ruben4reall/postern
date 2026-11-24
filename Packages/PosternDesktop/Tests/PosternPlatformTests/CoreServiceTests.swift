import Foundation
import Testing
import PosternCore
import PosternModel
import PosternPolicy
import PosternVault
@testable import PosternPlatform

/// A reader that is never reached in these tests.
struct NoReader: MessageReading {
    func sanitize(_ raw: Data, maxChars: Int) async throws -> SanitizedMessage { throw PosternError(.parseFailed, "no") }
    func attachment(_ raw: Data, index: Int) async throws -> (data: Data, filename: String?, mimeType: String) { throw PosternError(.parseFailed, "no") }
    func readAttachment(_ raw: Data, index: Int, maxChars: Int) async throws -> AttachmentContent { throw PosternError(.parseFailed, "no") }
}

/// One core on a socket of its own, as systemd or a relay would start it.
final class RunningCore: @unchecked Sendable {
    let service: CoreService
    let vault = MemoryVault()

    init() throws {
        #if os(Windows)
        PosternPaths.pipeOverride = #"\\.\pipe\postern-test-"# + UUID().uuidString
        #else
        PosternPaths.socketOverride = "/tmp/postern-test-\(UUID().uuidString.prefix(8)).sock"
        #endif
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("postern-platform-\(UUID().uuidString)")
        PosternPaths.supportOverride = folder
        PosternFolders.downloadsOverride = folder.appendingPathComponent("Downloads")
        service = try CoreService(listener: try LocalListener(), vault: vault, reader: NoReader())
        let service = self.service
        Thread.detachNewThread { service.run() }
    }
}

@Suite(.serialized) struct CoreServiceTests {
    @Test func anInterfaceReadsTheStatusOfACoreThatIsNotSetUp() async throws {
        let core = try RunningCore()
        let client = try ControlClient(startCore: false)
        let status = try #require(try await client.call("status").status)
        #expect(!status.configured)
        #expect(status.version == CoreService.version)
        #expect(status.policy == .initial)
        let tools = try #require(try await client.call("tools").tools)
        #expect(tools.count == ToolID.switchable.count)
        #expect(tools.allSatisfy { !$0.enabled && !$0.title.isEmpty && !$0.risk.isEmpty })
        _ = core
        client.close()
    }

    @Test func givingAppsMorePowerNeedsTheSystemsProofButTakingItAwayDoesNot() async throws {
        let core = try RunningCore()
        try PolicyStore(vault: core.vault).save(.readOnly)
        core.service.core.reloadPolicy()
        let client = try ControlClient(startCore: false)
        var more = Policy.readOnly
        more.enabledTools.insert(.sendMessage)
        // No polkit and no Windows Hello here: the proof fails, nothing changes.
        await #expect(throws: ControlWire.Failure.self) { _ = try await client.call("policy.update", .init(policy: more)) }
        #expect(core.service.core.policy == .readOnly)
        var less = Policy.readOnly
        less.enabledTools.remove(.getThread)
        let status = try #require(try await client.call("policy.update", .init(policy: less)).status)
        #expect(!status.policy.enabledTools.contains(.getThread))
        // Pausing takes power away; resuming gives it back.
        let paused = try #require(try await client.call("pause", .init(paused: true)).status)
        #expect(paused.policy.paused)
        await #expect(throws: ControlWire.Failure.self) { _ = try await client.call("pause", .init(paused: false)) }
        client.close()
    }

    @Test func aRelayGetsAnMCPSessionThatListsNoToolUntilSetUp() async throws {
        let core = try RunningCore()
        let relay = try LocalChannel.connect()
        relay.write(try ControlWire.encoder.encode(ControlWire.Hello(postern: .relay, client: "claude")))
        relay.write(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#.utf8))
        let initialized = try #require(relay.readLine())
        let answer = try #require(try JSONSerialization.jsonObject(with: initialized) as? [String: Any])
        let result = try #require(answer["result"] as? [String: Any])
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "proton-mail-postern")
        relay.write(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        relay.write(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8))
        let listed = try #require(relay.readLine())
        let tools = try #require(((try JSONSerialization.jsonObject(with: listed) as? [String: Any])?["result"] as? [String: Any])?["tools"] as? [Any])
        #expect(tools.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(core.service.core.connectedApps == ["Claude Code"])
        relay.close()
    }

    @Test func approvalsWaitForTheInterfaceAndExpireWhenNobodyAnswers() async throws {
        let core = try RunningCore()
        let client = try ControlClient(startCore: false)
        let seen = Seen()
        client.onEvent { event, data in if event == "approval", let id = data?.approval?.id { seen.add(id) } }
        let presenter = core.service.presenter
        let request = Task { await presenter.presentDeletion(.init(tool: "trash_messages", client: "Cursor", items: [], permanent: false), deadline: Date().addingTimeInterval(60)) }
        try await Task.sleep(for: .milliseconds(300))
        let id = try #require(seen.first)
        #expect(presenter.waiting().count == 1)
        _ = try await client.call("approval.decide", .init(id: id, decision: .reject, reason: "Not these"))
        let intent = await request.value
        #expect(intent == .reject(reason: "Not these"))
        #expect(presenter.waiting().isEmpty)
        client.close()
    }
}

final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    func add(_ id: String) { lock.withLock { ids.append(id) } }
    var first: String? { lock.withLock { ids.first } }
}

@Suite struct WireTests {
    @Test func messagesKeepTheirFieldsOnTheWire() throws {
        let message = ControlWire.Message(id: 4, result: .init(text: "ok"))
        let data = try ControlWire.encoder.encode(message)
        #expect(!data.contains(0x0A))
        let back = try ControlWire.decoder.decode(ControlWire.Message.self, from: data)
        #expect(back.id == 4 && back.result?.text == "ok")
    }

    @Test func everyAppHasASettingsFileInTheHomeFolder() {
        let home = URL(fileURLWithPath: "/home/anna")
        for target in AppTarget.all(home: home) {
            #expect(!target.files.isEmpty, "\(target.kind)")
        }
        #if os(Linux)
        let claude = AppTarget.all(home: home).first { $0.kind == .claudeDesktop }
        #expect(claude?.files.first?.path.hasSuffix(".config/Claude/claude_desktop_config.json") == true)
        #endif
    }
}

/// Linux and Windows announce the version the Mac app ships.
@Suite struct VersionTests {
    @Test func theDesktopCoreHasTheMacAppsVersion() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(contentsOf: repository.appendingPathComponent("project.yml"), encoding: .utf8)
        #expect(project.contains("MARKETING_VERSION: \"\(CoreService.version)\""))
    }
}
