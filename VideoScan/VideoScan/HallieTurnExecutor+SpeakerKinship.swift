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
                treeIdentity: $0.treeIdentity)
        }, graph: context.graph)
    }

    enum SpeakerKinship {

        struct Rebinding: Equatable, Sendable {
            var people: [String]
            var notes: [String] = []
            /// A decline Hallie should give instead of searching.
            var failure: String?
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

        /// Which people-list slot holds the relative: a bare pronoun, the
        /// phrase, the kin word, or the owner's name. nil ⇒ append.
        private static func slotIndex(in people: [String], phrase: String, speakers: Speakers) -> Int? {
            let kinWord = phrase.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
            return people.firstIndex { entry in
                let key = entry.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                return HallieTurnExecutor.isSpeakerPronoun(key)
                    || key == phrase || key == kinWord
                    || key == speakers.ownerName?.lowercased()
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
            namesSamePerson: (String) -> Bool
        ) -> [String] {
            var people = people
            let target = slot ?? people.firstIndex(where: namesSamePerson)
            if let target { people[target] = name } else { people.append(name) }
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
                        result.people = bind(
                            people, name: hit.member.name,
                            slot: slotIndex(in: people, phrase: phrase, speakers: speakers),
                            namesSamePerson: { entry in
                                PersonResolver.normalize(entry)
                                    == PersonResolver.normalize(hit.member.name)
                                    || overlay.nodes(claiming: entry, ownerName: owner)
                                        .contains(hit.member.node)
                            })
                        result.notes.append("'\(phrase)' = \(hit.member.displayName), \(relation.rawValue) of \(owner) in the People tab relationships")
                        return result
                    }
                }
            }
            // Which slot did the translator give the relative? A bare
            // pronoun ("me"), the phrase itself, the kin word, or — when the
            // model dropped it — nothing, in which case the relative is added.
            let kinWord = phrase.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
            let slot = slotIndex(in: people, phrase: phrase, speakers: speakers)
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
