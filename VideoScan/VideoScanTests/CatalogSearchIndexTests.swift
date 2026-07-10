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
@Suite("CatalogSearchIndex", .serialized)   // .serialized: the perf-budget tests
// below time real work; running them alongside the rest of this suite's 10k-
// record corpus builds adds parallel-contention noise to the measurements.
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

    /// Sleep-immune elapsed seconds for the perf-budget assertions.
    /// Date() (like ContinuousClock) keeps advancing while the machine is
    /// asleep — a mid-test lid-close on a nightly laptop turns milliseconds
    /// of work into "minutes elapsed" and falsely fails the budget (seen on
    /// the M5 nightly, 2026-07-09). SuspendingClock stops during sleep.
    /// C++ analogy: std::chrono::steady_clock, but one that also pauses
    /// across system suspend.
    private static func elapsedSeconds(since start: SuspendingClock.Instant) -> TimeInterval {
        let d = start.duration(to: SuspendingClock.now)
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    @Test func performanceMultiTokenUnderBudget() {
        let recs = makeCorpus(10_000)
        let idx = CatalogSearchIndex()
        idx.rebuild(records: recs)

        // Run a representative multi-token query 5 times and take the
        // median to smooth over transient pauses (GC, kernel work).
        var times: [Double] = []
        for _ in 0..<5 {
            let start = SuspendingClock.now
            _ = idx.filter(records: recs, query: "mark dan grampa beach")
            times.append(Self.elapsedSeconds(since: start))
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
        let start = SuspendingClock.now
        _ = idx.count(records: recs, query: "donna 1991 beach")
        let elapsed = Self.elapsedSeconds(since: start)
        #expect(elapsed < Self.perfBudgetSeconds,
                "Index count() took \(elapsed * 1000) ms for 10k records — over budget")
    }

    @Test func performanceRebuildUnderBudget() {
        // Rebuild is run once at catalog load (and on full reset).
        // Budget history: 1.0s → 1.5s (Rick 2026-06-16) to absorb the
        // inverted-word-index build; 1.5s → 3.0s (2026-07-09) because the
        // 1.5s value was calibrated on M4 (which passes with only ~16%
        // headroom) and the M1 nightly runs the same healthy rebuild in
        // ~1.76-1.80s — a fleet-calibration miss, not a regression. The
        // sensor's intent is to catch the NEXT-ORDER regression (rebuild
        // ballooning to "several seconds"); 3.0s still does that on every
        // fleet host while unmasking M1.
        let recs = makeCorpus(10_000)
        let idx = CatalogSearchIndex()
        let start = SuspendingClock.now
        idx.rebuild(records: recs)
        let elapsed = Self.elapsedSeconds(since: start)
        #expect(elapsed < 3.0,
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

        let idxStart = SuspendingClock.now
        _ = idx.filter(records: recs, query: query)
        let idxElapsed = Self.elapsedSeconds(since: idxStart)

        let canStart = SuspendingClock.now
        _ = recs.filter { pfRecordFilenameOrPersonMatch($0, query: query) }
        let canElapsed = Self.elapsedSeconds(since: canStart)

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

    // MARK: - Phase 1B — Path decomposition (CamelCase + letter/digit splits)
    //
    // Rick organizes videos in CamelCase project folders ("CapeCod1997
    // .iMovieProject", "Christmas2005.iMovieProject"). Without
    // decomposition, "cape cod 1997" still finds them via raw substring,
    // but "i movie" (with space) wouldn't and word-aware ranking can't
    // see the word boundaries. The pathTokenize helper injects spaces at
    // CamelCase transitions + letter↔digit boundaries so the haystack
    // reads the way a human would say the folder name.

    @Test func pathTokenize_camelCase() {
        #expect(CatalogSearchIndex.pathTokenize("CapeCod1997") == "Cape Cod 1997")
        #expect(CatalogSearchIndex.pathTokenize("iMovieProject") == "i Movie Project")
        #expect(CatalogSearchIndex.pathTokenize("LaCieWorkspace") == "La Cie Workspace")
    }

    @Test func pathTokenize_letterDigitBoundaries() {
        // Every letter↔digit boundary becomes a split. "Maxtor500FW"
        // reads as brand / model / interface (FireWire) — three logical
        // tokens, all separately findable.
        #expect(CatalogSearchIndex.pathTokenize("Maxtor500FW") == "Maxtor 500 FW")
        #expect(CatalogSearchIndex.pathTokenize("Christmas2005") == "Christmas 2005")
        #expect(CatalogSearchIndex.pathTokenize("500Flag") == "500 Flag")
    }

    @Test func pathTokenize_acronymToWord() {
        // "USAFlag" → "USA Flag": acronym→word boundary detected by
        // lookahead (uppercase followed by lowercase).
        #expect(CatalogSearchIndex.pathTokenize("USAFlag") == "USA Flag")
        #expect(CatalogSearchIndex.pathTokenize("MyHTTPServer") == "My HTTP Server")
    }

    @Test func pathTokenize_emptyAndSingleChar() {
        #expect(CatalogSearchIndex.pathTokenize("") == "")
        #expect(CatalogSearchIndex.pathTokenize("a") == "a")
        #expect(CatalogSearchIndex.pathTokenize("A") == "A")
        #expect(CatalogSearchIndex.pathTokenize("/") == "/")
    }

    /// regression: with path decomposition in the haystack, a query
    /// like "i movie" (two tokens) now matches a folder named
    /// "iMovieProject" via the decomposed "i Movie Project" form.
    @Test func decomposedHaystackEnablesMultiTokenFolderQuery() {
        let r = makeRecord(path: "/Volumes/X/iMovieProject/Clip.mov")
        r.directory = "/Volumes/X/iMovieProject"
        let idx = CatalogSearchIndex()
        idx.rebuild(records: [r])

        // "movie project" — two tokens — pre-Phase-1B these would both
        // match via substring of "iMovieProject", but the user reading
        // the catalog expects multi-word folder names to compose
        // naturally.
        let hits = idx.filter(records: [r], query: "movie project")
        #expect(hits.count == 1,
                "Multi-token folder query must match decomposed CamelCase")
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

    // MARK: - Inverted index v1 (Rick 2026-06-16)

    /// Fast-path correctness: whole-word substring queries hit the
    /// inverted word index and must return the SAME records the
    /// canonical matcher would.
    @Test func invertedIndex_wholeWordSearchMatchesCanonical() {
        let recs = makeCorpus(200)
        let idx = CatalogSearchIndex()
        idx.rebuild(records: recs)

        let viaIndex = Set(idx.filter(records: recs, query: "donna").map { $0.fullPath })
        let viaCanonical = Set(pfRecordsMatchingQuery(recs, query: "donna").map { $0.fullPath })
        #expect(viaIndex == viaCanonical,
                "Inverted-index fast path must match canonical results for whole-word query")
    }

    /// Fallback correctness: a substring INSIDE a word ("elev" inside
    /// "elevator") isn't a complete word in the index, so the query
    /// falls back to the per-record linear matcher — still returns
    /// the right records.
    @Test func invertedIndex_partialWordFallsBackCorrectly() {
        let recs = makeCorpus(200)
        let idx = CatalogSearchIndex()
        idx.rebuild(records: recs)

        // "donn" is a partial — the inverted index has "donna" not "donn".
        // The query must still find the records by falling back to linear.
        let viaIndex = Set(idx.filter(records: recs, query: "donn").map { $0.fullPath })
        let viaCanonical = Set(pfRecordsMatchingQuery(recs, query: "donn").map { $0.fullPath })
        #expect(viaIndex == viaCanonical,
                "Partial-word substring must still match via fallback path")
        #expect(!viaIndex.isEmpty,
                "Sanity check: a 'donn' query should find at least the donna-tagged records")
    }

    /// Fallback correctness: phrase tokens (contain whitespace) can't
    /// use the word index — they need adjacency. Must fall back to
    /// linear and still match.
    @Test func invertedIndex_phraseFallsBackCorrectly() {
        let cap = makeRecord(
            path: "/Volumes/X/Holiday/cape-cod-1997.mov",
            transcript: "We drove down to cape cod for the long weekend."
        )
        let other = makeRecord(
            path: "/Volumes/X/Misc/random.mov",
            transcript: "Some other content with cape and cod separately, far apart."
        )
        let idx = CatalogSearchIndex()
        idx.rebuild(records: [cap, other])

        // Phrase token — should only match the record where "cape cod"
        // appears as a literal phrase.
        let hits = idx.filter(records: [cap, other], query: "\"cape cod\"")
        #expect(hits.count == 1, "Phrase query should match only the literal phrase record")
        #expect(hits.first?.fullPath == cap.fullPath)
    }

    /// update() must keep the inverted index honest: words that LEFT
    /// the haystack should be removed from their buckets, and new
    /// words should be added.
    @Test func invertedIndex_updateRefreshesWords() {
        let rec = makeRecord(
            path: "/Volumes/X/alpha.mov",
            transcript: "before"
        )
        let idx = CatalogSearchIndex()
        idx.rebuild(records: [rec])

        // "before" should match; "after" should not.
        #expect(idx.filter(records: [rec], query: "before").count == 1)
        #expect(idx.filter(records: [rec], query: "after").isEmpty)

        // Mutate the transcript and update the index — old word goes
        // away, new word arrives.
        rec.audioTranscript = "after"
        idx.update(rec)

        #expect(idx.filter(records: [rec], query: "before").isEmpty,
                "Stale 'before' must no longer match after update()")
        #expect(idx.filter(records: [rec], query: "after").count == 1,
                "Fresh 'after' must match after update()")
    }

    /// remove() must drop the record's fullPath from every word bucket
    /// it appeared in. Otherwise stale entries pile up and the index
    /// returns false positives once the record is gone.
    @Test func invertedIndex_removeDropsFromAllBuckets() {
        let recA = makeRecord(path: "/Volumes/X/a.mov", transcript: "shared word")
        let recB = makeRecord(path: "/Volumes/X/b.mov", transcript: "shared word")
        let idx = CatalogSearchIndex()
        idx.rebuild(records: [recA, recB])

        #expect(idx.filter(records: [recA, recB], query: "shared").count == 2)

        idx.remove(fullPath: recA.fullPath)

        // After remove, only recB should be returned. Pass both records
        // to filter() to confirm the index dropped recA, not just the
        // caller's record list.
        let after = idx.filter(records: [recA, recB], query: "shared")
        #expect(after.map { $0.fullPath } == [recB.fullPath],
                "remove() must drop the record from the inverted word buckets")
    }

    /// AND across two whole-word tokens must intersect bucket sets and
    /// return only records containing both.
    @Test func invertedIndex_multiTokenAndIntersection() {
        let bothWords = makeRecord(
            path: "/Volumes/X/both.mov",
            transcript: "elevator and donna in the same clip"
        )
        let onlyElevator = makeRecord(
            path: "/Volumes/X/elev.mov",
            transcript: "just an elevator clip"
        )
        let onlyDonna = makeRecord(
            path: "/Volumes/X/donna.mov",
            transcript: "donna at the beach"
        )
        let idx = CatalogSearchIndex()
        let all = [bothWords, onlyElevator, onlyDonna]
        idx.rebuild(records: all)

        let hits = idx.filter(records: all, query: "elevator donna")
        #expect(hits.count == 1)
        #expect(hits.first?.fullPath == bothWords.fullPath)
    }

    /// regression: a needle that is simultaneously a STANDALONE word in some
    /// records AND an INFIX of a different word in others must still return
    /// BOTH sets — matching the canonical SUBSTRING matcher. This is the real
    /// 2026-06-27 bug ("rick" 917 vs 11016): the whole-word bucket for "rick"
    /// held only the standalone-token records and missed every record where
    /// "rick" lived inside "rickb" / "ricksbackups". The infix-safety gate in
    /// tryIndexLookup must detect that "rick" is an infix of another indexed
    /// word and either bail to the linear matcher or otherwise return the
    /// complete set. Either way: index == canonical, with BOTH records present.
    @Test func invertedIndex_infixOfAnotherWordMatchesCanonical() {
        // "rick" is a standalone word here (filename token).
        let standalone = makeRecord(path: "/Volumes/X/rick at the beach.mov",
                                    transcript: "rick waves hello")
        // "rick" appears ONLY as an infix of "rickb" — never standalone.
        let infixUser = makeRecord(path: "/Volumes/X/rickb-home-movie.mov",
                                   transcript: "captured by rickb on the camcorder")
        // "rick" as an infix of a directory-style token "ricksbackups".
        let infixDir = makeRecord(path: "/Volumes/RicksBackups/clip.mov",
                                  transcript: "no name token here")
        infixDir.directory = "/Volumes/RicksBackups/2001"
        // A control record that must NOT match.
        let unrelated = makeRecord(path: "/Volumes/X/donna.mov",
                                   transcript: "donna at home")

        let all = [standalone, infixUser, infixDir, unrelated]
        let idx = CatalogSearchIndex()
        idx.rebuild(records: all)

        let viaIndex = Set(idx.filter(records: all, query: "rick").map { $0.fullPath })
        let viaCanonical = Set(
            all.filter { pfRecordFilenameOrPersonMatch($0, query: "rick") }
                .map { $0.fullPath }
        )
        #expect(viaIndex == viaCanonical,
                "Infix needle 'rick' diverged: index=\(viaIndex.count) canonical=\(viaCanonical.count)")
        // The standalone AND both infix records must be present; the
        // unrelated 'donna' record must be absent.
        #expect(viaIndex.contains(standalone.fullPath), "standalone 'rick' record missing")
        #expect(viaIndex.contains(infixUser.fullPath), "infix 'rickb' record missing — whole-word bucket under-returned")
        #expect(viaIndex.contains(infixDir.fullPath), "infix 'RicksBackups' directory record missing")
        #expect(!viaIndex.contains(unrelated.fullPath), "unrelated record must not match 'rick'")
    }

    /// regression: the eligibility memo must not go stale. A needle that is
    /// fast-path eligible (standalone, no infix overlap) can become INELIGIBLE
    /// after update() introduces a longer word that contains it. The first
    /// query caches "eligible"; after the update, the same query must recompute
    /// and return the now-larger complete set.
    @Test func invertedIndex_eligibilityMemoInvalidatesOnUpdate() {
        let standalone = makeRecord(path: "/Volumes/X/rick.mov", transcript: "rick here")
        let other = makeRecord(path: "/Volumes/X/other.mov", transcript: "plain content")
        let idx = CatalogSearchIndex()
        idx.rebuild(records: [standalone, other])

        // First query: "rick" is standalone-only → fast-path eligible, cached.
        let before = Set(idx.filter(records: [standalone, other], query: "rick").map { $0.fullPath })
        #expect(before == [standalone.fullPath])

        // Now "other" gains the word "rickb" — "rick" is now an infix of it.
        other.audioTranscript = "captured by rickb"
        idx.update(other)

        let after = Set(idx.filter(records: [standalone, other], query: "rick").map { $0.fullPath })
        let canonical = Set(
            [standalone, other].filter { pfRecordFilenameOrPersonMatch($0, query: "rick") }
                .map { $0.fullPath }
        )
        #expect(after == canonical,
                "Stale eligibility memo: 'rick' returned \(after.count), canonical \(canonical.count)")
        #expect(after.contains(other.fullPath),
                "After update() added 'rickb', 'rick' must now match that record too")
    }

    /// clear() must wipe BOTH the haystack cache AND the inverted
    /// index — otherwise post-clear queries would return stale matches.
    @Test func invertedIndex_clearWipesBothSides() {
        let rec = makeRecord(path: "/Volumes/X/a.mov", transcript: "donna at home")
        let idx = CatalogSearchIndex()
        idx.rebuild(records: [rec])
        #expect(idx.filter(records: [rec], query: "donna").count == 1)
        #expect(idx.indexedWordCount() > 0)

        idx.clear()

        #expect(idx.indexedWordCount() == 0,
                "clear() must drop every word entry")
        // After clear, the haystack cache is empty too — the linear
        // matcher's lazy haystack build still finds matches if the
        // caller passes a record, but the fast path is empty (no
        // buckets). Both behaviors stay correct.
    }

    // MARK: - Persistence (Rick 2026-06-16)

    private func makeTempURL(name: String) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs_search_index_\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    /// Save → load roundtrip preserves filter results bit-for-bit.
    @Test func persistence_roundtripPreservesResults() throws {
        let recs = makeCorpus(500)
        let idx = CatalogSearchIndex()
        idx.rebuild(records: recs)
        let goldenQuery = "donna 1991 cape"
        let golden = idx.filter(records: recs, query: goldenQuery).map { $0.fullPath }

        let url = makeTempURL(name: "index.plist")
        try idx.saveToDisk(at: url)

        let loaded = CatalogSearchIndex()
        let ok = loaded.loadFromDisk(at: url, catalogModifiedAt: nil)
        #expect(ok, "loadFromDisk must succeed on a freshly-written file")

        let restored = loaded.filter(records: recs, query: goldenQuery).map { $0.fullPath }
        #expect(restored == golden,
                "Filter results after persistence roundtrip must match exactly")
    }

    /// Staleness check: if catalogModifiedAt is AFTER the persisted
    /// savedAt, loadFromDisk must reject the file so the caller
    /// rebuilds from records (correctness over speed).
    @Test func persistence_rejectsStaleIndex() throws {
        let recs = makeCorpus(50)
        let idx = CatalogSearchIndex()
        idx.rebuild(records: recs)

        let url = makeTempURL(name: "index.plist")
        try idx.saveToDisk(at: url)

        // Catalog modified one minute IN THE FUTURE → index is stale.
        let future = Date().addingTimeInterval(60)
        let loaded = CatalogSearchIndex()
        let ok = loaded.loadFromDisk(at: url, catalogModifiedAt: future)
        #expect(!ok, "Stale index must be rejected when catalog is newer")
    }

    /// loadFromDisk gracefully returns false on missing/garbage files
    /// (no throws, no crashes — caller falls back to rebuild).
    @Test func persistence_missingFileReturnsFalse() {
        let bogusURL = URL(fileURLWithPath: "/tmp/definitely-not-there.plist")
        let loaded = CatalogSearchIndex()
        #expect(!loaded.loadFromDisk(at: bogusURL, catalogModifiedAt: nil))
    }

    @Test func persistence_garbageFileReturnsFalse() throws {
        let url = makeTempURL(name: "garbage.plist")
        try "not a real plist".write(to: url, atomically: true, encoding: .utf8)
        let loaded = CatalogSearchIndex()
        #expect(!loaded.loadFromDisk(at: url, catalogModifiedAt: nil),
                "Corrupt plist must be rejected gracefully")
    }

    /// Speedup expectation: with the index built, multi-token whole-
    /// word queries on 10k records should land WELL under the perf
    /// budget. Looser than the pre-existing perf test — this one
    /// specifically exercises the fast path.
    @Test func invertedIndex_fastPathUnderTightBudget() {
        let recs = makeCorpus(10_000)
        let idx = CatalogSearchIndex()
        idx.rebuild(records: recs)

        // "mark donna" should hit the fast path (both are full words
        // present in the synthetic corpus' names). Take best of 5 to
        // smooth over noise.
        var best = TimeInterval.greatestFiniteMagnitude
        for _ in 0..<5 {
            let start = SuspendingClock.now
            _ = idx.filter(records: recs, query: "mark donna")
            best = min(best, Self.elapsedSeconds(since: start))
        }
        // Fast-path target: under 50 ms for 10k records (the linear
        // path was already <500ms; we expect substantial improvement).
        #expect(best < 0.100,
                "Fast-path whole-word AND took \(best * 1000) ms — expected <100 ms")
    }
}
