import Foundation
import PosternClients

/// The settings files of the MCP apps Postern connects itself to, where each app keeps them on this system. Some
/// apps have two (an older place and a newer one, or the Microsoft Store copy of Claude); Postern writes every one
/// that exists, and the first one when none does.
public struct AppTarget: Sendable {
    public let kind: ClientKind
    public let files: [URL]
    /// Present when the app is installed.
    public let markers: [URL]

    public var installed: Bool { markers.contains { FileManager.default.fileExists(atPath: $0.path) } }
    public var title: String { kind.displayName }

    /// The files to write: those that exist, else the first.
    public var writable: [URL] {
        let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        return existing.isEmpty ? Array(files.prefix(1)) : existing
    }

    public static func all(home: URL = PosternPaths.home) -> [AppTarget] {
        ClientKind.allCases.map { target($0, home: home) }
    }

    static func target(_ kind: ClientKind, home: URL) -> AppTarget {
        func at(_ path: String) -> URL { home.appendingPathComponent(path) }
        #if os(Windows)
        let roaming = PosternPaths.roamingAppData
        let local = PosternPaths.localAppData
        switch kind {
        case .claudeCode:
            return AppTarget(kind: kind, files: [at(".claude.json")], markers: [at(".claude.json"), at(".claude")])
        case .claudeDesktop:
            // The Microsoft Store version reads its own copy first.
            let packages = (try? FileManager.default.contentsOfDirectory(at: local.appendingPathComponent("Packages"), includingPropertiesForKeys: nil)) ?? []
            let store = packages.filter { $0.lastPathComponent.hasPrefix("Claude_") }
                .map { $0.appendingPathComponent("LocalCache/Roaming/Claude/claude_desktop_config.json") }
            let classic = roaming.appendingPathComponent("Claude/claude_desktop_config.json")
            return AppTarget(kind: kind, files: store + [classic],
                             markers: store.map { $0.deletingLastPathComponent() } + [classic.deletingLastPathComponent()])
        case .codex:
            return AppTarget(kind: kind, files: [at(".codex/config.toml")], markers: [at(".codex")])
        case .cursor:
            return AppTarget(kind: kind, files: [at(".cursor/mcp.json")], markers: [at(".cursor")])
        case .vscode:
            return AppTarget(kind: kind, files: [at(".copilot/mcp-config.json"), roaming.appendingPathComponent("Code/User/mcp.json")],
                             markers: [roaming.appendingPathComponent("Code/User"), at(".copilot")])
        case .windsurf:
            return AppTarget(kind: kind, files: [roaming.appendingPathComponent("devin/mcp_config.json"), at(".codeium/windsurf/mcp_config.json")],
                             markers: [roaming.appendingPathComponent("devin"), at(".codeium/windsurf")])
        case .geminiCLI:
            return AppTarget(kind: kind, files: [at(".gemini/settings.json")], markers: [at(".gemini")])
        case .kiro:
            return AppTarget(kind: kind, files: [at(".kiro/settings/mcp.json")], markers: [at(".kiro")])
        case .cline:
            let legacy = roaming.appendingPathComponent("Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json")
            return AppTarget(kind: kind, files: [at(".cline/data/settings/cline_mcp_settings.json"), legacy],
                             markers: [at(".cline"), legacy.deletingLastPathComponent().deletingLastPathComponent()])
        }
        #else
        let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? at(".config")
        switch kind {
        case .claudeCode:
            return AppTarget(kind: kind, files: [at(".claude.json")], markers: [at(".claude.json"), at(".claude")])
        case .claudeDesktop:
            let file = config.appendingPathComponent("Claude/claude_desktop_config.json")
            return AppTarget(kind: kind, files: [file], markers: [file.deletingLastPathComponent()])
        case .codex:
            return AppTarget(kind: kind, files: [at(".codex/config.toml")], markers: [at(".codex")])
        case .cursor:
            return AppTarget(kind: kind, files: [at(".cursor/mcp.json")], markers: [at(".cursor")])
        case .vscode:
            return AppTarget(kind: kind, files: [at(".copilot/mcp-config.json"), config.appendingPathComponent("Code/User/mcp.json")],
                             markers: [config.appendingPathComponent("Code/User"), at(".copilot")])
        case .windsurf:
            return AppTarget(kind: kind, files: [config.appendingPathComponent("devin/mcp_config.json"), at(".codeium/windsurf/mcp_config.json")],
                             markers: [config.appendingPathComponent("devin"), at(".codeium/windsurf")])
        case .geminiCLI:
            return AppTarget(kind: kind, files: [at(".gemini/settings.json")], markers: [at(".gemini")])
        case .kiro:
            return AppTarget(kind: kind, files: [at(".kiro/settings/mcp.json")], markers: [at(".kiro")])
        case .cline:
            let legacy = config.appendingPathComponent("Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json")
            return AppTarget(kind: kind, files: [at(".cline/data/settings/cline_mcp_settings.json"), legacy],
                             markers: [at(".cline"), legacy.deletingLastPathComponent().deletingLastPathComponent()])
        }
        #endif
    }

    /// How the app's files stand: connected when one of them already points at this relay.
    public func status(relay: String) -> ConnectionStatus {
        var best: ConnectionStatus = .notConnected
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            let status = ClientConfigurator.status(of: try? Data(contentsOf: file), kind: kind, relayPath: relay)
            if status == .connected { return .connected }
            if case .notConnected = best { best = status }
        }
        return best
    }

    /// Adds or updates Postern's entry in each file, keeping everything else the file holds.
    public func connect(relay: String) throws {
        for file in writable {
            let original = try? Data(contentsOf: file)
            guard let updated = try ClientConfigurator.connecting(original, kind: kind, relayPath: relay) else { continue }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try updated.write(to: file, options: .atomic)
        }
    }
}
