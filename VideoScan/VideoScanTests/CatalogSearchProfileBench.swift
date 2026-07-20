// CatalogSearchProfileBench.swift
// GH #123 — catalog search too slow / beachballs at ~103k records.
//
// MEASUREMENT HARNESS, not (yet) a regression sensor. This benchmark is
// the shared yardstick for the #123 fix: the diagnosis run
// (docs/perf/search_profile_2026-07-20.md) and the fix's before/after
// numbers must both come from THIS file, unchanged, in Release
// (-configuration Release; per project build-mode policy a Debug run is
// not a perf measurement).
//
// It reproduces, at unit level, exactly what the main thread runs on the
// trailing edge of the 250 ms search debounce:
//
//   1. tableFilter(): the CatalogContent.computeFiltered() search path —
//      pfApplyPurgeFilter → pfApplySetAsideFilter → searchIndex.filter.
//   2. badgeCount(): CatalogToolbar.recomputeSearchHitCount() —
//      pfSearchBadgeBase (two more full passes) → searchIndex.count.
//
// Both run back-to-back on the main actor in production (two independent
// debouncers with the same 250 ms delay), so the per-settled-keystroke
// main-thread cost is tableMs + badgeMs (+ SwiftUI Table diffing, which a
// unit bench can't see — see the profile doc).
//
// Corpus shape is matched to Rick's REAL catalog, measured read-only on
// 2026-07-19 (103,835 records):
//   streamType:  78.1% audio-only / 12.2% V+A / 5.4% V-only / 4.2% probe-failed
//   fullPath length: mean 137, p50 136, p90 171, max 363
//   audioTranscript: 7.9% of records; len mean 931, median 24, max 84,068
//   sceneCaptions 11.0% · ocrText 5.6% · people tags 0.63%
//   inferredRecordDate 9.7% · purged 0.3% · set-aside 0
//   ~72% of paths are iTunes/Music trees (the #124 pollution)
//   top exts: aif 25%, caf 22%, wav 21%, mov 7.5%, mxf 5.1%, m4a 2.6%, mp3 2.1%
//
// Deterministic (seeded SplitMix64) — reproducible across machines/runs.

import Testing
import Foundation
@testable import VideoScan

@MainActor
@Suite("CatalogSearchProfileBench", .serialized)
struct CatalogSearchProfileBench {

    // MARK: - Deterministic PRNG

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

    // MARK: - Corpus generator (Rick-shaped, see header)

    static let artists = [
        "The Blue Harbors", "Copley Square Quartet", "Middlefield Ramblers",
        "Berkshire Winds", "Harbor Lights Trio", "The Bay State Revue",
        "Cranberry Union", "Old Colony Brass", "Housatonic Drifters",
        "The Quabbin Set", "Mohawk Trail Band", "Pioneer Valley Players",
        "Nashua Street Five", "The Longmeadows", "Chester Granite Choir",
        "Westfield River Band",
    ]
    static let albums = [
        "Greatest Hits", "Live At The Orpheum 1993", "Autumn Sessions",
        "Homecoming", "Acoustic Evenings", "Studio Outtakes Vol 2",
        "The Early Years", "Winter Light", "One More Round", "Signal Fires",
    ]
    static let trackWords = [
        "Harbor", "Lantern", "Meadow", "Crossing", "Granite", "Firefly",
        "Northfield", "Ridgeline", "Sparrow", "Ember", "Milltown", "Beacon",
    ]
    static let places = [
        "Cape Cod", "Brockton", "Westford", "Cottage", "Beach", "Christmas",
        "Birthday", "Graduation", "Middlefield", "Fourth Of July",
    ]
    static let names = ["Donna", "Mark", "Dan", "Matt", "Tim", "Grampa", "Mom", "Dad"]
    static let years = [1988, 1990, 1991, 1992, 1993, 1995, 1997, 2001, 2007, 2010]
    static let transcriptFiller = [
        "okay", "yeah", "look", "over", "there", "hold", "camera", "steady",
        "birthday", "cake", "everybody", "wave", "music", "playing", "laughing",
        "singing", "happy", "kids", "backyard", "snow", "beach", "water",
    ]

    static func makeRickShapedCorpus(_ n: Int) -> [VideoRecord] {
        var rng = SplitMix64(seed: 0x5EA7C4)
        var out: [VideoRecord] = []
        out.reserveCapacity(n)
        let baseDate = Date(timeIntervalSince1970: 660_000_000) // ~1990-12
        for i in 0..<n {
            let r = VideoRecord()
            let roll = Double(rng.next() % 10_000) / 10_000.0
            let year = Self.years[i % Self.years.count]
            // dateCreatedRaw on every record: pfYearsFromRecord reads it on
            // every yearRange match, so it must be populated to be honest.
            r.dateCreatedRaw = baseDate.addingTimeInterval(Double(i % 12_000) * 86_400)
            r.dateCreated = "2024-01-01 12:00"

            if roll < 0.781 {
                // ---- audio-only (iTunes/Music tree; the #124 pollution) ----
                let artist = Self.artists[Int(rng.next() % UInt64(Self.artists.count))]
                let album = Self.albums[Int(rng.next() % UInt64(Self.albums.count))]
                let t1 = Self.trackWords[Int(rng.next() % UInt64(Self.trackWords.count))]
                let t2 = Self.trackWords[Int(rng.next() % UInt64(Self.trackWords.count))]
                let trackNo = (i % 14) + 1
                let ext = ["aif", "caf", "wav", "m4a", "mp3"][i % 5]
                r.filename = String(format: "%02d %@ %@ %d.%@", trackNo, t1, t2, i, ext)
                r.directory = "/Volumes/MyBook3Terabytes/MacPro2009 Backup/Users/rickb/Music/iTunes/iTunes Media/Music/\(artist)/\(album)"
                r.ext = ext
                r.streamTypeRaw = StreamType.audioOnly.rawValue
                r.audioCodec = ext == "mp3" ? "mp3" : (ext == "m4a" ? "aac" : "pcm_s16le")
            } else if roll < 0.903 {
                // ---- video+audio (family footage) ----
                let place = Self.places[Int(rng.next() % UInt64(Self.places.count))]
                let ext = (i % 5 == 0) ? "mts" : "mov"
                r.filename = "\(place.replacingOccurrences(of: " ", with: ""))\(year) clip \(i).\(ext)"
                r.directory = "/Volumes/LaCie8TB/Family Media/\(place) \(year)/iMovie Project \(place)\(year)"
                r.ext = ext
                r.streamTypeRaw = StreamType.videoAndAudio.rawValue
                r.videoCodec = ext == "mts" ? "h264" : "dvvideo"
                r.audioCodec = "pcm_s16le"
            } else if roll < 0.957 {
                // ---- video-only (Avid MXF halves — "V1993-06-14" style
                // names put words like "v1993" in the index, which is what
                // defeats the whole-word fast path for "1993" in real life) ----
                let mm = (i % 12) + 1
                let dd = (i % 27) + 1
                r.filename = String(format: "V%d-%02d-%02d.%d.A0%d.mxf", year, mm, dd, i, i % 4)
                r.directory = "/Volumes/Seagate2TB/Avid MediaFiles/MXF/\((i % 9) + 1)"
                r.ext = "mxf"
                r.streamTypeRaw = StreamType.videoOnly.rawValue
                r.videoCodec = "dnxhd"
            } else {
                // ---- ffprobe failed / junk ----
                r.filename = "Recovered \(i).sdir"
                r.directory = "/Volumes/MyBook3Terabytes/MacPro2009 Backup/Users/rickb/Documents/Old Projects/Recovered Items \(i % 40)"
                r.ext = "sdir"
                r.streamTypeRaw = StreamType.ffprobeFailed.rawValue
            }
            r.fullPath = r.directory + "/" + r.filename
            // volumeName is a derived property (scanContext first, then
            // path parsing) — populate the scan-time capture like ScanEngine.
            r.scanContext.volumeName = r.fullPath.hasPrefix("/Volumes/LaCie8TB") ? "LaCie8TB"
                : (r.fullPath.hasPrefix("/Volumes/Seagate2TB") ? "Seagate2TB" : "MyBook3Terabytes")
            r.sizeBytes = Int64(1_000_000 + (i % 1_000) * 10_000)

            // ---- dossier content, matched to measured prevalence ----
            let dossierRoll = Double(rng.next() % 10_000) / 10_000.0
            if dossierRoll < 0.079 {
                // Transcript length mix tuned to mean ≈ 931, median ≈ 24:
                // 50% ~tiny, 40% ~800 chars, 9% ~4 KB, 1% ~30 KB.
                let lenRoll = Double(rng.next() % 10_000) / 10_000.0
                let words: Int
                if lenRoll < 0.50 { words = 4 }
                else if lenRoll < 0.90 { words = 120 }
                else if lenRoll < 0.99 { words = 600 }
                else { words = 4_500 }
                var t: [String] = []
                t.reserveCapacity(words)
                for j in 0..<words {
                    t.append(Self.transcriptFiller[(i + j) % Self.transcriptFiller.count])
                    if j % 17 == 0 { t.append(Self.names[(i + j) % Self.names.count].lowercased()) }
                    if j % 41 == 0 { t.append("\(Self.years[(i + j) % Self.years.count])") }
                }
                r.audioTranscript = t.joined(separator: " ")
            }
            if dossierRoll < 0.110 {
                let nm = Self.names[i % Self.names.count]
                let pl = Self.places[i % Self.places.count]
                r.sceneCaptions = [SceneCaption(timestamp: 0, text: "A scene depicting \(nm) at \(pl), people smiling at the camera")]
            }
            if dossierRoll < 0.056 {
                r.ocrText = [SceneCaption(timestamp: 0, text: "JUN \(dossierRoll < 0.028 ? 14 : 25) \(year)")]
                r.ocrDateCandidates = [SceneCaption(timestamp: 0, text: "\(year)-06-14")]
            }
            if dossierRoll < 0.0063 {
                r.detectedPeople = [Self.names[i % Self.names.count]]
            }
            if dossierRoll < 0.097 {
                r.inferredRecordDate = baseDate.addingTimeInterval(Double(year - 1990) * 366 * 86_400)
            }
            if dossierRoll > 0.997 {
                r.purgedAt = Date()   // ~0.3% purged, like the real catalog
            }
            out.append(r)
        }
        return out
    }

    // MARK: - Production-path analogs (keep in lock-step with the app)

    /// CatalogContent.computeFiltered()'s search path, verbatim shape:
    /// purge filter → set-aside filter → searchIndex.filter. (No volume
    /// filter, no view chips, no filterByIDs — defaults, like Rick's
    /// spot test.)
    static func tableFilter(_ records: [VideoRecord], _ index: CatalogSearchIndex, _ query: String) -> [VideoRecord] {
        var out = pfApplyPurgeFilter(records, showRemoved: false)
        out = pfApplySetAsideFilter(out, showSetAside: false)
        if !query.isEmpty {
            out = index.filter(records: out, query: query)
        }
        return out
    }

    /// CatalogToolbar.recomputeSearchHitCount(), verbatim shape.
    static func badgeCount(_ records: [VideoRecord], _ index: CatalogSearchIndex, _ query: String) -> Int {
        index.count(
            records: pfSearchBadgeBase(records, showRemoved: false, showSetAside: false),
            query: query)
    }

    // MARK: - Timing helpers

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
    }

    struct QueryResult {
        let query: String
        let coldTableMs: Double
        let warmTableMs: Double   // median of warm runs
        let warmBadgeMs: Double   // median of warm runs
        let hits: Int
        /// What the main thread eats per settled keystroke (both
        /// debouncers land together): table + badge.
        var settledKeystrokeMs: Double { warmTableMs + warmBadgeMs }
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        return s[s.count / 2]
    }

    static func profileQuery(_ query: String, records: [VideoRecord],
                             index: CatalogSearchIndex, warmRuns: Int = 5) -> QueryResult {
        let clock = ContinuousClock()
        var hits = 0
        // Cold run — includes first-use isFastPathEligible scans (memoized
        // after) and any lazy caches. This is what the FIRST search after
        // launch (or after any index mutation, which drops the memo) costs.
        let cold = clock.measure {
            hits = tableFilter(records, index, query).count
        }
        var tableTimes: [Double] = []
        var badgeTimes: [Double] = []
        for _ in 0..<warmRuns {
            var out: [VideoRecord] = []
            let t = clock.measure { out = tableFilter(records, index, query) }
            hits = out.count
            tableTimes.append(ms(t))
            var n = 0
            let b = clock.measure { n = badgeCount(records, index, query) }
            precondition(n >= 0)
            badgeTimes.append(ms(b))
        }
        return QueryResult(query: query,
                           coldTableMs: ms(cold),
                           warmTableMs: median(tableTimes),
                           warmBadgeMs: median(badgeTimes),
                           hits: hits)
    }

    static func report(_ r: QueryResult, corpusLabel: String) {
        print(String(format: "[#123-bench] %@ q='%@' cold_table_ms=%.1f warm_table_ms=%.1f warm_badge_ms=%.1f settled_keystroke_ms=%.1f hits=%d",
                     corpusLabel, r.query, r.coldTableMs, r.warmTableMs, r.warmBadgeMs, r.settledKeystrokeMs, r.hits))
    }

    // MARK: - The profile

    @Test func profile100kSearchPipeline() throws {
        let n = 100_000
        let clock = ContinuousClock()

        var corpus: [VideoRecord] = []
        let genD = clock.measure { corpus = Self.makeRickShapedCorpus(n) }
        print(String(format: "[#123-bench] corpus=%d generated_in_ms=%.0f", corpus.count, Self.ms(genD)))
        // The index keys haystacks on fullPath — duplicate paths would
        // cross-contaminate index-vs-fallback comparisons.
        #expect(Set(corpus.map(\.fullPath)).count == corpus.count,
                "corpus fullPaths must be unique")

        let index = CatalogSearchIndex()
        let buildD = clock.measure { index.rebuild(records: corpus) }
        print(String(format: "[#123-bench] index_rebuild_ms=%.0f indexed_words=%d", Self.ms(buildD), index.indexedWordCount()))

        // The two cheap pre-filters alone (computeFiltered always runs
        // them, search or not) — two full-array passes + allocations.
        var prefiltered: [VideoRecord] = []
        let preD = clock.measure {
            prefiltered = pfApplySetAsideFilter(pfApplyPurgeFilter(corpus, showRemoved: false), showSetAside: false)
        }
        print(String(format: "[#123-bench] prefilter_passes_ms=%.1f rows=%d", Self.ms(preD), prefiltered.count))

        // Representative queries (issue + Rick's placeholder examples):
        //  "1993"            bare year — substring token, but "v1993"-style
        //                    words defeat the whole-word fast path
        //  "donna"           person name, rare hits
        //  "christmas"       filename/folder fragment
        //  "mov"             extension fragment (infix of "imovie" → linear)
        //  "elev"            partial word — guaranteed linear fallback
        //  "1990s"           decade shorthand — yearRange token, ALWAYS
        //                    linear + pfYearsFromRecord per record
        //  "donna 1990s"     the search field's own placeholder suggestion
        //  "mark dan grampa" 3-token AND (the jq demo)
        //  "\"cape cod\""    quoted phrase — always linear
        let queries = ["1993", "donna", "christmas", "mov", "elev",
                       "1990s", "donna 1990s", "mark dan grampa", "\"cape cod\""]
        var results: [QueryResult] = []
        for q in queries {
            let r = Self.profileQuery(q, records: corpus, index: index)
            Self.report(r, corpusLabel: "full_103k_shape")
            results.append(r)
        }

        // Hypothesis (e): what the #124 A/V-default working-set reduction
        // buys ON ITS OWN — same queries over only video-bearing records.
        let avOnly = corpus.filter {
            $0.streamType == .videoAndAudio || $0.streamType == .videoOnly
        }
        print("[#123-bench] av_only_rows=\(avOnly.count)")
        for q in ["1993", "donna", "1990s", "donna 1990s"] {
            let r = Self.profileQuery(q, records: avOnly, index: index)
            Self.report(r, corpusLabel: "av_only")
        }

        // POISONED-INDEX SCENARIO — the state Rick's machine was ACTUALLY
        // in for the #123 spot test. Any unit-test run that constructs
        // VideoScanModel executes searchIndex.rebuild(records: []) +
        // saveToDisk() with NO TestEnvironment guard and NO path redirect
        // (VideoScanModel.swift:770-785), overwriting the real
        // catalog.search-index.v1.plist with a 110-byte, 0-haystack file.
        // The app's next launch ACCEPTS it (loadFromDisk has no
        // recordCount-vs-catalog sanity check) whenever its savedAt ≥
        // catalog.json's mtime — verified on Rick's machine 2026-07-19:
        // persisted plist recordCount=0, catalog.log "Search index loaded
        // from disk in 0 ms (103832 records)" three times that day.
        // With an empty index, EVERY query takes matches()'s defensive
        // fallback: buildHaystack() runs INLINE per record per query —
        // multi-field concat + pathTokenize ×3 + lowercase + NFC.
        let poisonedIndex = CatalogSearchIndex()   // never rebuilt — 0 haystacks
        for q in ["1993", "donna", "donna 1990s"] {
            let r = Self.profileQuery(q, records: corpus, index: poisonedIndex, warmRuns: 3)
            Self.report(r, corpusLabel: "poisoned_empty_index")
            // Correctness cross-check: the healthy index (fast path or
            // cached-haystack linear) and the empty-index inline-build
            // fallback MUST agree — this doubles as an index/canonical
            // agreement sensor at 100k scale.
            if let healthy = results.first(where: { $0.query == q }) {
                #expect(healthy.hits == r.hits,
                        "index vs fallback disagree for '\(q)': \(healthy.hits) vs \(r.hits)")
            }
        }

        // Context: the column-header sort that onSort runs on the main
        // actor (model.records.sort(using:)) — a one-click beachball
        // candidate at 100k, measured here so the fix plan can cite it.
        var sortCopy = corpus
        let sortNameD = clock.measure {
            sortCopy.sort(using: [KeyPathComparator(\VideoRecord.filename)])
        }
        var sortCopy2 = corpus
        let sortDateD = clock.measure {
            sortCopy2.sort(using: [KeyPathComparator(\VideoRecord.resolvedDateSortKey)])
        }
        print(String(format: "[#123-bench] sort_by_filename_ms=%.0f sort_by_resolvedDate_ms=%.0f",
                     Self.ms(sortNameD), Self.ms(sortDateD)))

        // Sanity — the corpus must actually exercise the paths we claim.
        func hits(_ q: String) -> Int { results.first { $0.query == q }!.hits }
        #expect(hits("1993") > 100, "year query should hit video paths + transcripts")
        #expect(hits("donna") > 50, "name query should hit people tags + transcripts")
        #expect(hits("christmas") > 100, "folder-fragment query should hit")
        #expect(hits("1990s") > 100, "decade query should hit year signals")
        // Generous ceiling so a catastrophic regression still fails the
        // suite even before the #123 fix lands its real budgets.
        for r in results {
            #expect(r.settledKeystrokeMs < 10_000, "query '\(r.query)' took \(r.settledKeystrokeMs) ms — beyond even the known-bad baseline")
        }
    }
}
