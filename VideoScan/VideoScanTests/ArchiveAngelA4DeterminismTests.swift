// ArchiveAngelA4DeterminismTests.swift
// codex #1643 A4 follow-up (Manager ruling, 2026-09-23). The evidence pick's
// scan cut-off read the CHOSEN member's score: when the 25th pick was a copy
// group whose live Keep scored below its cached row, the band dropped to the
// Keep's score and the pick walked the whole 100k file (~1 run in 5 on the
// SENSOR A4 fixture, 12× slower, and different picks — which run depended on
// the random record ids). Now rows arrive by ARRIVAL score (a copy group at
// its best eligible member), and the cut is the count-th best pick actually
// collected. Pinned here: identical picks for every id draw, fast every
// time, and a Keep that outscores its late-arriving anchor is never missed.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private struct A4RNG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uuid() -> UUID {
        let a = next(), b = next()
        return withUnsafeBytes(of: (a, b)) { raw in
            UUID(uuid: raw.load(as: uuid_t.self))
        }
    }
}

@Suite("codex #1643 A4 ruling — the evidence pick is deterministic and stops on arrival scores", .serialized)
@MainActor
struct ArchiveAngelA4DeterminismTests {

    /// The SENSOR A4 fixture (100k records, 30k in 3-copy groups, the third
    /// copy of each group the person's Keep), with ids drawn from `seed`.
    private static func a4Fixture(seed: UInt64, now: Date)
    -> (ArchiveAngelEvidenceStore, [UUID: ArchiveAngelCandidate], URL) {
        var rng = A4RNG(state: seed)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("angel-a4det-\(seed)-\(UUID().uuidString.prefix(6))")
        let store = ArchiveAngelEvidenceStore(directory: dir)
        var records: [UUID: ArchiveAngelEvidenceRecord] = [:]
        var live: [UUID: ArchiveAngelCandidate] = [:]
        records.reserveCapacity(100_000)
        live.reserveCapacity(100_000)
        let d = Date(timeIntervalSince1970: 773_000_000)
        var group = rng.uuid()
        for i in 0..<100_000 {
            let id = rng.uuid()
            if i % 3 == 0 { group = rng.uuid() }
            let grouped = i < 30_000
            var r = ArchiveAngelEvidenceRecord(score: 100 + (i % 97), lines: [], rejection: nil, useCount: 0, lastUsed: nil, computedAt: now)
            r.recommendation = grouped && i % 3 != 0 ? .anotherCopy : .ready
            r.copyKey = grouped ? "group:" + group.uuidString : nil
            records[id] = r
            live[id] = ArchiveAngelCandidate(id: id, filename: "v\(i).mov", fullPath: "/Volumes/T/v\(i).mov", durationSeconds: 1800,
                                             starRating: 3, duplicateGroupID: grouped ? group : nil, captureDate: d,
                                             duplicateGroupCount: grouped ? 3 : 0,
                                             duplicateDisposition: grouped && i % 3 == 2 ? .keep : .none)
        }
        store.replace(with: ArchiveAngelEvidenceFile(computedAt: now, complete: true, considered: 100_000, eligible: 100_000, records: records))
        return (store, live, dir)
    }

    @Test("SENSOR: the A4 fixture under 16 id draws — identical picks, identical work, every run under 0.3 s")
    func sameAnswerEveryDraw() {
        let now = Date()
        var reference: [String]?
        var referenceProjections: Int?
        var slowest = Duration.zero
        let ceiling = PerformanceLane.loadAwareDebugCeiling(.milliseconds(300))
        for seed in UInt64(1)...16 {
            let (store, live, dir) = Self.a4Fixture(seed: seed * 7_919, now: now)
            defer { try? FileManager.default.removeItem(at: dir) }
            let started = ContinuousClock.now
            let pick = ArchiveAngelJob.selectFromEvidence(store: store, count: 25, now: now, policy: .coverageOff) { live[$0] }
            let elapsed = ContinuousClock.now - started
            slowest = max(slowest, elapsed)
            let names = (pick?.selection.picks ?? []).map(\.candidate.filename)
            #expect(names.count == 25, "seed \(seed)")
            for p in pick?.selection.picks ?? [] where p.candidate.duplicateGroupID != nil {
                #expect(p.candidate.duplicateDisposition == .keep, "a grouped pick is the group's Keep (seed \(seed))")
            }
            if let reference { #expect(names == reference, "seed \(seed) picked differently") } else { reference = names }
            if let referenceProjections {
                #expect(pick?.projections == referenceProjections, "seed \(seed) did different work")
            } else { referenceProjections = pick?.projections }
            #expect(elapsed < ceiling, "seed \(seed): \(elapsed) (\(PerformanceLane.loadDescription()))")
        }
        print("[angel-perf] a4Determinism16 \(PerformanceLane.configurationName) slowest \(slowest) projections \(referenceProjections ?? -1)")
    }

    /// Rules v13 (2026-09-26, codex acceptance gate "coverage disabled"):
    /// the fixture above is 100k files shot on ONE day. With coverage ON
    /// the cache cannot fill 25 slots without topping up from rows it
    /// skipped, so it declines — deterministically — and the walk fills
    /// the batch by the soft day rule, identically for every draw.
    @Test("SENSOR (coverage ON): the one-day A4 fixture declines the cache under 8 id draws, and the walk fills 25 the same way every time")
    func oneDayFixtureWithCoverageOn() {
        let now = Date()
        var reference: [String]?
        for seed in UInt64(1)...8 {
            let (store, live, dir) = Self.a4Fixture(seed: seed * 7_919, now: now)
            defer { try? FileManager.default.removeItem(at: dir) }
            let pick = ArchiveAngelJob.selectFromEvidence(store: store, count: 25, now: now, policy: .builtIn) { live[$0] }
            #expect(pick == nil, "seed \(seed): declined — the walk decides")
            var cands = Array(live.values.sorted { $0.filename < $1.filename }.prefix(2_000))
            ArchiveAngelEvent.applyCoverage(&cands, policy: .builtIn, now: now)
            let walked = ArchiveAngelScorer.select(cands, count: 25, policy: .builtIn, now: now)
            let names = walked.picks.map(\.candidate.filename)
            #expect(names.count == 25, "seed \(seed): the day rule relaxes to fill the batch")
            #expect(walked.rejected[.sameEventAsPick] != nil)
            if let reference { #expect(names == reference, "seed \(seed)") } else { reference = names }
        }
    }

    @Test("a Keep that outscores its late-arriving anchor is picked — for every id draw")
    func keepBehindLateAnchor() {
        let now = Date()
        let d = Date(timeIntervalSince1970: 773_000_000)
        for seed in UInt64(1)...40 {
            var rng = A4RNG(state: seed)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("angel-a4keep-\(seed)-\(UUID().uuidString.prefix(6))")
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = ArchiveAngelEvidenceStore(directory: dir)
            var records: [UUID: ArchiveAngelEvidenceRecord] = [:]
            var live: [UUID: ArchiveAngelCandidate] = [:]
            func add(_ name: String, score: Int, kind: ArchiveAngelRecommendationClass, group: UUID? = nil, keep: Bool = false) -> UUID {
                let id = rng.uuid()
                var r = ArchiveAngelEvidenceRecord(score: score, lines: [], rejection: nil, useCount: 0, lastUsed: nil, computedAt: now)
                r.recommendation = kind
                r.copyKey = group.map { "group:" + $0.uuidString }
                records[id] = r
                live[id] = ArchiveAngelCandidate(id: id, filename: name, fullPath: "/Volumes/T/\(name)", durationSeconds: 1800,
                                                 starRating: 3, duplicateGroupID: group, captureDate: d,
                                                 duplicateGroupCount: group == nil ? 0 : 3,
                                                 duplicateDisposition: keep ? .keep : .none)
                return id
            }
            for i in 0..<30 { _ = add("plain\(i).mov", score: 120, kind: .ready) }
            let g = rng.uuid()
            _ = add("anchor.mov", score: 100, kind: .ready, group: g)            // the sweep's pick, cached low
            let keep = add("keep.mov", score: 150, kind: .anotherCopy, group: g, keep: true)   // marked Keep after the sweep
            _ = add("third.mov", score: 90, kind: .anotherCopy, group: g)
            store.replace(with: ArchiveAngelEvidenceFile(computedAt: now, complete: true, considered: records.count,
                                                         eligible: records.count, records: records))
            let pick = ArchiveAngelJob.selectFromEvidence(store: store, count: 25, now: now, policy: .coverageOff) { live[$0] }
            let ids = pick?.selection.picks.map(\.id) ?? []
            #expect(ids.contains(keep), "seed \(seed): the 150-point Keep was missed (its anchor arrived at 100)")
            #expect(!(pick?.selection.picks.contains { $0.candidate.filename == "anchor.mov" } ?? true), "seed \(seed)")
        }
    }

    /// QA follow-up 2026-09-24. A row's arrival key (tier, score) must be
    /// an UPPER bound on what it can add — the band cut relies on it. A
    /// copy group arrives at its best CACHED tier; here that is the 0-star
    /// anchor's Worth a look (tier 1), because the Keep is cached as
    /// Another copy (not a Prepare class). Live, the vouched, dated Keep
    /// classifies Ready (tier 0) — above the band the 30 Ready plains set —
    /// so a band check made on the arrival key alone cut the best file in
    /// the catalog. Either the Keep is picked, or the evidence pick
    /// declines (nil) and the job walks.
    @Test("a Keep whose LIVE class outranks its group's cached tier is not cut by the tier band")
    func keepWhoseLiveClassOutranksCachedTier() {
        let now = Date()
        let d = Date(timeIntervalSince1970: 773_000_000)
        for seed in UInt64(1)...20 {
            var rng = A4RNG(state: seed &* 104_729)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("angel-a4tier-\(seed)-\(UUID().uuidString.prefix(6))")
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = ArchiveAngelEvidenceStore(directory: dir)
            var records: [UUID: ArchiveAngelEvidenceRecord] = [:]
            var live: [UUID: ArchiveAngelCandidate] = [:]
            func add(_ name: String, score: Int, kind: ArchiveAngelRecommendationClass, stars: Int,
                     group: UUID? = nil, keep: Bool = false) -> UUID {
                let id = rng.uuid()
                var r = ArchiveAngelEvidenceRecord(score: score, lines: [], rejection: nil, useCount: 0, lastUsed: nil, computedAt: now)
                r.recommendation = kind
                r.copyKey = group.map { "group:" + $0.uuidString }
                records[id] = r
                live[id] = ArchiveAngelCandidate(id: id, filename: name, fullPath: "/Volumes/T/\(name)", durationSeconds: 1800,
                                                 starRating: stars, duplicateGroupID: group, captureDate: d,
                                                 duplicateGroupCount: group == nil ? 0 : 2,
                                                 duplicateDisposition: keep ? .keep : .none)
                return id
            }
            for i in 0..<30 { _ = add("plain\(i).mov", score: 120, kind: .ready, stars: 3) }
            let g = rng.uuid()
            _ = add("anchor.mov", score: 100, kind: .worthALook, stars: 0, group: g)
            let keep = add("keep.mov", score: 150, kind: .anotherCopy, stars: 3, group: g, keep: true)
            store.replace(with: ArchiveAngelEvidenceFile(computedAt: now, complete: true, considered: records.count,
                                                         eligible: records.count, records: records))
            let pick = ArchiveAngelJob.selectFromEvidence(store: store, count: 25, now: now, policy: .coverageOff) { live[$0] }
            guard let pick else { continue }       // declined → the catalog walk decides; acceptable
            #expect(pick.selection.picks.map(\.id).contains(keep),
                    "seed \(seed): the live-Ready 150-point Keep was cut by the band its Worth-a-look anchor arrived in")
        }
    }

    /// The guard on its own: a live choice that outranks the row's arrival
    /// key (better tier, or a higher score) breaks the band's upper-bound
    /// invariant; anything at or below it keeps it.
    @Test("the arrival-bound guard: live tier above arrival, or live score above arrival, breaks the bound")
    func arrivalBoundGuard() {
        #expect(ArchiveAngelJob.liveChoiceExceedsArrival(liveTier: 0, liveScore: 100, arrivalTier: 1, arrivalScore: 150))
        #expect(ArchiveAngelJob.liveChoiceExceedsArrival(liveTier: 1, liveScore: 151, arrivalTier: 1, arrivalScore: 150))
        #expect(!ArchiveAngelJob.liveChoiceExceedsArrival(liveTier: 1, liveScore: 150, arrivalTier: 1, arrivalScore: 150))
        #expect(!ArchiveAngelJob.liveChoiceExceedsArrival(liveTier: 2, liveScore: 999, arrivalTier: 1, arrivalScore: 150))
        #expect(!ArchiveAngelJob.liveChoiceExceedsArrival(liveTier: 1, liveScore: 90, arrivalTier: 1, arrivalScore: 150))
    }
}
