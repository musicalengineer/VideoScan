// DuplicateLedgerTests.swift
// Analysis-ledger semantics for duplicate detection
// (docs/analysis_ledger_design.md, 2026-07-05): dup groups are computed
// once and stamped (`dupAnalyzedAt`); "Analyze All" processes only the
// pending delta (new/invalidated records) plus the records they could
// possibly group with; an unchanged catalog is an instant no-op. The
// full-catalog recompute survives only as the explicit selected-subset
// redo (and Clear & Re-analyze).
//
// RED (pre-fix): analyzeDuplicates() cleared and re-derived EVERY
// group's identity on every click, never stamped anything, and ran the
// whole pass on the main thread.

import Testing
import Foundation
@testable import VideoScan

@Suite(.serialized) @MainActor
struct DuplicateLedgerTests {

    /// Two records with identical content signature (same md5+size+type)
    /// — the strongest dup evidence the detector recognizes.
    private func makeTwin(_ name: String, md5: String, size: Int64 = 5000,
                          dir: String = "/vol/a") -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = dir + "/" + name
        r.directory = dir
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.partialMD5 = md5
        r.sizeBytes = size
        r.durationSeconds = 60
        r.isPlayable = "Yes"
        return r
    }

    // MARK: - 1. No-op when nothing is pending

    @Test func analyzeAllIsInstantNoOpWhenEverythingIsStamped() async {
        let model = VideoScanModel()
        let a = makeTwin("tape1.mov", md5: "aaa")
        let b = makeTwin("tape1 copy.mov", md5: "aaa", dir: "/vol/b")
        model.records = [a, b]
        await model.analyzeDuplicates()          // first run: groups + stamps
        let gid = a.duplicateGroupID
        #expect(gid != nil && gid == b.duplicateGroupID, "Fixture sanity: twins grouped")

        await model.analyzeDuplicates()          // second run: NOTHING pending

        #expect(a.duplicateGroupID == gid,
                "An unchanged catalog must be a no-op — group identity preserved (RED pre-fix: clear() + re-derive minted a fresh UUID every click)")
    }

    // MARK: - 2. Records get stamped — including loners

    @Test func analyzeStampsEveryExaminedRecordIncludingUniques() async {
        let model = VideoScanModel()
        let loner = makeTwin("unique.mov", md5: "solo")
        model.records = [loner]

        await model.analyzeDuplicates()

        #expect(loner.dupAnalyzedAt != nil,
                "'Checked and found unique' must persist — otherwise every loner is re-examined forever (RED pre-fix: no stamp existed)")
        #expect(loner.duplicateGroupID == nil, "…and a loner still has no group")
    }

    // MARK: - 3. New records join existing groups without disturbing them

    @Test func newRecordJoinsExistingGroupIncrementally() async {
        let model = VideoScanModel()
        let a = makeTwin("xmas.mov", md5: "xyz")
        let b = makeTwin("xmas copy.mov", md5: "xyz", dir: "/vol/b")
        model.records = [a, b]
        await model.analyzeDuplicates()
        #expect(a.duplicateGroupID != nil, "Fixture sanity")

        // A third copy arrives from a new scan (unstamped = pending).
        let c = makeTwin("xmas copy 2.mov", md5: "xyz", dir: "/vol/c")
        model.records = [a, b, c]
        await model.analyzeDuplicates()

        #expect(c.duplicateGroupID != nil, "The newcomer must be grouped")
        #expect(c.duplicateGroupID == a.duplicateGroupID && a.duplicateGroupID == b.duplicateGroupID,
                "All three copies share ONE group after the incremental pass")
        #expect(a.duplicateGroupCount == 3 && c.duplicateGroupCount == 3,
                "Group count reflects the merged membership")
    }

    // MARK: - 4. Untouched groups elsewhere in the catalog stay untouched

    @Test func unrelatedGroupsAreNotReDerivedByAnIncrementalPass() async {
        let model = VideoScanModel()
        let a = makeTwin("montana.mov", md5: "mmm")
        let b = makeTwin("montana copy.mov", md5: "mmm", dir: "/vol/b")
        model.records = [a, b]
        await model.analyzeDuplicates()
        let gid = a.duplicateGroupID

        // A completely unrelated new file shows up.
        let unrelated = makeTwin("cape.mov", md5: "ccc")
        model.records = [a, b, unrelated]
        await model.analyzeDuplicates()

        #expect(a.duplicateGroupID == gid,
                "A pending record that can't touch this group must not cause its re-derivation (group identity is settled history)")
        #expect(unrelated.dupAnalyzedAt != nil, "…while the newcomer is examined and stamped")
    }

    // MARK: - 5. Explicit selection is still a forced redo

    @Test func analyzeSelectedForcesReanalysisOfThatSubset() async {
        let model = VideoScanModel()
        let a = makeTwin("t.mov", md5: "sel")
        let b = makeTwin("t copy.mov", md5: "sel", dir: "/vol/b")
        model.records = [a, b]
        await model.analyzeDuplicates()
        let gid = a.duplicateGroupID
        #expect(gid != nil)

        await model.analyzeDuplicates(selectedIDs: [a.id, b.id])

        #expect(a.duplicateGroupID != nil && a.duplicateGroupID == b.duplicateGroupID,
                "Explicit selection re-derives the subset (fresh group id is fine — the user asked for a redo)")
    }
    // MARK: - 6. Chrome flags ride the debounced pass — never view bodies

    @Test func cachedChromeFlagsUpdateOnCatalogRefresh() async {
        let model = VideoScanModel()
        #expect(model.hasAnyPairs == false)
        #expect(model.deletableDupVolumes.isEmpty)

        // A pair + a same-volume high-confidence dup group.
        let v = makeTwin("v.mxf", md5: "p1")
        v.streamTypeRaw = StreamType.videoOnly.rawValue
        let a = makeTwin("a.mxf", md5: "p2")
        a.streamTypeRaw = StreamType.audioOnly.rawValue
        v.pairedWith = a; a.pairedWith = v
        let d1 = makeTwin("dup.mov", md5: "ddd", dir: "/Volumes/X/media")
        let d2 = makeTwin("dup copy.mov", md5: "ddd", dir: "/Volumes/X/other")
        model.records = [v, a, d1, d2]
        await model.analyzeDuplicates()
        model.refreshDossierCountsNow()

        #expect(model.hasAnyPairs, "Pair flag must reflect the catalog after the debounced pass")
        #expect(!model.deletableDupVolumes.isEmpty,
                "Same-volume extra copies must surface in the cached menu payload")
    }
}

// MARK: - Main-thread responsiveness at scale (the beachball pin)

@Suite(.serialized) struct DuplicateLedgerPerfTests {

    @Test func analyzeDuplicatesKeepsMainThreadResponsiveAtScale() async throws {
        let model = await MainActor.run { () -> VideoScanModel in
            let m = VideoScanModel()
            var recs: [VideoRecord] = []
            recs.reserveCapacity(30_000)
            for i in 0..<15_000 {
                // Pairs of twins so real grouping work happens.
                for (n, dir) in [("clip\(i).mov", "/vol/a"), ("clip\(i) copy.mov", "/vol/b")] {
                    let r = VideoRecord()
                    r.filename = n
                    r.fullPath = dir + "/" + n
                    r.directory = dir
                    r.streamTypeRaw = StreamType.videoAndAudio.rawValue
                    r.partialMD5 = "md5-\(i)"
                    r.sizeBytes = Int64(4000 + i)
                    r.durationSeconds = Double(30 + i % 500)
                    r.isPlayable = "Yes"
                    recs.append(r)
                }
            }
            m.records = recs
            return m
        }

        let analyzeTask = Task { @MainActor in
            await model.analyzeDuplicates()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        var worstHop: Double = 0
        for _ in 0..<10 {
            let t0 = ContinuousClock.now
            await MainActor.run {}
            let elapsed = ContinuousClock.now - t0
            let hop = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            worstHop = max(worstHop, hop)
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        await analyzeTask.value
        #expect(worstHop < 0.5,
                "Main actor must stay responsive during Analyze Duplicates (worst hop \(String(format: "%.3f", worstHop))s at 30k records)")
        let grouped = await MainActor.run {
            model.records.contains { $0.duplicateGroupID != nil }
        }
        #expect(grouped, "…and grouping actually happened")
    }
}
