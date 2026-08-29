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
                fallbackText: prose)
        }
    }

    /// Names listed by name before "and N more" (the children sentence).
    static let maxListedNames = 12

    // MARK: - Build

    static func card(for person: GedcomFamilyGraph.Person,
                     in graph: GedcomFamilyGraph) -> Card {
        let summary = ArchivistFamilyTreePolicy.summary(of: person, in: graph)
        let name = person.name
        let pronoun = Pronoun(sex: person.sex)
        var sentences: [Card.Sentence] = []
        // The first sentence, whichever it is, names the subject in full
        // (HallieAnswerPlan.subjectLeadSentence needs one; the composer's
        // name-first rule rests on it). Later sentences use the pronoun.
        func lead() -> String { sentences.isEmpty ? name : pronoun.subject }

        // 1. Vitals with places, as recorded.
        if let vitals = vitalsClause(person) {
            sentences.append(.init(text: "\(name) \(vitals).", evidenceIDs: [person.id]))
        }
        // 2. Parents, with grandparents folded in (the family-tree summary
        //    always named them; one claim keeps the sentence budget).
        if !summary.parents.isEmpty {
            var text = "\(lead()) was the child of \(joinedNames(summary.parents))"
            if !summary.grandparents.isEmpty {
                let plural = summary.grandparents.count > 1
                text += "; \(pronoun.possessive) recorded grandparent\(plural ? "s were" : " was") "
                    + listedNames(summary.grandparents)
            }
            sentences.append(.init(
                text: text + ".",
                evidenceIDs: [person.id] + summary.parents.map(\.id) + summary.grandparents.map(\.id)))
        }
        // 3. Siblings.
        if !summary.siblings.isEmpty {
            let n = summary.siblings.count
            sentences.append(.init(
                text: "\(lead()) had \(n) recorded \(n == 1 ? "sibling" : "siblings"), "
                    + listedNames(summary.siblings) + ".",
                evidenceIDs: [person.id] + summary.siblings.map(\.id)))
        }
        // 4. Marriage(s) with the MARR date when the family record has one.
        let marriages = orderedMarriages(graph.marriages(of: person))
        if !marriages.isEmpty, let clause = marriageClause(marriages) {
            sentences.append(.init(
                text: "\(lead()) \(clause).",
                evidenceIDs: [person.id] + marriages.compactMap(\.spouse?.id)))
        }
        // 5. Children: count and names.
        if !summary.children.isEmpty {
            let n = summary.children.count
            sentences.append(.init(
                text: "\(lead()) had \(n) recorded \(n == 1 ? "child" : "children"), "
                    + listedNames(summary.children) + ".",
                evidenceIDs: [person.id] + summary.children.map(\.id)))
        }
        // 6. How far the tree reaches from this person.
        if let depth = depthClause(summary) {
            let opener = sentences.isEmpty ? "\(name)'s" : pronoun.possessive.capitalized
            sentences.append(.init(text: "\(opener) family tree includes \(depth).",
                                   evidenceIDs: [person.id]))
        }
        return Card(subject: person, sentences: sentences)
    }

    /// The policy-shaped answer both graph operations return.
    static func answer(for person: GedcomFamilyGraph.Person,
                       in graph: GedcomFamilyGraph) -> (ArchivistBiographyAnswer, HallieAnswerPlan?) {
        let card = card(for: person, in: graph)
        guard !card.sentences.isEmpty else {
            return (ArchivistBiographyAnswer(
                state: .missingFact,
                text: "\(person.name) is in the family tree, but it records no further details.",
                basis: ArchivistBiographyPolicy.gedcomBasis,
                catalogPersonName: person.name), nil)
        }
        return (ArchivistBiographyAnswer(
            state: .answered,
            text: card.prose,
            basis: ArchivistBiographyPolicy.gedcomBasis,
            catalogPersonName: person.name), card.plan)
    }

    // MARK: - Clauses

    struct Pronoun {
        let subject: String
        let possessive: String
        init(sex: String) {
            switch sex {
            case "M": subject = "He"; possessive = "his"
            case "F": subject = "She"; possessive = "her"
            default: subject = "They"; possessive = "their"
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
    static func marriageClause(_ marriages: [GedcomFamilyGraph.Marriage]) -> String? {
        var parts: [String] = []
        for marriage in orderedMarriages(marriages) {
            let date = spokenDate(marriage.date)
            switch (marriage.spouse, date) {
            case (let spouse?, let date?):
                parts.append("\(spouse.name) (married \(date))")
            case (let spouse?, nil):
                parts.append(spouse.name)
            case (nil, let date?):
                parts.append("someone the tree does not name (married \(date))")
            case (nil, nil):
                continue
            }
        }
        guard !parts.isEmpty else { return nil }
        return "was married to " + joined(parts)
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
