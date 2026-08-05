// PersonResolver.swift
// Family Archivist Phase 1 (docs/family-archivist-phase1.md): maps the
// names people actually type — nicknames, aliases, casual spellings —
// to canonical POI identities. Pure and injected so codex can test it
// without profiles on disk.
//
// Contract (design doc §deliverable 2): ambiguity is SURFACED, never
// guessed. "Tim" and "Timmy" are distinct POIs in this family; a query
// naming a shared alias returns .ambiguous and the chat asks — a family
// archivist that guesses the wrong son is worse than one that asks.
// Unknown names return .unknown so the answer layer can say "I don't
// know anyone called X" instead of hallucinating a match.

import Foundation

/// One resolvable identity: canonical name + the aliases/spellings that
/// map to it (from POIProfile.name / POIProfile.aliases).
struct ResolvablePerson: Sendable, Equatable {
    let canonicalName: String
    let aliases: [String]
}

enum PersonResolution: Sendable, Equatable {
    case resolved(canonicalName: String)
    /// The typed name maps to more than one identity — ask, don't guess.
    case ambiguous(candidates: [String])
    case unknown
}

struct PersonResolver: Sendable {

    /// normalized token → canonical names it could mean (sorted, unique).
    private let index: [String: [String]]

    init(people: [ResolvablePerson]) {
        var idx: [String: Set<String>] = [:]
        for person in people {
            let canonical = person.canonicalName
            for token in [person.canonicalName] + person.aliases {
                let key = Self.normalize(token)
                guard !key.isEmpty else { continue }
                idx[key, default: []].insert(canonical)
            }
        }
        index = idx.mapValues { $0.sorted() }
    }

    /// Exact normalized match on a name or alias. Phase 1 deliberately
    /// does no fuzzy/prefix matching — a wrong-person match in a family
    /// archive is a trust-destroying error, and the ambiguity path
    /// already gives the chat a graceful "which one?" turn.
    func resolve(_ typed: String) -> PersonResolution {
        let key = Self.normalize(typed)
        guard !key.isEmpty, let hits = index[key] else { return .unknown }
        if hits.count == 1 { return .resolved(canonicalName: hits[0]) }
        return .ambiguous(candidates: hits)
    }

    /// Lowercased, diacritics folded, whitespace trimmed — "Timmy",
    /// " timmy " and "TIMMY" are one key; "Renée"/"Renee" match.
    static func normalize(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .caseInsensitive],
                    locale: Locale(identifier: "en_US"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
