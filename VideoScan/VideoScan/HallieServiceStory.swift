// HallieServiceStory.swift
// The WORDS of Hallie's military-service answers, decided in one pure,
// testable place (Rick 2026-09-23: "hallie could say 'would you like to
// hear more about X and how they served their country' … then we tell a
// brief story about their service, brief is good because we're lacking some
// details").
//
// Everything said here is either
//   - the family's own story, verbatim (the CyberBrain item's `text`),
//   - a line built only from the structured record's fields (force,
//     engagements, combat, basis — never a rank, unit, wound or deed the
//     record does not hold),
//   - a fact the family tree records, quoted verbatim with its raw date and
//     place, or
//   - a question Hallie asks (the offer).
// So a sentence can always answer "how do we know that?".
//
// THE OFFER WORDING (proposed by Claude, 2026-09-23 — Rick to confirm):
//   - the family's tradition, not yet documented (John Robert Latta):
//       "Would you like to hear the family story of John Robert Latta's
//        service in the Civil War?"
//     — it is a story the family tells, and Hallie says so before telling it.
//   - a United States force, pronoun known from the tree (Rick's father):
//       "Would you like to hear how Richard Harding Breen Sr served his country?"
//     — Rick's own phrase. Only for a US force: "his country" is accurate
//     there and needs no argument.
//   - any other force (Chris O'Connor, British Army):
//       "Would you like to hear about Christopher O'Connor's service in the
//        British Army?"
//     — names the army instead of deciding which country was "his" (an
//     Irishman in the British Army before 1922, a Confederate soldier).
//
// C++ analogy: a namespace of pure functions (an enum with no cases cannot
// be instantiated); every input is a value, nothing reads disk or globals.

import Foundation
import VideoScanCore

enum HallieServiceStory {

    // MARK: - The story itself

    /// The line that says how the family knows the story, from the item's
    /// first source and the record's basis.
    static func sourceLine(item: CyberBrainItem, record: CyberBrainServiceRecord,
                           source: CyberBrainSource?) -> String {
        let who = source?.attribution?.trimmingCharacters(in: .whitespaces)
        switch record.basis {
        case .familyTradition:
            if let who, !who.isEmpty {
                return "That's family tradition, from \(who); no document confirms it yet."
            }
            return "That's family tradition; no document confirms it yet."
        case .documented:
            if let title = source?.title, !title.isEmpty {
                return "The source is \(title)."
            }
            return "A document confirms it."
        case .confirmedByFamily:
            if let who, !who.isEmpty { return "\(who) told me this." }
            return "The family told me this."
        }
    }

    /// The brief story: the family's own text, then how we know it.
    static func story(item: CyberBrainItem, source: CyberBrainSource?) -> String {
        guard let record = item.service else { return item.text }
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ended = text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?") ? text : text + "."
        return ended + " " + sourceLine(item: item, record: record, source: source)
    }

    // MARK: - One line per person (family-wide answers)

    /// "Richard Harding Breen Sr served in the United States Marine Corps
    /// (World War II; never in combat)." — only the record's fields.
    static func summaryLine(name: String, record: CyberBrainServiceRecord) -> String {
        let verb: String
        if record.combat == .yes, !record.engagements.isEmpty {
            verb = "fought with the \(record.force)"
        } else {
            verb = "served in the \(record.force)"
        }
        var line = "\(name) \(verb)"
        let places = record.engagements.map(\.name)
        switch places.count {
        case 0: break
        case 1: line += " at the \(places[0])"
        case 2: line += " at the \(places[0]) and the \(places[1])"
        default: line += " in \(places.count) battles the family names"
        }
        var notes: [String] = []
        if let war = record.conflict.flatMap(HallieServiceQuestion.War.init) {
            notes.append(war.name)
        }
        if let dates = record.serviceDates?.displayText, !dates.isEmpty,
           record.engagements.isEmpty {
            notes.append(dates)
        }
        if record.combat == .no { notes.append("never in combat") }
        if record.basis == .familyTradition { notes.append("family tradition") }
        if record.conflict == nil, record.serviceDates == nil, record.engagements.isEmpty {
            notes.append("the details aren't known yet")
        }
        if !notes.isEmpty { line += " (\(notes.joined(separator: "; ")))" }
        return line + "."
    }

    // MARK: - The offer

    /// True for a force of the United States ("United States Marine Corps",
    /// "U.S. Army", "US Navy") — the only case "served his country" is said.
    static func isUnitedStatesForce(_ force: String) -> Bool {
        let lower = force.lowercased()
        return lower.hasPrefix("united states ") || lower.hasPrefix("u.s. ")
            || lower.hasPrefix("us ") || lower.hasPrefix("u. s. ")
            || lower == "united states army" || lower.hasPrefix("usmc")
    }

    /// The question Hallie asks after a biography. `pronoun` is the tree's
    /// possessive ("his"/"her"), nil when the tree doesn't say.
    static func offerSentence(name: String, record: CyberBrainServiceRecord,
                              pronoun: String?) -> String {
        if record.basis == .familyTradition {
            let war = record.conflict.flatMap(HallieServiceQuestion.War.init).map { " in \($0.name)" } ?? ""
            return "Would you like to hear the family story of \(possessive(name)) service\(war)?"
        }
        if isUnitedStatesForce(record.force) {
            if let pronoun {
                return "Would you like to hear how \(name) served \(pronoun) country?"
            }
            return "Would you like to hear how \(name) served in the \(record.force)?"
        }
        return "Would you like to hear about \(possessive(name)) service in the \(record.force)?"
    }

    /// "his" / "her" from a tree SEX; nil for anything else.
    static func possessivePronoun(sex: String?) -> String? {
        switch sex?.uppercased() {
        case "M": return "his"
        case "F": return "her"
        default: return nil
        }
    }

    /// "Christopher O'Connor" → "Christopher O'Connor's"; "Hughes" → "Hughes'".
    static func possessive(_ name: String) -> String {
        name.hasSuffix("s") ? name + "'" : name + "'s"
    }

    // MARK: - Facts the family tree records

    /// Which of the four wars a tree fact belongs to: the war its own words
    /// name, else the war whose years contain its DATE. Nil when neither.
    /// The date rule never says the person fought — the phrase keeps the
    /// fact's own words and date ("dated 6 July 1780").
    static func war(of fact: GedcomFamilyGraph.MilitaryFact) -> HallieServiceQuestion.War? {
        let words = [fact.value, fact.type, fact.note].compactMap { $0 }.joined(separator: " ")
        if let named = HallieServiceQuestion.war(namedIn: words) { return named }
        guard let year = fact.year else { return nil }
        return HallieServiceQuestion.War.allCases.first { $0.worldFact?.years.contains(year) == true }
    }

    /// "a military draft registration dated 1917-1918 in Ohio, West Virginia,
    /// United States" / "“Private in Revolutionary War”" / "military service
    /// dated 6 July 1780 in Shrewsbury, Worcester, Massachusetts" — the
    /// tree's own words, raw date, raw place.
    static func phrase(_ fact: GedcomFamilyGraph.MilitaryFact) -> String {
        var text: String
        if fact.isDraftRegistration {
            text = "a military draft registration"
        } else if let summary = fact.summary {
            text = "“\(summary)”"
        } else {
            text = "military service"
        }
        if let date = fact.date { text += " dated \(date)" }
        if let place = fact.place { text += " in \(place)" }
        return text
    }

    /// One sentence for a person's tree facts (at most `limit` of them).
    static func treeSentence(name: String, facts: [GedcomFamilyGraph.MilitaryFact],
                             limit: Int = 3) -> String? {
        guard !facts.isEmpty else { return nil }
        let shown = facts.prefix(limit).map(phrase)
        var sentence = "The family tree records " + shown.joined(separator: "; ") + " for \(name)"
        if facts.count > limit { sentence += ", and \(facts.count - limit) more" }
        return sentence + "."
    }

    /// "Nathaniel Caleb Parker (b. 1741) — military service dated 6 July 1780
    /// in Shrewsbury, Worcester, Massachusetts, United States" for a list.
    static func treeListLine(person: GedcomFamilyGraph.Person,
                             facts: [GedcomFamilyGraph.MilitaryFact]) -> String {
        var name = person.name
        if let born = person.birthYear { name += " (b. \(born))" }
        return name + " — " + facts.prefix(2).map(phrase).joined(separator: "; ")
    }
}
