import Testing
import Foundation
@testable import VideoScan

// MARK: - RealDataSearchTests (Rick 2026-06-27)
//
// Automated search testing against Rick's ACTUAL catalog, nondestructively.
//
// The existing search suites (CatalogSearchIndexTests, CatalogQueriesTests)
// are entirely SYNTHETIC — small deterministic corpora. They prove the
// algebra of the matcher and the index/canonical equivalence contract, but
// they say nothing about behaviour at the real 19K-record scale or against
// the real distribution of filenames, people tags, and dossier text. This
// suite closes that gap.
//
// Guarantees:
//   * NONDESTRUCTIVE — never opens the real catalog.json for writing. It
//     copies the file into a throwaway temp dir and loads THAT copy through
//     the production decode path (CatalogStore(directory:).load()). load()
//     only ever writes within its own directory (it rotates primary → .prev
//     on a successful load), so on a temp copy the original is untouched.
//     A size/mtime guard test proves this empirically.
//   * GRACEFUL SKIP — the whole suite is gated on the real catalog existing.
//     On CI / a fresh machine where it is absent, every test is SKIPPED, not
//     failed, so the suite stays green. (See note on the skip mechanism
//     below.)
//   * INVARIANT, not golden — assertions are properties that hold no matter
//     how the catalog churns (empty→all, case-insensitivity, AND-narrowing,
//     index==canonical, count==filter.count, derived-substring membership).
//     No hard-coded record counts that would rot as Rick scans more media.
//
// Skip mechanism note (Swift Testing idiom vs the literal ask):
//   The task suggested `try #require(fileExists)` for the skip. In Swift
//   Testing a FAILED `#require` records a *failure*, not a skip — it would
//   turn CI red on machines without the file, the opposite of the goal. The
//   genuine "skip cleanly" primitive is the `.enabled(if:)` suite trait
//   (already used by CICanaryTests in this codebase): when the predicate is
//   false the tests simply don't run and the suite reports green. That is
//   what we use here. Inside tests we still `#require` the loaded corpus is
//   non-empty, which IS a real precondition worth failing on if it breaks.
//
// C++ analogy: `#expect(x == y)` ≈ EXPECT_EQ(x, y) (non-fatal, keeps going);
// `try #require(x)` ≈ ASSERT_TRUE(x) (fatal for this test, unwinds). The
// `.enabled(if:)` trait has no GoogleTest analog — it is a compile-time-
// attached, run-time-evaluated gate, closest to a GTEST_SKIP() decided
// before the test body runs.

// MARK: - File-scope helpers (kept out of the @MainActor type so the
// `.enabled(if:)` trait can reference them without a self-reference.)

/// The real catalog location: ~/Library/Application Support/VideoScan/catalog.json
private func realCatalogURL() -> URL {
    let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support")
    return appSupport
        .appendingPathComponent("VideoScan", isDirectory: true)
        .appendingPathComponent("catalog.json")
}

/// Gate predicate for the suite. False on machines without the catalog
/// (CI, fresh checkouts) → the whole suite is skipped, staying green.
private func realCatalogExists() -> Bool {
    FileManager.default.fileExists(atPath: realCatalogURL().path)
}

@MainActor
@Suite("RealDataSearch", .enabled(if: realCatalogExists()))
struct RealDataSearchTests {

    // MARK: - Shared, once-loaded corpus
    //
    // Decoding 19K records + building the inverted index costs real time, and
    // every test needs the same corpus. Load it once and cache. Each access
    // goes through the SAME nondestructive temp-copy path; the dedicated
    // nondestructive test below does its own copy and additionally proves the
    // original's bytes/mtime are untouched.

    @MainActor private static var cachedRecords: [VideoRecord]?
    @MainActor private static var cachedIndex: CatalogSearchIndex?

    /// Copy the real catalog into a fresh temp dir and return that dir.
    private static func makeTempCopyDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RealDataSearchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: realCatalogURL(),
            to: tmp.appendingPathComponent("catalog.json")
        )
        return tmp
    }

    /// Load the real catalog (via a throwaway copy + the production decode
    /// path) once, build the index once, and cache both.
    private static func shared() throws -> (records: [VideoRecord], index: CatalogSearchIndex) {
        if let r = cachedRecords, let i = cachedIndex { return (r, i) }
        let tmp = try makeTempCopyDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Non-shared store → bypasses the test-host short-circuit (which only
        // fires for CatalogStore.shared), so this runs the REAL JSONDecoder +
        // ISO8601 + pairedWith-rewiring path against the copy.
        let store = CatalogStore(directory: tmp)
        let records = store.load()
        let index = CatalogSearchIndex()
        index.rebuild(records: records)
        cachedRecords = records
        cachedIndex = index
        return (records, index)
    }

    // MARK: - Data-derived term mining
    //
    // Everything below derives its query terms FROM the loaded corpus so the
    // suite self-adapts to whatever Rick's catalog currently holds and never
    // hard-codes specific content.

    /// Lowercased maximal alphanumeric runs of a string.
    private static func words(in s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// The most frequent filename words of at least `minLen` chars, most
    /// common first. These are guaranteed to match the filename field, so
    /// each yields a non-empty result set.
    private static func commonFilenameWords(_ records: [VideoRecord],
                                            minLen: Int = 3,
                                            limit: Int = 8) -> [String] {
        var freq: [String: Int] = [:]
        for rec in records {
            // Dedup within a filename so one long name doesn't dominate.
            for w in Set(words(in: rec.filename)) where w.count >= minLen {
                freq[w, default: 0] += 1
            }
        }
        return freq.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    /// The most frequently tagged person name (detected + suspected +
    /// confirmed), if any — used to exercise the people-field token path.
    private static func commonPersonName(_ records: [VideoRecord]) -> String? {
        var freq: [String: Int] = [:]
        for rec in records {
            for p in rec.detectedPeople { freq[p.lowercased(), default: 0] += 1 }
            for p in rec.suspectedPeople { freq[p.lowercased(), default: 0] += 1 }
            for t in rec.confirmedByUserPeople { freq[t.name.lowercased(), default: 0] += 1 }
        }
        // First alphanumeric word of the most common name (avoid spaces so it
        // stays a single substring token).
        return freq.sorted { $0.value > $1.value }
            .lazy
            .compactMap { words(in: $0.key).first }
            .first { $0.count >= 3 }
    }

    // MARK: - Timing helper

    /// Wall-clock seconds for one execution of `body`.
    private static func seconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now()
        body()
        let end = DispatchTime.now()
        return Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000.0
    }

    private static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    // MARK: - 0. Nondestructiveness guard
    //
    // regression: loading the real catalog must NEVER mutate the original
    // file. Capture size + mtime, run a full copy+load through the production
    // path, and assert the original is byte-identical-sized and not re-stamped.
    @Test func nondestructive_originalCatalogUnchanged() throws {
        let original = realCatalogURL()
        let fm = FileManager.default

        let before = try fm.attributesOfItem(atPath: original.path)
        let sizeBefore = (before[.size] as? NSNumber)?.uint64Value
        let mtimeBefore = before[.modificationDate] as? Date
        #expect(sizeBefore != nil, "Original catalog should report a size")
        #expect(mtimeBefore != nil, "Original catalog should report a modification date")

        // Full copy + production-path load against the COPY only.
        let tmp = try Self.makeTempCopyDir()
        defer { try? fm.removeItem(at: tmp) }
        let store = CatalogStore(directory: tmp)
        let records = store.load()
        #expect(!records.isEmpty, "Production load of the real catalog returned no records")

        let after = try fm.attributesOfItem(atPath: original.path)
        let sizeAfter = (after[.size] as? NSNumber)?.uint64Value
        let mtimeAfter = after[.modificationDate] as? Date

        #expect(sizeAfter == sizeBefore,
                "Original catalog size changed (\(sizeBefore ?? 0) → \(sizeAfter ?? 0)) — load was NOT nondestructive")
        #expect(mtimeAfter == mtimeBefore,
                "Original catalog mtime changed — load touched the original file")

        // The temp copy is the thing that may have grown a sibling .prev — that
        // proves the rotation happened in the SANDBOX dir, not next to the real
        // catalog.
        #expect(fm.fileExists(atPath: tmp.appendingPathComponent("catalog.json.prev").path),
                "Production load should have rotated the COPY's primary → .prev (inside the temp dir)")
        #expect(!fm.fileExists(atPath: realCatalogURL().deletingLastPathComponent()
                    .appendingPathComponent("catalog.json.prev.realdatatest").path),
                "Sanity: no stray test artifact next to the real catalog")
    }

    // MARK: - 1. Empty query returns everything
    @Test func emptyQueryReturnsAll() throws {
        let (records, idx) = try Self.shared()
        try #require(!records.isEmpty)
        #expect(idx.filter(records: records, query: "").count == records.count)
        #expect(idx.count(records: records, query: "") == records.count)
    }

    // MARK: - 2. Case-insensitivity on real terms
    @Test func caseInsensitiveOnRealTerms() throws {
        let (records, idx) = try Self.shared()
        try #require(!records.isEmpty)
        let terms = Self.commonFilenameWords(records, minLen: 4, limit: 5)
        try #require(!terms.isEmpty, "Could not derive any common filename word")
        for t in terms {
            let lower = Set(idx.filter(records: records, query: t).map(\.fullPath))
            let upper = Set(idx.filter(records: records, query: t.uppercased()).map(\.fullPath))
            #expect(lower == upper,
                    "Case sensitivity drift on '\(t)': \(lower.count) vs \(upper.count)")
        }
    }

    // MARK: - 3. AND-narrowing
    //
    // regression: a multi-token query is the intersection of its tokens —
    // adding a term can only shrink (or hold) the result set, never grow it.
    @Test func andNarrowsResultSet() throws {
        let (records, idx) = try Self.shared()
        try #require(!records.isEmpty)
        let words = Self.commonFilenameWords(records, minLen: 4, limit: 6)
        try #require(words.count >= 2, "Need two common terms for AND-narrowing")
        let a = words[0], b = words[1]
        let setA  = Set(idx.filter(records: records, query: a).map(\.fullPath))
        let setB  = Set(idx.filter(records: records, query: b).map(\.fullPath))
        let setAB = Set(idx.filter(records: records, query: "\(a) \(b)").map(\.fullPath))
        #expect(!setA.isEmpty && !setB.isEmpty, "Derived terms should both match real records")
        #expect(setAB.isSubset(of: setA), "'\(a) \(b)' must be ⊆ '\(a)'")
        #expect(setAB.isSubset(of: setB), "'\(a) \(b)' must be ⊆ '\(b)'")
    }

    // MARK: - 4a. INDEX is SOUND vs CANONICAL (strict, has teeth)
    //
    // regression: the inverted-index accelerator must NEVER return a record the
    // canonical catalog-bar matcher (pfRecordFilenameOrPersonMatch) would NOT —
    // i.e. zero false positives. Set(index) ⊆ Set(canonical) for every query,
    // fast-path AND fallback-path. This is a genuine, currently-PASSING guard:
    // it would fail loudly if the fast path ever started over-matching (e.g. a
    // bad bucket union, stale wordIndex entry, or tokenizer change that widened
    // word boundaries). See 4c for the *completeness* direction, which is
    // currently a known production bug.
    @Test func indexNeverOverReturnsVsCanonical() throws {
        let (records, idx) = try Self.shared()
        try #require(!records.isEmpty)
        for q in Self.queryBattery(records) {
            let viaIndex = Set(idx.filter(records: records, query: q).map(\.fullPath))
            let viaCanon = Set(records.filter { pfRecordFilenameOrPersonMatch($0, query: q) }.map(\.fullPath))
            #expect(viaIndex.isSubset(of: viaCanon),
                    "Index OVER-returned on '\(q)': \(viaIndex.subtracting(viaCanon).count) record(s) the canonical matcher rejects")
        }
    }

    // MARK: - 4b. FALLBACK path == CANONICAL exactly (strict, has teeth)
    //
    // regression: any query that bypasses the inverted index (partial word,
    // quoted phrase, field/year token) routes through the linear per-record
    // matcher, which MUST be exactly the canonical matcher. On the real corpus
    // these queries match canonical to the record. This pins the linear scan —
    // the path the perf sensor below also exercises — and localizes the known
    // fast-path bug (4c) to `tryIndexLookup`, not the fallback.
    @Test func fallbackPathExactlyMatchesCanonical() throws {
        let (records, idx) = try Self.shared()
        try #require(!records.isEmpty)
        for q in Self.forcedFallbackQueries(records) {
            let viaIndex = Set(idx.filter(records: records, query: q).map(\.fullPath))
            let viaCanon = Set(records.filter { pfRecordFilenameOrPersonMatch($0, query: q) }.map(\.fullPath))
            #expect(viaIndex == viaCanon,
                    "Fallback/canonical divergence on '\(q)': index=\(viaIndex.count) canonical=\(viaCanon.count)")
        }
    }

    // MARK: - 4c. INDEX == CANONICAL on real data (STRICT — primary proof)
    //
    // regression: the production contract (CatalogSearchIndex.swift:34) states
    // `filter` MUST return the SAME records as the canonical catalog matcher.
    // This asserts FULL equivalence — completeness AND soundness — on the real
    // 19K-record corpus, for every query in the data-derived battery.
    //
    // History: this previously failed because the inverted-index fast path did
    // a WHOLE-WORD bucket lookup while the canonical matcher does SUBSTRING
    // matching. A token like "rick" is a standalone word in some records yet an
    // INFIX of "rickb"/"RicksBackups" directory paths in ~10K others — the
    // whole-word bucket missed every infix hit (index 917 vs canonical 11016).
    // The fix (the "infix-safety gate" in tryIndexLookup) only trusts a
    // whole-word bucket when the needle is NOT also an infix of any OTHER
    // indexed word; otherwise it bails to the linear matcher. With that gate in
    // place the fast path is provably the complete substring-match set, so this
    // equivalence now holds STRICT.
    //
    // The synthetic suites (CatalogSearchIndexTests) never had this infix
    // overlap, so they passed while real search was wrong — exactly the class
    // of bug this real-data harness exists to catch. CatalogSearchIndexTests
    // now also carries a synthetic infix regression so the fix is pinned
    // without real data (CI-safe).
    @Test func indexEqualsCanonicalOnRealData() throws {
        let (records, idx) = try Self.shared()
        try #require(!records.isEmpty)
        for q in Self.queryBattery(records) {
            let viaIndex = Set(idx.filter(records: records, query: q).map(\.fullPath))
            let viaCanon = Set(records.filter { pfRecordFilenameOrPersonMatch($0, query: q) }.map(\.fullPath))
            #expect(viaIndex == viaCanon,
                    "Index/canonical divergence on '\(q)': index=\(viaIndex.count) canonical=\(viaCanon.count) (missed \(viaCanon.subtracting(viaIndex).count), extra \(viaIndex.subtracting(viaCanon).count))")
        }
    }

    // MARK: - 5. count == filter.count for every query
    @Test func countAgreesWithFilter() throws {
        let (records, idx) = try Self.shared()
        try #require(!records.isEmpty)
        for q in Self.queryBattery(records) {
            #expect(idx.count(records: records, query: q) == idx.filter(records: records, query: q).count,
                    "count != filter.count on '\(q)'")
        }
    }

    // MARK: - 6. Derived-substring membership
    //
    // Pick a real record, derive a clean word token from its filename, and
    // assert (a) the result set is non-empty and (b) that very record is in it.
    // The term comes FROM the data so it can never go stale.
    @Test func derivedSubstringFindsItsRecord() throws {
        let (records, idx) = try Self.shared()
        try #require(!records.isEmpty)
        // Find a record whose filename yields a usable (len ≥ 4) word token.
        var picked: (rec: VideoRecord, term: String)?
        for rec in records {
            if let w = Self.words(in: rec.filename).first(where: { $0.count >= 4 }) {
                picked = (rec, w); break
            }
        }
        let (rec, term) = try #require(picked, "No record had a filename word ≥ 4 chars")
        let results = idx.filter(records: records, query: term)
        #expect(results.count >= 1, "Derived term '\(term)' returned nothing")
        #expect(results.contains { $0.fullPath == rec.fullPath },
                "Record '\(rec.filename)' missing from results for its own filename term '\(term)'")
    }

    // MARK: - 7. Perf regression sensor at REAL scale
    //
    // regression: search latency at the real 19K-record scale. The current
    // suites only measure the synthetic 10K corpus. Crucially this measures
    // BOTH paths:
    //   * FAST PATH — whole-word queries that hit the inverted index.
    //   * FALLBACK PATH — partial word, quoted multi-word phrase, and a
    //     field/year token. These bypass the inverted index and force the
    //     linear per-record haystack scan (the real worst case). This is the
    //     latency Rick actually cares about.
    // Median of several runs (not a single sample), generous ceiling so it
    // catches a true regression without flaking in Debug. Actual medians are
    // printed so Rick can read real numbers off the test log.
    @Test func perfSensorFastVsFallback() throws {
        let (records, idx) = try Self.shared()
        try #require(!records.isEmpty)

        let words = Self.commonFilenameWords(records, minLen: 3, limit: 8)
        try #require(words.count >= 2, "Need terms to build perf queries")
        let a = words[0], b = words[1]
        // A long word to truncate into a partial (non-whole) needle.
        let longWord = words.first(where: { $0.count >= 6 }) ?? a
        let partial = String(longWord.prefix(4))   // e.g. "elev" of "elevator"

        // Fast-path queries: complete words present in the index.
        let fastQueries = [a, b, "\(a) \(b)"]
        // Fallback-path queries: each forces the linear scan.
        let fallbackQueries = [
            partial,            // partial word — not a whole index word
            "\"\(a) \(b)\"",    // quoted phrase (needle contains a space)
            "year:1995",        // year-range token — needs structural access
        ]

        let runs = 7
        let ceiling = 2.0   // seconds — Debug, unoptimized; flags a real regression

        func medianSeconds(of queries: [String]) -> Double {
            var samples: [Double] = []
            for _ in 0..<runs {
                samples.append(Self.seconds {
                    for q in queries { _ = idx.filter(records: records, query: q) }
                })
            }
            return Self.median(samples)
        }

        let fastMedian = medianSeconds(of: fastQueries)
        let fallbackMedian = medianSeconds(of: fallbackQueries)

        // Visible in the test log (print survives in xcodebuild output).
        print("""
        [RealDataSearch perf] records=\(records.count) runs=\(runs)
          fast-path     queries=\(fastQueries)         median=\(String(format: "%.4f", fastMedian))s
          fallback-path queries=\(fallbackQueries)     median=\(String(format: "%.4f", fallbackMedian))s
        """)

        #expect(fastMedian < ceiling,
                "Fast-path median \(fastMedian)s exceeded \(ceiling)s ceiling at \(records.count) records")
        #expect(fallbackMedian < ceiling,
                "Fallback-path median \(fallbackMedian)s exceeded \(ceiling)s ceiling at \(records.count) records")
    }

    // MARK: - Query battery (data-derived; spans fast + fallback paths)

    private static func queryBattery(_ records: [VideoRecord]) -> [String] {
        var qs: [String] = [""]
        let words = commonFilenameWords(records, minLen: 3, limit: 6)
        qs.append(contentsOf: words)                       // fast-path whole words
        if words.count >= 2 {
            qs.append("\(words[0]) \(words[1])")            // multi-token AND (fast)
            qs.append(words[0].uppercased())               // case variant
            qs.append("\"\(words[0]) \(words[1])\"")       // quoted phrase (fallback)
        }
        if let long = words.first(where: { $0.count >= 6 }) {
            qs.append(String(long.prefix(4)))              // partial word (fallback)
        }
        if let person = commonPersonName(records) {
            qs.append(person)                              // plain person substring
            qs.append("people:\(person)")                  // people field token (fallback)
        }
        qs.append("year:1995")                             // year token (fallback)
        qs.append("1990s")                                 // decade shorthand (fallback)
        qs.append("zzz_no_such_term_qx9")                  // guaranteed-empty
        return qs
    }

    /// Queries that are GUARANTEED to bypass the inverted-index fast path and
    /// route through the linear (canonical-equivalent) matcher: a partial word,
    /// a quoted multi-word phrase, a year token, a decade shorthand, and a
    /// people field token. Used by `fallbackPathExactlyMatchesCanonical` and
    /// the fallback perf sample.
    private static func forcedFallbackQueries(_ records: [VideoRecord]) -> [String] {
        let words = commonFilenameWords(records, minLen: 3, limit: 6)
        var qs: [String] = []
        if let long = words.first(where: { $0.count >= 6 }) {
            qs.append(String(long.prefix(4)))              // partial word
        } else if let w = words.first {
            qs.append(String(w.prefix(max(1, w.count - 1)))) // shorter partial
        }
        if words.count >= 2 {
            qs.append("\"\(words[0]) \(words[1])\"")        // quoted phrase
        }
        qs.append("year:1995")                             // year-range token
        qs.append("1990s")                                 // decade shorthand
        if let person = commonPersonName(records) {
            qs.append("people:\(person)")                  // people field token
        }
        return qs
    }
}
