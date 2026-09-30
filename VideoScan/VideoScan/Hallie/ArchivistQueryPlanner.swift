import Foundation

/// Complete deterministic result of taking one translated catalog question
/// through identity resolution, normalization, and query composition. The UI
/// renders this plan; it does not reimplement planning branch by branch.
enum ArchivistQueryPlan: Equatable {
    case search(query: String, isCount: Bool, preface: String?,
                playAfterAnswer: Bool)
    case personAmbiguity(typedName: String, candidates: [String],
                         playAfterAnswer: Bool)
    case segmentationAmbiguity(options: [[String]], playAfterAnswer: Bool)
    case tooManyPeople(limit: Int)
    case unknownPerson(typedName: String, knownNames: [String],
                       playAfterAnswer: Bool)
}

enum ArchivistKinshipContinuation: Equatable {
    case factOnly
    case birthDate
    case deathDate
    case catalogSearch
}

/// Conversation-local continuation for a person-resolution question.  The
/// translator is deliberately not involved in the reply: it receives one
/// isolated request at a time and therefore cannot know what a bare "yes"
/// refers to.
struct ArchivistPersonClarification: Equatable {
    enum Reply: Equatable {
        case select(String)
        case reject
        case needsExplicitChoice
        case newQuestion
    }

    let question: String
    let spec: NLQuerySpec
    let candidates: [String]
    let playAfterAnswer: Bool

    func classify(_ text: String) -> Reply {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = Self.fold(trimmed)
        if let candidate = candidates.first(where: {
            let name = Self.fold($0)
            return [
                name,
                "i mean \(name)",
                "yes \(name)",
                "\(name) please",
                "the \(name) one",
            ].contains(folded)
        }) {
            return .select(candidate)
        }

        let affirmative: Set<String> = [
            "yes", "y", "yeah", "yep", "correct", "right", "thats right",
        ]
        if affirmative.contains(folded) {
            return candidates.count == 1
                ? .select(candidates[0]) : .needsExplicitChoice
        }
        let negative: Set<String> = ["no", "n", "nope"]
        if negative.contains(folded) { return .reject }
        return .newQuestion
    }

    /// Atomically classify a reply and retire the continuation unless the
    /// reply still needs an explicit choice.  This is the state-transition
    /// seam used by the chat view and by regression tests.
    static func consume(
        _ pending: inout ArchivistPersonClarification?,
        reply text: String
    ) -> Reply? {
        guard let current = pending else { return nil }
        let result = current.classify(text)
        if result != .needsExplicitChoice { pending = nil }
        return result
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }
}

enum ArchivistQueryPlanner {
    static let literalFallbackPreface =
        "I couldn't derive a structured filter, so I searched your words literally."

    /// Continue a catalog search after Swift has resolved a GEDCOM
    /// relationship. The resolved names are family evidence, so they must go
    /// straight into the deterministic query pipeline and must never be
    /// interpolated into a new sentence sent back through the LLM.
    static func kinshipContinuation(
        for question: String,
        matchedPhrase: String,
        playAfterAnswer: Bool
    ) -> ArchivistKinshipContinuation {
        let words = Set(question.lowercased().split(whereSeparator: {
            !$0.isLetter && !$0.isNumber
        }).map(String.init))
        if words.contains("when") && words.contains("born") {
            return .birthDate
        }
        if words.contains("when")
            && !words.isDisjoint(with: ["die", "died", "death"]) {
            return .deathDate
        }
        if playAfterAnswer { return .catalogSearch }

        // After removing the possessive relationship, only a small set of
        // biography carrier words may remain for a fact-only question.
        // Anything substantive ("Christmas", "appear", "do we have") is a
        // catalog constraint and must take the search path.
        let residual = question.replacingOccurrences(
            of: matchedPhrase, with: "", options: .caseInsensitive)
        let residualWords = Set(residual.lowercased().split(whereSeparator: {
            !$0.isLetter && !$0.isNumber
        }).map(String.init))
        let factCarriers: Set<String> = ["who", "is", "was", "tell", "me", "about"]
        return residualWords.isSubset(of: factCarriers)
            ? .factOnly : .catalogSearch
    }

    /// Merge a translation of the ORIGINAL user sentence with names resolved
    /// by Swift. The model never sees those resolved names. Relationship words
    /// are removed when they appear as bare content constraints; otherwise a
    /// translated `father` keyword would require the filename/caption to say
    /// "father" in addition to containing the actual person.
    ///
    /// Returns nil rather than allowing NLQueryNormalizer to truncate a long
    /// set of relatives and silently broaden an autoplay search.
    static func kinshipCatalogSpec(
        translated: NLQuerySpec,
        resolvedNames: [String],
        relationWord: String
    ) -> NLQuerySpec? {
        let personTokens = resolvedNames.flatMap {
            NLQueryNormalizer.sanitizeValue($0).split(separator: " ")
        }
        guard !personTokens.isEmpty,
              personTokens.count <= NLQueryNormalizer.maxListItems else {
            return nil
        }

        let relation = NLQueryNormalizer.sanitizeValue(relationWord)
        func withoutRelation(_ values: [String]?) -> [String]? {
            guard let values else { return nil }
            let relationCarriers: Set<String> = [
                "a", "an", "at", "his", "her", "my", "of", "the", "their", "with",
            ]
            let kept = values.flatMap { value -> [String] in
                let sanitized = NLQueryNormalizer.sanitizeValue(value)
                let tokens = sanitized.split(separator: " ").map(String.init)
                guard tokens.contains(relation) else {
                    return sanitized.isEmpty ? [] : [sanitized]
                }
                // A phrase containing the relationship is translator
                // scaffolding, not a literal phrase constraint. Preserve its
                // remaining content as independent AND terms.
                return tokens.filter {
                    $0 != relation && !relationCarriers.contains($0)
                }
            }
            return kept.isEmpty ? nil : kept
        }

        var spec = translated
        spec.people = resolvedNames
        spec.keywords = withoutRelation(translated.keywords)
        spec.transcript = withoutRelation(translated.transcript)
        return spec
    }

    static func plan(
        question: String,
        spec: NLQuerySpec,
        profiles: [POIProfile],
        resolvedPeople: [String]? = nil,
        playAfterAnswer: Bool
    ) -> ArchivistQueryPlan {
        var resolvedSpec = spec
        if let resolvedPeople {
            resolvedSpec.people = resolvedPeople
        } else if !profiles.isEmpty {
            switch PersonResolver(profiles: profiles)
                .resolveAll(spec.people ?? []) {
            case .resolved(let canonicalNames):
                resolvedSpec.people = canonicalNames
            case .ambiguous(let typedName, let candidates):
                return .personAmbiguity(
                    typedName: typedName,
                    candidates: candidates,
                    playAfterAnswer: playAfterAnswer)
            case .segmentationAmbiguous(let options):
                return .segmentationAmbiguity(
                    options: options,
                    playAfterAnswer: playAfterAnswer)
            case .tooMany(let limit):
                return .tooManyPeople(limit: limit)
            case .unknown(let typedName):
                return .unknownPerson(
                    typedName: typedName,
                    knownNames: profiles.map(\.name).sorted(),
                    playAfterAnswer: playAfterAnswer)
            }
        }

        let query = NLQueryComposer.infixString(
            for: NLQueryNormalizer.normalize(resolvedSpec))
        guard !query.isEmpty else {
            return .search(
                query: question,
                isCount: false,
                preface: literalFallbackPreface,
                playAfterAnswer: playAfterAnswer)
        }
        return .search(
            query: query,
            isCount: resolvedSpec.intent?.lowercased() == "count",
            preface: nil,
            playAfterAnswer: playAfterAnswer)
    }
}

/// Single-owner transfer for the mutable play latch. Any branch that pauses
/// for clarification must take the intent out of view state immediately and
/// carry the returned value in its continuation action.
enum ArchivistPlayIntentPolicy {
    static func take(from pending: inout Bool) -> Bool {
        let captured = pending
        pending = false
        return captured
    }
}
