// JunkFrozenSnapshotTests.swift
// 🔴 fix 2 + design R1 (codex design review F1, 2026-10-09): Delete Junk
// acts on EXACTLY the set its confirmation counted. The set is frozen when
// the confirmation opens — record, path, file identity, size — and Move to
// Trash executes only that snapshot. At each file's turn it re-checks:
// still Confirmed Junk, still the same catalog record at the same path,
// still the same file on disk, reachable, not protected. Any change is a
// named HOLD; nothing ever acts on whatever now sits at a counted path.
//
// Before the fix, JunkDeleteAction re-queried ALL confirmed junk when the
// button was pressed, so a file marked after the sheet opened was moved,
// and a file replaced at a counted path was moved.
//
// Files are tiny synthetic blobs in a temp sandbox; the Trash is the
// routine's `remove` seam (SandboxTrash) — nothing reaches the real Trash.

import Foundation
import Testing
@testable import VideoScan

@Suite("Delete Junk — the frozen snapshot is the only set acted on", .serialized)
@MainActor
struct JunkFrozenSnapshotTests {

    private func trashed(_ sb: JunkTrashSandbox) -> Set<String> { Set(sb.trash.attempts) }

    @Test("a file marked Confirmed AFTER the sheet opened is never moved; count shown == set acted on")
    func neverWidens() async throws {
        let sb = try JunkTrashSandbox("widen"); defer { sb.cleanup() }
        let model = sb.model()
        let a = sb.junk(try sb.write("test_a.mov")), b = sb.junk(try sb.write("test_b.mov"))
        let late = sb.junk(try sb.write("test_late.mov"))
        late.mediaDisposition = .unreviewed
        model.records = [a, b, late]

        let snapshot = await model.freezeJunkSnapshot([a, b], isOffline: { _ in false })
        #expect(snapshot.count == 2 && snapshot.moveCount == 2)
        late.mediaDisposition = .confirmedJunk           // marked after the sheet opened

        let result = await model.trashFrozenJunk(snapshot, fileOperation: sb.trash.operation)
        #expect(trashed(sb) == [a.fullPath, b.fullPath], "moved ⊆ the frozen set: \(sb.trash.attempts)")
        #expect(FileManager.default.fileExists(atPath: late.fullPath) && late.purgedAt == nil)
        #expect(result.attempted == snapshot.count, "the set acted on is the set the sheet counted")
        #expect(result.succeeded == 2)
    }

    @Test("a file no longer marked Confirmed Junk at its turn is held, named")
    func revokedMarkHolds() async throws {
        let sb = try JunkTrashSandbox("revoked"); defer { sb.cleanup() }
        let model = sb.model()
        let a = sb.junk(try sb.write("test_a.mov")), b = sb.junk(try sb.write("test_b.mov"))
        model.records = [a, b]
        let snapshot = await model.freezeJunkSnapshot([a, b], isOffline: { _ in false })
        a.mediaDisposition = .important

        let result = await model.trashFrozenJunk(snapshot, fileOperation: sb.trash.operation)
        #expect(trashed(sb) == [b.fullPath])
        #expect(FileManager.default.fileExists(atPath: a.fullPath) && a.purgedAt == nil)
        #expect(result.refused.count == 1 && result.refused.first?.record === a)
        #expect(result.refused.first?.reason.contains("no longer marked Confirmed Junk") == true, "\(result.refused.map(\.reason))")
    }

    @Test("a file REPLACED at a counted path is held — never the new occupant")
    func replacedFileHolds() async throws {
        let sb = try JunkTrashSandbox("replaced"); defer { sb.cleanup() }
        let model = sb.model()
        let url = try sb.write("test_a.mov", bytes: 2_048, fill: 1)
        let a = sb.junk(url)
        model.records = [a]
        let snapshot = await model.freezeJunkSnapshot([a], isOffline: { _ in false })
        // Something else now sits at the counted path (same size, new inode).
        try FileManager.default.removeItem(at: url)
        try Data(repeating: 2, count: 2_048).write(to: url)

        let result = await model.trashFrozenJunk(snapshot, fileOperation: sb.trash.operation)
        #expect(sb.trash.attempts.isEmpty, "the new occupant of a counted path was handed to the Trash")
        #expect(FileManager.default.fileExists(atPath: url.path) && a.purgedAt == nil)
        #expect(result.refused.first?.reason.contains("not the file you confirmed") == true, "\(result.refused.map(\.reason))")
    }

    @Test("a file CHANGED since the confirmation (size / mtime) is held")
    func changedFileHolds() async throws {
        let sb = try JunkTrashSandbox("changed"); defer { sb.cleanup() }
        let model = sb.model()
        let url = try sb.write("test_a.mov", bytes: 1_024)
        let a = sb.junk(url)
        model.records = [a]
        let snapshot = await model.freezeJunkSnapshot([a], isOffline: { _ in false })
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 7, count: 100))
        try handle.close()

        let result = await model.trashFrozenJunk(snapshot, fileOperation: sb.trash.operation)
        #expect(sb.trash.attempts.isEmpty)
        #expect(result.refused.count == 1 && a.purgedAt == nil)
    }

    @Test("a record removed from the catalog, or re-pointed at another path, is held")
    func catalogChangesHold() async throws {
        let sb = try JunkTrashSandbox("catalog"); defer { sb.cleanup() }
        let model = sb.model()
        let a = sb.junk(try sb.write("test_a.mov")), b = sb.junk(try sb.write("test_b.mov"))
        let other = try sb.write("test_other.mov")
        model.records = [a, b]
        let snapshot = await model.freezeJunkSnapshot([a, b], isOffline: { _ in false })
        model.records = [b]                               // a left the catalog
        b.fullPath = other.path                           // b now points elsewhere

        let result = await model.trashFrozenJunk(snapshot, fileOperation: sb.trash.operation)
        #expect(sb.trash.attempts.isEmpty, "\(sb.trash.attempts)")
        let reasons = result.refused.map(\.reason)
        #expect(reasons.contains { $0.contains("no longer in the catalog") }, "\(reasons)")
        #expect(reasons.contains { $0.contains("moved in the catalog") }, "\(reasons)")
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    /// Poisoned state (isolation): the snapshot's view of the world is
    /// stale — the drive was "offline" when frozen and is reachable now.
    /// What the confirmation did not count as moving never moves.
    @Test("isolation: a file offline when frozen is never moved later, even when it is reachable")
    func offlineWhenFrozenNeverMoves() async throws {
        let sb = try JunkTrashSandbox("offline"); defer { sb.cleanup() }
        let model = sb.model()
        let a = sb.junk(try sb.write("test_a.mov"))
        model.records = [a]
        let snapshot = await model.freezeJunkSnapshot([a], isOffline: { _ in true })
        #expect(snapshot.moveCount == 0 && snapshot.offlineCount == 1)

        let result = await model.trashFrozenJunk(snapshot, fileOperation: sb.trash.operation)
        #expect(sb.trash.attempts.isEmpty)
        #expect(FileManager.default.fileExists(atPath: a.fullPath) && a.purgedAt == nil)
        #expect(result.refused.first?.reason.contains("wasn't connected when you confirmed") == true, "\(result.refused.map(\.reason))")
    }

    @Test("a counted file that vanished before its turn is 'already missing' (catalog updated), not moved")
    func vanishedIsMissing() async throws {
        let sb = try JunkTrashSandbox("vanished"); defer { sb.cleanup() }
        let model = sb.model()
        let url = try sb.write("test_a.mov")
        let a = sb.junk(url)
        model.records = [a]
        let snapshot = await model.freezeJunkSnapshot([a], isOffline: { _ in false })
        try FileManager.default.removeItem(at: url)

        let result = await model.trashFrozenJunk(snapshot, fileOperation: sb.trash.operation)
        #expect(sb.trash.attempts.isEmpty)
        #expect(result.alreadyMissing == 1 && result.refused.isEmpty && a.purgedAt != nil)
    }

    @Test("the snapshot freezes path, identity and measured size; the sheet's numbers come from it")
    func snapshotFreezesIdentityAndSize() async throws {
        let sb = try JunkTrashSandbox("freeze"); defer { sb.cleanup() }
        let model = sb.model()
        let a = sb.junk(try sb.write("test_a.mov", bytes: 3_000))
        a.sizeBytes = 999_999                              // the catalog's number is stale
        let b = sb.junk(try sb.write("test_b.mov", bytes: 5_000))
        model.records = [a, b]
        let snapshot = await model.freezeJunkSnapshot([a, b, a], isOffline: { _ in false })
        #expect(snapshot.count == 2, "a record listed twice is counted once")
        #expect(snapshot.items.map(\.path) == [a.fullPath, b.fullPath])
        #expect(snapshot.items.allSatisfy { $0.identity != nil })
        #expect(snapshot.moveBytes == 8_000, "measured sizes, not the catalog's: \(snapshot.moveBytes)")
    }

    // MARK: Invariants: the gates still fire on this path

    @Test("invariant: a Master Archive file is shown held back and never moved")
    func masterArchiveNeverMoves() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("junkfrozen_archive"); defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let inArchive = try MasterArchiveTestSupport.writeBlob(at: sb.archiveRoot.appendingPathComponent("test_kept.mov"), bytes: 512, seed: 1)
        let onVolume = try MasterArchiveTestSupport.writeBlob(at: sb.archiveVolume.appendingPathComponent("test_loose.mov"), bytes: 512, seed: 2)
        let recs = [inArchive, onVolume].map { url -> VideoRecord in
            let r = MasterArchiveTestSupport.makeRecord(path: url.path)
            r.mediaDisposition = .confirmedJunk
            return r
        }
        model.records = recs
        let trash = SandboxTrash(dir: sb.root)
        let snapshot = await model.freezeJunkSnapshot(recs, isOffline: { _ in false })
        #expect(snapshot.moveCount == 0 && snapshot.heldCount == 2, "\(snapshot.heldGroups)")

        let result = await model.trashFrozenJunk(snapshot, fileOperation: trash.operation)
        #expect(trash.attempts.isEmpty)
        #expect(FileManager.default.fileExists(atPath: inArchive.path) && FileManager.default.fileExists(atPath: onVolume.path))
        #expect(recs.allSatisfy { $0.purgedAt == nil })
        #expect(result.succeeded == 0)
    }

    @Test("invariant: a drive marked Read only AFTER the confirmation protects its files at their turn")
    func readOnlyMarkedLaterHolds() async throws {
        let sb = try JunkTrashSandbox("readonly"); defer { sb.cleanup() }
        let model = sb.model()
        let target = junkTrashScanTarget(sb.files.path)
        model.scanTargets = [target]
        let a = sb.junk(try sb.write("test_a.mov"))
        model.records = [a]
        let snapshot = await model.freezeJunkSnapshot([a], isOffline: { _ in false })
        #expect(snapshot.moveCount == 1)
        model.setVolumeReadOnly(true, for: target)

        let result = await model.trashFrozenJunk(snapshot, fileOperation: sb.trash.operation)
        #expect(sb.trash.attempts.isEmpty)
        #expect(FileManager.default.fileExists(atPath: a.fullPath) && a.purgedAt == nil)
        #expect(result.succeeded == 0, "\(result)")
    }

    @Test("invariant: a viewer Mac moves nothing")
    func viewerMovesNothing() async throws {
        let sb = try JunkTrashSandbox("viewer"); defer { sb.cleanup() }
        let model = sb.model()
        let a = sb.junk(try sb.write("test_a.mov"))
        model.records = [a]
        let snapshot = await model.freezeJunkSnapshot([a], isOffline: { _ in false })
        model.isReadOnly = true

        let result = await model.trashFrozenJunk(snapshot, fileOperation: sb.trash.operation)
        #expect(sb.trash.attempts.isEmpty && a.purgedAt == nil)
        #expect(result.refused.count == 1 && result.refused.first?.reason.contains("read-only viewer") == true)
    }
}

/// Per-file freshness of the routine's own guard (codex design F1): the
/// caller's `authorize` is asked at EACH file's turn — after the previous
/// file's disk operation — never once for the whole batch up front.
@Suite("Trash routine — authorization is fresh per file", .serialized)
@MainActor
struct JunkPerFileAuthorizationTests {

    @Test("authorize(file 2) runs after file 1 has gone; a change made then holds file 2")
    func authorizeIsPerFile() async throws {
        let sb = try JunkTrashSandbox("perfile"); defer { sb.cleanup() }
        let model = sb.model()
        let a = sb.junk(try sb.write("test_a.mov")), b = sb.junk(try sb.write("test_b.mov"))
        model.records = [a, b]
        let order = OrderLog()
        let trash = sb.trash.operation
        let unmarked = DispatchSemaphore(value: 0)
        let fileGuard = VideoScanModel.JunkDeletionGuard(
            authorize: { rec in
                order.add("authorize \(rec.filename)")
                return rec.mediaDisposition == .confirmedJunk ? nil : "no longer junk"
            },
            beforeRemoval: { _ in nil },
            remove: { url in
                order.add("remove \(url.lastPathComponent)")
                // File 1's move waits (off-main) until the person has
                // un-marked file 2 — deterministic, no timing race.
                if url.lastPathComponent == "test_a.mov" { unmarked.wait() }
                try trash(url)
            })
        let run = Task { @MainActor in await model.deleteConfirmedJunk([a, b], mode: .toTrash, guard: fileGuard) }
        // While file 1 is being moved, the person un-marks file 2.
        let deadline = ContinuousClock.now + .seconds(20)
        while !order.entries.contains("remove test_a.mov"), ContinuousClock.now < deadline { await Task.yield() }
        b.mediaDisposition = .unreviewed
        unmarked.signal()
        let result = await run.value
        #expect(order.entries.prefix(3) == ["authorize test_a.mov", "remove test_a.mov", "authorize test_b.mov"],
                "the second file was authorized before the first file's turn ended: \(order.entries)")
        #expect(result.succeeded == 1 && result.refused.map(\.reason) == ["no longer junk"], "\(result)")
        #expect(FileManager.default.fileExists(atPath: b.fullPath))
    }
}

/// Thread-safe ordered log.
final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ s: String) { lock.withLock { stored.append(s) } }
    var entries: [String] { lock.withLock { stored } }
}

/// Scale (CLAUDE.md dimension 2): freezing is O(n) on main plus one stat
/// per movable file off-main. 100k synthetic Confirmed Junk records whose
/// files do not exist (stat fails fast) must freeze inside the budget, and
/// the sheet's numbers must come out of the snapshot already summed.
@Suite("Delete Junk — freezing 100k records stays inside its budget", .serialized)
@MainActor
struct JunkSnapshotScaleTests {

    @Test("100k records freeze in under 2 s; counts and bytes are pre-summed")
    func hundredThousandFreezeInBudget() async throws {
        let model = VideoScanModel()
        let base = NSTemporaryDirectory() + "test_junkscale_\(UUID().uuidString.prefix(8))/"
        var recs: [VideoRecord] = []
        recs.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.fullPath = base + "test_\(i).mov"
            r.filename = "test_\(i).mov"
            r.mediaDisposition = .confirmedJunk
            r.sizeBytes = 10
            recs.append(r)
        }
        model.records = recs
        let clock = ContinuousClock()
        let start = clock.now
        let snapshot = await model.freezeJunkSnapshot(recs, isOffline: { $0.filename.hasSuffix("7.mov") })
        let elapsed = clock.now - start
        #expect(elapsed < .seconds(2), "freezing 100k records took \(elapsed) (0.45 s measured in Debug on the M4, 2026-10-09)")
        #expect(snapshot.count == 100_000)
        #expect(snapshot.offlineCount == 10_000 && snapshot.moveCount == 90_000)
        #expect(snapshot.moveBytes == 900_000, "catalog sizes stand in for files that could not be stat'ed")
        #expect(snapshot.items.allSatisfy { $0.identity == nil })
    }
}
