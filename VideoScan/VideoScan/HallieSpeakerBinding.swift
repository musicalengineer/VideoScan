// HallieSpeakerBinding.swift
// Who "I" and "you" are when someone talks to Hallie Mae.
//
// Rick (Hallie log 2026-08-18): "how am I related to you?" and "how am I
// related to you hallie?" both failed. Besides the missing relationship
// operation, nothing bound the pronouns: the translator handed the executor
// the literal word "you" and the executor tried to find a person named
// "you" in the family tree. This file makes the binding deterministic and
// visible — the LLM never decides who "I" is:
//
//   I / me / my / mine / myself      → the app's owner (the person typing;
//                                      `archivist.ownerPersonName`, default
//                                      "Rick Breen")
//   you / your / yours / yourself /
//   hallie / hallie mae / <her name> → the archivist herself
//                                      (`archivist.name`, default "Hallie
//                                      Mae"; optionally pinned to an exact
//                                      family-tree spelling with
//                                      `archivist.personName`)
//
// The binding is recorded in the turn's Intent and echoed in the basis line
// ("'you' = Hallie Mae; 'I' = Rick Breen") so a wrong assumption is visible.

import Foundation

extension HallieTurnExecutor {

    /// The two speakers a conversation has, by the names the settings give
    /// them. Both optional: an empty owner name means "I" cannot be bound
    /// and the executor says so instead of guessing.
    struct Speakers: Sendable, Equatable {
        /// The person using the app ("I").
        let ownerName: String?
        /// The archivist's display name ("you"), e.g. "Hallie Mae".
        let archivistName: String?
        /// Optional exact family-tree spelling for the archivist ("Hallie
        /// May McGill") when the display name does not token-match her
        /// GEDCOM record. Empty → derived from `archivistName`.
        let archivistPersonName: String?
        /// The owner's FamilySearch person ID ("GVQV-NW3"), when set. The
        /// GEDCOM carries it as `1 _FSFTID`, so it pins "me" to one record
        /// ahead of any name matching (2026-08-26). Empty → nil.
        let ownerFamilySearchID: String?

        static let none = Speakers(ownerName: nil, archivistName: nil,
                                   archivistPersonName: nil)

        init(ownerName: String?, archivistName: String?,
             archivistPersonName: String? = nil,
             ownerFamilySearchID: String? = nil) {
            self.ownerName = Self.clean(ownerName)
            self.archivistName = Self.clean(archivistName)
            self.archivistPersonName = Self.clean(archivistPersonName)
            self.ownerFamilySearchID = Self.clean(ownerFamilySearchID)?.uppercased()
        }

        /// The persisted `archivist.*` settings, same keys the chat window's
        /// `@AppStorage` properties use.
        static let ownerDefaultsKey = "archivist.ownerPersonName"
        static let archivistNameDefaultsKey = "archivist.name"
        static let archivistPersonNameDefaultsKey = "archivist.personName"
        /// `hallie.ownerFamilySearchID` — set from the speaker settings
        /// sheet or `defaults write Rick-Breen.VideoScan
        /// hallie.ownerFamilySearchID GVQV-NW3`. Default empty.
        static let ownerFamilySearchIDDefaultsKey = "hallie.ownerFamilySearchID"
        static let defaultOwnerName = "Rick Breen"
        static let defaultArchivistName = "Hallie Mae"

        static func fromDefaults(_ defaults: UserDefaults = .standard) -> Speakers {
            let owner = defaults.string(forKey: ownerDefaultsKey) ?? defaultOwnerName
            let archivist = defaults.string(forKey: archivistNameDefaultsKey)
                ?? defaultArchivistName
            return Speakers(
                ownerName: owner,
                archivistName: archivist == "Name TBD" ? defaultArchivistName : archivist,
                archivistPersonName: defaults.string(forKey: archivistPersonNameDefaultsKey),
                ownerFamilySearchID: defaults.string(forKey: ownerFamilySearchIDDefaultsKey))
        }

        /// The spellings to try, most specific first, when resolving the
        /// archivist to a family-tree person. The display name may be a
        /// nickname or a variant spelling ("Hallie Mae" vs. the tree's
        /// "Hallie May McGill"), so the ladder ends with her first name alone
        /// — accepted only if it names exactly one person (checked by the
        /// caller). Deterministic; every rung is echoed in the basis line.
        var archivistNameLadder: [String] {
            var rungs: [String] = []
            for candidate in [archivistPersonName, archivistName] {
                if let candidate, !rungs.contains(candidate) { rungs.append(candidate) }
            }
            if let archivistName,
               let first = archivistName.split(whereSeparator: \.isWhitespace).first,
               first.count > 1 {
                let firstName = String(first)
                if !rungs.contains(firstName) { rungs.append(firstName) }
            }
            return rungs
        }

        private static func clean(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    enum SpeakerRole: String, Sendable, Equatable {
        /// The person using the app — Hallie says "you"/"your".
        case owner
        /// The archivist herself — Hallie says "I"/"my".
        case archivist
    }

    /// One pronoun bound for one turn: which people-list slot, what the user
    /// wrote, who it became. Lives on the Intent so clarifications and
    /// continuations keep the same reading.
    struct SpeakerBinding: Sendable, Equatable {
        let index: Int
        let pronoun: String
        let role: SpeakerRole
        /// The speaker's configured name ("Hallie Mae", "Rick Breen").
        let boundName: String
        /// The spelling actually placed in the people list when the family
        /// tree knows the archivist under a different one ("Hallie" for a
        /// tree that has "Hallie May McGill"); nil when identical.
        let treeSpelling: String?

        init(index: Int, pronoun: String, role: SpeakerRole,
             boundName: String, treeSpelling: String? = nil) {
            self.index = index
            self.pronoun = pronoun
            self.role = role
            self.boundName = boundName
            self.treeSpelling = treeSpelling == boundName ? nil : treeSpelling
        }

        /// What goes into the people list.
        var effectiveName: String { treeSpelling ?? boundName }

        var note: String {
            var text = "'\(pronoun)' = \(boundName)"
            if let treeSpelling { text += " (as “\(treeSpelling)” in the family tree)" }
            return text
        }
    }

    /// Words that mean the person typing.
    static let firstPersonPronouns: Set<String> = [
        "i", "me", "my", "mine", "myself",
    ]

    /// Words that mean the archivist. Her display name (and its first word)
    /// is added at binding time.
    static let secondPersonPronouns: Set<String> = [
        "you", "your", "yours", "yourself", "hallie", "hallie mae",
        "the archivist", "archivist",
    ]

    /// True when a people-list entry is a pronoun the executor will bind.
    /// The translator's list normalizer consults this so "you"/"me" survive
    /// the stopword filter (both ARE stopwords for keyword search).
    static func isSpeakerPronoun(_ value: String) -> Bool {
        let key = pronounKey(value)
        return firstPersonPronouns.contains(key) || secondPersonPronouns.contains(key)
    }

    struct PronounBindingResult: Equatable {
        /// The people list with pronouns replaced by names.
        let people: [String]
        let bindings: [SpeakerBinding]
        /// Pronouns that could not be bound because the speaker's name is
        /// not configured (never silently dropped).
        let unbound: [String]
    }

    /// Replace pronouns in a graph people list with the speakers' names.
    /// Pure and deterministic: same input, same binding, every time.
    /// `isKnownPerson` (optional) lets the archivist's name ladder pick the
    /// spelling the family tree actually knows ("Hallie Mae" → "Hallie");
    /// without it her display name is used as-is.
    static func bindPronouns(
        _ people: [String],
        speakers: Speakers,
        isKnownPerson: ((String) -> Bool)? = nil
    ) -> PronounBindingResult {
        var archivistWords = secondPersonPronouns
        if let name = speakers.archivistName {
            archivistWords.insert(pronounKey(name))
            if let first = name.split(whereSeparator: \.isWhitespace).first, first.count > 1 {
                archivistWords.insert(pronounKey(String(first)))
            }
        }
        var bound: [String] = []
        var bindings: [SpeakerBinding] = []
        var unbound: [String] = []
        for (index, raw) in people.enumerated() {
            let key = pronounKey(raw)
            if firstPersonPronouns.contains(key) {
                if let owner = speakers.ownerName {
                    bound.append(owner)
                    bindings.append(SpeakerBinding(
                        index: index, pronoun: raw, role: .owner, boundName: owner))
                } else {
                    bound.append(raw)
                    unbound.append(raw)
                }
            } else if archivistWords.contains(key) {
                // The archivist resolves through her name ladder later; the
                // people slot carries the display name so the query line
                // reads naturally ("person=Hallie Mae").
                if let archivist = speakers.archivistName ?? speakers.archivistPersonName {
                    let ladder = speakers.archivistNameLadder
                    let spelling = isKnownPerson.flatMap { known in
                        ladder.first(where: known)
                    } ?? archivist
                    bound.append(spelling)
                    bindings.append(SpeakerBinding(
                        index: index, pronoun: raw, role: .archivist,
                        boundName: archivist, treeSpelling: spelling))
                } else {
                    bound.append(raw)
                    unbound.append(raw)
                }
            } else {
                bound.append(raw)
            }
        }
        return PronounBindingResult(people: bound, bindings: bindings, unbound: unbound)
    }

    /// The one-line note for the basis: "'you' = Hallie Mae; 'I' = Rick Breen".
    static func bindingNote(_ bindings: [SpeakerBinding]) -> String? {
        guard !bindings.isEmpty else { return nil }
        return bindings.map(\.note).joined(separator: "; ")
    }

    private static func pronounKey(_ value: String) -> String {
        var key = value.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = key.last, "?!.,".contains(last) { key.removeLast() }
        // "you," "yourself" etc. are already words; strip a possessive that a
        // model sometimes leaves on ("your's").
        if key.hasSuffix("'s") { key.removeLast(2) }
        return key.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
