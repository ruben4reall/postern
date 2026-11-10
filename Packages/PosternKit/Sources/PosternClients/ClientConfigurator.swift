import Foundation

/// The MCP clients Postern can connect itself to, each through its own configuration file.
public enum ClientKind: String, CaseIterable, Sendable, Identifiable {
    case claudeCode, claudeDesktop, codex, cursor, vscode, windsurf, geminiCLI, kiro, cline

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .codex: "Codex and ChatGPT"
        case .cursor: "Cursor"
        case .vscode: "VS Code (Copilot)"
        case .windsurf: "Windsurf"
        case .geminiCLI: "Gemini CLI"
        case .kiro: "Kiro"
        case .cline: "Cline"
        }
    }

    /// The configuration file, relative to the home folder.
    public var relativePath: String {
        switch self {
        case .claudeCode: ".claude.json"
        case .claudeDesktop: "Library/Application Support/Claude/claude_desktop_config.json"
        case .codex: ".codex/config.toml"
        case .cursor: ".cursor/mcp.json"
        case .vscode: "Library/Application Support/Code/User/mcp.json"
        case .windsurf: ".codeium/windsurf/mcp_config.json"
        case .geminiCLI: ".gemini/settings.json"
        case .kiro: ".kiro/settings/mcp.json"
        case .cline: "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json"
        }
    }

    /// The folder whose presence shows the client is installed, relative to the home folder.
    public var installMarker: String {
        switch self {
        case .claudeCode: ".claude.json"
        case .claudeDesktop: "Library/Application Support/Claude"
        case .codex: ".codex"
        case .cursor: ".cursor"
        case .vscode: "Library/Application Support/Code/User"
        case .windsurf: ".codeium/windsurf"
        case .geminiCLI: ".gemini"
        case .kiro: ".kiro"
        case .cline: "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev"
        }
    }

    /// The key that holds the servers in a JSON file: VS Code names it differently from everyone else.
    var serversKey: String { self == .vscode ? "servers" : "mcpServers" }

    /// Postern's entry, as this client expects it.
    func entry(_ relayPath: String) -> [String: Any] {
        switch self {
        case .claudeCode, .cursor: ["type": "stdio", "command": relayPath, "args": [String](), "env": [String: String]()]
        case .vscode: ["type": "stdio", "command": relayPath]
        case .cline: ["command": relayPath, "args": [String](), "disabled": false]
        default: ["command": relayPath, "args": [String]()]
        }
    }
}

/// How to set Postern up by hand, for the apps Postern does not write to itself.
public enum SetupSnippet: String, CaseIterable, Sendable, Identifiable {
    case json, vscode, zed, toml, opencode, goose, continueYAML

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .json: "JSON (mcpServers): LM Studio, JetBrains, Raycast, Msty, BoltAI, Roo Code, Warp and most others"
        case .vscode: "VS Code (servers)"
        case .zed: "Zed (context_servers)"
        case .toml: "TOML: Codex"
        case .opencode: "OpenCode"
        case .goose: "Goose (YAML)"
        case .continueYAML: "Continue (YAML)"
        }
    }

    public func text(relayPath: String) -> String {
        let name = ClientConfigurator.serverName
        let quoted = "\"" + relayPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        switch self {
        case .json:
            return "{\n  \"mcpServers\": {\n    \"\(name)\": {\n      \"command\": \(quoted),\n      \"args\": []\n    }\n  }\n}"
        case .vscode:
            return "{\n  \"servers\": {\n    \"\(name)\": {\n      \"type\": \"stdio\",\n      \"command\": \(quoted)\n    }\n  }\n}"
        case .zed:
            return "\"context_servers\": {\n  \"\(name)\": {\n    \"command\": \(quoted),\n    \"args\": [],\n    \"env\": {}\n  }\n}"
        case .toml:
            return "[mcp_servers.\(name)]\ncommand = \(quoted)\nargs = []"
        case .opencode:
            return "{\n  \"mcp\": {\n    \"\(name)\": {\n      \"type\": \"local\",\n      \"command\": [\(quoted)]\n    }\n  }\n}"
        case .goose:
            return "extensions:\n  \(name):\n    type: stdio\n    name: Proton Mail (Postern)\n    cmd: \(quoted)\n    args: []\n    enabled: true\n    timeout: 300"
        case .continueYAML:
            return "mcpServers:\n  - name: \(name)\n    type: stdio\n    command: \(quoted)"
        }
    }
}

public enum ConnectionStatus: Hashable, Sendable {
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
    /// The name apps list Postern under: what people search for is Proton Mail.
    public static let serverName = "proton-mail-postern"
    /// The names Postern used before 0.2.0. An entry under one of them is Postern's, and connecting again renames it.
    public static let formerNames = ["postern"]
    static var allNames: [String] { [serverName] + formerNames }

    public static func status(of data: Data?, kind: ClientKind, relayPath: String) -> ConnectionStatus {
        guard let current = command(in: data, kind: kind) else { return .notConnected }
        return current == relayPath ? .connected : .connectedElsewhere(current)
    }

    /// The file's new bytes, or nil when Postern is already there with this path.
    public static func connecting(_ data: Data?, kind: ClientKind, relayPath: String) throws -> Data? {
        if status(of: data, kind: kind, relayPath: relayPath) == .connected { return nil }
        switch kind {
        case .codex: return connectingTOML(data, relayPath: relayPath)
        default: return try connectingJSON(data, kind: kind, relayPath: relayPath)
        }
    }

    // MARK: JSON clients

    /// Edits the file's text in place, so the user's comments, key order and formatting stay; a file the editor
    /// cannot walk is rewritten whole, as long as it parses.
    private static func connectingJSON(_ data: Data?, kind: ClientKind, relayPath: String) throws -> Data {
        var root: [String: Any] = [:]
        if let data, !data.trimmingCharacters().isEmpty {
            guard let object = parse(data) else { throw ClientConfiguratorError.unreadable }
            root = object
            let original = String(decoding: data, as: UTF8.self)
            // The edit is kept only if the file still parses, holds the entry as apps read it (the last of
            // duplicate keys), lost no former copy, and gained no trailing comma a strict parser would refuse.
            if let edited = JSONCEditor.setting(original, servers: kind.serversKey, name: serverName,
                                                oldNames: formerNames, entry: pretty(kind.entry(relayPath))),
               parse(Data(edited.utf8)) != nil,
               JSONCEditor.command(in: edited, servers: kind.serversKey, name: serverName) == relayPath,
               let keys = JSONCEditor.serverKeys(in: edited, servers: kind.serversKey),
               keys.filter({ allNames.contains($0) }) == [serverName],
               JSONCEditor.hasTrailingComma(original) || !JSONCEditor.hasTrailingComma(edited) {
                return Data(edited.utf8)
            }
        }
        var servers = root[kind.serversKey] as? [String: Any] ?? [:]
        for name in formerNames { servers[name] = nil }
        servers[serverName] = kind.entry(relayPath)
        root[kind.serversKey] = servers
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
    }

    /// JSON as people write it by hand: two spaces, `"key": value`, keys sorted, empty lists and objects on one line.
    static func pretty(_ value: Any, indent: String = "") -> String {
        switch value {
        case let text as String:
            let data = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        case let flag as Bool:
            return flag ? "true" : "false"
        case let list as [Any]:
            if list.isEmpty { return "[]" }
            return "[\n" + list.map { indent + "  " + pretty($0, indent: indent + "  ") }.joined(separator: ",\n") + "\n" + indent + "]"
        case let object as [String: Any]:
            if object.isEmpty { return "{}" }
            return "{\n" + object.keys.sorted().map { indent + "  " + pretty($0) + ": " + pretty(object[$0]!, indent: indent + "  ") }
                .joined(separator: ",\n") + "\n" + indent + "}"
        default:
            return "\(value)"
        }
    }

    // MARK: TOML (Codex)

    private static func section(_ name: String) -> String { "[mcp_servers.\(name)]" }
    private static let section = section(serverName)

    private static func connectingTOML(_ data: Data?, relayPath: String) -> Data {
        var lines = data.map { String(decoding: $0, as: UTF8.self) }?.components(separatedBy: "\n") ?? []
        let value = "command = \"\(escape(relayPath))\""
        // An entry under a former name is renamed where it is, with its sub-tables such as `.env`.
        if !lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == section }),
           let old = formerNames.first(where: { name in lines.contains { $0.trimmingCharacters(in: .whitespaces) == section(name) } }) {
            for index in lines.indices {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                for prefix in ["[mcp_servers.\(old)]", "[mcp_servers.\(old)."] where trimmed.hasPrefix(prefix) {
                    lines[index] = "[mcp_servers.\(serverName)" + trimmed.dropFirst("[mcp_servers.\(old)".count)
                }
            }
        }
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
        case .codex:
            let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            let sections = allNames.map(section)
            guard let start = lines.firstIndex(where: { sections.contains($0.trimmingCharacters(in: .whitespaces)) }) else {
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
        default:
            guard let root = parse(data), let servers = root[kind.serversKey] as? [String: Any],
                  let entry = allNames.lazy.compactMap({ servers[$0] as? [String: Any] }).first else { return nil }
            return entry["command"] as? String
        }
    }

    /// JSON, with the comments and trailing commas VS Code and others allow.
    private static func parse(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            ?? (try? JSONSerialization.jsonObject(with: data, options: .json5Allowed) as? [String: Any])
    }
}

private extension Data {
    func trimmingCharacters() -> String {
        String(decoding: self, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
