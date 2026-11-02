// DuplicateLedgerTests.swift
// Analysis-ledger semantics for duplicate detection
// (docs/design/analysis_ledger_design.md, 2026-07-05): dup groups are computed
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
    // MARK: - 7. affectedSubset walks bucket adjacency TRANSITIVELY (QA P1-3)

    @Test func affectedSubsetIncludesTransitiveBucketNeighbors() {
        // A(delta) shares a stem key with B; B shares an md5 key with C;
        // C shares NOTHING with A. Grouping walks connected components,
        // so C's disposition can change — it must be in the subset.
        let a = makeTwin("family tape.mov", md5: "k1", size: 1111)
        let b = makeTwin("family tape copy.mov", md5: "k2", size: 2222, dir: "/vol/b")
        let c = makeTwin("othername.mov", md5: "k2", size: 2222, dir: "/vol/c")
        b.dupAnalyzedAt = Date()
        c.dupAnalyzedAt = Date()

        let subset = DuplicateDetector.affectedSubset(delta: [a], allActive: [a, b, c])
        let ids = Set(subset.map(\.id))
        #expect(ids.contains(a.id) && ids.contains(b.id),
                "One-hop neighbors must be included")
        #expect(ids.contains(c.id),
                "TRANSITIVE neighbor (via B's second bucket key) must be included — a one-hop expansion elects keepers over truncated components (QA P1-3)")
    }

    // MARK: - 8. The closure's stems run OFF the main actor (nightly 2026-11-02)
    //
    // The beachball pin below (DuplicateLedgerPerfTests) failed in both
    // Macs' nightly at 0.50 s / 0.53 s: ~3/4 of Analyze Duplicates'
    // synchronous main-actor stretch was `affectedSubset` computing every
    // active record's normalized stem (five regex replacements per name).
    // Dimensions: LOGIC (same answer as the synchronous rule), ISOLATION
    // (the main-actor projection computes no stem), SCALE (100k projection
    // inside a budget), SENSOR (the verb calls the off-main form). Media
    // matrix N/A — no media is opened.

    @Test func affectedSubsetOffMainAgreesWithTheSynchronousRule() async {
        // The transitive fixture (7) + a settled group whose second member
        // shares no key with the delta (the full-group pull) + an unrelated
        // record that must stay out.
        let a = makeTwin("family tape.mov", md5: "k1", size: 1111)
        let b = makeTwin("family tape copy.mov", md5: "k2", size: 2222, dir: "/vol/b")
        let c = makeTwin("othername.mov", md5: "k2", size: 2222, dir: "/vol/c")
        let star = makeTwin("zzz.mov", md5: "k3", size: 3333, dir: "/vol/d")
        let unrelated = makeTwin("unrelated.mov", md5: "k9", size: 9999, dir: "/vol/e")
        unrelated.durationSeconds = 7
        let g = UUID()
        c.duplicateGroupID = g; star.duplicateGroupID = g
        for r in [b, c, star, unrelated] { r.dupAnalyzedAt = Date() }
        let all = [a, b, c, star, unrelated]

        let sync = DuplicateDetector.affectedSubset(delta: [a], allActive: all).map(\.id)
        let offMain = await DuplicateDetector.affectedSubsetOffMain(delta: [a], allActive: all).map(\.id)
        #expect(offMain == sync, "Same records, same order as the synchronous rule")
        #expect(Set(offMain) == Set([a.id, b.id, c.id, star.id]),
                "Transitive neighbours and the reached group's full membership — and nothing unrelated")
        #expect(await DuplicateDetector.affectedSubsetOffMain(delta: [], allActive: all).isEmpty)
    }

    @Test func affectedSubsetProjectionComputesNoStemOnTheMainActor() {
        let recs = (0..<50).map { makeTwin("clip \($0) copy (2).mov", md5: "m\($0)") }
        let input = DuplicateDetector.AffectedSubsetInput(delta: [recs[0]], allActive: recs)
        #expect(input.facts.count == recs.count && input.deltaIndices == [0])
        #expect(input.facts.allSatisfy { $0.stem == DuplicateLikeness.Facts.deferredStem },
                "The main-actor projection copies fields only; the regex stems run in the detached closure walk")
    }

    @Test func affectedSubsetProjectionAt100kIsInsideItsMainActorBudget() async {
        var recs: [VideoRecord] = []
        recs.reserveCapacity(100_000)
        for i in 0..<50_000 {
            recs.append(makeTwin("clip\(i).mov", md5: "md5-\(i)", size: Int64(4000 + i)))
            recs.append(makeTwin("clip\(i) copy.mov", md5: "md5-\(i)", size: Int64(4000 + i), dir: "/vol/b"))
        }
        let t0 = SuspendingClock.now
        let input = DuplicateDetector.AffectedSubsetInput(delta: recs, allActive: recs)
        let projected = SuspendingClock.now - t0
        let seconds = Double(projected.components.seconds) + Double(projected.components.attoseconds) / 1e18
        // Measured at 90k, Debug, M5 Ultra under load: projection 0.072 s;
        // the old all-on-main closure 0.681 s (stems + keys per record).
        #expect(seconds < PerformanceLane.debugCeiling(seconds: 0.25),
                "Main-actor projection for 100k records took \(String(format: "%.3f", seconds)) s")
        let indices = await Task.detached { DuplicateDetector.affectedIndices(input) }.value
        #expect(indices.count == recs.count, "Every record of a fully pending catalog is in scope")
    }

    @Test func analyzeDuplicatesScopesItsDeltaOffTheMainActor() throws {
        let url = try #require(SourceTree.appSourceURL(named: "MediaOps/VideoScanModel+Duplicates.swift"))
        let code = SourceTree.strippingComments(try String(contentsOf: url, encoding: .utf8))
        let body = try #require(code.range(of: "func analyzeDuplicates(").map { String(code[$0.lowerBound...].prefix(6_000)) })
        #expect(body.contains("DuplicateDetector.affectedSubsetOffMain("),
                "Analyze Duplicates must build its scope with the off-main closure")
        #expect(!body.contains("DuplicateDetector.affectedSubset("),
                "…never the synchronous one (regex stems for every active record on the main actor)")
    }

    // MARK: - 8. The mutation notification refreshes chrome caches (QA P0-1)

    @Test func catalogMutatedNotificationRefreshesChromeCaches() async throws {
        let model = VideoScanModel()
        let v = makeTwin("v.mxf", md5: "n1")
        v.streamTypeRaw = StreamType.videoOnly.rawValue
        let a = makeTwin("a.mxf", md5: "n2")
        a.streamTypeRaw = StreamType.audioOnly.rawValue
        model.records = [v, a]
        // Let the didSet-triggered debounce settle with NO pairs.
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(model.hasAnyPairs == false)

        // Field-level pair mutation (what the ledger correlators do) +
        // the notification they post — NO array republish.
        v.pairedWith = a; a.pairedWith = v
        NotificationCenter.default.post(name: .videoScanCatalogMutated, object: nil)
        var refreshed = false
        for _ in 0..<20 {   // debounce is 250 ms; allow up to 1 s
            try await Task.sleep(nanoseconds: 50_000_000)
            if model.hasAnyPairs { refreshed = true; break }
        }
        #expect(refreshed,
                "The catalog-mutated notification must refresh the chrome caches — the ledger paths publish through it, not through array didSet (QA P0-1)")
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
            // SuspendingClock: hop bound must not tick across machine sleep.
            let t0 = SuspendingClock.now
            await MainActor.run {}
            let elapsed = SuspendingClock.now - t0
            let hop = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            worstHop = max(worstHop, hop)
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        await analyzeTask.value
        // 0.5 s locally; ×3 on a GitHub-hosted runner only (0.647 s there, run 36202513830).
        #expect(worstHop < PerformanceLane.debugCeiling(seconds: 0.5),
                "Main actor must stay responsive during Analyze Duplicates (worst hop \(String(format: "%.3f", worstHop))s at 30k records)")
        let grouped = await MainActor.run {
            model.records.contains { $0.duplicateGroupID != nil }
        }
        #expect(grouped, "…and grouping actually happened")
    }
}
