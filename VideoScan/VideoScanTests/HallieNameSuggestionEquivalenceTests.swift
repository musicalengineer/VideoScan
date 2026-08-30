// HallieNameSuggestionEquivalenceTests.swift
// 2026-08-30. `HallieNameSuggestion.suggest` is the second full-tree scan
// on a "that name matches nobody" turn — it runs beside
// `HallieSpellingRecovery.bestMatches`, over the same 16,383 people, and
// in the profile of HallieQueryBench's slowest question shape it was the
// LARGER of the two.
//
// The optimisation is allocation removal only: typed tokens prepared once
// instead of per person, candidate tokens prepared once instead of once
// per typed token, a character-presence bitmask that rejects hopeless
// pairs before the matrix, and rolling rows in a caller-owned buffer
// instead of two fresh Arrays per ROW. None of that is allowed to change
// an answer, so this file keeps a frozen copy of the previous
// implementation and makes the two agree.

import Testing
import Foundation
@testable import VideoScan
import VideoScanCore

/// The implementation as of commit 2f6f0988, copied verbatim.
enum FrozenNameSuggestion {

    static func matchCost(_ typed: [String], against nameTokens: [String]) -> Int? {
        guard !nameTokens.isEmpty else { return nil }
        var remaining = nameTokens
        var total = 0
        for token in typed {
            let budget = token.count <= 4 ? 1 : 2
            var bestIndex: Int?
            var bestCost = Int.max
            for (i, candidate) in remaining.enumerated() {
                let d = editDistance(token, candidate, limit: budget)
                if d <= budget, d < bestCost { bestCost = d; bestIndex = i }
            }
            guard let index = bestIndex else { return nil }
            remaining.remove(at: index)
            total += bestCost
        }
        return total > 0 ? total : nil
    }

    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > limit { return limit + 1 }
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            var rowMin = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMin = min(rowMin, current[j])
            }
            if rowMin > limit { return limit + 1 }
            previous = current
        }
        return previous[y.count]
    }

    /// The whole-tree scan, frozen, so the suggestion LISTS can be compared
    /// and not merely the metric.
    static func suggest(
        _ typed: String,
        graph: GedcomFamilyGraph?,
        profiles: [(stableID: String, name: String, aliases: [String])] = [],
        limit: Int = 3
    ) -> [HallieNameSuggestion.Suggestion] {
        typealias Suggestion = HallieNameSuggestion.Suggestion
        let typedTokens = FamilyIdentityText.tokens(typed)
        guard !typedTokens.isEmpty, typedTokens.allSatisfy({ $0.count >= 2 }) else { return [] }

        var found: [Suggestion] = []
        if let graph {
            for person in graph.people.values {
                guard let cost = matchCost(typedTokens, against: FamilyIdentityText.tokens(person.name)) else { continue }
                var label = person.name
                if let year = person.birthYear { label += " (born \(year))" }
                found.append(Suggestion(identity: .gedcom(id: person.id), name: person.name,
                                        label: label, cost: cost))
            }
        }
        for profile in profiles {
            let names = [profile.name] + profile.aliases
            let best = names.compactMap { matchCost(typedTokens, against: FamilyIdentityText.tokens($0)) }.min()
            if let best {
                found.append(Suggestion(identity: .profile(stableID: profile.stableID),
                                        name: profile.name, label: "\(profile.name) (People tab)", cost: best))
            }
        }
        let gedcomNames = Set(found.compactMap { s -> String? in
            if case .gedcom = s.identity { return FamilyIdentityText.normalized(s.name) }
            return nil
        })
        let kept = found.filter { s in
            if case .profile = s.identity {
                return !gedcomNames.contains(FamilyIdentityText.normalized(s.name))
            }
            return true
        }
        let ranked = kept.sorted { $0.cost == $1.cost ? $0.label < $1.label : $0.cost < $1.cost }
        let head = Array(ranked.prefix(limit))
        let listedNames = Set(head.map { FamilyIdentityText.normalized($0.name) })
        let tail = ranked.dropFirst(limit).filter {
            listedNames.contains(FamilyIdentityText.normalized($0.name))
        }
        return head + tail.prefix(max(0, HallieNameSuggestion.maxSuggestions - head.count))
    }
}

@Suite("Hallie name suggestion — frozen-reference equivalence + scale")
struct HallieNameSuggestionEquivalenceTests {

    static let performanceOptIn = "VIDEOSCAN_HALLIE_PERF"

    static let graph = GedcomFamilyGraph(
        gedcomText: GedcomSyntheticPedigree.gedcom(people: 16_383))

    static let profiles: [(stableID: String, name: String, aliases: [String])] = [
        (stableID: "owner", name: "Rick Breen", aliases: ["Rick", "Richard Breen"]),
        (stableID: "donna", name: "Donna Hudson", aliases: ["Donna"]),
        (stableID: "hallie", name: "Hallie Mae McGill", aliases: ["Hallie"]),
    ]

    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
    }

    /// The metric, over pairs chosen to hit the cap, the length guard, the
    /// empty cases and the exact values other suites already assert.
    @Test("editDistance agrees with the frozen implementation wherever the value is meaningful")
    func editDistanceMatchesFrozen() {
        let words = ["", "a", "ab", "abc", "jusson", "judson", "lambe", "lamb",
                     "issaa", "isaac", "abcdef", "xyz", "breen", "brene", "bren",
                     "nathaniel", "nathanniel", "elizabeth", "elisabeth",
                     "josé", "jose", "1234", "12345", "AAAA", "aaaa"]
        var compared = 0
        for lhs in words {
            for rhs in words {
                for limit in [1, 2, 3] {
                    let mine = HallieNameSuggestion.editDistance(lhs, rhs, limit: limit)
                    let frozen = FrozenNameSuggestion.editDistance(lhs, rhs, limit: limit)
                    compared += 1
                    // Inside the cap the value must be identical. Above it
                    // both are only ever compared against the cap, and the
                    // frozen one is not consistent about which "too far"
                    // number it reports, so the claim is "both over".
                    if frozen <= limit || mine <= limit {
                        #expect(mine == frozen,
                                Comment(rawValue: "\"\(lhs)\"~\"\(rhs)\" limit \(limit): live \(mine) vs frozen \(frozen)"))
                    } else {
                        #expect(mine > limit && frozen > limit)
                    }
                }
            }
        }
        print("[suggest-equiv] editDistance: \(compared) (pair, limit) combinations compared")
        // The exact values the shipped suite pins, restated here so this
        // file fails on its own if the metric drifts.
        #expect(HallieNameSuggestion.editDistance("jusson", "judson", limit: 2) == 1)
        #expect(HallieNameSuggestion.editDistance("issaa", "isaac", limit: 2) == 2)
        #expect(HallieNameSuggestion.editDistance("abcdef", "xyz", limit: 2) == 3)
    }

    @Test("suggest returns the same list as the frozen implementation over 16,383 people")
    func suggestMatchesFrozenAtScale() throws {
        let graph = Self.graph
        try #require(graph.people.count == 16_383)
        var rng = Seeded(state: 0xBEEF_0000_1234)
        let names = graph.people.values.map(\.name).sorted()

        var probes: [String] = ["Jusson Lambe", "Issaa Damno", "Rik Bren",
                                "Donna Hudsen", "Hallie Mcgil", "", "  ", "Zzz"]
        for i in stride(from: 3, to: names.count, by: 431) {
            var chars = Array(names[i])
            guard chars.count > 6 else { continue }
            let at = 2 + Int(rng.next() % UInt64(chars.count - 3))
            switch rng.next() % 3 {
            case 0: chars.remove(at: at)
            case 1: chars.swapAt(at, at - 1)
            default: chars[at] = "q"
            }
            probes.append(String(chars))
        }

        var disagreements = 0
        var productive = 0
        for probe in probes {
            let mine = HallieNameSuggestion.suggest(probe, graph: graph, profiles: Self.profiles)
            let frozen = FrozenNameSuggestion.suggest(probe, graph: graph, profiles: Self.profiles)
            if mine != frozen {
                disagreements += 1
                Issue.record(Comment(rawValue: "\"\(probe)\": \(mine.map(\.label)) vs \(frozen.map(\.label))"))
            }
            if !mine.isEmpty { productive += 1 }
        }
        print("[suggest-equiv] suggest: \(probes.count) probes over 16,383 people, \(disagreements) disagreements, \(productive) produced suggestions")
        #expect(disagreements == 0)
        #expect(productive >= 10,
                Comment(rawValue: "only \(productive) probes suggested anything — equivalence would be vacuous"))
    }

    @Test("worst-case suggest over 16,383 people, live against frozen")
    func suggestAtScaleIsBounded() {
        let graph = Self.graph
        let probe = "Nathanniel Bradforde"

        func time(_ body: () -> [HallieNameSuggestion.Suggestion]) -> (Double, [HallieNameSuggestion.Suggestion]) {
            let start = ContinuousClock.now
            let value = body()
            let d = ContinuousClock.now - start
            return (Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18, value)
        }
        _ = time { HallieNameSuggestion.suggest(probe, graph: graph, profiles: Self.profiles) }

        var live: [Double] = []
        var liveResult: [HallieNameSuggestion.Suggestion] = []
        for _ in 0..<5 {
            let (seconds, value) = time { HallieNameSuggestion.suggest(probe, graph: graph, profiles: Self.profiles) }
            live.append(seconds)
            liveResult = value
        }
        let (frozenSeconds, frozenResult) = time {
            FrozenNameSuggestion.suggest(probe, graph: graph, profiles: Self.profiles)
        }
        let liveBest = live.min() ?? 0
        #expect(liveResult == frozenResult)
        print(String(format: "[suggest-equiv] worst-case suggest over 16,383 people: live %.1f ms, frozen %.1f ms (x%.1f) [%@]",
                     liveBest * 1000, frozenSeconds * 1000,
                     frozenSeconds / max(liveBest, 1e-9),
                     PerformanceLane.configurationName))

        #expect(liveBest < 5.0,
                Comment(rawValue: String(format: "worst-case suggest took %.0f ms", liveBest * 1000)))
        #expect(liveBest <= frozenSeconds * 1.10,
                Comment(rawValue: String(format: "live %.1f ms is slower than frozen %.1f ms", liveBest * 1000, frozenSeconds * 1000)))
        if PerformanceLane.isAuthoritative(optInKey: Self.performanceOptIn) {
            #expect(liveBest < 0.060,
                    Comment(rawValue: String(format: "Release budget: %.1f ms", liveBest * 1000)))
        }
    }
}
