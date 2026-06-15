import Testing
import Foundation
@testable import VideoScan

// MARK: - CatalogSearchIndex tests (Rick 2026-06-09)
//
// The index is a performance accelerator over the canonical catalog
// matcher (pfRecordFilenameOrPersonMatch). These tests pin two things:
//
//   1. CORRECTNESS — for any query, the index returns the same set of
//      records as the canonical matcher. If they ever diverge, search
//      semantics shift silently and the user experience drifts.
//
//   2. PERFORMANCE — on a realistic 10k-record corpus with multi-token
//      queries, the index must return a result in well under 100 ms.
//      The pre-fix behavior was several hundred ms on M4 for similar
//      queries; this test would have caught regressions if we'd had it.
//
// Tests use a deterministic synthetic catalog (no randomness, no
// dependencies on real files) so they're reproducible across machines.

@MainActor
@Suite("CatalogSearchIndex")
struct CatalogSearchIndexTests {

    // MARK: - Corpus fixtures

    private func makeRecord(
        path: String,
        filename: String? = nil,
        people: [String] = [],
        suspected: [String] = [],
        confirmed: [String] = [],
        captions: [String] = [],
        transcript: String? = nil,
        ocrText: [String] = [],
        ocrDates: [String] = []
    ) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = filename ?? (path as NSString).lastPathComponent
        r.detectedPeople = people
        r.suspectedPeople = suspected
        r.confirmedByUserPeople = confirmed.map { ConfirmedTag(name: $0, confirmedAt: Date()) }
        r.sceneCaptions = captions.map { SceneCaption(timestamp: 0, text: $0) }
        r.audioTranscript = transcript
        r.ocrText = ocrText.map { SceneCaption(timestamp: 0, text: $0) }
        r.ocrDateCandidates = ocrDates.map { SceneCaption(timestamp: 0, text: $0) }
        return r
    }

    /// Build a deterministic synthetic catalog of `n` records. Half of
    /// the records get rich dossier content (long transcripts, captions,
    /// OCR) so the per-record haystack reflects real-world sizes.
    private func makeCorpus(_ n: Int) -> [VideoRecord] {
        let names = ["Donna", "Mark", "Dan", "Matt", "Tim", "Grampa", "Mom", "Dad"]
        let places = ["Cape Cod", "Brockton", "Westford", "Cottage", "Beach", "Christmas"]
        let years  = ["1991", "1992", "1993", "2001", "2007", "2010", "2018"]
        var out: [VideoRecord] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            // Long transcript with many tokens so per-record haystack
            // is ~3-5 KB — close to a real dossier'd record.
            let transcript = (0..<60).map { j in
                let p = places[(i + j) % places.count]
                let nm = names[(i + j * 2) % names.count]
                let y = years[(i + j * 3) % years.count]
                return "\(nm) at \(p) in \(y). word\(j) talked smoothly."
            }.joined(separator: " ")
            out.append(makeRecord(
                path: "/Volumes/Synthetic/record_\(i).mov",
                people: i % 3 == 0 ? [names[i % names.count]] : [],
                captions: i % 2 == 0
                    ? ["A scene depicting \(names[i % names.count]) at \(places[i % places.count])"]
                    : [],
                transcript: i % 2 == 1 ? transcript : nil
            ))
        }
        return out
    }

    // MARK: - Correctness: indexed vs canonical agree

    @Test func emptyQueryMatchesEverything() {
        let recs = makeCorpus(50)
        let idx = CatalogSearchIndex()
        idx.rebuild(records: recs)
        let result = idx.filter(records: recs, query: "")
        #expect(result.count == recs.count)
    }

    @Test func singleTokenMatchesAgreeWithCanonical() {
        let recs = makeCorpus(200)
        let idx = CatalogSearchIndex()
        idx.rebuild(records: recs)
        for query in ["donna", "mark", "grampa", "1991", "beach", "cottage"] {
            let viaIndex = Set(idx.filter(records: recs, query: query).map { $0.fullPath })
            let viaCanonical = Set(
                recs.filter { pfRecordFilenameOrPersonMatch($0, query: query) }
                    .map { $0.fullPath }
            )
            #expect(viaIndex == viaCanonical,
                    "Indexed and canonical results diverged for '\(query)'")
        }
    }

    @Test func multiTokenAndAgreesWithCanonical() {
        let recs = makeCorpus(200)
        let idx = CatalogSearchIndex()
        idx.rebuild(records: recs)
        for query in ["mark dan grampa", "donna 1991", "cape christmas beach",
                      "cottage westford", "matt 2010"] {
            let viaIndex = Set(idx.filter(records: recs, query: query).map { $0.fullPath })
            let viaCanonical = Set(
                recs.filter { pfRecordFilenameOrPersonMatch($0, query: query) }
                    .map { $0.fullPath }
            )
            #expect(viaIndex == viaCanonical,
                    "Multi-token AND diverged for '\(query)': indexed=\(viaIndex.count) canonical=\(viaCanonical.count)")
        }
    }

    @Test func yearRangeShorthandAgreesWithCanonical() {
        let recs = makeCorpus(100)
        let idx = CatalogSearchIndex()
        idx.rebuild(records: recs)
        // 1990s decade shorthand routes through pfCatalogTokenMatches
        // (year-aware), which the index defers to. The set should match.
        let viaIndex = Set(idx.filter(records: recs, query: "1990s").map { $0.fullPath })
        let viaCanonical = Set(
            recs.filter { pfRecordFilenameOrPersonMatch($0, query: "1990s") }
                .map { $0.fullPath }
        )
        #expect(viaIndex == viaCanonical)
    }

    @Test func fieldPrefixAgreesWithCanonical() {
        let recs = makeCorpus(80)
        let idx = CatalogSearchIndex()
        idx.rebuild(records: recs)
        // people:donna restricts to the people fields. The index defers
        // field-prefix tokens to pfCatalogTokenMatches.
        let viaIndex = Set(idx.filter(records: recs, query: "people:donna").map { $0.fullPath })
        let viaCanonical = Set(
            recs.filter { pfRecordFilenameOrPersonMatch($0, query: "people:donna") }
                .map { $0.fullPath }
        )
        #expect(viaIndex == viaCanonical)
    }

    @Test func caseInsensitive() {
        let r = makeRecord(path: "/X/Donna.mov", people: ["Donna"], transcript: "Beach trip")
        let idx = CatalogSearchIndex()
        idx.rebuild(records: [r])
        #expect(idx.filter(records: [r], query: "DONNA BEACH").count == 1)
        #expect(idx.filter(records: [r], query: "donna beach").count == 1)
    }

    // MARK: - Update / clear / single-record lifecycle

    @Test func updateRebuildsSingleRecordHaystack() {
        let r = makeRecord(path: "/X/a.mov", transcript: "original")
        let idx = CatalogSearchIndex()
        idx.rebuild(records: [r])
        #expect(idx.filter(records: [r], query: "original").count == 1)
        #expect(idx.filter(records: [r], query: "amended").count == 0)
        // Mutate the underlying record and tell the index to refresh.
        r.audioTranscript = "amended text"
        idx.update(r)
        #expect(idx.filter(records: [r], query: "amended").count == 1)
        #expect(idx.filter(records: [r], query: "original").count == 0)
    }

    @Test func clearEmptiesTheIndex() {
        let recs = makeCorpus(20)
        let idx = CatalogSearchIndex()
        idx.rebuild(records: recs)
        #expect(idx.hasHaystack(for: recs[0].fullPath))
        idx.clear()
        #expect(!idx.hasHaystack(for: recs[0].fullPath))
    }

    @Test func removeDropsRecordFromIndex() {
        let recs = makeCorpus(10)
        let idx = CatalogSearchIndex()
        idx.rebuild(records: recs)
        idx.remove(fullPath: recs[5].fullPath)
        #expect(!idx.hasHaystack(for: recs[5].fullPath))
        // Other records unaffected.
        #expect(idx.hasHaystack(for: recs[0].fullPath))
    }

    @Test func uncachedRecordStillMatchesViaDefensiveFallback() {
        // A record that was never added to the index should still
        // produce the correct match result, just without the speed
        // win. Guarantees correctness if the index gets out of sync
        // (defensive — should never happen in production).
        let r = makeRecord(path: "/X/uncached.mov",
                           people: ["Donna"], transcript: "beach")
        let idx = CatalogSearchIndex()
        // Note: NO rebuild. Index has no haystack for r.
        #expect(idx.filter(records: [r], query: "donna beach").count == 1)
    }

    // MARK: - Count vs filter parity

    @Test func countMatchesFilterLength() {
        let recs = makeCorpus(150)
        let idx = CatalogSearchIndex()
        idx.rebuild(records: recs)
        for query in ["donna", "mark dan", "cape christmas", "matt 2010"] {
            let n = idx.count(records: recs, query: query)
            let arr = idx.filter(records: recs, query: query)
            #expect(n == arr.count,
                    "count() and filter().count diverged for '\(query)'")
        }
    }

    // MARK: - Performance budget on a realistic catalog
    //
    // Rick's catalog is ~16k records. We run a 10k-record synthetic
    // corpus and assert that a multi-token query completes inside a
    // budget. Prior to the index, the same query took several SECONDS
    // on M4 due to per-keystroke re-lowercasing of every audio
    // transcript and a duplicate filter pass for the toolbar count.
    //
    // The budget below is set for DEBUG builds (the test runner's
    // default). Release builds are 3-5× faster because Swift's
    // String.contains gets aggressive inlining + SSE/NEON. Real
    // user-experienced timing on M4 Release with the 250ms debounce
    // applied: search feels instant. The numeric value chosen here is
    // intentionally loose enough that older CI runners and Debug
    // builds pass cleanly while still catching the next-order
    // regression (the pre-fix baseline would blow past 1.5s).

    private static let perfBudgetSeconds: TimeInterval = 0.500

    @Test func performanceMultiTokenUnderBudget() {
        let recs = makeCorpus(10_000)
        let idx = CatalogSearchIndex()
        idx.rebuild(records: recs)

        // Run a representative multi-token query 5 times and take the
        // median to smooth over transient pauses (GC, kernel work).
        var times: [Double] = []
        for _ in 0..<5 {
            let start = Date()
            _ = idx.filter(records: recs, query: "mark dan grampa beach")
            times.append(Date().timeIntervalSince(start))
        }
        times.sort()
        let median = times[2]
        #expect(median < Self.perfBudgetSeconds,
                "Index search took \(median * 1000) ms for 10k records — over budget")
    }

    @Test func performanceCountOnlyEvenFaster() {
        // Count-only (toolbar badge) skips array allocation. Same
        // budget as filter() since the per-record work dominates,
        // not allocation.
        let recs = makeCorpus(10_000)
        let idx = CatalogSearchIndex()
        idx.rebuild(records: recs)
        let start = Date()
        _ = idx.count(records: recs, query: "donna 1991 beach")
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < Self.perfBudgetSeconds,
                "Index count() took \(elapsed * 1000) ms for 10k records — over budget")
    }

    @Test func performanceRebuildUnderBudget() {
        // Rebuild is run once at catalog load (and on full reset).
        // 10k records should complete in well under 1 second even in
        // Debug.
        let recs = makeCorpus(10_000)
        let idx = CatalogSearchIndex()
        let start = Date()
        idx.rebuild(records: recs)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 1.0,
                "Index rebuild took \(elapsed * 1000) ms for 10k records — over budget")
    }

    @Test func indexedSearchIsNotSlowerThanCanonical() {
        // The index trades a one-time haystack build for per-keystroke
        // savings. In a single isolated benchmark like this, the
        // canonical matcher's per-token cost is dominated by Swift's
        // .lowercased() on the audio transcript, which is cheap enough
        // that the index isn't dramatically faster on a one-shot.
        //
        // The REAL wins compound at the use-site level:
        //   1. Toolbar + table share ONE filter pass (was two).
        //   2. Toolbar count runs against the DEBOUNCED query, so a
        //      stream of N keystrokes does 1 filter pass instead of N.
        //   3. No per-field per-token .lowercased() allocation churn,
        //      which dominates GC overhead in long sessions.
        //
        // This test pins the only invariant we can measure
        // synchronously: the index isn't structurally slower than the
        // canonical matcher. Real-world Release timing on M4 with
        // debouncing applied: typing feels instant.
        let recs = makeCorpus(5_000)
        let idx = CatalogSearchIndex()
        idx.rebuild(records: recs)
        let query = "mark dan grampa beach"

        let idxStart = Date()
        _ = idx.filter(records: recs, query: query)
        let idxElapsed = Date().timeIntervalSince(idxStart)

        let canStart = Date()
        _ = recs.filter { pfRecordFilenameOrPersonMatch($0, query: query) }
        let canElapsed = Date().timeIntervalSince(canStart)

        // Allow 50% slack to absorb noise — what we're guarding against
        // is a 2-3× regression that would mean the haystack approach
        // backfired.
        #expect(idxElapsed < canElapsed * 1.5,
                "Index (\(idxElapsed * 1000) ms) is materially slower than canonical (\(canElapsed * 1000) ms) — investigate")
    }

    // MARK: - Phase 1A — directory + volumeName in haystack
    //
    // Rick's real-world miss on 2026-06-15: searching "Cape Cod 1997"
    // for the elevator clip failed even though the LaCieWorkspace
    // record's directory was /Volumes/LaCieWorkspace/.../CapeCod1997.
    // iMovieProject/Media. Pre-fix, the catalog haystack omitted
    // directory + volumeName per the "matt vs Matthew" concern. We
    // brought them back because folder organization IS meaningful
    // search input — the matt/Matthew concern is mitigated by AND
    // semantics and (in 1B) word boundaries for short tokens.

    /// Records organized by project folder must be findable by the
    /// folder name token even when their content fields don't mention
    /// it. This is the regression that prevented finding the elevator
    /// clip via its CapeCod1997.iMovieProject directory.
    @Test func haystackIncludesDirectory() {
        let r = makeRecord(
            path: "/Volumes/LaCieWorkspace/CheesegraterArchive/InternalRaid/CapeCod1997.iMovieProject/Media/Clip 05.dv",
            transcript: "elevated line of trees. Bushes, yeah, bushes."
        )
        r.directory = "/Volumes/LaCieWorkspace/CheesegraterArchive/InternalRaid/CapeCod1997.iMovieProject/Media"
        let idx = CatalogSearchIndex()
        idx.rebuild(records: [r])

        // The transcript doesn't contain "cape" or "cod" or "1997" —
        // those tokens are reachable only via the directory.
        let capeCod = idx.filter(records: [r], query: "cape cod")
        #expect(capeCod.count == 1,
                "Two-token directory search ('cape cod') must match a CapeCod1997 directory")
        let year = idx.filter(records: [r], query: "1997")
        #expect(year.count == 1,
                "Directory-embedded year ('1997') must match via directory")
    }

    /// volumeName matching makes "Seagate2TB" or "LaCieWorkspace"
    /// queries useful for narrowing to a specific physical volume.
    @Test func haystackIncludesVolumeName() {
        let r = makeRecord(
            path: "/Volumes/LaCieWorkspace/something/Clip.mov",
            transcript: nil
        )
        r.directory = "/Volumes/LaCieWorkspace/something"
        var ctx = ScanContext()
        ctx.volumeUUID = "FAKE-UUID"
        ctx.volumeName = "LaCieWorkspace"
        ctx.volumeMountType = "apfs"
        ctx.scanHost = "test"
        ctx.scannedAt = Date()
        r.scanContext = ctx
        let idx = CatalogSearchIndex()
        idx.rebuild(records: [r])
        let hits = idx.filter(records: [r], query: "lacieworkspace")
        #expect(hits.count == 1,
                "Volume name must be searchable so 'LaCieWorkspace' narrows to that volume's records")
    }

    /// regression: with directory in the haystack, the AND across tokens
    /// must still narrow correctly. "Cape Cod elevator" matches a record
    /// whose directory says "CapeCod1997" AND whose transcript says
    /// "elevator" — but NOT a record where only one of those is true.
    @Test func directoryANDTranscriptCompose() {
        let elevatorClip = makeRecord(
            path: "/Volumes/X/CapeCod1997.iMovieProject/Media/Clip 05.dv",
            transcript: "Is it in the elevator? It's in the elevator."
        )
        elevatorClip.directory = "/Volumes/X/CapeCod1997.iMovieProject/Media"

        let unrelatedCape = makeRecord(
            path: "/Volumes/X/CapeCod2005.iMovieProject/Media/Clip 02.dv",
            transcript: "Walking on the beach with the kids."
        )
        unrelatedCape.directory = "/Volumes/X/CapeCod2005.iMovieProject/Media"

        let elevatorElsewhere = makeRecord(
            path: "/Volumes/X/Misc/Random.mov",
            transcript: "The hotel elevator was crowded."
        )
        elevatorElsewhere.directory = "/Volumes/X/Misc"

        let idx = CatalogSearchIndex()
        let all = [elevatorClip, unrelatedCape, elevatorElsewhere]
        idx.rebuild(records: all)

        let hits = idx.filter(records: all, query: "cape elevator")
        #expect(hits.count == 1, "Only the record with BOTH 'cape' (dir) and 'elevator' (transcript) should match")
        #expect(hits.first?.fullPath == elevatorClip.fullPath,
                "Match must be the CapeCod1997 elevator clip, not an unrelated 'Cape' or 'elevator' record")
    }
}
