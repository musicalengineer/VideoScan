// CorrelateLedgerTests.swift
// Analysis-ledger semantics for correlation (docs/analysis_ledger_design.md,
// Rick's directive 2026-07-05): derived relations are computed once and
// preserved; "Correlate All" processes the DELTA (unpaired orphans), never
// the world; full recompute exists only as an explicit, separate action.
//
// RED (pre-fix): correlate() clears prior pairing for its whole scope
// (CorrelationScorer.resolveCorrelateScope) and re-derives everything —
// destroying manual pairs the scorer can't re-create and reassigning
// pairs the user already had. GREEN: Correlate All preserves existing
// pairs and scores only unpaired records; clearAndRecorrelateAll() is
// the explicit from-scratch action.

import Testing
import Foundation
@testable import VideoScan

@Suite(.serialized) @MainActor
struct CorrelateLedgerTests {

    private func makeAV(filenameV: String, filenameA: String,
                        duration: Double = 30.0,
                        dir: String = "/vol/media") -> (VideoRecord, VideoRecord) {
        let v = VideoRecord()
        v.filename = filenameV
        v.fullPath = dir + "/" + filenameV
        v.streamTypeRaw = StreamType.videoOnly.rawValue
        v.durationSeconds = duration
        v.directory = dir
        let a = VideoRecord()
        a.filename = filenameA
        a.fullPath = dir + "/" + filenameA
        a.streamTypeRaw = StreamType.audioOnly.rawValue
        a.durationSeconds = duration + 0.2
        a.directory = dir
        return (v, a)
    }

    /// A pairing the SCORER would never produce (nothing matches — the
    /// user made it by hand via Repair Video / manual pairing).
    private func makeManualPair() -> (VideoRecord, VideoRecord) {
        let v = VideoRecord()
        v.filename = "christmas_master_video.mov"
        v.fullPath = "/volX/masters/christmas_master_video.mov"
        v.streamTypeRaw = StreamType.videoOnly.rawValue
        v.durationSeconds = 0
        v.directory = "/volX/masters"
        let a = VideoRecord()
        a.filename = "totally_unrelated_name.wav"
        a.fullPath = "/volY/audio/totally_unrelated_name.wav"
        a.streamTypeRaw = StreamType.audioOnly.rawValue
        a.durationSeconds = 0
        a.directory = "/volY/audio"
        let gid = UUID()
        v.pairedWith = a; v.pairGroupID = gid; v.pairConfidence = .high
        a.pairedWith = v; a.pairGroupID = gid; a.pairConfidence = .high
        return (v, a)
    }

    // MARK: - 1. Correlate All preserves existing pairs

    @Test func correlateAllPreservesManualPairs() async {
        let model = VideoScanModel()
        let (mv, ma) = makeManualPair()
        let originalGID = mv.pairGroupID
        // Plus one fresh orphan pair the correlator SHOULD match.
        let (nv, na) = makeAV(filenameV: "V01AB23.mxf", filenameA: "A01AB23.mxf")
        model.records = [mv, ma, nv, na]

        await model.correlate()

        #expect(mv.pairedWith === ma,
                "A manual pair the scorer can't re-create must SURVIVE Correlate All (RED pre-fix: wiped by resolveCorrelateScope, never re-paired)")
        #expect(mv.pairGroupID == originalGID,
                "The surviving pair keeps its identity — not wiped and re-derived")
        #expect(nv.pairedWith === na, "The new orphans still get matched")
    }

    // MARK: - 2. Correlate All never steals a partner from an existing pair

    @Test func correlateAllDoesNotReassignExistingPairs() async {
        let model = VideoScanModel()
        // v1↔a1 exists (medium evidence). a2 is a BETTER match for v1 by
        // score (same key, closer duration, same dir) — but v1 is taken.
        let (v1, a1) = makeAV(filenameV: "V0FF11.mxf", filenameA: "A0FF11.mxf",
                              duration: 30.0)
        a1.durationSeconds = 32.0   // outside duration tolerance — the
                                    // existing pair scores LOWER than a2
        let gid = UUID()
        v1.pairedWith = a1; v1.pairGroupID = gid; v1.pairConfidence = .medium
        a1.pairedWith = v1; a1.pairGroupID = gid; a1.pairConfidence = .medium
        let a2 = VideoRecord()
        a2.filename = "A0FF11.mxf"     // same correlation key as v1
        a2.fullPath = "/vol/media/copy/A0FF11.mxf"
        a2.streamTypeRaw = StreamType.audioOnly.rawValue
        a2.durationSeconds = 30.0      // perfect duration match
        a2.directory = v1.directory    // same dir — higher score than a1
        model.records = [v1, a1, a2]

        await model.correlate()

        #expect(v1.pairedWith === a1,
                "An existing pair is settled history — Correlate All must not re-open it because a 'better' candidate appeared (RED pre-fix: wipe + greedy reassign)")
        #expect(a2.pairedWith == nil,
                "The newcomer stays unmatched rather than stealing a settled partner")
    }

    // MARK: - 3. Explicit selection still re-pairs (user intent is explicit)

    @Test func correlateSelectedStillRepairsThatSubset() async {
        let model = VideoScanModel()
        let (v, a) = makeAV(filenameV: "V0AA77.mxf", filenameA: "A0AA77.mxf")
        // Pre-paired WRONGLY (to each other but user wants a redo of these two).
        let gid = UUID()
        v.pairedWith = a; v.pairGroupID = gid; v.pairConfidence = .low
        a.pairedWith = v; a.pairGroupID = gid; a.pairConfidence = .low
        model.records = [v, a]

        await model.correlate(selectedIDs: [v.id, a.id])

        // Selection = explicit "redo THESE": pairing rebuilt (fresh gid ok),
        // confidence re-derived from evidence.
        #expect(v.pairedWith === a)
        #expect(v.pairConfidence != nil)
    }

    // MARK: - 4. The explicit from-scratch action still exists

    @Test func clearAndRecorrelateAllRebuildsEverything() async {
        let model = VideoScanModel()
        let (mv, ma) = makeManualPair()     // scorer can't re-create this
        let (nv, na) = makeAV(filenameV: "V01AB23.mxf", filenameA: "A01AB23.mxf")
        model.records = [mv, ma, nv, na]

        await model.clearAndRecorrelateAll()

        #expect(mv.pairedWith == nil,
                "Clear & Re-correlate wipes even manual pairs — that's its explicit job")
        #expect(nv.pairedWith === na, "…and rebuilds evidence-based pairs")
    }

    // MARK: - 5b. Selected redo frees the unselected partner (QA P1-2)

    @Test func correlateSelectedClearsPartnerBackReferenceOutsideSelection() async {
        let model = VideoScanModel()
        let (v, a) = makeAV(filenameV: "V0EE55.mxf", filenameA: "A0EE55.mxf")
        let gid = UUID()
        v.pairedWith = a; v.pairGroupID = gid; v.pairConfidence = .low
        a.pairedWith = v; a.pairGroupID = gid; a.pairConfidence = .low
        model.records = [v, a]

        // Redo ONLY the video: with no candidates in scope it stays
        // unpaired — and the audio must NOT dangle at the old instance.
        await model.correlate(selectedIDs: [v.id])

        #expect(v.pairedWith == nil, "Selected record cleared and (no candidates in scope) unpaired")
        #expect(a.pairedWith == nil,
                "The unselected partner's back-reference must be freed — a dangling 'settled' partner can never re-pair under the incremental ledger (QA P1-2)")
        #expect(a.pairGroupID == nil && a.pairConfidence == nil)
    }

    // MARK: - 6. Avid cross-volume correlator under the ledger

    private func makeAvid(_ name: String, dir: String, video: Bool,
                          size: Int64 = 1000) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = dir + "/" + name
        r.directory = dir
        r.streamTypeRaw = (video ? StreamType.videoOnly : StreamType.audioOnly).rawValue
        r.sizeBytes = size
        r.isPlayable = "Yes"
        return r
    }

    @Test func avidCorrelatePreservesExistingPairsAndSkipsTheirClips() async {
        let model = VideoScanModel()
        // Clip 14D1BBD3F: v1↔a1 already paired (an earlier run picked
        // them); worse copies v2/a2 of the SAME clip exist unpaired.
        let v1 = makeAvid("00001.V14D1BBD3F.mxf", dir: "/volA", video: true, size: 9000)
        let a1 = makeAvid("00001.A14D1BBD3F.mxf", dir: "/volA", video: false, size: 9000)
        let gid = UUID()
        v1.pairedWith = a1; v1.pairGroupID = gid; v1.pairConfidence = .high
        a1.pairedWith = v1; a1.pairGroupID = gid; a1.pairConfidence = .high
        let v2 = makeAvid("00002.V14D1BBD3F.mxf", dir: "/volB", video: true, size: 100)
        let a2 = makeAvid("00002.A14D1BBD3F.mxf", dir: "/volB", video: false, size: 100)
        // A brand-new clip that SHOULD get paired.
        let nv = makeAvid("00003.VAAAA1111.mxf", dir: "/volC", video: true)
        let na = makeAvid("00003.AAAAA1111.mxf", dir: "/volC", video: false)
        model.records = [v1, a1, v2, a2, nv, na]

        await model.correlateAcrossVolumes()

        #expect(v1.pairedWith === a1 && v1.pairGroupID == gid,
                "An existing pair is settled — the Avid pass must not wipe and re-derive it (RED pre-fix: cleared all pairs first)")
        #expect(v2.pairedWith == nil && a2.pairedWith == nil,
                "Duplicate copies of an already-paired clip stay unpaired (one pair per clip, as before)")
        #expect(nv.pairedWith === na, "New clips still get paired")
    }

    @Test func avidCorrelatePairsBestUnpairedCopy() async {
        let model = VideoScanModel()
        // Two copies of a fresh clip — bigger one must win, same as legacy.
        let vBig = makeAvid("00001.VBB22CC33.mxf", dir: "/volA", video: true, size: 9000)
        let vSmall = makeAvid("00002.VBB22CC33.mxf", dir: "/volB", video: true, size: 10)
        let a = makeAvid("00001.ABB22CC33.mxf", dir: "/volA", video: false)
        model.records = [vBig, vSmall, a]

        await model.correlateAcrossVolumes()

        #expect(vBig.pairedWith === a, "Best copy (larger) wins the pairing")
        #expect(vSmall.pairedWith == nil)
    }
}

// MARK: - 5. Main thread stays responsive at scale (the beachball pin)
//
// Deliberately NOT @MainActor: the measurement loop must run OFF the
// main actor so each MainActor.run round-trip genuinely measures how
// long the main thread takes to become available. Pre-fix, the whole
// scoring loop runs on main and the worst hop is the full correlate
// duration; the HIG spins the beachball at ≈2 s of unresponsiveness.

@Suite(.serialized) struct CorrelateLedgerPerfTests {

    @Test func correlateAllKeepsMainThreadResponsiveAtScale() async throws {
        let model = await MainActor.run { () -> VideoScanModel in
            let m = VideoScanModel()
            // 6k video + 6k audio orphans across a handful of key/dir
            // pools so real scoring happens at realistic shape.
            var recs: [VideoRecord] = []
            recs.reserveCapacity(12_000)
            for i in 0..<6_000 {
                let v = VideoRecord()
                v.filename = String(format: "V%05X.mxf", i)
                v.fullPath = "/vol/pool\(i % 8)/" + v.filename
                v.streamTypeRaw = StreamType.videoOnly.rawValue
                v.durationSeconds = Double(30 + i % 50)
                v.directory = "/vol/pool\(i % 8)"
                let a = VideoRecord()
                a.filename = String(format: "A%05X.mxf", i)
                a.fullPath = "/vol/pool\(i % 8)/" + a.filename
                a.streamTypeRaw = StreamType.audioOnly.rawValue
                a.durationSeconds = Double(30 + i % 50) + 0.2
                a.directory = "/vol/pool\(i % 8)"
                recs.append(v); recs.append(a)
            }
            m.records = recs
            return m
        }

        let correlateTask = Task { @MainActor in
            await model.correlate()
        }
        try await Task.sleep(nanoseconds: 50_000_000)   // let it start
        var worstHop: Double = 0
        for _ in 0..<10 {
            // SuspendingClock: hop bound must not tick across machine sleep.
            let t0 = SuspendingClock.now
            await MainActor.run {}                       // round-trip through main
            let elapsed = SuspendingClock.now - t0
            let hop = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            worstHop = max(worstHop, hop)
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        await correlateTask.value
        #expect(worstHop < 0.5,
                "Main actor must stay responsive during Correlate All (worst hop \(String(format: "%.3f", worstHop))s; HIG beachball threshold ≈ 2 s, budget 0.5 s)")
        let paired = await MainActor.run { model.records.contains { $0.pairedWith != nil } }
        #expect(paired, "…and the correlation actually happened")
    }
}
