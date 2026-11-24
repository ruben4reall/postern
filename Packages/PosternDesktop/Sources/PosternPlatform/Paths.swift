import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import WinSDK
#endif

/// Where Postern keeps things on this system. Nothing here is a secret: the secrets are in the system's store.
public enum PosternPaths {
    /// The folder of the running program: the core, the relay, the reader and the app are installed side by side
    /// (`/usr/libexec/postern` and `/usr/bin` on Linux are linked to the same release).
    public static var programFolder: URL {
        URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
            .standardizedFileURL.absoluteURL
    }

    /// Looks for a Postern program next to this one, then in the places packages install them.
    public static func program(_ name: String) -> URL? {
        #if os(Windows)
        let file = name + ".exe"
        #else
        let file = name
        #endif
        var candidates = [programFolder.appendingPathComponent(file)]
        #if os(Linux)
        candidates += [URL(fileURLWithPath: "/usr/libexec/postern/\(file)"), URL(fileURLWithPath: "/usr/bin/\(file)"),
                       URL(fileURLWithPath: "/usr/local/libexec/postern/\(file)"), URL(fileURLWithPath: "/usr/local/bin/\(file)")]
        #endif
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The activity log and the sealed batches.
    nonisolated(unsafe) public static var supportOverride: URL?

    public static var supportFolder: URL {
        if let supportOverride { return supportOverride }
        #if os(Windows)
        return localAppData.appendingPathComponent("Postern", isDirectory: true)
        #elseif os(Linux)
        let environment = ProcessInfo.processInfo.environment
        let base = environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share", isDirectory: true)
        return base.appendingPathComponent("postern", isDirectory: true)
        #else
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Postern Desktop", isDirectory: true)
        #endif
    }

    #if os(Windows)
    public static var localAppData: URL {
        if let value = ProcessInfo.processInfo.environment["LOCALAPPDATA"], !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Local", isDirectory: true)
    }

    public static var roamingAppData: URL {
        if let value = ProcessInfo.processInfo.environment["APPDATA"], !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Roaming", isDirectory: true)
    }

    /// The pipe of this user's core. Its access list lets only this user and the system in.
    nonisolated(unsafe) public static var pipeOverride: String?
    public static var pipeName: String { pipeOverride ?? #"\\.\pipe\postern-core-"# + (CurrentUser.sid ?? "unknown") }
    #else
    /// The core's socket, in the user's runtime folder: created by systemd (`postern.socket`) or by the core
    /// itself, readable by this user only. Codex starts servers with a short environment that may drop
    /// `XDG_RUNTIME_DIR`, so the standard place is the fallback.
    nonisolated(unsafe) public static var socketOverride: String?

    public static var socketPath: String {
        if let socketOverride { return socketOverride }
        #if os(Linux)
        let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? "/run/user/\(getuid())"
        return runtime + "/postern/core.sock"
        #else
        return NSTemporaryDirectory() + "postern-\(getuid())/core.sock"
        #endif
    }
    #endif

    /// The user's home folder, as the apps whose settings Postern edits see it.
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
}

#if os(Windows)
/// The account the programs run as.
public enum CurrentUser {
    /// The user's security identifier, such as S-1-5-21-…, from the process token.
    public static let sid: String? = sid(of: GetCurrentProcess())

    /// Whether another process runs as this user. Pipe names are shared by every account on the machine, so the
    /// relays, the app and the command line check that the core at the other end is theirs before saying anything.
    public static func owns(processID: ULONG) -> Bool {
        // PROCESS_QUERY_LIMITED_INFORMATION: another account's process does not even open.
        guard let mine = sid, let process = OpenProcess(DWORD(0x1000), false, processID) else { return false }
        defer { CloseHandle(process) }
        return sid(of: process) == mine
    }

    /// The account a process runs as, from its token.
    static func sid(of process: HANDLE) -> String? {
        var token: HANDLE?
        guard OpenProcessToken(process, DWORD(TOKEN_QUERY), &token), let token else { return nil }
        defer { CloseHandle(token) }
        var size: DWORD = 0
        _ = GetTokenInformation(token, TokenUser, nil, 0, &size)
        guard size > 0 else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { buffer.deallocate() }
        guard GetTokenInformation(token, TokenUser, buffer, size, &size) else { return nil }
        let user = buffer.assumingMemoryBound(to: TOKEN_USER.self).pointee
        var text: LPWSTR?
        guard ConvertSidToStringSidW(user.User.Sid, &text), let text else { return nil }
        defer { LocalFree(text) }
        return String(decodingCString: text, as: UTF16.self)
    }
}
#endif
