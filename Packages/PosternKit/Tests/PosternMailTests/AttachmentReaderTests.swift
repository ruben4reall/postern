import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import PosternModel
@testable import PosternMail

@Suite struct AttachmentReaderTests {
    /// A one-page PDF with a text layer, written by hand.
    static let textPDF = Data("""
    %PDF-1.4
    1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
    2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
    3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 400 144] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >> endobj
    4 0 obj << /Length 52 >> stream
    BT /F1 18 Tf 20 100 Td (Facture 2026-117 CHF 42) Tj ET
    endstream endobj
    5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj
    trailer << /Root 1 0 R >>
    %%EOF
    """.utf8)

    /// Black text drawn on white, as a scanner or a phone would see it.
    static func picture(_ text: String) -> CGImage {
        let width = 1400, height = 300
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 64, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]))
        context.textPosition = CGPoint(x: 40, y: 120)
        CTLineDraw(line, context)
        return context.makeImage()!
    }

    static func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// A PDF whose only page is an image: a scan, with no text layer.
    static func scannedPDF(_ image: CGImage) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 700, height: 150)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    @Test func readsTheTextOfAPDF() throws {
        let content = try AttachmentReader.read(Self.textPDF, filename: "facture.pdf", mimeType: "application/pdf", maxChars: 20_000)
        #expect(content.kind == .pdf && content.pages == 1 && !content.recognized)
        #expect(content.text.contains("Facture 2026-117"))
    }

    @Test func recognizesTheTextOfAScanAndAPhoto() throws {
        let image = Self.picture("Postern reads scans")
        let scan = try AttachmentReader.read(Self.scannedPDF(image), filename: "scan.pdf", mimeType: "application/pdf", maxChars: 20_000)
        #expect(scan.recognized && scan.text.lowercased().contains("postern"))
        let photo = try AttachmentReader.read(Self.png(image), filename: "IMG_1.png", mimeType: "image/png", maxChars: 20_000)
        #expect(photo.kind == .image && photo.text.lowercased().contains("reads"))
    }

    @Test func readsTextFilesAndHTMLAsAPersonWouldSeeThem() throws {
        let csv = try AttachmentReader.read(Data("name;total\nAna;42\n".utf8), filename: "list.csv", mimeType: "text/csv", maxChars: 20_000)
        #expect(csv.kind == .text && csv.text == "name;total\nAna;42\n")
        let html = Data(#"<p>Visible</p><p style="display:none">Hidden order</p>"#.utf8)
        let page = try AttachmentReader.read(html, filename: "offer.html", mimeType: "text/html", maxChars: 20_000)
        #expect(page.text.contains("Visible") && !page.text.contains("Hidden"))
        let long = try AttachmentReader.read(Data(String(repeating: "a", count: 900).utf8), filename: "a.txt", mimeType: "text/plain", maxChars: 500)
        #expect(long.truncated && long.text.count == 500)
        #expect(throws: AttachmentReader.Failure.self) {
            try AttachmentReader.read(Data([0x50, 0x4B, 0x03, 0x04]), filename: "cv.docx", mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", maxChars: 500)
        }
    }
}
