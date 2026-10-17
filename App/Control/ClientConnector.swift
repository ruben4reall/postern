import AppKit
import PosternClients

/// One configuration file Postern can connect itself to.
struct ClientTarget: Identifiable, Hashable {
    let id: String
    let title: String
    let kind: ClientKind
    let fileURL: URL
    /// Security-scoped bookmark of a profile folder the user picked, when the file is not at its usual place.
    let bookmark: Data?
}

struct ClientRow: Identifiable, Hashable {
    let target: ClientTarget
    let installed: Bool
    let status: ConnectionStatus
    var id: String { target.id }
}

/// Reads and writes client configuration files from inside the sandbox, through the narrow exceptions declared in
/// the entitlements or a folder the user picked.
@MainActor
enum ClientConnector {
    private static let profilesKey = "ClaudeCodeProfileBookmarks"

    /// The real home folder: inside the sandbox, `homeDirectoryForCurrentUser` is the container.
    static var realHome: URL {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    }

    static var relayPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/postern-mcp").path
    }

    static func rows() -> [ClientRow] {
        let standard = ClientKind.allCases.map { kind in
            ClientTarget(id: kind.rawValue, title: kind.displayName, kind: kind,
                         fileURL: realHome.appendingPathComponent(kind.relativePath), bookmark: nil)
        }
        return (standard + profiles()).map(row)
    }

    static func row(_ target: ClientTarget) -> ClientRow {
        withAccess(target) {
            let installed = isInstalled(target)
            let data = try? Data(contentsOf: target.fileURL)
            return ClientRow(target: target, installed: installed,
                             status: ClientConfigurator.status(of: data, kind: target.kind, relayPath: relayPath))
        }
    }

    static func connect(_ target: ClientTarget) throws {
        try withAccess(target) {
            let original = try? Data(contentsOf: target.fileURL)
            guard let updated = try ClientConfigurator.connecting(original, kind: target.kind, relayPath: relayPath) else {
                return
            }
            // `~/.claude.json` sits in the home folder, where the sandbox only allows this one file: no temporary
            // file can be created beside it, so it is rewritten in place, and restored if that fails.
            let atomic = target.kind != .claudeCode || target.bookmark != nil
            do {
                try updated.write(to: target.fileURL, options: atomic ? .atomic : [])
            } catch {
                if let original, !atomic { try? original.write(to: target.fileURL) }
                throw error
            }
        }
    }

    /// Lets the user pick another Claude Code profile folder, such as one set with CLAUDE_CONFIG_DIR.
    static func addProfile() -> ClientTarget? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.directoryURL = realHome
        panel.message = "Choose a Claude Code profile folder, the one CLAUDE_CONFIG_DIR points to."
        panel.prompt = "Add Profile"
        guard panel.runModal() == .OK, let folder = panel.url,
              let bookmark = try? folder.bookmarkData(options: .withSecurityScope) else { return nil }
        var stored = UserDefaults.standard.array(forKey: profilesKey) as? [Data] ?? []
        stored.append(bookmark)
        UserDefaults.standard.set(stored, forKey: profilesKey)
        return profiles().last
    }

    private static func profiles() -> [ClientTarget] {
        let stored = UserDefaults.standard.array(forKey: profilesKey) as? [Data] ?? []
        return stored.compactMap { bookmark in
            var stale = false
            guard let folder = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                        bookmarkDataIsStale: &stale) else { return nil }
            return ClientTarget(id: "profile:" + folder.path, title: "Claude Code, \(folder.lastPathComponent)",
                                kind: .claudeCode, fileURL: folder.appendingPathComponent(".claude.json"),
                                bookmark: bookmark)
        }
    }

    private static func isInstalled(_ target: ClientTarget) -> Bool {
        let files = FileManager.default
        switch target.kind {
        case .claudeCode: return files.fileExists(atPath: target.fileURL.path)
        case .claudeDesktop, .codex: return files.fileExists(atPath: target.fileURL.deletingLastPathComponent().path)
        }
    }

    private static func withAccess<T>(_ target: ClientTarget, _ body: () throws -> T) rethrows -> T {
        guard let bookmark = target.bookmark else { return try body() }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                    bookmarkDataIsStale: &stale) else { return try body() }
        let started = folder.startAccessingSecurityScopedResource()
        defer { if started { folder.stopAccessingSecurityScopedResource() } }
        return try body()
    }
}
