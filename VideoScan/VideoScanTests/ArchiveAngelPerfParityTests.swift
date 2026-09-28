// ArchiveAngelPerfParityTests.swift
// 2026-09-23 perf pass on the 100k Angel scale tests: two hot paths were
// restructured for speed. Each change must give the SAME answer as the code
// it replaced, so each is pinned here against a reference copy of the old
// algorithm on seeded random fixtures dense in ties and edge cases.
//   - RankKey / sortedByRank vs `sort(by: rank)` (select's full sort)
//   - markDerivatives' lookup-tail filter vs the unfiltered pass (incl.
//     folder and file names containing "|", the key separator)

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private struct ParityRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Archive Angel perf parity — the fast paths answer exactly as the code they replaced")
struct ArchiveAngelPerfParityTests {

    // MARK: rank

    private static func tiedPicks(_ n: Int, seed: UInt64) -> [ArchiveAngelPick] {
        var rng = ParityRNG(state: seed)
        let codecs = ["dvvideo", "DV", "h264", "HEVC", "prores", "", "wmv3", "mpeg2video"]
        let dates: [Date?] = [nil, Date(timeIntervalSince1970: 700_000_000), Date(timeIntervalSince1970: 800_000_000)]
        return (0..<n).map { _ in
            let c = ArchiveAngelCandidate(filename: "f\(Int.random(in: 0..<6, using: &rng)).mov",
                                          sizeBytes: Int64(Int.random(in: 0..<3, using: &rng)),
                                          durationSeconds: [60, 120, .nan][Int.random(in: 0..<3, using: &rng)],
                                          inferredRecordDate: dates[Int.random(in: 0..<3, using: &rng)],
                                          videoCodec: codecs[Int.random(in: 0..<codecs.count, using: &rng)])
            return ArchiveAngelPick(candidate: c, score: Int.random(in: 0..<4, using: &rng), evidence: [])
        }
    }

    @Test("sortedByRank is the permutation sort(by: rank) gives — ties, NaN durations, nil dates, codec case")
    func rankKeyParity() {
        for seed in UInt64(1)...40 {
            let picks = Self.tiedPicks(400, seed: seed)
            var reference = picks
            reference.sort { ArchiveAngelScorer.rank($0, $1, tables: .standard) }
            let fast = ArchiveAngelScorer.sortedByRank(picks, tables: .standard)
            #expect(fast.map(\.id) == reference.map(\.id), "seed \(seed)")
        }
    }

    @Test("with a class tier: sortedByRank matches the tier-then-rank sort select used")
    func rankKeyParityWithTier() {
        for seed in UInt64(100)...130 {
            let picks = Self.tiedPicks(300, seed: seed)
            var rng = ParityRNG(state: seed)
            var tier: [UUID: Int] = [:]
            for p in picks { tier[p.id] = Int.random(in: 0..<3, using: &rng) }
            var reference = picks
            reference.sort { a, b in
                let ta = tier[a.id] ?? .max, tb = tier[b.id] ?? .max
                return ta != tb ? ta < tb : ArchiveAngelScorer.rank(a, b, tables: .standard)
            }
            let fast = ArchiveAngelScorer.sortedByRank(picks, tables: .standard, tier: { tier[$0.id] ?? .max })
            #expect(fast.map(\.id) == reference.map(\.id), "seed \(seed)")
        }
    }

    // MARK: markDerivatives

    /// The pass as it was before the lookup-tail filter (verbatim logic):
    /// every usable non-export is indexed, then each export looks up.
    private static func referenceMarkDerivatives(_ candidates: inout [ArchiveAngelCandidate],
                                                 policy p: AngelRecommendationPolicy) {
        let maxOriginalsPerKey = p.tables.maxOriginalsPerKey
        var byFolder: [String: [Int]] = [:], byGroup: [String: [Int]] = [:], byGrandparent: [String: [Int]] = [:]
        func add(_ table: inout [String: [Int]], _ key: String, _ i: Int) {
            var list = table[key, default: []]
            guard list.count < maxOriginalsPerKey else { return }
            list.append(i)
            table[key] = list
        }
        let bases: [String?] = candidates.map {
            ArchiveAngelNaming.derivativeBaseStem(($0.filename as NSString).deletingPathExtension)?.lowercased()
        }
        for (i, c) in candidates.enumerated() {
            var probe = c
            probe.attention = .none
            guard bases[i] == nil, c.derivativeOfOriginal == nil,
                  ArchiveAngelScorer.hardFloor(probe, policy: p) == nil else { continue }
            let stem = (c.filename as NSString).deletingPathExtension.lowercased()
            let folder = (c.fullPath as NSString).deletingLastPathComponent
            add(&byFolder, folder + "|" + stem, i)
            if let g = c.duplicateGroupID { add(&byGroup, g.uuidString + "|" + stem, i) }
            if let year = c.knownYear {
                add(&byGrandparent, (folder as NSString).deletingLastPathComponent + "|\(year)|" + stem, i)
            }
        }
        for i in candidates.indices {
            guard let base = bases[i] else { continue }
            let export = candidates[i]
            let folder = (export.fullPath as NSString).deletingLastPathComponent
            var related: [Int] = byFolder[folder + "|" + base] ?? []
            if related.isEmpty, let g = export.duplicateGroupID { related = byGroup[g.uuidString + "|" + base] ?? [] }
            if related.isEmpty, let year = export.knownYear {
                related = byGrandparent[(folder as NSString).deletingLastPathComponent + "|\(year)|" + base] ?? []
            }
            guard let original = related.first(where: { j in
                j != i && candidates[j].durationSeconds >= 0.9 * export.durationSeconds
            }) else { continue }
            candidates[i].derivativeOfOriginal = candidates[original].filename
        }
    }

    private static func derivativeFixture(seed: UInt64) -> [ArchiveAngelCandidate] {
        var rng = ParityRNG(state: seed)
        // "|" in folders and stems on purpose: the key separator itself.
        let folders = ["/v/a", "/v/b", "/v/a|b", "/v", "/w/a", "/w/x|y/z"]
        let stems = ["tape", "Tape", "clip 01", "b|tape", "tape|x", "x", "2001|tape", "y/z|tape"]
        let tokens = ["", "", "", "_balanced", ".vs.edit", "_trimmed", " copy 2", "_NV12"]
        let groups = [UUID(), UUID(), UUID()]
        let base = Date(timeIntervalSince1970: 978_307_200)   // 2001
        return (0..<600).map { _ in
            let folder = folders[Int.random(in: 0..<folders.count, using: &rng)]
            let name = stems[Int.random(in: 0..<stems.count, using: &rng)] + tokens[Int.random(in: 0..<tokens.count, using: &rng)] + ".mov"
            let roll = Int.random(in: 0..<10, using: &rng)
            return ArchiveAngelCandidate(filename: name, fullPath: folder + "/" + name,
                                         sizeBytes: 9_000_000_000,
                                         durationSeconds: [30, 600, 1800, 3600][Int.random(in: 0..<4, using: &rng)],
                                         mediaDisposition: roll == 0 ? .confirmedJunk : .unreviewed,
                                         inferredRecordDate: roll < 5 ? base.addingTimeInterval(Double(roll) * 3_000_000) : nil,
                                         inferredDateConfidence: 0.9,
                                         duplicateGroupID: roll % 3 == 0 ? groups[roll % groups.count] : nil)
        }
    }

    @Test("markDerivatives marks exactly what the unfiltered pass marked — incl. '|' in folders and names, groups, years, floors, caps")
    func markDerivativesParity() {
        var smallCap = AngelRecommendationPolicy.builtIn
        smallCap.tables.maxOriginalsPerKey = 2
        for policy in [AngelRecommendationPolicy.builtIn, smallCap] {
            for seed in UInt64(1)...40 {
                let fixture = Self.derivativeFixture(seed: seed)
                var reference = fixture, fast = fixture
                Self.referenceMarkDerivatives(&reference, policy: policy)
                ArchiveAngelScorer.markDerivatives(&fast, policy: policy)
                #expect(fast.map(\.derivativeOfOriginal) == reference.map(\.derivativeOfOriginal), "seed \(seed)")
                #expect(reference.contains { $0.derivativeOfOriginal != nil }, "fixture exercises marking (seed \(seed))")
            }
        }
    }
}
