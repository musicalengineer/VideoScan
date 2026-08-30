// HallieSpellingRecoveryEquivalenceTests.swift
// 2026-08-30. `HallieSpellingRecovery.bestMatches` is the last-resort arm of
// `ArchivistGraphExecutor.resolveUnselected`: when a typed name matches
// nobody, EVERY person in the tree becomes a spelling candidate. On the
// 16,383-person pedigree that turn measured 778 ms p50 (Debug), 25× the
// next slowest deterministic shape and the entire p95 of HallieQueryBench.
//
// This file exists so that path can be made fast WITHOUT anyone having to
// take "it still works" on faith. It carries a FROZEN byte-for-byte copy of
// the implementation as it stood before the optimisation, and asserts the
// live one agrees with it on:
//
//   * every name in a production-scale synthetic tree, typed exactly;
//   * seeded single-character mutations of those names (the actual use
//     case: a typo);
//   * adversarial short / long / accented / digit-bearing / empty inputs;
//   * the transposition cases the OSA metric exists for.
//
// Same pattern as GedcomIndexEquivalenceTests, and for the same reason:
// an optimisation whose only evidence is that the suite is still green has
// no evidence at all, because the suite never asked this question.

import Testing
import Foundation
@testable import VideoScan
import VideoScanCore

/// The implementation as of commit b3827176, copied verbatim. Do not
/// "fix" or tidy this — its whole value is being the thing that was
/// shipped and known good.
enum FrozenSpellingRecovery {

    static func bestMatches(
        typed: String,
        candidates: [(identity: String, spellings: [String])]
    ) -> [String] {
        let typedTokens = tokens(typed)
        guard !typedTokens.isEmpty, typedTokens.count <= 6 else { return [] }
        var scores: [String: Int] = [:]
        for candidate in candidates {
            for spelling in candidate.spellings {
                guard let score = nameScore(typedTokens, spelling) else { continue }
                scores[candidate.identity] = min(
                    scores[candidate.identity] ?? Int.max, score)
            }
        }
        guard let best = scores.values.min() else { return [] }
        return scores.compactMap { $0.value == best ? $0.key : nil }.sorted()
    }

    static func nameScore(_ typedTokens: [String], _ candidate: String) -> Int? {
        let candidateTokens = tokens(candidate)
        guard candidateTokens.count <= 8,
              typedTokens.count <= candidateTokens.count else { return nil }

        func assign(_ index: Int, used: Set<Int>, score: Int) -> Int? {
            if index == typedTokens.count { return score > 0 ? score : nil }
            var best: Int?
            for candidateIndex in candidateTokens.indices
            where !used.contains(candidateIndex) {
                guard let distance = tokenDistance(
                    typedTokens[index], candidateTokens[candidateIndex]) else {
                    continue
                }
                var nextUsed = used
                nextUsed.insert(candidateIndex)
                if let total = assign(
                    index + 1, used: nextUsed, score: score + distance),
                   total <= 2, total < (best ?? Int.max) {
                    best = total
                }
            }
            return best
        }
        return assign(0, used: [], score: 0)
    }

    static func tokens(_ value: String) -> [String] {
        PersonResolver.normalize(value)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    static func tokenDistance(_ lhs: String, _ rhs: String) -> Int? {
        if lhs == rhs { return 0 }
        guard lhs.count >= 4, rhs.count >= 4 else { return nil }
        let limit = max(lhs.count, rhs.count) >= 8 ? 2 : 1
        guard abs(lhs.count - rhs.count) <= limit else { return nil }
        let left = Array(lhs)
        let right = Array(rhs)
        var matrix = Array(
            repeating: Array(repeating: 0, count: right.count + 1),
            count: left.count + 1)
        for index in 0...left.count { matrix[index][0] = index }
        for index in 0...right.count { matrix[0][index] = index }
        for i in 1...left.count {
            for j in 1...right.count {
                let substitution = matrix[i - 1][j - 1]
                    + (left[i - 1] == right[j - 1] ? 0 : 1)
                matrix[i][j] = min(
                    matrix[i - 1][j] + 1,
                    matrix[i][j - 1] + 1,
                    substitution)
                if i > 1, j > 1,
                   left[i - 1] == right[j - 2],
                   left[i - 2] == right[j - 1] {
                    matrix[i][j] = min(
                        matrix[i][j], matrix[i - 2][j - 2] + 1)
                }
            }
        }
        let distance = matrix[left.count][right.count]
        return distance <= limit ? distance : nil
    }
}

@Suite("Hallie spelling recovery — frozen-reference equivalence + scale")
struct HallieSpellingRecoveryEquivalenceTests {

    static let performanceOptIn = "VIDEOSCAN_HALLIE_PERF"

    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
    }

    /// One shared production-scale tree: 16,383 people, the size of Rick's
    /// real export.
    static let graph = GedcomFamilyGraph(
        gedcomText: GedcomSyntheticPedigree.gedcom(people: 16_383))

    static var candidates: [(identity: String, spellings: [String])] {
        graph.people.values.map { (identity: $0.id, spellings: [$0.name]) }
    }

    // MARK: Token-level equivalence

    /// The inner metric, over pairs designed to hit every branch: equal,
    /// too short, length gap beyond the limit, one edit, two edits at the
    /// 8-character boundary, transpositions, accents, digits.
    @Test("tokenDistance agrees with the frozen implementation on adversarial pairs")
    func tokenDistanceMatchesFrozenOnEdgeCases() {
        let words = [
            "", "a", "ann", "anne", "joanne", "john", "jonh", "jhon",
            "breen", "bren", "breene", "breeen", "brene", "bree",
            "mcgill", "mcgil", "macgill", "mcgilll",
            "nathaniel", "nathanael", "nathanel", "nathanniel",
            "elizabeth", "elisabeth", "elizbeth", "elizabet",
            "hallie", "hallei", "halie", "hallie1", "1234", "12345",
            "josé", "jose", "renée", "renee", "ünter", "unter",
            "verylongsurnamethatnobodyhas", "verylongsurnamethatnobodyhaz",
        ]
        var checked = 0
        var agreed = 0
        for lhs in words {
            for rhs in words {
                let mine = HallieSpellingRecovery.tokenDistance(lhs, rhs)
                let frozen = FrozenSpellingRecovery.tokenDistance(lhs, rhs)
                checked += 1
                if mine == frozen { agreed += 1 }
                #expect(mine == frozen,
                        Comment(rawValue: "\"\(lhs)\" ~ \"\(rhs)\": live \(String(describing: mine)) vs frozen \(String(describing: frozen))"))
            }
        }
        print("[spelling-equiv] tokenDistance: \(agreed)/\(checked) pairs agreed")
        #expect(checked == words.count * words.count)
    }

    // MARK: Whole-answer equivalence at production scale

    /// Typing a real name that IS in the tree, and typos of it. Both
    /// implementations must return the SAME identity set — not merely a
    /// non-empty one, which is how a broken fuzzy matcher passes a lazy
    /// test.
    @Test("bestMatches agrees with the frozen implementation over 16,383 people")
    func bestMatchesMatchesFrozenAtScale() throws {
        let candidates = Self.candidates
        try #require(candidates.count == 16_383)
        var rng = Seeded(state: 0xC0FFEE_1234_5678)

        var probes: [String] = []
        let names = Self.graph.people.values.map(\.name).sorted()
        // Exact names, spread through the tree.
        for i in stride(from: 0, to: names.count, by: 400) { probes.append(names[i]) }
        // Seeded typos: drop, double, swap, substitute one character.
        for i in stride(from: 7, to: names.count, by: 397) {
            var chars = Array(names[i])
            guard chars.count > 5 else { continue }
            let at = 1 + Int(rng.next() % UInt64(chars.count - 2))
            switch rng.next() % 4 {
            case 0: chars.remove(at: at)
            case 1: chars.insert(chars[at], at: at)
            case 2: chars.swapAt(at, at - 1)
            default: chars[at] = "z"
            }
            probes.append(String(chars))
        }
        // Names that are nowhere near the tree.
        probes += ["Zzyzx Quibbleton", "", "   ", "X", "Ann", "1999",
                   "a b c d e f g h", "José Renée Ünter"]

        var disagreements: [String] = []
        for probe in probes {
            let mine = HallieSpellingRecovery.bestMatches(typed: probe, candidates: candidates)
            let frozen = FrozenSpellingRecovery.bestMatches(typed: probe, candidates: candidates)
            if mine != frozen {
                disagreements.append("\"\(probe)\": \(mine.count) vs \(frozen.count)")
            }
        }
        print("[spelling-equiv] bestMatches: \(probes.count) probes over \(candidates.count) people, \(disagreements.count) disagreements")
        #expect(disagreements.isEmpty,
                Comment(rawValue: disagreements.prefix(5).joined(separator: "; ")))
        // The probes must actually exercise the matcher: an all-empty run
        // would agree trivially.
        let productive = probes.filter {
            !HallieSpellingRecovery.bestMatches(typed: $0, candidates: candidates).isEmpty
        }
        print("[spelling-equiv] \(productive.count) of \(probes.count) probes produced a match")
        #expect(productive.count >= 10,
                Comment(rawValue: "only \(productive.count) probes matched anything — equivalence would be vacuous"))
    }

    // MARK: Scale sensor

    /// The regression sensor. A worst-case turn is ONE `bestMatches` call
    /// against every person in the tree; this pins its cost so a future
    /// change that reintroduces per-candidate allocation is visible.
    @Test("worst-case fuzzy resolve over 16,383 people, with the frozen cost for scale")
    func fuzzyResolveAtScaleIsBounded() throws {
        let candidates = Self.candidates
        let probe = "Nathanniel Bradforde"   // near-miss: forces the full DP

        func time(_ body: () -> [String]) -> (Double, [String]) {
            let start = ContinuousClock.now
            let value = body()
            let d = ContinuousClock.now - start
            return (Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18, value)
        }
        _ = time { HallieSpellingRecovery.bestMatches(typed: probe, candidates: candidates) }

        var live: [Double] = []
        for _ in 0..<5 {
            live.append(time { HallieSpellingRecovery.bestMatches(typed: probe, candidates: candidates) }.0)
        }
        let (frozenSeconds, frozenResult) = time {
            FrozenSpellingRecovery.bestMatches(typed: probe, candidates: candidates)
        }
        let liveBest = live.min() ?? 0
        let (_, liveResult) = time { HallieSpellingRecovery.bestMatches(typed: probe, candidates: candidates) }
        #expect(liveResult == frozenResult)

        print(String(format: "[spelling-equiv] worst-case resolve over %d people: live %.1f ms, frozen %.1f ms (x%.1f) [%@]",
                     candidates.count, liveBest * 1000, frozenSeconds * 1000,
                     frozenSeconds / max(liveBest, 1e-9),
                     PerformanceLane.configurationName))

        // Loose, always-on ceiling. Only fires if a turn starts doing
        // something asymptotically worse than one pass over the tree.
        #expect(liveBest < 5.0,
                Comment(rawValue: String(format: "worst-case fuzzy resolve took %.0f ms", liveBest * 1000)))
        // Relative claim, true on any machine at any optimisation level:
        // the live path must not be SLOWER than the implementation it
        // replaced.
        #expect(liveBest <= frozenSeconds * 1.10,
                Comment(rawValue: String(format: "live %.1f ms is slower than frozen %.1f ms", liveBest * 1000, frozenSeconds * 1000)))
        if PerformanceLane.isAuthoritative(optInKey: Self.performanceOptIn) {
            #expect(liveBest < 0.060,
                    Comment(rawValue: String(format: "Release budget: %.1f ms", liveBest * 1000)))
        }
    }
}
