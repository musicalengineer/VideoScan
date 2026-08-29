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

    private struct SpellingEntry: Sendable {
        let canonicalName: String
        let spellings: [String]
    }

    /// Keep the resolver's pre-normalization combinatorics bounded. This
    /// mirrors NLQueryNormalizer.maxListItems, but is enforced here because
    /// translator output reaches identity resolution before normalization.
    static let maxPeoplePerQuestion = 6

    /// normalized token → canonical names it could mean (sorted, unique).
    private let index: [String: [String]]
    private let spellingEntries: [SpellingEntry]

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
        spellingEntries = people.map {
            SpellingEntry(
                canonicalName: $0.canonicalName,
                spellings: [$0.canonicalName] + $0.aliases)
        }
    }

    /// Production bridge from the persisted People gallery. Keep this
    /// mapping here (instead of at a call site) so aliases cannot silently
    /// disappear from Archivist resolution during a UI refactor.
    init(profiles: [POIProfile]) {
        self.init(people: profiles.map {
            ResolvablePerson(canonicalName: $0.name, aliases: $0.aliases)
        })
    }

    /// Exact normalized match first. A narrowly bounded spelling recovery is
    /// attempted only when exact lookup fails: short names are never guessed,
    /// and tied nearest identities are surfaced as ambiguous.
    func resolve(_ typed: String) -> PersonResolution {
        let key = Self.normalize(typed)
        guard !key.isEmpty else { return .unknown }
        if let hits = index[key] {
            if hits.count == 1 { return .resolved(canonicalName: hits[0]) }
            return .ambiguous(candidates: hits)
        }
        let recovered = HallieSpellingRecovery.bestMatches(
            typed: typed,
            candidates: spellingEntries.map {
                (identity: $0.canonicalName, spellings: $0.spellings)
            })
        if recovered.count == 1 {
            return .resolved(canonicalName: recovered[0])
        }
        if !recovered.isEmpty {
            return .ambiguous(candidates: recovered.sorted())
        }
        return .unknown
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

/// Small, deterministic typo layer shared by identity lookup and the two
/// Hallie clients. This is intentionally not a general spell checker: it can
/// only select from a closed caller-provided vocabulary.
enum HallieSpellingRecovery {
    struct QuestionRepair: Sendable, Equatable {
        let text: String
        let originalWord: String?
        let replacementWord: String?
    }

    static func repairRequestOpener(_ question: String) -> QuestionRepair {
        let words = question.split(whereSeparator: \Character.isWhitespace)
        guard words.count >= 2 else {
            return QuestionRepair(
                text: question, originalWord: nil, replacementWord: nil)
        }
        let first = String(words[0])
        let second = PersonResolver.normalize(String(words[1]))
        let allowed: [String]
        switch second {
        case "me", "us":
            allowed = ["show", "tell", "find", "give"]
        case "my", "the", "a", "all", "some", "any":
            allowed = ["show", "find", "search", "list", "open", "play"]
        default:
            return QuestionRepair(
                text: question, originalWord: nil, replacementWord: nil)
        }
        let normalizedFirst = PersonResolver.normalize(first)
        guard !allowed.contains(normalizedFirst) else {
            return QuestionRepair(
                text: question, originalWord: nil, replacementWord: nil)
        }
        let ranked = allowed.compactMap { candidate -> (String, Int)? in
            guard let distance = tokenDistance(
                normalizedFirst, candidate), distance == 1 else { return nil }
            return (candidate, distance)
        }
        guard ranked.count == 1, let replacement = ranked.first?.0,
              let range = question.range(of: first) else {
            return QuestionRepair(
                text: question, originalWord: nil, replacementWord: nil)
        }
        var repaired = question
        repaired.replaceSubrange(range, with: replacement)
        return QuestionRepair(
            text: repaired, originalWord: first,
            replacementWord: replacement)
    }

    /// Returns the identity or identities tied at the lowest acceptable
    /// edit score. Callers resolve a singleton and clarify a tie.
    static func bestMatches(
        typed: String,
        candidates: [(identity: String, spellings: [String])]
    ) -> [String] {
        // The query is invariant across the candidate scan. On a 100k
        // GEDCOM, tokenizing it inside `nameScore` once per person was a
        // measurable part of every failed-name Hallie turn.
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

    private static func nameScore(_ typedTokens: [String], _ candidate: String) -> Int? {
        let candidateTokens = tokens(candidate)
        guard candidateTokens.count <= 8,
              typedTokens.count <= candidateTokens.count else { return nil }

        func assign(
            _ index: Int, used: Set<Int>, score: Int
        ) -> Int? {
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

    private static func tokens(_ value: String) -> [String] {
        PersonResolver.normalize(value)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Optimal-string-alignment distance, capped per token. Transposed keys
    /// (`shwo`) count as one edit. Words shorter than four characters must be
    /// exact, protecting short family names from risky guesses.
    private static func tokenDistance(_ lhs: String, _ rhs: String) -> Int? {
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
            // Try the profile's spellings MOST SPECIFIC FIRST (more words,
            // then longer), canonical name breaking ties. A formal
            // "Richard Breen" alias therefore beats a one-word canonical
            // nickname "Rick" (2026-08-27, codex #756: a literal GEDCOM
            // "Rick Smith" must not override the configured identity),
            // and a broad "Richard" alias still cannot contaminate an exact
            // "Richard Breen" match because it is tried after it.
            let terms = ([canonicalName] + matchingProfiles.flatMap(\.aliases) + [typedName])
            var seen = Set<String>()
            let ordered = terms.filter { seen.insert(PersonResolver.normalize($0)).inserted }
                .enumerated()
                .sorted { lhs, rhs in
                    let lhsWords = lhs.element.split(whereSeparator: \.isWhitespace).count
                    let rhsWords = rhs.element.split(whereSeparator: \.isWhitespace).count
                    if lhsWords != rhsWords { return lhsWords > rhsWords }
                    if lhs.element.count != rhs.element.count { return lhs.element.count > rhs.element.count }
                    return lhs.offset < rhs.offset
                }
                .map(\.element)
            for term in ordered {
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
