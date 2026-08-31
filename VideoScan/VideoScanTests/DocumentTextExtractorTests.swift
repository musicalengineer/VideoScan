// DocumentTextExtractorTests.swift
// Documents are only worth cataloguing if you can find them (2026-08-31).

import Testing
import Foundation
import PDFKit
import AppKit
@testable import VideoScan

@Suite("Documents: text extraction")
struct DocumentTextExtractorTests {

    // MARK: - Fixtures

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doctext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A born-digital PDF: real text layer, drawn as text.
    private func textPDF(_ pages: [String], at url: URL) throws {
        let doc = PDFDocument()
        for (i, body) in pages.enumerated() {
            let attributed = NSAttributedString(string: body, attributes: [
                .font: NSFont.systemFont(ofSize: 18),
                .foregroundColor: NSColor.black,
            ])
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            guard let consumer = CGDataConsumer(data: data),
                  let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            ctx.beginPDFPage(nil)
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            attributed.draw(in: CGRect(x: 40, y: 100, width: 520, height: 640))
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
            ctx.closePDF()
            if let onePage = PDFDocument(data: data as Data), let page = onePage.page(at: 0) {
                doc.insert(page, at: i)
            }
        }
        guard doc.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// A SCAN: a picture of paper. No text layer at all, so the only way
    /// in is optical recognition — this is what most family documents are.
    private func scannedPDF(_ text: String, at url: URL) throws {
        let size = NSSize(width: 612, height: 300)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSAttributedString(string: text, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 48),
            .foregroundColor: NSColor.black,
        ]).draw(at: NSPoint(x: 30, y: 120))
        image.unlockFocus()

        guard let page = PDFPage(image: image) else { throw CocoaError(.fileWriteUnknown) }
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        guard doc.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
        // Guard the fixture itself: if PDFPage(image:) ever started
        // embedding a text layer, the OCR test below would silently stop
        // testing OCR.
        let reread = PDFDocument(url: url)
        let layer = reread?.page(at: 0)?.string ?? ""
        #expect(layer.count < DocumentTextExtractor.textLayerMinimumCharacters,
                "fixture is not scan-like — it has a text layer: \(layer)")
    }

    // MARK: - Plain text

    @Test("a text file is indexed whole")
    func plainTextIsExtracted() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("letter.txt")
        try "Dear Martha,\n\nBorn 12-mar-1900 in Derry.".write(
            to: url, atomically: true, encoding: .utf8)

        let out = await DocumentTextExtractor.extract(url: url)
        #expect(out.usedOCR == false)
        #expect(out.pages.first?.text.contains("Derry") == true)
    }

    @Test("a non-UTF8 text file still reads — old records are full of accents")
    func latin1TextIsExtracted() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("old.txt")
        let latin1 = "Reíllé Roynane".data(using: .isoLatin1)!
        try latin1.write(to: url)

        let out = await DocumentTextExtractor.extract(url: url)
        #expect(out.isEmpty == false, "a Latin-1 document was dropped entirely")
    }

    // MARK: - PDFs

    @Test("a born-digital PDF is read from its text layer, WITHOUT OCR")
    func textLayerIsPreferred() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("certificate.pdf")
        try textPDF(["Martha Lamson was born in Derry"], at: url)

        let out = await DocumentTextExtractor.extract(url: url)
        #expect(out.pages.first?.text.contains("Lamson") == true,
                "text layer missed: \(out.pages.first?.text ?? "nil")")
        // The performance property: OCR costs seconds per page, and the
        // text was already sitting there.
        #expect(out.usedOCR == false, "OCR ran on a PDF that had a text layer")
    }

    @Test("page numbers are preserved, so a hit can say which page")
    func pageNumbersArePreserved() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("multi.pdf")
        try textPDF(["First page about Terry",
                     "Second page about Donna",
                     "Third page about Agnes"], at: url)

        let out = await DocumentTextExtractor.extract(url: url)
        #expect(out.pages.count == 3)
        let donnaPage = out.pages.first { $0.text.contains("Donna") }?.page
        #expect(donnaPage == 2, "wrong page number: \(String(describing: donnaPage))")
        // SceneCaption.timestamp carries the page for documents.
        #expect(out.captions.first { $0.text.contains("Agnes") }?.timestamp == 3)
    }

    @Test("a SCANNED page falls back to optical recognition")
    func scannedPageUsesOCR() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("scan.pdf")
        try scannedPDF("BREEN", at: url)

        let out = await DocumentTextExtractor.extract(url: url)
        #expect(out.usedOCR == true, "a text-layer-less scan did not reach OCR")
        let text = (out.pages.first?.text ?? "").uppercased()
        #expect(text.contains("BREEN"), "OCR read: \(text)")
    }

    // MARK: - Honest limits

    @Test("a format we cannot parse yields nothing, and does not pretend")
    func unparseableFormatsAreEmpty() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("report.docx")
        try Data(repeating: 0x50, count: 512).write(to: url)

        let out = await DocumentTextExtractor.extract(url: url)
        #expect(out.isEmpty, "claimed to have indexed a .docx it cannot read")
    }

    @Test("a corrupt PDF does not crash or invent text")
    func corruptPDFIsHandled() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("broken.pdf")
        try Data("not really a pdf".utf8).write(to: url)

        let out = await DocumentTextExtractor.extract(url: url)
        #expect(out.isEmpty)
    }

    @Test("a huge text file is truncated rather than bloating the catalog")
    func oversizeIsTruncated() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("huge.txt")
        try String(repeating: "a", count: DocumentTextExtractor.maxCharacters + 5_000)
            .write(to: url, atomically: true, encoding: .utf8)

        let out = await DocumentTextExtractor.extract(url: url)
        #expect(out.truncated)
        let total = out.pages.reduce(0) { $0 + $1.text.count }
        #expect(total <= DocumentTextExtractor.maxCharacters)
    }

    @Test("media files are not sent through the document extractor")
    func mediaIsSkipped() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clip.mov")
        try Data(repeating: 0, count: 64).write(to: url)
        #expect(await DocumentTextExtractor.extract(url: url).isEmpty)
    }
}


@MainActor
@Suite("Documents: end-to-end searchability")
struct DocumentSearchIntegrationTests {

    @Test("a document added to the catalog is findable by its CONTENTS")
    func documentIsFindableByItsText() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("docsearch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("MarthaLamson_Birth.txt")
        try "Martha Lamson, born 12-mar-1900, Derry, County Londonderry."
            .write(to: url, atomically: true, encoding: .utf8)

        let model = VideoScanModel()
        let added = model.addDocuments(urls: [url])
        let rec = try #require(added.records.first)

        // Before extraction the filename is searchable but the CONTENTS
        // are not — that is the whole point of the feature.
        #expect(model.searchIndex.filter(records: model.records, query: "Londonderry").isEmpty,
                "content matched before any text was extracted")

        // Do synchronously what indexDocumentText does in the background.
        let extraction = await DocumentTextExtractor.extract(url: url)
        rec.ocrText = extraction.captions
        model.searchIndex.update(rec)

        for term in ["Londonderry", "Derry", "1900"] {
            let hits = model.searchIndex.filter(records: model.records, query: term)
            #expect(hits.contains { $0.fullPath == url.path },
                    "\(term) did not find the document")
        }
        // And a term that is not in it must NOT match, or the test above
        // would pass against an index that matches everything.
        #expect(model.searchIndex.filter(records: model.records, query: "Kalamazoo").isEmpty)
    }
}
