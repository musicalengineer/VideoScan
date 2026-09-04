// HallieBiographyCard.swift
// ONE biography fact plan for a family-tree person (live 2026-08-29).
//
// "tell me about Matthew Rice" (graph operation .biography) and "show
// Matthew Rice's family tree" (.familyTree) used to draw from two different
// templates: ArchivistBiographyPolicy (dates, parents, spouse, children —
// no places, no marriage date, no depth) and ArchivistFamilyTreePolicy
// (parents, spouse, children, depth counts — no dates at all). Each was a
// single semicolon-joined sentence, so HallieAnswerPlan.derive handed the
// composer ONE claim and the model was free to phrase two sentences and
// drop the marriage and children. Same person, two different cards.
//
// This type builds the fact set once, one claim per sentence, each cited
// to the GEDCOM pointers it rests on, and both operations use it. Nothing
// here is invented: a missing half is simply absent, a missing death date
// is never "living", dates keep their recorded qualifier (before / after /
// about / between …) and their recorded precision (day and month when the
// record has them). CyberBrain and People-tab facts are layered on top
// exactly as before (FamilyKnowledgeSupplement, +PeopleTab).
//
// Two additions (live miss #16, 2026-08-29, "tell me about rick's family
// tree, his brothers, sisters, parents, and grandparents"):
//   • CROSS-WORLD KIN — when the subject bridges to a People-tab profile
//     (a tree pin, a certain derivation assumed for the turn, or the
//     name-route bridge), the card adds the People-tab relatives the tree
//     lacks: siblings always (FamilySearch strips the living), children
//     and spouse only when the tree records none. Each such sentence says
//     "In the People tab:" and cites the profile rows it came from.
//   • DATA-QUALITY FLAG — a person with more than one recorded mother or
//     father (Eileen Latta: two FAMC lines, Mary Catherine O'Connor AND
//     Mary O'Connor) gets one honest sentence naming both records with
//     their FamilySearch IDs, so the duplicate can be merged upstream.
//
// C++ readers: a pure static factory over immutable inputs; the result is a
// value type holding the sentences and their citations. No I/O, no model.

import Foundation
import VideoScanCore

enum HallieBiographyCard {

    /// The card: sentences in the archivist's order, each with the GEDCOM
    /// pointers behind it. `prose` is the deterministic fallback; `plan`
    /// is what a composing model may re-phrase (verifier drops the rest).
    struct Card: Sendable, Equatable {
        struct Sentence: Sendable, Equatable {
            let text: String
            let evidenceIDs: [String]
            /// People this sentence promises to name. Evidence may contain
            /// additional people whose records only support the sentence;
            /// those are intentionally not included here.
            let requiredPersonNames: [String]

            init(text: String, evidenceIDs: [String],
                 requiredPersonNames: [String] = []) {
                self.text = text
                self.evidenceIDs = evidenceIDs
                self.requiredPersonNames = requiredPersonNames
            }
        }
        let subject: GedcomFamilyGraph.Person
        let sentences: [Sentence]
        /// People-tab profiles whose relationship rows the card used
        /// (canonical names, sorted); empty when no People-tab sentence
        /// was added. The executor cites them in the basis line.
        let peopleTabStoredOn: [String]
        /// Duplicate-parent flags the card stated (subject first, then
        /// each parent), for the "Show possible duplicate" chip.
        let dataQualityFlags: [DataQualityFlag]
        /// Living or passed on (LifeStatus, 2026-09-01): decided the tense
        /// of every sentence above and is handed to the composer so the
        /// model's phrasing keeps it.
        let lifeStatus: LifeStatus
        /// People-tab relatives the card named that rest on a read-time
        /// inference rather than a stored row (2026-09-02, "full siblings
        /// share parents"), grouped under the overlay's derivation note.
        /// The basis line states them; the prose stays plain.
        var peopleTabDerived: [DerivedNote] = []
        /// Derivation conflicts involving the subject (see
        /// `PeopleTabKin.warnings`); the basis line states them.
        var peopleTabWarnings: [String] = []

        struct DerivedNote: Sendable, Equatable {
            /// "derived from Rick's rows: full siblings share parents".
            let note: String
            /// People-tab names, in the order the sentence listed them.
            let names: [String]
        }

        var prose: String { sentences.map(\.text).joined(separator: " ") }

        var plan: HallieAnswerPlan {
            HallieAnswerPlan(
                route: .graph,
                shape: .biography,
                subject: subject.name,
                claims: sentences.enumerated().map { index, sentence in
                    HallieAnswerPlan.Claim(
                        id: "c\(index + 1)", text: sentence.text,
                        evidenceIDs: sentence.evidenceIDs,
                        requiredPersonNames: (index == 0 ? [subject.name] : [])
                            + sentence.requiredPersonNames,
                        requiresCoverage: true)
                },
                fallbackText: prose,
                subjectLifeStatus: lifeStatus)
        }
    }

    /// People-tab relatives of the subject, resolved by the executor from
    /// the kinship overlay (one hop — a stored row, or a parent/child edge
    /// the overlay derived from sibling rows; never a composed route).
    /// Names are the profiles' canonical names ("Tim"), terms the
    /// relation word for that person's sex ("brother").
    struct PeopleTabKin: Sendable, Equatable {
        struct Relative: Sendable, Equatable {
            let name: String
            let term: String
            /// Durable identity for the citation ("uuid:…", or the
            /// profile's audit id when the profile carries no UUID).
            let evidenceID: String
            /// The tree record this relative is itself bridged to, so a
            /// relative the tree already lists is not said twice.
            let gedcomID: String?
            /// The overlay's derivation note when this relative is an
            /// inference ("derived from Rick's rows: full siblings share
            /// parents"); nil for a stored row.
            var derivation: String? = nil

            init(name: String, term: String, evidenceID: String, gedcomID: String?,
                 derivation: String? = nil) {
                self.name = name
                self.term = term
                self.evidenceID = evidenceID
                self.gedcomID = gedcomID
                self.derivation = derivation
            }
        }
        /// The subject's own People-tab canonical name ("Rick").
        let profileName: String
        /// That profile's stable id, so a caller that holds the People-tab
        /// profiles (the turn executor) can find the SAME profile again —
        /// today to quote its free-text note. Empty for legacy callers that
        /// never had one. Notes themselves deliberately never enter graph
        /// execution (see ArchivistGraphProfileSnapshot).
        var profileStableID: String = ""
        let siblings: [Relative]
        let children: [Relative]
        let spouses: [Relative]
        /// Profiles whose rows produced the relatives above.
        let storedOn: [String]

        /// Derivation conflicts the subject's sibling set is part of (the
        /// overlay failed closed — nothing derived for it); stated in the
        /// basis so a silent gap is never mistaken for "no siblings".
        var warnings: [String] = []

        init(profileName: String, profileStableID: String = "",
             siblings: [Relative] = [], children: [Relative] = [],
             spouses: [Relative] = [], storedOn: [String] = [], warnings: [String] = []) {
            self.profileName = profileName
            self.profileStableID = profileStableID
            self.siblings = siblings
            self.children = children
            self.spouses = spouses
            self.storedOn = storedOn
            self.warnings = warnings
        }
    }

    /// A second recorded parent family for one person (Rick's 2026-09-02
    /// ruling: the PRIMARY family's parents are the ones prose names —
    /// GedcomFamilyGraph+ParentFamily — so this never reaches a sentence).
    /// It survives as the BASIS note and as the "Show possible duplicate"
    /// chip: either a FamilySearch duplicate folded into the primary
    /// parent ("Mary Catherine O'Connor" / "Mary O'Connor", same parents)
    /// or a genuine second family the reader can ask about by name.
    struct DataQualityFlag: Sendable, Equatable {
        let child: GedcomFamilyGraph.Person
        /// "mothers" / "fathers" / "parents" — which role(s) carry a
        /// non-primary record.
        let role: String
        /// The primary parent(s) first, then the non-primary record(s).
        let parents: [GedcomFamilyGraph.Person]
        /// Every non-primary record folds into its primary parent (the
        /// duplicate reading); false when a genuine second family exists.
        let looksLikeDuplicate: Bool
        /// The graph's one short basis note for this child.
        let note: String

        var evidenceIDs: [String] { [child.id] + parents.map(\.id) }

        /// The basis wording — what the card used to say in prose.
        var text: String { note }
    }

    /// Names listed by name before "and N more" (the children sentence).
    static let maxListedNames = 12

    // MARK: - Build

    /// `lifeStatus` nil ⇒ decided from the tree record and the family around
    /// it (LifeStatus.of); the executor passes the People-tab verdict when
    /// the subject is a profile, whose recorded death the tree may lack.
    ///
    /// `profileBirthdate`/`profileDeathdate` (HallieVitalDates, 2026-09-04 —
    /// Rick's ruling: for a person who has a People profile, the profile's
    /// date is the true one and the tree's is wrong): the owning profile's
    /// date, which REPLACES the tree's own recorded date for that field.
    /// Nil means the profile holds nothing for that field, and then the
    /// tree's date stands exactly as written. Places, parents, spouses and
    /// every other sentence still come from the tree.
    static func card(for person: GedcomFamilyGraph.Person,
                     in graph: GedcomFamilyGraph,
                     peopleTab: PeopleTabKin? = nil,
                     lifeStatus: LifeStatus? = nil,
                     profileBirthdate: Date? = nil,
                     profileDeathdate: Date? = nil) -> Card {
        let summary = ArchivistFamilyTreePolicy.summary(of: person, in: graph)
        let name = person.name
        let pronoun = Pronoun(sex: person.sex)
        // Tense (Rick, 2026-09-01): a living subject IS the child of, HAS
        // siblings, IS married; the departed keep the past tense exactly as
        // before. A birth is always "was born" (vitalsClause).
        let life = lifeStatus ?? LifeStatus.of(person, in: graph)
        let living = life.isLiving
        var sentences: [Card.Sentence] = []
        var storedOn = Set<String>()
        var derivedOrder: [String] = []
        var derivedNames: [String: [String]] = [:]
        // Verb agreement for the sentence about to be added: the lead names
        // the subject (singular); later sentences use the pronoun, and an
        // unrecorded sex gives "They", which takes the plural verb.
        // (C++: local lambdas reading the enclosing `sentences` by reference.)
        func plural() -> Bool { !sentences.isEmpty && pronoun.subject == "They" }
        func be() -> String { living ? (plural() ? "are" : "is") : (plural() ? "were" : "was") }
        func have() -> String { living ? (plural() ? "have" : "has") : "had" }
        // The first sentence, whichever it is, names the subject in full
        // (HallieAnswerPlan.subjectLeadSentence needs one; the composer's
        // name-first rule rests on it). A subject bridged from a People-tab
        // profile under another name is introduced with both ("Richard
        // Harding Breen Jr (Rick in the People tab)"). Later sentences use
        // the pronoun.
        let leadName: String = {
            guard let profileName = peopleTab?.profileName,
                  FamilyIdentityText.normalized(profileName) != FamilyIdentityText.normalized(name)
            else { return name }
            return "\(name) (\(profileName) in the People tab)"
        }()
        func lead() -> String { sentences.isEmpty ? leadName : pronoun.subject }

        /// The People-tab relatives the tree does not already list, with
        /// their derivation notes registered for the basis line. Call once
        /// per relation — it mutates the derivation bookkeeping.
        func extraPeopleTab(_ relatives: [PeopleTabKin.Relative],
                            treeIDs: Set<String>) -> [PeopleTabKin.Relative] {
            let extra = relatives.filter { $0.gedcomID.map { !treeIDs.contains($0) } ?? true }
            for relative in extra {
                guard let note = relative.derivation else { continue }
                if derivedNames[note] == nil { derivedOrder.append(note) }
                derivedNames[note, default: []].append(relative.name)
            }
            return extra
        }

        /// "In the People tab: Tim — brother, Beth — sister." over relatives
        /// already filtered by `extraPeopleTab`.
        func peopleTabListSentence(_ extra: [PeopleTabKin.Relative]) -> Card.Sentence {
            let listed = extra.map { "\($0.name) — \($0.term)" }
            // Three siblings derived from one card cite that card once.
            var evidence = [person.id]
            for id in extra.map(\.evidenceID) where !evidence.contains(id) { evidence.append(id) }
            return .init(text: "In the People tab: " + joined(listed) + ".",
                         evidenceIDs: evidence,
                         requiredPersonNames: extra.map(\.name))
        }

        /// "In the People tab: Tim — brother, Beth — sister." Nil when the
        /// tree already lists every one of them.
        func peopleTabSentence(_ relatives: [PeopleTabKin.Relative],
                               treeIDs: Set<String>) -> Card.Sentence? {
            let extra = extraPeopleTab(relatives, treeIDs: treeIDs)
            guard !extra.isEmpty else { return nil }
            return peopleTabListSentence(extra)
        }

        // 1. Vitals with places, as recorded.
        if let vitals = vitalsClause(
            person, profileBirthdate: profileBirthdate, profileDeathdate: profileDeathdate) {
            sentences.append(.init(text: "\(leadName) \(vitals).", evidenceIDs: [person.id]))
        }
        // 2. Parents, with grandparents folded in (the family-tree summary
        //    always named them; one claim keeps the sentence budget).
        if !summary.parents.isEmpty {
            var text = "\(lead()) \(be()) the child of \(joinedNames(summary.parents))"
            if !summary.grandparents.isEmpty {
                let plural = summary.grandparents.count > 1
                text += "; \(pronoun.possessive) recorded grandparent\(plural ? "s were" : " was") "
                    + listedNames(summary.grandparents)
            }
            sentences.append(.init(
                text: text + ".",
                evidenceIDs: [person.id] + summary.parents.map(\.id) + summary.grandparents.map(\.id),
                requiredPersonNames: summary.parents.map(\.name)
                    + Array(summary.grandparents.prefix(maxListedNames)).map(\.name)))
        }
        // 2b. Data quality: a second parent family on the subject or on a
        //     parent. Since 2026-09-02 the prose lists the primary family
        //     only; the flag goes to the basis line (dataQualityBasis) and
        //     the "Show possible duplicate" chip, never to a sentence.
        let flags = dataQualityFlags(for: person, in: graph)
        // 3. Siblings — the tree's, then the People tab's (the living are
        //    not on FamilySearch; Tim is a People-tab sibling row).
        if !summary.siblings.isEmpty {
            let n = summary.siblings.count
            sentences.append(.init(
                text: "\(lead()) \(have()) \(n) recorded \(n == 1 ? "sibling" : "siblings"), "
                    + listedNames(summary.siblings) + ".",
                evidenceIDs: [person.id] + summary.siblings.map(\.id),
                requiredPersonNames: Array(summary.siblings.prefix(maxListedNames)).map(\.name)))
        }
        if let peopleTab,
           let extra = peopleTabSentence(peopleTab.siblings, treeIDs: Set(summary.siblings.map(\.id))) {
            if summary.siblings.isEmpty {
                sentences.append(.init(
                    text: "The tree records no siblings for \(sentences.isEmpty ? leadName : pronoun.object).",
                    evidenceIDs: [person.id]))
            }
            sentences.append(extra)
            peopleTab.storedOn.forEach { storedOn.insert($0) }
        }
        // 4. Marriage(s) with the MARR date when the family record has one.
        let marriages = orderedMarriages(graph.marriages(of: person))
        if !marriages.isEmpty,
           let clause = marriageClause(marriages, subjectLiving: living, plural: plural(),
                                       spouseLiving: { LifeStatus.of($0, in: graph).isLiving }) {
            sentences.append(.init(
                text: "\(lead()) \(clause).",
                evidenceIDs: [person.id] + marriages.compactMap(\.spouse?.id),
                requiredPersonNames: marriages.compactMap(\.spouse?.name)))
        } else if let peopleTab, let extra = peopleTabSentence(peopleTab.spouses, treeIDs: []) {
            sentences.append(extra)
            peopleTab.storedOn.forEach { storedOn.insert($0) }
        }
        // 5. Children — ONE sentence that names each source (Rick,
        //    2026-09-04). "He had 1 recorded child, Richard Harding Breen
        //    Jr." stated the TREE's count as the truth, to that man's son,
        //    and the very next sentence named three more children from the
        //    People tab. The archive cannot stand behind ANY total here:
        //    the two sources may overlap, and Michael is in neither. So the
        //    count is attributed to the tree that holds it, the People-tab
        //    names are added as the People tab's, and nothing is summed.
        let treeChildren = summary.children
        let tabChildren = peopleTab.map {
            extraPeopleTab($0.children, treeIDs: Set(treeChildren.map(\.id)))
        } ?? []
        if !treeChildren.isEmpty {
            // The first sentence of a card always names the subject in full;
            // later ones use the pronoun — same rule as the no-siblings line.
            let about = sentences.isEmpty ? leadName : pronoun.object
            let n = treeChildren.count
            var text = "The family tree records \(countWord(n)) "
                + "\(n == 1 ? "child" : "children") for \(about), "
                + listedNames(treeChildren)
            var evidence = [person.id] + treeChildren.map(\.id)
            var required = Array(treeChildren.prefix(maxListedNames)).map(\.name)
            if !tabChildren.isEmpty {
                text += "; the People tab adds " + addedClause(tabChildren)
                for id in tabChildren.map(\.evidenceID) where !evidence.contains(id) {
                    evidence.append(id)
                }
                required += tabChildren.map(\.name)
                peopleTab?.storedOn.forEach { storedOn.insert($0) }
            }
            sentences.append(.init(text: text + ".", evidenceIDs: evidence,
                                   requiredPersonNames: required))
        } else if !tabChildren.isEmpty, let peopleTab {
            // The tree records no children at all, so there is no count to
            // attribute: the People tab speaks for itself, exactly as before.
            sentences.append(peopleTabListSentence(tabChildren))
            peopleTab.storedOn.forEach { storedOn.insert($0) }
        }
        // 6. How far the tree reaches from this person.
        if let depth = depthClause(summary) {
            let opener = sentences.isEmpty ? "\(leadName)'s" : pronoun.possessive.capitalized
            sentences.append(.init(text: "\(opener) family tree includes \(depth).",
                                   evidenceIDs: [person.id]))
        }
        return Card(subject: person, sentences: sentences,
                    peopleTabStoredOn: storedOn.sorted(), dataQualityFlags: flags,
                    lifeStatus: life,
                    peopleTabDerived: derivedOrder.map {
                        .init(note: $0, names: derivedNames[$0] ?? [])
                    },
                    peopleTabWarnings: peopleTab?.warnings ?? [])
    }

    /// The policy-shaped answer both graph operations return.
    static func answer(for person: GedcomFamilyGraph.Person,
                       in graph: GedcomFamilyGraph,
                       peopleTab: PeopleTabKin? = nil,
                       lifeStatus: LifeStatus? = nil,
                       profileBirthdate: Date? = nil,
                       profileDeathdate: Date? = nil) -> (ArchivistBiographyAnswer, HallieAnswerPlan?, Card) {
        let card = card(for: person, in: graph, peopleTab: peopleTab, lifeStatus: lifeStatus,
                        profileBirthdate: profileBirthdate, profileDeathdate: profileDeathdate)
        guard !card.sentences.isEmpty else {
            return (ArchivistBiographyAnswer(
                state: .missingFact,
                text: "\(person.name) is in the family tree, but it records no further details.",
                basis: ArchivistBiographyPolicy.gedcomBasis,
                catalogPersonName: person.name), nil, card)
        }
        return (ArchivistBiographyAnswer(
            state: .answered,
            text: card.prose,
            basis: ArchivistBiographyPolicy.gedcomBasis,
            catalogPersonName: person.name), card.plan, card)
    }

    /// The basis clause for the People-tab rows a card used — appended by
    /// the executor after whatever basis the bridge produced. Empty when
    /// the card used none.
    static func peopleTabBasis(_ card: Card) -> String {
        var basis = ""
        if !card.peopleTabStoredOn.isEmpty {
            // "(stored on Rick's profile; Tim, Ellen and Beth derived from
            // Rick's rows: full siblings share parents)" — same clause shape
            // as the kinship route, so the two read alike.
            basis += " People tab relationships "
                + ArchivistGraphExecutor.overlayStoredOnClause(
                    storedOn: card.peopleTabStoredOn,
                    namesByNote: card.peopleTabDerived.map { (note: $0.note, names: $0.names) })
                + "; local only, not from the family tree."
        }
        // A sibling set that failed closed is said here, whether or not
        // any row was used: the People tab may look empty for this person
        // only because its rows contradict each other.
        if !card.peopleTabWarnings.isEmpty {
            basis += ArchivistGraphExecutor.overlayWarningClause(card.peopleTabWarnings)
        }
        return basis
    }

    // MARK: - Data quality

    /// Flags for the subject and each of the subject's parents: any of
    /// them with a second recorded parent family. Deterministic order:
    /// subject first, then parents in policy order. One flag per person;
    /// the same record listed under two families is not a second parent
    /// (the graph already drops it).
    static func dataQualityFlags(for person: GedcomFamilyGraph.Person,
                                 in graph: GedcomFamilyGraph) -> [DataQualityFlag] {
        let subjects = [person] + ArchivistBiographyPolicy.orderedPeople(graph.relatives(.parents, of: person))
        var flags: [DataQualityFlag] = []
        for subject in subjects {
            guard let choice = graph.parentFamilyChoice(of: subject), !choice.alternates.isEmpty,
                  let note = graph.parentFamilyBasisNote(for: subject) else { continue }
            let roles = Set(choice.alternates.map(\.role))
            let role = roles.count == 1 ? (roles.first == .mother ? "mothers" : "fathers") : "parents"
            flags.append(DataQualityFlag(
                child: subject, role: role,
                parents: choice.parents + choice.alternates.map(\.person),
                looksLikeDuplicate: choice.unfoldedAlternates.isEmpty,
                note: note))
        }
        return flags
    }

    /// The basis clause for the data-quality flags a card carries —
    /// appended by the executor after the People-tab clause. Empty when
    /// there are none. A flag on a PARENT of the subject is prefixed with
    /// that parent's name so "her mother" cannot be misread:
    /// " (another record for her mother, Mary O'Connor b. 1905, exists in
    /// the tree — same parents; treated as the same person)" on Eileen's
    /// card; " For Eileen Latta: (another record …)" on Rick's.
    static func dataQualityBasis(_ card: Card) -> String {
        card.dataQualityFlags.map { flag in
            flag.child.id == card.subject.id ? " \(flag.note)" : " For \(flag.child.name): \(flag.note)"
        }.joined()
    }

    /// " Birth and death dates are from Ma's People profile." — the basis
    /// clause naming WHICH store a spoken vital date came from
    /// (HallieVitalDates rule 6, 2026-09-04), appended by the executor next
    /// to the People-tab and data-quality clauses. Empty when the tree's own
    /// dates were spoken. It deliberately does NOT say the two stores
    /// disagree: that goes to the log for Rick, never into the answer.
    static func vitalDatesBasis(
        profileName: String?, birth: Date?, death: Date?
    ) -> String {
        guard let profileName, birth != nil || death != nil else { return "" }
        let fields: String
        switch (birth != nil, death != nil) {
        case (true, true): fields = "Birth and death dates are"
        case (true, false): fields = "The birth date is"
        default: fields = "The death date is"
        }
        return " \(fields) from \(profileName)'s People profile."
    }

    /// The FamilySearch ID when the record has one, else the file-local
    /// pointer — whatever lets Rick find the record upstream.
    static func recordCode(_ person: GedcomFamilyGraph.Person) -> String {
        let fsid = person.familySearchID?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        return fsid.isEmpty ? person.id : fsid
    }

    static func countWord(_ n: Int) -> String {
        switch n {
        case 1: return "one"
        case 2: return "two"
        case 3: return "three"
        case 4: return "four"
        case 5: return "five"
        case 6: return "six"
        case 7: return "seven"
        case 8: return "eight"
        case 9: return "nine"
        case 10: return "ten"
        case 11: return "eleven"
        case 12: return "twelve"
        default: return "\(n)"
        }
    }

    /// "Beth and Ellen as daughters and Tim as a son" — People-tab
    /// relatives grouped by the word their row gives them. Deliberately
    /// ADDS rather than totals: the sentence that carries this never says
    /// how many children the person had, only what each source holds.
    static func addedClause(_ relatives: [PeopleTabKin.Relative]) -> String {
        var order: [String] = []
        var namesByTerm: [String: [String]] = [:]
        for relative in relatives {
            if namesByTerm[relative.term] == nil { order.append(relative.term) }
            namesByTerm[relative.term, default: []].append(relative.name)
        }
        return joined(order.map { term in
            let names = namesByTerm[term] ?? []
            return joined(names) + " as "
                + (names.count == 1 ? "a \(term)" : pluralTerm(term))
        })
    }

    /// "daughter" → "daughters", "child" → "children"; a term that is
    /// already plural is left alone.
    static func pluralTerm(_ term: String) -> String {
        if term.hasSuffix("child") { return term + "ren" }
        return term.hasSuffix("s") ? term : term + "s"
    }

    // MARK: - Clauses

    struct Pronoun {
        let subject: String
        let object: String
        let possessive: String
        init(sex: String) {
            switch sex {
            case "M": subject = "He"; object = "him"; possessive = "his"
            case "F": subject = "She"; object = "her"; possessive = "her"
            default: subject = "They"; object = "them"; possessive = "their"
            }
        }
    }

    /// "was born 28 February 1629 in Sudbury, Middlesex and died before
    /// 29 November 1717 in Sudbury, Middlesex" — either half may be absent;
    /// a place with no date still stands on its own ("was born in Boston").
    /// Nil when the record has neither a date nor a place for either event.
    /// `profileBirthdate`/`profileDeathdate`: the owning People profile's
    /// date, spoken INSTEAD of the tree's own recorded date for that field
    /// (HallieVitalDates rule 1). Nil ⇒ the tree's date, unchanged.
    static func vitalsClause(
        _ person: GedcomFamilyGraph.Person,
        profileBirthdate: Date? = nil,
        profileDeathdate: Date? = nil
    ) -> String? {
        let birth = eventClause("was born", date: person.birthDate, place: person.birthPlace,
                                profileDate: profileBirthdate)
        let death = eventClause("died", date: person.deathDate, place: person.deathPlace,
                                profileDate: profileDeathdate)
        let parts = [birth, death].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " and ")
    }

    /// ", born 21 February 1929 in Boston, died 25 June 2008" — the vitals
    /// as a trailing aside for a relative named inside another sentence
    /// (the kinship overlay's bridged answers). Empty when nothing is
    /// recorded.
    ///
    /// `profileBirthdate`/`profileDeathdate`: as on `vitalsClause` — the
    /// owning People profile's date, spoken instead of the tree's own
    /// (HallieVitalDates rule 1, Rick's ruling 2026-09-04). This is the
    /// THIRD route that states a person's dates, and until 2026-09-04 it
    /// was the last one still reading the tree directly: "who are Tim's
    /// parents" said Dad died 22 June 2008 while "tell me about Dad" in the
    /// same conversation said 25 June 2008. Note that a profile date is
    /// stated here even when the tree records none for that field — that is
    /// rule 1, not a special case, and it is why a relative who has a
    /// People profile now carries dates in sentences that used to carry
    /// none.
    static func vitalsAside(
        _ person: GedcomFamilyGraph.Person,
        profileBirthdate: Date? = nil,
        profileDeathdate: Date? = nil
    ) -> String {
        let birth = eventClause("born", date: person.birthDate, place: person.birthPlace,
                                profileDate: profileBirthdate)
        let death = eventClause("died", date: person.deathDate, place: person.deathPlace,
                                profileDate: profileDeathdate)
        let parts = [birth, death].compactMap { $0 }
        return parts.isEmpty ? "" : ", " + parts.joined(separator: ", ")
    }

    private static func eventClause(
        _ verb: String, date: String?, place: String?, profileDate: Date? = nil
    ) -> String? {
        // A People profile's date is a `Date`, not a GEDCOM string. It is
        // canonicalised and rendered through exactly the same UTC calendar
        // and house format the age route uses (HallieVitalDates), so the two
        // routes cannot render the same day as two different sentences.
        let spoken = profileDate.map {
            HallieDateStyle.spoken(
                ArchivistTemporalExecutor.canonicalDay($0) ?? $0,
                calendar: HallieVitalDates.utcCalendar)
        } ?? spokenDate(date)
        let trimmedPlace = place?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard spoken != nil || !trimmedPlace.isEmpty else { return nil }
        var text = verb
        if let spoken { text += " " + spoken }
        if !trimmedPlace.isEmpty { text += " in " + trimmedPlace }
        return text
    }

    /// "was married to Martha Lamson (married 12 May 1650)"; several
    /// marriages joined with "and"; a family with a date but no recorded
    /// spouse is stated as such. Nil when no marriage says anything.
    /// The departed subject's form — every marriage in the past tense.
    static func marriageClause(_ marriages: [GedcomFamilyGraph.Marriage]) -> String? {
        marriageClause(marriages, subjectLiving: false, spouseLiving: { _ in false })
    }

    /// Tense-aware form (2026-09-01). A living subject "is married to" a
    /// living spouse and "was married to" one who has passed on (or one
    /// the tree does not name): "is married to Donna Hudson and was
    /// married to Jane Doe". A subject who has passed on keeps "was
    /// married to" for all of them, exactly as before. `plural` = the
    /// sentence opens with "They" (unrecorded sex): "are" / "were".
    static func marriageClause(_ marriages: [GedcomFamilyGraph.Marriage],
                               subjectLiving: Bool,
                               plural: Bool = false,
                               spouseLiving: (GedcomFamilyGraph.Person) -> Bool) -> String? {
        var present: [String] = []
        var past: [String] = []
        for marriage in orderedMarriages(marriages) {
            let date = spokenDate(marriage.date)
            switch (marriage.spouse, date) {
            case (let spouse?, let date?):
                let part = "\(spouse.name) (married \(date))"
                if subjectLiving, spouseLiving(spouse) { present.append(part) } else { past.append(part) }
            case (let spouse?, nil):
                if subjectLiving, spouseLiving(spouse) { present.append(spouse.name) } else { past.append(spouse.name) }
            case (nil, let date?):
                past.append("someone the tree does not name (married \(date))")
            case (nil, nil):
                continue
            }
        }
        var clauses: [String] = []
        if !present.isEmpty { clauses.append("\(plural ? "are" : "is") married to " + joined(present)) }
        if !past.isEmpty { clauses.append("\(plural ? "were" : "was") married to " + joined(past)) }
        guard !clauses.isEmpty else { return nil }
        return clauses.joined(separator: " and ")
    }

    /// Policy order (name, then pointer), not FAMS file order, so two
    /// equivalent GEDCOM orderings read — and cite — the same; nameless last.
    static func orderedMarriages(_ marriages: [GedcomFamilyGraph.Marriage]) -> [GedcomFamilyGraph.Marriage] {
        marriages.sorted { lhs, rhs in
            switch (lhs.spouse, rhs.spouse) {
            case (nil, nil): return (lhs.date ?? "") < (rhs.date ?? "")
            case (nil, _): return false
            case (_, nil): return true
            case (let a?, let b?):
                let left = FamilyIdentityText.normalized(a.name)
                let right = FamilyIdentityText.normalized(b.name)
                return left != right ? left < right : a.id < b.id
            }
        }
    }

    /// "2 recorded ancestors across 1 generation and 27 recorded
    /// descendants across 11 generations" — the family-tree summary's own
    /// wording, kept so existing readers recognise it. Nil when the person
    /// is unlinked.
    static func depthClause(_ summary: ArchivistFamilyTreePolicy.PersonSummary) -> String? {
        var counts: [String] = []
        if summary.ancestorCount > 0 {
            counts.append("\(summary.ancestorCount) recorded ancestor"
                + (summary.ancestorCount == 1 ? "" : "s")
                + " across \(summary.ancestorGenerations) generation"
                + (summary.ancestorGenerations == 1 ? "" : "s"))
        }
        if summary.descendantCount > 0 {
            counts.append("\(summary.descendantCount) recorded descendant"
                + (summary.descendantCount == 1 ? "" : "s")
                + " across \(summary.descendantGenerations) generation"
                + (summary.descendantGenerations == 1 ? "" : "s"))
        }
        return counts.isEmpty ? nil : counts.joined(separator: " and ")
    }

    // MARK: - Names

    static func joinedNames(_ people: [GedcomFamilyGraph.Person]) -> String {
        joined(people.map(\.name))
    }

    /// "A", "A and B", "A, B and C".
    static func joined(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return items[0] + " and " + items[1]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    /// Up to `maxListedNames` names, then "and N more".
    static func listedNames(_ people: [GedcomFamilyGraph.Person]) -> String {
        guard people.count > maxListedNames else { return joinedNames(people) }
        let shown = people.prefix(maxListedNames).map(\.name).joined(separator: ", ")
        return shown + " and \(people.count - maxListedNames) more"
    }

    // MARK: - Dates

    /// The recorded GEDCOM date read aloud in the house format
    /// (`HallieDateStyle`, 2026-09-03): "28 FEB 1629" → "28 February
    /// 1629", "BEF 29 NOV 1717" → "before 29 November 1717". The month
    /// table, the qualifier table, and the rendering now live in one place
    /// that the composition verifier also reads, so a date Swift wrote and
    /// a date the verifier recognises can never drift apart.
    static func spokenDate(_ raw: String?) -> String? {
        HallieDateStyle.spoken(raw)
    }
}
