// PersonNameClaim.swift
// ONE precedence rule for "who does this typed name mean?", and one
// dedupe for the person terms that reach prose.
//
// WHY (2026-09-03, demo eval lv260902-004 / lv260902-023 / cj008). Rick's
// brother Tim and Rick's son Timmy are separate people whose alias lists
// cross-contaminate: Tim's profile lists "Timmy" as an alias and Timmy's
// lists "Tim". Every identity route treated a canonical NAME match and an
// ALIAS match as equally strong, so the bare term "tim" claimed two
// profiles and Hallie asked "Which tim do you mean?" for every question
// about either of them.
//
// The People tab settled this on 2026-08-22: EXACT NAME WINS. A candidate
// whose own name is the typed spelling beats a candidate that answers to
// it only through an alias. Disambiguation is still correct — and still
// happens — when two candidates match by name (two people really called
// "John"), which is the only case where Hallie genuinely cannot tell.
//
// C++ readers: a namespace of pure static functions over value types. The
// generic `narrow` takes key-extractor closures instead of a protocol so
// the three call sites can pass their own unrelated snapshot types
// (POI profiles, graph snapshots, resolver entries) without adopting a
// common base — closer to a template with a policy argument than to
// inheritance.

import Foundation

enum PersonNameClaim {

    /// How strongly a candidate claims a typed spelling. `name` outranks
    /// `alias`; there is deliberately no third tier (a fuzzy/spelling
    /// recovery is a different question, decided by its own caller).
    enum Strength: Int, Comparable, Sendable {
        case alias = 0
        case name = 1

        static func < (lhs: Strength, rhs: Strength) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// `nil` when the candidate does not answer to `typed` at all.
    static func strength(
        of typed: String, name: String, aliases: [String]
    ) -> Strength? {
        let key = PersonResolver.normalize(typed)
        guard !key.isEmpty else { return nil }
        if PersonResolver.normalize(name) == key { return .name }
        if aliases.contains(where: { PersonResolver.normalize($0) == key }) {
            return .alias
        }
        return nil
    }

    /// The claimants of `typed` at the strongest strength ANY of them
    /// reaches: exact-name claimants if there are any, otherwise the alias
    /// claimants. Input order is preserved, and candidates that do not
    /// claim the spelling at all are dropped.
    ///
    /// Two exact-name claimants come back as two — that is real ambiguity
    /// and the caller must still ask.
    static func narrow<Candidate>(
        _ candidates: [Candidate],
        typed: String,
        name: (Candidate) -> String,
        aliases: (Candidate) -> [String]
    ) -> [Candidate] {
        var byName: [Candidate] = []
        var byAlias: [Candidate] = []
        for candidate in candidates {
            switch strength(of: typed,
                            name: name(candidate),
                            aliases: aliases(candidate)) {
            case .name:  byName.append(candidate)
            case .alias: byAlias.append(candidate)
            case nil:    continue
            }
        }
        return byName.isEmpty ? byAlias : byName
    }

    /// Person terms with duplicates removed under `PersonResolver.normalize`
    /// — case, diacritics and surrounding whitespace. The FIRST spelling of
    /// each identity survives, so the result is deterministic.
    ///
    /// This is the guard that stopped "I don't have any videos tagged with
    /// tim and Tim yet": one typed term became two person terms differing
    /// only in case, and the prose joiner dutifully said both.
    static func dedupe(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.filter { seen.insert(PersonResolver.normalize($0)).inserted }
    }
}
