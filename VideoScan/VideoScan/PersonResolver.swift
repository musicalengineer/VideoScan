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

enum PersonListResolution: Sendable, Equatable {
    case resolved(canonicalNames: [String])
    case ambiguous(typedName: String, candidates: [String])
    case segmentationAmbiguous(options: [[String]])
    case tooMany(limit: Int)
    case unknown(typedName: String)
}

struct PersonResolver: Sendable {

    /// Keep the resolver's pre-normalization combinatorics bounded. This
    /// mirrors NLQueryNormalizer.maxListItems, but is enforced here because
    /// translator output reaches identity resolution before normalization.
    static let maxPeoplePerQuestion = 6

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

    /// Production bridge from the persisted People gallery. Keep this
    /// mapping here (instead of at a call site) so aliases cannot silently
    /// disappear from Archivist resolution during a UI refactor.
    init(profiles: [POIProfile]) {
        self.init(people: profiles.map {
            ResolvablePerson(canonicalName: $0.name, aliases: $0.aliases)
        })
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

    /// Resolve a translator-produced person list atomically. The caller
    /// receives canonical names for query composition, or the first item
    /// that requires a human clarification. Merely validating an alias and
    /// then searching the original spelling would produce false zero hits.
    func resolveAll(_ typedNames: [String]) -> PersonListResolution {
        guard typedNames.count <= Self.maxPeoplePerQuestion else {
            return .tooMany(limit: Self.maxPeoplePerQuestion)
        }
        guard !typedNames.isEmpty else {
            return .resolved(canonicalNames: [])
        }

        // A translator may split one multi-word identity into neighboring
        // array elements ("Dad Breen" -> ["dad", "breen"]) while leaving
        // other people intact. Segment the capped (<= 6) wire list into
        // resolvable identities, preferring the shortest valid span so two
        // independently valid people remain two people.
        func segment(from start: Int)
            -> (solutions: [[String]], firstIssue: PersonListResolution?) {
            var solutions: [[String]] = []
            var firstIssue: PersonListResolution?
            for end in start..<typedNames.count {
                let phrase = typedNames[start...end].joined(separator: " ")
                switch self.resolve(phrase) {
                case .resolved(let canonicalName):
                    if end == typedNames.index(before: typedNames.endIndex) {
                        solutions.append([canonicalName])
                    } else {
                        let suffix = segment(
                            from: typedNames.index(after: end))
                        solutions.append(contentsOf: suffix.solutions.map {
                            [canonicalName] + $0
                        })
                        if firstIssue == nil {
                            firstIssue = suffix.firstIssue
                        }
                    }
                case .ambiguous(let candidates):
                    if firstIssue == nil {
                        firstIssue = .ambiguous(
                            typedName: phrase, candidates: candidates)
                    }
                case .unknown:
                    continue
                }
            }
            return (solutions, firstIssue)
        }

        let segmented = segment(from: typedNames.startIndex)
        var unique: [[String]] = []
        for solution in segmented.solutions where !unique.contains(solution) {
            unique.append(solution)
        }
        switch unique.count {
        case 0:
            return segmented.firstIssue
                ?? .unknown(typedName: typedNames[typedNames.startIndex])
        case 1:
            return .resolved(canonicalNames: unique[0])
        default:
            return .segmentationAmbiguous(options: unique)
        }
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

enum FamilyTreeIdentityResolution: Sendable, Equatable {
    case people([GedcomFamilyGraph.Person])
    case profileAmbiguous(candidates: [String])
}

/// Bridges POI nicknames to formal GEDCOM identities before biography or
/// kinship execution. Ancestors need not have POI profiles: an unknown POI
/// spelling falls back to direct GEDCOM token matching.
struct FamilyTreeIdentityResolver {
    private let graph: GedcomFamilyGraph
    private let profiles: [POIProfile]
    private let profileResolver: PersonResolver

    init(graph: GedcomFamilyGraph, profiles: [POIProfile]) {
        self.graph = graph
        self.profiles = profiles
        self.profileResolver = PersonResolver(profiles: profiles)
    }

    func resolve(_ typedName: String) -> FamilyTreeIdentityResolution {
        switch profileResolver.resolve(typedName) {
        case .resolved(let canonicalName):
            let matchingProfiles = profiles.filter {
                PersonResolver.normalize($0.name)
                    == PersonResolver.normalize(canonicalName)
            }
            // A unique formal profile name is stronger evidence than a
            // nickname. Consult one specificity tier at a time so a broad
            // alias such as "Richard" cannot contaminate an exact
            // "Richard Breen" GEDCOM match with unrelated Richards.
            let canonicalMatches = graph.people(matching: canonicalName)
            if !canonicalMatches.isEmpty {
                return .people(canonicalMatches)
            }

            let fallbackTerms = ([typedName]
                + matchingProfiles.flatMap(\.aliases))
                .filter {
                    PersonResolver.normalize($0)
                        != PersonResolver.normalize(canonicalName)
                }
                .sorted { lhs, rhs in
                    let lhsWords = lhs.split(whereSeparator: \.isWhitespace).count
                    let rhsWords = rhs.split(whereSeparator: \.isWhitespace).count
                    if lhsWords != rhsWords { return lhsWords > rhsWords }
                    return lhs.count > rhs.count
                }
            for term in fallbackTerms {
                let matches = graph.people(matching: term)
                if !matches.isEmpty { return .people(matches) }
            }
            return .people([])
        case .ambiguous(let candidates):
            return .profileAmbiguous(candidates: candidates)
        case .unknown:
            return .people(graph.people(matching: typedName))
        }
    }

}
