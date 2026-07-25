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
                                            showSuperseded: false, kindFacet: .everything)
        #expect(defaultBase.map(\.filename) == ["clip.mov"],
                "the badge must never count rows the default table hides")

        let revealBase = pfSearchBadgeBase(all,
                                           showRemoved: false, showSetAside: false,
                                           showSuperseded: true, kindFacet: .everything)
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

    @Test func viewFilterCaseExistsWithFriendlyLabel() {
        // The View-menu item is generated from allCases — pin the case,
        // its family-language label, and its icon.
        #expect(CatalogViewFilter.allCases.contains(.awaitingConfirmation))
        #expect(CatalogViewFilter.awaitingConfirmation.rawValue == "Repaired — Awaiting Confirmation")
        #expect(CatalogViewFilter.awaitingConfirmation.icon == "checkmark.seal")
    }

    @Test func worklistComposesWithTheHiddenStateFilters() {
        // computeFiltered()'s order: purge → set-aside → superseded →
        // kind facet → … → view filters. An awaiting repair passes; a
        // confirmed repair, a plain record, and a superseded original
        // (its repair confirmed) do not.
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
        out = pfApplyKindFacet(out, facet: .videoBearing)
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
