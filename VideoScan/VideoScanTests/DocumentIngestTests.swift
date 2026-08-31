// DocumentIngestTests.swift
// Documents in the catalog (2026-08-31).

import Testing
import Foundation
@testable import VideoScan

@MainActor
@Suite("Catalog: document ingest")
struct DocumentIngestTests {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("docingest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `Result<VideoRecord, _>` cannot be compared directly — VideoRecord
    /// is a reference type with no Equatable conformance — so tests that
    /// care about *why* a pick was refused look at the reason alone.
    private func rejection(_ url: URL) -> DocumentIngest.Rejection? {
        switch DocumentIngest.makeRecord(url: url) {
        case .success: return nil
        case .failure(let why): return why
        }
    }

    @discardableResult
    private func write(_ name: String, bytes: Int = 2048, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    @Test("a PDF becomes a real record with size, hash and dates")
    func pdfBecomesARecord() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try write("BirthCertificate.pdf", in: dir)

        let rec = try DocumentIngest.makeRecord(url: url).get()
        #expect(rec.filename == "BirthCertificate.pdf")
        #expect(rec.ext == "pdf")
        #expect(rec.sizeBytes == 2048)
        #expect(rec.size.isEmpty == false)
        #expect(rec.fullPath == url.path)
        #expect(rec.directory == dir.path)
        // Duplicate detection must work on documents too — the same
        // certificate does get scanned twice.
        #expect(rec.partialMD5.isEmpty == false, "no hash: documents would never dedupe")
        #expect(rec.dateModifiedRaw != nil, "no modification date captured")
    }

    @Test("a document is 'no streams', NOT 'ffprobe failed'")
    func documentIsNotAProbeFailure() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = try DocumentIngest.makeRecord(url: try write("deed.pdf", in: dir)).get()
        // Calling it a failure would park every document in the
        // probe-failure triage queue forever.
        #expect(rec.streamTypeRaw == StreamType.noStreams.rawValue)
        #expect(rec.streamTypeRaw != StreamType.ffprobeFailed.rawValue)
    }

    @Test("a document record routes itself to 50_Documents")
    func documentRecordRoutesToDocuments() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = try DocumentIngest.makeRecord(url: try write("letter.pdf", in: dir)).get()
        // The end-to-end property: ingest and the archive router agree.
        let facts = ArchivePathResolver.facts(for: rec)
        let path = ArchivePathResolver.baseRelativePath(facts: facts)
        #expect(path.hasPrefix("50_Documents/"), "ingested document misrouted: \(path)")
    }

    @Test("media and photos are refused, with a reason a person can act on")
    func nonDocumentsAreRefused() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try write("home.mov", in: dir)
        let photo = try write("scan.jpg", in: dir)

        #expect(rejection(movie) == .notADocument(.audioVisual))
        #expect(rejection(photo) == .notADocument(.photo))
    }

    @Test("an empty, missing, or directory pick produces no phantom record")
    func badPicksProduceNoRecord() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = try write("blank.pdf", bytes: 0, in: dir)
        #expect(rejection(empty) == .empty)
        #expect(rejection(dir.appendingPathComponent("gone.pdf")) == .notAFile)

        let sub = dir.appendingPathComponent("folder.pdf")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        #expect(rejection(sub) == .notAFile)
    }

    @Test("a batch keeps its failures instead of silently dropping them")
    func batchReportsRejections() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good1 = try write("cert.pdf", in: dir)
        let good2 = try write("census.csv", in: dir)
        let bad = try write("clip.mov", in: dir)

        let outcome = DocumentIngest.makeRecords(urls: [good1, bad, good2])
        #expect(outcome.records.count == 2)
        #expect(outcome.rejected.count == 1, "a rejected pick vanished without trace")
        #expect(outcome.rejected.first?.url == bad)
        #expect(outcome.rejected.first?.reason.message.isEmpty == false)
    }

    // MARK: - Regression sensor

    @Test("the volume scan STILL refuses documents — they did not sneak in",
          arguments: ["pdf", "docx", "txt", "csv", "jpg"],
          [true, false])
    func scanStillRefusesDocuments(_ ext: String, _ videoOnly: Bool) {
        // What actually blocks these is SkipCategories.knownNonMediaExtensions,
        // which lists pdf/docx/txt/csv/jpg and gates the "Scan Unrecognized
        // File Types" toggle. videoOnlyCatalogScope additionally excludes
        // stills (Rick's 2026-07-15 decision, after camera raws leaked in
        // through that same toggle) — which is why .jpg is refused under
        // both settings and this runs with the scope on AND off.
        //
        // Document ingest is a DELIBERATE, user-picked path. If it ever
        // starts riding in on a volume walk, this fails.
        let admitted = FilesystemWalker.shouldAdmitFile(
            extension: ext,
            videoExtensions: ["mov", "mp4", "mxf", "dv"],
            audioExtensions: ["wav", "aif"],
            probeExtensionless: true,
            scanAudioFiles: true,
            scanUnknownExtensions: true,
            videoOnlyCatalogScope: videoOnly)
        #expect(admitted == false,
                ".\(ext) was admitted to a scan (videoOnly=\(videoOnly))")
    }

    @Test("a real video extension is still admitted — the sensor discriminates")
    func scanStillAdmitsVideo() {
        // Without this, the test above would pass just as well if the
        // walker refused everything.
        #expect(FilesystemWalker.shouldAdmitFile(
            extension: "mov",
            videoExtensions: ["mov", "mp4", "mxf", "dv"],
            videoOnlyCatalogScope: true))
    }
}


@MainActor
@Suite("Catalog: picking documents")
struct DocumentPickExpansionTests {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("docpick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("a picked folder contributes its documents and skips the rest")
    func folderPickTakesDocumentsOnly() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a.pdf", "b.docx", "thumb.jpg", "clip.mov", ".DS_Store"] {
            try Data([0x41]).write(to: dir.appendingPathComponent(name))
        }
        let picked = VideoScanModel.expandDocumentPicks([dir])
            .map(\.lastPathComponent).sorted()
        #expect(picked == ["a.pdf", "b.docx"], "got \(picked)")
    }

    @Test("folder expansion does NOT recurse into subfolders")
    func folderPickIsOneLevelDeep() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([0x41]).write(to: dir.appendingPathComponent("top.pdf"))
        let sub = dir.appendingPathComponent("deeper")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data([0x41]).write(to: sub.appendingPathComponent("buried.pdf"))

        // A recursive walk on a picked folder is how you accidentally
        // ingest an entire drive.
        let picked = VideoScanModel.expandDocumentPicks([dir]).map(\.lastPathComponent)
        #expect(picked == ["top.pdf"], "recursed: \(picked)")
    }

    @Test("a directly picked file is taken as-is, whatever it is")
    func directPicksAreNotFiltered() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mov = dir.appendingPathComponent("clip.mov")
        try Data([0x41]).write(to: mov)
        // Filtering here would swallow the pick silently; makeRecord
        // refuses it WITH a reason instead, which the user can see.
        #expect(VideoScanModel.expandDocumentPicks([mov]) == [mov])
    }

    @Test("adding the same document twice does not double the record")
    func reAddingIsIdempotent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("cert.pdf")
        try Data(repeating: 0x41, count: 512).write(to: pdf)

        let model = VideoScanModel()
        let first = model.addDocuments(urls: [pdf])
        #expect(first.records.count == 1)
        let second = model.addDocuments(urls: [pdf])
        #expect(second.records.isEmpty, "re-adding created a duplicate record")
        #expect(model.records.filter { $0.fullPath == pdf.path }.count == 1)
    }
}
