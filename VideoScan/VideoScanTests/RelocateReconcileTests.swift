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

    /// Shorthand: call reconcile with `allCatalogRecords == records` and
    /// `skipDupsOnOtherVolumes = false`. Preserves the pre-Bucket-E test
    /// semantics for legacy A/B/C/D coverage. The Bucket E tests further
    /// down pass the full catalog and the flag explicitly.
    private func reconcileLegacy(records: [VideoRecord],
                                 sourceVolumeRootPath: String,
                                 destinationRoot: URL,
                                 sourceFiles: [ReconcileFileEntry],
                                 destFiles: [ReconcileFileEntry],
                                 hash: @escaping (String) -> String) -> ReconcileResult {
        RelocateReconcile.reconcile(
            records: records,
            allCatalogRecords: records,
            sourceVolumeRootPath: sourceVolumeRootPath,
            destinationRoot: destinationRoot,
            sourceFiles: sourceFiles,
            destFiles: destFiles,
            skipDupsOnOtherVolumes: false,
            hash: hash
        )
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
        let result = reconcileLegacy(
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
        #expect(result.safelyRedundant.isEmpty)
    }

    // MARK: - Bucket B (manually deleted)

    @Test
    func bucketB_fileMissing_noMatchAnywhere_isManuallyDeleted() {
        let r = rec("gone.mov", path: "/Volumes/Mini2TB/gone.mov", size: 2048, md5: "HASH-G")
        let result = reconcileLegacy(
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
        let result = reconcileLegacy(
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
        let result = reconcileLegacy(
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
        let result = reconcileLegacy(
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

        let result = reconcileLegacy(
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
        let result = reconcileLegacy(
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
        let result = reconcileLegacy(
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
        let result = reconcileLegacy(
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

    // MARK: - Bucket E (safely redundant on a third volume)

    @Test
    func bucketE_recordWithMatchOnThirdVolume_isSafelyRedundant() {
        // Source record on Mini2TB, identical (size + md5) record cataloged
        // on a third volume (MyBook). Destination dir has nothing.
        let srcRec = rec("kids.mov",
                         path: "/Volumes/Mini2TB/kids.mov",
                         size: 5000, md5: "HASH-K")
        let witness = rec("kids.mov",
                          path: "/Volumes/MyBook3Terabytes/family/kids.mov",
                          size: 5000, md5: "HASH-K")

        let result = RelocateReconcile.reconcile(
            records: [srcRec],
            allCatalogRecords: [srcRec, witness],
            sourceVolumeRootPath: "/Volumes/Mini2TB",
            destinationRoot: URL(fileURLWithPath: "/Volumes/LaCie/archive"),
            sourceFiles: [],
            destFiles: [],
            skipDupsOnOtherVolumes: true,
            hash: hashFn([:])
        )
        #expect(result.safelyRedundant.count == 1)
        #expect(result.safelyRedundant.first?.rec.id == srcRec.id)
        #expect(result.safelyRedundant.first?.witnesses == ["/Volumes/MyBook3Terabytes/family/kids.mov"])
        #expect(result.safelyRedundant.first?.totalWitnessCount == 1)
        #expect(result.ready.isEmpty)
        #expect(result.manuallyDeleted.isEmpty)
    }

    @Test
    func bucketE_prefersAlreadyOnDestOverSafelyRedundant() {
        // Both conditions hold: file is at planned destination AND a witness
        // exists on a third volume. Destination wins — Rick's expected
        // post-relocate path is the dest, not "marked deleted with witnesses".
        let srcRec = rec("a.mov",
                         path: "/Volumes/Mini2TB/a.mov",
                         size: 1000, md5: "HASH-A")
        // Witness on a third volume.
        let witness = rec("a.mov",
                          path: "/Volumes/MyBook3Terabytes/a.mov",
                          size: 1000, md5: "HASH-A")
        // File also pre-copied to destination during triage.
        let destPath = "/Volumes/LaCie/archive/a.mov"

        let result = RelocateReconcile.reconcile(
            records: [srcRec],
            allCatalogRecords: [srcRec, witness],
            sourceVolumeRootPath: "/Volumes/Mini2TB",
            destinationRoot: URL(fileURLWithPath: "/Volumes/LaCie/archive"),
            sourceFiles: [],
            destFiles: [.init(path: destPath, size: 1000)],
            skipDupsOnOtherVolumes: true,
            hash: hashFn([destPath: "HASH-A"])
        )
        #expect(result.adopted.count == 1)
        #expect(result.adopted.first?.destPath == destPath)
        #expect(result.safelyRedundant.isEmpty)
    }

    @Test
    func bucketE_toggleOffFallsThroughToLegacyBuckets() {
        // Same setup as bucketE_recordWithMatchOnThirdVolume_isSafelyRedundant,
        // but with the gate OFF. Source file isn't on disk (no entry in
        // sourceFiles) and dest is empty, so the record falls all the way
        // through to manuallyDeleted — never enters safelyRedundant.
        let srcRec = rec("kids.mov",
                         path: "/Volumes/Mini2TB/kids.mov",
                         size: 5000, md5: "HASH-K")
        let witness = rec("kids.mov",
                          path: "/Volumes/MyBook3Terabytes/family/kids.mov",
                          size: 5000, md5: "HASH-K")

        let result = RelocateReconcile.reconcile(
            records: [srcRec],
            allCatalogRecords: [srcRec, witness],
            sourceVolumeRootPath: "/Volumes/Mini2TB",
            destinationRoot: URL(fileURLWithPath: "/Volumes/LaCie/archive"),
            sourceFiles: [],
            destFiles: [],
            skipDupsOnOtherVolumes: false,
            hash: hashFn([:])
        )
        #expect(result.safelyRedundant.isEmpty)
        #expect(result.manuallyDeleted.count == 1)
    }

    @Test
    func bucketE_winsOverBucketA_evenWhenSourceFileIsStillReadable() throws {
        // Even when the source file is on disk and reads fine, the
        // safely-redundant rule fires when a third-volume witness exists.
        // This is the headline failing-drive use case — we don't WANT to
        // read 739 GB off a flaky drive just because we can. Bucket A loses.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs-recon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let here = tmp.appendingPathComponent("a.mov")
        try Data(repeating: 0, count: 1024).write(to: here)

        let srcRec = rec("a.mov", path: here.path, size: 1024, md5: "HASH-A")
        let witness = rec("a.mov",
                          path: "/Volumes/MyBook3Terabytes/a.mov",
                          size: 1024, md5: "HASH-A")

        let result = RelocateReconcile.reconcile(
            records: [srcRec],
            allCatalogRecords: [srcRec, witness],
            sourceVolumeRootPath: tmp.path,
            destinationRoot: URL(fileURLWithPath: "/tmp/no-dest"),
            sourceFiles: [.init(path: here.path, size: 1024)],
            destFiles: [],
            skipDupsOnOtherVolumes: true,
            hash: hashFn([here.path: "HASH-A"])
        )
        #expect(result.safelyRedundant.count == 1)
        #expect(result.ready.isEmpty)
    }

    @Test
    func bucketE_capsWitnessListAtMaxButTracksFullCount() {
        // Six identical-hash witnesses; sample should hold 5 (the cap),
        // totalWitnessCount should be 6.
        let srcRec = rec("v.mov",
                         path: "/Volumes/Mini2TB/v.mov",
                         size: 2048, md5: "HASH-V")
        var witnesses: [VideoRecord] = []
        for i in 1...6 {
            witnesses.append(rec("v.mov",
                                 path: "/Volumes/W\(i)/v.mov",
                                 size: 2048, md5: "HASH-V"))
        }

        let result = RelocateReconcile.reconcile(
            records: [srcRec],
            allCatalogRecords: [srcRec] + witnesses,
            sourceVolumeRootPath: "/Volumes/Mini2TB",
            destinationRoot: URL(fileURLWithPath: "/Volumes/LaCie/archive"),
            sourceFiles: [],
            destFiles: [],
            skipDupsOnOtherVolumes: true,
            hash: hashFn([:])
        )
        #expect(result.safelyRedundant.count == 1)
        #expect(result.safelyRedundant.first?.witnesses.count == RelocateReconcile.maxWitnessSample)
        #expect(result.safelyRedundant.first?.totalWitnessCount == 6)
    }

    @Test
    func bucketE_emptyHashRecordIsNeverClassifiedAsSafelyRedundant() {
        // Source record with no partialMD5 (legacy). Even with the toggle
        // ON and a witness of the same size on a third volume, we refuse
        // to classify — too weak a signal for a "safely redundant" claim.
        let srcRec = rec("legacy.mov",
                         path: "/Volumes/Mini2TB/legacy.mov",
                         size: 5000, md5: "")
        let witness = rec("similar.mov",
                          path: "/Volumes/MyBook3Terabytes/similar.mov",
                          size: 5000, md5: "HASH-X")  // has hash but src doesn't

        let result = RelocateReconcile.reconcile(
            records: [srcRec],
            allCatalogRecords: [srcRec, witness],
            sourceVolumeRootPath: "/Volumes/Mini2TB",
            destinationRoot: URL(fileURLWithPath: "/Volumes/LaCie/archive"),
            sourceFiles: [],
            destFiles: [],
            skipDupsOnOtherVolumes: true,
            hash: hashFn([:])
        )
        #expect(result.safelyRedundant.isEmpty)
    }

    @Test
    func bucketE_zeroSizeRecordIsNeverClassifiedAsSafelyRedundant() {
        // Zero-byte file: too many of these in real catalogs to trust as a
        // dedup signal. Treat as legacy-weak; never safelyRedundant.
        let srcRec = rec("empty.mov",
                         path: "/Volumes/Mini2TB/empty.mov",
                         size: 0, md5: "HASH-EMPTY")
        let witness = rec("empty.mov",
                          path: "/Volumes/MyBook3Terabytes/empty.mov",
                          size: 0, md5: "HASH-EMPTY")

        let result = RelocateReconcile.reconcile(
            records: [srcRec],
            allCatalogRecords: [srcRec, witness],
            sourceVolumeRootPath: "/Volumes/Mini2TB",
            destinationRoot: URL(fileURLWithPath: "/Volumes/LaCie/archive"),
            sourceFiles: [],
            destFiles: [],
            skipDupsOnOtherVolumes: true,
            hash: hashFn([:])
        )
        #expect(result.safelyRedundant.isEmpty)
    }

    @Test
    func bucketE_witnessOnSourceVolumeIsExcluded() {
        // A "witness" record whose path is itself under sourceVolumeRootPath
        // must NOT count as a third-volume witness. It's the same drive.
        let srcRec = rec("a.mov",
                         path: "/Volumes/Mini2TB/a.mov",
                         size: 1000, md5: "HASH-A")
        let inScopeOther = rec("a.mov",
                               path: "/Volumes/Mini2TB/sub/a-copy.mov",
                               size: 1000, md5: "HASH-A")

        let result = RelocateReconcile.reconcile(
            records: [srcRec],
            allCatalogRecords: [srcRec, inScopeOther],
            sourceVolumeRootPath: "/Volumes/Mini2TB",
            destinationRoot: URL(fileURLWithPath: "/Volumes/LaCie/archive"),
            sourceFiles: [],
            destFiles: [],
            skipDupsOnOtherVolumes: true,
            hash: hashFn([:])
        )
        #expect(result.safelyRedundant.isEmpty)
    }

    @Test
    func bucketE_witnessUnderDestinationIsExcluded() {
        // Witness that lives under destinationRoot — also disqualified.
        // (Dest-side matches are Bucket D's job; we don't double-classify.)
        let srcRec = rec("a.mov",
                         path: "/Volumes/Mini2TB/a.mov",
                         size: 1000, md5: "HASH-A")
        let destResident = rec("a.mov",
                               path: "/Volumes/LaCie/archive/other/a.mov",
                               size: 1000, md5: "HASH-A")

        let result = RelocateReconcile.reconcile(
            records: [srcRec],
            allCatalogRecords: [srcRec, destResident],
            sourceVolumeRootPath: "/Volumes/Mini2TB",
            destinationRoot: URL(fileURLWithPath: "/Volumes/LaCie/archive"),
            sourceFiles: [],
            destFiles: [],
            skipDupsOnOtherVolumes: true,
            hash: hashFn([:])
        )
        #expect(result.safelyRedundant.isEmpty)
        #expect(result.manuallyDeleted.count == 1)
    }
}
