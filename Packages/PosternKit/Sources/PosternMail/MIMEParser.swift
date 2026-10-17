import Foundation
import PosternText

/// Parses RFC 5322 and MIME structure from raw bytes. Every input is treated as hostile: sizes, depth and part
/// counts are bounded, and malformed structure degrades to a single opaque part instead of failing.
public enum MIMEParser {
    public static func parse(_ data: Data, limits: MIMELimits = MIMELimits()) throws -> MIMEEntity {
        guard data.count <= limits.maxBytes else { throw MIMEError.tooLarge }
        var partCount = 0
        return try parseEntity(Array(data)[...], depth: 0, limits: limits, partCount: &partCount)
    }

    private static func parseEntity(
        _ bytes: ArraySlice<UInt8>, depth: Int, limits: MIMELimits, partCount: inout Int
    ) throws -> MIMEEntity {
        guard depth <= limits.maxDepth else { throw MIMEError.tooDeep }
        partCount += 1
        guard partCount <= limits.maxParts else { throw MIMEError.tooManyParts }

        let (headerBytes, bodyBytes) = splitHeaderAndBody(bytes)
        guard headerBytes.count <= limits.maxHeaderBytes else { throw MIMEError.headerTooLarge }
        let headers = parseHeaders(headerBytes)
        let field = { (name: String) in headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }

        let contentType = field("Content-Type").map(parseContentType) ?? .defaultText
        let encoding = (field("Content-Transfer-Encoding") ?? "7bit")
            .trimmingCharacters(in: .whitespaces).lowercased()
        let (disposition, dispositionParameters) = field("Content-Disposition").map(parseDisposition) ?? (nil, [:])

        if contentType.type == "multipart", let boundary = contentType.parameters["boundary"], !boundary.isEmpty {
            var parts: [MIMEEntity] = []
            for slice in splitMultipart(bodyBytes, boundary: boundary) {
                parts.append(try parseEntity(slice, depth: depth + 1, limits: limits, partCount: &partCount))
            }
            return MIMEEntity(
                headers: headers, contentType: contentType, transferEncoding: encoding, disposition: disposition,
                dispositionParameters: dispositionParameters, body: .multipart(parts)
            )
        }
        return MIMEEntity(
            headers: headers, contentType: contentType, transferEncoding: encoding, disposition: disposition,
            dispositionParameters: dispositionParameters, body: .leaf(Data(bodyBytes))
        )
    }

    // MARK: Headers

    static func splitHeaderAndBody(_ bytes: ArraySlice<UInt8>) -> (ArraySlice<UInt8>, ArraySlice<UInt8>) {
        var index = bytes.startIndex
        // A part that starts with an empty line has no headers.
        if bytes.starts(with: [13, 10]) { return (bytes[index..<index], bytes.dropFirst(2)) }
        if bytes.starts(with: [10]) { return (bytes[index..<index], bytes.dropFirst(1)) }
        while index < bytes.endIndex {
            if bytes[index] == 10 {
                let next = bytes.index(after: index)
                if next < bytes.endIndex, bytes[next] == 10 {
                    return (bytes[bytes.startIndex..<index], bytes[bytes.index(after: next)...])
                }
                if next < bytes.endIndex, bytes[next] == 13 {
                    let afterCR = bytes.index(after: next)
                    if afterCR < bytes.endIndex, bytes[afterCR] == 10 {
                        return (bytes[bytes.startIndex..<index], bytes[bytes.index(after: afterCR)...])
                    }
                }
            }
            index = bytes.index(after: index)
        }
        return (bytes, bytes[bytes.endIndex...])
    }

    static func parseHeaders(_ bytes: ArraySlice<UInt8>) -> [HeaderField] {
        // Swift treats CRLF as one Character: normalize before splitting on line feeds.
        let text = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var fields: [HeaderField] = []
        var name: String?
        var value = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            if let first = line.first, first == " " || first == "\t" {
                value += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            if let name { fields.append(HeaderField(name: name, value: value.trimmingCharacters(in: .whitespaces))) }
            name = nil
            value = ""
            guard let colon = line.firstIndex(of: ":") else { continue }
            let candidate = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty, candidate.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { continue }
            name = candidate
            value = String(line[line.index(after: colon)...])
        }
        if let name { fields.append(HeaderField(name: name, value: value.trimmingCharacters(in: .whitespaces))) }
        return fields
    }

    // MARK: Parameters

    static func parseContentType(_ value: String) -> ContentType {
        let (main, parameters) = splitParameters(value)
        let pieces = main.lowercased().split(separator: "/", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty else {
            return ContentType(type: "application", subtype: "octet-stream", parameters: parameters)
        }
        return ContentType(type: pieces[0], subtype: pieces[1], parameters: parameters)
    }

    static func parseDisposition(_ value: String) -> (String?, [String: String]) {
        let (main, parameters) = splitParameters(value)
        let kind = main.trimmingCharacters(in: .whitespaces).lowercased()
        return (kind.isEmpty ? nil : kind, parameters)
    }

    /// Splits `main; a=1; b*=utf-8''x; c*0=..; c*1=..` into the main value and decoded parameters.
    static func splitParameters(_ value: String) -> (String, [String: String]) {
        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for character in value {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" && inQuotes { escaped = true; continue }
            if character == "\"" { inQuotes.toggle(); continue }
            if character == ";" && !inQuotes { pieces.append(current); current = ""; continue }
            current.append(character)
        }
        pieces.append(current)
        let main = pieces.first ?? ""

        var simple: [String: String] = [:]
        var extended: [String: [(Int, String, Bool)]] = [:]
        for piece in pieces.dropFirst() {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let key = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let raw = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            // RFC 2231: name*=charset'lang'value, name*0=..., name*1*=...
            if let star = key.firstIndex(of: "*") {
                let base = String(key[..<star])
                let rest = key[key.index(after: star)...]
                let encoded = rest.hasSuffix("*") || rest.isEmpty
                let section = Int(rest.trimmingCharacters(in: CharacterSet(charactersIn: "*"))) ?? 0
                extended[base, default: []].append((section, raw, encoded))
            } else {
                simple[key] = raw
            }
        }
        for (base, sections) in extended {
            let ordered = sections.sorted { $0.0 < $1.0 }
            var charset: String.Encoding = .utf8
            var bytes = Data()
            for (offset, item) in ordered.enumerated() {
                var text = item.1
                if item.2 {
                    if offset == 0 {
                        let parts = text.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                        if parts.count == 3 {
                            charset = Charsets.encoding(named: String(parts[0])) ?? .utf8
                            text = String(parts[2])
                        }
                    }
                    bytes.append(percentDecode(text))
                } else {
                    bytes.append(Data(text.utf8))
                }
            }
            simple[base] = String(data: bytes, encoding: charset) ?? String(decoding: bytes, as: UTF8.self)
        }
        return (main, simple)
    }

    private static func percentDecode(_ text: String) -> Data {
        var out = Data()
        var iterator = Array(text.utf8).makeIterator()
        while let byte = iterator.next() {
            if byte == UInt8(ascii: "%"), let high = iterator.next(), let low = iterator.next(),
               let value = UInt8(String(decoding: [high, low], as: UTF8.self), radix: 16) {
                out.append(value)
            } else {
                out.append(byte)
            }
        }
        return out
    }

    // MARK: Multipart

    static func splitMultipart(_ body: ArraySlice<UInt8>, boundary: String) -> [ArraySlice<UInt8>] {
        let delimiter = Array("--\(boundary)".utf8)
        var parts: [ArraySlice<UInt8>] = []
        var lineStart = body.startIndex
        var partStart: Int?
        var index = body.startIndex
        while index <= body.endIndex {
            let atEnd = index == body.endIndex
            if atEnd || body[index] == 10 {
                let line = body[lineStart..<index]
                let trimmed = line.last == 13 ? line.dropLast() : line
                if trimmed.starts(with: delimiter) {
                    let tail = trimmed.dropFirst(delimiter.count)
                    let isClose = tail.starts(with: [45, 45])
                    let isBoundary = isClose || tail.allSatisfy { $0 == 32 || $0 == 9 }
                    if isBoundary {
                        if let start = partStart {
                            // The line break before a boundary belongs to the boundary.
                            var end = lineStart
                            if end > start, body[end - 1] == 10 { end -= 1 }
                            if end > start, body[end - 1] == 13 { end -= 1 }
                            parts.append(body[start..<end])
                        }
                        if isClose { return parts }
                        partStart = atEnd ? body.endIndex : index + 1
                    }
                }
                lineStart = atEnd ? body.endIndex : index + 1
            }
            if atEnd { break }
            index += 1
        }
        // Missing close delimiter: keep what was collected, including the last open part.
        if let start = partStart, start < body.endIndex { parts.append(body[start..<body.endIndex]) }
        return parts
    }
}

enum TransferDecoding {
    static func base64(_ data: Data) -> Data {
        let filtered = data.filter { byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || byte == 43 || byte == 47
        }
        var text = String(decoding: filtered, as: UTF8.self)
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text) ?? Data()
    }

    static func quotedPrintable(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)
        let bytes = Array(data)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == UInt8(ascii: "=") else { out.append(byte); index += 1; continue }
            // Soft line break: "=" then optional spaces, then CRLF or LF.
            var look = index + 1
            while look < bytes.count, bytes[look] == 32 || bytes[look] == 9 { look += 1 }
            if look < bytes.count, bytes[look] == 13, look + 1 < bytes.count, bytes[look + 1] == 10 {
                index = look + 2; continue
            }
            if look < bytes.count, bytes[look] == 10 { index = look + 1; continue }
            if look >= bytes.count { index = look; continue }
            if index + 2 < bytes.count,
               let value = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                out.append(value)
                index += 3
            } else {
                out.append(byte)
                index += 1
            }
        }
        return out
    }
}
