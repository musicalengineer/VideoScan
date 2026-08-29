// HallieResearchQuestion.swift
// "what do we know about David McGill Latta from research" / "research on
// David Latta" (Research Person phase 1, 2026-08-29). Answered from the
// CyberBrain ONLY: the items Research Person wrote when Rick pressed Tell
// Hallie — each carries a research source (URL + retrieval date) and is
// `confirmed`. Anything else about the person (told-me passages, notes,
// unconfirmed research items however they got there) is never cited by
// this shape; "tell me about …" remains the place for the full picture.
//
// Model-free and pure: detection is a handful of regexes over the
// normalized sentence; the answer is a template over the matching items.
//
// C++ readers: a namespace of static functions over value types.

import Foundation
import VideoScanCore

struct HallieResearchQuestion: Equatable {
    /// The name as typed, trimmed.
    let personName: String

    // MARK: - Detection

    private static let shapes: [NSRegularExpression] = {
        let name = "(.+?)"
        let research = "(?:the )?research(?: findings| results| notes)?"
        let patterns = [
            "^what do we know about \(name) from \(research)$",
            "^what do we know from \(research) about \(name)$",
            "^what does \(research) (?:say|tell us|show|have) (?:about|on|for) \(name)$",
            "^what (?:did|has) \(research) (?:find|found|turn up|turned up|say|said) (?:about|on|for) \(name)$",
            "^what \(research) (?:do we have|is there|have we done|did we do|have we got|do you have) (?:on|about|for) \(name)$",
            "^(?:show|tell|give) me \(research) (?:on|about|for) \(name)$",
            "^\(research) (?:on|about|for) \(name)$",
            "^what have we researched (?:about|on) \(name)$",
            "^(?:any|is there any) \(research) (?:on|about|for) \(name)$",
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// Lower-cased, punctuation-free, single-spaced; "hallie"/"please"
    /// dropped (same normalization as the roster question).
    static func normalized(_ text: String) -> String {
        let folded = text.lowercased()
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
        return folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
            .map(String.init)
            .filter { !["hallie", "please", "mae"].contains($0) }
            .joined(separator: " ")
    }

    static func detect(_ question: String) -> HallieResearchQuestion? {
        let text = normalized(question)
        guard !text.isEmpty, text.contains("research") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for shape in shapes {
            guard let match = shape.firstMatch(in: text, options: [], range: range),
                  match.numberOfRanges > 1,
                  let nameRange = Range(match.range(at: 1), in: text)
            else { continue }
            var name = String(text[nameRange]).trimmingCharacters(in: .whitespaces)
            for lead in ["my ", "our ", "the "] where name.hasPrefix(lead) && name.count > lead.count {
                name = String(name.dropFirst(lead.count))
            }
            guard !name.isEmpty, name != "him", name != "her", name != "them" else { return nil }
            // Restore capitalization for display: Title Case each token.
            let display = name.split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
            return HallieResearchQuestion(personName: display)
        }
        return nil
    }

    // MARK: - Answer

    typealias Result = HallieTurnExecutor.Result
    typealias Context = HallieTurnExecutor.Context
    typealias KnowledgeCitation = HallieTurnExecutor.KnowledgeCitation

    static let maxCited = 8

    struct Finding: Equatable {
        let item: CyberBrainItem
        let source: CyberBrainSource
    }

    /// Confirmed research items about one CyberBrain person, newest first.
    /// A research item that is not `confirmed` (however it got that way)
    /// is dropped here — the promise is "unconfirmed never cited".
    static func confirmedResearch(personID: String, index: CyberBrainIndex) -> [Finding] {
        index.allActiveItems(for: personID).compactMap { item -> Finding? in
            guard item.confidence == .confirmed else { return nil }
            guard let source = item.sourceIDs.lazy
                .compactMap({ index.source(id: $0) })
                .first(where: { $0.id.hasPrefix(CyberBrainWriter.researchSourceIDPrefix) })
            else { return nil }
            return Finding(item: item, source: source)
        }
        .sorted { $0.item.createdAt == $1.item.createdAt ? $0.item.id < $1.item.id : $0.item.createdAt > $1.item.createdAt }
    }

    /// Who "X" is: a CyberBrain person by name, else tree records by name
    /// bridged to their linked CyberBrain people. Returns (people, tree
    /// person for the chip when nothing is known).
    static func resolve(_ name: String, context: Context)
        -> (people: [CyberBrainPerson], ambiguous: [String], treePerson: GedcomFamilyGraph.Person?) {
        var people: [CyberBrainPerson] = []
        var ambiguous: [String] = []
        if let index = context.cyberBrain {
            switch index.resolve(name) {
            case .resolved(let person): people = [person]
            case .ambiguous(let candidates): ambiguous = candidates.map(\.canonicalName)
            case .notFound: break
            }
        }
        var treePerson: GedcomFamilyGraph.Person?
        if let graph = context.graph {
            let matches = graph.people(namedLike: name)
            if matches.count == 1 { treePerson = matches[0] }
            if people.isEmpty, ambiguous.isEmpty {
                if let index = context.cyberBrain {
                    for match in matches {
                        for linked in index.people(gedcomPersonID: match.id)
                        where !people.contains(where: { $0.id == linked.id }) {
                            people.append(linked)
                        }
                    }
                }
                // Two tree records fit the name and nothing in the brain
                // picks one: ask, never guess (Jr/Sr rule).
                if matches.count > 1, people.isEmpty {
                    ambiguous = matches.map { person in
                        let years = [person.birthYear, person.deathYear].compactMap { $0.map(String.init) }
                        return years.isEmpty ? person.name : "\(person.name) (\(years.joined(separator: "–")))"
                    }
                }
            }
        }
        return (people, ambiguous, treePerson)
    }

    static func answer(_ ask: HallieResearchQuestion, context: Context) -> Result {
        let description = "shape=research person=\(ask.personName)"
        func result(_ prose: String, basis: String, outcome: HallieTurnExecutor.Outcome,
                    citations: [KnowledgeCitation] = [],
                    offered: [HallieTurnExecutor.OfferedAction] = []) -> Result {
            Result(route: .graph, outcome: outcome, prose: prose, basisLine: basis,
                   queryDescription: description, citations: [], knowledgeCitations: citations,
                   catalogPersonName: nil, offeredActions: offered)
        }
        let (people, ambiguous, treePerson) = resolve(ask.personName, context: context)
        if !ambiguous.isEmpty {
            return result(
                "More than one person is called \(ask.personName): \(ambiguous.joined(separator: "; ")). Which one do you mean?",
                basis: "Basis: name matched \(ambiguous.count) people; nothing cited.",
                outcome: .needsClarification)
        }
        let offered: [HallieTurnExecutor.OfferedAction] = treePerson.map {
            [.openFamilyTreePerson(personID: $0.id, personName: $0.name)]
        } ?? []
        guard let index = context.cyberBrain, !people.isEmpty else {
            let who = treePerson?.name ?? ask.personName
            let hint = treePerson != nil
                ? " Right-click \(who) in the Family Tree and choose Research Person… to look, then confirm what's right and tell me."
                : (context.graph == nil ? " I don't have a family tree loaded to research from." : " I don't find \(who) in the family tree.")
            return result(
                "I don't have any confirmed research on \(who) yet.\(hint)",
                basis: "Basis: no CyberBrain research attestations for \(who); nothing cited.",
                outcome: .declined, offered: offered)
        }
        let findings = people.flatMap { confirmedResearch(personID: $0.id, index: index) }
        let displayName = people.first?.canonicalName ?? ask.personName
        guard !findings.isEmpty else {
            return result(
                "I don't have any confirmed research on \(displayName) yet. Right-click them in the Family Tree, choose Research Person…, confirm what's right and press Tell Hallie.",
                basis: "Basis: CyberBrain person \(people.map(\.id).joined(separator: ", ")) has no confirmed research attestations; nothing cited.",
                outcome: .declined, offered: offered)
        }
        let shown = findings.prefix(maxCited)
        var lines: [String] = []
        for (offset, finding) in shown.enumerated() {
            let who = finding.source.attribution.map { " — \($0)" } ?? ""
            lines.append("\(offset + 1). \(finding.item.text) [\(finding.source.title)\(who)]")
        }
        var prose = "From research on \(displayName), \(findings.count) confirmed \(findings.count == 1 ? "finding" : "findings"):\n"
            + lines.joined(separator: "\n")
        if findings.count > shown.count {
            prose += "\n…and \(findings.count - shown.count) more in the Research pane."
        }
        var citations: [KnowledgeCitation] = []
        for finding in shown where !citations.contains(where: { $0.id == finding.source.id }) {
            citations.append(KnowledgeCitation(id: finding.source.id, title: finding.source.title,
                                               attribution: finding.source.attribution,
                                               locator: finding.source.locator))
        }
        let basis = "Basis: CyberBrain research attestations, confirmed only ("
            + shown.map(\.item.id).joined(separator: ", ") + "); unconfirmed research is never cited."
        return result(prose, basis: basis, outcome: .answered, citations: citations, offered: offered)
    }
}
