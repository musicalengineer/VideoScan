// CatalogSearchBenchmarkTests.swift
// feature/search-benchmarks — headless catalog-search benchmark suite.
//
// Hard numbers for the search stack: CatalogSearchIndex
// (filter/count/rebuild/persistence, memmem haystack scan, inverted word
// index + infix-safety gate, precomputed year sets) against the canonical
// matcher/tokenizer in CatalogQueries.swift.
//
// Three tests:
//
//   1. searchSmokeSensorAt17k — ALWAYS ON. 17k corpus, 3 queries. The
//      regression sensor: correctness (index == canonical) everywhere,
//      timing budgets in Release only (per project build-mode policy a
//      Debug run is not a perf measurement — same #if !DEBUG pattern as
//      CatalogSearchBudgetSensorTests).
//
//   2. fullBenchmarkMatrix — HEAVY, gated behind VS_RUN_SEARCH_BENCH=1
//      (like CombinePipelineIntegrationTests' env gate). Runs the full
//      10-query matrix at 100k, plus rebuild timing, saveToDisk +
//      loadFromDisk round-trip, and an approximate index-memory figure.
//
//   3. realCatalogBenchmark — optional. If VS_SEARCH_BENCH_CATALOG points
//      at a COPY of a catalog JSON ({version, savedAt, records:[...]}
//      envelope, decoded exactly like CatalogStore), runs the same matrix
//      against it. Skips when unset. Never reads the real App Support path.
//
// To run the heavy suite (env reaches the test host via xcodebuild's
// TEST_RUNNER_ prefix, same as VS_RUN_COMBINE_INTEGRATION):
//
//   xcodebuild test \
//     -project VideoScan/VideoScan.xcodeproj -scheme VideoScan \
//     -configuration Release -derivedDataPath .dd \
//     -only-testing:VideoScanTests/CatalogSearchBenchmarkTests \
//     TEST_RUNNER_VS_RUN_SEARCH_BENCH=1 \
//     TEST_RUNNER_VS_BENCH_OUT=/tmp/searchbench.jsonl
//
// CORRECTNESS GUARD: every benchmarked query asserts that
// CatalogSearchIndex.filter == brute-force pfRecordFilenameOrPersonMatch
// over the same records (the correctness contract in CatalogSearchIndex's
// header). A benchmark that measures a wrong answer is worthless.
//
// BUDGETS (Release-only sensors; the VALUE is the printed numbers):
// two tiers, because the corpus spec here is deliberately transcript-heavy
// (~40% of records carry 1–10 KB transcripts vs 7.9% in the Rick-shaped
// #123 corpus) and the linear-regime full memmem scan provably cannot meet
// a single 60 ms ceiling at 100k on that much text — the #123 sensors
// already budget linear-regime queries at 165 ms on a ~3x LIGHTER corpus.
//   fast tier   (index fast path / year sets / field tokens):
//                 15 ms median @17k, 60 ms @100k   (task-spec numbers)
//   linear tier (partial words, infix-defeated words, phrases, zero-hit):
//                 80 ms median @17k, 400 ms @100k  (~2x expected headroom)
// Rebuild: 5 s median @100k.

import Testing
import Foundation
@testable import VideoScan

@MainActor
@Suite("CatalogSearchBench", .serialized)
struct CatalogSearchBenchmarkTests {

    // MARK: - Env gates

    nonisolated static var benchEnabled: Bool {
        ProcessInfo.processInfo.environment["VS_RUN_SEARCH_BENCH"] == "1"
    }
    nonisolated static var realCatalogPath: String? {
        let p = ProcessInfo.processInfo.environment["VS_SEARCH_BENCH_CATALOG"]
        return (p?.isEmpty == false) ? p : nil
    }

    // MARK: - Query matrix

    /// Whether a query is expected to be answered via the inverted-index
    /// fast path / precomputed sets (fast) or via the linear per-record
    /// memmem scan (linear). Drives the two-tier budgets only — the
    /// correctness guard is identical for both.
    enum Tier { case fast, linear }

    /// The 10-case matrix. Expected regime, by construction of the corpus:
    ///  1. "d"      — one-char prefix; not an indexed word → linear
    ///  2. "don"    — partial word (infix of donna/madonna) → linear
    ///  3. "donna"  — complete word, but infix-DEFEATED by the planted
    ///                superstrings (madonna/belladonna) → linear. This is
    ///                the real-catalog shape for name queries.
    ///  4. unique transcript needle — unique word, no superstring →
    ///                whole-word fast path, 1-element bucket
    ///  5. "zzqx"   — zero hits; NOT an indexed word, so the index CANNOT
    ///                prove absence → full linear scan with no early exits
    ///                (the true worst case, worth watching)
    ///  6. "donna christmas 1997" — multi-token AND; "donna" defeats the
    ///                fast path for the whole query → linear
    ///  7. "1990s"  — yearRange token → linear walk but per-record work is
    ///                a precomputed-set membership test (PR D) → fast tier
    ///  8. "people:donna" — field token → per-record canonical field match
    ///                over tiny arrays → fast tier
    ///  9. "cape cod" (quoted) — phrase → linear
    /// 10. planted pair — two complete non-infix words → intersection
    ///                fast path CAN fire
    static let matrix: [(query: String, tier: Tier)] = [
        ("d", .linear),
        ("don", .linear),
        ("donna", .linear),
        (SearchBenchCorpus.uniqueTranscriptNeedle, .fast),
        ("zzqx", .linear),
        ("donna christmas 1997", .linear),
        ("1990s", .fast),
        ("people:donna", .fast),
        (SearchBenchCorpus.phraseTarget, .linear),
        (SearchBenchCorpus.fastPairQuery, .fast),
    ]

    static func queryBudgetMs(_ tier: Tier, corpusSize: Int) -> Double {
        let big = corpusSize > 50_000
        switch tier {
        case .fast:   return big ? 60 : 15
        case .linear: return big ? 400 : 80
        }
    }

    // MARK: - Correctness guard

    /// Brute-force canonical answer: the catalog-narrow matcher applied
    /// per record. THE reference the index contracts to reproduce.
    static func canonicalFilter(_ records: [VideoRecord], _ query: String) -> [String] {
        records.filter { pfRecordFilenameOrPersonMatch($0, query: query) }
            .map(\.fullPath)
    }

    /// Assert index.filter == canonical for `query`, returning the hit
    /// count so callers can also sanity-check planted-needle populations.
    @discardableResult
    static func assertCorrectness(
        _ records: [VideoRecord],
        _ index: CatalogSearchIndex,
        _ query: String,
        corpusLabel: String
    ) -> Int {
        let viaIndex = index.filter(records: records, query: query).map(\.fullPath)
        let canonical = canonicalFilter(records, query)
        #expect(viaIndex == canonical,
                "correctness contract violated for '\(query)' on \(corpusLabel): index returned \(viaIndex.count) rows, canonical matcher \(canonical.count)")
        return canonical.count
    }

    // MARK: - Shared per-corpus benchmark body

    /// Runs the full measurement set over one prepared corpus. Reused by
    /// the synthetic 17k/100k runs and the optional real-catalog run.
    /// `assertBudgets` is false for the real catalog (unknown shape — we
    /// report, we don't gate).
    static func runMatrix(
        records: [VideoRecord],
        corpusLabel: String,
        assertBudgets: Bool,
        exportsMeasurements: Bool = true
    ) throws {
        let runner = SearchBenchRunner(
            recordCount: records.count,
            exportsMeasurements: exportsMeasurements)
        let index = CatalogSearchIndex()

        // ---- rebuild() timing ----
        let rebuild = runner.run(operation: "rebuild", iterations: 3,
                                 expectedResultCount: records.count) {
            index.rebuild(records: records)
            return index.recordCount()
        }
        try runner.emit(rebuild)
        #expect(rebuild.resultCount == records.count, "rebuild must index every record")
        #if !DEBUG
        if assertBudgets, records.count > 50_000 {
            let rebuildMedian = rebuild.median ?? .infinity
            #expect(rebuildMedian <= 5_000,
                    "rebuild median \(rebuildMedian) ms at \(corpusLabel) — budget 5000 ms")
        }
        #endif

        // ---- approximate index memory (haystack bytes) ----
        // Sum of per-record haystack UTF-8 sizes — the dominant term of the
        // index's footprint (yearSets/wordIndex overhead excluded). This is
        // exported as a single byte value, never as latency statistics.
        var haystackBytes = 0
        for rec in records { haystackBytes += CatalogSearchIndex.buildHaystack(rec).utf8.count }
        try runner.emit(runner.footprint(bytes: haystackBytes))

        // ---- saveToDisk + loadFromDisk round-trip ----
        let persistURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-bench-\(ProcessInfo.processInfo.processIdentifier)-\(corpusLabel).plist")
        defer { try? FileManager.default.removeItem(at: persistURL) }
        let roundTrip = runner.run(operation: "persist-roundtrip", iterations: 3,
                                   expectedResultCount: records.count) {
            try? index.saveToDisk(at: persistURL)
            let fresh = CatalogSearchIndex()
            let ok = fresh.loadFromDisk(at: persistURL,
                                        catalogModifiedAt: nil,
                                        expectedRecordCount: records.count)
            return ok ? fresh.recordCount() : -1
        }
        try runner.emit(roundTrip)
        #expect(roundTrip.resultCount == records.count,
                "persistence round-trip must restore all \(records.count) records (got \(roundTrip.resultCount))")

        // ---- the query matrix ----
        for (query, tier) in matrix {
            let canonicalHits = assertCorrectness(records, index, query, corpusLabel: corpusLabel)
            let result = runner.run(operation: "query", query: query,
                                    expectedResultCount: canonicalHits) {
                index.filter(records: records, query: query).count
            }
            try runner.emit(result)
            #expect(result.resultCount == canonicalHits,
                    "benchmark measured \(result.resultCount) hits for '\(query)' but canonical says \(canonicalHits)")
            #if !DEBUG
            if assertBudgets {
                let budget = queryBudgetMs(tier, corpusSize: records.count)
                let median = result.median ?? .infinity
                #expect(median <= budget,
                        "median for '\(query)' at \(corpusLabel) was \(median) ms — budget \(budget) ms")
            }
            #endif
        }
    }

    /// Planted-needle population checks — a benchmark over a corpus whose
    /// needles didn't land where the generator promised is measuring the
    /// wrong thing. Synthetic corpora only.
    static func assertPlantedNeedles(_ records: [VideoRecord], _ index: CatalogSearchIndex, corpusLabel: String) {
        let n = records.count
        let unique = index.filter(records: records, query: SearchBenchCorpus.uniqueTranscriptNeedle)
        #expect(unique.count == 1,
                "\(corpusLabel): unique transcript needle must hit exactly 1 record (got \(unique.count))")
        #expect(index.filter(records: records, query: "zzqx").isEmpty,
                "\(corpusLabel): zero-hit query must hit nothing")
        let donna = index.filter(records: records, query: "donna").count
        let donnaFrac = Double(donna) / Double(n)
        #expect(donnaFrac > 0.04 && donnaFrac < 0.16,
                "\(corpusLabel): donna population out of shape: \(donna)/\(n)")
        // Some donna hits must be transcript-ONLY (no path/people signal) —
        // the planted 3% band.
        let transcriptOnly = records.filter {
            ($0.audioTranscript?.contains("donna") ?? false)
                && !$0.fullPath.lowercased().contains("donna")
                && !$0.detectedPeople.contains("Donna")
        }
        #expect(!transcriptOnly.isEmpty, "\(corpusLabel): need transcript-only donna records")
        let pair = index.filter(records: records, query: SearchBenchCorpus.fastPairQuery)
        #expect(!pair.isEmpty, "\(corpusLabel): fast-pair planted words missing")
        #expect(index.filter(records: records, query: "1990s").count > n / 20,
                "\(corpusLabel): year-cluster population missing")
    }

    // MARK: - 1. Always-on smoke sensor (17k, 3 queries)

    /// The regression sensor that runs in every suite invocation. Small
    /// enough to stay cheap, real enough to catch a broken fast path,
    /// year-set drift, or an index/canonical divergence.
    @Test func searchSmokeSensorAt17k() throws {
        let records = SearchBenchCorpus.make(17_000)
        #expect(Set(records.map(\.fullPath)).count == records.count,
                "corpus fullPaths must be unique — index keys on fullPath")
        let index = CatalogSearchIndex()
        index.rebuild(records: records)
        Self.assertPlantedNeedles(records, index, corpusLabel: "17k-smoke")

        let runner = SearchBenchRunner(recordCount: records.count, exportsMeasurements: false)
        // (query, Release-only budget ms): one linear-regime query
        // (infix-defeated name — the realistic worst common case), one
        // fast-path query, one yearRange query.
        let cases: [(String, Double)] = [
            ("donna", 80),
            (SearchBenchCorpus.uniqueTranscriptNeedle, 15),
            ("1990s", 15),
        ]
        for (query, budget) in cases {
            let canonicalHits = Self.assertCorrectness(records, index, query, corpusLabel: "17k-smoke")
            let result = runner.run(operation: "query", query: query,
                                    expectedResultCount: canonicalHits) {
                index.filter(records: records, query: query).count
            }
            try runner.emit(result)
            #expect(result.resultCount == canonicalHits)
            // Timing sensor is Release-only (a Debug run is not a perf
            // measurement — project build-mode policy).
            #if !DEBUG
            let median = result.median ?? .infinity
            #expect(median <= budget,
                    "smoke: median for '\(query)' was \(median) ms — budget \(budget) ms at 17k")
            #else
            _ = budget
            #endif
        }
    }

    // MARK: - 2. Full matrix (heavy — env-gated)

    @Test(.enabled(if: benchEnabled,
                   "set VS_RUN_SEARCH_BENCH=1 (TEST_RUNNER_VS_RUN_SEARCH_BENCH=1 via xcodebuild) to run the full benchmark"))
    func fullBenchmarkMatrix() throws {
        let clock = ContinuousClock()
        for n in [100_000] {
            let label = "100k"
            var records: [VideoRecord] = []
            let gen = clock.measure { records = SearchBenchCorpus.make(n) }
            print(String(format: "SEARCHBENCH | corpus=%-5@ | generated %d records in %.0f ms",
                         label as NSString, records.count, SearchBenchRunner.ms(gen)))
            #expect(Set(records.map(\.fullPath)).count == records.count,
                    "corpus fullPaths must be unique — index keys on fullPath")

            // Needle sanity on a throwaway index before timing anything.
            let probe = CatalogSearchIndex()
            probe.rebuild(records: records)
            Self.assertPlantedNeedles(records, probe, corpusLabel: label)
            print("SEARCHBENCH | corpus=\(label) | indexed_words=\(probe.indexedWordCount())")

            try Self.runMatrix(records: records, corpusLabel: label, assertBudgets: true)
        }
    }

    // MARK: - 3. Optional real-catalog mode

    /// Decodes the SAME envelope CatalogStore reads ({version, savedAt,
    /// records:[...]}, ISO-8601 dates) from a COPY the operator points at
    /// via VS_SEARCH_BENCH_CATALOG. Never touches App Support. Reports the
    /// same matrix; no budgets (unknown shape) and no synthetic-needle
    /// assertions (real data has no planted needles).
    @Test(.enabled(if: benchEnabled && realCatalogPath != nil,
                   "set VS_RUN_SEARCH_BENCH=1 and VS_SEARCH_BENCH_CATALOG=/path/to/catalog-copy.json"))
    func realCatalogBenchmark() throws {
        guard let path = Self.realCatalogPath else { return } // skip silently
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601   // matches CatalogStore.decode
        let snapshot = try decoder.decode(CatalogSnapshot.self, from: data)
        let records = snapshot.records
        print("SEARCHBENCH | corpus=real | decoded \(records.count) records (envelope v\(snapshot.version)) from \(path)")
        try #require(!records.isEmpty, "real catalog copy decoded to zero records")

        let label = "real-\(records.count / 1000)k"
        // A real catalog can contain private family metadata. It is useful
        // for an operator-only spot check but must never enter raw publisher
        // input, even when VS_BENCH_OUT is set for the synthetic suite.
        try Self.runMatrix(
            records: records,
            corpusLabel: label,
            assertBudgets: false,
            exportsMeasurements: false)
    }
}
