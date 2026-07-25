// RepairLifecycleDeepTests.swift
// Deep-test pass over the GH #132 repair lifecycle (testing agent,
// 2026-07-24 overnight branch). Covers the hard edges feature-dev
// flagged plus the gap sweep:
//
//   * Inheritance merge EDGE cases — conflicting people tiers
//     (confirmed-on-original vs rejected-on-repair), case collisions in
//     the rejected union, multi-line userNotes composition, starRating
//     max in BOTH directions, the stage copy-only-when-default guards,
//     and a byte-level no-op proof for a blank original.
//   * Confirm ↔ rescan ↔ undo interleavings through the REAL pipeline
//     (snapshotPreservedFieldsForRescan → fresh instances →
//     applyPreservedFieldsAfterRescan → commitScanResults), including
//     the rescan-never-resurrects sensor in its post-confirm shape.
//   * Mixed batch confirm + undo — byte-for-byte exact restoration,
//     no-op members untouched.
//   * Superseded-visibility audit across ALL 8 documented
//     pfActiveRecords call sites (source-scan sensor + a functional
//     smoke through the delta duplicate analysis).
//   * The commit-5 scale gap: pfAwaitingConfirmation and the widened
//     pfActiveRecords at 100k with explicit budgets.
//
// C++ note: `#expect` ≈ gtest's EXPECT_* (non-fatal, captures the whole
// expression); `withKnownIssue { … }` is gtest's "expected failure" but
// INVERTED on fix — the test FAILS the day the bug is fixed, forcing the
// block to be promoted to plain #expect. We use it to pin real defects
// found by this pass without turning the suite red (findings reported to
// the Manager for production attention — tests must not fix production).

import Testing
import Foundation
@testable import VideoScan

// MARK: - Shared fixtures

@MainActor
private func makeLifecyclePair(
    model: VideoScanModel,
    suffix: String = ""
) -> (original: VideoRecord, repair: VideoRecord) {
    let original = VideoRecord()
    original.filename = "tape\(suffix).mov"
    original.fullPath = "/Volumes/T/tape\(suffix).mov"
    original.directory = "/Volumes/T"
    original.streamTypeRaw = StreamType.videoAndAudio.rawValue
    original.audioVerifyStatus = "damaged"
    original.audioVerifyNote = "Damaged audio — invalid codec (qdm2)"

    let repair = VideoRecord()
    repair.filename = "tape\(suffix)_RepairedAudio.mov"
    repair.fullPath = "/Volumes/T/tape\(suffix)_RepairedAudio.mov"
    repair.directory = "/Volumes/T"
    repair.streamTypeRaw = StreamType.videoAndAudio.rawValue
    repair.derivedFrom = original.id
    repair.derivationKind = "rebuildAudio"

    model.records.append(contentsOf: [original, repair])
    return (original, repair)
}

/// Deterministic DTO encoding — the catalog.json byte shape. Byte
/// equality is the strongest "restored exactly / never touched" oracle:
/// ANY persisted field that drifts shows up, including fields a future
/// snapshot forgets to carry.
@MainActor
private func lifecycleGoldenBytes(_ r: VideoRecord) throws -> Data {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    e.dateEncodingStrategy = .iso8601
    return try e.encode(VideoRecordDTO(r))
}

// MARK: - 1. Inheritance merge edges

@MainActor
@Suite("RepairLifecycle — inheritance merge edges")
struct RepairInheritanceEdgeTests {

    // The app-wide people invariant (ConfirmPersonSheet.catalogWriteback,
    // InspectorFamilyTagsView.confirmTag): a person lives in EXACTLY ONE
    // tier — confirmed, suspected, or rejected — and the user's MOST
    // RECENT explicit decision wins. The confirm-time merge must honor
    // both rules; today it violates them (reported to Manager — the
    // union loops append cross-tier without cleanup).

    @Test func repairSideRejectionMustBeatOriginalSideConfirmation() {
        let model = VideoScanModel()
        let (original, repair) = makeLifecyclePair(model: model)
        // Rick confirmed Donna on the ORIGINAL years-ago pass…
        original.confirmedByUserPeople = [ConfirmedTag(name: "Donna", confirmedAt: Date())]
        // …then looked at the repair and explicitly said No.
        repair.rejectedPeople = ["Donna"]

        model.applyHumanMetadataInheritance(from: original, to: repair)

        // Fixed (deep-test finding 3): the repair-side judgment wins and
        // the one-tier invariant holds.
        let confirmedNames = repair.confirmedByUserPeople.map(\.name)
        #expect(!confirmedNames.contains("Donna"),
                "Rick's explicit No on the repair is his most recent decision — the original's stale confirmation must not resurrect Donna")
        #expect(!(confirmedNames.contains("Donna") && repair.rejectedPeople.contains("Donna")),
                "one-tier invariant: a person must never be confirmed AND rejected on the same record")
    }

    @Test func repairSideConfirmationMustBeatOriginalSideRejection() {
        let model = VideoScanModel()
        let (original, repair) = makeLifecyclePair(model: model)
        original.rejectedPeople = ["Donna"]
        repair.confirmedByUserPeople = [ConfirmedTag(name: "Donna", confirmedAt: Date())]

        model.applyHumanMetadataInheritance(from: original, to: repair)

        // Fixed (deep-test finding 3, reverse direction).
        #expect(!repair.rejectedPeople.contains("Donna"),
                "the repair's explicit confirmation wins; Donna must not enter rejectedPeople")
    }

    @Test func rejectedPeopleUnionMustBeCaseInsensitive() {
        // Every other people comparison in the app (ConfirmPersonSheet,
        // the confirmed-union in this very merge) is caseInsensitive;
        // the rejected union uses exact contains — "donna" and "Donna"
        // both land.
        let model = VideoScanModel()
        let (original, repair) = makeLifecyclePair(model: model)
        original.rejectedPeople = ["donna"]
        repair.rejectedPeople = ["Donna"]

        model.applyHumanMetadataInheritance(from: original, to: repair)

        // Fixed (deep-test finding 4): the union is case-insensitive
        // like every other people comparison.
        let unique = Set(repair.rejectedPeople.map { $0.lowercased() })
        #expect(repair.rejectedPeople.count == unique.count,
                "case-variant duplicate in rejectedPeople: \(repair.rejectedPeople)")
    }

    @Test func multiLineUserNotesComposeRepairFirstInOrder() {
        let model = VideoScanModel()
        let (original, repair) = makeLifecyclePair(model: model)
        original.userNotes = "birthday tape\nfrom Pat's house"
        repair.userNotes = "audio fixed by hand\nchecked levels"

        model.applyHumanMetadataInheritance(from: original, to: repair)

        #expect(repair.userNotes == "audio fixed by hand\nchecked levels\nbirthday tape\nfrom Pat's house",
                "repair's own notes keep the lead; the original's full multi-line text appends after ONE joining newline")
        #expect(!repair.userNotes.contains("\n\n"),
                "no blank-line artifacts from the append")
    }

    @Test func starRatingTakesTheMaxInBothDirections() {
        let model = VideoScanModel()
        let a = makeLifecyclePair(model: model, suffix: "A")
        a.original.starRating = 5
        a.repair.starRating = 2
        model.applyHumanMetadataInheritance(from: a.original, to: a.repair)
        #expect(a.repair.starRating == 5, "original-higher direction: max wins")

        let b = makeLifecyclePair(model: model, suffix: "B")
        b.original.starRating = 1
        b.repair.starRating = 4
        model.applyHumanMetadataInheritance(from: b.original, to: b.repair)
        #expect(b.repair.starRating == 4, "repair-higher direction: max wins")
    }

    @Test func stageFieldsCopyOnlyWhileTheRepairHoldsTheDefault() {
        let model = VideoScanModel()

        // Guard direction: Rick already staged the repair — never clobber.
        let a = makeLifecyclePair(model: model, suffix: "A")
        a.original.archiveStage = .archived
        a.original.lifecycleStage = .archived
        a.repair.archiveStage = .backedUp
        a.repair.lifecycleStage = .workbench
        model.applyHumanMetadataInheritance(from: a.original, to: a.repair)
        #expect(a.repair.archiveStage == .backedUp,
                "a non-default archiveStage on the repair is Rick's call — copy-only-when-default")
        #expect(a.repair.lifecycleStage == .workbench,
                "a non-default lifecycleStage on the repair is Rick's call")

        // Copy direction: default repair inherits the original's stages.
        let b = makeLifecyclePair(model: model, suffix: "B")
        b.original.archiveStage = .healthy
        b.original.lifecycleStage = .archived
        model.applyHumanMetadataInheritance(from: b.original, to: b.repair)
        #expect(b.repair.archiveStage == .healthy)
        #expect(b.repair.lifecycleStage == .archived)
    }

    @Test func inheritingFromABlankOriginalIsAByteLevelNoOp() throws {
        // An original with NO human metadata must leave the repair
        // byte-identical — no empty-string appends, no spurious default
        // copies, nothing.
        let model = VideoScanModel()
        let (original, repair) = makeLifecyclePair(model: model)
        repair.tags = ["Fix Audio"]
        repair.userNotes = "my note"
        repair.starRating = 3
        let before = try lifecycleGoldenBytes(repair)

        model.applyHumanMetadataInheritance(from: original, to: repair)

        let after = try lifecycleGoldenBytes(repair)
        #expect(after == before,
                "blank-original inheritance drifted the repair's bytes")
    }
}

// MARK: - 2. Confirm ↔ rescan ↔ undo interleavings

@MainActor
@Suite("RepairLifecycle — confirm ↔ rescan ↔ undo", .serialized)
struct RepairLifecycleRescanInterleavingTests {

    /// Run the REAL rescan pipeline over /Volumes/T exactly the way
    /// ScanExecution does: snapshot preserved fields → fresh instances
    /// (what probeFile would produce: same paths, NEW UUIDs, no user
    /// fields) → apply preserved fields → commitScanResults (complete).
    /// Returns the fresh instances now living in the catalog.
    private func rescan(
        model: VideoScanModel,
        paths: [String]
    ) async -> [String: VideoRecord] {
        let target = CatalogScanTarget(searchPath: "/Volumes/T")
        model.snapshotPreservedFieldsForRescan(of: target)
        let fresh: [VideoRecord] = paths.map { path in
            let r = VideoRecord()
            r.fullPath = path
            r.filename = (path as NSString).lastPathComponent
            r.directory = (path as NSString).deletingLastPathComponent
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            return r
        }
        model.applyPreservedFieldsAfterRescan(of: target, onto: fresh)
        _ = await model.commitScanResults(root: "/Volumes/T", volName: "T",
                                          targetRecords: fresh,
                                          scanWasComplete: true)
        return Dictionary(uniqueKeysWithValues: fresh.map { ($0.fullPath, $0) })
    }

    @Test func supersededOriginalStaysRetiredThroughAFullRescanCycle() async throws {
        // The rescan-never-resurrects sensor in its POST-CONFIRM shape,
        // through the real snapshot → merge pipeline (the schema tests
        // pin the field-level contract; this pins the wiring).
        let model = VideoScanModel()
        let (original, repair) = makeLifecyclePair(model: model)
        original.tags = ["Gold"]
        #expect(model.confirmRepair(repairID: repair.id))

        let fresh = await rescan(model: model,
                                 paths: [original.fullPath, repair.fullPath])
        let freshOriginal = try #require(fresh[original.fullPath])
        let freshRepair = try #require(fresh[repair.fullPath])

        #expect(model.records.count == 2, "replace, not duplicate")
        #expect(freshOriginal.isSuperseded,
                "a routine rescan must NEVER resurrect a superseded original")
        #expect(pfActiveRecords(model.records).map(\.id) == [freshRepair.id],
                "post-rescan default view still shows only the repair")
        #expect(freshRepair.repairConfirmedDate != nil,
                "a rescan must never un-confirm a confirmed repair")

        // The supersede marker survives AND resolves: record ids are
        // minted fresh by the scan, so the apply pass re-links the
        // pointer via the fullPath → old-id join (deep-test finding 2,
        // fixed). "Show Repaired Copy in Catalog" must keep working
        // across an instance swap.
        let resolves = model.records.contains { $0.id == freshOriginal.supersededByID }
        #expect(resolves,
                "supersededByID must resolve to a live record after a rescan")
        #expect(freshOriginal.supersededByID == freshRepair.id,
                "…and to the repair's FRESH instance specifically")
    }

    @Test func awaitingRepairMustSurviveARescan() async throws {
        // The sharper bug: rebuild 25 tapes overnight, rescan the volume
        // in the morning — every repair silently leaves the "Repaired —
        // Awaiting Confirmation" worklist and can never be confirmed,
        // because RescanPreservedFields does not carry derivedFrom /
        // derivationKind and the scan's fresh instances have neither.
        let model = VideoScanModel()
        let (original, repair) = makeLifecyclePair(model: model)
        #expect(repair.isAwaitingConfirmation, "fixture sanity")

        let fresh = await rescan(model: model,
                                 paths: [original.fullPath, repair.fullPath])
        let freshRepair = try #require(fresh[repair.fullPath])

        // Fixed (deep-test finding 1 + the finding-2 re-link):
        // derivedFrom/derivationKind are rescan-preserved AND the
        // derivedFrom pointer is re-linked to the original's fresh id,
        // so the worklist survives and confirm still resolves the pair.
        #expect(freshRepair.isAwaitingConfirmation,
                "an unconfirmed repair must still be awaiting confirmation after a rescan")
        #expect(model.confirmRepair(repairID: freshRepair.id),
                "confirm must still work after a rescan")
    }

    @Test func undoAfterARescanNeverHalfRestores() async throws {
        // The armed undo batch holds PRE-RESCAN record ids. After the
        // instances are swapped, undo must be a clean all-or-nothing:
        // either exact restore or a false return with ZERO mutation —
        // never a half-restored stamp pair. (Today it is the clean
        // no-op; the stale banner itself is a minor UX finding.)
        let model = VideoScanModel()
        let (original, repair) = makeLifecyclePair(model: model)
        #expect(model.confirmRepair(repairID: repair.id))
        #expect(model.lastConfirmBatch != nil)

        let fresh = await rescan(model: model,
                                 paths: [original.fullPath, repair.fullPath])
        let freshOriginal = try #require(fresh[original.fullPath])
        let freshRepair = try #require(fresh[repair.fullPath])
        let originalBytes = try lifecycleGoldenBytes(freshOriginal)
        let repairBytes = try lifecycleGoldenBytes(freshRepair)

        #expect(!model.undoConfirmRepair(),
                "undo whose snapshot ids no longer resolve must report false")
        let originalAfter = try lifecycleGoldenBytes(freshOriginal)
        #expect(originalAfter == originalBytes,
                "no half-restore: the fresh original is byte-identical")
        let repairAfter = try lifecycleGoldenBytes(freshRepair)
        #expect(repairAfter == repairBytes,
                "no half-restore: the fresh repair is byte-identical")
        #expect(freshOriginal.isSuperseded, "the retire marker stays put")
        #expect(model.lastConfirmBatch == nil, "the stale banner is dropped")
    }
}

// MARK: - 3. Mixed batch confirm + undo, chained repairs

@MainActor
@Suite("RepairLifecycle — batch undo exactness")
struct RepairLifecycleBatchUndoTests {

    @Test func mixedBatchUndoRestoresOnlyWhatChangedByteForByte() throws {
        let model = VideoScanModel()

        // Two valid pairs — B's repair carries pre-existing curation so
        // the undo has real merged state to unwind.
        let a = makeLifecyclePair(model: model, suffix: "A")
        a.original.tags = ["Gold"]
        a.original.userDate = "1992-06"
        a.original.userDateConfidence = "known"
        let b = makeLifecyclePair(model: model, suffix: "B")
        b.original.userNotes = "the good tape"
        b.original.starRating = 5
        b.repair.tags = ["Fix Audio"]
        b.repair.userNotes = "checked levels"
        b.repair.starRating = 1

        // No-op members: an orphan repair (original gone) and an
        // already-confirmed repair.
        let orphan = VideoRecord()
        orphan.filename = "orphan_RepairedAudio.mov"
        orphan.fullPath = "/Volumes/T/orphan_RepairedAudio.mov"
        orphan.streamTypeRaw = StreamType.videoAndAudio.rawValue
        orphan.derivedFrom = UUID()
        orphan.derivationKind = "rebuildAudio"
        model.records.append(orphan)
        let d = makeLifecyclePair(model: model, suffix: "D")
        #expect(model.confirmRepair(repairID: d.repair.id), "pre-confirm D")

        // Byte capture of EVERYTHING before the batch.
        let all = [a.original, a.repair, b.original, b.repair,
                   orphan, d.original, d.repair]
        let before = try all.map { try lifecycleGoldenBytes($0) }

        let ids: Set<UUID> = [a.repair.id, b.repair.id, orphan.id, d.repair.id]
        #expect(model.confirmRepairs(repairIDs: ids) == 2,
                "only the two valid members confirm")
        #expect(model.lastConfirmBatch?.snapshots.count == 2)

        // The no-op members were never touched — not even a stamp.
        let orphanAfter = try lifecycleGoldenBytes(orphan)
        #expect(orphanAfter == before[4])
        let dOriginalAfter = try lifecycleGoldenBytes(d.original)
        #expect(dOriginalAfter == before[5])
        let dRepairAfter = try lifecycleGoldenBytes(d.repair)
        #expect(dRepairAfter == before[6])

        #expect(model.undoConfirmRepair())

        // EXACT restoration, byte-for-byte, across the whole cast.
        for (i, rec) in all.enumerated() {
            let restored = try lifecycleGoldenBytes(rec)
            #expect(restored == before[i],
                    "record \(rec.filename) drifted through confirm+undo — the snapshot is incomplete")
        }
    }

    @Test func chainedRepairOfARepairFlowsThroughTheSameLifecycle() {
        // A ← B (confirmed repair) — then B itself turns out damaged and
        // C repairs B. Confirming C must retire B while A stays retired:
        // the lifecycle composes.
        let model = VideoScanModel()
        let first = makeLifecyclePair(model: model, suffix: "A")
        #expect(model.confirmRepair(repairID: first.repair.id))

        let c = VideoRecord()
        c.filename = "tapeA_RepairedAudio_v2.mov"
        c.fullPath = "/Volumes/T/tapeA_RepairedAudio_v2.mov"
        c.streamTypeRaw = StreamType.videoAndAudio.rawValue
        c.derivedFrom = first.repair.id
        c.derivationKind = "rebuildAudio"
        model.records.append(c)
        #expect(c.isAwaitingConfirmation)

        #expect(model.confirmRepair(repairID: c.id))
        #expect(first.repair.supersededByID == c.id,
                "the middle record is both a confirmed repair AND superseded")
        #expect(first.repair.repairConfirmedDate != nil)
        #expect(first.original.supersededByID == first.repair.id,
                "the first retire is untouched by the second confirm")
        #expect(pfActiveRecords(model.records).map(\.id) == [c.id],
                "only the tip of the chain is active")
        #expect(model.records.filter(pfAwaitingConfirmation).isEmpty)
    }

    @Test func reconfirmAfterManualUnsupersedeIsANoOp() {
        // Settled decision #4 adjacent: un-supersede restores the
        // original but the repair KEEPS its confirmation — so a repeat
        // confirm must be a no-op (nothing is awaiting), and the
        // original must not silently re-retire.
        let model = VideoScanModel()
        let (original, repair) = makeLifecyclePair(model: model)
        #expect(model.confirmRepair(repairID: repair.id))
        #expect(model.unsupersede(id: original.id))

        let notesBefore = repair.notes
        #expect(!model.confirmRepair(repairID: repair.id),
                "a confirmed repair is not awaiting — reconfirm no-ops")
        #expect(!original.isSuperseded, "the manual restore sticks")
        #expect(repair.notes == notesBefore, "no duplicate Confirm stamp")
        #expect(pfActiveRecords(model.records).count == 2,
                "both records visible after the restore")
    }
}

// MARK: - 4. Superseded-visibility audit — all 8 documented call sites

@MainActor
@Suite("RepairLifecycle — superseded visibility audit")
struct SupersededVisibilityAuditTests {

    /// The 8 pfActiveRecords call sites documented in PLAN-132 §1.
    /// Correlator + DuplicateDetector have functional sensors
    /// (RepairLifecycleFilterTests); TriageView / ArchiveView /
    /// WorkbenchView / VolumeCompare consume it inside private SwiftUI
    /// computed vars with no headless seam — for those this source-scan
    /// sensor pins that the surface still routes through the ONE
    /// predicate whose superseded-exclusion is unit-tested. If a site is
    /// refactored away from pfActiveRecords, this fails and the
    /// visibility audit must be redone by hand.
    private static let auditedCallSites: [(file: String, minCount: Int)] = [
        ("Correlator.swift", 1),
        ("DuplicateDetector.swift", 1),
        ("TriageView.swift", 1),
        ("ArchiveView.swift", 1),
        ("WorkbenchView.swift", 1),
        ("VolumeCompare.swift", 2),     // per-record backups + runCompare
        ("VideoScanModel+Duplicates.swift", 1),
        ("VideoScanModel+VolumeLifecycle.swift", 1),
    ]

    @Test func allEightDocumentedCallSitesRouteThroughPfActiveRecords() throws {
        let appSources = URL(fileURLWithPath: #filePath)   // …/VideoScanTests/this
            .deletingLastPathComponent()                    // …/VideoScanTests
            .deletingLastPathComponent()                    // …/VideoScan (project dir)
            .appendingPathComponent("VideoScan")            // …/VideoScan/VideoScan
        for site in Self.auditedCallSites {
            let url = appSources.appendingPathComponent(site.file)
            let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                      "\(site.file) missing — the pfActiveRecords visibility audit list is stale; re-audit and update this sensor")
            let count = source.components(separatedBy: "pfActiveRecords(").count - 1
            #expect(count >= site.minCount,
                    "\(site.file) no longer routes through pfActiveRecords (\(count) < \(site.minCount)) — superseded records may leak into this surface; re-audit")
        }
    }

    @Test func deltaDuplicateAnalysisNeverExaminesSupersededRecords() async {
        // Functional smoke for the VideoScanModel+Duplicates:48 site —
        // the model-level delta pass (distinct from the DuplicateDetector
        // sensor, which pins the detector's own input filter).
        func twin(_ name: String, dir: String) -> VideoRecord {
            let r = VideoRecord()
            r.filename = name
            r.fullPath = dir + "/" + name
            r.directory = dir
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            r.partialMD5 = "cafef00d"
            r.sizeBytes = 9_000
            r.durationSeconds = 60
            r.isPlayable = "Yes"
            return r
        }
        let model = VideoScanModel()
        let live1 = twin("clone.mov", dir: "/vol/a")
        let live2 = twin("clone.mov", dir: "/vol/b")
        let retired = twin("clone.mov", dir: "/vol/c")
        retired.supersededByID = UUID()
        model.records = [live1, live2, retired]

        await model.analyzeDuplicates()

        #expect(live1.duplicateGroupID != nil && live1.duplicateGroupID == live2.duplicateGroupID,
                "fixture sanity: the live twins group")
        #expect(retired.duplicateGroupID == nil,
                "a superseded record must never enter a duplicate group via the delta pass")
        #expect(retired.duplicateDisposition == DuplicateDisposition.none)
        #expect(retired.dupAnalyzedAt == nil,
                "the delta pass must not even examine (stamp) a superseded record")
    }
}

// MARK: - 5. Scale — the commit-5 gap (pfAwaitingConfirmation @ 100k)

@MainActor
@Suite("RepairLifecycle — lifecycle filters at 100k", .serialized)
struct RepairLifecycleScaleGapTests {

    /// One Rick-shaped 100k corpus, both lifecycle predicates measured.
    /// Budgets asserted in Release only (Debug timing is not a perf
    /// measurement); the correctness pass always runs. Complements the
    /// pfApplySupersededFilter budget in RepairLifecycleFilterTests —
    /// this covers the two predicates that commit 5 left unmeasured:
    /// the WIDENED pfActiveRecords and the worklist filter.
    @Test func activeAndWorklistFiltersHoldTheirBudgetsAt100k() {
        let clock = ContinuousClock()
        let corpus = CatalogSearchProfileBench.makeRickShapedCorpus(100_000)
        // The Rick-shaped generator already marks some records inert
        // (set-aside pollution etc.) — count the baseline so the
        // expected totals stay honest if the corpus recipe evolves.
        let preInert = corpus.reduce(into: 0) {
            if $1.isPurged || $1.isSetAside || $1.isSuperseded { $0 += 1 }
        }
        let preAwaiting = corpus.reduce(into: 0) {
            if $1.isAwaitingConfirmation { $0 += 1 }
        }
        var newlyInert = 0
        for (i, rec) in corpus.enumerated() {
            let wasInert = rec.isPurged || rec.isSetAside || rec.isSuperseded
            if i % 100 == 0 {                                          // 1,000
                rec.supersededByID = UUID()
                if !wasInert { newlyInert += 1 }
            } else if i % 200 == 1 {                                    //   500
                rec.derivedFrom = UUID()
                rec.derivationKind = "rebuildAudio"
            } else if i % 200 == 3 {                                    //   500
                rec.purgedAt = Date()
                if !wasInert { newlyInert += 1 }
            } else if i % 200 == 7 {                                    //   500
                rec.setAsideReason = "still"
                if !wasInert { newlyInert += 1 }
            }
        }
        let expectedActive = corpus.count - preInert - newlyInert
        let expectedAwaiting = preAwaiting + 500

        var active: [VideoRecord] = []
        var worklist: [VideoRecord] = []
        var activeTimes: [Double] = []
        var worklistTimes: [Double] = []
        for _ in 0..<5 {
            let tA = clock.measure { active = pfActiveRecords(corpus) }
            activeTimes.append(CatalogSearchBudgetSensorTests.ms(tA))
            let tW = clock.measure { worklist = corpus.filter(pfAwaitingConfirmation) }
            worklistTimes.append(CatalogSearchBudgetSensorTests.ms(tW))
        }
        let activeMs = CatalogSearchBudgetSensorTests.median(activeTimes)
        let worklistMs = CatalogSearchBudgetSensorTests.median(worklistTimes)
        print(String(format: "[#132-sensor] pfActiveRecords_ms=%.1f pfAwaitingConfirmation_ms=%.1f n=%d",
                     activeMs, worklistMs, corpus.count))

        #expect(active.count == expectedActive,
                "active = 100k − baseline inert (\(preInert)) − newly retired/purged/set-aside (\(newlyInert))")
        #expect(active.allSatisfy { !$0.isSuperseded && !$0.isPurged && !$0.isSetAside })
        #expect(worklist.count == expectedAwaiting)
        #expect(worklist.allSatisfy { $0.isAwaitingConfirmation })
        #if !DEBUG
        #expect(activeMs <= 50,
                "pfActiveRecords took \(activeMs) ms at 100k — budget 50 ms (three booleans per record)")
        #expect(worklistMs <= 50,
                "pfAwaitingConfirmation took \(worklistMs) ms at 100k — budget 50 ms")
        #endif
    }
}
