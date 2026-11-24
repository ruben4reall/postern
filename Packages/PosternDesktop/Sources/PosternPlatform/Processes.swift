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

/// Starts the core on its own, outside the relay's session and process group, so it outlives the app that launched
/// the relay.
public enum CoreStarter {
    public static func start(_ program: URL) {
        #if os(Windows)
        _ = WindowsProcess.spawnDetached(program, arguments: [])
        #elseif os(Linux)
        _ = postern_spawn_detached(program.path)
        #else
        // Development builds on macOS only.
        let process = Process()
        process.executableURL = program
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        #endif
    }
}

#if os(Windows)
public enum WindowsProcess {
    /// The executable name of the process that started this one, such as claude.exe or Cursor.exe.
    public static func parentName() -> String? {
        let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0)
        guard let snapshot, snapshot != INVALID_HANDLE_VALUE else { return nil }
        defer { CloseHandle(snapshot) }
        var entry = PROCESSENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        var entries: [DWORD: (parent: DWORD, name: String)] = [:]
        if Process32FirstW(snapshot, &entry) {
            repeat {
                let name = withUnsafeBytes(of: entry.szExeFile) { raw -> String in
                    let units = raw.bindMemory(to: UInt16.self)
                    let length = units.firstIndex(of: 0) ?? units.count
                    return String(decoding: units.prefix(length), as: UTF16.self)
                }
                entries[entry.th32ProcessID] = (entry.th32ParentProcessID, name)
            } while Process32NextW(snapshot, &entry)
        }
        guard let parent = entries[GetCurrentProcessId()]?.parent, let name = entries[parent]?.name else { return nil }
        return name.hasSuffix(".exe") ? String(name.dropLast(4)) : name
    }

    /// Starts a program with no console, out of the caller's job when the job allows it, so it outlives the caller.
    @discardableResult
    public static func spawnDetached(_ program: URL, arguments: [String]) -> Bool {
        let commandLine = ([program.path] + arguments).map(quote).joined(separator: " ")
        var startup = STARTUPINFOW()
        startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        var information = PROCESS_INFORMATION()
        let flags = DWORD(DETACHED_PROCESS) | DWORD(CREATE_NEW_PROCESS_GROUP) | DWORD(CREATE_NO_WINDOW)
        for extra in [DWORD(CREATE_BREAKAWAY_FROM_JOB), 0] {
            var line = Array(commandLine.utf16) + [0]
            let ok = program.path.withCString(encodedAs: UTF16.self) { path in
                CreateProcessW(path, &line, nil, nil, false, flags | extra, nil, nil, &startup, &information)
            }
            if ok {
                CloseHandle(information.hThread)
                CloseHandle(information.hProcess)
                return true
            }
        }
        return false
    }

    /// Opens a new console window running a command, for the user to read and answer.
    public static func openConsole(_ program: URL, arguments: [String]) {
        let commandLine = ([program.path] + arguments).map(quote).joined(separator: " ")
        var startup = STARTUPINFOW()
        startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        var information = PROCESS_INFORMATION()
        var line = Array(commandLine.utf16) + [0]
        let flags = DWORD(CREATE_NEW_CONSOLE) | DWORD(CREATE_BREAKAWAY_FROM_JOB)
        var ok = program.path.withCString(encodedAs: UTF16.self) { path in
            CreateProcessW(path, &line, nil, nil, false, flags, nil, nil, &startup, &information)
        }
        if !ok {
            ok = program.path.withCString(encodedAs: UTF16.self) { path in
                CreateProcessW(path, &line, nil, nil, false, DWORD(CREATE_NEW_CONSOLE), nil, nil, &startup, &information)
            }
        }
        if ok {
            CloseHandle(information.hThread)
            CloseHandle(information.hProcess)
        }
    }

    static func quote(_ argument: String) -> String {
        guard argument.contains(where: { $0 == " " || $0 == "\"" || $0 == "\t" }) || argument.isEmpty else { return argument }
        return "\"" + argument.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Starts the message reader in an AppContainer with no capability: no network, no user files, no other app's
/// objects, and inside a job that kills it past its time or memory. It talks only through two pipes.
enum AppContainerLauncher {
    static let profile = "ch.rubencatalao.postern.reader"
    /// ProcThreadAttributeValue(ProcThreadAttributeHandleList, FALSE, TRUE, FALSE): a function-like macro Swift does
    /// not import.
    static let handleListAttribute = DWORD_PTR(0x0002_0002)
    /// ProcThreadAttributeValue(ProcThreadAttributeSecurityCapabilities, FALSE, TRUE, FALSE).
    static let securityCapabilitiesAttribute = DWORD_PTR(0x0002_0009)
    /// ALL APPLICATION PACKAGES: the reader's own files must be readable from inside the container.
    static let allPackages = "*S-1-15-2-1"
    nonisolated(unsafe) static var preparedFolder: String?
    static let lock = NSLock()

    static func containerSID() throws -> PSID {
        var sid: PSID?
        let created = profile.withCString(encodedAs: UTF16.self) { name in
            "Postern reader".withCString(encodedAs: UTF16.self) { display in
                CreateAppContainerProfile(name, display, display, nil, 0, &sid)
            }
        }
        if created == S_OK, let sid { return sid }
        let derived = profile.withCString(encodedAs: UTF16.self) { DeriveAppContainerSidFromAppContainerName($0, &sid) }
        guard derived == S_OK, let sid else { throw ReaderLaunchError.container }
        return sid
    }

    /// Lets the container read and run the reader's folder, once per run of the core.
    static func prepare(_ folder: URL) {
        lock.withLock {
            guard preparedFolder != folder.path else { return }
            let icacls = URL(fileURLWithPath: (ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#) + #"\System32\icacls.exe"#)
            let process = Process()
            process.executableURL = icacls
            process.arguments = [folder.path, "/grant", "\(allPackages):(OI)(CI)RX", "/Q"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            preparedFolder = folder.path
        }
    }

    static func run(program: URL, input: Data, seconds: Double) throws -> Data {
        prepare(program.deletingLastPathComponent())
        let sid = try containerSID()
        defer { FreeSid(sid) }

        // Two pipes: the child's ends are inheritable, ours are not.
        var inheritable = SECURITY_ATTRIBUTES(nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size), lpSecurityDescriptor: nil, bInheritHandle: true)
        var childIn: HANDLE?, parentIn: HANDLE?, parentOut: HANDLE?, childOut: HANDLE?
        guard CreatePipe(&childIn, &parentIn, &inheritable, 1 << 20), CreatePipe(&parentOut, &childOut, &inheritable, 1 << 20),
              let childIn, let parentIn, let parentOut, let childOut else { throw ReaderLaunchError.pipes }
        SetHandleInformation(parentIn, DWORD(HANDLE_FLAG_INHERIT), 0)
        SetHandleInformation(parentOut, DWORD(HANDLE_FLAG_INHERIT), 0)
        defer { CloseHandle(parentOut) }

        // The attribute list: the container with no capability, and exactly the two pipe ends to inherit.
        var size: SIZE_T = 0
        _ = InitializeProcThreadAttributeList(nil, 2, 0, &size)
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { list.deallocate() }
        let attributes: LPPROC_THREAD_ATTRIBUTE_LIST = OpaquePointer(list)
        guard InitializeProcThreadAttributeList(attributes, 2, 0, &size) else { throw ReaderLaunchError.attributes }
        defer { DeleteProcThreadAttributeList(attributes) }
        var capabilities = SECURITY_CAPABILITIES(AppContainerSid: sid, Capabilities: nil, CapabilityCount: 0, Reserved: 0)
        var handles: [HANDLE?] = [childIn, childOut]
        let securityOK = UpdateProcThreadAttribute(attributes, 0, securityCapabilitiesAttribute,
                                                   &capabilities, SIZE_T(MemoryLayout<SECURITY_CAPABILITIES>.size), nil, nil)
        let handlesOK = handles.withUnsafeMutableBufferPointer { buffer in
            UpdateProcThreadAttribute(attributes, 0, handleListAttribute, buffer.baseAddress,
                                      SIZE_T(MemoryLayout<HANDLE?>.size * buffer.count), nil, nil)
        }
        guard securityOK, handlesOK else { throw ReaderLaunchError.attributes }

        var startup = STARTUPINFOEXW()
        startup.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
        startup.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES)
        startup.StartupInfo.hStdInput = childIn
        startup.StartupInfo.hStdOutput = childOut
        startup.StartupInfo.hStdError = childOut
        startup.lpAttributeList = attributes
        var information = PROCESS_INFORMATION()
        var line = Array(WindowsProcess.quote(program.path).utf16) + [0]
        let flags = DWORD(EXTENDED_STARTUPINFO_PRESENT) | DWORD(CREATE_NO_WINDOW) | DWORD(CREATE_SUSPENDED)
        let started = program.path.withCString(encodedAs: UTF16.self) { path in
            withUnsafeMutablePointer(to: &startup) { pointer in
                pointer.withMemoryRebound(to: STARTUPINFOW.self, capacity: 1) {
                    CreateProcessW(path, &line, nil, nil, true, flags, nil, nil, $0, &information)
                }
            }
        }
        CloseHandle(childIn)
        CloseHandle(childOut)
        guard started else {
            CloseHandle(parentIn)
            throw ReaderLaunchError.start
        }
        defer {
            CloseHandle(information.hThread)
            CloseHandle(information.hProcess)
        }

        // A job: killed with its handle, one process, 3 GB of memory, no error dialog.
        let job = CreateJobObjectW(nil, nil)
        defer { if let job { CloseHandle(job) } }
        if let job {
            var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
            limits.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE) | DWORD(JOB_OBJECT_LIMIT_ACTIVE_PROCESS)
                | DWORD(JOB_OBJECT_LIMIT_PROCESS_MEMORY) | DWORD(JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION)
            limits.BasicLimitInformation.ActiveProcessLimit = 1
            limits.ProcessMemoryLimit = SIZE_T(3 << 30)
            SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size))
            AssignProcessToJobObject(job, information.hProcess)
        }
        ResumeThread(information.hThread)

        // Handles cross into these closures as numbers: they are plain addresses, owned by this function.
        let inputPipe = UInt(bitPattern: parentIn)
        let writer = Thread {
            guard let pipe = HANDLE(bitPattern: inputPipe) else { return }
            var offset = 0
            while offset < input.count {
                var written: DWORD = 0
                let ok = input.withUnsafeBytes { WriteFile(pipe, $0.baseAddress! + offset, DWORD(min(input.count - offset, 1 << 20)), &written, nil) }
                guard ok, written > 0 else { break }
                offset += Int(written)
            }
            CloseHandle(pipe)
        }
        writer.start()
        let jobHandle = job.map { UInt(bitPattern: $0) }
        let processHandle = information.hProcess.map { UInt(bitPattern: $0) }
        let watchdog = DispatchWorkItem {
            if let jobHandle, let handle = HANDLE(bitPattern: jobHandle) {
                TerminateJobObject(handle, 1)
            } else if let processHandle, let handle = HANDLE(bitPattern: processHandle) {
                TerminateProcess(handle, 1)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: watchdog)
        defer { watchdog.cancel() }
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            var read: DWORD = 0
            let ok = ReadFile(parentOut, &chunk, DWORD(chunk.count), &read, nil)
            guard ok, read > 0 else { break }
            output.append(contentsOf: chunk.prefix(Int(read)))
            if output.count > 40_000_000 { break }
        }
        WaitForSingleObject(information.hProcess, 2000)
        return output
    }
}

enum ReaderLaunchError: Error {
    case container, pipes, attributes, start
}
#endif
