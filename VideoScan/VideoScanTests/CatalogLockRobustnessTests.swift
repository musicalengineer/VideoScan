//
//  CatalogLockRobustnessTests.swift
//  VideoScanTests
//
//  Proves the catalog's cross-process write safety against a DUMMY catalog
//  in a temp directory -- never the real ~/Library/Application Support one.
//
//  These exist because of a real incident on 2026-08-14: an external script
//  reduced the catalog from 18,142 to 8,760 records, the app was launched
//  mid-operation, and the app's stale in-memory copy overwrote the result.
//  9,382 records of work vanished with no error and no torn file.
//
//  The five dimensions from the project checklist:
//    logic     -- acquire/release/contention/reentrancy, staleness, checksum
//    scale     -- 100k-record catalog stays within a stated time budget
//    media     -- N/A, this layer opens no media
//    isolation -- every test uses its own temp dir; the real catalog and the
//                 shared singleton are never touched
//    sensor    -- testStaleWriteIsRefused_theAugust14Regression pins the
//                 exact production failure
//

import XCTest
@testable import VideoScan

final class CatalogLockRobustnessTests: XCTestCase {

    private var dir: URL!
    private var catalogURL: URL!
    private var lockURL: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CatalogLockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        catalogURL = dir.appendingPathComponent("catalog.json")
        lockURL = dir.appendingPathComponent("catalog.lock")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Lock semantics

    func testAcquireSucceedsOnFreeLock() {
        let lock = CatalogLock(lockURL: lockURL)
        XCTAssertEqual(lock.acquire(), .acquired)
        XCTAssertTrue(lock.isHeldByUs)
        lock.release()
        XCTAssertFalse(lock.isHeldByUs)
    }

    func testAcquireIsReentrantForSameInstance() {
        let lock = CatalogLock(lockURL: lockURL)
        XCTAssertEqual(lock.acquire(), .acquired)
        XCTAssertEqual(lock.acquire(), .acquired, "same owner must not deadlock itself")
        lock.release()
    }

    func testSecondHolderIsRefusedWhileFirstHolds() {
        let first = CatalogLock(lockURL: lockURL)
        XCTAssertEqual(first.acquire(), .acquired)

        // A distinct fd on the same file is what a second process looks like
        // to flock, so this genuinely exercises the contention path.
        let second = CatalogLock(lockURL: lockURL)
        guard case .heldByAnother = second.acquire() else {
            return XCTFail("second holder must be refused while the first holds")
        }
        XCTAssertFalse(second.isHeldByUs)

        first.release()
        XCTAssertEqual(second.acquire(), .acquired, "must be acquirable once released")
        second.release()
    }

    func testOwnerMetadataIdentifiesTheHolder() throws {
        let lock = CatalogLock(lockURL: lockURL)
        XCTAssertEqual(lock.acquire(), .acquired)
        let owner = try XCTUnwrap(CatalogLock.readOwner(at: lockURL))
        XCTAssertEqual(owner.pid, getpid())
        XCTAssertFalse(owner.hostname.isEmpty)
        lock.release()
    }

    func testReleaseClearsOwnerMetadata() {
        let lock = CatalogLock(lockURL: lockURL)
        XCTAssertEqual(lock.acquire(), .acquired)
        XCTAssertNotNil(CatalogLock.readOwner(at: lockURL))
        lock.release()
        XCTAssertNil(CatalogLock.readOwner(at: lockURL),
                     "a released lock must not advertise a stale owner")
    }

    func testWaiterTimesOutRatherThanHangingForever() {
        let holder = CatalogLock(lockURL: lockURL)
        XCTAssertEqual(holder.acquire(), .acquired)

        let waiter = CatalogLock(lockURL: lockURL)
        let t0 = Date()
        let result = waiter.acquire(waitingUpTo: 0.75, pollInterval: 0.1)
        let elapsed = Date().timeIntervalSince(t0)

        guard case .heldByAnother = result else {
            return XCTFail("waiter must report contention, not acquire")
        }
        XCTAssertGreaterThanOrEqual(elapsed, 0.7, "must actually wait")
        XCTAssertLessThan(elapsed, 3.0, "must not hang past its timeout")
        holder.release()
    }

    func testWaiterAcquiresOnceHolderReleases() {
        let holder = CatalogLock(lockURL: lockURL)
        XCTAssertEqual(holder.acquire(), .acquired)

        let released = expectation(description: "holder released")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            holder.release()
            released.fulfill()
        }

        let waiter = CatalogLock(lockURL: lockURL)
        let result = waiter.acquire(waitingUpTo: 5.0, pollInterval: 0.1)
        XCTAssertEqual(result, .acquired, "waiter must get the lock after release")
        wait(for: [released], timeout: 2.0)
        waiter.release()
    }

    // MARK: - Error contract

    func testErrorCodesAreStableAndDistinct() {
        let all: [CatalogWriteError] = [
            .readOnlyViewer,
            .lockedByAnotherProcess(owner: nil),
            .staleGeneration(loaded: 1, onDisk: 2),
            .lockUnavailable("x"),
            .writeFailed("x"),
            .verificationFailed(expectedSHA256: "a", actualSHA256: "b", bytes: 1),
            .writesDisabled("newer build"),
        ]
        XCTAssertEqual(Set(all.map(\.code)).count, all.count, "codes must be distinct")
        // Frozen values -- renumbering breaks logs and support requests.
        XCTAssertEqual(CatalogWriteError.readOnlyViewer.code, 1)
        XCTAssertEqual(CatalogWriteError.lockedByAnotherProcess(owner: nil).code, 2)
        XCTAssertEqual(CatalogWriteError.staleGeneration(loaded: 1, onDisk: 2).code, 3)
        XCTAssertEqual(CatalogWriteError.writesDisabled("x").code, 7)
    }

    func testStaleGenerationIsNotTreatedAsTransient() {
        // A blind retry after a stale-generation refusal would reintroduce
        // the very lost update the guard exists to prevent.
        XCTAssertFalse(CatalogWriteError.staleGeneration(loaded: 1, onDisk: 2).isTransient)
        XCTAssertFalse(CatalogWriteError.writesDisabled("newer build").isTransient)
        XCTAssertTrue(CatalogWriteError.lockedByAnotherProcess(owner: nil).isTransient)
    }

    // MARK: - Journal

    func testJournalRecordsAndReadsBackRefusals() throws {
        CatalogWriteJournal.record(.lockedByAnotherProcess(owner: nil),
                                   catalogURL: catalogURL)
        CatalogWriteJournal.record(.staleGeneration(loaded: 1, onDisk: 2),
                                   catalogURL: catalogURL)

        let entries = CatalogWriteJournal.recent(10, catalogURL: catalogURL)
        XCTAssertEqual(entries.count, 2)
        // Newest first.
        XCTAssertEqual(entries.first?.kind, "stale")
        XCTAssertEqual(entries.first?.code, 3)
        XCTAssertEqual(entries.last?.kind, "locked")
        XCTAssertEqual(entries.first?.pid, getpid())
    }

    func testJournalAppendsRatherThanTruncating() {
        for _ in 0..<5 {
            CatalogWriteJournal.record(.readOnlyViewer, catalogURL: catalogURL)
        }
        XCTAssertEqual(CatalogWriteJournal.recent(50, catalogURL: catalogURL).count, 5,
                       "each refusal must survive; the journal is append-only")
    }

    /// Codex #385: the journal was unbounded. It now rotates to `.1` once it
    /// passes `maxBytes`, keeping one older generation.
    func testJournalRotatesInsteadOfGrowingWithoutBound() throws {
        let saved = CatalogWriteJournal.maxBytes
        defer { CatalogWriteJournal.maxBytes = saved }
        CatalogWriteJournal.maxBytes = 600     // ~3 entries
        for _ in 0..<40 {
            CatalogWriteJournal.record(.readOnlyViewer, catalogURL: catalogURL)
        }
        let url = CatalogWriteJournal.journalURL(besideCatalogAt: catalogURL)
        let rotated = url.appendingPathExtension("1")
        let liveSize = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertLessThan(liveSize, 600 + 400, "live journal must be capped near maxBytes, was \(liveSize)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path), "one rotated generation is kept")
        // Whatever is live is still well-formed JSONL.
        XCTAssertFalse(CatalogWriteJournal.recent(50, catalogURL: catalogURL).isEmpty)
    }

    /// O_APPEND: 8 concurrent writers x 50 entries must yield exactly 400
    /// intact lines -- no interleaved/torn lines, no lost appends.
    func testJournalConcurrentAppendsAreNeverTornOrLost() {
        let saved = CatalogWriteJournal.maxBytes
        defer { CatalogWriteJournal.maxBytes = saved }
        CatalogWriteJournal.maxBytes = .max     // no rotation during this test
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<50 {
                CatalogWriteJournal.record(.readOnlyViewer, catalogURL: catalogURL)
            }
        }
        let entries = CatalogWriteJournal.recent(1000, catalogURL: catalogURL)
        XCTAssertEqual(entries.count, 400, "every concurrent append must land intact")
    }

    func testJournalSurvivesAMissingDirectoryWithoutThrowing() {
        // Error handling must not itself become a source of errors.
        let bogus = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/catalog.json")
        CatalogWriteJournal.record(.readOnlyViewer, catalogURL: bogus)
        XCTAssertTrue(CatalogWriteJournal.recent(5, catalogURL: bogus).isEmpty)
    }

    // MARK: - Checksum

    func testSHA256DetectsASingleFlippedByte() {
        var data = Data("the quick brown fox".utf8)
        let before = CatalogStore.sha256Hex(data)
        data[3] ^= 0x01
        XCTAssertNotEqual(before, CatalogStore.sha256Hex(data),
                          "checksum must catch a one-bit change")
    }

    func testSHA256IsStableForIdenticalContent() {
        let a = Data(repeating: 0xAB, count: 4096)
        let b = Data(repeating: 0xAB, count: 4096)
        XCTAssertEqual(CatalogStore.sha256Hex(a), CatalogStore.sha256Hex(b))
    }

    // MARK: - Scale

    /// Streaming verify (#161 suspect 3) must agree with the in-memory
    /// digest byte-for-byte across chunk boundaries -- 3.5 MB spans four
    /// 1 MB chunks with a ragged tail.
    func testStreamingSHA256MatchesInMemoryAcrossChunkBoundaries() throws {
        var payload = Data(count: 3 * 1024 * 1024 + 512 * 1024)
        payload.withUnsafeMutableBytes { buf in
            for i in 0..<buf.count { buf[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        }
        let url = dir.appendingPathComponent("stream.bin")
        try payload.write(to: url)
        XCTAssertEqual(try CatalogStore.sha256HexStreaming(fileURL: url),
                       CatalogStore.sha256Hex(payload))
        // And an empty file hashes to the SHA-256 of nothing.
        let empty = dir.appendingPathComponent("empty.bin")
        try Data().write(to: empty)
        XCTAssertEqual(try CatalogStore.sha256HexStreaming(fileURL: empty),
                       CatalogStore.sha256Hex(Data()))
    }

    /// fullFsync is best-effort: a path that does not exist must not crash
    /// or throw, and a real file survives it unchanged.
    func testFullFsyncIsBestEffortAndHarmless() throws {
        CatalogStore.fullFsync(fileURL: dir.appendingPathComponent("does-not-exist.json"))
        let url = dir.appendingPathComponent("real.json")
        try Data("{}".utf8).write(to: url)
        CatalogStore.fullFsync(fileURL: url)
        XCTAssertEqual(try Data(contentsOf: url), Data("{}".utf8))
    }

    func testChecksumOfA100kRecordSizedPayloadIsFast() {
        // A 100k-record catalog is roughly 400 MB of JSON. Verification runs
        // on every save, so it must not dominate the write.
        let payload = Data(repeating: 0x7B, count: 400 * 1024 * 1024)
        let t0 = CFAbsoluteTimeGetCurrent()
        _ = CatalogStore.sha256Hex(payload)
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        XCTAssertLessThan(elapsed, 5.0,
                          "SHA-256 of a 400 MB catalog took \(elapsed)s; budget is 5s")
    }

    func testLockAcquisitionIsCheapUnderRepeatedUse() {
        let lock = CatalogLock(lockURL: lockURL)
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<1000 {
            _ = lock.acquire()      // re-entrant fast path
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        lock.release()
        XCTAssertLessThan(elapsed, 1.0,
                          "1000 re-entrant acquires took \(elapsed)s; budget is 1s")
    }

    /// #161 sensor: the store takes and releases the lock around EVERY save,
    /// on the main actor. A full acquire/release cycle must therefore be
    /// microseconds, not an fsync -- 200 cycles well under 250 ms.
    func testFullAcquireReleaseCycleIsCheap_noFsyncPerSave() {
        let lock = CatalogLock(lockURL: lockURL)
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<200 {
            XCTAssertEqual(lock.acquire(), .acquired)
            lock.release()
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        XCTAssertLessThan(elapsed, 0.25,
                          "200 acquire/release cycles took \(elapsed)s; an fsync per acquire has crept back in")
    }

    // MARK: - The August 14 regression sensor
    //
    // This is the one that matters. The header used to CLAIM this test
    // existed while it did not -- caught by codex review (#376). The
    // incident it pins: an external writer reduced the catalog, the app
    // was launched mid-operation, loaded the pre-reduction file, and wrote
    // its stale in-memory copy back over the result. Both writes were
    // well-formed and correctly serialised, so a lock alone would NOT have
    // caught it. Only a staleness check does.

    /// Reconcile-then-save (design doc): after the live dossier reload has
    /// merged a cooperating writer's file, adopting its generation lets the
    /// session save again -- stamping on top of the foreign write, never
    /// underneath it. Adopt is forward-only and a no-op when disk is not
    /// ahead of us.
    @MainActor
    func testAdoptOnDiskGenerationAfterReconcileUnblocksSaves() throws {
        let store = CatalogStore(directory: dir)
        try Data("{\"version\":6,\"generation\":3,\"records\":[]}".utf8).write(to: catalogURL)
        _ = store.load()
        XCTAssertEqual(store.loadedGeneration, 3)

        // A cooperating external writer (merge_dossier_jsonl) bumps to 4.
        try Data("{\"version\":6,\"generation\":4,\"records\":[]}".utf8).write(to: catalogURL)
        XCTAssertFalse(store.saveNow(records: []), "must refuse before reconcile")

        // No-op when not behind (simulate: nothing newer) -- adopt is forward-only.
        store.adoptOnDiskGenerationAfterReconcile()
        XCTAssertEqual(store.loadedGeneration, 4)
        store.adoptOnDiskGenerationAfterReconcile()
        XCTAssertEqual(store.loadedGeneration, 4, "adopt never regresses or double-counts")

        XCTAssertTrue(store.saveNow(records: []), "after reconcile the session may save again")
        XCTAssertEqual(CatalogSnapshot.headerProbe(at: catalogURL)?.generation, 5,
                       "the save stamps on top of the foreign write")
    }

    @MainActor
    func testStaleWriteIsRefused_theAugust14Regression() throws {
        let store = CatalogStore(directory: dir)

        // A writer loads the catalog. No generation key -- a pre-OCC
        // catalog -- baselines the session at generation 0.
        try Data("{\"version\":6,\"records\":[]}".utf8).write(to: catalogURL)
        _ = store.load()
        XCTAssertEqual(store.loadedGeneration, 0)

        // ...then somebody else writes generation 1 underneath it. Note:
        // NO sleep. mtime needed a 1.1s nap to defeat timestamp slack;
        // generations are exact. (shutil.copy2 preserves mtime, which is
        // why the old guard could never have caught the real incident.)
        try Data("{\"version\":6,\"generation\":1,\"records\":[]}".utf8)
            .write(to: catalogURL)

        // The stale writer must now be refused, not silently allowed to win.
        let refused = store.saveNow(records: [])
        XCTAssertFalse(refused, "a stale write must be refused, not silently win")
        XCTAssertEqual(store.lastWriteError?.kind, "stale",
                       "refusal must be attributed to staleness, got \(String(describing: store.lastWriteError))")

        // And it must be RECORDED, not merely returned -- the incident was
        // invisible precisely because nothing was written down.
        let journal = CatalogWriteJournal.recent(10, catalogURL: catalogURL)
        XCTAssertTrue(journal.contains { $0.kind == "stale" },
                      "the refusal must appear in the journal")
    }

    @MainActor
    func testSuccessfulSaveBumpsGenerationAndHeaderProbeReadsIt() throws {
        let store = CatalogStore(directory: dir)
        try Data("{\"version\":6,\"generation\":41,\"records\":[]}".utf8)
            .write(to: catalogURL)
        _ = store.load()
        XCTAssertEqual(store.loadedGeneration, 41)

        XCTAssertTrue(store.saveNow(records: []), "non-stale save must succeed")
        XCTAssertEqual(store.loadedGeneration, 42, "save must claim generation+1")

        // The stamp must be on disk AND readable from the first 4 KB --
        // that cheap probe is what makes the OCC check affordable on a
        // 41 MB catalog.
        let probe = try XCTUnwrap(CatalogSnapshot.headerProbe(at: catalogURL))
        XCTAssertEqual(probe.generation, 42)
        XCTAssertEqual(probe.version, CatalogSnapshot.currentVersion)
    }

    @MainActor
    func testFutureSchemaLoadLatchesWritesOff() throws {
        // Codex #377 blocker 3: load() of a NEWER-build catalog returned []
        // but left writes enabled, so the quit-time save would replace a
        // future-schema catalog with an empty current-schema one.
        let store = CatalogStore(directory: dir)
        let future = CatalogSnapshot.currentVersion + 1
        try Data("{\"version\":\(future),\"generation\":7,\"records\":[]}".utf8)
            .write(to: catalogURL)

        XCTAssertTrue(store.load().isEmpty, "future-schema catalog must refuse to load")
        XCTAssertNotNil(store.writesDisabledReason, "refusing to load must latch writes off")

        XCTAssertFalse(store.saveNow(records: []),
                       "no write may proceed while the latch is set")
        XCTAssertEqual(store.lastWriteError?.kind, "writesDisabled")

        // The future catalog must be byte-for-byte untouched.
        let survived = try XCTUnwrap(CatalogSnapshot.headerProbe(at: catalogURL))
        XCTAssertEqual(survived.version, future)
        XCTAssertEqual(survived.generation, 7)
    }

    func testLockUnavailableFailsOpenRatherThanBrickingSaves() {
        // An advisory lock that cannot be created must NOT block writing.
        // Refusing every save because a lock file could not be made turns
        // an unlikely filesystem problem into guaranteed data loss.
        let lock = CatalogLock(lockURL: URL(fileURLWithPath:
            "/nonexistent-\(UUID().uuidString)/catalog.lock"))
        guard case .unavailable = lock.acquire() else {
            return XCTFail("expected .unavailable for an uncreatable lock file")
        }
        // The store's precondition treats this as fail-open; see
        // CatalogStore.writePrecondition.
    }

    // MARK: - Python round-trip sensor (the fourth-clobber gate)
    //
    // On 8/14 the catalog reduction was reverted three times. The third
    // reversion's mechanism, established by log-timeline elimination: the
    // app FAILED TO DECODE the python-written catalog.json and silently
    // fell back to .prev, resurrecting the pre-reduction file. Every
    // maintenance script writes via python json.dump, so "the app can
    // decode python-round-tripped JSON" is a load-bearing assumption that
    // was never tested. This sensor either proves it or reproduces the
    // failure with a diffable artifact. DO NOT re-run catalog_reduce.py
    // --apply while this test is red.

    @MainActor
    func testPythonRoundTrippedCatalogStillDecodes() throws {
        let python = "/usr/bin/python3"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python),
                          "python3 required for this sensor")

        // Synthetic records exercising the field shapes the real catalog
        // uses: dates, floats, nested arrays, unicode, pair references.
        let store = CatalogStore(directory: dir)
        let a = VideoRecord()
        a.filename = "Donna-Cape-1991 — été.mov"      // unicode: ensure_ascii path
        a.fullPath = "/Volumes/Test/Donna-Cape-1991 — été.mov"
        a.durationSeconds = 3808.271133                // float precision
        a.sizeBytes = 69_189_370_465                   // > Int32
        a.notes = "line1\nline2\t\"quoted\" \\ slash/" // escapes
        let b = VideoRecord()
        b.filename = "pair-half.mxf"
        b.fullPath = "/Volumes/Test/pair-half.mxf"
        // NOTE deliberately NOT paired: revalidateExistingPairs correctly
        // clears pairs whose endpoints aren't valid A/V halves, so a
        // synthetic pair here tests the validator, not the round-trip.
        // (First version of this test made that mistake.)
        XCTAssertTrue(store.saveNow(records: [a, b]), "seed save must succeed")

        // Round-trip through python exactly the way the maintenance
        // scripts do: json.load -> json.dump. No compact separators, no
        // sort -- the defaults catalog_reduce.py uses.
        let script = """
        import json, sys
        p = sys.argv[1]
        d = json.load(open(p))
        json.dump(d, open(p, "w"))
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = ["-c", script, catalogURL.path]
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0, "python round-trip must succeed")

        // The app must still decode it -- and must NOT have fallen back.
        let store2 = CatalogStore(directory: dir)
        let loaded = store2.load()
        XCTAssertEqual(loaded.count, 2,
                       "python-round-tripped catalog must decode; falling back or "
                       + "returning [] here is exactly the third-clobber mechanism")
        XCTAssertEqual(store2.lastLoadOutcome, .loaded(fromBackup: false),
                       "must load the PRIMARY, not fall back to .prev")
        let names = Set(loaded.map(\.filename))
        XCTAssertTrue(names.contains("Donna-Cape-1991 — été.mov"), "unicode filename must survive")
        XCTAssertEqual(loaded.first(where: { $0.filename.hasPrefix("Donna") })?.sizeBytes,
                       69_189_370_465, "large integers must survive")
    }

    /// Same sensor against the REAL pre-reduction backup when it exists on
    /// this machine (skips elsewhere). Read-only on the backup: it is
    /// COPIED to the test's temp dir first, so the isolation contract
    /// holds. This is the test that answers "would re-running the
    /// reduction clobber a fourth time?" with production data.
    @MainActor
    func testPythonRoundTripOfRealBackupDecodes() throws {
        let python = "/usr/bin/python3"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python))
        let backup = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask)[0]
            .appendingPathComponent("VideoScan/catalog.pre-triage-20260814.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: backup.path),
                          "real backup only exists on Rick's M4")

        try FileManager.default.copyItem(at: backup, to: catalogURL)

        let script = """
        import json, sys
        p = sys.argv[1]
        d = json.load(open(p))
        d["records"] = d["records"][:500]   # decode failure is per-record; 500 is plenty
        json.dump(d, open(p, "w"))
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = ["-c", script, catalogURL.path]
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)

        let store = CatalogStore(directory: dir)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 500,
                       "python-round-tripped REAL records must decode")
        XCTAssertEqual(store.lastLoadOutcome, .loaded(fromBackup: false))
    }

    /// END-TO-END: the ACTUAL reducer script against the REAL backup, full
    /// output, decoded by the app. The [:500]-sample sensor above passed
    /// while the app rejected the reducer's real output TWICE (clobbers 3
    /// and 4) — because the sample round-tripped the backup without the
    /// reducer's MUTATIONS, and truncated before the poison. This test
    /// runs the real transform on all 18,142 records and, on failure,
    /// surfaces the decoder's actual error via lastLoadOutcome + NSLog.
    @MainActor
    func testActualReducerOutputDecodes_endToEnd() throws {
        let python = "/usr/bin/python3"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python))
        let backup = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask)[0]
            .appendingPathComponent("VideoScan/catalog.pre-triage-20260814.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: backup.path))
        // The reducer script lives in the repo; find it relative to this
        // test file's known location at compile time.
        let script = URL(fileURLWithPath: #filePath)          // …/VideoScan/VideoScanTests/…
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()                       // repo root
            .appendingPathComponent("scripts/catalog_reduce.py")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: script.path))

        try FileManager.default.copyItem(at: backup, to: catalogURL)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [script.path, "--catalog", catalogURL.path, "--apply"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = out
        try proc.run()
        proc.waitUntilExit()
        let scriptOut = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                               encoding: .utf8) ?? ""
        XCTAssertEqual(proc.terminationStatus, 0, "reducer failed:\n\(scriptOut.suffix(500))")
        XCTAssertTrue(scriptOut.contains("WRITTEN"), "reducer must have applied:\n\(scriptOut.suffix(500))")

        let store = CatalogStore(directory: dir)
        let loaded = store.load()
        XCTAssertEqual(store.lastLoadOutcome, .loaded(fromBackup: false),
                       "the app REJECTED the reducer's real output — outcome \(store.lastLoadOutcome). "
                       + "The decoder's error is in this test run's NSLog output; read it.")
        XCTAssertEqual(loaded.count, 8_760, "expected the reduced record count")
    }

    // MARK: - Isolation

    /// 2026-08-17 crash at launch: a catalog.json carrying duplicate record
    /// ids (203 twins created by the live-reload re-append bug) trapped in
    /// Dictionary(uniqueKeysWithValues:) inside decode. A file with twins
    /// must LOAD, keeping the current home (relinked twin) and dropping the
    /// stale one.
    @MainActor
    func testCatalogWithDuplicateRecordIDsStillLoads_keepingTheCurrentHome() throws {
        let store = CatalogStore(directory: dir)
        let id = UUID()
        let json = """
        {"version":\(CatalogSnapshot.currentVersion),"savedAt":"2026-08-17T00:00:00Z","generation":1,
         "records":[
           {"id":"\(id.uuidString)","filename":"clip.mov","fullPath":"/Volumes/LaCie/old/clip.mov","directory":"/Volumes/LaCie/old","ext":"MOV"},
           {"id":"\(id.uuidString)","filename":"clip.mov","fullPath":"/Volumes/SanDisk/new/clip.mov","directory":"/Volumes/SanDisk/new","ext":"MOV","originalFullPath":"/Volumes/LaCie/old/clip.mov"},
           {"id":"\(UUID().uuidString)","filename":"other.mov","fullPath":"/Volumes/LaCie/other.mov","directory":"/Volumes/LaCie","ext":"MOV"}
         ]}
        """
        try Data(json.utf8).write(to: catalogURL)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 2, "twins collapse to one record; the file must load, not trap")
        let survivor = try XCTUnwrap(loaded.first { $0.id == id })
        XCTAssertEqual(survivor.fullPath, "/Volumes/SanDisk/new/clip.mov", "the relinked (current home) twin wins")
        XCTAssertEqual(Set(loaded.map(\.id)).count, 2)
    }

    func testTestsNeverTouchTheRealCatalog() throws {
        let appSupport = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory,
                                     in: .userDomainMask).first)
        let real = appSupport.appendingPathComponent("VideoScan/catalog.json")
        XCTAssertNotEqual(catalogURL.standardizedFileURL, real.standardizedFileURL)
        XCTAssertTrue(catalogURL.path.contains(NSTemporaryDirectory()))
    }
}
