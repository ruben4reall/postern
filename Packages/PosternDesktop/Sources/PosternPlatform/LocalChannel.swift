import CPosternSys
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

public enum LocalChannelError: Error, CustomStringConvertible {
    case alreadyRunning
    case unavailable(String)

    public var description: String {
        switch self {
        case .alreadyRunning: "Another Postern core is already running for this user."
        case .unavailable(let reason): reason
        }
    }
}

/// Who is at the other end of a connection, as the system reports it.
public struct LocalPeer: Sendable {
    public let processID: Int32
    public let userID: UInt32?
}

/// One connection to or from the core: newline-delimited messages, both ways. Reading blocks; writing is safe from
/// any thread.
public final class LocalConnection: @unchecked Sendable {
    /// No message is larger: MCP requests carry files of up to 10 MB in base64.
    public static let maxLine = 48_000_000

    public let peer: LocalPeer
    private let endpoint: Endpoint
    private let writeLock = NSLock()
    private var buffer = Data()
    private var closed = false
    private let stateLock = NSLock()

    init(endpoint: Endpoint, peer: LocalPeer) {
        self.endpoint = endpoint
        self.peer = peer
    }

    deinit { close() }

    /// The next message, without its newline, or nil when the other side closed the connection.
    public func readLine() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            guard buffer.count <= Self.maxLine, let chunk = endpoint.read(), !chunk.isEmpty else { return nil }
            buffer.append(chunk)
        }
    }

    @discardableResult
    public func write(_ line: Data) -> Bool {
        var message = line
        message.append(0x0A)
        return writeLock.withLock { endpoint.write(message) }
    }

    public func close() {
        let first = stateLock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        if first { endpoint.close() }
    }
}

// MARK: - Endpoints

#if os(Windows)
final class Endpoint: @unchecked Sendable {
    let handle: HANDLE
    let server: Bool

    init(handle: HANDLE, server: Bool) {
        self.handle = handle
        self.server = server
    }

    func read() -> Data? {
        var data = Data(count: 65_536)
        var count: DWORD = 0
        let ok = data.withUnsafeMutableBytes { ReadFile(handle, $0.baseAddress, DWORD($0.count), &count, nil) }
        guard ok, count > 0 else { return nil }
        return data.prefix(Int(count))
    }

    func write(_ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            var written: DWORD = 0
            let ok = data.withUnsafeBytes { bytes in
                WriteFile(handle, bytes.baseAddress! + offset, DWORD(data.count - offset), &written, nil)
            }
            guard ok, written > 0 else { return false }
            offset += Int(written)
        }
        return true
    }

    func close() {
        if server {
            FlushFileBuffers(handle)
            DisconnectNamedPipe(handle)
        }
        CloseHandle(handle)
    }
}
#else
final class Endpoint: @unchecked Sendable {
    let descriptor: Int32

    init(descriptor: Int32) { self.descriptor = descriptor }

    func read() -> Data? {
        var data = Data(count: 65_536)
        let count = data.withUnsafeMutableBytes { bytes -> Int in
            while true {
                let result = recv(descriptor, bytes.baseAddress, bytes.count, 0)
                if result < 0 && errno == EINTR { continue }
                return result
            }
        }
        guard count > 0 else { return nil }
        return data.prefix(count)
    }

    func write(_ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            let result = data.withUnsafeBytes { bytes -> Int in
                #if os(Linux)
                send(descriptor, bytes.baseAddress! + offset, data.count - offset, Int32(MSG_NOSIGNAL))
                #else
                send(descriptor, bytes.baseAddress! + offset, data.count - offset, 0)
                #endif
            }
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { return false }
            offset += result
        }
        return true
    }

    func close() {
        shutdown(descriptor, Int32(SHUT_RDWR))
        _ = Glibc_or_Darwin_close(descriptor)
    }
}

@inline(__always) func Glibc_or_Darwin_close(_ fd: Int32) -> Int32 {
    #if canImport(Glibc)
    Glibc.close(fd)
    #elseif canImport(Musl)
    Musl.close(fd)
    #else
    Darwin.close(fd)
    #endif
}
#endif

// MARK: - Listening (the core)

/// The core's end: accepts the relays, the app and the command line of this user only.
public final class LocalListener: @unchecked Sendable {
    #if os(Windows)
    private let name: String
    private var first = true
    private let security: UnsafeMutableRawPointer?
    #else
    private let descriptor: Int32
    #endif

    public init() throws {
        #if os(Windows)
        name = PosternPaths.pipeName
        // Only this user and the system: no one else on the machine, and never over the network.
        guard let sid = CurrentUser.sid else { throw LocalChannelError.unavailable("Postern could not read the current user's identity.") }
        var descriptor: PSECURITY_DESCRIPTOR?
        let ok = "D:P(A;;GA;;;\(sid))(A;;GA;;;SY)".withCString(encodedAs: UTF16.self) {
            ConvertStringSecurityDescriptorToSecurityDescriptorW($0, DWORD(SDDL_REVISION_1), &descriptor, nil)
        }
        guard ok, let descriptor else { throw LocalChannelError.unavailable("Postern could not protect its pipe.") }
        security = UnsafeMutableRawPointer(descriptor)
        #else
        descriptor = try Self.socket()
        #endif
    }

    #if !os(Windows)
    /// systemd's socket when the core was started by `postern.socket`, else a socket it makes itself, in a folder
    /// only this user can open.
    private static func socket() throws -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        if environment["LISTEN_PID"].flatMap(Int32.init) == getpid(), (environment["LISTEN_FDS"].flatMap(Int.init) ?? 0) >= 1 {
            return 3
        }
        let path = PosternPaths.socketPath
        let folder = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(folder, 0o700)
        if FileManager.default.fileExists(atPath: path) {
            if (try? LocalChannel.connectSocket(path)) != nil { throw LocalChannelError.alreadyRunning }
            unlink(path)
        }
        #if os(Linux)
        let fd = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        #else
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw LocalChannelError.unavailable("Postern could not open its socket.") }
        var address = try LocalChannel.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            _ = Glibc_or_Darwin_close(fd)
            throw LocalChannelError.unavailable("Postern could not create \(path).")
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            _ = Glibc_or_Darwin_close(fd)
            throw LocalChannelError.unavailable("Postern could not listen on \(path).")
        }
        return fd
    }
    #endif

    /// The next connection of this user, blocking until one comes. Connections from another user are closed at once.
    public func accept() -> LocalConnection? {
        #if os(Windows)
        while true {
            let mode = DWORD(PIPE_ACCESS_DUPLEX) | (first ? DWORD(FILE_FLAG_FIRST_PIPE_INSTANCE) : 0)
            var attributes = SECURITY_ATTRIBUTES(nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size), lpSecurityDescriptor: security, bInheritHandle: false)
            let handle = name.withCString(encodedAs: UTF16.self) {
                CreateNamedPipeW($0, mode, DWORD(PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS),
                                 DWORD(PIPE_UNLIMITED_INSTANCES), 65_536, 65_536, 0, &attributes)
            }
            guard let handle, handle != INVALID_HANDLE_VALUE else {
                // Another process owns the name: refuse to serve rather than share it.
                if first { return nil }
                Sleep(200)
                continue
            }
            first = false
            let connected = ConnectNamedPipe(handle, nil) || GetLastError() == DWORD(ERROR_PIPE_CONNECTED)
            guard connected else {
                CloseHandle(handle)
                continue
            }
            var pid: ULONG = 0
            GetNamedPipeClientProcessId(handle, &pid)
            return LocalConnection(endpoint: Endpoint(handle: handle, server: true), peer: LocalPeer(processID: Int32(pid), userID: nil))
        }
        #else
        while true {
            let client = Glibc_or_Darwin_accept(descriptor)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return nil
            }
            var uid: UInt32 = 0
            var pid: Int32 = 0
            #if os(Linux)
            let known = postern_peer_credentials(client, &uid, &pid) == 0
            #else
            var gid: gid_t = 0
            let known = getpeereid(client, &uid, &gid) == 0
            #endif
            guard known, uid == getuid() else {
                _ = Glibc_or_Darwin_close(client)
                continue
            }
            return LocalConnection(endpoint: Endpoint(descriptor: client), peer: LocalPeer(processID: pid, userID: uid))
        }
        #endif
    }
}

#if !os(Windows)
@inline(__always) func Glibc_or_Darwin_accept(_ fd: Int32) -> Int32 {
    let client = accept(fd, nil, nil)
    // Not inherited by the reader processes the core starts.
    if client >= 0 { _ = fcntl(client, F_SETFD, FD_CLOEXEC) }
    return client
}
#endif

// MARK: - Connecting (the relay, the app, the command line)

public enum LocalChannel {
    /// Connects to this user's core. Throws when no core answers.
    public static func connect() throws -> LocalConnection {
        #if os(Windows)
        let name = PosternPaths.pipeName
        for _ in 0..<10 {
            let handle = name.withCString(encodedAs: UTF16.self) {
                CreateFileW($0, GENERIC_READ | DWORD(GENERIC_WRITE), 0, nil, DWORD(OPEN_EXISTING), 0, nil)
            }
            if let handle, handle != INVALID_HANDLE_VALUE {
                var pid: ULONG = 0
                GetNamedPipeServerProcessId(handle, &pid)
                return LocalConnection(endpoint: Endpoint(handle: handle, server: false), peer: LocalPeer(processID: Int32(pid), userID: nil))
            }
            guard GetLastError() == DWORD(ERROR_PIPE_BUSY) else { break }
            _ = name.withCString(encodedAs: UTF16.self) { WaitNamedPipeW($0, 2000) }
        }
        throw LocalChannelError.unavailable("Postern is not running.")
        #else
        let fd = try connectSocket(PosternPaths.socketPath)
        return LocalConnection(endpoint: Endpoint(descriptor: fd), peer: LocalPeer(processID: 0, userID: nil))
        #endif
    }

    #if !os(Windows)
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw LocalChannelError.unavailable("The socket path is too long: \(path)") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    static func connectSocket(_ path: String) throws -> Int32 {
        #if os(Linux)
        let fd = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        #else
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw LocalChannelError.unavailable("Postern could not open a socket.") }
        var address = try address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glibc_or_Darwin_connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            _ = Glibc_or_Darwin_close(fd)
            throw LocalChannelError.unavailable("Postern is not running.")
        }
        return fd
    }
    #endif
}

#if !os(Windows)
@inline(__always) func Glibc_or_Darwin_connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    #if canImport(Glibc)
    Glibc.connect(fd, address, length)
    #elseif canImport(Musl)
    Musl.connect(fd, address, length)
    #else
    Darwin.connect(fd, address, length)
    #endif
}
#endif
