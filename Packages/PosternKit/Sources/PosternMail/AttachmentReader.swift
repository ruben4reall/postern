import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import PosternModel
import PosternText
import Vision

/// Reads the text of an attachment: a PDF's text, or what Vision recognizes on scanned pages and photos; text, CSV,
/// JSON, calendar and contact files as they are; HTML as a person would see it. It runs in the parser service, so a
/// file crafted against PDFKit or ImageIO lands in a process with no network, no Keychain and no files.
public enum AttachmentReader {
    public enum Failure: Error, CustomStringConvertible {
        case unsupported(String)
        case unreadable(String)

        public var description: String {
            switch self {
            case .unsupported(let type): "Postern cannot read this kind of file (\(type)); save_attachment saves it to Downloads."
            case .unreadable(let reason): reason
            }
        }
    }

    /// Pages read from a PDF's text, and pages recognized when a PDF has no text, such as a scan.
    static let maxPages = 300
    static let maxRecognizedPages = 10
    /// The longest side of an image handed to Vision.
    static let maxPixels = 3000

    public static func read(
        _ data: Data, filename: String?, mimeType: String, maxChars: Int
    ) throws -> AttachmentContent {
        let type = mimeType.lowercased()
        let ext = (filename.map { ($0 as NSString).pathExtension.lowercased() }) ?? ""
        var content: (kind: AttachmentContent.Kind, text: String, pages: Int?, recognized: Bool)
        if type == "application/pdf" || ext == "pdf" || data.starts(with: Array("%PDF".utf8)) {
            content = try pdf(data, maxChars: maxChars)
        } else if type.hasPrefix("image/") || ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"].contains(ext) {
            content = (.image, try recognize(image: data), nil, true)
        } else if type == "text/html" || ["html", "htm"].contains(ext) {
            content = (.html, HTMLSanitizer().render(decode(data)).text, nil, false)
        } else if type.hasPrefix("text/") || ["application/json", "application/xml", "application/csv", "application/ics"].contains(type)
                    || ["txt", "csv", "tsv", "md", "json", "xml", "ics", "vcf", "log", "yaml", "yml"].contains(ext) {
            content = (.text, decode(data), nil, false)
        } else {
            throw Failure.unsupported(mimeType)
        }
        var text = UnicodeCleaner.clean(content.text, keepNewlines: true)
        let truncated = text.count > maxChars
        if truncated { text = String(text.prefix(maxChars)) }
        return AttachmentContent(
            filename: filename.map { UnicodeCleaner.clean($0, keepNewlines: false) }, mimeType: mimeType, size: data.count, kind: content.kind, text: text,
            pages: content.pages, recognized: content.recognized, truncated: truncated
        )
    }

    // MARK: PDF

    static func pdf(_ data: Data, maxChars: Int) throws -> (kind: AttachmentContent.Kind, text: String, pages: Int?, recognized: Bool) {
        guard let document = PDFDocument(data: data) else { throw Failure.unreadable("This PDF could not be opened.") }
        guard !document.isLocked else { throw Failure.unreadable("This PDF is protected by a password.") }
        let count = document.pageCount
        var parts: [String] = []
        var length = 0
        for index in 0..<min(count, maxPages) where length <= maxChars {
            let text = document.page(at: index)?.string ?? ""
            parts.append(text)
            length += text.count
        }
        let text = parts.joined(separator: "\n\n")
        // Fewer than five letters or digits a page: a scan. The images of its first pages are read instead.
        let meaningful = text.filter { $0.isLetter || $0.isNumber }.count
        if meaningful >= 5 * max(1, parts.count) { return (.pdf, text, count, false) }
        var recognized: [String] = []
        for index in 0..<min(count, maxRecognizedPages) {
            guard let page = document.page(at: index), let image = render(page) else { continue }
            recognized.append(recognize(image))
        }
        let ocr = recognized.joined(separator: "\n\n")
        guard ocr.count > text.count else { return (.pdf, text, count, false) }
        return (.pdf, ocr, count, true)
    }

    /// A page drawn on white, about 200 dots per inch, at most `maxPixels` on its longest side.
    static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(200.0 / 72.0, Double(maxPixels) / Double(max(bounds.width, bounds.height)))
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    // MARK: Images

    static func recognize(image data: Data) throws -> String {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.unreadable("This image could not be opened.")
        }
        return recognize(image)
    }

    /// The text Vision finds on an image, line by line, on this Mac only.
    static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return "" }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    // MARK: Text

    /// UTF-8 or UTF-16 with its mark, else the Windows encoding older programs write.
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16) ?? ""
        }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        if let text = String(data: bytes, encoding: .utf8) { return text }
        return String(data: bytes, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
    }
}
