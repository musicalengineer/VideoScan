// SearchBenchSupport.swift
// feature/search-benchmarks — shared fixtures + measurement harness for the
// headless catalog-search benchmark suite (CatalogSearchBenchmarkTests).
//
// Two things live here, deliberately separated from the tests so they can be
// cloned for other subsystems (Rick wants this harness shape to be THE
// reusable model):
//
//   1. SearchBenchCorpus — a deterministic, seeded synthetic catalog
//      generator with PLANTED NEEDLES whose exact hit populations are known
//      by construction, so benchmarks can assert what they measure.
//   2. SearchBenchRunner — a tiny benchmark runner: warmup + measured
//      iterations via ContinuousClock, min/median/p95 in ms, one aligned
//      human-readable summary line per case, plus machine-readable JSON
//      lines appended to $VS_BENCH_OUT for the metrics JSONL pipeline.
//
// NO production source is touched by this branch (another active branch owns
// CatalogSearchIndex/CatalogQueries) — tests + fixtures only.
//
// C++ analogy: SearchBenchRunner ≈ a header-only micro-benchmark fixture
// (think a tiny google/benchmark): you hand it a lambda that returns a
// "result count" and it does the timing bookkeeping.

import Testing
import Foundation
@testable import VideoScan

// MARK: - Deterministic corpus with planted needles

enum SearchBenchCorpus {

    /// Fixed seed — NEVER derive from Date()/SystemRandom. Reproducible
    /// across machines and runs, like the CatalogSearchProfileBench corpus.
    static let fixedSeed: UInt64 = 0xB005_EED0_2026_0723

    /// Same SplitMix64 the profile bench uses (kept local so this file has
    /// no dependency on that suite's internals).
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: Planted needles (public so tests can assert exact populations)

    /// (a) Appears in EXACTLY ONE transcript in the whole corpus. A unique
    /// indexed word → exercises the whole-word fast path with a 1-element
    /// bucket (it is not an infix of any other generated word).
    static let uniqueTranscriptNeedle = "xylotheremin"

    /// (b) "donna" is spread over ~8% of records: ~5% carry it in
    /// filename/people, ~3% ONLY in the audio transcript. The corpus also
    /// plants SUPERSTRING words — the artist "Madonna" in the music tree and
    /// "belladonna" in garden transcripts — so the infix-safety gate fires
    /// and "donna" is forced down the linear path (exactly what happens on
    /// Rick's real catalog).
    static let donnaSuperstrings = ["madonna", "belladonna"]

    /// (c) Phrase target: "Cape Cod" appears SPACED in family directories
    /// (never camelCase-only, so the index's pathTokenize enrichment cannot
    /// diverge from the canonical matcher on the phrase query).
    static let phraseTarget = "\"cape cod\""

    /// (10) Two planted complete words that co-occur in ~1.5% of records
    /// and are not infixes of any other generated word → the two-token
    /// intersection fast path CAN fire.
    static let fastPairQuery = "pelicanwharf sunsetreel"

    // MARK: Vocabulary

    static let volumes = [
        "LaCie8TB", "Seagate2TB", "MyBook3Terabytes", "Crucial2TB",
        "RicksBackups", "MacStudioInternal", "IntelMacProRAID", "T5Portable",
        "GDrive4TB", "OWCEnvoyPro", "TimeCapsuleArchive", "BlueSSD",
    ]
    static let artists = [
        "The Blue Harbors", "Madonna", "Copley Square Quartet",
        "Middlefield Ramblers", "Berkshire Winds", "Harbor Lights Trio",
        "Cranberry Union", "Old Colony Brass", "Housatonic Drifters",
        "Pioneer Valley Players", "The Longmeadows", "Westfield River Band",
    ]
    static let albums = [
        "Greatest Hits", "Live At The Orpheum 1993", "Autumn Sessions",
        "Homecoming", "Acoustic Evenings", "Studio Outtakes Vol 2",
        "The Early Years", "Winter Light", "One More Round", "Signal Fires",
    ]
    /// Family occasions. "Cape Cod" spaced (see phraseTarget); camelCase
    /// compounds are built from these for filenames/projects.
    static let places = [
        "Cape Cod", "Brockton", "Westford", "Cottage", "Beach", "Christmas",
        "Birthday", "Graduation", "Middlefield", "Fourth Of July",
    ]
    /// People names — Donna/Rick/Tim variants per the corpus spec.
    static let names = ["Donna", "Rick", "Ricky", "Tim", "Timmy", "Mark", "Dan", "Matt"]
    /// Names injected into transcripts. Deliberately EXCLUDES Donna so the
    /// "donna" population is controlled solely by the planted bands
    /// (~5% path/people + ~3% transcript-only + Madonna-superstring dirs).
    static let transcriptNames = ["Rick", "Timmy", "Mark", "Dan", "Matt"]
    static let years = [1988, 1990, 1991, 1992, 1993, 1995, 1996, 1997, 1999, 2001, 2004, 2007, 2010]

    /// Pre-joined transcript sentence chunks (~100–130 chars each) so
    /// transcript synthesis is O(chunks) appends, not O(words) — keeps 100k
    /// generation tolerable in Debug builds. None of these words contain
    /// the planted needles as substrings.
    static let transcriptChunks: [String] = [
        "okay everybody look over here hold the camera steady we are almost ready to sing happy birthday to you",
        "yeah the water is freezing but the kids went in anyway grandma is waving from the porch with her big hat",
        "hold on let me get the cake out first the candles keep blowing out in the wind can somebody block the breeze",
        "the parade went right past the house this year fire trucks and the marching band and everyone waving flags",
        "we drove out along the shore road and stopped for ice cream the lighthouse was open so we climbed to the top",
        "snow again this morning the driveway took an hour to clear then the sledding started down the back hill",
        "graduation gowns everywhere we could barely find our seats the speeches went long but the weather held up",
        "somebody turn the music down a little the baby is asleep upstairs and we are trying to play cards out here",
        "the garden did great this year tomatoes and squash and the scarecrow stayed up by the fence all summer",
        "first day of school photos on the front steps new backpacks and nervous smiles then the bus came early",
        "the old projector still works we watched the wedding reels twice and everyone argued about the year",
        "campfire smoke follows me every time i move my chair marshmallows are gone somebody hid the chocolate",
    ]

    /// Deterministic date base (~1990) — record dates derive from index
    /// arithmetic, not from wall-clock Date().
    static let baseDate = Date(timeIntervalSince1970: 660_000_000)

    // MARK: Generator

    /// Build `n` records. Deterministic for a given `n` (the planted-needle
    /// positions use index arithmetic + the fixed-seed PRNG only).
    ///
    /// Shape targets (corpus spec for this suite — heavier on transcripts
    /// than the Rick-shaped #123 corpus on purpose, to stress the haystack
    /// scan):
    ///   * ~12 volumes, camelCase filenames/dirs
    ///   * transcripts: ~60% none, ~30% 1–3 KB, ~10% 5–10 KB
    ///   * "donna" on ~8% of records (~3% transcript-ONLY)
    ///   * OCR snippets, scene captions, year signals in paths and dates
    static func make(_ n: Int) -> [VideoRecord] {
        var rng = SplitMix64(seed: fixedSeed)
        var out: [VideoRecord] = []
        out.reserveCapacity(n)
        let uniqueNeedleIndex = n / 2   // exactly one transcript gets it

        for i in 0..<n {
            let r = VideoRecord()
            let roll = Double(rng.next() % 10_000) / 10_000.0
            let volume = volumes[i % volumes.count]
            let year = years[i % years.count]
            r.dateCreatedRaw = baseDate.addingTimeInterval(Double(year - 1990) * 365.25 * 86_400 + Double(i % 300) * 86_400)
            r.dateCreated = "2024-01-01 12:00"

            // donna population: ~5% path/people, ~3% transcript-only.
            let donnaInPath = (i % 20 == 7)                    // 5%
            let donnaTranscriptOnly = (i % 100 >= 90 && i % 100 < 93) // 3%
            // fast-pair population (~1.5%): planted caption words.
            let fastPair = (i % 200 == 11)

            if roll < 0.45 {
                // ---- music/audio tree (camelCase artist dirs, Madonna superstring) ----
                let artist = artists[Int(rng.next() % UInt64(artists.count))]
                let album = albums[Int(rng.next() % UInt64(albums.count))]
                let ext = ["aif", "wav", "m4a", "mp3", "caf"][i % 5]
                let camelArtist = artist.replacingOccurrences(of: " ", with: "")
                r.filename = String(format: "%02d %@ Track %d.%@", (i % 14) + 1, camelArtist, i, ext)
                r.directory = "/Volumes/\(volume)/Users/rickb/Music/iTunes/iTunes Media/Music/\(artist)/\(album)"
                r.ext = ext
                r.streamTypeRaw = StreamType.audioOnly.rawValue
                r.audioCodec = ext == "mp3" ? "mp3" : (ext == "m4a" ? "aac" : "pcm_s16le")
            } else if roll < 0.80 {
                // ---- family video (spaced dir + camelCase project name) ----
                let place = places[Int(rng.next() % UInt64(places.count))]
                let camel = place.replacingOccurrences(of: " ", with: "")
                let ext = (i % 5 == 0) ? "mts" : "mov"
                let namePart = donnaInPath ? "Donna\(camel)" : camel
                r.filename = "\(namePart)\(year) clip \(i).\(ext)"
                r.directory = "/Volumes/\(volume)/Family Media/\(place) \(year)/iMovieProject \(camel)\(year)"
                r.ext = ext
                r.streamTypeRaw = StreamType.videoAndAudio.rawValue
                r.videoCodec = ext == "mts" ? "h264" : "dvvideo"
                r.audioCodec = "pcm_s16le"
                if donnaInPath, i % 40 == 7 {   // half the path-donna records also carry the tag
                    r.detectedPeople = ["Donna"]
                }
            } else if roll < 0.92 {
                // ---- Avid MXF video-only halves ("V1993-06-14" style —
                // puts "v1993" words in the index, which is what defeats the
                // whole-word fast path for bare-year queries in real life) ----
                r.filename = String(format: "V%d-%02d-%02d.%d.A0%d.mxf",
                                    year, (i % 12) + 1, (i % 27) + 1, i, i % 4)
                r.directory = "/Volumes/\(volume)/Avid MediaFiles/MXF/\((i % 9) + 1)"
                r.ext = "mxf"
                r.streamTypeRaw = StreamType.videoOnly.rawValue
                r.videoCodec = "dnxhd"
            } else {
                // ---- recovered/junk ----
                r.filename = "Recovered \(i).sdir"
                r.directory = "/Volumes/\(volume)/Old Projects/RecoveredItems \(i % 40)"
                r.ext = "sdir"
                r.streamTypeRaw = StreamType.ffprobeFailed.rawValue
            }
            r.fullPath = r.directory + "/" + r.filename
            r.scanContext.volumeName = volume
            r.sizeBytes = Int64(1_000_000 + (i % 1_000) * 10_000)

            // ---- transcripts: 60% none / 30% 1–3 KB / 10% 5–10 KB ----
            // (deterministic bucket by PRNG roll, size by index arithmetic)
            let tRoll = Double(rng.next() % 10_000) / 10_000.0
            var needsTranscript = tRoll < 0.40
            if donnaTranscriptOnly || i == uniqueNeedleIndex { needsTranscript = true }
            if needsTranscript {
                // chunk ≈ 110 chars → 1–3 KB ≈ 10–27 chunks, 5–10 KB ≈ 45–90.
                let big = tRoll < 0.10 || (!(tRoll < 0.40) && i % 4 == 0)
                let chunkCount = big ? 45 + (i % 46) : 10 + (i % 18)
                var t: [String] = []
                t.reserveCapacity(chunkCount + 4)
                for j in 0..<chunkCount {
                    t.append(transcriptChunks[(i + j) % transcriptChunks.count])
                    if j % 7 == 3 { t.append(transcriptNames[(i + j) % transcriptNames.count].lowercased()) }
                    if j % 11 == 5 { t.append("\(years[(i + j) % years.count])") }
                }
                if donnaTranscriptOnly {
                    t.append("and then donna started singing near the camera")
                }
                // Superstring planting: "belladonna" must EXIST as an indexed
                // word (one record is enough to defeat the whole-word fast
                // path for "donna" via the infix gate) but must stay RARE —
                // substring semantics mean every belladonna record also
                // counts as a "donna" hit, and an earlier draft that put it
                // in the cycling chunks inflated the donna population to 46%.
                if i % 211 == 13 {
                    t.append("mind the belladonna sign by the back fence")
                }
                if i == uniqueNeedleIndex {
                    t.append("someone brought out the \(uniqueTranscriptNeedle) and played it badly")
                }
                r.audioTranscript = t.joined(separator: " ")
            }

            // ---- scene captions (incl. the fast-pair planted words) ----
            if fastPair {
                r.sceneCaptions = [SceneCaption(
                    timestamp: 0,
                    text: "pelicanwharf sunsetreel footage of the harbor at dusk")]
            } else if i % 9 == 2 {
                let nm = names[i % names.count]
                let pl = places[i % places.count]
                r.sceneCaptions = [SceneCaption(
                    timestamp: 0,
                    text: "A scene depicting \(nm) at \(pl), people smiling at the camera")]
            }

            // ---- OCR snippets (date burn-ins) ----
            if i % 18 == 4 {
                r.ocrText = [SceneCaption(timestamp: 0, text: "JUN \((i % 27) + 1) \(year)")]
                r.ocrDateCandidates = [SceneCaption(timestamp: 0, text: "\(year)-06-14")]
            }
            if i % 10 == 6 {
                r.inferredRecordDate = baseDate.addingTimeInterval(Double(year - 1990) * 366 * 86_400)
            }
            out.append(r)
        }
        return out
    }
}

// MARK: - Benchmark runner (the reusable measurement model)

/// One measured case's statistics, in milliseconds.
struct SearchBenchResult {
    let bench: String       // subsystem label, e.g. "catalog-search"
    let corpus: String      // corpus label, e.g. "100k"
    let label: String       // query / operation label
    let minMs: Double
    let medianMs: Double
    let p95Ms: Double
    let hits: Int

    /// One aligned human-readable line. Grep key: SEARCHBENCH.
    var summaryLine: String {
        String(format: "SEARCHBENCH | corpus=%-5@ | q=%-26@ | min=%8.2f med=%8.2f p95=%8.2f | hits=%d",
               corpus as NSString, label as NSString, minMs, medianMs, p95Ms, hits)
    }

    /// One machine-readable JSON line, shaped for the project's metrics
    /// JSONL pipeline.
    var jsonLine: String {
        let host = ProcessInfo.processInfo.hostName
        let ts = ISO8601DateFormatter().string(from: Date())
        // Hand-rolled to keep key order stable across runs (JSONEncoder
        // dictionary ordering isn't) — nicer diffs in the metrics branch.
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        return "{\"bench\":\"\(esc(bench))\",\"corpus\":\"\(esc(corpus))\","
            + "\"query\":\"\(esc(label))\","
            + String(format: "\"min_ms\":%.3f,\"median_ms\":%.3f,\"p95_ms\":%.3f,", minMs, medianMs, p95Ms)
            + "\"hits\":\(hits),\"host\":\"\(esc(host))\",\"timestamp\":\"\(ts)\"}"
    }
}

/// Minimal warmup+iterations benchmark harness. Designed as the reusable
/// pattern for benchmarking other subsystems: construct with a bench +
/// corpus label, call `run` per case with a closure that does the work and
/// returns a result count, then `emit` each result.
///
/// C++ analogy: like a stripped-down google/benchmark `BENCHMARK` body —
/// warmup runs prime caches/memos (CatalogSearchIndex memoizes fast-path
/// eligibility per needle, so the first pass of a query is structurally
/// slower), measured runs feed the order statistics.
struct SearchBenchRunner {
    let bench: String
    let corpus: String
    var warmupIterations: Int = 3
    var measuredIterations: Int = 10   // >= 10 per harness spec

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
    }

    /// Time `body` (warmup + measured) and return the stats. `body` returns
    /// the case's hit/result count so the benchmark can prove it measured a
    /// correct answer (a benchmark of a wrong answer is worthless).
    func run(_ label: String, iterations: Int? = nil, _ body: () -> Int) -> SearchBenchResult {
        let clock = ContinuousClock()
        let iters = max(1, iterations ?? measuredIterations)
        var hits = 0
        for _ in 0..<warmupIterations { hits = body() }
        var times: [Double] = []
        times.reserveCapacity(iters)
        for _ in 0..<iters {
            let d = clock.measure { hits = body() }
            times.append(Self.ms(d))
        }
        let sorted = times.sorted()
        let p95Index = min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)
        return SearchBenchResult(
            bench: bench, corpus: corpus, label: label,
            minMs: sorted.first ?? 0,
            medianMs: sorted[sorted.count / 2],
            p95Ms: sorted[max(0, p95Index)],
            hits: hits)
    }

    /// Print the aligned summary line and append the JSON line to
    /// $VS_BENCH_OUT (if set). Appending (not truncating) so one metrics
    /// file can accumulate every corpus/case of a run.
    func emit(_ result: SearchBenchResult) {
        print(result.summaryLine)
        guard let path = ProcessInfo.processInfo.environment["VS_BENCH_OUT"],
              !path.isEmpty else { return }
        let line = result.jsonLine + "\n"
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
