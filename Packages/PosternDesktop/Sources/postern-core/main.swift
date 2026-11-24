import CPosternSys
import Foundation
import PosternPlatform
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// postern-core: Postern's core for this user. systemd starts it on the first connection to its socket
// (postern.socket), Windows at sign-in; a relay starts it too when none answers. It runs until the session ends.

#if !os(Windows)
// A relay or a window that goes away must not take the core with it.
signal(SIGPIPE, SIG_IGN)
#endif
// Other programs of the same user cannot read the core's memory through ptrace or /proc.
postern_not_dumpable()

do {
    let listener = try LocalListener()
    let service = try CoreService(listener: listener)
    service.run()
} catch LocalChannelError.alreadyRunning {
    exit(0)
} catch {
    FileHandle.standardError.write(Data("postern-core: \(error)\n".utf8))
    exit(1)
}
