import Foundation

/// The MCP clients Postern can connect itself to.
public enum ClientKind: String, CaseIterable, Sendable, Identifiable {
    case claudeCode, claudeDesktop, codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .codex: "Codex"
        }
    }

    /// The configuration file, relative to the home folder.
    public var relativePath: String {
        switch self {
        case .claudeCode: ".claude.json"
        case .claudeDesktop: "Library/Application Support/Claude/claude_desktop_config.json"
        case .codex: ".codex/config.toml"
        }
    }
}

public enum ConnectionStatus: Equatable, Sendable {
    case notConnected
    case connected
    /// Postern is listed, but at another path: an older copy of the app.
    case connectedElsewhere(String)
}

public enum ClientConfiguratorError: Error, Equatable {
    case unreadable
}

/// Adds Postern to a client's configuration. The entry holds the relay's path and nothing else: no secret ever goes
/// into these files. Pure functions over the file's bytes; reading and writing belong to the caller.
public enum ClientConfigurator {
    public static let serverName = "postern"

    public static func status(of data: Data?, kind: ClientKind, relayPath: String) -> ConnectionStatus {
        guard let current = command(in: data, kind: kind) else { return .notConnected }
        return current == relayPath ? .connected : .connectedElsewhere(current)
    }

    /// The file's new bytes, or nil when Postern is already there with this path.
    public static func connecting(_ data: Data?, kind: ClientKind, relayPath: String) throws -> Data? {
        if status(of: data, kind: kind, relayPath: relayPath) == .connected { return nil }
        switch kind {
        case .claudeCode, .claudeDesktop: return try connectingJSON(data, kind: kind, relayPath: relayPath)
        case .codex: return connectingTOML(data, relayPath: relayPath)
        }
    }

    // MARK: JSON clients

    private static func connectingJSON(_ data: Data?, kind: ClientKind, relayPath: String) throws -> Data {
        var root: [String: Any] = [:]
        if let data, !data.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ClientConfiguratorError.unreadable
            }
            root = object
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = kind == .claudeCode
            ? ["type": "stdio", "command": relayPath, "args": [String](), "env": [String: String]()]
            : ["command": relayPath, "args": [String]()]
        root["mcpServers"] = servers
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
    }

    // MARK: TOML (Codex)

    private static let section = "[mcp_servers.\(serverName)]"

    private static func connectingTOML(_ data: Data?, relayPath: String) -> Data {
        var lines = data.map { String(decoding: $0, as: UTF8.self) }?.components(separatedBy: "\n") ?? []
        let value = "command = \"\(escape(relayPath))\""
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == section }) {
            var index = start + 1
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("command") {
                    lines[index] = value
                    return Data(lines.joined(separator: "\n").utf8)
                }
                index += 1
            }
            lines.insert(value, at: start + 1)
            return Data(lines.joined(separator: "\n").utf8)
        }
        var text = lines.joined(separator: "\n")
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        if !text.isEmpty { text += "\n" }
        text += "\(section)\n\(value)\nargs = []\n"
        return Data(text.utf8)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Reading

    private static func command(in data: Data?, kind: ClientKind) -> String? {
        guard let data, !data.isEmpty else { return nil }
        switch kind {
        case .claudeCode, .claudeDesktop:
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entry = (root["mcpServers"] as? [String: Any])?[serverName] as? [String: Any] else { return nil }
            return entry["command"] as? String
        case .codex:
            let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == section }) else {
                return nil
            }
            for line in lines[(start + 1)...] {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") { break }
                guard trimmed.hasPrefix("command"), let equals = trimmed.firstIndex(of: "=") else { continue }
                return trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                    .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            return ""
        }
    }
}
