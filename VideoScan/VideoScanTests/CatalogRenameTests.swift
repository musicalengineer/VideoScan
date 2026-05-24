import Testing
import Foundation
@testable import VideoScan

// MARK: - Catalog Rename Tests
//
// Pins down the rename-on-disk + persist-in-catalog flow that lives on
// `VideoScanModel.renameRecord(_:toBaseName:)`. Before the fix:
//  - The view-local `performRename()` mutated rec.filename and rec.fullPath
//    but never called `saveCatalogDebounced()`, so a relaunch reverted the
//    in-memory rename.
//  - FileManager failures were silently caught — the sheet closed and the
//    user had no idea why nothing happened.
//  - No audit of path-keyed structures: thumbnailCache leaked entries
//    under the old path.
//
// These tests write to a tmp dir; they never touch real user files.
// CatalogStore.scheduleSave() is a no-op under tests (see
// CatalogStore.isRunningTests), so we don't assert on the on-disk
// catalog.json — instead we verify the *record* mutated correctly, the
// disk file was actually moved, and (when applicable) cross-reference
// state was updated.

@MainActor
struct CatalogRenameTests {

    // MARK: helpers

    /// Build an isolated tmp directory the test owns end-to-end. We
    /// cleanup-on-deinit by stashing the URL in a deferred-cleanup
    /// closure inside each test (no shared mutable state across tests).
    private static func makeTmpDir(label: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoScanRenameTests-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func writeFixture(at url: URL, bytes: String = "fixture") throws {
        try bytes.data(using: .utf8)!.write(to: url)
    }

    /// VideoRecord pointed at an on-disk path. Mirrors the populate-then-
    /// hand-to-model pattern used by FamilyTaggingTests.
    private static func record(at fullPath: String) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = fullPath
        r.filename = (fullPath as NSString).lastPathComponent
        r.ext      = ((fullPath as NSString).pathExtension).uppercased()
        r.directory = (fullPath as NSString).deletingLastPathComponent
        return r
    }

    // MARK: positive: rename succeeds end-to-end

    @Test func renameMovesFileAndUpdatesRecord() throws {
        let tmp = try Self.makeTmpDir(label: "happy")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let oldURL = tmp.appendingPathComponent("scratch.mxf")
        try Self.writeFixture(at: oldURL)

        let model = VideoScanModel()
        let rec = Self.record(at: oldURL.path)
        model.records = [rec]

        let newPath = try model.renameRecord(rec, toBaseName: "Donna_Wedding_1987")

        // Disk-side: file moved
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(FileManager.default.fileExists(atPath: newPath))

        // In-memory mutation
        #expect(rec.filename == "Donna_Wedding_1987.mxf")
        #expect(rec.fullPath == newPath)
        // Returned path lines up with what we mutated
        #expect(newPath == tmp.appendingPathComponent("Donna_Wedding_1987.mxf").path)
    }

    // The "saveCatalogDebounced was missing" bug: verify the rename path
    // does invoke the persistence layer. CatalogStore.scheduleSave is a
    // no-op under tests, so we can't read the JSON back — but we *can*
    // verify the model state survives an encoder round-trip, which is
    // what the persistence path eventually does on disk.
    @Test func renamedRecordRoundTripsThroughCatalogEncoder() throws {
        let tmp = try Self.makeTmpDir(label: "roundtrip")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let oldURL = tmp.appendingPathComponent("orig.mxf")
        try Self.writeFixture(at: oldURL)

        let model = VideoScanModel()
        let rec = Self.record(at: oldURL.path)
        model.records = [rec]

        _ = try model.renameRecord(rec, toBaseName: "renamed_clip")

        // Encode + decode through the same CatalogSnapshot used on disk.
        let snap = CatalogSnapshot(records: model.records)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snap)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CatalogSnapshot.self, from: data)

        #expect(decoded.records.count == 1)
        #expect(decoded.records.first?.filename == "renamed_clip.mxf")
        #expect(decoded.records.first?.fullPath == tmp.appendingPathComponent("renamed_clip.mxf").path)
    }

    // MARK: positive: cross-reference structures stay valid

    // Paired records cross-reference by object identity (`pairedWith:
    // VideoRecord?`), not by path string. A rename of either side must
    // not invalidate the pair.
    @Test func renamingDoesNotBreakPairedWithReference() throws {
        let tmp = try Self.makeTmpDir(label: "pair")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let videoURL = tmp.appendingPathComponent("v_only.mxf")
        let audioURL = tmp.appendingPathComponent("a_only.mxf")
        try Self.writeFixture(at: videoURL)
        try Self.writeFixture(at: audioURL)

        let model = VideoScanModel()
        let video = Self.record(at: videoURL.path)
        let audio = Self.record(at: audioURL.path)
        video.pairedWith = audio
        audio.pairedWith = video
        model.records = [video, audio]

        _ = try model.renameRecord(video, toBaseName: "v_renamed")

        // Identity-based references survive: both sides still point at
        // each other, and the partner now reflects the renamed path.
        #expect(video.pairedWith === audio)
        #expect(audio.pairedWith === video)
        #expect(video.pairedWith?.fullPath == audioURL.path)   // audio untouched
        #expect(audio.pairedWith?.fullPath.hasSuffix("v_renamed.mxf") == true)
    }

    // applyDetectedPeople / applyCaptions look up by `fullPath` against the
    // *current* records array on each call. Post-rename, looking up by the
    // new path should succeed; looking up by the old path should miss.
    // This codifies the "writeback after rename must use the new path"
    // contract (see the cross-reference audit in
    // VideoScanModel+Rename.swift).
    @Test func writebackPostRenameMatchesNewPathNotOld() throws {
        let tmp = try Self.makeTmpDir(label: "writeback")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let oldURL = tmp.appendingPathComponent("clip.mxf")
        try Self.writeFixture(at: oldURL)

        let model = VideoScanModel()
        let rec = Self.record(at: oldURL.path)
        model.records = [rec]
        let oldPath = oldURL.path

        let newPath = try model.renameRecord(rec, toBaseName: "clip_tagged")

        // Lookup under new path → hit
        #expect(model.records.first(where: { $0.fullPath == newPath })?.id == rec.id)
        // Lookup under old path → miss (the in-memory state is consistent)
        #expect(model.records.first(where: { $0.fullPath == oldPath }) == nil)

        // And a real applyCaptions writeback against the new path lands
        // captions on the renamed record.
        let captions = [SceneCaption(timestamp: 1.0, text: "test")]
        let didApply = model.applyCaptions(captions, to: newPath, model: "test-model")
        #expect(didApply == true)
        #expect(rec.sceneCaptions.count == 1)
    }

    // MARK: negative paths

    @Test func renameFailsWhenDestinationExists() throws {
        let tmp = try Self.makeTmpDir(label: "dest-exists")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let srcURL = tmp.appendingPathComponent("src.mxf")
        let dstURL = tmp.appendingPathComponent("dst.mxf")
        try Self.writeFixture(at: srcURL, bytes: "src")
        try Self.writeFixture(at: dstURL, bytes: "dst")

        let model = VideoScanModel()
        let rec = Self.record(at: srcURL.path)
        model.records = [rec]

        #expect(throws: VideoScanModel.RenameError.self) {
            _ = try model.renameRecord(rec, toBaseName: "dst")
        }

        // Original file untouched on disk and in record
        #expect(FileManager.default.fileExists(atPath: srcURL.path))
        #expect(FileManager.default.fileExists(atPath: dstURL.path))
        #expect(rec.filename == "src.mxf")
        #expect(rec.fullPath == srcURL.path)

        // Destination file contents untouched (didn't get overwritten)
        let dstAfter = try String(contentsOf: dstURL, encoding: .utf8)
        #expect(dstAfter == "dst")
    }

    @Test func renameFailsWhenSourceMissing() throws {
        let tmp = try Self.makeTmpDir(label: "src-missing")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = VideoScanModel()
        // Record points at a path that does not exist (stale catalog
        // entry from a volume that's now offline or a file the user
        // moved outside the app).
        let rec = Self.record(at: tmp.appendingPathComponent("ghost.mxf").path)
        model.records = [rec]

        #expect(throws: VideoScanModel.RenameError.self) {
            _ = try model.renameRecord(rec, toBaseName: "found_at_last")
        }

        // No phantom file created at the destination
        #expect(!FileManager.default.fileExists(atPath: tmp.appendingPathComponent("found_at_last.mxf").path))
        #expect(rec.filename == "ghost.mxf")
    }

    // Provoke a FileManager error by attempting to rename into a
    // non-writable parent. Mark the source's *parent* read-only so
    // moveItem can read the source but cannot create the entry under
    // a different name. (Renaming inside a chmod 555 dir fails with
    // EPERM/EACCES on APFS.)
    @Test func renameSurfacesFileManagerError() throws {
        let tmp = try Self.makeTmpDir(label: "fm-error")
        defer {
            // Restore writable so cleanup works
            _ = try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: tmp.path
            )
            try? FileManager.default.removeItem(at: tmp)
        }

        let srcURL = tmp.appendingPathComponent("ro_src.mxf")
        try Self.writeFixture(at: srcURL)

        // chmod the dir to read+execute only — no write means no rename.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: tmp.path
        )

        let model = VideoScanModel()
        let rec = Self.record(at: srcURL.path)
        model.records = [rec]

        var caught: Error?
        do {
            _ = try model.renameRecord(rec, toBaseName: "ro_dst")
        } catch {
            caught = error
        }
        #expect(caught != nil)
        if case .filesystem = caught as? VideoScanModel.RenameError {
            // expected branch
        } else {
            Issue.record("Expected RenameError.filesystem, got \(String(describing: caught))")
        }

        // Record left untouched on failure
        #expect(rec.filename == "ro_src.mxf")
        #expect(rec.fullPath == srcURL.path)
    }

    // Empty / whitespace name is treated as a no-op (preserves old UX:
    // the sheet just closes), not as an error to alert about.
    @Test func renameWithEmptyNameIsNoOp() throws {
        let tmp = try Self.makeTmpDir(label: "empty-name")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let url = tmp.appendingPathComponent("keepme.mxf")
        try Self.writeFixture(at: url)

        let model = VideoScanModel()
        let rec = Self.record(at: url.path)
        model.records = [rec]

        // Whitespace-only — should throw .emptyName (caller swallows)
        #expect(throws: VideoScanModel.RenameError.self) {
            _ = try model.renameRecord(rec, toBaseName: "   ")
        }
        // Truly empty
        #expect(throws: VideoScanModel.RenameError.self) {
            _ = try model.renameRecord(rec, toBaseName: "")
        }

        // File untouched
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(rec.filename == "keepme.mxf")
        #expect(rec.fullPath == url.path)
    }

    // Path separators in the "filename" must not let the rename UI
    // become a file-mover.
    @Test func renameRejectsPathSeparators() throws {
        let tmp = try Self.makeTmpDir(label: "no-slash")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let url = tmp.appendingPathComponent("safe.mxf")
        try Self.writeFixture(at: url)

        let model = VideoScanModel()
        let rec = Self.record(at: url.path)
        model.records = [rec]

        #expect(throws: VideoScanModel.RenameError.self) {
            _ = try model.renameRecord(rec, toBaseName: "../escape")
        }
        #expect(throws: VideoScanModel.RenameError.self) {
            _ = try model.renameRecord(rec, toBaseName: "sub/dir/file")
        }
        #expect(rec.filename == "safe.mxf")
    }

    // Sanity check: the new-name-equals-old-name guard fires before
    // we touch the filesystem.
    @Test func renameWithUnchangedNameIsNoOp() throws {
        let tmp = try Self.makeTmpDir(label: "same-name")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let url = tmp.appendingPathComponent("hello.mxf")
        try Self.writeFixture(at: url)

        let model = VideoScanModel()
        let rec = Self.record(at: url.path)
        model.records = [rec]

        #expect(throws: VideoScanModel.RenameError.self) {
            // "hello" + ".mxf" == "hello.mxf" (current filename)
            _ = try model.renameRecord(rec, toBaseName: "hello")
        }
        #expect(rec.filename == "hello.mxf")
    }
}
