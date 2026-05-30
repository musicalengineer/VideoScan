import Testing
import Foundation
@testable import VideoScan

// MARK: - RelocateReconcileTests
//
// Drives RelocateReconcile.reconcile with synthetic file lists + an
// injectable hash function. The pure design lets us exercise every
// bucket boundary without disk I/O. The integration test (§10) will
// cover the real-file path end-to-end.

@MainActor
struct RelocateReconcileTests {

    // MARK: - Helpers

    private func rec(_ name: String,
                     path: String,
                     size: Int64 = 1024,
                     md5: String = "abc123") -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = path
        r.sizeBytes = size
        r.partialMD5 = md5
        return r
    }

    /// Stub hash function backed by a dictionary. Default: returns the
    /// path's last-component-uppercased so tests can construct hash
    /// values inline.
    private func hashFn(_ table: [String: String]) -> (String) -> String {
        { table[$0] ?? "" }
    }

    // MARK: - Bucket A (ready)

    @Test
    func bucketA_fileAtRecordedPath_hashMatches_isReady() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs-recon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // We need an actual file on disk so fileSize() (stat) succeeds.
        let here = tmp.appendingPathComponent("a.mov")
        try Data(repeating: 0, count: 1024).write(to: here)

        let r = rec("a.mov", path: here.path, size: 1024, md5: "HASH-A")
        let result = RelocateReconcile.reconcile(
            records: [r],
            sourceVolumeRootPath: tmp.path,
            destinationRoot: URL(fileURLWithPath: "/tmp/no-dest"),
            sourceFiles: [.init(path: here.path, size: 1024)],
            destFiles: [],
            hash: hashFn([here.path: "HASH-A"])
        )
        #expect(result.ready.count == 1)
        #expect(result.ready.first?.id == r.id)
        #expect(result.manuallyDeleted.isEmpty)
        #expect(result.adopted.isEmpty)
        #expect(result.sourceSideMoves.isEmpty)
    }

    // MARK: - Bucket B (manually deleted)

    @Test
    func bucketB_fileMissing_noMatchAnywhere_isManuallyDeleted() {
        let r = rec("gone.mov", path: "/Volumes/Mini2TB/gone.mov", size: 2048, md5: "HASH-G")
        let result = RelocateReconcile.reconcile(
            records: [r],
            sourceVolumeRootPath: "/Volumes/Mini2TB",
            destinationRoot: URL(fileURLWithPath: "/Volumes/LaCie/archive"),
            sourceFiles: [],
            destFiles: [],
            hash: hashFn([:])
        )
        #expect(result.manuallyDeleted.count == 1)
        #expect(result.manuallyDeleted.first?.id == r.id)
        #expect(result.ready.isEmpty)
    }

    // MARK: - Bucket C (source-side move)

    @Test
    func bucketC_fileFoundElsewhereOnSource_isSourceSideMove() {
        let r = rec("clip.mov",
                    path: "/Volumes/Mini2TB/old/clip.mov",
                    size: 4096, md5: "HASH-C")
        // Catalog says /old/, but Rick moved it to /sorted/.
        let result = RelocateReconcile.reconcile(
            records: [r],
            sourceVolumeRootPath: "/Volumes/Mini2TB",
            destinationRoot: URL(fileURLWithPath: "/Volumes/LaCie/archive"),
            sourceFiles: [.init(path: "/Volumes/Mini2TB/sorted/clip.mov", size: 4096)],
            destFiles: [],
            hash: hashFn(["/Volumes/Mini2TB/sorted/clip.mov": "HASH-C"])
        )
        #expect(result.sourceSideMoves.count == 1)
        #expect(result.sourceSideMoves.first?.rec.id == r.id)
        #expect(result.sourceSideMoves.first?.newSourcePath == "/Volumes/Mini2TB/sorted/clip.mov")
        #expect(result.ready.isEmpty)
        #expect(result.manuallyDeleted.isEmpty)
    }

    // MARK: - Bucket D (adopted — already at destination)

    @Test
    func bucketD_fileFoundAtDestination_isAdopted() {
        // Rick already copied this manually during triage.
        let r = rec("happy.mov",
                    path: "/Volumes/Mini2TB/family/happy.mov",
                    size: 8192, md5: "HASH-D")
        let destPath = "/Volumes/LaCie/archive/family/happy.mov"
        let result = RelocateReconcile.reconcile(
            records: [r],
            sourceVolumeRootPath: "/Volumes/Mini2TB",
            destinationRoot: URL(fileURLWithPath: "/Volumes/LaCie/archive"),
            sourceFiles: [],
            destFiles: [.init(path: destPath, size: 8192)],
            hash: hashFn([destPath: "HASH-D"])
        )
        #expect(result.adopted.count == 1)
        #expect(result.adopted.first?.rec.id == r.id)
        #expect(result.adopted.first?.destPath == destPath)
    }

    // MARK: - Preference: dest before source when both have a hit

    @Test
    func adoptionPrefersDestOverSourceMoveWhenBothMatch() {
        // Both source AND dest have the same content. Dest wins — no
        // point copying when the file is already in place.
        let r = rec("dup.mov",
                    path: "/Volumes/Mini2TB/old/dup.mov",
                    size: 1000, md5: "HASH-X")
        let destPath = "/Volumes/LaCie/archive/old/dup.mov"
        let elsewhereOnSource = "/Volumes/Mini2TB/elsewhere/dup.mov"
        let result = RelocateReconcile.reconcile(
            records: [r],
            sourceVolumeRootPath: "/Volumes/Mini2TB",
            destinationRoot: URL(fileURLWithPath: "/Volumes/LaCie/archive"),
            sourceFiles: [.init(path: elsewhereOnSource, size: 1000)],
            destFiles: [.init(path: destPath, size: 1000)],
            hash: hashFn([destPath: "HASH-X", elsewhereOnSource: "HASH-X"])
        )
        #expect(result.adopted.count == 1)
        #expect(result.sourceSideMoves.isEmpty)
    }

    // MARK: - Already-relocated short-circuit

    @Test
    func previouslyRelocatedRecordIsShortCircuited() {
        let r = rec("done.mov",
                    path: "/Volumes/LaCie/archive/done.mov",
                    size: 1024, md5: "H")
        r.originalFullPath = "/Volumes/Mini2TB/done.mov"
        r.originVolume = "Mini2TB"

        let result = RelocateReconcile.reconcile(
            records: [r],
            sourceVolumeRootPath: "/Volumes/Mini2TB",
            destinationRoot: URL(fileURLWithPath: "/Volumes/LaCie/archive"),
            sourceFiles: [],
            destFiles: [],
            hash: hashFn([:])
        )
        #expect(result.previouslyRelocated.count == 1)
        #expect(result.ready.isEmpty)
        #expect(result.manuallyDeleted.isEmpty)
    }

    // MARK: - Hash-mismatch on recorded path falls through (not bucket A)

    @Test
    func hashMismatchOnRecordedPathFallsOutOfBucketA() throws {
        // File exists at recorded path but its hash is wrong (corrupted
        // or different content). Don't auto-accept — fall through to
        // look elsewhere; if nothing matches, classify as manually deleted.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs-recon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bad = tmp.appendingPathComponent("bad.mov")
        try Data(repeating: 0, count: 100).write(to: bad)

        let r = rec("bad.mov", path: bad.path, size: 100, md5: "EXPECTED-HASH")
        let result = RelocateReconcile.reconcile(
            records: [r],
            sourceVolumeRootPath: tmp.path,
            destinationRoot: URL(fileURLWithPath: "/tmp/no-dest"),
            sourceFiles: [.init(path: bad.path, size: 100)],
            destFiles: [],
            // hash returns something OTHER than EXPECTED-HASH
            hash: hashFn([bad.path: "DIFFERENT-HASH"])
        )
        #expect(result.ready.isEmpty)
        #expect(result.manuallyDeleted.count == 1)
    }

    // MARK: - Empty-hash record + ambiguous size match → not auto-adopted

    @Test
    func emptyHashRecordWithMultipleSizeMatchesFallsThrough() {
        // Legacy record with no stored hash. If two files on source share
        // its size we can't pick — refuse to guess; fall through to
        // manuallyDeleted rather than risk adopting the wrong content.
        let r = rec("legacy.mov",
                    path: "/Volumes/Mini2TB/legacy.mov",
                    size: 500, md5: "")
        let result = RelocateReconcile.reconcile(
            records: [r],
            sourceVolumeRootPath: "/Volumes/Mini2TB",
            destinationRoot: URL(fileURLWithPath: "/Volumes/LaCie/archive"),
            sourceFiles: [
                .init(path: "/Volumes/Mini2TB/a.mov", size: 500),
                .init(path: "/Volumes/Mini2TB/b.mov", size: 500)
            ],
            destFiles: [],
            hash: hashFn([:])
        )
        #expect(result.manuallyDeleted.count == 1)
        #expect(result.sourceSideMoves.isEmpty)
    }

    @Test
    func emptyHashRecordWithExactlyOneSizeMatchIsAdoptedAsSourceSideMove() {
        // Legacy record, single size match on source → safe to adopt.
        let r = rec("legacy.mov",
                    path: "/Volumes/Mini2TB/missing.mov",
                    size: 500, md5: "")
        let result = RelocateReconcile.reconcile(
            records: [r],
            sourceVolumeRootPath: "/Volumes/Mini2TB",
            destinationRoot: URL(fileURLWithPath: "/Volumes/LaCie/archive"),
            sourceFiles: [.init(path: "/Volumes/Mini2TB/found.mov", size: 500)],
            destFiles: [],
            hash: hashFn([:])
        )
        #expect(result.sourceSideMoves.count == 1)
        #expect(result.sourceSideMoves.first?.newSourcePath == "/Volumes/Mini2TB/found.mov")
    }
}
