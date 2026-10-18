// CatalogCutoverRegressionTests.swift
// The INDEPENDENT regression net for the catalog.json → catalog.sqlite flip
// (docs/briefs/cloud/CUTOVER_REGRESSION.md; design docs/design/
// catalog_cutover_f_prime_2026_10_17.md §3, §7, §10). Ten scenarios a person
// actually does in the first week after the flip, each through the model's
// own calls (the funnels the UI calls, the one removal-marker writer, the
// Promote catalog step, the purge door, the quit path, the Switch and Adopt
// doors), each ending quit → relaunch on catalog.sqlite → assert that nothing
// was lost and nothing was invented.
//   LOGIC     curated edits, copies of one content, Trash / Undo / emptied,
//             a new row without a whole-file hash, a purge, a promotion, the
//             Switch, a restore + Adopt;
//   SCALE     a 2,000-row catalog with 50 seeded edits across 10 save
//             windows: exactly those 50 changes, every other row's DTO equal;
//   ISOLATION a MOPS-16 hold (the commit waits; the quit path still saves);
//             a catalog.sqlite restored below the high-water opens read-only;
//   SENSOR    every scenario compares the DTO of every record it did not
//             edit, before and after the relaunch;
//   MEDIA     N/A — no media is opened.
// Reuses the existing harness (CutoverScene + the B2/B2.1 helpers); every case
// runs in a sandbox folder, never Application Support.
//
// Written in a Linux cloud session without a compiler (2026-10-18); compiled
// and run on the Mac against B2.2 (f3900b36f). Three scenarios carry a
// `withKnownIssue` whose words name the pinned cause (file:line) — each is a
// FINDING on real behaviour, not a test to relax: the later of two edits to
// copies of one content loses (scenario 2), an Undo of a committed Trash is
// refused by the store (scenario 3), and the purge doors are dead after the
// flip (scenario 5). When the code is fixed the known issue stops recording
// and the test fails until the marker is removed.
// (Swift Testing: `withKnownIssue { … }` ≈ a gtest EXPECT that is expected to
// fail — it still runs every check, reports them as "known", and FAILS the
// test if nothing inside fails any more.)
//
// Suites (filter by SUITE): CutoverFirstWeekEditsTests · CutoverRemovalTests ·
// CutoverNewRowTests · CutoverArchiveTests · CutoverHoldTests ·
// CutoverSwitchRestoreTests · CutoverManyEditsTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - Scene helpers (on top of CutoverScene and its B2 / B2.1 extensions)

@MainActor
extension CutoverScene {

    /// The poisoned fixture plus `healthyRows` bulk rows (distinct ids, paths
    /// and digests, all `present`), written over the scene's catalog folder.
    static func make(_ label: String, healthyRows: Int) throws -> CutoverScene {
        let scene = try CutoverScene.make(label)
        for (name, data) in PoisonedCatalogFixture(healthyRows: healthyRows).files {
            try data.write(to: scene.folder.appendingPathComponent(name), options: .atomic)
        }
        return scene
    }

    /// The live record with `id` in the model.
    func live(_ id: UUID) throws -> VideoRecord {
        try #require(model.records.first { $0.id == id })
    }

    /// Bulk row `n` of the fixture, as the model holds it.
    func bulk(_ n: Int) throws -> VideoRecord {
        try #require(model.records.first { $0.id.uuidString == PoisonedCatalogFixture.bulkID(n) })
    }

    /// Quit: the committer's store is closed, as at quit (no relaunch yet).
    func closeStore() async {
        if let committer = model.catalogCutover.committer { await committer.repository.close() }
    }

    /// The revisions of a row's tombstones, read through the seam.
    func storedTombstoneRevisions(id: UUID) async throws -> [Int] {
        let repository = GRDBCatalogRepository(host: "cutover-test")
        _ = await repository.open(at: databaseURL)
        do {
            let revisions = try await repository.read { try $0.tombstoneRevisions(fileID: id.uuidString) }
            await repository.close()
            return revisions
        } catch {
            await repository.close()
            throw error
        }
    }

    /// A sealed copy of the (closed) catalog.sqlite — `VACUUM INTO`, the
    /// backup shape the store's own tests use — made by the system sqlite3,
    /// so the app target needs no SQLite import.
    func vacuumInto(_ target: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databaseURL.path, "VACUUM INTO '\(target.path)'"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CutoverFailure(words: "sqlite3 VACUUM INTO exited \(process.terminationStatus)")
        }
    }
}

/// The DTO comparisons every scenario ends with.
enum CutoverRegression {

    /// A record's DTO with what the contract does not keep set aside.
    @MainActor
    static func dto(_ record: VideoRecord) throws -> CatalogRecordDTO {
        CutoverKept.normalized(try CatalogRecordDTO(record: record, migrationLoadedAt: 0))
    }

    @MainActor
    static func dtos(_ records: [VideoRecord]) throws -> [UUID: CatalogRecordDTO] {
        var out: [UUID: CatalogRecordDTO] = [:]
        for record in records { out[record.id] = try dto(record) }
        return out
    }

    /// The DTO without the curated fields a person edits in these
    /// scenarios (and the evidence lists those edits append to).
    static func withoutPersonEdits(_ d: CatalogRecordDTO) -> CatalogRecordDTO {
        var k = d
        k.curated.starRating = nil
        k.curated.userNotes = nil
        k.curated.userDate = nil
        k.curated.userPlace = nil
        k.curated.people = []
        k.curatedFields = []
        k.knowledgeSources = []
        return k
    }

    /// Filenames whose DTO after the relaunch differs from before, or that
    /// are missing / new. `edited`: compared without the person's edits.
    @MainActor
    static func drift(before: [UUID: CatalogRecordDTO], after records: [VideoRecord],
                      edited: Set<UUID> = []) throws -> [String] {
        var wrong: [String] = []
        var seen = Set<UUID>()
        for record in records {
            seen.insert(record.id)
            guard let old = before[record.id] else { wrong.append("new: \(record.filename)"); continue }
            let now = try dto(record)
            let same = edited.contains(record.id) ? withoutPersonEdits(old) == withoutPersonEdits(now) : old == now
            if !same { wrong.append("changed: \(record.filename)") }
        }
        for id in before.keys where !seen.contains(id) { wrong.append("missing: \(id.uuidString)") }
        return wrong
    }

    /// A whole-second date (the store keeps Unix seconds).
    static func date(_ seconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}

/// A seeded generator (SplitMix64): the same 50 edits on every run.
struct CutoverSeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - 1, 2: curated edits, and copies of one content

@Suite("Cutover first week — a person's edits come back after a relaunch, on every copy", .serialized)
@MainActor
struct CutoverFirstWeekEditsTests {

    @Test("Star five videos, date two, place one, note one, confirm one person, reject another — relaunch: all there, nothing else changed")
    func curatedEditsSurviveRelaunch() async throws {
        let scene = try CutoverScene.make("reg_edits", healthyRows: 20); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        let before = try CutoverRegression.dtos(model.records)

        // Stars (the Inspector's StarRatingView writes the field, then saves;
        // good / better / best = 1...3 — StarRatingView.maxStars, the DDL's CHECK).
        let starred = try (1...5).map { try scene.bulk($0) }
        for (record, stars) in zip(starred, [3, 2, 1, 3, 2]) {
            record.starRating = stars
            model.saveCatalogDebounced()
        }
        // Dates (InspectorDateView: the canonical entry + its confidence).
        let dated = try [scene.bulk(1), scene.bulk(6)]
        let dates = try [#require(UserDateEntry.canonicalize("1994")), #require(UserDateEntry.canonicalize("1987-12"))]
        for (record, date) in zip(dated, dates) {
            record.userDate = date
            record.userDateConfidence = UserDateConfidence.known.rawValue
            model.saveCatalogDebounced()
        }
        // A place (InspectorPlaceView).
        let placed = try scene.bulk(2)
        let place = try #require(UserPlaceEntry.canonicalize("Lake Winnipesaukee"))
        placed.userPlace = place
        placed.userPlaceConfidence = UserPlaceConfidence.estimated.rawValue
        model.saveCatalogDebounced()
        // A note (the Notes… sheet's model call).
        let noted = try scene.bulk(3)
        model.setUserNotes("Grandma's 80th — the cake", for: noted)
        // Confirm a person (InspectorFamilyTagsView.confirmTag) on one video,
        // reject another (rejectAutoDetected) on a second.
        let confirmed = try scene.bulk(4)
        confirmed.confirmedByUserPeople.append(ConfirmedTag(name: "Donna", confirmedAt: CutoverRegression.date(1_790_500_000)))
        confirmed.rejectedPeople.removeAll { $0 == "Donna" }
        model.saveCatalogDebounced()
        let rejected = try scene.bulk(7)
        rejected.rejectedPeople.append("Matt")
        rejected.detectedPeople.removeAll { $0 == "Matt" }
        model.saveCatalogDebounced()

        // Quit (the synchronous funnel), relaunch on catalog.sqlite.
        #expect(model.saveCatalogNow())
        try await scene.relaunch()
        #expect(model.catalogCutover.isSQLiteAuthority)

        for (n, stars) in zip(1...5, [3, 2, 1, 3, 2]) {
            #expect(try scene.bulk(n).starRating == stars, Comment(rawValue: "bulk row \(n)"))
        }
        #expect(try scene.bulk(1).userDate == dates[0])
        #expect(try scene.bulk(6).userDate == dates[1])
        #expect(try scene.bulk(6).userDateConfidence == UserDateConfidence.known.rawValue)
        #expect(try scene.bulk(2).userPlace == place)
        #expect(try scene.bulk(2).userPlaceConfidence == UserPlaceConfidence.estimated.rawValue)
        #expect(try scene.bulk(3).userNotes == "Grandma's 80th — the cake")
        #expect(try scene.bulk(4).confirmedByUserPeople.map(\.name) == ["Donna"])
        #expect(try scene.bulk(7).rejectedPeople.contains("Matt"))
        #expect(try scene.bulk(7).confirmedByUserPeople.isEmpty)

        let edited = Set((starred + dated + [placed, noted, confirmed, rejected]).map(\.id))
        let drift = try CutoverRegression.drift(before: before, after: model.records, edited: edited)
        #expect(drift.isEmpty, Comment(rawValue: drift.joined(separator: ", ")))
    }

    // The fixture's curatedConflictA / curatedConflictB are two byte-identical
    // copies (one digest). Step 3 FAILS on B2.2 (f3900b36f), deterministically:
    // both copies end with the EARLIER edit ("typed on B"), in memory and in
    // catalog.sqlite — consistent, but the person's later edit is gone.
    static let laterEditLoses: Comment = """
        FINDING: two copies of one content edited differently in one save window — the value \
        in records order wins, not the later edit. CatalogCommitter.detect builds the plan in \
        records order (VideoScan/Catalog/CatalogCommitter.swift:346); the store's shared row and \
        CatalogCommitBaseline.propagate keep the LAST row written \
        (VideoScan/Catalog/CatalogCommitBaseline.swift:239). No edit time is kept, so A's later \
        note is overwritten by B's earlier one on both copies.
        """

    @Test("Edits on one of two identical copies show on both; edit again → the other follows; both edited differently in one save window → a conflict, nothing dropped; a later single edit resolves it")
    func copiesShareEditsAndLaterEditWins() async throws {
        let scene = try CutoverScene.make("reg_copies"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        let a = try scene.record(.curatedConflictA)
        let b = try scene.record(.curatedConflictB)
        let others = model.records.filter { $0.id != a.id && $0.id != b.id }
        let before = try CutoverRegression.dtos(others)
        let date = try #require(UserDateEntry.canonicalize("1993"))

        // 1. Edits on copy A → both show them.
        a.starRating = 1      // the fixture's copies hold 2 and 3: a value neither had
        a.userDate = date
        a.userDateConfidence = UserDateConfidence.known.rawValue
        model.setUserNotes("the first birthday", for: a)
        #expect(model.saveCatalogNow())
        #expect(b.starRating == 1)
        #expect(b.userDate == date)
        #expect(b.userNotes == "the first birthday")

        // 2. Edit copy B again → copy A follows.
        let lakeHouse: String = try #require(UserPlaceEntry.canonicalize("the lake house"))
        b.userPlace = lakeHouse
        b.userPlaceConfidence = UserPlaceConfidence.known.rawValue
        model.saveCatalogDebounced()
        #expect(model.saveCatalogNow())
        #expect(a.userPlace == b.userPlace)

        // 3. Both edited in ONE save window, differently. B2.3 (Manager's rule,
        // 2026-10-18 — Rick may change it): nothing is silently dropped. Both
        // values go to row_knowledge, the display row is a conflict (empty
        // after a relaunch), and each copy keeps showing its own value now.
        model.setUserNotes("earlier, typed on B", for: b)
        model.setUserNotes("later, typed on A", for: a)
        #expect(model.saveCatalogNow())
        #expect(a.userNotes == "later, typed on A")
        #expect(b.userNotes == "earlier, typed on B", "neither copy is overwritten by the other")

        try await scene.relaunch()
        let a2 = try scene.record(.curatedConflictA)
        let b2 = try scene.record(.curatedConflictB)
        for copy in [a2, b2] {
            #expect(copy.starRating == 1, Comment(rawValue: copy.filename))
            #expect(copy.userDate == date, Comment(rawValue: copy.filename))
            #expect(copy.userPlace == a2.userPlace, Comment(rawValue: copy.filename))
            #expect(copy.userNotes.isEmpty, Comment(rawValue: "\(copy.filename): a conflict shows empty, like an import conflict"))
        }
        // 4. A later edit on ONE copy resolves it: stored, and the other copy follows.
        model.setUserNotes("resolved on A", for: a2)
        #expect(model.saveCatalogNow())
        #expect(b2.userNotes == "resolved on A")
        try await scene.relaunch()
        #expect(try scene.record(.curatedConflictB).userNotes == "resolved on A")
        #expect(a2.userPlace != nil)
        let drift = try CutoverRegression.drift(before: before, after: model.records.filter { $0.id != a.id && $0.id != b.id })
        #expect(drift.isEmpty, Comment(rawValue: drift.joined(separator: ", ")))
    }
}

// MARK: - 3, 5: Trash / Undo / emptied, and a purge

@Suite("Cutover removals — Trash, Undo, Trash emptied and a purge hold across relaunches", .serialized)
@MainActor
struct CutoverRemovalTests {

    @Test("Trash ten videos, Undo three, the Trash emptied for the other seven — relaunch: seven gone with tombstones, three live, revisions consistent")
    func trashUndoEmptied() async throws {
        let scene = try CutoverScene.make("reg_trash", healthyRows: 20); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        let trashed = try (1...10).map { try scene.bulk($0) }
        let mirrors = Dictionary(uniqueKeysWithValues: trashed.map { ($0.id, RemovalMirrors.of($0)) })
        let trashFolder = scene.sandbox.root.appendingPathComponent("Trash", isDirectory: true)

        // Move to Trash: the Trash engine's catalog half, through the one
        // marker writer (applyJunkOutcomes stamps exactly this), then its save.
        let movedAt = CutoverRegression.date(1_790_400_000)
        for record in trashed {
            let gone = trashFolder.appendingPathComponent(record.filename).path    // never created: emptied
            VideoScanModel.stampRemoval(record, .inTrash(movedAt: movedAt, trashPath: gone, reason: .catalogTrash))
        }
        model.saveCatalogDebounced()
        #expect(model.saveCatalogNow())

        // Undo three: each marker write put back BY VALUE AND REVISION.
        let undone = Array(trashed.prefix(3))
        for record in undone {
            let before = try #require(mirrors[record.id])
            let reverted = VideoScanModel.revertRemoval(record, wrote: record.removal, previous: nil, revision: record.removalRevision,
                                                        mirrorsBefore: before, mirrorsAfter: RemovalMirrors.of(record))
            #expect(reverted)
        }
        // Empty the Trash: the other seven are seen emptied.
        let rest = Array(trashed.dropFirst(3))
        #expect(model.noteEmptiedTrash(in: rest, now: CutoverRegression.date(1_790_400_600)) == 7)
        #expect(model.saveCatalogNow())

        try await scene.relaunch()
        for record in undone {
            let back = try scene.live(record.id)
            let stored = try await scene.storedTombstoneRevisions(id: record.id)
            #expect(back.removal == nil, Comment(rawValue: back.filename))
            #expect(back.lifecycleStage == mirrors[record.id]?.lifecycleStage, Comment(rawValue: back.filename))
            #expect(back.removalRevision == 2, Comment(rawValue: back.filename))
            #expect(stored == [1, 2], Comment(rawValue: back.filename))
        }
        for record in rest {
            let back = try scene.live(record.id)
            #expect(back.removal?.state == .inTrash, Comment(rawValue: back.filename))
            #expect(back.removal?.isTrashEmptied == true, Comment(rawValue: back.filename))
            #expect(back.isPurged, Comment(rawValue: back.filename))
            #expect(back.removalRevision == 2, Comment(rawValue: back.filename))
            #expect(try await scene.storedTombstoneRevisions(id: record.id) == [1, 2], Comment(rawValue: back.filename))
        }
        #expect(model.records.filter { $0.isPurged }.count == 8, "the seven, and the fixture's own tombstoned row")
    }

    /// Seen on B2.2 (f3900b36f): the three undone rows come back In the Trash
    /// after the relaunch (purged count 11, not 8); catalog.log names each
    /// refusal ("CHECK constraint failed: removal_state IS NOT 'inTrash' OR
    /// lifecycle = 'Trashed'").
    static let undoRefused: Comment = """
        FINDING: Undo (or Restore) of a Trash that was already committed is REFUSED by catalog.sqlite \
        and comes back In the Trash after a relaunch. updateFile writes lifecycle in its first UPDATE \
        (VideoScanCore/Store/GRDBCatalogRepository+Live.swift:64) and the removal marker only in a \
        second one (:86); between them the row holds removal_state 'inTrash' with lifecycle no longer \
        'Trashed', which the files CHECK removalMirrorsLifecycle refuses \
        (VideoScanCore/Store/CatalogDataSchema.swift:225).
        """

    // FAILS on B2.2 (f3900b36f): the door logs "Purge Non-Video Media
    // DEGRADED … NOTHING was removed". Fail-closed (no data lost), but the
    // purge is dead after the flip — and so is every door gated on the same
    // snapshot (cover-art and unrelated-audio purges, Remove Scan Target,
    // Notes repair, volume rename; the scan-merge tripwire degrades to no-prune).
    static let purgeDoorDead: Comment = """
        FINDING: after the flip every snapshot-gated purge removes nothing. snapshotCatalog writes \
        its safety copy through CatalogStore.writeSnapshot \
        (VideoScan/Volumes/VideoScanModel+ScanMerge.swift:819), which refuses while catalog.json is \
        frozen (VideoScan/Catalog/CatalogStore.swift:1233; frozen at CatalogAuthorityFlip.swift:194), \
        so purgeNonVideoMedia degrades and returns .none \
        (VideoScan/MediaOps/VideoScanModel+NonVideoMediaPurge.swift:104-113).
        """

    @Test("Purge a stray non-video file from the catalog — relaunch twice: gone both times, its row tombstoned")
    func purgedRowStaysGone() async throws {
        let scene = try CutoverScene.make("reg_purge", healthyRows: 20); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        // A still image that got into the catalog (the shape Purge Non-Video Media is for).
        let stray = try scene.bulk(3)
        stray.ext = "jpg"
        model.saveCatalogDebounced()
        #expect(model.saveCatalogNow())
        let id = stray.id
        let others = model.records.filter { $0.id != id }
        let before = try CutoverRegression.dtos(others)

        let volumes = Set(model.classifyNonVideoMedia().volumeKeys)
        #expect(volumes.isEmpty == false, "the classification offers the stray")
        let outcome = model.purgeNonVideoMedia(extensions: ["jpg"], volumeKeys: volumes)
        // Everything after the door depends on it having removed the row.
        #expect(outcome.removed == 1, Comment(rawValue: scene.sandbox.catalogLogText()))
        #expect(model.records.contains { $0.id == id } == false)

        for _ in 1...2 {
            try await scene.relaunch()
            #expect(model.records.contains { $0.id == id } == false)
        }
        let reloaded = try await scene.sqliteLoad()
        #expect(reloaded.purgedCount == 1)
        #expect(try await scene.storedTombstoneRevisions(id: id) == [1], "tombstoned, never deleted")
        let drift = try CutoverRegression.drift(before: before, after: model.records)
        #expect(drift.isEmpty, Comment(rawValue: drift.joined(separator: ", ")))
    }
}

// MARK: - 4: a new file before its whole-file hash

@Suite("Cutover new rows — a new file quit before its hash, then hashed, is there exactly once", .serialized)
@MainActor
struct CutoverNewRowTests {

    @Test("A new file appears, quit before its hash lands — relaunch: back, waiting; the hash lands — stored; relaunch again: there exactly once")
    func newFileBeforeAndAfterHash() async throws {
        let scene = try CutoverScene.make("reg_new"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        let before = try CutoverRegression.dtos(model.records)
        // A Combine output / scan result: a record with no whole-file hash yet.
        let fresh = try scene.freshCopy(of: .healthy, path: "/Volumes/Fixture/New/combined-1994.mov")
        model.records.append(fresh)
        model.saveCatalogDebounced()
        #expect(model.saveCatalogNow(), "a held row is durable")

        try await scene.relaunch()
        let back = try scene.live(fresh.id)
        #expect(model.catalogCutover.awaitingDigest.contains(fresh.id))
        #expect(try scene.committer().heldIDs == [fresh.id])

        // Fill In Full Hashes lands the hash on the record, then saves.
        back.contentFixity = ContentFixity(digest: PoisonedCatalogFixture.digest("combined-1994"), byteCount: back.sizeBytes,
                                           stamp: FileIdentityStamp(device: 1, inode: 2, size: back.sizeBytes, mtimeNs: 3,
                                                                    ctimeNs: 4, volumeUUID: nil))
        model.saveCatalogDebounced()
        #expect(model.saveCatalogNow())
        #expect(try scene.committer().heldIDs.isEmpty)

        try await scene.relaunch()
        #expect(model.records.filter { $0.id == fresh.id }.count == 1)
        #expect(try scene.live(fresh.id).contentFixity?.digest == PoisonedCatalogFixture.digest("combined-1994"))
        #expect(model.catalogCutover.awaitingDigest.isEmpty)
        #expect(try scene.committer().heldIDs.isEmpty)
        let reloaded = try await scene.sqliteLoad()
        #expect(reloaded.records.filter { $0.id == fresh.id }.count == 1)
        #expect(reloaded.heldIDs.isEmpty)
        let drift = try CutoverRegression.drift(before: before, after: model.records.filter { $0.id != fresh.id })
        #expect(drift.isEmpty, Comment(rawValue: drift.joined(separator: ", ")))
    }
}

// MARK: - 6: a promotion

@Suite("Cutover promote — an archive copy, its fixity and lineage survive a relaunch", .serialized)
@MainActor
struct CutoverArchiveTests {

    @Test("Promote a video to the Master Archive — relaunch: the archive copy, its fixity and its lineage are there")
    func promotedCopySurvives() async throws {
        let scene = try CutoverScene.make("reg_promote"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        let source = try scene.record(.healthy)
        let sourceID = source.id
        let archivePath = "/Volumes/Fixture/FamilyArchive/1990s/healthy.mov"
        let digest = PoisonedCatalogFixture.digest(PoisonedCatalogFixture.Shape.healthy.rawValue)
        let promotedAt = CutoverRegression.date(1_790_600_000)
        // The job's probe of the verified copy (fresh id, its path), then
        // Promote's main-actor catalog step (PromoteToArchiveJob calls it).
        let probed = try scene.freshCopy(of: .healthy, path: archivePath)
        let copy = model.registerPromotedCopy(source: source, destinationURL: URL(fileURLWithPath: archivePath),
                                              relativePath: "1990s/healthy.mov", sha256: digest, probed: probed,
                                              promotedAt: promotedAt)
        let copyID = copy.id
        #expect(model.saveCatalogNow())

        try await scene.relaunch()
        let back = try scene.live(copyID)
        #expect(back.fullPath == archivePath)
        #expect(back.archiveFixity?.digest == digest)
        #expect(back.archiveFixity?.sizeBytes == back.sizeBytes)
        #expect(back.archivedAt == promotedAt)
        #expect(back.derivedFrom == sourceID)
        #expect(back.derivationKind == ArchivePromotion.derivationKind)
        #expect(back.archiveStage == .masterAssigned)
        let origin = try scene.live(sourceID)
        #expect(origin.archiveStage == .masterAssigned)
        #expect(origin.removal == nil, "the source stays live")
        #expect(model.records.filter { $0.id == copyID }.count == 1)
    }
}

// MARK: - 7: MOPS-16

@Suite("Cutover hold — an edit during an MFO job's hold lands when it ends, and survives a quit", .serialized)
@MainActor
struct CutoverHoldTests {

    @Test("An edit while a job holds catalog writes lands when the job ends; an edit during a hold then Quit is still there after the relaunch")
    func editDuringHoldLands() async throws {
        let scene = try CutoverScene.make("reg_hold"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model

        // 1. The job holds writes; the edit waits; the job ends; it lands.
        _ = await model.catalogStore.holdWrites(reason: "Verify Catalog is reading the catalog", owner: CatalogWriteHoldOwner())
        let healthy = try scene.record(.healthy)
        model.setUserNotes("typed while Verify ran", for: healthy)
        try await Task.sleep(for: .milliseconds(2_600))           // past one debounce: the commit was asked for
        #expect(scene.sandbox.catalogLogText().contains("HELD — Verify Catalog is reading the catalog"))
        #expect(try await scene.reloaded(.healthy).userNotes != "typed while Verify ran")
        _ = model.catalogStore.releaseWriteHold()
        try await scene.settle()
        #expect(try scene.committer().changedRecordCount() == 0)
        #expect(try await scene.reloaded(.healthy).userNotes == "typed while Verify ran")

        // 2. Another hold, an edit, then Quit: the quit path releases a hold
        //    still up and saves (or writes a recovery copy).
        _ = await model.catalogStore.holdWrites(reason: "Import to SQLite is reading the catalog", owner: CatalogWriteHoldOwner())
        try scene.record(.stalePrint).starRating = 3
        model.saveCatalogDebounced()
        ImportToSQLiteQuit.releaseHoldIfStillHeld(model: model, deadline: 0)
        let outcome = CatalogQuitRecovery.saveAtTermination(model: model)
        #expect(outcome == .saved, Comment(rawValue: "\(outcome)"))
        try await scene.relaunch()
        #expect(try scene.record(.stalePrint).starRating == 3)
        #expect(try scene.record(.healthy).userNotes == "typed while Verify ran")
    }
}

// MARK: - 8, 9: the Switch itself, and a restore + Adopt

@Suite("Cutover Switch and restore — the Switch carries the last edit; a restored catalog.sqlite is read-only until adopted", .serialized)
@MainActor
struct CutoverSwitchRestoreTests {

    @Test("Switch with a rehearsal catalog.sqlite and an unsaved edit: the edit is in the new catalog, the rehearsal moved aside (all five files), catalog.json frozen, the designation carried, the latch written")
    func switchCarriesPendingEdit() async throws {
        let scene = try CutoverScene.make("reg_switch"); defer { scene.cleanup() }
        let designation = try scene.writeDesignation(rootPath: "/Volumes/Archive/Breen_Family_Archive")
        try await scene.importCatalog()                            // the rehearsal
        let rehearsal = CatalogSwitch.rehearsalFiles(in: scene.folder).map(\.lastPathComponent).sorted()
        #expect(rehearsal.count == 5, Comment(rawValue: rehearsal.joined(separator: ", ")))
        let model = scene.model
        model.records = model.loadCatalogAtLaunch()                // still on catalog.json (no latch)
        #expect(model.catalogCutover.isSQLiteAuthority == false)
        // The last edit before the switch, still in the JSON store's debounce.
        let healthy = try scene.record(.healthy)
        model.setUserNotes("typed just before Switch", for: healthy)
        #expect(model.catalogStore.hasUnsavedChanges)

        // The app's own switch environment; only the import is scripted (the
        // fixture has no media for Audit/Verify to read): Verify and Audit
        // "ran again" on the flushed bytes, then the real importer.
        var env = model.catalogSwitchEnvironment(center: MediaFileOperationsCenter())
        env.runImport = {
            do { try scene.recertify(); try await scene.importCatalog(); return .imported } catch { return .notImported("\(error)") }
        }
        let phase = await CatalogSwitchRun.run(env)
        guard case .done = phase else { Issue.record("expected .done, got \(phase)"); return }

        // The rehearsal: moved, all five, into one dated folder.
        let asides = try FileManager.default.contentsOfDirectory(at: scene.folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(CatalogSwitch.rehearsalPrefix) }
        #expect(asides.count == 1)
        let aside = try #require(asides.first)
        let moved = try FileManager.default.contentsOfDirectory(atPath: aside.path).sorted()
        #expect(moved == rehearsal)
        // catalog.json frozen: a save after the switch does not reach it.
        #expect(model.catalogStore.isReadOnly)
        let frozen = try scene.sha256(scene.catalogURL)
        let late = try scene.record(.stalePrint)
        model.setUserNotes("typed after Switch, before the quit", for: late)
        #expect(model.saveCatalogNow() == false)
        #expect(try scene.sha256(scene.catalogURL) == frozen)
        // The latch, and the designation catalog.json carried.
        #expect(FileManager.default.fileExists(atPath: scene.latchURL.path))
        let launch = try #require(try? await SQLiteLaunchRead.read(scene.databaseURL).get())
        await launch.repository.close()
        #expect(CatalogCommitter.designation(fromJSON: launch.designationJSON) == designation)

        // Quit, relaunch: on catalog.sqlite, with the edit.
        try await scene.relaunch()
        #expect(model.catalogCutover.isSQLiteAuthority)
        #expect(try scene.record(.healthy).userNotes == "typed just before Switch")
        // ADAPTED: a real launch is VideoScanModel.init — loadCatalogAtLaunch(),
        // THEN `masterArchive = catalogStore.masterArchive` (VideoScanModel.swift:
        // 1161-1169). The scene's relaunch re-runs only the first half, so assert
        // the value init adopts: catalog_state's, set by adoptSQLiteAuthority
        // (CatalogAuthorityFlip.swift:196).
        #expect(model.catalogStore.masterArchive == designation)
    }

    @Test("Restore an older catalog.sqlite backup: it opens read-only and says so; Adopt makes it writable; no edit made after the backup comes back")
    func restoreThenAdopt() async throws {
        let scene = try CutoverScene.make("reg_restore"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        try scene.record(.healthy).starRating = 2
        model.saveCatalogDebounced()
        #expect(model.saveCatalogNow())
        await scene.closeStore()                                   // quit
        let backup = scene.sandbox.root.appendingPathComponent("backup-catalog.sqlite")
        try scene.vacuumInto(backup)                               // the backup

        // The next sessions: edits made AFTER the backup.
        try await scene.relaunch()
        let healthy = try scene.record(.healthy)
        model.setUserNotes("typed after the backup", for: healthy)
        try scene.record(.stalePrint).starRating = 3
        model.saveCatalogDebounced()
        #expect(model.saveCatalogNow())
        await scene.closeStore()                                   // quit

        // Restore: the backup replaces catalog.sqlite (its -wal / -shm go
        // with the file they belong to); the high-water files stay.
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: scene.databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        try FileManager.default.copyItem(at: backup, to: scene.databaseURL)

        try await scene.relaunch()
        let cutover = model.catalogCutover
        #expect(cutover.isSQLiteAuthority)
        #expect(model.isReadOnly)
        #expect(cutover.blockedReason?.contains("restoredBelowHighWater") == true)
        #expect(scene.sandbox.catalogLogText().contains("Adopt This SQLite Catalog"))
        #expect(cutover.canAdopt)
        #expect(try scene.record(.healthy).starRating == 2, "the backup's own edit is there")

        let request = try #require(await cutover.adoptRequestIfAdoptable())
        #expect(request.databaseGeneration < request.highWater)
        #expect(await cutover.adopt(request) == .adopted(from: request.databaseGeneration, to: request.highWater))
        #expect(model.isReadOnly == false)
        #expect(cutover.canAdopt == false)
        #expect(model.saveCatalogNow())

        try await scene.relaunch()
        #expect(model.isReadOnly == false)
        #expect(try scene.record(.healthy).starRating == 2)
        #expect(try scene.record(.healthy).userNotes != "typed after the backup")
        #expect(try scene.record(.stalePrint).starRating != 3)
    }
}

// MARK: - 10: many edits over many save windows

@Suite("Cutover many edits — a 2,000-row catalog gets exactly the 50 edits made, nothing else", .serialized)
@MainActor
struct CutoverManyEditsTests {

    /// What a bulk row must show after the relaunch (the last edit wins).
    struct Expected {
        var stars: Int?
        var notes: String?
        var date: String?
        var place: String?
    }

    @Test("A 2,000-row catalog: 50 seeded random edits across 10 save windows — relaunch: exactly those 50 changes, every other row identical")
    func fiftyEditsTenWindows() async throws {
        let rows = 2_000
        let scene = try CutoverScene.make("reg_many", healthyRows: rows); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        #expect(model.records.count == rows + 5)
        let before = try CutoverRegression.dtos(model.records)
        let years = try (0..<50).map { try #require(UserDateEntry.canonicalize(String(1950 + $0))) }
        let places = try (0..<20).map { try #require(UserPlaceEntry.canonicalize("Place \($0 + 1)")) }

        var rng = CutoverSeededGenerator(seed: 20_261_018)
        var expected: [UUID: Expected] = [:]
        for window in 0..<10 {
            for edit in 0..<5 {
                let record = try scene.bulk(Int.random(in: 0..<rows, using: &rng))
                var want = expected[record.id] ?? Expected()
                switch Int.random(in: 0..<4, using: &rng) {
                case 0:
                    let stars = Int.random(in: 1...3, using: &rng)   // good / better / best
                    record.starRating = stars
                    model.saveCatalogDebounced()
                    want.stars = stars
                case 1:
                    let text = "window \(window), edit \(edit)"
                    model.setUserNotes(text, for: record)
                    want.notes = text
                case 2:
                    let year = years[Int.random(in: 0..<years.count, using: &rng)]
                    record.userDate = year
                    record.userDateConfidence = UserDateConfidence.estimated.rawValue
                    model.saveCatalogDebounced()
                    want.date = year
                default:
                    let place = places[Int.random(in: 0..<places.count, using: &rng)]
                    record.userPlace = place
                    record.userPlaceConfidence = UserPlaceConfidence.known.rawValue
                    model.saveCatalogDebounced()
                    want.place = place
                }
                expected[record.id] = want
            }
            #expect(model.saveCatalogNow(), Comment(rawValue: "save window \(window)"))
        }

        try await scene.relaunch()
        #expect(model.records.count == rows + 5)
        var wrong: [String] = []
        for (id, want) in expected {
            let record = try scene.live(id)
            if let stars = want.stars, record.starRating != stars { wrong.append("\(record.filename) stars \(record.starRating) ≠ \(stars)") }
            if let notes = want.notes, record.userNotes != notes { wrong.append("\(record.filename) notes") }
            if let date = want.date, record.userDate != date { wrong.append("\(record.filename) date") }
            if let place = want.place, record.userPlace != place { wrong.append("\(record.filename) place") }
        }
        #expect(wrong.isEmpty, Comment(rawValue: wrong.joined(separator: "; ")))
        let drift = try CutoverRegression.drift(before: before, after: model.records, edited: Set(expected.keys))
        #expect(drift.isEmpty, Comment(rawValue: drift.prefix(20).joined(separator: ", ")))
    }
}
