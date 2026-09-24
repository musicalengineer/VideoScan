// ArchiveAngelScorer+Sets.swift
// The scorer's whole-set passes: sorting a candidate set in `rank` order
// fast (2026-09-23 perf pass) and T10 H3 `markDerivatives` with its
// key-tail filter. Moved out of ArchiveAngelScorer.swift (2026-09-23) so
// each file stays readable.

import Foundation
import VideoScanCore

extension ArchiveAngelScorer {

    /// T10 H3. One pass over a candidate set: an export (a stem carrying a
    /// derivative token, `ArchiveAngelNaming.derivativeBaseStem`) is marked
    /// with its original's filename when a RELATED, USABLE original is in
    /// the set. Related = same folder; else same duplicate group; else same
    /// grandparent folder AND the same known year (inferred or user date).
    /// Usable = passes the hard floor (online, playable, a video, not junk,
    /// not too short, not a cache) and runs at least 0.9 × the export (an
    /// original is not shorter than its export). Otherwise the export is
    /// left alone — it is the best copy the family has. codex #1306: the
    /// earlier any-folder fallback let "Clip 01" in another tree displace
    /// an unrelated export.
    ///
    /// O(n): originals are indexed under exact keys (folder|stem,
    /// group|stem, grandparent|year|stem), at most `maxOriginalsPerKey`
    /// per key, so 5,000 same-named "Clip 01" originals cost 8 compares per
    /// export, never n².
    static var maxOriginalsPerKey: Int { AngelPolicyTables.standard.maxOriginalsPerKey }

    static func markDerivatives(_ candidates: inout [ArchiveAngelCandidate],
                                weights w: ArchiveAngelWeights = .standard) {
        markDerivatives(&candidates, policy: AngelRecommendationPolicy.builtIn.with(weights: w))
    }

    static func markDerivatives(_ candidates: inout [ArchiveAngelCandidate], policy p: AngelRecommendationPolicy) {
        let maxOriginalsPerKey = p.tables.maxOriginalsPerKey
        var byFolder: [String: [Int]] = [:]        // "folder|stem" → indices
        var byGroup: [String: [Int]] = [:]         // "group|stem"  → indices
        var byGrandparent: [String: [Int]] = [:]   // "grandparent|year|stem" → indices
        func add(_ table: inout [String: [Int]], _ key: String, _ i: Int) {
            var list = table[key, default: []]
            guard list.count < maxOriginalsPerKey else { return }
            list.append(i)
            table[key] = list
        }
        // The base stem once per candidate (one regex pass, not two).
        let bases: [String?] = candidates.map {
            ArchiveAngelNaming.derivativeBaseStem(($0.filename as NSString).deletingPathExtension)?.lowercased()
        }
        // Only an original some export can look up needs the hard floor.
        let lookupTails = derivativeLookupTails(candidates, bases: bases)
        guard !lookupTails.isEmpty else { return }                           // no export → nothing to mark
        for (i, c) in candidates.enumerated() {
            guard bases[i] == nil,                                           // an export is never an original
                  c.derivativeOfOriginal == nil else { continue }
            let stem = (c.filename as NSString).deletingPathExtension.lowercased()
            guard lookupTails.contains(stem) else { continue }              // no export can look it up
            var probe = c
            probe.attention = .none                                          // a resting original is still the original
            guard hardFloor(probe, policy: p) == nil else { continue }      // usable NOW
            let folder = (c.fullPath as NSString).deletingLastPathComponent
            add(&byFolder, folder + "|" + stem, i)
            if let g = c.duplicateGroupID { add(&byGroup, g.uuidString + "|" + stem, i) }
            if let year = c.knownYear {
                let grandparent = (folder as NSString).deletingLastPathComponent
                add(&byGrandparent, grandparent + "|\(year)|" + stem, i)
            }
        }
        for i in candidates.indices {
            guard let base = bases[i] else { continue }
            let export = candidates[i]
            let folder = (export.fullPath as NSString).deletingLastPathComponent
            var related: [Int] = byFolder[folder + "|" + base] ?? []
            if related.isEmpty, let g = export.duplicateGroupID { related = byGroup[g.uuidString + "|" + base] ?? [] }
            if related.isEmpty, let year = export.knownYear {
                let grandparent = (folder as NSString).deletingLastPathComponent
                related = byGrandparent[grandparent + "|\(year)|" + base] ?? []
            }
            guard let original = related.first(where: { j in
                j != i && candidates[j].durationSeconds >= 0.9 * export.durationSeconds
            }) else { continue }
            candidates[i].derivativeOfOriginal = candidates[original].filename
        }
    }

    /// `rank`'s inputs resolved ONCE per pick, for sorting a whole set
    /// (2026-09-23 perf: sorting 100k picks by `rank` moved the fat pick
    /// structs and lower-cased both codec names on every comparison —
    /// ~22% of a 100k family pass + select in Debug). `precedes` is `rank`
    /// field for field, with a leading class tier (0 when unused);
    /// `RankKeyParityTests` pins the two orders identical.
    struct RankKey {
        var tier: Int
        var score: Int
        var originality: Int
        var date: Date
        var duration: Double
        var size: Int64
        var filename: String

        init(_ c: ArchiveAngelCandidate, score: Int, tier: Int = 0, tables: AngelPolicyTables = .standard) {
            self.tier = tier
            self.score = score
            originality = ArchiveAngelScorer.originalityRank(c.videoCodec, tables: tables)
            date = c.inferredRecordDate ?? .distantFuture
            duration = c.durationSeconds
            size = c.sizeBytes
            filename = c.filename
        }

        static func precedes(_ a: RankKey, _ b: RankKey) -> Bool {
            if a.tier != b.tier { return a.tier < b.tier }
            if a.score != b.score { return a.score > b.score }
            if a.originality != b.originality { return a.originality < b.originality }
            if a.date != b.date { return a.date < b.date }
            if a.duration != b.duration { return a.duration > b.duration }
            if a.size != b.size { return a.size > b.size }
            return a.filename < b.filename
        }
    }

    /// `picks` in (tier, `rank`) order — the same permutation
    /// `picks.sort { tier, then rank }` produces (the sort sees identical
    /// comparison answers position for position), computed over small keys
    /// and an index array instead of the picks themselves.
    static func sortedByRank(_ picks: [ArchiveAngelPick], tables: AngelPolicyTables = .standard,
                             tier: (ArchiveAngelPick) -> Int = { _ in 0 }) -> [ArchiveAngelPick] {
        let keys = picks.map { RankKey($0.candidate, score: $0.score, tier: tier($0), tables: tables) }
        var order = Array(keys.indices)
        keys.withUnsafeBufferPointer { k in
            order.sort { RankKey.precedes(k[$0], k[$1]) }
        }
        return order.map { picks[$0] }
    }

    /// Every string that follows a "|" in a key some export will look up
    /// in `markDerivatives` (folder|base, group|base, grandparent|year|base).
    /// An original's keys all end in "|" + its stem, so it can only ever be
    /// found when its stem is in this set (exact even when a folder or a
    /// name contains "|"); `markDerivatives` runs the hard floor only for
    /// those. Originals it skips are in no table a lookup reads, so the
    /// per-key cap order is unchanged. (2026-09-23 perf: the floor on every
    /// non-export was 70% of the pass at 100k.)
    static func derivativeLookupTails(_ candidates: [ArchiveAngelCandidate], bases: [String?]) -> Set<String> {
        var lookupTails = Set<String>()
        for i in candidates.indices {
            guard let base = bases[i] else { continue }
            let export = candidates[i]
            let folder = (export.fullPath as NSString).deletingLastPathComponent
            var keys = [folder + "|" + base]
            if let g = export.duplicateGroupID { keys.append(g.uuidString + "|" + base) }
            if let year = export.knownYear {
                keys.append((folder as NSString).deletingLastPathComponent + "|\(year)|" + base)
            }
            for key in keys {
                var rest = Substring(key)
                while let bar = rest.firstIndex(of: "|") {
                    rest = rest[rest.index(after: bar)...]
                    lookupTails.insert(String(rest))
                }
            }
        }
        return lookupTails
    }
}
