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
                        evidenceIDs: sentence.evidenceIDs)
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
        let siblings: [Relative]
        let children: [Relative]
        let spouses: [Relative]
        /// Profiles whose rows produced the relatives above.
        let storedOn: [String]

        /// Derivation conflicts the subject's sibling set is part of (the
        /// overlay failed closed — nothing derived for it); stated in the
        /// basis so a silent gap is never mistaken for "no siblings".
        var warnings: [String] = []

        init(profileName: String, siblings: [Relative] = [], children: [Relative] = [],
             spouses: [Relative] = [], storedOn: [String] = [], warnings: [String] = []) {
            self.profileName = profileName
            self.siblings = siblings
            self.children = children
            self.spouses = spouses
            self.storedOn = storedOn
            self.warnings = warnings
        }
    }

    /// More than one recorded mother (or father) for one person. Either a
    /// FamilySearch duplicate (the same woman entered twice — "Mary
    /// Catherine O'Connor" and "Mary O'Connor") or a genuine second
    /// parent; the sentence says which reading the names suggest and
    /// never picks one.
    struct DataQualityFlag: Sendable, Equatable {
        let child: GedcomFamilyGraph.Person
        /// "mothers" / "fathers".
        let role: String
        let parents: [GedcomFamilyGraph.Person]
        /// The parents share a surname and a first given name — the
        /// duplicate reading.
        let looksLikeDuplicate: Bool

        var evidenceIDs: [String] { [child.id] + parents.map(\.id) }

        /// "The tree records two mothers for Eileen Latta — Mary Catherine
        /// O'Connor (G89Q-34N) and Mary O'Connor (GNZ5-428) — probably a
        /// duplicate on FamilySearch worth merging."
        var text: String {
            let labelled = parents.map { "\($0.name) (\(HallieBiographyCard.recordCode($0)))" }
            let reading = looksLikeDuplicate
                ? "probably a duplicate on FamilySearch worth merging"
                : "possibly a second marriage, or a duplicate worth checking on FamilySearch"
            return "The tree records \(HallieBiographyCard.countWord(parents.count)) \(role) for \(child.name) — "
                + HallieBiographyCard.joined(labelled) + " — \(reading)."
        }
    }

    /// Names listed by name before "and N more" (the children sentence).
    static let maxListedNames = 12

    // MARK: - Build

    /// `lifeStatus` nil ⇒ decided from the tree record and the family around
    /// it (LifeStatus.of); the executor passes the People-tab verdict when
    /// the subject is a profile, whose recorded death the tree may lack.
    static func card(for person: GedcomFamilyGraph.Person,
                     in graph: GedcomFamilyGraph,
                     peopleTab: PeopleTabKin? = nil,
                     lifeStatus: LifeStatus? = nil) -> Card {
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

        /// "In the People tab: Tim — brother, Beth — sister." Nil when the
        /// tree already lists every one of them.
        func peopleTabSentence(_ relatives: [PeopleTabKin.Relative],
                               treeIDs: Set<String>) -> Card.Sentence? {
            let extra = relatives.filter { $0.gedcomID.map { !treeIDs.contains($0) } ?? true }
            guard !extra.isEmpty else { return nil }
            for relative in extra {
                guard let note = relative.derivation else { continue }
                if derivedNames[note] == nil { derivedOrder.append(note) }
                derivedNames[note, default: []].append(relative.name)
            }
            let listed = extra.map { "\($0.name) — \($0.term)" }
            // Three siblings derived from one card cite that card once.
            var evidence = [person.id]
            for id in extra.map(\.evidenceID) where !evidence.contains(id) { evidence.append(id) }
            return .init(text: "In the People tab: " + joined(listed) + ".",
                         evidenceIDs: evidence)
        }

        // 1. Vitals with places, as recorded.
        if let vitals = vitalsClause(person) {
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
                evidenceIDs: [person.id] + summary.parents.map(\.id) + summary.grandparents.map(\.id)))
        }
        // 2b. Data quality: a duplicated parent on the subject or on a
        //     parent (the reason a card can list five grandparents).
        let flags = dataQualityFlags(for: person, in: graph)
        for flag in flags {
            sentences.append(.init(text: flag.text, evidenceIDs: flag.evidenceIDs))
        }
        // 3. Siblings — the tree's, then the People tab's (the living are
        //    not on FamilySearch; Tim is a People-tab sibling row).
        if !summary.siblings.isEmpty {
            let n = summary.siblings.count
            sentences.append(.init(
                text: "\(lead()) \(have()) \(n) recorded \(n == 1 ? "sibling" : "siblings"), "
                    + listedNames(summary.siblings) + ".",
                evidenceIDs: [person.id] + summary.siblings.map(\.id)))
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
                evidenceIDs: [person.id] + marriages.compactMap(\.spouse?.id)))
        } else if let peopleTab, let extra = peopleTabSentence(peopleTab.spouses, treeIDs: []) {
            sentences.append(extra)
            peopleTab.storedOn.forEach { storedOn.insert($0) }
        }
        // 5. Children: the tree's count and names, then the People tab's
        //    that the tree lacks (2026-09-02: Eileen's tree lists Rick;
        //    Tim, Ellen and Beth are hers through Rick's sibling rows).
        if !summary.children.isEmpty {
            let n = summary.children.count
            sentences.append(.init(
                text: "\(lead()) \(have()) \(n) recorded \(n == 1 ? "child" : "children"), "
                    + listedNames(summary.children) + ".",
                evidenceIDs: [person.id] + summary.children.map(\.id)))
        }
        if let peopleTab,
           let extra = peopleTabSentence(peopleTab.children, treeIDs: Set(summary.children.map(\.id))) {
            sentences.append(extra)
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
                       lifeStatus: LifeStatus? = nil) -> (ArchivistBiographyAnswer, HallieAnswerPlan?, Card) {
        let card = card(for: person, in: graph, peopleTab: peopleTab, lifeStatus: lifeStatus)
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
    /// them with more than one recorded mother or father. Deterministic
    /// order: subject first, then parents in policy order; mothers before
    /// fathers; parents in policy order. Two distinct records only — a
    /// person listed as a child of the same family twice is one parent.
    static func dataQualityFlags(for person: GedcomFamilyGraph.Person,
                                 in graph: GedcomFamilyGraph) -> [DataQualityFlag] {
        let subjects = [person] + ArchivistBiographyPolicy.orderedPeople(graph.relatives(.parents, of: person))
        var flags: [DataQualityFlag] = []
        for subject in subjects {
            for (relation, role) in [(GedcomFamilyGraph.Relation.mother, "mothers"),
                                     (GedcomFamilyGraph.Relation.father, "fathers")] {
                let parents = ArchivistBiographyPolicy.orderedPeople(graph.relatives(relation, of: subject))
                guard parents.count > 1 else { continue }
                flags.append(DataQualityFlag(
                    child: subject, role: role, parents: parents,
                    looksLikeDuplicate: namesLookAlike(parents)))
            }
        }
        return flags
    }

    /// Any two of them share a surname and a first given-name token
    /// ("Mary Catherine O'Connor" / "Mary O'Connor").
    static func namesLookAlike(_ people: [GedcomFamilyGraph.Person]) -> Bool {
        func key(_ person: GedcomFamilyGraph.Person) -> (given: String, surname: String)? {
            let suffixes = GedcomFamilyGraph.nameSuffixes
            let tokens = FamilyIdentityText.tokens(person.name).filter { !suffixes.contains($0) }
            guard let given = tokens.first else { return nil }
            let surname = person.surname.map(FamilyIdentityText.normalized) ?? tokens.last ?? ""
            return (given, surname)
        }
        let keys = people.compactMap(key)
        guard keys.count >= 2 else { return false }
        for i in keys.indices {
            for j in keys.indices where j > i {
                if keys[i].given == keys[j].given, keys[i].surname == keys[j].surname,
                   !keys[i].surname.isEmpty { return true }
            }
        }
        return false
    }

    /// The FamilySearch ID when the record has one, else the file-local
    /// pointer — whatever lets Rick find the record upstream.
    static func recordCode(_ person: GedcomFamilyGraph.Person) -> String {
        let fsid = person.familySearchID?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        return fsid.isEmpty ? person.id : fsid
    }

    static func countWord(_ n: Int) -> String {
        switch n {
        case 2: return "two"
        case 3: return "three"
        case 4: return "four"
        default: return "\(n)"
        }
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
    static func vitalsClause(_ person: GedcomFamilyGraph.Person) -> String? {
        let birth = eventClause("was born", date: person.birthDate, place: person.birthPlace)
        let death = eventClause("died", date: person.deathDate, place: person.deathPlace)
        let parts = [birth, death].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " and ")
    }

    /// ", born 22 February 1929 in Albany, died 1 July 2008" — the vitals
    /// as a trailing aside for a relative named inside another sentence
    /// (the kinship overlay's bridged answers). Empty when nothing is
    /// recorded.
    static func vitalsAside(_ person: GedcomFamilyGraph.Person) -> String {
        let birth = eventClause("born", date: person.birthDate, place: person.birthPlace)
        let death = eventClause("died", date: person.deathDate, place: person.deathPlace)
        let parts = [birth, death].compactMap { $0 }
        return parts.isEmpty ? "" : ", " + parts.joined(separator: ", ")
    }

    private static func eventClause(_ verb: String, date: String?, place: String?) -> String? {
        let spoken = spokenDate(date)
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

    private static let monthNames: [String: String] = [
        "JAN": "January", "FEB": "February", "MAR": "March", "APR": "April",
        "MAY": "May", "JUN": "June", "JUL": "July", "AUG": "August",
        "SEP": "September", "OCT": "October", "NOV": "November", "DEC": "December",
    ]
    private static let qualifierWords: [String: String] = [
        "BEF": "before", "AFT": "after", "ABT": "about", "CAL": "about",
        "EST": "about", "INT": "about", "BET": "between", "AND": "and",
        "FROM": "from", "TO": "to",
    ]

    /// The recorded GEDCOM date read aloud at its own precision and with
    /// its own qualifier: "28 FEB 1629" → "28 February 1629", "BEF 29 NOV
    /// 1717" → "before 29 November 1717", "ABT 1633" → "about 1633",
    /// "BET 1700 AND 1710" → "between 1700 and 1710". Anything else with a
    /// four-digit year passes through as written; no year → nil (a date
    /// we cannot read is not a date we can state).
    static func spokenDate(_ raw: String?) -> String? {
        guard let raw, GedcomYearInterval.parse(raw) != nil else { return nil }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop a calendar escape ("@#DJULIAN@ 1700").
        if text.hasPrefix("@#") , let close = text.firstIndex(of: " ") {
            text = String(text[text.index(after: close)...])
        }
        let words = text.split(separator: " ").map { word -> String in
            let upper = word.uppercased()
            if let month = monthNames[upper] { return month }
            if let qualifier = qualifierWords[upper] { return qualifier }
            return String(word)
        }
        return words.joined(separator: " ")
    }
}
