import CPosternSys
import Foundation
import PosternMail
import PosternModel

// postern-parser: reads one raw message on its standard input and answers on its standard output, then exits.
// The core starts a fresh one for every message. On Linux it locks itself in before reading anything (no files, no
// network, no new programs, limited memory and time); on Windows the core starts it in an AppContainer with no
// capability. A message crafted to exploit the reader lands in a process that can reach nothing.

/// Loads everything the reader may need lazily (time zones, locale data, the HTML parser), so nothing has to be
/// opened once the jail is on.
func warmUp() {
    _ = TimeZone.current
    _ = Locale.current
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
    _ = formatter.date(from: "Tue, 24 Nov 2026 10:00:00 +0100")
    let sample = """
    From: Anna <anna@example.com>\r
    To: me@example.com\r
    Subject: =?UTF-8?Q?H=C3=A9llo?=\r
    Date: Tue, 24 Nov 2026 10:00:00 +0100\r
    MIME-Version: 1.0\r
    Content-Type: multipart/alternative; boundary=b\r
    \r
    --b\r
    Content-Type: text/plain; charset=iso-8859-1\r
    \r
    Caf\u{e9}\r
    --b\r
    Content-Type: text/html; charset=utf-8\r
    \r
    <html><body><p style="color:#000">Café <a href="https://example.com">link</a></p></body></html>\r
    --b--\r
    """
    _ = try? MessageSanitizer.sanitize(raw: Data(sample.utf8), maxChars: 1000)
    _ = try? JSONEncoder().encode(ParserAnswer(error: "warm"))
}

func readExactly(_ count: Int) -> Data? {
    var data = Data()
    while data.count < count {
        let chunk = FileHandle.standardInput.readData(ofLength: min(count - data.count, 1 << 20))
        if chunk.isEmpty { return nil }
        data.append(chunk)
    }
    return data
}

func readHeaderLine() -> Data? {
    var line = Data()
    while line.count < 4096 {
        let byte = FileHandle.standardInput.readData(ofLength: 1)
        guard let first = byte.first else { return nil }
        if first == 0x0A { return line }
        line.append(first)
    }
    return nil
}

func answer(_ answer: ParserAnswer) -> Never {
    let data = (try? JSONEncoder().encode(answer)) ?? Data(#"{"error":"The reader could not write its answer."}"#.utf8)
    FileHandle.standardOutput.write(data)
    exit(0)
}

warmUp()
// 3 GB of address space: the Swift runtime reserves more than it uses; a message is 25 MB at most. 60 s of CPU.
let jail = postern_jail(3 << 30, 60)
#if os(Linux)
if jail < 0 { answer(ParserAnswer(error: "The reader could not lock itself in, so it read nothing.")) }
#endif

guard let header = readHeaderLine(), let request = try? JSONDecoder().decode(ParserRequest.self, from: header),
      request.size >= 0, request.size <= ParserRequest.maxSize, let raw = readExactly(request.size) else {
    answer(ParserAnswer(error: "The reader did not receive a message it could read."))
}

switch request.operation {
case .sanitize:
    do {
        answer(ParserAnswer(message: try MessageSanitizer.sanitize(raw: raw, maxChars: request.maxChars)))
    } catch {
        answer(ParserAnswer(error: String(describing: error)))
    }
case .attachment:
    do {
        let file = try MessageSanitizer.attachment(raw: raw, index: request.index)
        answer(ParserAnswer(file: .init(data: file.data, filename: file.filename, mimeType: file.mimeType)))
    } catch {
        answer(ParserAnswer(error: "There is no attachment \(request.index) in this message."))
    }
case .readAttachment:
    do {
        answer(ParserAnswer(content: try MessageSanitizer.readAttachment(raw: raw, index: request.index, maxChars: request.maxChars)))
    } catch let failure as AttachmentReader.Failure {
        answer(ParserAnswer(error: failure.description))
    } catch {
        answer(ParserAnswer(error: "There is no attachment \(request.index) in this message, or it could not be read."))
    }
}
