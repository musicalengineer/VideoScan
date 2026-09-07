// HallieTurnExecutor+SpeakerKinship.swift
// "show me videos of my dad" (Rick 2026-08-21 eval: this came back as
// "I don't have any videos tagged with me yet").
//
// The translator cannot know who "my dad" is, and it tends to collapse the
// phrase to the speaker ("me"). Hallie can know: the archivist settings say
// who is typing (Speakers.ownerName) and the family tree says who that
// person's father is. So, for a presence/cross search, a first-person
// kinship phrase in the ORIGINAL question is resolved here, deterministically,
// and the binding is written into the basis line ("'my dad' = Richard
// Harding Breen Sr, father of Rick Breen in the family tree"). When the tree
// cannot say, Hallie declines by NAME — "the family tree doesn't list a
// father for Rick Breen" — never with a shrug.

import Foundation
import VideoScanCore

extension HallieTurnExecutor {

    /// The People-tab relationship overlay for this turn's context (nil when
    /// no profile carries a row — cheap to build otherwise).
    static func kinshipOverlay(context: Context) -> FamilyKinshipOverlay? {
        let profiles = context.profiles ?? []
        guard profiles.contains(where: { !$0.kinships.isEmpty }) else { return nil }
        return FamilyKinshipOverlay(snapshots: profiles.map {
            ArchivistGraphProfileSnapshot(
                stableID: $0.stableID, canonicalName: $0.canonicalName, aliases: $0.aliases,
                kinships: $0.kinships, sex: $0.sex, birthdate: $0.birthdate,
                deathdate: $0.deathdate, uuid: $0.uuid,
                treeIdentity: $0.treeIdentity,
                // The name fields have to be here, not only on the
                // POIProfile bridge (2026-09-06). This is the builder the
                // LIVE turn uses, and without them `fullNameByNode` is empty
                // at runtime, so `unambiguousName` finds nothing fuller to
                // reach for and B7 goes on binding the contested given name.
                // Every unit test passed because each one built its overlay
                // directly, with the fields — the production route was the
                // one path nothing covered. Hence the test below.
                surname: $0.surname, maidenName: $0.maidenName,
                middleName: $0.middleName, suffix: $0.suffix)
        }, graph: context.graph)
    }

    enum SpeakerKinship {

        struct Rebinding: Equatable, Sendable {
            var people: [String]
            var notes: [String] = []
            /// A decline Hallie should give instead of searching.
            var failure: String?
            /// The kinship phrase and its kin word once they have been SPENT
            /// on resolving a person ("my dad" → Richard Breen Sr). B5,
            /// 2026-09-06: the translator emits `person=my dad keyword=dad`,
            /// and the kin word survived into the content search, so "show me
            /// videos of my dad" became "videos of Richard with 'dad'" and
            /// found nothing — the right person AND'd with a word that
            /// appears in no filename, transcript or caption. A term that has
            /// been turned into an identity is not also a thing to search for.
            /// nil when no kinship phrase was resolved.
            var consumedKinPhrase: (phrase: String, word: String)?

            static func == (lhs: Rebinding, rhs: Rebinding) -> Bool {
                lhs.people == rhs.people && lhs.notes == rhs.notes
                    && lhs.failure == rhs.failure
                    && lhs.consumedKinPhrase?.phrase == rhs.consumedKinPhrase?.phrase
                    && lhs.consumedKinPhrase?.word == rhs.consumedKinPhrase?.word
            }

            /// Does `keyword` name the relationship this rebinding already
            /// spent? Compared on the same normalization the keyword matcher
            /// uses, so "Dad" and "dad" are one term.
            func spentKeyword(_ keyword: String) -> Bool {
                guard let consumed = consumedKinPhrase else { return false }
                let key = ArchivistKeywordText.normalizedPhrase(keyword)
                return key == ArchivistKeywordText.normalizedPhrase(consumed.word)
                    || key == ArchivistKeywordText.normalizedPhrase(consumed.phrase)
            }
        }

        private static let kinWords: [String: GedcomFamilyGraph.Relation] = [
            "dad": .father, "daddy": .father, "father": .father, "pop": .father, "papa": .father,
            "mom": .mother, "mommy": .mother, "mother": .mother, "mum": .mother, "mama": .mother, "ma": .mother,
            "brother": .brother, "sister": .sister,
            "husband": .husband, "wife": .wife,
            "son": .son, "daughter": .daughter,
        ]

        /// The kinship phrase in the question, if any: ("my dad", .father).
        static func kinshipPhrase(in question: String) -> (phrase: String, relation: GedcomFamilyGraph.Relation)? {
            let lowered = question.lowercased().replacingOccurrences(of: "’", with: "'")
            let pattern = #"\b(my|our)\s+(dad|daddy|father|pop|papa|mom|mommy|mother|mum|mama|ma|brother|sister|husband|wife|son|daughter)\b"#
            guard let range = lowered.range(of: pattern, options: .regularExpression) else { return nil }
            let phrase = String(lowered[range])
            let word = phrase.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
            guard let relation = kinWords[word] else { return nil }
            return (phrase, relation)
        }

        /// The kin word inside a phrase: "my dad" → "dad".
        static func kinWord(of phrase: String) -> String {
            phrase.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        }

        /// Did the QUESTION ask for `entry` as a second subject beside the
        /// kinship phrase, rather than merely mentioning them?
        ///
        /// "videos of my dad and Rick" asks for two people. "tell me about my
        /// dad" asks for one, and its "me" is grammar, not a subject. The
        /// difference that survives normalization is the conjunction sitting
        /// between the two, in either order — so that is what is tested, on
        /// word boundaries, because "me" must not be found inside "some".
        static func requestedAlongside(_ entry: String, phrase: String, in question: String) -> Bool {
            // Sentence punctuation is separated, not just commas (codex
            // #1163): "my dad and Rick?" and "my dad and me." both ended the
            // padded haystack with "rick?" / "me." and failed the
            // trailing-space requirement, so an ordinary question mark
            // silently turned the preservation off.
            var text = question.lowercased().replacingOccurrences(of: "&", with: " and ")
            for mark in [",", ".", "?", "!", ";", ":", "\"", "'"] {
                text = text.replacingOccurrences(of: mark, with: " ")
            }
            text = " " + text + " "
            let squeezed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let entryWords = entry.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let phraseWords = phrase.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !entryWords.isEmpty, !phraseWords.isEmpty else { return false }
            let padded = " " + squeezed + " "
            return padded.contains(" \(phraseWords) and \(entryWords) ")
                || padded.contains(" \(entryWords) and \(phraseWords) ")
        }

        /// Which people-list slot holds the relative: a bare pronoun, the
        /// phrase, the kin word, or the owner's name. nil ⇒ append.
        private static func slotIndex(in people: [String], phrase: String,
                                      question: String, speakers: Speakers) -> Int? {
            let kinWord = phrase.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
            func key(_ entry: String) -> String {
                entry.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // THE PHRASE WINS THE SLOT (codex #1163). A single firstIndex over
            // all four shapes handed the slot to whichever came FIRST in the
            // list, so people = ["Rick", "my dad"] for "videos of Rick and my
            // dad" overwrote Rick with the resolved father — before the
            // preservation filter in bind() ever ran. The relative's own slot
            // is looked for first; an owner or pronoun placeholder is only a
            // fallback, and never one the question asked for by itself.
            if let exact = people.firstIndex(where: { key($0) == phrase || key($0) == kinWord }) {
                return exact
            }
            return people.firstIndex { entry in
                let key = key(entry)
                guard HallieTurnExecutor.isSpeakerPronoun(key)
                        || key == speakers.ownerName?.lowercased() else { return false }
                return !requestedAlongside(key, phrase: phrase, in: question)
            }
        }

        /// Put the resolved relative into the people list EXACTLY ONCE.
        ///
        /// The translator usually leaves the relative's own name in the
        /// list — "find videos of my brother tim" arrives as people
        /// ["tim"] — while the kinship binding produces the canonical
        /// spelling "Tim". `slotIndex` only recognises a pronoun, the
        /// phrase, the kin word or the owner's name, so a typed given name
        /// found no slot and the canonical spelling was APPENDED: two
        /// person terms for one person, which the presence decline then
        /// said out loud — "I don't have any videos tagged with tim and
        /// Tim yet" (demo eval lv260902-004, 2026-09-03).
        ///
        /// The canonical spelling replaces any entry that already names the
        /// same person, and the result is deduped case-insensitively so no
        /// later renderer can say one name in two casings.
        private static func bind(
            _ people: [String],
            name: String,
            slot: Int?,
            phrase: String,
            question: String,
            speakers: Speakers,
            namesSamePerson: (String) -> Bool
        ) -> [String] {
            var people = people
            let target = slot ?? people.firstIndex(where: namesSamePerson)
            if let target { people[target] = name } else { people.append(name) }
            // Every OTHER entry that named the same relative goes too
            // (2026-09-06). The translator emits the phrase and the bare kin
            // word often enough that Rick hit it on his first evening
            // question: for "tell me about my dad" it produced
            // `people = ["my dad", "dad"]`, slot 0 became "Richard Breen Sr",
            // and "dad" rode along — `person=Richard Breen Sr,dad`. The
            // graph route cannot choose between two people, so it declined
            // with a question in PROSE and, because it was a decline rather
            // than a clarification, registered no pending question. Rick
            // answered "Richard Breen Sr" into the void and the refinement
            // path took his reply as a new search term.
            //
            // One relative resolved once means one entry. Compared on the
            // same normalization `slotIndex` uses, so "Dad", "my dad" and
            // "MY DAD" are all the one we just spent.
            //
            // THE SWEEP IS NOT UNIFORM (codex #1156, 2026-09-07). The first
            // version removed every remaining owner-name and pronoun entry as
            // well, which is right for "tell me about my dad" — where "me" is
            // an artifact of "tell me" — and wrong the moment the question
            // asks for two people: "videos of my dad and Rick" with Rick as
            // the owner bound "my dad" and then DELETED the independently
            // requested Rick. Same for "my dad and me".
            //
            // The phrase and the bare kin word are always the person just
            // resolved, so they always go. The owner and the speaker pronouns
            // go only when the question did not ask for them ALONGSIDE the
            // relative.
            let kin = kinWord(of: phrase)
            people = people.enumerated().filter { index, entry in
                if index == target { return true }
                let key = entry.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if key == phrase || key == kin { return false }
                if HallieTurnExecutor.isSpeakerPronoun(key)
                    || key == speakers.ownerName?.lowercased() {
                    return requestedAlongside(key, phrase: phrase, in: question)
                }
                return true
            }.map(\.element)
            if !people.contains(name) { people.append(name) }
            return PersonNameClaim.dedupe(people)
        }

        /// Rebind the people list when the question names a relative of the
        /// speaker. Untouched (no notes, no failure) when it does not.
        static func rebind(
            people: [String],
            question: String,
            speakers: Speakers,
            graph: GedcomFamilyGraph?,
            cyberBrain: CyberBrainIndex? = nil,
            kinshipOverlay: FamilyKinshipOverlay? = nil
        ) -> Rebinding {
            var result = Rebinding(people: people)
            guard let (phrase, relation) = kinshipPhrase(in: question) else { return result }
            // People-tab relationships first (codex #778): "my dad" with the
            // owner's profile carrying "child of Dad" resolves through that
            // typed row — never through a stray "Dad" alias. One relative →
            // bound; several → ask; none → the tree below gets its turn.
            if let overlay = kinshipOverlay, !overlay.isEmpty, let owner = speakers.ownerName,
               let wanted = KinshipRelation.parse(term: relation.rawValue) {
                let owners = overlay.nodes(claiming: owner, ownerName: owner)
                if owners.count == 1 {
                    let relatives = overlay.relatives(of: owners[0], relation: wanted.relation, sex: wanted.sex)
                    if relatives.count > 1 {
                        result.failure = "The People tab lists more than one \(relation.rawValue) for \(owner): "
                            + relatives.map(\.member.displayName).joined(separator: ", ") + ". Which one do you mean?"
                        return result
                    }
                    if let hit = relatives.first {
                        // B7, 2026-09-06: bind the UNAMBIGUOUS spelling.
                        // Binding `hit.member.name` threw the resolution
                        // away — since Rick adopted surnames on 2026-09-04,
                        // his father's canonical name is "Richard" and Rick's
                        // own alias is "Richard" too, so downstream the graph
                        // route re-resolved that bare given name against the
                        // GEDCOM and answered with Richard Harding Breen JR.
                        // Live 2026-09-05: "when was my dad born" → "Richard
                        // Harding Breen Jr was born 4 March 1959" — Rick's
                        // birthday, given confidently as his father's. The
                        // full name ("Richard Breen Sr") names one person and
                        // resolves back to the same profile, because the
                        // overlay's resolver now indexes full-name forms.
                        let bound = overlay.unambiguousName(of: hit.member)
                        result.people = bind(
                            people, name: bound,
                            slot: slotIndex(in: people, phrase: phrase,
                                                            question: question, speakers: speakers),
                            phrase: phrase, question: question, speakers: speakers,
                            namesSamePerson: { entry in
                                PersonResolver.normalize(entry)
                                    == PersonResolver.normalize(hit.member.name)
                                    || PersonResolver.normalize(entry)
                                        == PersonResolver.normalize(bound)
                                    || overlay.nodes(claiming: entry, ownerName: owner)
                                        .contains(hit.member.node)
                            })
                        result.consumedKinPhrase = (phrase: phrase, word: kinWord(of: phrase))
                        result.notes.append("'\(phrase)' = \(hit.member.displayName), \(relation.rawValue) of \(owner) in the People tab relationships")
                        return result
                    }
                }
            }
            // Which slot did the translator give the relative? A bare
            // pronoun ("me"), the phrase itself, the kin word, or — when the
            // model dropped it — nothing, in which case the relative is added.
            let kinWord = phrase.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
            let slot = slotIndex(in: people, phrase: phrase, question: question, speakers: speakers)
            guard let owner = speakers.ownerName else {
                result.failure = "I don't know who “\(phrase)” is because no one has told me who is using the archive — set your name in Hallie's settings and I'll look \(kinWord == "dad" || kinWord == "father" ? "him" : "them") up in the family tree."
                return result
            }
            guard let graph else {
                result.failure = "I can't work out who “\(phrase)” is without the family tree, and no family tree is loaded."
                return result
            }
            // The owner's configured name ("Rick Breen") is usually a
            // CyberBrain alias whose GEDCOM pointer names the tree person
            // ("Richard Harding Breen Jr"); fall back to the tree's own
            // name match.
            var owners: [GedcomFamilyGraph.Person] = []
            if let pinned = graph.person(familySearchID: speakers.ownerFamilySearchID) {
                owners = [pinned]
                result.notes.append("“you” = \(pinned.name) (FamilySearch ID \(pinned.familySearchID ?? ""))")
            } else if let stale = HallieOwnerResolver.stalePinLine(
                        familySearchID: speakers.ownerFamilySearchID, graph: graph) {
                // Explicit pin, not in the tree: fail closed (codex #707).
                result.failure = stale + " So I can't work out who “\(phrase)” is."
                return result
            } else if let cyberBrain, case .resolved(let person) = cyberBrain.resolve(owner),
               let gedcomID = person.gedcomPersonID, let treePerson = graph.people[gedcomID] {
                owners = [treePerson]
            } else {
                owners = graph.people(matching: owner)
                if owners.count != 1 {
                    // The shared owner chain (2026-08-26): diminutive/suffix
                    // tolerant, tree root as tie-breaker — the same rule the
                    // lineage and kinship routes apply to "me".
                    switch HallieOwnerResolver.resolve(
                        owner, graph: graph, familySearchID: speakers.ownerFamilySearchID) {
                    case .one(let person, let note):
                        owners = [person]
                        result.notes.append(note.replacingOccurrences(of: "Basis: ", with: ""))
                    case .many(let people):
                        owners = people
                    case .none(let reason):
                        owners = []
                        if let reason { result.notes.append(reason) }
                    }
                }
            }
            guard owners.count == 1 else {
                result.failure = owners.isEmpty
                    ? "I don't find you (\(owner)) in the family tree, so I can't work out who “\(phrase)” is."
                    : "More than one person in the family tree matches your name (\(owner)), so I can't work out who “\(phrase)” is."
                return result
            }
            let relatives = graph.relatives(relation, of: owners[0])
            guard !relatives.isEmpty else {
                result.failure = "The family tree doesn't list a \(relation.rawValue) for \(owners[0].name), so I can't work out who “\(phrase)” is. If you tell me — “let me tell you about \(phrase)” — I'll remember."
                return result
            }
            guard relatives.count == 1 else {
                let names = relatives.map(\.name).joined(separator: ", ")
                result.failure = "The family tree lists more than one \(relation.rawValue) for \(owners[0].name): \(names). Which one do you mean?"
                return result
            }
            let relative = relatives[0]
            result.people = bind(
                people, name: relative.name, slot: slot,
                phrase: phrase, question: question, speakers: speakers,
                namesSamePerson: { entry in
                    PersonResolver.normalize(entry)
                        == PersonResolver.normalize(relative.name)
                        || graph.people(matching: entry)
                            .contains { $0.id == relative.id }
                })
            result.notes.append("'\(phrase)' = \(relative.name), \(relation.rawValue) of \(owners[0].name) in the family tree")
            return result
        }
    }
}
