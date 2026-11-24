import Foundation
import PosternCompose
import PosternModel
import PosternServer
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Windows)
import WinSDK
#endif

/// The two folders Postern touches on disk, both inside Downloads: saved attachments, and the outbox, the only
/// place a file can be attached from.
public enum PosternFolders {
    public static let maxOutboxFile = OutgoingMessage.maxAttachmentBytes

    /// Set once at start-up by a platform whose Downloads folder is elsewhere, and by tests.
    nonisolated(unsafe) public static var downloadsOverride: URL?

    public static var downloads: URL {
        if let downloadsOverride { return downloadsOverride }
        #if os(macOS)
        // The app is sandboxed: its home is its container, so ask for the real one.
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else {
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        return URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Downloads", isDirectory: true)
        #elseif os(Linux)
        return XDGUserDirs.download()
        #else
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        #endif
    }

    public static var saved: URL { downloads.appendingPathComponent("Postern", isDirectory: true) }
    public static var outbox: URL { saved.appendingPathComponent("Outbox", isDirectory: true) }

    public static func prepare() {
        try? FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
    }

    /// A file name with no path, no leading dot, no control or invisible characters.
    public static func safeName(_ name: String) -> String {
        let cleaned = name.unicodeScalars.filter { scalar in
            !"/\\:".unicodeScalars.contains(scalar) && scalar.properties.generalCategory != .control
                && scalar.properties.generalCategory != .format
        }
        var result = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix(".") { result.removeFirst() }
        #if os(Windows)
        // Names Windows reserves for devices, whatever the extension.
        let stem = result.split(separator: ".").first.map { $0.uppercased() } ?? ""
        if ["CON", "PRN", "AUX", "NUL"].contains(stem) || stem.range(of: #"^(COM|LPT)[0-9]$"#, options: .regularExpression) != nil {
            result = "_" + result
        }
        result = String(result.unicodeScalars.filter { !"<>\"|?*".unicodeScalars.contains($0) }.map(Character.init))
        while result.hasSuffix(".") || result.hasSuffix(" ") { result.removeLast() }
        #endif
        if result.isEmpty { result = "attachment" }
        return String(result.prefix(150))
    }

    public static func save(_ data: Data, suggestedName: String, mimeType: String) throws -> SavedAttachment {
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        let name = safeName(suggestedName)
        var url = saved.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            url = saved.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            counter += 1
        }
        try data.write(to: url, options: .withoutOverwriting)
        markDownloaded(url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return SavedAttachment(path: url.path, filename: url.lastPathComponent, mimeType: mimeType, size: data.count, sha256: hash)
    }

    /// Marked as downloaded, so the system's checks for files from the internet apply before it opens.
    static func markDownloaded(_ url: URL) {
        #if os(macOS)
        var url = url
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
            kLSQuarantineAgentNameKey as String: "Postern",
        ]
        try? url.setResourceValues(values)
        #elseif os(Windows)
        // The Mark of the Web: SmartScreen and Office's Protected View treat the file as coming from the internet.
        let stream = URL(fileURLWithPath: url.path + ":Zone.Identifier")
        try? Data("[ZoneTransfer]\r\nZoneId=3\r\n".utf8).write(to: stream)
        #endif
    }

    /// Only a plain file inside the outbox, directly or in a subfolder such as `Letters/Acme.pdf`: no `..`, no
    /// hidden name, no link anywhere on the way, so nothing outside the outbox can be reached.
    public static func outboxFile(named name: String) throws -> OutgoingAttachment {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= 4, parts.allSatisfy({ $0 == safeName($0) && $0 != ".." && $0 != "." }) else {
            throw PosternError(.invalidArgument, "\(name) is not a file name Postern accepts. Attachments come only from Downloads › Postern › Outbox.")
        }
        var url = outbox
        for (index, part) in parts.enumerated() {
            url.appendPathComponent(part, isDirectory: index < parts.count - 1)
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            guard let values, values.isSymbolicLink != true,
                  index < parts.count - 1 ? values.isDirectory == true : values.isRegularFile == true else {
                throw PosternError(.notFound, "\(name) is not in Downloads › Postern › Outbox. Put the file there first.")
            }
        }
        let data = try readPlainFile(url, name: name)
        do {
            return try OutgoingAttachment.make(filename: parts[parts.count - 1], data: data)
        } catch {
            throw PosternError(.invalidArgument, "\(name) could not be attached.")
        }
    }

    /// Reads the file through a handle opened without following a link, and checks that very file: a regular
    /// file with a single name, so neither a link swapped in after the checks nor a hard link to a file elsewhere
    /// is read.
    public static func readPlainFile(_ url: URL, name: String) throws -> Data {
        let values = try? outbox.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else {
            throw PosternError(.invalidArgument, "The outbox folder is a link; Postern reads only a real folder.")
        }
        let missing = PosternError(.notFound, "\(name) is not in Downloads › Postern › Outbox. Put the file there first.")
        let notPlain = PosternError(.invalidArgument, "\(name) is not a plain file of its own; Postern does not read links.")
        #if os(Windows)
        let handle = url.path.withCString(encodedAs: UTF16.self) { path in
            CreateFileW(path, GENERIC_READ, DWORD(FILE_SHARE_READ), nil, DWORD(OPEN_EXISTING),
                        DWORD(FILE_FLAG_OPEN_REPARSE_POINT) | DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { throw missing }
        defer { CloseHandle(handle) }
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &info),
              info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0,
              info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0, info.nNumberOfLinks == 1 else { throw notPlain }
        let size = (UInt64(info.nFileSizeHigh) << 32) | UInt64(info.nFileSizeLow)
        guard size <= UInt64(maxOutboxFile) else { throw PosternError(.tooLarge, "\(name) is larger than 20 MB.") }
        var data = Data(count: Int(size))
        var total = 0
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            while total < Int(size) {
                var read: DWORD = 0
                guard ReadFile(handle, buffer.baseAddress! + total, DWORD(Int(size) - total), &read, nil), read > 0 else { return false }
                total += Int(read)
            }
            return true
        }
        guard ok else { throw PosternError(.invalidArgument, "\(name) could not be read.") }
        return data
        #else
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw missing }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { throw notPlain }
        guard Int(info.st_size) <= maxOutboxFile else { throw PosternError(.tooLarge, "\(name) is larger than 20 MB.") }
        guard let data = try? handle.readToEnd() else { throw PosternError(.invalidArgument, "\(name) could not be read.") }
        return data
        #endif
    }

    /// The files of the outbox and its subfolders, three levels deep at most, without hidden files or links.
    public static func outboxFiles() -> [OutboxFile] {
        var found: [OutboxFile] = []
        func visit(_ folder: URL, prefix: String, depth: Int) {
            let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            guard depth < 4, found.count < 5000, let entries = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            ) else { return }
            for entry in entries {
                let name = entry.lastPathComponent
                guard name == safeName(name), let values = try? entry.resourceValues(forKeys: Set(keys)),
                      values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    visit(entry, prefix: prefix + name + "/", depth: depth + 1)
                } else if values.isRegularFile == true {
                    found.append(OutboxFile(path: prefix + name, size: values.fileSize ?? 0, modified: values.contentModificationDate))
                }
            }
        }
        visit(outbox, prefix: "", depth: 0)
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

#if os(Linux)
/// The user's Downloads folder as the desktop names it (`XDG_DOWNLOAD_DIR` in `~/.config/user-dirs.dirs`), which
/// a French desktop calls `~/Téléchargements`.
enum XDGUserDirs {
    static func download() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        if let text = try? String(contentsOf: config.appendingPathComponent("user-dirs.dirs"), encoding: .utf8) {
            for line in text.split(separator: "\n") where line.hasPrefix("XDG_DOWNLOAD_DIR=") {
                var value = line.dropFirst("XDG_DOWNLOAD_DIR=".count).trimmingCharacters(in: .whitespaces)
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if value.hasPrefix("$HOME") { value = home.path + value.dropFirst("$HOME".count) }
                if value.hasPrefix("/"), value != home.path { return URL(fileURLWithPath: value, isDirectory: true) }
            }
        }
        return home.appendingPathComponent("Downloads", isDirectory: true)
    }
}
#endif
