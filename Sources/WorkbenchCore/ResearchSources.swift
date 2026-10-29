import Foundation
import CryptoKit
import PDFKit
import AppKit
import Darwin

public enum ResearchSourceFormat: String, Codable, Sendable {
    case utf8Text, pdf, rtf, image, unsupported
}

public struct ResearchSourceIdentity: Codable, Sendable, Equatable {
    public let canonicalPath: String
    public let sha256: String
    public let byteCount: Int
    public init(canonicalPath: String, sha256: String, byteCount: Int) {
        self.canonicalPath = canonicalPath; self.sha256 = sha256; self.byteCount = byteCount
    }
}

/// Offsets are half-open UTF-8 byte offsets in the complete extracted text.
public struct ResearchSourcePage: Codable, Sendable, Equatable {
    public let number: Int
    public let startUTF8: Int
    public let endUTF8: Int
    public let hasExtractableText: Bool
    public init(number: Int, startUTF8: Int, endUTF8: Int, hasExtractableText: Bool) {
        self.number = number; self.startUTF8 = startUTF8; self.endUTF8 = endUTF8
        self.hasExtractableText = hasExtractableText
    }
}

public struct ResearchSourceWindow: Codable, Sendable, Equatable {
    public let index: Int
    public let startUTF8: Int
    public let endUTF8: Int
    public let text: String
    public let sha256: String
    public init(index: Int, startUTF8: Int, endUTF8: Int, text: String, sha256: String) {
        self.index = index; self.startUTF8 = startUTF8; self.endUTF8 = endUTF8
        self.text = text; self.sha256 = sha256
    }
}

public struct ResearchSourceCapture: Codable, Sendable, Equatable {
    public let original: ResearchSourceIdentity
    public let format: ResearchSourceFormat
    public let extractedText: String
    public let extractedTextSHA256: String
    public let warnings: [String]
    public let pages: [ResearchSourcePage]
    /// True only for decoded plain text. Native PDF/RTF extraction cannot certify visual coverage.
    public let fullDocumentTextCoverage: Bool
    public init(original: ResearchSourceIdentity, format: ResearchSourceFormat, extractedText: String,
                extractedTextSHA256: String, warnings: [String], pages: [ResearchSourcePage],
                fullDocumentTextCoverage: Bool) {
        self.original = original; self.format = format; self.extractedText = extractedText
        self.extractedTextSHA256 = extractedTextSHA256; self.warnings = warnings; self.pages = pages
        self.fullDocumentTextCoverage = fullDocumentTextCoverage
    }

    /// Nonoverlapping, deterministic windows; no trimming, normalization, or omitted suffix.
    public func windows(maxUTF8Bytes: Int, maxWindows: Int = 100_000) throws -> [ResearchSourceWindow] {
        guard maxUTF8Bytes > 0, maxWindows > 0,
              ResearchSourceIngestor.sha256(Data(extractedText.utf8)) == extractedTextSHA256 else {
            throw ResearchSourceError.invalidWindows
        }
        var result: [ResearchSourceWindow] = [], buffer = "", offset = 0
        func appendWindow() throws {
            guard result.count < maxWindows else { throw ResearchSourceError.invalidWindows }
            let bytes = buffer.utf8.count
            result.append(.init(index: result.count, startUTF8: offset, endUTF8: offset + bytes,
                                text: buffer, sha256: ResearchSourceIngestor.sha256(Data(buffer.utf8))))
            offset += bytes; buffer = ""
        }
        var size = 0
        for character in extractedText {
            let fragment = String(character), count = fragment.utf8.count
            guard count <= maxUTF8Bytes else { throw ResearchSourceError.invalidWindows }
            if size > maxUTF8Bytes - count { try appendWindow(); size = 0 }
            buffer += fragment; size += count
        }
        if !buffer.isEmpty { try appendWindow() }
        return result
    }

    public func reassemble(_ windows: [ResearchSourceWindow]) throws -> String {
        var bytes = Data()
        for (index, window) in windows.enumerated() {
            let data = Data(window.text.utf8)
            guard window.index == index, window.startUTF8 == bytes.count,
                  window.endUTF8 >= window.startUTF8,
                  window.endUTF8 - window.startUTF8 == data.count,
                  ResearchSourceIngestor.sha256(data) == window.sha256 else { throw ResearchSourceError.invalidWindows }
            bytes.append(data)
        }
        guard bytes == Data(extractedText.utf8), ResearchSourceIngestor.sha256(bytes) == extractedTextSHA256,
              let text = String(data: bytes, encoding: .utf8) else { throw ResearchSourceError.invalidWindows }
        return text
    }
}

public struct ResearchSourceLimits: Codable, Sendable, Equatable {
    public let maxOriginalBytes: Int
    public let maxExtractedUTF8Bytes: Int
    public let maxPDFPages: Int
    public init(maxOriginalBytes: Int = 16_777_216, maxExtractedUTF8Bytes: Int = 8_388_608, maxPDFPages: Int = 2_000) {
        self.maxOriginalBytes = maxOriginalBytes; self.maxExtractedUTF8Bytes = maxExtractedUTF8Bytes
        self.maxPDFPages = maxPDFPages
    }
}

public enum ResearchSourceError: Error, Equatable, Sendable {
    case invalidPath, notRegularFile, sourceChanged, originalLimit, textLimit, pageLimit
    case invalidLimits, extractionFailed, invalidWindows
}

public enum ResearchSourceIngestor {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func review(url: URL, limits: ResearchSourceLimits = .init()) throws -> ResearchSourceIdentity {
        let (path, data) = try read(url: url, limits: limits)
        return .init(canonicalPath: path, sha256: sha256(data), byteCount: data.count)
    }

    public static func capture(reviewed: ResearchSourceIdentity, limits: ResearchSourceLimits = .init()) throws -> ResearchSourceCapture {
        let (path, data) = try read(url: URL(fileURLWithPath: reviewed.canonicalPath), limits: limits)
        guard path == reviewed.canonicalPath, data.count == reviewed.byteCount, sha256(data) == reviewed.sha256 else {
            throw ResearchSourceError.sourceChanged
        }
        let format = detectFormat(data)
        var text = "", pages: [ResearchSourcePage] = [], warnings: [String] = []
        func checkBound(_ candidate: String) throws {
            guard candidate.utf8.count <= limits.maxExtractedUTF8Bytes else { throw ResearchSourceError.textLimit }
        }
        switch format {
        case .utf8Text:
            guard let decoded = String(data: data, encoding: .utf8) else { throw ResearchSourceError.extractionFailed }
            text = decoded
        case .rtf:
            guard completeRTF(data) else { throw ResearchSourceError.extractionFailed }
            guard let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else {
                throw ResearchSourceError.extractionFailed
            }
            text = attributed.string
            warnings.append("Native RTF text conversion does not capture embedded images, objects, or visual layout; full document coverage is not established.")
        case .pdf:
            guard data.suffix(1024).range(of: Data("%%EOF".utf8), options: .backwards) != nil else { throw ResearchSourceError.extractionFailed }
            guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else { throw ResearchSourceError.extractionFailed }
            guard document.pageCount <= limits.maxPDFPages else { throw ResearchSourceError.pageLimit }
            warnings.append("PDFKit text extraction does not inspect images, diagrams, or visual layout, including on pages with text; full document coverage is not established. No OCR performed.")
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { throw ResearchSourceError.extractionFailed }
                if index > 0 { text += "\n\u{000C}\n" }
                let start = text.utf8.count, pageText = page.string ?? ""
                text += pageText
                try checkBound(text)
                let hasText = !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                pages.append(.init(number: index + 1, startUTF8: start, endUTF8: text.utf8.count, hasExtractableText: hasText))
                if !hasText { warnings.append("Page \(index + 1) has no extractable text; it may be image-only or blank. Its visual content was not extracted.") }
            }
        case .image:
            warnings.append("Image source: no text extracted; no OCR or image interpretation performed.")
        case .unsupported:
            warnings.append("Unsupported binary or text encoding: no text extracted.")
        }
        try checkBound(text)
        // Check again after conversion so a changed file cannot receive a completed capture receipt.
        let (_, after) = try read(url: URL(fileURLWithPath: path), limits: limits)
        guard after == data else { throw ResearchSourceError.sourceChanged }
        return .init(original: reviewed, format: format, extractedText: text,
                     extractedTextSHA256: sha256(Data(text.utf8)), warnings: warnings, pages: pages,
                     fullDocumentTextCoverage: format == .utf8Text)
    }

    /// Content signatures only; filenames and extensions are never consulted.
    public static func detectFormat(_ data: Data) -> ResearchSourceFormat {
        if data.starts(with: Data("%PDF-".utf8)) { return .pdf }
        if data.starts(with: Data("{\\rtf".utf8)) { return .rtf }
        let signatures: [[UInt8]] = [[137,80,78,71,13,10,26,10], [255,216,255], Array("GIF87a".utf8),
                                   Array("GIF89a".utf8), [73,73,42,0], [77,77,0,42], Array("BM".utf8)]
        if signatures.contains(where: { data.starts(with: $0) }) { return .image }
        if data.count >= 12 {
            let bytes = [UInt8](data.prefix(32))
            if (data.starts(with: Data("RIFF".utf8)) && Array(bytes[8..<12]) == Array("WEBP".utf8)) ||
                (Array(bytes[4..<8]) == Array("ftyp".utf8) && ["heic", "heix", "hevc", "hevx", "mif1", "msf1", "avif", "avis"].contains(String(bytes: bytes[8..<12], encoding: .ascii) ?? "")) { return .image }
        }
        guard let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value < 32 && ![9,10,13].contains($0.value) }) else { return .unsupported }
        return .utf8Text
    }

    // Native RTF import can recover an unterminated stream without throwing. Refuse
    // incomplete groups and binary payloads rather than returning a recovered prefix.
    private static func completeRTF(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var index = 0, depth = 0, closed = false
        func letter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
        while index < bytes.count {
            let byte = bytes[index]
            if closed {
                guard [9,10,13,32].contains(byte) else { return false }
                index += 1; continue
            }
            if byte == 123 { depth += 1; index += 1; continue }
            if byte == 125 {
                depth -= 1; guard depth >= 0 else { return false }
                if depth == 0 { closed = true }
                index += 1; continue
            }
            if byte != 92 { index += 1; continue }
            index += 1
            guard index < bytes.count else { return false }
            if !letter(bytes[index]) {
                if bytes[index] == 39 {
                    guard index + 2 < bytes.count,
                          bytes[(index + 1)...(index + 2)].allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return false }
                    index += 3
                } else { index += 1 }
                continue
            }
            let start = index
            while index < bytes.count && letter(bytes[index]) { index += 1 }
            let word = String(bytes: bytes[start..<index], encoding: .ascii)
            let numberStart = index
            if index < bytes.count && bytes[index] == 45 { index += 1 }
            while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
            let number = Int(String(bytes: bytes[numberStart..<index], encoding: .ascii) ?? "")
            if index < bytes.count && bytes[index] == 32 { index += 1 }
            if word == "bin" {
                guard let count = number, count >= 0, count <= bytes.count - index else { return false }
                index += count
            }
        }
        return closed && depth == 0
    }

    private static func read(url: URL, limits: ResearchSourceLimits) throws -> (String, Data) {
        guard limits.maxOriginalBytes > 0, limits.maxOriginalBytes < Int.max,
              limits.maxExtractedUTF8Bytes > 0, limits.maxPDFPages > 0 else { throw ResearchSourceError.invalidLimits }
        guard url.isFileURL, url.path.hasPrefix("/") else { throw ResearchSourceError.invalidPath }
        // Walk every path component using directory descriptors. O_NOFOLLOW rejects both
        // final symlinks and symlinked parents, without resolving away the evidence.
        let components = url.path.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains(".."), !components.contains("."), !url.path.utf8.contains(0) else { throw ResearchSourceError.invalidPath }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw ResearchSourceError.invalidPath }
        defer { Darwin.close(descriptor) }
        for (index, component) in components.enumerated() {
            let final = index == components.count - 1
            let next = openat(descriptor, component, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (final ? 0 : O_DIRECTORY))
            guard next >= 0 else { throw ResearchSourceError.invalidPath }
            Darwin.close(descriptor); descriptor = next
        }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw ResearchSourceError.notRegularFile }
        guard before.st_size >= 0, before.st_size <= limits.maxOriginalBytes else { throw ResearchSourceError.originalLimit }
        func readAll() throws -> Data {
            var result = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = Darwin.read(descriptor, &buffer, min(buffer.count, limits.maxOriginalBytes - result.count + 1))
                if count < 0 { if errno == EINTR { continue }; throw ResearchSourceError.sourceChanged }
                if count == 0 { break }
                guard count <= limits.maxOriginalBytes - result.count else { throw ResearchSourceError.originalLimit }
                result.append(contentsOf: buffer.prefix(count))
            }
            return result
        }
        let data = try readAll()
        guard lseek(descriptor, 0, SEEK_SET) == 0, try readAll() == data else { throw ResearchSourceError.sourceChanged }
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, data.count == before.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw ResearchSourceError.sourceChanged }
        return ("/" + components.joined(separator: "/"), data)
    }
}
