import Testing
import Foundation
@testable import VideoScan

// MARK: - Archivist query bench (2026-08-01)
//
// Performance sensors for the NL-search hot paths, built for codex to
// run, tighten, and extend. Conventions follow CatalogSearchProfileBench:
// 100k Rick-shaped synthetic records (reused from that suite), printed
// measurements for the record, LOOSE absolute budgets (they must pass on
// a loaded Debug CI box), and RELATIVE assertions where the claim is
// structural ("the index path is not slower than the linear path") —
// those hold on any machine at any optimization level.
//
// Real numbers belong to Release runs (build-mode policy): re-run there
// before quoting figures. Debug numbers are still useful as regression
// ratios.

@MainActor
@Suite("ArchivistQueryBench", .serialized)
struct ArchivistQueryBench {

    static func ms(_ body: () -> Void) -> Double {
        let t0 = ContinuousClock.now
        body()
        return Double((ContinuousClock.now - t0).components.attoseconds) / 1e15
    }

    /// The archivist's bread-and-butter query shapes at 100k records:
    /// person, person+era+kind, era+kind. Asserts the planner's indexed
    /// path is never SLOWER than the canonical linear scan, and prints
    /// both so codex can track the ratio over time.
    @Test func personQueryShapesAt100k() {
        let records = CatalogSearchProfileBench.makeRickShapedCorpus(100_000)
        let index = CatalogSearchIndex()
        let buildMs = Self.ms { index.rebuild(records: records) }

        let shapes = [
            "people:donna",
            "people:donna year:1990..1999 type:video",
            "people:dan type:video-only",
        ]
        for query in shapes {
            var indexedHits = 0
            let indexedMs = Self.ms {
                indexedHits = index.filter(records: records, query: query).count
            }
            var linearHits = 0
            let linearMs = Self.ms {
                linearHits = records.lazy.filter { pfRecordMatchesQuery($0, query: query) }.count
            }
            print(String(format: "bench '%@': indexed %.2f ms (%d hits) vs linear %.2f ms (%d hits) — %.1fx",
                         query, indexedMs, indexedHits, linearMs, linearHits,
                         linearMs / max(indexedMs, 0.001)))
            // Correctness first, speed second — a fast wrong answer is a bug.
            #expect(indexedHits == linearHits, "'\(query)': indexed \(indexedHits) != linear \(linearHits)")
            // Structural claim: narrowing through the person index must not
            // lose to the full scan (allow 1ms noise floor for tiny queries).
            #expect(indexedMs <= linearMs + 1.0,
                    "'\(query)': indexed \(indexedMs) ms slower than linear \(linearMs) ms")
            // Loose absolute ceiling — the archivist applies queries per
            // chat message; even Debug on a loaded box must stay interactive.
            #expect(indexedMs < 2_000, "'\(query)' took \(indexedMs) ms at 100k")
        }
        print(String(format: "bench index rebuild at 100k: %.0f ms", buildMs))
        #expect(buildMs < 60_000, "100k rebuild took \(buildMs) ms")
    }

    /// knownPeople() feeds archivist autocomplete on every keystroke —
    /// it must be trivially cheap even at 100k records.
    @Test func knownPeopleVocabularyIsCheapAt100k() {
        let records = CatalogSearchProfileBench.makeRickShapedCorpus(100_000)
        let index = CatalogSearchIndex()
        index.rebuild(records: records)
        var names = 0
        let vocabMs = Self.ms { names = index.knownPeople().count }
        print(String(format: "bench knownPeople: %.3f ms (%d names)", vocabMs, names))
        #expect(names > 0)
        #expect(vocabMs < 100, "knownPeople took \(vocabMs) ms")
    }

    /// NL preprocessing throughput: normalize+compose is everything the
    /// archivist does around the LLM call — it must be noise next to it.
    /// 10k specs through the full pipeline, budgeted generously.
    @Test func nlNormalizeComposeThroughput() {
        let specs: [NLQuerySpec] = (0..<10_000).map { i in
            NLQuerySpec(
                people: ["Donna", "Dad Breen"],
                yearStart: 1990 + (i % 10),
                yearEnd: 1995,
                mediaKind: ["videos", "movies", "audio", "hologram"][i % 4],
                keywords: ["down the cape", "christmas"],
                transcript: ["happy birthday"],
                intent: i % 5 == 0 ? "count" : "filter")
        }
        var composedChars = 0
        let pipelineMs = Self.ms {
            for spec in specs {
                composedChars += NLQueryComposer
                    .infixString(for: NLQueryNormalizer.normalize(spec)).count
            }
        }
        print(String(format: "bench NL pipeline: 10k specs in %.1f ms (%.1f µs/spec)",
                     pipelineMs, pipelineMs * 1000 / 10_000))
        #expect(composedChars > 0)
        #expect(pipelineMs < 2_000, "10k normalize+compose took \(pipelineMs) ms")
    }
}
