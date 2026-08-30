// HallieNameSuggestion.swift
// "Did you mean Judson Lamb?" (Rick, live 2026-08-24: "Jusson Lambe…
// Issaa Damno…"). When a typed name matches nobody, offer the closest
// real names as a clarification — never a silent substitution.
//
// Pure: names in, suggestions out. Matching is token-wise edit distance
// against GEDCOM and People-tab names; every typed token must land on a
// distinct name token within its budget, so "Jusson Lambe" reaches
// "Judson Lamb" while "John Smith" cannot drift to "Joan Smyth" through a
// pile of small edits (two tokens each costing the maximum is rejected).

import Foundation
import VideoScanCore

enum HallieNameSuggestion {

    struct Suggestion: Equatable, Sendable {
        enum Identity: Equatable, Sendable {
            case gedcom(id: String)
            case profile(stableID: String)
        }
        let identity: Identity
        let name: String
        let label: String
        /// Total edits across tokens — lower is better.
        let cost: Int
    }

    /// Closest names to `typed`, best first, at most `limit`. Empty when
    /// nothing is close enough. Exact matches are excluded (the caller
    /// only asks after resolution already failed).
    static func suggest(
        _ typed: String,
        graph: GedcomFamilyGraph?,
        profiles: [(stableID: String, name: String, aliases: [String])] = [],
        limit: Int = 3
    ) -> [Suggestion] {
        let typedTokens = FamilyIdentityText.tokens(typed)
        guard !typedTokens.isEmpty, typedTokens.allSatisfy({ $0.count >= 2 }) else { return [] }

        // Prepared ONCE. `suggest` runs over every person in the tree on
        // the same turn as HallieSpellingRecovery.bestMatches, so anything
        // done per candidate is done ~16,000 times: on Rick's export those
        // two scans were the whole of the slowest question shape in
        // HallieQueryBench. Same answers, pinned against a frozen copy in
        // HallieNameSuggestionEquivalenceTests.
        let preparedTyped = typedTokens.map(HallieSpellingRecovery.PreparedToken.init)
        var scratch = HallieSpellingRecovery.MatrixScratch()

        var found: [Suggestion] = []
        if let graph {
            for person in graph.people.values {
                guard let cost = matchCost(preparedTyped,
                                           against: FamilyIdentityText.tokens(person.name),
                                           &scratch) else { continue }
                var label = person.name
                if let year = person.birthYear { label += " (born \(year))" }
                found.append(Suggestion(identity: .gedcom(id: person.id), name: person.name,
                                        label: label, cost: cost))
            }
        }
        for profile in profiles {
            let names = [profile.name] + profile.aliases
            let best = names.compactMap {
                matchCost(preparedTyped, against: FamilyIdentityText.tokens($0), &scratch)
            }.min()
            if let best {
                found.append(Suggestion(identity: .profile(stableID: profile.stableID),
                                        name: profile.name, label: "\(profile.name) (People tab)", cost: best))
            }
        }
        // Distinct people stay distinct (two Judson Lambs, told apart by
        // their labels); a People-tab profile that merely repeats a GEDCOM
        // name is folded away.
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
        let ranked = kept
            .sorted { $0.cost == $1.cost ? $0.label < $1.label : $0.cost < $1.cost }
        // The limit must never SPLIT people who share a name: offering one
        // of two Judson Lambs and hiding the other would resolve a real
        // GEDCOM ambiguity by accident (codex #663). Take the top `limit`,
        // then pull in every remaining entry whose name is already listed.
        // Bounded (codex #675): a pathological tree with hundreds of one
        // name still gets a chip list a person can read, not every entry.
        let head = Array(ranked.prefix(limit))
        let listedNames = Set(head.map { FamilyIdentityText.normalized($0.name) })
        let tail = ranked.dropFirst(limit).filter {
            listedNames.contains(FamilyIdentityText.normalized($0.name))
        }
        return head + tail.prefix(max(0, Self.maxSuggestions - head.count))
    }

    /// Hard ceiling on offered chips, same-name groups included.
    static let maxSuggestions = 12

    /// Sum of per-token edit distances when EVERY typed token matches a
    /// distinct name token within budget (≤1 edit for tokens up to 4
    /// letters, ≤2 for longer); nil when any token has no match. At least
    /// one token must be a non-trivial match (cost > 0 somewhere) — an
    /// all-exact match is not a "suggestion".
    static func matchCost(_ typed: [String], against nameTokens: [String]) -> Int? {
        var scratch = HallieSpellingRecovery.MatrixScratch()
        return matchCost(typed.map(HallieSpellingRecovery.PreparedToken.init),
                         against: nameTokens, &scratch)
    }

    static func matchCost(
        _ typed: [HallieSpellingRecovery.PreparedToken],
        against nameTokens: [String],
        _ scratch: inout HallieSpellingRecovery.MatrixScratch
    ) -> Int? {
        guard !nameTokens.isEmpty else { return nil }
        var remaining = nameTokens.map(HallieSpellingRecovery.PreparedToken.init)
        var total = 0
        for token in typed {
            let budget = token.count <= 4 ? 1 : 2
            var bestIndex: Int?
            var bestCost = Int.max
            for (i, candidate) in remaining.enumerated() {
                let d = editDistance(token, candidate, limit: budget, &scratch)
                if d <= budget, d < bestCost { bestCost = d; bestIndex = i }
            }
            guard let index = bestIndex else { return nil }
            remaining.remove(at: index)
            total += bestCost
        }
        return total > 0 ? total : nil
    }

    /// Levenshtein distance, capped: returns `limit + 1` as soon as the
    /// distance is known to exceed `limit`.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        var scratch = HallieSpellingRecovery.MatrixScratch()
        return editDistance(HallieSpellingRecovery.PreparedToken(a),
                            HallieSpellingRecovery.PreparedToken(b),
                            limit: limit, &scratch)
    }

    /// Same metric, same cap, no allocation: the tokens arrive already
    /// converted and the rows live in a buffer the caller reuses across
    /// every candidate in the tree. The old version built two Arrays per
    /// call and TWO MORE per row of the matrix.
    static func editDistance(
        _ a: HallieSpellingRecovery.PreparedToken,
        _ b: HallieSpellingRecovery.PreparedToken,
        limit: Int,
        _ scratch: inout HallieSpellingRecovery.MatrixScratch
    ) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.characters.isEmpty { return b.count }
        if b.characters.isEmpty { return a.count }
        // A character in one word and not the other costs at least one
        // edit, so this rejects most of a 16k-name tree without touching
        // the matrix. Only a REJECTION is taken from it: the exact value
        // still comes from the recurrence below.
        if (a.present & ~b.present).nonzeroBitCount > limit
            || (b.present & ~a.present).nonzeroBitCount > limit {
            return limit + 1
        }
        let x = a.characters
        let y = b.characters
        let width = y.count + 1
        scratch.reserve(columns: width)
        return scratch.rows.withUnsafeMutableBufferPointer { rows -> Int in
            var previous = 0
            var current = width
            for column in 0...y.count { rows[previous + column] = column }
            for i in 1...x.count {
                rows[current] = i
                var rowMin = i
                let xi = x[i - 1]
                for j in 1...y.count {
                    let cost = xi == y[j - 1] ? 0 : 1
                    let value = Swift.min(
                        rows[previous + j] + 1,
                        rows[current + j - 1] + 1,
                        rows[previous + j - 1] + cost)
                    rows[current + j] = value
                    if value < rowMin { rowMin = value }
                }
                if rowMin > limit { return limit + 1 }
                swap(&previous, &current)
            }
            return rows[previous + y.count]
        }
    }
}
