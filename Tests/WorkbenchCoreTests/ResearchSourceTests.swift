import XCTest
import Foundation
import PDFKit
import AppKit
import Darwin
@testable import WorkbenchCore

final class ResearchSourceTests: XCTestCase {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("research-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
    private func capture(_ url: URL, limits: ResearchSourceLimits = .init()) throws -> ResearchSourceCapture {
        try ResearchSourceIngestor.capture(reviewed: ResearchSourceIngestor.review(url: url, limits: limits), limits: limits)
    }

    func testRTFMagicOverridesMarkdownExtensionAndPreservesOriginal() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("lab.md")
            let bytes = Data("{\\rtf1\\ansi Native \\b evidence\\b0 .}".utf8)
            try bytes.write(to: url)
            let result = try capture(url)
            XCTAssertEqual(result.format, .rtf)
            XCTAssertEqual(result.extractedText, "Native evidence.")
            XCTAssertFalse(result.fullDocumentTextCoverage)
            XCTAssertFalse(result.warnings.isEmpty)
            XCTAssertEqual(result.original.byteCount, bytes.count)
            XCTAssertEqual(result.original.sha256, ResearchSourceIngestor.sha256(bytes))
            XCTAssertEqual(result.original.canonicalPath, url.path)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            try bytes.dropLast().write(to: url)
            XCTAssertThrowsError(try capture(url))
            try bytes.write(to: url)
            XCTAssertEqual(try JSONDecoder().decode(ResearchSourceCapture.self, from: JSONEncoder().encode(result)), result)
        }
    }

    func testUnicodeWindowsReassembleExactlyAndRejectImpossibleOrTamperedWindows() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("text.pdf")
            let text = "A e\u{301} 漢字 \u{1F469}\u{200D}\u{1F4BB}\r\nend\n"
            try Data(text.utf8).write(to: url)
            let result = try capture(url)
            XCTAssertEqual(result.format, .utf8Text)
            let windows = try result.windows(maxUTF8Bytes: 12)
            XCTAssertEqual(try result.reassemble(windows), text)
            XCTAssertEqual(windows, try result.windows(maxUTF8Bytes: 12))
            XCTAssertTrue(windows.allSatisfy { $0.text.utf8.count <= 12 })
            XCTAssertThrowsError(try result.windows(maxUTF8Bytes: 2))
            XCTAssertThrowsError(try result.windows(maxUTF8Bytes: 12, maxWindows: 1))
            XCTAssertThrowsError(try result.windows(maxUTF8Bytes: 0))
            XCTAssertThrowsError(try result.reassemble(Array(windows.dropLast())))
            XCTAssertThrowsError(try result.reassemble(Array(windows.reversed())))
            let forged = ResearchSourceWindow(index: 0, startUTF8: 0, endUTF8: 1, text: "B", sha256: windows[0].sha256)
            XCTAssertThrowsError(try result.reassemble([forged]))
        }
    }

    func testMutationPathAndLimits() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("original")
            try Data("first".utf8).write(to: url)
            let review = try ResearchSourceIngestor.review(url: url)
            try Data("other".utf8).write(to: url)
            XCTAssertThrowsError(try ResearchSourceIngestor.capture(reviewed: review)) { XCTAssertEqual($0 as? ResearchSourceError, .sourceChanged) }
            let wrongPath = ResearchSourceIdentity(canonicalPath: url.path + "-missing", sha256: review.sha256, byteCount: review.byteCount)
            XCTAssertThrowsError(try ResearchSourceIngestor.capture(reviewed: wrongPath))
            XCTAssertThrowsError(try capture(url, limits: .init(maxOriginalBytes: 4)))
            XCTAssertThrowsError(try capture(url, limits: .init(maxExtractedUTF8Bytes: 4))) { XCTAssertEqual($0 as? ResearchSourceError, .textLimit) }
            XCTAssertThrowsError(try capture(url, limits: .init(maxOriginalBytes: 0)))
            XCTAssertThrowsError(try ResearchSourceIngestor.review(url: directory))
            let fifo = directory.appendingPathComponent("pipe")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
            XCTAssertThrowsError(try ResearchSourceIngestor.review(url: fifo)) { XCTAssertEqual($0 as? ResearchSourceError, .notRegularFile) }
            let link = directory.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            XCTAssertThrowsError(try ResearchSourceIngestor.review(url: link))
            let parentLink = directory.appendingPathComponent("parent-link")
            try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: directory)
            XCTAssertThrowsError(try ResearchSourceIngestor.review(url: parentLink.appendingPathComponent("original")))
        }
    }

    func testImagesUnsupportedAndEmptySourcesHaveExplicitOutcomes() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("pretend.md")
            try Data([137,80,78,71,13,10,26,10,0]).write(to: url)
            let image = try capture(url)
            XCTAssertEqual(image.format, .image)
            XCTAssertEqual(image.extractedText, "")
            XCTAssertFalse(image.fullDocumentTextCoverage)
            XCTAssertFalse(image.warnings.isEmpty)
            try Data([0,1,2,255]).write(to: url)
            let unsupported = try capture(url)
            XCTAssertEqual(unsupported.format, .unsupported)
            XCTAssertFalse(unsupported.warnings.isEmpty)
            try Data().write(to: url)
            let empty = try capture(url)
            XCTAssertEqual(try empty.reassemble(empty.windows(maxUTF8Bytes: 1)), "")
            try Data("%PDF-invalid".utf8).write(to: url)
            XCTAssertThrowsError(try capture(url))
        }
    }

    func testPDFTextAndImageOnlyGapHavePageReceipts() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("report.md")
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 300, height: 200)
            let consumer = CGDataConsumer(data: data)!
            let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Native PDF text", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
            context.textPosition = CGPoint(x: 20, y: 100)
            CTLineDraw(line, context)
            context.endPDFPage()
            context.beginPDFPage(nil)
            let pixels = Data([0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 255])
            let provider = CGDataProvider(data: pixels as CFData)!
            let image = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            context.draw(image, in: CGRect(x: 30, y: 30, width: 80, height: 80))
            context.endPDFPage()
            context.closePDF()
            try (data as Data).write(to: url)
            let result = try capture(url)
            XCTAssertEqual(result.format, .pdf)
            XCTAssertEqual(result.pages.count, 2)
            XCTAssertTrue(result.pages[0].hasExtractableText)
            XCTAssertFalse(result.pages[1].hasExtractableText)
            XCTAssertTrue(result.extractedText.contains("Native PDF text"))
            XCTAssertTrue(result.warnings.contains { $0.contains("Page 2") })
            XCTAssertFalse(result.fullDocumentTextCoverage)
            XCTAssertEqual(try result.reassemble(result.windows(maxUTF8Bytes: 8)), result.extractedText)
            XCTAssertThrowsError(try capture(url, limits: .init(maxPDFPages: 1))) { XCTAssertEqual($0 as? ResearchSourceError, .pageLimit) }
            XCTAssertThrowsError(try capture(url, limits: .init(maxExtractedUTF8Bytes: 2)))
        }
    }
}
