import Testing
import Foundation
@testable import VideoScan

// GH #151 — adding photos to an existing person. The copy routine used to
// be a private view method that swallowed errors and dropped same-named
// files; these pin the extracted, reporting importer. Temp dirs only.
struct ReferencePhotoImporterTests {

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferencePhotoImporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ name: String, _ bytes: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    @Test func singleFileIsCopiedAndDestinationCreated() throws {
        let src = try tempDir(), dst = try tempDir().appendingPathComponent("person", isDirectory: true)
        let photo = try write("beach.JPG", "aaa", in: src)
        let outcome = ReferencePhotoImporter.copy(from: photo, into: dst)
        #expect(outcome.copied == ["beach.JPG"])
        #expect(outcome.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("beach.JPG").path))
    }

    @Test func folderCopiesImagesOnlyAndCountsTheRest() throws {
        let src = try tempDir(), dst = try tempDir()
        _ = try write("a.jpg", "1", in: src); _ = try write("b.heic", "2", in: src)
        _ = try write("c.TIF", "3", in: src); _ = try write("notes.txt", "x", in: src)
        _ = try write("movie.mov", "y", in: src)
        let outcome = ReferencePhotoImporter.copy(from: src, into: dst)
        #expect(Set(outcome.copied) == ["a.jpg", "b.heic", "c.TIF"])
        #expect(outcome.ignoredNonImages == 2)
    }

    @Test func identicalDuplicateIsSkippedButDifferentPhotoWithSameNameIsRenamed() throws {
        let src1 = try tempDir(), src2 = try tempDir(), dst = try tempDir()
        _ = try write("IMG_0001.jpg", "same", in: src1)
        _ = try write("IMG_0001.jpg", "same", in: src2)
        let first = ReferencePhotoImporter.copy(from: src1, into: dst)
        let second = ReferencePhotoImporter.copy(from: src2, into: dst)
        #expect(first.copied == ["IMG_0001.jpg"])
        #expect(second.copied.isEmpty)
        #expect(second.skippedIdentical == ["IMG_0001.jpg"])

        let src3 = try tempDir()
        _ = try write("IMG_0001.jpg", "a different photo", in: src3)
        let third = ReferencePhotoImporter.copy(from: src3, into: dst)
        #expect(third.copied == ["IMG_0001-2.jpg"])
        #expect(third.renamed == ["IMG_0001.jpg": "IMG_0001-2.jpg"])
        #expect(try String(contentsOf: dst.appendingPathComponent("IMG_0001.jpg"), encoding: .utf8) == "same",
                "the original is never overwritten")
        let fourth = ReferencePhotoImporter.copy(from: src3, into: dst)
        #expect(fourth.skippedIdentical.isEmpty && fourth.copied == ["IMG_0001-3.jpg"],
                "a third distinct photo of the same name takes the next free slot")
    }

    @Test func nonImageSingleFileIsIgnoredNotFailed() throws {
        let src = try tempDir(), dst = try tempDir()
        let doc = try write("scan.pdf", "%PDF", in: src)
        let outcome = ReferencePhotoImporter.copy(from: doc, into: dst)
        #expect(outcome.copied.isEmpty && outcome.ignoredNonImages == 1 && outcome.failures.isEmpty)
    }

    @Test func unreadableSourceIsReportedNotSwallowed() throws {
        let src = try tempDir(), dst = try tempDir()
        let missing = src.appendingPathComponent("gone.jpg")
        let outcome = ReferencePhotoImporter.copy(from: missing, into: dst)
        #expect(outcome.copied.isEmpty)
        #expect(outcome.failures["gone.jpg"] != nil, "a copy that cannot happen is named in failures")
        #expect(outcome.summary.contains("1 FAILED"))
    }

    @Test func summaryReadsLikeALogLine() {
        var o = ReferencePhotoImporter.Outcome()
        #expect(o.summary == "0 added")
        o.copied = ["a", "b"]; o.skippedIdentical = ["c"]; o.renamed = ["d": "d-2"]; o.ignoredNonImages = 3
        #expect(o.summary == "2 added, 1 already there, 1 renamed (same name, different photo), 3 non-image skipped")
    }
}
