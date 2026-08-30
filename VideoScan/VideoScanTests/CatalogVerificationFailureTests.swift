import Testing
import Foundation
@testable import VideoScan

// MARK: - CatalogVerificationFailureTests
//
// End-to-end coverage for CatalogWriteError.verificationFailed — the
// read-back check that catches truncation, a filesystem that lied about
// durability, and media errors surfacing between write and re-read. Until
// now nothing exercised the path: the only reference to the case in the
// suite constructed it to assert error codes are distinct.
//
// It cannot be induced without a seam. The atomic write is temp-file +
// rename(2), so anything pre-planted at the destination is replaced before
// the verify reads it, and a concurrent external writer would be a race
// rather than a deterministic test. CatalogStore therefore exposes
// `testAfterWriteBeforeVerify`, an internal per-instance @Sendable closure
// run between the fsync and the read-back — the same shape as the existing
// `testBetweenProbeAndDecode` seam. It is additionally gated on
// TestEnvironment.isTestHost, but that is defence in depth rather than a
// boundary: TestEnvironment.detect trusts launch markers, VS_UI_TEST=1
// among them, so a shipped app launched with one would satisfy it. The nil
// default and the absence of any production assignment are the protection.
//
// Isolation: every case injects CatalogStore(directory:), never
// CatalogStore.shared, so nothing here can touch Application Support.

@MainActor
struct CatalogVerificationFailureTests {

    private func scratchDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs_verify_fail_\(UUID().uuidString)", isDirectory: true)
    }

    private func makeRecord(name: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/Test/\(name)"
        return r
    }

    /// Corrupts the just-written file so the read-back hash cannot match.
    /// Appending is enough — the streaming re-read covers the whole file.
    private static let corrupt: @Sendable (URL) -> Void = { url in
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("tamper".utf8))
            try? handle.close()
        }
    }

    /// Counts observer callbacks. `catalogStoreDidWrite` fires only on
    /// success, so on these paths the expected count is always zero.
    private final class WriteCounter: CatalogStoreObserver {
        nonisolated(unsafe) var writes = 0
        func catalogStoreDidWrite(_ store: CatalogStore) { writes += 1 }
    }

    private func waitUntil(_ timeout: TimeInterval = 5,
                           _ cond: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return cond()
    }

    /// The async completion releases CatalogStore's lock on the main actor
    /// AFTER the journal entry lands on the writer queue. Probing the
    /// external lock contract keeps teardown from pulling the scratch
    /// directory out from under that completion.
    private func waitForCatalogLockRelease(at catalogURL: URL,
                                           timeout: TimeInterval = 5) async throws -> Bool {
        let probe = CatalogLock(besideCatalogAt: catalogURL)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch probe.acquire() {
            case .acquired: probe.release(); return true
            case .heldByAnother: try await Task.sleep(nanoseconds: 10_000_000)
            case .unavailable: return false
            }
        }
        return false
    }

    private func verificationEntries(_ catalogURL: URL) -> [CatalogWriteJournal.Entry] {
        CatalogWriteJournal.recent(50, catalogURL: catalogURL)
            .filter { $0.kind == "verificationFailed" }
    }

    // MARK: 1. Synchronous live write

    @Test func syncVerificationFailureReportsJournalsOnceAndReleasesTheLock() async throws {
        let dir = scratchDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalogURL = dir.appendingPathComponent("catalog.json")

        let store = CatalogStore(directory: dir)
        let counter = WriteCounter()
        store.observer = counter
        store.testAfterWriteBeforeVerify = Self.corrupt

        #expect(store.saveNow(records: [makeRecord(name: "a.mov")]) == false,
                "a read-back mismatch must fail the save")
        #expect(store.lastWriteError?.kind == "verificationFailed",
                "got \(String(describing: store.lastWriteError))")
        #expect(counter.writes == 0,
                "catalogStoreDidWrite must not fire for a failed write")

        let entries = verificationEntries(catalogURL)
        #expect(entries.count == 1,
                "exactly one journal entry — encodeAndWrite journals, finishWrite must not double it; saw \(entries.count)")

        // Lock release, probed EXTERNALLY and BEFORE any further save on this
        // store (codex QA of 8b7d446f). CatalogLock is re-entrant for the same
        // process — `if fd >= 0 { return .acquired }` — so a second save on the
        // SAME store sails through a leaked lock and then releases it, making a
        // "next save succeeds" check pass whether or not finishWrite released
        // anything. A separate CatalogLock has its own fd and must win the flock.
        #expect(try await waitForCatalogLockRelease(at: catalogURL),
                "the failed save must release the lock — probed from outside, before any same-store save")

        // Only now the weaker, caller-visible consequence: the store still works.
        store.testAfterWriteBeforeVerify = nil
        #expect(store.saveNow(records: [makeRecord(name: "b.mov")]) == true)
        #expect(store.lastWriteError == nil, "a successful save clears the error")
        #expect(counter.writes == 1, "the successful save notifies exactly once")
    }

    // MARK: 2. Asynchronous live write

    @Test func asyncVerificationFailureReportsAndJournalsOnce() async throws {
        let dir = scratchDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let catalogURL = dir.appendingPathComponent("catalog.json")

        let store = CatalogStore(directory: dir)
        let counter = WriteCounter()
        store.observer = counter
        store.testAfterWriteBeforeVerify = Self.corrupt

        store.saveAsync(records: [makeRecord(name: "a.mov")])

        #expect(await waitUntil { store.lastWriteError != nil },
                "the async failure never reached lastWriteError")
        #expect(store.lastWriteError?.kind == "verificationFailed")
        #expect(counter.writes == 0, "no observer callback for a failed async write")
        #expect(verificationEntries(catalogURL).count == 1)

        // Probe the external lock before teardown so the main-actor
        // completion cannot outlive the scratch directory.
        #expect(try await waitForCatalogLockRelease(at: catalogURL))
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: 3. Precedence

    /// A later attempted-and-failed write must REPLACE an earlier one.
    /// This is the ACROSS-attempts form; the same-attempt form is the case
    /// below. An earlier revision claimed that one was impossible because
    /// lockUnavailable needs an unwritable directory — that was wrong, and
    /// the correction is documented there.
    @Test func aLaterWriteFailureReplacesAnEarlierVerificationFailure() throws {
        let dir = scratchDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalogURL = dir.appendingPathComponent("catalog.json")

        let store = CatalogStore(directory: dir)
        store.testAfterWriteBeforeVerify = Self.corrupt
        #expect(store.saveNow(records: []) == false)
        #expect(store.lastWriteError?.kind == "verificationFailed")

        // Now make the write itself impossible: catalog.json as a directory
        // fails the atomic write with EISDIR, long before any verification.
        store.testAfterWriteBeforeVerify = nil
        try FileManager.default.removeItem(at: catalogURL)
        try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: true)

        #expect(store.saveNow(records: []) == false)
        #expect(store.lastWriteError?.kind == "writeFailed",
                "the current failure must outrank the stale verificationFailed, got \(String(describing: store.lastWriteError))")
    }

    // MARK: 4. Snapshot verification

    /// A snapshot mismatch keeps its documented journal behavior — the
    /// verification branch journals for BOTH purposes, unlike ordinary I/O
    /// failure — while leaving the live catalog's lastWriteError alone.
    @Test func snapshotVerificationFailureJournalsBesideTheSnapshotOnly() throws {
        let dir = scratchDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A SUBDIRECTORY, so the snapshot's journal file is a different file
        // from the catalog's and the two assertions cannot be confused.
        let snapDir = dir.appendingPathComponent("snaps", isDirectory: true)
        try FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
        let snapPath = snapDir.appendingPathComponent("catalog.pre-test.2026.json")

        let store = CatalogStore(directory: dir)
        store.testAfterWriteBeforeVerify = Self.corrupt

        #expect(store.writeSnapshot(records: [makeRecord(name: "c.mov")],
                                    toPath: snapPath.path) == false)
        #expect(store.lastWriteError == nil,
                "a snapshot failure must not be reported as a live catalog write error")

        #expect(verificationEntries(snapPath).count == 1,
                "the verification branch journals for snapshots too — beside the snapshot")
        let catalogJournal = CatalogWriteJournal.journalURL(
            besideCatalogAt: dir.appendingPathComponent("catalog.json"))
        #expect(FileManager.default.fileExists(atPath: catalogJournal.path) == false,
                "nothing may be journalled beside the live catalog for a snapshot failure")
    }

    // MARK: 3b. Same-attempt precedence

    /// The precedence case that actually matters: an advisory
    /// lockUnavailable recorded by writePrecondition, then superseded by a
    /// verification failure inside the SAME save.
    ///
    /// Make only the LOCK path unopenable — catalog.lock as a DIRECTORY
    /// fails open(2) with EISDIR while the parent stays writable — so the
    /// lock fails open, the catalog write itself succeeds, and the seam then
    /// corrupts the file. An earlier revision of this file claimed this was
    /// impossible because lockUnavailable required an unwritable directory.
    /// That was wrong: only the lock file has to be unopenable.
    ///
    /// The journal keeps it non-vacuous — both errors must appear, proving
    /// lockUnavailable really was recorded before verificationFailed
    /// replaced it in lastWriteError.
    @Test func verificationFailureSupersedesAdvisoryLockUnavailableInTheSameSave() throws {
        let dir = scratchDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalogURL = dir.appendingPathComponent("catalog.json")

        try FileManager.default.createDirectory(at: dir.appendingPathComponent("catalog.lock"),
                                                withIntermediateDirectories: true)

        let store = CatalogStore(directory: dir)
        store.testAfterWriteBeforeVerify = Self.corrupt

        #expect(store.saveNow(records: [makeRecord(name: "a.mov")]) == false)
        #expect(store.lastWriteError?.kind == "verificationFailed",
                "verification must supersede the advisory lockUnavailable, got \(String(describing: store.lastWriteError))")

        // Exact contents, newest first — not `contains`. The ORDER is the
        // evidence: the advisory refusal is recorded first and the
        // verification failure after it, within one save. A containment
        // check would also pass if the two arrived the other way round, or
        // if either were duplicated.
        let kinds = CatalogWriteJournal.recent(50, catalogURL: catalogURL).map(\.kind)
        #expect(kinds == ["verificationFailed", "lockUnavailable"],
                "journal must be exactly [verificationFailed, lockUnavailable] newest-first; saw \(kinds)")
    }

    /// Negative control for the case above: same unopenable lock, no seam.
    /// lockUnavailable is deliberately FAIL-OPEN, so the save must succeed.
    @Test func anUnopenableLockAloneStillLetsTheSaveSucceed() throws {
        let dir = scratchDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(at: dir.appendingPathComponent("catalog.lock"),
                                                withIntermediateDirectories: true)
        let store = CatalogStore(directory: dir)

        #expect(store.saveNow(records: [makeRecord(name: "a.mov")]) == true,
                "lockUnavailable is fail-open — the save must still land")
        #expect(store.lastWriteError == nil, "a successful save clears the advisory error")
    }

    // MARK: 4b. Asynchronous snapshot

    /// writeSnapshotAsync must carry the seam and behave like writeSnapshot.
    /// codex QA: deleting the seam propagation at the Task.detached call site
    /// left every other case green, so this path had no sensor at all.
    @Test func asyncSnapshotVerificationFailureJournalsBesideTheSnapshotOnly() async throws {
        let dir = scratchDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let snapDir = dir.appendingPathComponent("snaps", isDirectory: true)
        try FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
        let snapPath = snapDir.appendingPathComponent("catalog.pre-test.async.json")

        let store = CatalogStore(directory: dir)
        let counter = WriteCounter()
        store.observer = counter
        store.testAfterWriteBeforeVerify = Self.corrupt

        let ok = await store.writeSnapshotAsync(records: [makeRecord(name: "d.mov")],
                                                toPath: snapPath.path)
        #expect(ok == false, "a corrupted async snapshot must fail verification")
        #expect(counter.writes == 0,
                "a snapshot never notifies the observer — that callback belongs to catalog.json writes")
        #expect(store.lastWriteError == nil,
                "an async snapshot failure must not touch the live catalog error")
        #expect(verificationEntries(snapPath).count == 1,
                "one verification entry beside the snapshot")
        let catalogJournal = CatalogWriteJournal.journalURL(
            besideCatalogAt: dir.appendingPathComponent("catalog.json"))
        #expect(FileManager.default.fileExists(atPath: catalogJournal.path) == false,
                "nothing beside the live catalog")
    }

    // MARK: 5. Negative control for the seam itself

    /// With the seam nil the same flow verifies clean and succeeds. Without
    /// this, every case above could be passing because the seam fires
    /// unconditionally rather than because the verification works.
    @Test func withoutTheSeamTheSameFlowVerifiesAndSucceeds() throws {
        let dir = scratchDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalogURL = dir.appendingPathComponent("catalog.json")

        let store = CatalogStore(directory: dir)
        let counter = WriteCounter()
        store.observer = counter
        #expect(store.testAfterWriteBeforeVerify == nil, "the seam must default to nil")

        #expect(store.saveNow(records: [makeRecord(name: "a.mov")]) == true)
        #expect(store.lastWriteError == nil)
        #expect(counter.writes == 1)
        #expect(verificationEntries(catalogURL).isEmpty,
                "a clean write must journal nothing")
        #expect(FileManager.default.fileExists(atPath: catalogURL.path))
    }
}
