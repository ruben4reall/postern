import Foundation
import PosternApproval
#if canImport(Glibc)
import Glibc
#endif

/// The proof, on Linux, that the person at the computer approved: polkit asks for the user's password (or their
/// fingerprint where fprintd is set up) in the desktop's own dialog, and only polkitd, running as root, says yes.
/// Postern ships two actions in /usr/share/polkit-1/actions/ch.rubencatalao.postern.policy, both `auth_self`, so
/// every approval asks again.
public struct PolkitAuthenticator: Authenticating {
    public enum Action: String, Sendable {
        /// Sending an email, deleting messages, resuming a batch.
        case approve = "ch.rubencatalao.postern.approve"
        /// Turning a tool on, raising a limit, trusting a recipient: any change that gives apps more.
        case changePolicy = "ch.rubencatalao.postern.change-policy"
    }

    let action: Action

    public init(action: Action = .approve) {
        self.action = action
    }

    public func confirm(reason: String) async -> Bool {
        await Task.detached { Self.check(action: action) }.value
    }

    /// Whether polkit's actions are installed: without them, nothing can be approved and the app says how to fix it.
    public static var installed: Bool {
        FileManager.default.fileExists(atPath: "/usr/share/polkit-1/actions/ch.rubencatalao.postern.policy")
            && pkcheck != nil
    }

    static var pkcheck: String? {
        ["/usr/bin/pkcheck", "/bin/pkcheck"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs pkcheck for this very process, named by its id, start time and user so a recycled id cannot stand in.
    static func check(action: Action) -> Bool {
        #if os(Linux)
        guard let pkcheck, let subject = processSubject() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pkcheck)
        process.arguments = ["--action-id", action.rawValue, "--process", subject, "--allow-user-interaction"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationReason == .exit && process.terminationStatus == 0
        #else
        return false
        #endif
    }

    #if os(Linux)
    /// `pid,start-time,uid`, the form polkit asks for.
    static func processSubject() -> String? {
        guard let stat = try? String(contentsOfFile: "/proc/self/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return nil }
        // Fields after the command name, which may hold spaces: state is field 3, start time field 22.
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        guard fields.count > 19 else { return nil }
        return "\(getpid()),\(fields[19]),\(getuid())"
    }
    #endif
}
