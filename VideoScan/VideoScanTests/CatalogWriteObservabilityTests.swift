import Testing
import Foundation
@testable import VideoScan

// MARK: - CatalogWriteObservabilityTests
//
// Pins how a FAILED catalog write reports itself. Triaged 2026-08-29 while
// chasing EPERM noise in the nightly log; the noise turned out to be
// deliberate negative tests, but it exposed two real defects in the shared
// writer (CatalogStore.encodeAndWrite):
//
//   1. A live catalog.json failure was logged with the words "failed to
//      save catalog snapshot" — the same text as a recovery-copy failure.
//      A reader cannot tell "the catalog did not persist" from "a safety
//      net was skipped", and the wording understates the worse of the two.
//
//   2. Ordinary I/O failure (ENOSPC, EIO, EPERM) never reached
//      CatalogWriteJournal. The journal recorded lock refusals, viewer-mode
//      refusals and checksum mismatches, so the one failure class it could
//      not see was the most common one — and that journal exists because of
//      the #167 clobber.
//
// `lastWriteError` was already being set via finishWrite, so what changed
// there is fidelity, not presence: it now carries the underlying error
// instead of the fixed string "encode or atomic write failed".
//
// Failure is induced by making the destination PATH A DIRECTORY. That fails
// the atomic write with EISDIR while leaving the parent writable — which
// matters, because the journal is written into that same parent. An
// unwritable-parent simulation (the shape other tests use) cannot assert
// journalling at all: the journal append fails for the same reason the
// catalog write did.
//
// Isolation: every case injects CatalogStore(directory:), never
// CatalogStore.shared, so nothing here can touch Application Support.

@MainActor
struct CatalogWriteObservabilityTests {

    private func scratchDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs_write_obs_\(UUID().uuidString)", isDirectory: true)
    }

    private func makeRecord(name: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/Test/\(name)"
        return r
    }

    /// A live catalog.json write that fails must (a) journal, and (b) leave
    /// `lastWriteError` carrying the real cause — not a fixed placeholder.
    ///
    /// This is the SENSOR for defect 2: a non-empty journal after a failed
    /// live save is the property that regressed silently before.
    @Test func liveWriteFailureJournalsAndCarriesTheRealCause() throws {
        let dir = scratchDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // catalog.json as a directory: the atomic write fails, the parent
        // stays writable so the journal beside it can still be appended.
        let catalogURL = dir.appendingPathComponent("catalog.json")
        try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: true)

        let store = CatalogStore(directory: dir)
        let ok = store.saveNow(records: [makeRecord(name: "a.mov")])

        #expect(ok == false, "writing over a directory must fail")
        #expect(store.lastWriteError?.kind == "writeFailed",
                "an I/O failure must be attributed to writeFailed, got \(String(describing: store.lastWriteError))")

        // Fidelity: the underlying error must survive into the error value,
        // not be flattened to the old fixed string.
        if case .writeFailed(let detail)? = store.lastWriteError {
            #expect(detail != "encode or atomic write failed",
                    "the real cause must replace the placeholder detail")
            #expect(detail.isEmpty == false)
        } else {
            Issue.record("expected .writeFailed, got \(String(describing: store.lastWriteError))")
        }

        let entries = CatalogWriteJournal.recent(50, catalogURL: catalogURL)
        #expect(entries.isEmpty == false,
                "a failed LIVE catalog write must leave a journal entry — this is the #167 audit trail")
        #expect(entries.contains { $0.kind == "writeFailed" },
                "journal must attribute the failure to writeFailed, got \(entries.map(\.kind))")
    }

    /// A failed SNAPSHOT write is diagnosed but not journalled, and must not
    /// masquerade as a live-catalog failure by touching `lastWriteError`.
    /// The journal lives beside catalog.json; a snapshot may be written
    /// anywhere, so journalling it would scatter audit files.
    @Test func snapshotWriteFailureIsDistinctAndNotJournalled() throws {
        let dir = scratchDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CatalogStore(directory: dir)

        // Same induced failure, applied to a snapshot destination.
        let snapPath = dir.appendingPathComponent("catalog.pre-test.2026.json")
        try FileManager.default.createDirectory(at: snapPath, withIntermediateDirectories: true)

        let ok = store.writeSnapshot(records: [makeRecord(name: "b.mov")], toPath: snapPath.path)

        #expect(ok == false, "writing a snapshot over a directory must fail")
        #expect(store.lastWriteError == nil,
                "a snapshot failure must NOT be reported as a catalog write error — callers degrade on the nil return instead")

        let journal = CatalogWriteJournal.journalURL(besideCatalogAt: dir.appendingPathComponent("catalog.json"))
        #expect(FileManager.default.fileExists(atPath: journal.path) == false,
                "snapshot failures must not write a journal entry")
    }

    /// The two purposes must stay distinguishable even when they fail in the
    /// same directory in the same test — the exact confusion that made the
    /// nightly log unreadable.
    @Test func liveAndSnapshotFailuresRemainDistinguishable() throws {
        let dir = scratchDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CatalogStore(directory: dir)

        // Snapshot fails first: no journal, no lastWriteError.
        let snapPath = dir.appendingPathComponent("catalog.pre-test.2026.json")
        try FileManager.default.createDirectory(at: snapPath, withIntermediateDirectories: true)
        #expect(store.writeSnapshot(records: [], toPath: snapPath.path) == false)
        #expect(store.lastWriteError == nil)

        let catalogURL = dir.appendingPathComponent("catalog.json")
        #expect(FileManager.default.fileExists(atPath: CatalogWriteJournal.journalURL(besideCatalogAt: catalogURL).path) == false,
                "the snapshot failure must not have opened the journal")

        // Now the live write fails: journal appears, error is attributed.
        try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: true)
        #expect(store.saveNow(records: []) == false)
        #expect(store.lastWriteError?.kind == "writeFailed")
        #expect(CatalogWriteJournal.recent(50, catalogURL: catalogURL).contains { $0.kind == "writeFailed" })
    }

    // MARK: - Precedence (codex QA of 4fc11741)

    /// Wait for `cond` or give up. `saveInFlight` is private, so the async
    /// paths are observed through `lastWriteError` and the journal — which
    /// is the right level anyway: these are the properties callers see.
    private func waitUntil(_ timeout: TimeInterval = 5,
                           _ cond: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return cond()
    }

    /// SENSOR for the precedence rule: when the lock cannot be created AND
    /// the write then fails, the reported error must be the write failure.
    ///
    /// This is reachable in one ordinary flow, not a contrived one. An
    /// unwritable catalog directory makes CatalogLock.acquire() return
    /// .unavailable, which is deliberately FAIL-OPEN: writePrecondition
    /// records lockUnavailable and proceeds with the write anyway. The write
    /// then fails for the same reason. Before this fix the user was told
    /// "Could not obtain the catalog lock" and the worse, truer fact — the
    /// catalog did not persist — was silently dropped.
    @Test func lockUnavailableThenWriteFailureReportsTheWriteFailure() throws {
        let dir = scratchDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }

        let store = CatalogStore(directory: dir)
        // r-x: catalog.lock cannot be created, and neither can catalog.json.
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: dir.path)

        #expect(store.saveNow(records: [makeRecord(name: "a.mov")]) == false)
        #expect(store.lastWriteError?.kind == "writeFailed",
                "an attempted write that failed must outrank the advisory lockUnavailable, got \(String(describing: store.lastWriteError))")
    }

    // MARK: - Async paths

    /// The async live path must propagate the failure exactly as the
    /// synchronous one does — and must do so with NO observer attached.
    /// `catalogStoreDidWrite` only fires on success, so a test that waits on
    /// an observer would hang here; that asymmetry is why this case needs
    /// its own sensor.
    @Test func asyncLiveWriteFailurePropagatesWithNoObserver() async throws {
        let dir = scratchDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let catalogURL = dir.appendingPathComponent("catalog.json")
        try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: true)

        let store = CatalogStore(directory: dir)
        #expect(store.observer == nil, "this case deliberately runs without an observer")

        store.saveAsync(records: [makeRecord(name: "a.mov")])

        let landed = await waitUntil { store.lastWriteError != nil }
        #expect(landed, "the async failure never reached lastWriteError")
        #expect(store.lastWriteError?.kind == "writeFailed")
        #expect(CatalogWriteJournal.recent(50, catalogURL: catalogURL)
                    .contains { $0.kind == "writeFailed" },
                "the async live path must journal like the sync one")
    }

    /// A save coalesced behind an in-flight one still runs, and still
    /// reports. Two failing async saves must therefore leave TWO journal
    /// entries — if the follow-up were dropped, only one would appear.
    @Test func asyncCoalescedFollowUpAlsoReportsItsFailure() async throws {
        let dir = scratchDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let catalogURL = dir.appendingPathComponent("catalog.json")
        try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: true)

        let store = CatalogStore(directory: dir)
        store.testWriteDelay = 0.2   // hold the first write open long enough to coalesce behind it

        store.saveAsync(records: [makeRecord(name: "first.mov")])
        store.saveAsync(records: [makeRecord(name: "second.mov")])   // coalesces

        let both = await waitUntil(10) {
            CatalogWriteJournal.recent(50, catalogURL: catalogURL)
                .filter { $0.kind == "writeFailed" }.count >= 2
        }
        #expect(both,
                "the coalesced follow-up save must run and report; saw \(CatalogWriteJournal.recent(50, catalogURL: catalogURL).filter { $0.kind == "writeFailed" }.count) journal entries")
    }

    /// writeSnapshotAsync must match writeSnapshot: no journal, and
    /// `lastWriteError` untouched. A snapshot failure is not a catalog
    /// write failure whichever thread it happens on.
    @Test func asyncSnapshotFailureIsNotJournalledAndLeavesLastWriteErrorAlone() async throws {
        let dir = scratchDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CatalogStore(directory: dir)
        let snapPath = dir.appendingPathComponent("catalog.pre-test.2026.json")
        try FileManager.default.createDirectory(at: snapPath, withIntermediateDirectories: true)

        let ok = await store.writeSnapshotAsync(records: [makeRecord(name: "c.mov")],
                                                toPath: snapPath.path)

        #expect(ok == false)
        #expect(store.lastWriteError == nil,
                "an async snapshot failure must not be reported as a catalog write error")
        let journal = CatalogWriteJournal.journalURL(besideCatalogAt: dir.appendingPathComponent("catalog.json"))
        #expect(FileManager.default.fileExists(atPath: journal.path) == false,
                "async snapshot failures must not write a journal entry")
    }
}
