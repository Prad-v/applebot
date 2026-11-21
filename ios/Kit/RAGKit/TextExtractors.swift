import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Extracts text blocks from a file URL.
public protocol TextExtractor: Sendable {
    func extract(from url: URL) async throws -> [TextBlock]
}

/// Plain text, Markdown and other UTF-8 text files.
public struct PlainTextExtractor: TextExtractor {
    public static let extensions: Set<String> = ["txt", "md", "markdown", "text", "csv", "log", "json", "yaml", "yml", "rtf"]

    public init() {}

    public func extract(from url: URL) async throws -> [TextBlock] {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw RAGError.extractionFailed(error.localizedDescription) }
        if url.pathExtension.lowercased() == "rtf" {
            #if canImport(UIKit) || canImport(AppKit)
            if let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
                return [TextBlock(text: attributed.string)]
            }
            #endif
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw RAGError.extractionFailed("the file is not valid text")
        }
        return [TextBlock(text: text)]
    }
}

/// Picks an extractor from the file extension.
public struct DocumentExtractor: TextExtractor {
    public init() {}

    public static var supportedExtensions: Set<String> {
        var all = PlainTextExtractor.extensions
        #if canImport(PDFKit)
        all.insert("pdf")
        #endif
        #if canImport(Vision) && canImport(ImageIO)
        all.formUnion(ImageTextExtractor.extensions)
        #endif
        return all
    }

    public func extract(from url: URL) async throws -> [TextBlock] {
        let ext = url.pathExtension.lowercased()
        if PlainTextExtractor.extensions.contains(ext) {
            return try await PlainTextExtractor().extract(from: url)
        }
        #if canImport(PDFKit)
        if ext == "pdf" { return try await PDFTextExtractor().extract(from: url) }
        #endif
        #if canImport(Vision) && canImport(ImageIO)
        if ImageTextExtractor.extensions.contains(ext) { return try await ImageTextExtractor().extract(from: url) }
        #endif
        throw RAGError.unsupportedFileType(ext.isEmpty ? "unknown" : ext)
    }
}

#if canImport(Vision) && canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics

enum OCR {
    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}

/// OCR for photos and screenshots using on-device Vision.
public struct ImageTextExtractor: TextExtractor {
    public static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "gif", "bmp"]

    public init() {}

    public func extract(from url: URL) async throws -> [TextBlock] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw RAGError.extractionFailed("the image could not be decoded") }
        let text = try OCR.recognize(image)
        return [TextBlock(text: text)]
    }
}
#endif

#if canImport(PDFKit)
/// PDF text extraction with per-page numbers. Pages without a text layer fall back to OCR.
public struct PDFTextExtractor: TextExtractor {
    public init() {}

    public func extract(from url: URL) async throws -> [TextBlock] {
        guard let document = PDFDocument(url: url) else {
            throw RAGError.extractionFailed("the PDF could not be opened")
        }
        if document.isLocked { throw RAGError.extractionFailed("the PDF is password protected") }

        var blocks: [TextBlock] = []
        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex) else { continue }
            var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            #if canImport(Vision) && canImport(ImageIO) && canImport(CoreGraphics)
            if text.count < 20, let image = Self.render(page) {
                text = (try? OCR.recognize(image)) ?? text
            }
            #endif
            if !text.isEmpty { blocks.append(TextBlock(text: text, page: pageIndex + 1)) }
        }
        return blocks
    }

    #if canImport(Vision) && canImport(ImageIO) && canImport(CoreGraphics)
    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = 1800 / max(bounds.width, bounds.height)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        #if canImport(UIKit)
        return image.cgImage
        #else
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }
    #endif
}
#endif
