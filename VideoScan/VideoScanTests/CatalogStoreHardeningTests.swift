import Testing
import Foundation
@testable import VideoScan

// MARK: - CatalogStoreHardeningTests
//
// Locks down the persistence hardening pass:
//   1. Atomic write — `writeToDisk` uses Data(.atomic), i.e. writes to a
//      sibling tmp + rename. We can't observe the temp file from the test
//      (it's gone by the time `write` returns), but we CAN observe that
//      a partial-write hazard never leaves a corrupt primary on disk
//      under a write-failure simulation (parent dir non-writable).
//   2. Backup-on-load rotation — every successful load copies primary
//      → catalog.json.prev so a subsequent corrupt primary can fall
//      back to the previous good catalog.
//   3. Newer-version refusal — a catalog.json with version >
//      `CatalogSnapshot.currentVersion` does NOT load, and the load
//      outcome is .refusedNewerVersion(found:). This is the critical
//      data-protection path: without it, an old build loading a newer
//      catalog would silently come back with empty records and the next
//      debounced save would overwrite the user's data.
//   4. Corrupt primary with usable .prev — falls back transparently.
//   5. Corrupt primary AND corrupt .prev — empty records (safe fallback;
//      no crash) with `lastLoadOutcome == .corruptNoBackup`.
//
// All tests use `CatalogStore(directory:)` so they touch a per-test
// temporary directory only — never the user's real Application Support.

@MainActor
struct CatalogStoreHardeningTests {

    // Per-test scratch dir under NSTemporaryDirectory. Caller is responsible
    // for cleanup via `defer { try? FileManager.default.removeItem(at: dir) }`.
    private func scratchDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("videoscan_catalog_hardening_\(UUID().uuidString)",
                                    isDirectory: true)
    }

    private func makeRecord(name: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/Test/\(name)"
        r.partialMD5 = name.uppercased()
        return r
    }

    // Helper: encode a snapshot the same way CatalogStore.writeToDisk does.
    private func encode(snapshot: CatalogSnapshot) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try CatalogSnapshotDTO(snapshot).encoded(using: enc)
    }

    // MARK: - 1. Atomic write

    // The atomic option means primary either exists with the full new
    // content or stays as the old content. A "crash mid-write" simulated by
    // making the parent dir non-writable should leave the prior catalog
    // intact (since the rename can't land), NOT a half-written file.
    @Test
    func atomicWritePreservesPriorCatalogOnWriteFailure() throws {
        let dir = scratchDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            // Restore writability so cleanup succeeds.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let store = CatalogStore(directory: dir)

        // Seed a known-good primary.
        store.saveNow(records: [makeRecord(name: "good.mov")])
        let primaryBefore = try Data(contentsOf: URL(fileURLWithPath: store.fileLocation))
        #expect(primaryBefore.isEmpty == false)

        // Make the directory read-only so the next write fails.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: dir.path
        )

        // Attempt to save — expected to fail silently (logs an NSLog), but
        // must NOT mangle the existing primary.
        store.saveNow(records: [makeRecord(name: "would_clobber.mov")])

        let primaryAfter = try Data(contentsOf: URL(fileURLWithPath: store.fileLocation))
        #expect(primaryAfter == primaryBefore,
                "Failed write must not modify the existing primary catalog")
    }

    // MARK: - 2. Backup-on-load rotation

    // Successful load copies primary → .prev. Verified by:
    //   - Seed primary with records.
    //   - Confirm .prev does NOT exist yet.
    //   - Load via a fresh CatalogStore (same dir).
    //   - .prev now exists and matches primary byte-for-byte.
    @Test
    func loadRotatesPrimaryIntoBackup() throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)

        store.saveNow(records: [makeRecord(name: "a.mov"), makeRecord(name: "b.mov")])
        #expect(FileManager.default.fileExists(atPath: store.backupLocation) == false,
                ".prev must not exist before any load")

        let store2 = CatalogStore(directory: dir)
        let loaded = store2.load()
        #expect(loaded.count == 2)
        #expect(store2.lastLoadOutcome == .loaded(fromBackup: false))
        #expect(FileManager.default.fileExists(atPath: store2.backupLocation),
                ".prev must exist after a successful load")

        let primaryBytes = try Data(contentsOf: URL(fileURLWithPath: store2.fileLocation))
        let backupBytes  = try Data(contentsOf: URL(fileURLWithPath: store2.backupLocation))
        #expect(primaryBytes == backupBytes,
                ".prev must be a byte-for-byte copy of primary")
    }

    // A second load (after the first one rotated) must still leave .prev
    // valid — replaced, not deleted-and-stranded.
    @Test
    func loadRotationIsIdempotent() throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CatalogStore(directory: dir)
        store.saveNow(records: [makeRecord(name: "first.mov")])

        let s1 = CatalogStore(directory: dir)
        _ = s1.load()
        #expect(FileManager.default.fileExists(atPath: s1.backupLocation))

        // Write a new primary, then load again.
        s1.saveNow(records: [makeRecord(name: "second.mov")])
        let s2 = CatalogStore(directory: dir)
        let loaded = s2.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.filename == "second.mov")
        #expect(FileManager.default.fileExists(atPath: s2.backupLocation))
    }

    // MARK: - 3. Newer-version refusal

    // A catalog.json written by a hypothetical future v99 build must NOT
    // load — that would let the current build (which doesn't know about
    // v99 fields) come back with empty records and overwrite on the next
    // debounced save. This is the catastrophic-data-loss path the audit
    // flagged as HIGH severity.
    @Test
    func loadRefusesNewerVersion() throws {
        let dir = scratchDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var future = CatalogSnapshot(
            version: CatalogSnapshot.currentVersion + 1,
            savedAt: Date(),
            records: [makeRecord(name: "from_future.mov")],
            savedFromHost: "FutureMachine"
        )
        future.version = CatalogSnapshot.currentVersion + 1  // explicit in case init drops it
        let data = try encode(snapshot: future)
        try data.write(to: dir.appendingPathComponent("catalog.json"))

        let store = CatalogStore(directory: dir)
        let loaded = store.load()
        #expect(loaded.isEmpty, "Newer-version snapshot must NOT decode into records")
        #expect(store.lastLoadOutcome == .refusedNewerVersion(found: CatalogSnapshot.currentVersion + 1))
    }

    // The current version must always load.
    @Test
    func loadAcceptsCurrentVersion() throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        store.saveNow(records: [makeRecord(name: "current.mov")])

        let store2 = CatalogStore(directory: dir)
        let loaded = store2.load()
        #expect(loaded.count == 1)
        if case .loaded(let fromBackup) = store2.lastLoadOutcome {
            #expect(fromBackup == false)
        } else {
            Issue.record("Expected .loaded(fromBackup: false), got \(store2.lastLoadOutcome)")
        }
    }

    // MARK: - 4. Fallback to .prev on corrupt primary

    @Test
    func loadFallsBackToPrevWhenPrimaryCorrupt() throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Save twice via two loads to populate primary AND .prev.
        let s1 = CatalogStore(directory: dir)
        s1.saveNow(records: [makeRecord(name: "good.mov")])
        let s2 = CatalogStore(directory: dir)
        _ = s2.load()  // rotates primary → .prev
        #expect(FileManager.default.fileExists(atPath: s2.backupLocation))

        // Corrupt primary by truncating it to invalid JSON. .prev untouched.
        try Data("{ not valid json".utf8)
            .write(to: URL(fileURLWithPath: s2.fileLocation))

        let s3 = CatalogStore(directory: dir)
        let loaded = s3.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.filename == "good.mov")
        #expect(s3.lastLoadOutcome == .loaded(fromBackup: true))
    }

    // MARK: - 5. Both corrupt → safe empty

    @Test
    func loadReturnsEmptyWhenBothCorrupt() throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Write garbage to both files directly.
        try Data("{not json".utf8)
            .write(to: dir.appendingPathComponent("catalog.json"))
        try Data("also bad".utf8)
            .write(to: dir.appendingPathComponent("catalog.json.prev"))

        let store = CatalogStore(directory: dir)
        let loaded = store.load()
        #expect(loaded.isEmpty)
        #expect(store.lastLoadOutcome == .corruptNoBackup)
    }

    // Missing file (first launch) reports .missing — not corrupt.
    @Test
    func loadReportsMissingOnFirstLaunch() throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        let loaded = store.load()
        #expect(loaded.isEmpty)
        #expect(store.lastLoadOutcome == .missing)
    }
}

// MARK: - Path Normalization Pin-Down Tests
//
// `applyDetectedPeople`, `applyCaptions`, and `applyAudioTranscript` all do
// exact-string match on `VideoRecord.fullPath`. This is brittle: a record
// at "/Volumes/X/clip.mov" and an incoming path "/Volumes/X/Clip.mov"
// (case-different basename) silently miss, as does a trailing-slash
// difference or symlink. Per Rick's memory `project_path_normalization_risk`,
// changing this behavior is OUT OF SCOPE here (touches too many call sites)
// — but pinning the current contract with tests means a future refactor
// can land confidently or fail loudly.

@MainActor
struct CatalogPathMatchingContractTests {

    private func makeModel(paths: [String]) -> VideoScanModel {
        let m = VideoScanModel()
        m.records = paths.map { p in
            let r = VideoRecord()
            r.filename = (p as NSString).lastPathComponent
            r.fullPath = p
            return r
        }
        return m
    }

    // CONTRACT: exact-string match. Case-sensitive.
    @Test
    func applyCaptionsRequiresExactCaseMatch() {
        let m = makeModel(paths: ["/Volumes/X/Clip.mov"])
        // Case-mismatched path: matches the *intent* but not the string.
        let okMismatch = m.applyCaptions(
            [SceneCaption(timestamp: 0, text: "guitar")],
            to: "/Volumes/X/clip.mov",
            model: "test"
        )
        #expect(okMismatch == false,
                "Current contract: applyCaptions is case-sensitive on fullPath. If this test starts failing, the path-normalization refactor has landed — update or delete this pin-down test.")
        // And the actual exact path DOES match.
        let okExact = m.applyCaptions(
            [SceneCaption(timestamp: 0, text: "guitar")],
            to: "/Volumes/X/Clip.mov",
            model: "test"
        )
        #expect(okExact == true)
    }

    // CONTRACT: trailing slash is NOT normalized.
    @Test
    func applyCaptionsRequiresExactTrailingSlashMatch() {
        let m = makeModel(paths: ["/Volumes/X/Clip.mov"])
        let withTrailingSlash = m.applyCaptions(
            [SceneCaption(timestamp: 0, text: "x")],
            to: "/Volumes/X/Clip.mov/",   // trailing slash that wouldn't be in fullPath
            model: "test"
        )
        #expect(withTrailingSlash == false)
    }

    // CONTRACT: applyDetectedPeople is also exact-match.
    @Test
    func applyDetectedPeopleIsCaseSensitive() {
        let m = makeModel(paths: ["/Volumes/X/Clip.mov"])
        let result = pfVideoResult(
            filename: "clip.mov",
            filePath: "/Volumes/X/clip.mov",   // lowercase
            durationSeconds: 10,
            fps: 30,
            totalHits: 1,
            segments: [pfSegment(startSecs: 0, endSecs: 1, bestDistance: 0.3, avgDistance: 0.4)]
        )
        let n = m.applyDetectedPeople(matches: [result], person: "Donna")
        #expect(n == 0,
                "Current contract: case-mismatched paths silently miss. Locks down behavior — refactor to normalize must update this.")
    }

    // CONTRACT: applyAudioTranscript is exact-match.
    @Test
    func applyAudioTranscriptIsCaseSensitive() {
        let m = makeModel(paths: ["/Volumes/X/Clip.mov"])
        let ok = m.applyAudioTranscript(
            "hello",
            to: "/volumes/x/clip.mov",
            model: "whisper-test"
        )
        #expect(ok == false)
    }

    // POSITIVE control — exact match works through all three apply* call sites.
    @Test
    func exactMatchSucceedsAcrossApplyFamily() {
        let m = makeModel(paths: ["/Volumes/X/Clip.mov"])

        let cap = m.applyCaptions(
            [SceneCaption(timestamp: 0, text: "x")],
            to: "/Volumes/X/Clip.mov",
            model: "vlm"
        )
        #expect(cap == true)

        let dp = m.applyDetectedPeople(
            matches: [pfVideoResult(
                filename: "Clip.mov",
                filePath: "/Volumes/X/Clip.mov",
                durationSeconds: 10,
                fps: 30,
                totalHits: 1,
                segments: [pfSegment(startSecs: 0, endSecs: 1, bestDistance: 0.3, avgDistance: 0.4)]
            )],
            person: "Donna"
        )
        #expect(dp == 1)

        let tr = m.applyAudioTranscript(
            "hello",
            to: "/Volumes/X/Clip.mov",
            model: "whisper-test"
        )
        #expect(tr == true)
    }
}

// MARK: - CatalogSnapshot version handling tests
//
// Companion to the CatalogStore newer-version refusal: pin the snapshot's
// own decode contract so a missing version key still implies v1 (legacy
// snapshots from the records-only era).

struct CatalogSnapshotVersionTests {

    @Test
    func snapshotMissingVersionKeyImpliesV1() throws {
        // A pre-version-key snapshot — only records present. Decode must
        // succeed and report version == 1 (the v1 contract).
        let json = """
        {
          "records": []
        }
        """
        let data = Data(json.utf8)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let snap = try dec.decode(CatalogSnapshot.self, from: data)
        #expect(snap.version == 1)
        #expect(snap.records.isEmpty)
    }

    @Test
    func snapshotExplicitV4Decodes() throws {
        let json = """
        {
          "version": 4,
          "savedAt": "2026-05-23T12:00:00Z",
          "records": [],
          "savedFromHost": "MacStudio"
        }
        """
        let data = Data(json.utf8)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let snap = try dec.decode(CatalogSnapshot.self, from: data)
        #expect(snap.version == 4)
        #expect(snap.savedFromHost == "MacStudio")
    }
}
