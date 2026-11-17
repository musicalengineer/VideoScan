// RepairLifecycleFilterTests.swift
// LOGIC + SCALE + SENSOR dimensions for the superseded visibility filter
// (GH #132 Commit 2): superseded originals hidden from default views,
// revealed by the session-scoped "Show superseded" toggle, excluded from
// correlate/dup candidacy, but INCLUDED in exports (provenance must stay
// readable years from now).
//
// Patterns: CatalogPurgeTests (composition + correlator/dup sensors),
// CatalogSetAsideMigrationTests (badge base), CatalogSearchBudgetSensor-
// Tests (100k scale budget).

import Combine
import Testing
import Foundation
@testable import VideoScan

@MainActor
@Suite("RepairLifecycle — superseded filters")
struct RepairLifecycleFilterTests {

    private func makeRecord(
        name: String,
        purged: Bool = false,
        setAside: Bool = false,
        supersededBy: UUID? = nil
    ) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/T/\(name)"
        r.directory = "/Volumes/T"
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        if purged { r.purgedAt = Date() }
        if setAside { r.setAsideReason = "still-image" }
        r.supersededByID = supersededBy
        return r
    }

    // MARK: Composition

    @Test func supersededFilterHidesByDefaultAndRevealsOnToggle() {
        let normal = makeRecord(name: "a.mov")
        let superseded = makeRecord(name: "old.mov", supersededBy: UUID())
        let all = [normal, superseded]

        #expect(pfApplySupersededFilter(all, showSuperseded: false).map(\.filename) == ["a.mov"])
        #expect(pfApplySupersededFilter(all, showSuperseded: true).count == 2,
                "reveal toggle is a pure inclusion")
        #expect(pfSupersededRecords(all).map(\.filename) == ["old.mov"])
    }

    @Test func threeHiddenStatesComposeIndependently() {
        let active = makeRecord(name: "active.mov")
        let purged = makeRecord(name: "purged.mov", purged: true)
        let aside = makeRecord(name: "aside.jpg", setAside: true)
        let superseded = makeRecord(name: "old.mov", supersededBy: UUID())
        let all = [active, purged, aside, superseded]

        // pfActiveRecords excludes all three inert states.
        #expect(pfActiveRecords(all).map(\.filename) == ["active.mov"])

        // Each toggle reveals ONLY its own state.
        let showSupersededOnly = pfApplySupersededFilter(
            pfApplySetAsideFilter(
                pfApplyPurgeFilter(all, showRemoved: false),
                showSetAside: false),
            showSuperseded: true)
        #expect(showSupersededOnly.map(\.filename) == ["active.mov", "old.mov"],
                "Show superseded must not reveal purged or set-aside rows")

        let showRemovedOnly = pfApplySupersededFilter(
            pfApplySetAsideFilter(
                pfApplyPurgeFilter(all, showRemoved: true),
                showSetAside: false),
            showSuperseded: false)
        #expect(showRemovedOnly.map(\.filename) == ["active.mov", "purged.mov"],
                "Show removed must not reveal superseded rows")
    }

    @Test func exportsCarrySupersededRecords() {
        // SENSOR: superseded records travel in exports/backups WITH their
        // marker — provenance readable years from now. Only purged stays
        // local (the "local trash never travels" policy).
        let active = makeRecord(name: "active.mov")
        let purged = makeRecord(name: "purged.mov", purged: true)
        let superseded = makeRecord(name: "old.mov", supersededBy: UUID())
        let exportable = pfExportableRecords([active, purged, superseded])
        #expect(exportable.map(\.filename) == ["active.mov", "old.mov"],
                "pfExportableRecords must carry superseded originals and drop purged only")
    }

    @Test func searchBadgeBaseMatchesComputeFilteredOrder() {
        let active = makeRecord(name: "clip.mov")
        let superseded = makeRecord(name: "clip_old.mov", supersededBy: UUID())
        let all = [active, superseded]

        let defaultBase = pfSearchBadgeBase(all,
                                            showRemoved: false, showSetAside: false,
                                            showSuperseded: false)
        #expect(defaultBase.map(\.filename) == ["clip.mov"],
                "the badge must never count rows the default table hides")

        let revealBase = pfSearchBadgeBase(all,
                                           showRemoved: false, showSetAside: false,
                                           showSuperseded: true)
        #expect(revealBase.count == 2)
    }

    @Test func awaitingConfirmationPredicateMatchesDerivedFlag() {
        let repair = makeRecord(name: "fixed.mov")
        repair.derivedFrom = UUID()
        repair.derivationKind = "rebuildAudio"
        #expect(pfAwaitingConfirmation(repair))
        repair.repairConfirmedDate = Date()
        #expect(!pfAwaitingConfirmation(repair))
        #expect(!pfAwaitingConfirmation(makeRecord(name: "plain.mov")))
    }

    // MARK: Correlate / dup candidacy sensors

    @Test func correlatorSkipsSupersededRecords() {
        // Same scenario as CatalogPurgeTests test 15, with supersede as
        // the hiding state: a superseded audio counterpart must be
        // invisible to pairing.
        let video = makeRecord(name: "shot.mxf")
        video.fullPath = "/Volumes/V1/shot.mxf"
        video.streamTypeRaw = StreamType.videoOnly.rawValue
        video.durationSeconds = 10.0

        let audio = makeRecord(name: "shot.wav", supersededBy: UUID())
        audio.fullPath = "/Volumes/V1/shot.wav"
        audio.streamTypeRaw = StreamType.audioOnly.rawValue
        audio.durationSeconds = 10.0

        _ = Correlator.correlate(records: [video, audio])

        #expect(video.pairedWith == nil,
                "Active video must not be paired when its only partner is superseded")
        #expect(audio.pairedWith == nil,
                "Superseded audio must not be paired with anything")
        #expect(audio.pairConfidence == nil)
    }

    @Test func duplicateDetectorIgnoresSupersededDuplicates() {
        func mkClone(name: String, path: String, supersededBy: UUID? = nil) -> VideoRecord {
            let r = VideoRecord()
            r.filename = name
            r.fullPath = path
            r.directory = (path as NSString).deletingLastPathComponent
            r.partialMD5 = "deadbeefcafe"
            r.sizeBytes = 12_345_678
            r.durationSeconds = 60.0
            r.dateCreatedRaw = Date(timeIntervalSince1970: 1_700_000_000)
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            r.supersededByID = supersededBy
            return r
        }
        let liveA = mkClone(name: "clone.mov", path: "/Volumes/V1/clone.mov")
        let liveB = mkClone(name: "clone.mov", path: "/Volumes/V2/clone.mov")
        let retired = mkClone(name: "clone.mov", path: "/Volumes/V3/clone.mov",
                              supersededBy: UUID())

        _ = DuplicateDetector.analyze(records: [liveA, liveB, retired])

        #expect(retired.duplicateGroupID == nil,
                "Superseded record must not be assigned to a duplicate group")
        #expect(retired.duplicateDisposition == .none)
        #expect(retired.duplicateConfidence == nil)
    }

    // MARK: Un-supersede (restore path)

    @Test func unsupersedeClearsMarkerAndReturnsRecordToActive() {
        let model = VideoScanModel()
        let original = makeRecord(name: "old.mov", supersededBy: UUID())
        model.records = [original]

        #expect(model.unsupersede(id: original.id))
        #expect(original.supersededByID == nil)
        #expect(pfActiveRecords(model.records).count == 1)

        // Idempotent + honest return: second call is a no-op.
        #expect(!model.unsupersede(id: original.id))
        // Bogus id is a no-op too.
        #expect(!model.unsupersede(id: UUID()))
    }
}

// MARK: - Awaiting-confirmation worklist (GH #132 P3)

@MainActor
@Suite("RepairLifecycle — awaiting-confirmation worklist")
struct AwaitingConfirmationWorklistTests {

    private func makeRepair(name: String, confirmed: Bool) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/T/\(name)"
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.derivedFrom = UUID()
        r.derivationKind = "rebuildAudio"
        if confirmed { r.repairConfirmedDate = Date() }
        return r
    }

    @Test func worklistComposesWithTheHiddenStateFilters() {
        // The hidden-state order: purge → set-aside → superseded, then the
        // awaiting rule. An awaiting repair passes; a confirmed repair, a
        // plain record, and a superseded original (its repair confirmed) do not.
        let awaiting = makeRepair(name: "a_RepairedAudio.mov", confirmed: false)
        let confirmed = makeRepair(name: "b_RepairedAudio.mov", confirmed: true)
        let plain = VideoRecord()
        plain.filename = "plain.mov"
        plain.fullPath = "/Volumes/T/plain.mov"
        plain.streamTypeRaw = StreamType.videoAndAudio.rawValue
        let supersededOriginal = VideoRecord()
        supersededOriginal.filename = "b.mov"
        supersededOriginal.fullPath = "/Volumes/T/b.mov"
        supersededOriginal.streamTypeRaw = StreamType.videoAndAudio.rawValue
        supersededOriginal.supersededByID = confirmed.id

        let all = [awaiting, confirmed, plain, supersededOriginal]
        var out = pfApplyPurgeFilter(all, showRemoved: false)
        out = pfApplySetAsideFilter(out, showSetAside: false)
        out = pfApplySupersededFilter(out, showSuperseded: false)
        out = out.filter(pfAwaitingConfirmation)

        #expect(out.map(\.filename) == ["a_RepairedAudio.mov"],
                "the worklist shows exactly the repairs waiting for Rick's OK")

        // Even with Show superseded ON, the worklist keeps only
        // awaiting repairs — a retired original is not awaiting anything.
        var revealed = pfApplySupersededFilter(all, showSuperseded: true)
        revealed = revealed.filter(pfAwaitingConfirmation)
        #expect(revealed.map(\.filename) == ["a_RepairedAudio.mov"])
    }

    @Test func worklistDrainsAsRepairsAreConfirmed() {
        let model = VideoScanModel()
        let original = VideoRecord()
        original.filename = "tape.mov"
        original.fullPath = "/Volumes/T/tape.mov"
        let repair = makeRepair(name: "tape_RepairedAudio.mov", confirmed: false)
        repair.derivedFrom = original.id
        model.records = [original, repair]

        #expect(model.records.filter(pfAwaitingConfirmation).count == 1)
        #expect(model.confirmRepair(repairID: repair.id))
        #expect(model.records.filter(pfAwaitingConfirmation).isEmpty,
                "confirming removes the repair from the worklist")
    }

    // MARK: The list in the Media File Operations window (2026-11-17)
    //
    // The awaiting-confirmation list left the Catalog's Show menu; the MFO
    // window shows it from RepairsAwaitingConfirmationStore.

    private func plain(_ name: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/T/\(name)"
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        return r
    }

    @Test("LOGIC: the MFO list is the awaiting rule over live rows — each waiting repair once, in catalog order, naming its original")
    func theWaitingListIsTheAwaitingRuleOverLiveRows() {
        typealias Store = RepairsAwaitingConfirmationStore
        let tape = plain("tape.mov"), reel = plain("reel.mov")
        let waiting = makeRepair(name: "tape_RepairedAudio.mov", confirmed: false)
        waiting.derivedFrom = tape.id
        let adopted = makeRepair(name: "reel_fixed_elsewhere.mov", confirmed: false)
        adopted.derivedFrom = reel.id
        adopted.derivationKind = "externalRepair"
        let done = makeRepair(name: "done_RepairedAudio.mov", confirmed: true)
        let trimmed = plain("tape_trim.mov")
        trimmed.derivedFrom = tape.id
        trimmed.derivationKind = "trim"
        let orphan = makeRepair(name: "orphan_RepairedAudio.mov", confirmed: false)   // its original is not in the catalog
        let trashed = makeRepair(name: "trashed_RepairedAudio.mov", confirmed: false)
        trashed.derivedFrom = tape.id
        trashed.purgedAt = Date()
        let aside = makeRepair(name: "aside_RepairedAudio.mov", confirmed: false)
        aside.derivedFrom = tape.id
        aside.setAsideReason = "still-image"
        let replaced = makeRepair(name: "replaced_RepairedAudio.mov", confirmed: false)
        replaced.derivedFrom = tape.id
        replaced.supersededByID = UUID()
        let all = [tape, waiting, reel, done, trimmed, adopted, orphan, trashed, aside, replaced]

        let items = Store.items(in: all)
        #expect(items.map(\.filename) == ["tape_RepairedAudio.mov", "reel_fixed_elsewhere.mov", "orphan_RepairedAudio.mov"])
        #expect(items.map(\.id) == [waiting.id, adopted.id, orphan.id])
        #expect(items.map(\.originalName) == ["tape.mov", "reel.mov", nil])
        #expect(items.map(\.canConfirm) == [true, true, false], "a copy whose original is gone offers no confirm (the engine refuses it)")
        // ONE rule: every item is a record pfAwaitingConfirmation names, and every live one it names is an item.
        let live = all.filter { pfAwaitingConfirmation($0) && !$0.isPurged && !$0.isSetAside && !$0.isSuperseded }
        #expect(items.map(\.id) == live.map(\.id))
        // Every row that offers Sounds Good is one the engine accepts; the orphan is the one it skips.
        let model = VideoScanModel()
        model.records = all
        #expect(model.confirmRepairs(repairIDs: Set(items.map(\.id))) == items.filter(\.canConfirm).count)
        #expect(RepairsAwaitingConfirmationStore.items(in: model.records).map(\.id) == [orphan.id])
        // Words.
        #expect(Store.title(count: 1) == "1 repaired copy is waiting for you to confirm it")
        #expect(Store.title(count: 3) == "3 repaired copies are waiting for you to confirm them")
        #expect(Store.replaces("tape.mov") == "replaces tape.mov")
        #expect(Store.replaces(nil).contains("cannot be confirmed"))
        #expect(Store.items(in: []).isEmpty)
    }

    @Test("LOGIC: Sounds Good from the MFO list is the one confirm engine — the row leaves, the original is superseded, undo brings it back")
    func theListDrainsThroughTheOneEngine() {
        let model = VideoScanModel()
        let original = plain("tape.mov")
        let repair = makeRepair(name: "tape_RepairedAudio.mov", confirmed: false)
        repair.derivedFrom = original.id
        model.records = [original, repair]
        let store = RepairsAwaitingConfirmationStore()
        var publishes = 0
        let watch = store.$items.dropFirst().sink { _ in publishes += 1 }
        defer { watch.cancel() }

        store.refresh(from: model.records)
        #expect(store.items.map(\.id) == [repair.id] && publishes == 1)
        store.refresh(from: model.records)
        #expect(publishes == 1, "an unchanged list is not published again")

        // What the section's button does.
        #expect(model.confirmRepairs(repairIDs: [repair.id]) == 1)
        store.refresh(from: model.records)
        #expect(store.items.isEmpty && publishes == 2)
        #expect(original.supersededByID == repair.id && repair.repairConfirmedDate != nil, "the engine's own stamps")
        #expect(original.purgedAt == nil, "the original is hidden, never removed")

        // The Catalog's undo banner puts the repair back on the list.
        #expect(model.undoConfirmRepair())
        store.refresh(from: model.records)
        #expect(store.items.map(\.id) == [repair.id])
    }

    @Test("ISOLATION: poisoned repair records — a copy derived from itself, the same row twice, an unknown kind — never crash or duplicate a row")
    func poisonedWaitingRecords() {
        typealias Store = RepairsAwaitingConfirmationStore
        let selfDerived = makeRepair(name: "self.mov", confirmed: false)
        selfDerived.derivedFrom = selfDerived.id
        #expect(Store.items(in: [selfDerived]).map(\.originalName) == ["self.mov"])
        let unknownKind = makeRepair(name: "odd.mov", confirmed: false)
        unknownKind.derivationKind = "not-a-kind"
        let noKind = makeRepair(name: "nokind.mov", confirmed: false)
        noKind.derivationKind = nil
        #expect(Store.items(in: [unknownKind, noKind]).isEmpty)
        // Two originals carrying the same id (a catalog that holds a row twice): one name is used, nothing traps.
        let original = plain("tape.mov")
        let repair = makeRepair(name: "tape_RepairedAudio.mov", confirmed: false)
        repair.derivedFrom = original.id
        let items = Store.items(in: [original, original, repair])
        #expect(items.count == 1 && items[0].originalName == "tape.mov")
        // An empty name is still a row.
        let nameless = makeRepair(name: "", confirmed: false)
        #expect(Store.items(in: [nameless]).count == 1)
    }

    @Test("SCALE: the MFO list over 100k records — one pass, inside the budget, with and without waiting repairs")
    func waitingListAt100k() {
        let corpus = CatalogSearchProfileBench.makeRickShapedCorpus(100_000)
        var t0 = Date()
        #expect(RepairsAwaitingConfirmationStore.items(in: corpus).isEmpty)
        var elapsed = Date().timeIntervalSince(t0)
        #expect(elapsed < PerformanceLane.debugCeiling(seconds: 0.5), "no repairs waiting: \(elapsed)s for 100k records")
        // 200 repairs wait (far more than a real catalog holds), each derived from another record.
        for i in 0..<200 {
            let repair = corpus[i * 400 + 1]
            repair.derivedFrom = corpus[i * 400].id
            repair.derivationKind = "rebuildAudio"
            repair.purgedAt = nil
            repair.setAsideReason = nil
            repair.supersededByID = nil
        }
        t0 = Date()
        let items = RepairsAwaitingConfirmationStore.items(in: corpus)
        elapsed = Date().timeIntervalSince(t0)
        #expect(items.count == 200)
        #expect(items.filter(\.canConfirm).count == 200)
        #expect(elapsed < PerformanceLane.debugCeiling(seconds: 0.5), "200 waiting: \(elapsed)s for 100k records")
    }
}

// MARK: - Scale (100k) — checklist dimension 2

@MainActor
@Suite("RepairLifecycle — superseded filter at scale", .serialized)
struct RepairLifecycleFilterScaleTests {

    /// The new filter iterates `records`, so it gets the 100k budget
    /// treatment (Rick-shaped corpus, same generator as the #123
    /// sensors). Budget asserted in Release only — Debug timing is not a
    /// perf measurement — but the pass always runs for correctness.
    @Test func supersededFilterBudgetAt100k() {
        let clock = ContinuousClock()
        let corpus = CatalogSearchProfileBench.makeRickShapedCorpus(100_000)
        // Retire a deterministic 1% — repairs are rare relative to the
        // catalog, but the filter cost is per-record regardless.
        for (i, rec) in corpus.enumerated() where i % 100 == 0 {
            rec.supersededByID = UUID()
        }

        var filtered: [VideoRecord] = []
        var times: [Double] = []
        for _ in 0..<5 {
            let t = clock.measure {
                filtered = pfApplySupersededFilter(corpus, showSuperseded: false)
            }
            times.append(CatalogSearchBudgetSensorTests.ms(t))
        }
        let settled = CatalogSearchBudgetSensorTests.median(times)
        print(String(format: "[#132-sensor] supersededFilter_ms=%.1f n=%d hidden=%d",
                     settled, corpus.count, corpus.count - filtered.count))

        #expect(filtered.count == corpus.count - 1_000)
        #expect(pfActiveRecords(corpus).allSatisfy { !$0.isSuperseded })
        #if !DEBUG
        #expect(settled <= 50,
                "pfApplySupersededFilter took \(settled) ms at 100k — budget 50 ms (one boolean per record)")
        #endif
    }
}
