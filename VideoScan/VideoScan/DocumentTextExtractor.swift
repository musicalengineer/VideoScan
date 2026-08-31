// DocumentTextExtractor.swift
// Making documents searchable (2026-08-31).
//
// Rick, on documents in the catalog: "I think yes so we can search them."
// A PDF's value to this archive is its TEXT — a birth certificate is worth
// having because it says a name, a date and a place.
//
// Two kinds of PDF, and the difference matters:
//   * born-digital (exported from a form, a website, a word processor)
//     carries a real text layer, and PDFKit hands it over instantly.
//   * a SCAN — which is most of what a family has — is a picture of paper
//     with no text layer at all. PDFKit returns nothing for it, and the
//     only way in is optical recognition.
// So: try the text layer, and fall back to Vision when it comes back
// empty. Getting this backwards (always OCR) would burn minutes per
// document for text that was already sitting there.
//
// WHERE THE TEXT GOES
//
// Into `VideoRecord.ocrText`, which the catalog's search index ALREADY
// folds into its per-record haystack. Nothing new to wire: filling that
// field is what makes a document findable.
//
// `SceneCaption.timestamp` means "page number" here. For video it is
// seconds; a document has no time, and a page is the thing a person
// actually wants to be told ("it's on page 3").

import Foundation
import PDFKit
import Vision
import CoreGraphics

enum DocumentTextExtractor {

    /// Beyond this a document is a book, not a record, and we are
    /// indexing a family archive rather than building a library catalog.
    static let maxPages = 200
    /// Guard against one pathological file bloating the catalog. ~500k
    /// characters is far more than any certificate or letter.
    static let maxCharacters = 500_000
    /// Below this, a PDF page's text layer is treated as absent — some
    /// scanners embed a stray character or a bare page number.
    static let textLayerMinimumCharacters = 12

    struct Extraction: Sendable {
        var pages: [(page: Int, text: String)] = []
        var usedOCR = false
        var truncated = false

        var isEmpty: Bool { pages.allSatisfy { $0.text.isEmpty } }
        var captions: [SceneCaption] {
            pages.filter { !$0.text.isEmpty }
                 .map { SceneCaption(timestamp: Double($0.page), text: $0.text) }
        }
    }

    /// Extract searchable text. Off-actor: `@concurrent` because a bare
    /// `nonisolated async` runs on the CALLER's actor under Approachable
    /// Concurrency, which would put Vision and PDF rendering on the main
    /// thread and beachball the app (three prior incidents in this repo).
    @concurrent
    nonisolated static func extract(url: URL) async -> Extraction {
        let medium = ArchiveMedium.forFilename(url.lastPathComponent)
        guard medium == .document || medium == .photo else { return Extraction() }

        switch url.pathExtension.lowercased() {
        case "pdf":
            return await extractPDF(url: url)
        case "txt", "md", "csv", "tsv", "rtf":
            return extractPlainText(url: url)
        default:
            // A photo of a document, or an image-only format.
            if medium == .photo { return await extractImage(url: url) }
            // .docx/.pages/.xlsx are zip containers needing a real parser.
            // Returning empty is honest; claiming to have indexed them
            // would be worse than not indexing them.
            return Extraction()
        }
    }

    // MARK: - Plain text

    nonisolated private static func extractPlainText(url: URL) -> Extraction {
        // UTF-8 first, then let Foundation guess, then Latin-1 outright.
        //
        // The explicit Latin-1 arm is load-bearing: a plain Latin-1 file
        // carries no BOM and no declaration, so `usedEncoding:` has
        // nothing to go on and simply fails. Without this, a letter with
        // one accented name in it — "Reíllé", "Ó Ruanáin" — extracts as
        // NOTHING and silently never turns up in a search. Latin-1
        // decodes any byte sequence, so it is the right last resort.
        var text = (try? String(contentsOf: url, encoding: .utf8))
        if text == nil {
            var used: String.Encoding = .utf8
            text = try? String(contentsOf: url, usedEncoding: &used)
        }
        if text == nil {
            text = (try? Data(contentsOf: url)).flatMap {
                String(data: $0, encoding: .isoLatin1)
            }
        }
        guard var body = text else { return Extraction() }

        var out = Extraction()
        if body.count > maxCharacters {
            body = String(body.prefix(maxCharacters))
            out.truncated = true
        }
        out.pages = [(1, normalize(body))]
        return out
    }

    // MARK: - PDF

    @concurrent
    nonisolated private static func extractPDF(url: URL) async -> Extraction {
        guard let doc = PDFDocument(url: url) else { return Extraction() }
        var out = Extraction()
        let pageCount = min(doc.pageCount, maxPages)
        out.truncated = doc.pageCount > maxPages
        var budget = maxCharacters

        for index in 0..<pageCount {
            guard budget > 0, let page = doc.page(at: index) else { break }

            var text = normalize(page.string ?? "")
            if text.count < textLayerMinimumCharacters {
                // No usable text layer — this page is a picture of paper.
                if let recognized = await recognizeText(on: page) {
                    text = recognized
                    out.usedOCR = true
                }
            }
            if text.count > budget {
                text = String(text.prefix(budget))
                out.truncated = true
            }
            budget -= text.count
            out.pages.append((index + 1, text))
        }
        return out
    }

    /// Render one PDF page and read it optically.
    @concurrent
    nonisolated private static func recognizeText(on page: PDFPage) async -> String? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }

        // 2× is the usual sweet spot for document OCR: enough resolution
        // for small print without quadrupling the work.
        let scale: CGFloat = 2
        let pixelSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: pixelSize, for: .mediaBox)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return recognizeText(in: cgImage)
    }

    // MARK: - Images

    @concurrent
    nonisolated private static func extractImage(url: URL) async -> Extraction {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let text = recognizeText(in: cgImage), !text.isEmpty else {
            return Extraction()
        }
        var out = Extraction()
        out.usedOCR = true
        out.pages = [(1, String(text.prefix(maxCharacters)))]
        return out
    }

    // MARK: - Vision

    nonisolated private static func recognizeText(in cgImage: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Old records are full of names and places no language model
        // predicts well; correction turns "Roynane" into "Romane".
        request.usesLanguageCorrection = false
        request.revision = VNRecognizeTextRequestRevision3

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        let lines = (request.results ?? []).compactMap {
            $0.topCandidates(1).first?.string
        }
        let joined = lines.joined(separator: "\n")
        return joined.isEmpty ? nil : normalize(joined)
    }

    // MARK: - Shared

    /// Collapse the whitespace a PDF text layer is full of, without
    /// destroying line structure — a certificate's layout is meaningful.
    nonisolated private static func normalize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r\n", with: "\n")
           .replacingOccurrences(of: "\r", with: "\n")
           .replacing(/[ \t]+/, with: " ")
           .replacing(/\n{3,}/, with: "\n\n")
           .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
