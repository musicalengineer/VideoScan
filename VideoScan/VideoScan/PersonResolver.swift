// PersonResolver.swift
// Family Archivist Phase 1 (docs/family-archivist-phase1.md): maps the
// names people actually type — nicknames, aliases, casual spellings —
// to canonical POI identities. Pure and injected so codex can test it
// without profiles on disk.
//
// Contract (design doc §deliverable 2): ambiguity is SURFACED, never
// guessed. A query naming a spelling that two identities own returns
// .ambiguous and the chat asks — a family archivist that guesses the
// wrong son is worse than one that asks. Unknown names return .unknown so
// the answer layer can say "I don't know anyone called X" instead of
// hallucinating a match.
//
// AMENDED 2026-09-03 (Director's rule, demo eval lv260902-023 / cj008):
// EXACT NAME WINS, the same precedence the People tab adopted 2026-08-22.
// "Tim" and "Timmy" are distinct POIs whose alias lists cross-contaminate
// — Tim's profile lists "Timmy", Timmy's lists "Tim" — so under the old
// "a name and an alias are equally strong" reading the bare term "tim"
// owned two identities and EVERY question about either one asked which.
// A candidate whose own name is the typed spelling now beats a candidate
// that answers to it only through an alias, and .ambiguous is reserved for
// what it was always for: two identities that genuinely share a name.
// The rule itself lives in PersonNameClaim so the graph and temporal
// routes decide identically.

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

    /// The identities that answer to one normalized spelling, split by HOW
    /// they answer to it. `winners` applies the exact-name-wins rule.
    private struct Claimants: Sendable {
        var byName: [String] = []
        var byAlias: [String] = []

        /// Exact-name claimants if there are any, else the alias claimants.
        /// Never empty for a key that exists in the index.
        var winners: [String] { byName.isEmpty ? byAlias : byName }
    }

    /// normalized token → the canonical names it could mean, by claim kind.
    private let index: [String: Claimants]
    private let spellingEntries: [SpellingEntry]

    init(people: [ResolvablePerson]) {
        var names: [String: Set<String>] = [:]
        var aliases: [String: Set<String>] = [:]
        for person in people {
            let canonical = person.canonicalName
            let nameKey = Self.normalize(canonical)
            if !nameKey.isEmpty { names[nameKey, default: []].insert(canonical) }
            for alias in person.aliases {
                let key = Self.normalize(alias)
                guard !key.isEmpty else { continue }
                aliases[key, default: []].insert(canonical)
            }
        }
        var idx: [String: Claimants] = [:]
        for (key, owners) in names {
            idx[key, default: Claimants()].byName = owners.sorted()
        }
        for (key, owners) in aliases {
            // An identity that owns the spelling by NAME does not also
            // claim it by alias (a profile may redundantly list its own
            // name among its aliases).
            let aliasOnly = owners.subtracting(names[key] ?? [])
            guard !aliasOnly.isEmpty else { continue }
            idx[key, default: Claimants()].byAlias = aliasOnly.sorted()
        }
        index = idx
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

    /// Exact normalized match first, under the exact-name-wins rule (see
    /// the file header and PersonNameClaim): an identity NAMED the typed
    /// spelling beats one that merely lists it as an alias. A narrowly
    /// bounded spelling recovery is attempted only when exact lookup
    /// fails: short names are never guessed, and tied nearest identities
    /// are surfaced as ambiguous.
    func resolve(_ typed: String) -> PersonResolution {
        let key = Self.normalize(typed)
        guard !key.isEmpty else { return .unknown }
        if let claimants = index[key] {
            let hits = claimants.winners
            if hits.count == 1 { return .resolved(canonicalName: hits[0]) }
            if hits.count > 1 { return .ambiguous(candidates: hits) }
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
    ///
    /// PERFORMANCE (2026-08-30). `ArchivistGraphExecutor.resolveUnselected`
    /// calls this with EVERY person in the tree when a typed name matches
    /// nobody, so on Rick's 16,383-person export one such turn was 778 ms
    /// p50 (Debug) — 96% of HallieQueryBench's whole p95. The work is the
    /// same as it always was; what changed is that the query side is
    /// prepared once instead of per candidate, each candidate's tokens are
    /// prepared once instead of once per typed token, a character
    /// histogram rejects hopeless pairs before the matrix is touched, and
    /// the matrix itself is one scratch buffer rather than a fresh
    /// array-of-arrays per pair. Results are identical by construction and
    /// pinned against a frozen copy of the previous implementation in
    /// HallieSpellingRecoveryEquivalenceTests.
    static func bestMatches(
        typed: String,
        candidates: [(identity: String, spellings: [String])]
    ) -> [String] {
        // The query is invariant across the candidate scan. On a 100k
        // GEDCOM, tokenizing it inside `nameScore` once per person was a
        // measurable part of every failed-name Hallie turn.
        let typedTokens = tokens(typed).map(PreparedToken.init)
        guard !typedTokens.isEmpty, typedTokens.count <= 6 else { return [] }
        var scores: [String: Int] = [:]
        var scratch = MatrixScratch()
        for candidate in candidates {
            for spelling in candidate.spellings {
                guard let score = nameScore(typedTokens, spelling, &scratch) else { continue }
                scores[candidate.identity] = min(
                    scores[candidate.identity] ?? Int.max, score)
            }
        }
        guard let best = scores.values.min() else { return [] }
        return scores.compactMap { $0.value == best ? $0.key : nil }.sorted()
    }

    private static func nameScore(
        _ typedTokens: [PreparedToken],
        _ candidate: String,
        _ scratch: inout MatrixScratch
    ) -> Int? {
        let rawCandidateTokens = tokens(candidate)
        guard rawCandidateTokens.count <= 8,
              typedTokens.count <= rawCandidateTokens.count else { return nil }
        // Prepared ONCE per candidate. The assignment search below asks
        // about the same candidate token from several typed positions, and
        // each of those used to re-tokenize and re-allocate it.
        let candidateTokens = rawCandidateTokens.map(PreparedToken.init)

        func assign(
            _ index: Int, used: Set<Int>, score: Int
        ) -> Int? {
            if index == typedTokens.count { return score > 0 ? score : nil }
            var best: Int?
            for candidateIndex in candidateTokens.indices
            where !used.contains(candidateIndex) {
                guard let distance = tokenDistance(
                    typedTokens[index], candidateTokens[candidateIndex],
                    &scratch) else {
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

    /// One token, with everything the distance needs computed once: its
    /// characters as an array (String is not random access), its length,
    /// and a presence bitmask.
    struct PreparedToken {
        let characters: [Character]
        let count: Int
        /// Bit per character class: a–z, 0–9, and one bit for everything
        /// else. Collapsing the tail can only UNDERSTATE how different two
        /// tokens are, so the bound it feeds stays a lower bound. A word,
        /// not an array — this is built once per candidate token on a
        /// 16k-name scan, and an allocation here is 16k allocations there.
        let present: UInt64

        init(_ token: String) {
            let characters = Array(token)
            self.characters = characters
            self.count = characters.count
            var mask: UInt64 = 0
            for character in characters { mask |= 1 << UInt64(Self.bit(character)) }
            self.present = mask
        }

        static func bit(_ character: Character) -> Int {
            guard let ascii = character.asciiValue else { return 36 }
            if ascii >= 97, ascii <= 122 { return Int(ascii) - 97 }
            if ascii >= 65, ascii <= 90 { return Int(ascii) - 65 }
            if ascii >= 48, ascii <= 57 { return 26 + Int(ascii) - 48 }
            return 36
        }
    }

    /// Reused row buffer for the alignment matrix. Three rows is all the
    /// recurrence reads (the transposition term looks two back), so the
    /// whole matrix never exists — and neither does a heap allocation per
    /// candidate.
    struct MatrixScratch {
        var rows: [Int] = Array(repeating: 0, count: 3 * 64)

        mutating func reserve(columns: Int) {
            let needed = 3 * columns
            if rows.count < needed { rows = Array(repeating: 0, count: needed) }
        }
    }

    /// Optimal-string-alignment distance, capped per token. Transposed keys
    /// (`shwo`) count as one edit. Words shorter than four characters must be
    /// exact, protecting short family names from risky guesses.
    private static func tokenDistance(
        _ lhs: PreparedToken, _ rhs: PreparedToken, _ scratch: inout MatrixScratch
    ) -> Int? {
        if lhs.count == rhs.count, lhs.characters == rhs.characters { return 0 }
        guard lhs.count >= 4, rhs.count >= 4 else { return nil }
        let limit = max(lhs.count, rhs.count) >= 8 ? 2 : 1
        guard abs(lhs.count - rhs.count) <= limit else { return nil }
        // Cheap necessary condition before the matrix. A character present
        // in one token and absent from the other costs at least one edit,
        // and a transposition costs nothing in this currency, so the count
        // of one-sided character classes is a lower bound on the distance.
        // Two AND-NOTs and two popcounts, instead of an O(n*m) matrix, for
        // the overwhelming majority of the 16k candidates.
        guard (lhs.present & ~rhs.present).nonzeroBitCount <= limit,
              (rhs.present & ~lhs.present).nonzeroBitCount <= limit else { return nil }
        return alignmentDistance(lhs.characters, rhs.characters, limit: limit, &scratch)
    }

    /// Three rolling rows over `scratch`. Bails as soon as a whole row is
    /// already above the cap: row minima never decrease as the row index
    /// grows, so nothing below can come back under it.
    private static func alignmentDistance(
        _ left: [Character], _ right: [Character], limit: Int,
        _ scratch: inout MatrixScratch
    ) -> Int? {
        let n = left.count
        let m = right.count
        let width = m + 1
        scratch.reserve(columns: width)
        return scratch.rows.withUnsafeMutableBufferPointer { rows -> Int? in
            var previousPrevious = 0
            var previous = width
            var current = 2 * width
            for column in 0...m { rows[previous + column] = column }
            for i in 1...n {
                rows[current] = i
                var rowMinimum = i
                let leftCharacter = left[i - 1]
                for j in 1...m {
                    let substitution = rows[previous + j - 1]
                        + (leftCharacter == right[j - 1] ? 0 : 1)
                    var value = Swift.min(
                        rows[previous + j] + 1,
                        rows[current + j - 1] + 1,
                        substitution)
                    if i > 1, j > 1,
                       leftCharacter == right[j - 2],
                       left[i - 2] == right[j - 1] {
                        value = Swift.min(value, rows[previousPrevious + j - 2] + 1)
                    }
                    rows[current + j] = value
                    if value < rowMinimum { rowMinimum = value }
                }
                if rowMinimum > limit { return nil }
                let recycled = previousPrevious
                previousPrevious = previous
                previous = current
                current = recycled
            }
            let distance = rows[previous + m]
            return distance <= limit ? distance : nil
        }
    }

    /// String form, for `repairRequestOpener` and the equivalence tests.
    static func tokenDistance(_ lhs: String, _ rhs: String) -> Int? {
        var scratch = MatrixScratch()
        return tokenDistance(PreparedToken(lhs), PreparedToken(rhs), &scratch)
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
