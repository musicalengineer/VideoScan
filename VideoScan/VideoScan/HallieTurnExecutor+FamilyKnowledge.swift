// HallieTurnExecutor+FamilyKnowledge.swift
// What the family tree cannot say, the family can (Rick 2026-08-21: Hallie
// should sound like a relative who knows the family).
//
// The 2026-08-21 baseline: "who are Rick's sons" → "The family tree doesn't
// record a children for Richard Harding Breen Jr." — true, and useless. The
// GEDCOM stops at people born in 1959; the sons are not in it. But the
// CyberBrain holds, confirmed by Rick himself, "Rick and Donna have four
// adult sons…". A relative would say both: the tree stops there, AND here
// is what I was told. That is all this file does — two deterministic
// sentences, each traceable: the coverage note to the tree's own birth
// years, the passage to a CyberBrain item and its source. Nothing is
// inferred; the passage is quoted, never paraphrased.

import Foundation

extension HallieTurnExecutor {

    enum FamilyKnowledgeSupplement {

        private static func keywords(for relation: ArchivistQueryAST.Graph.Relation?) -> [String] {
            switch relation?.rawValue ?? "" {
            case "son", "daughter", "children":
                return ["son", "sons", "daughter", "daughters", "children", "kids", "boys", "girls"]
            case "brother", "sister", "siblings":
                return ["brother", "brothers", "sister", "sisters", "sibling", "siblings"]
            case "father", "mother", "parents":
                return ["father", "mother", "parents", "dad", "mom"]
            case "husband", "wife", "spouse":
                return ["married", "wife", "husband", "spouse", "wedding"]
            case "grandfather", "grandmother", "grandparents",
                 "great-grandfather", "great-grandmother", "great-grandparents",
                 "great-great-grandfather", "great-great-grandmother", "great-great-grandparents":
                return ["grandfather", "grandmother", "grandparents", "grandpa", "grandma", "great-grand"]
            default:
                return []
            }
        }

        /// The latest four-digit birth year recorded anywhere in the tree.
        static func latestBirthYear(in graph: GedcomFamilyGraph) -> Int? {
            var latest: Int?
            for person in graph.people.values {
                guard let year = trailingYear(person.birthDate) else { continue }
                latest = max(latest ?? year, year)
            }
            return latest
        }

        static func trailingYear(_ date: String?) -> Int? {
            guard let date else { return nil }
            var digits = ""
            var best: Int?
            for character in date + " " {
                if character.isNumber {
                    digits.append(character)
                } else {
                    if digits.count == 4, let year = Int(digits), (1000...2100).contains(year) {
                        best = year
                    }
                    digits.removeAll()
                }
            }
            return best
        }

        /// Retired 2026-08-26 (live: "The family tree I have only goes up to
        /// people born in 1959, so Rick isn't in it yet" — Rick is in it,
        /// undated, because FamilySearch strips living people's dates). A
        /// max-birth-year is not evidence of coverage; nothing is said.
        static func coverageNote(relation: ArchivistQueryAST.Graph.Relation?,
                                 graph: GedcomFamilyGraph?) -> String? {
            nil
        }

        /// Family-told passages about the subject that mention the missing
        /// relation, with their sources. Empty when there is nothing to say.
        static func passages(
            subjectGedcomID: String?,
            subjectName: String,
            relation: ArchivistQueryAST.Graph.Relation?,
            index: CyberBrainIndex,
            limit: Int = 2
        ) -> [(item: CyberBrainItem, source: CyberBrainSource?)] {
            let words = keywords(for: relation)
            guard !words.isEmpty else { return [] }
            var person: CyberBrainPerson?
            if let subjectGedcomID {
                person = index.archive.people.first { $0.gedcomPersonID == subjectGedcomID }
            }
            if person == nil, case .resolved(let resolved) = index.resolve(subjectName) {
                person = resolved
            }
            guard let person else { return [] }
            let evidence = index.evidence(for: person.id, privacyCeiling: appPrivacyCeiling)
            return evidence
                .filter { item in
                    let text = item.text.lowercased()
                    return words.contains { text.contains($0) }
                }
                .prefix(limit)
                .map { ($0, $0.sourceIDs.first.flatMap { index.source(id: $0) }) }
        }

        private static func attributionLead(_ source: CyberBrainSource?, item: CyberBrainItem) -> String {
            let hedge = item.confidence == .confirmed ? "" : " (not yet verified)"
            guard let source else { return "I have a note\(hedge) that says" }
            switch source.type {
            case .firstPerson, .familyWitness:
                let who = source.attribution ?? "a family member"
                return "\(who) told me\(hedge)"
            case .officialRecord:
                return "the records say"
            case .gedcom:
                return "the family tree notes say"
            case .curatedBiography:
                return "the family biography says\(hedge)"
            case .mediaEvidence, .profileNote, .inference:
                return "I have a note\(hedge) that says"
            }
        }

        /// The graph route's final answer, enriched when the tree fell short.
        /// Only `.missingFact` is touched; every other conclusion passes
        /// through unchanged.
        static func apply(
            to result: Result,
            payload: ArchivistQueryAST.Graph,
            graphResult: ArchivistGraphResult,
            graph: GedcomFamilyGraph?,
            context: Context
        ) -> Result {
            guard graphResult.conclusion == .missingFact else { return result }
            var sentences: [String] = [result.prose]
            if let note = coverageNote(relation: payload.relation, graph: graph) {
                sentences.append(note)
            }
            var citations: [KnowledgeCitation] = []
            var itemIDs: [String] = []
            if let index = context.cyberBrain {
                let found = passages(
                    subjectGedcomID: graphResult.evidence?.subjectID,
                    subjectName: graphResult.evidence?.subjectName ?? payload.people.first ?? "",
                    relation: payload.relation,
                    index: index)
                for (offset, entry) in found.enumerated() {
                    let lead = offset == 0 ? "But " : "And "
                    sentences.append(
                        lead + attributionLead(entry.source, item: entry.item)
                        + ": “" + entry.item.text + "”")
                    itemIDs.append(entry.item.id)
                    if let source = entry.source,
                       !citations.contains(where: { $0.id == source.id }) {
                        citations.append(KnowledgeCitation(
                            id: source.id, title: source.title,
                            attribution: source.attribution, locator: source.locator))
                    }
                }
            }
            guard sentences.count > 1 else { return result }
            let answered = !itemIDs.isEmpty
            var basis = result.basisLine
            if answered {
                basis += " Family knowledge: " + itemIDs.joined(separator: ", ") + "."
            }
            let prose = sentences.joined(separator: " ")
            return Result(
                route: result.route,
                outcome: answered ? .answered : result.outcome,
                prose: prose,
                basisLine: basis,
                queryDescription: result.queryDescription,
                citations: result.citations,
                knowledgeCitations: result.knowledgeCitations + citations,
                catalogPersonName: result.catalogPersonName,
                clarification: result.clarification,
                matchCount: result.matchCount,
                mediaAction: result.mediaAction,
                offeredActions: result.offeredActions,
                // Fixed text: a quoted family passage and a statement about
                // the tree's reach must not be re-phrased (eval pass 2: the
                // composer turned the coverage note into "it likely stops…").
                answerPlan: HallieAnswerPlan(route: result.route, shape: .fixed, fallbackText: prose),
                composedBy: result.composedBy,
                transcriptText: nil,
                subjectLifeStatus: result.subjectLifeStatus)
        }

        /// A not-found answer that explains the tree's reach and offers the
        /// one thing that would fix it: telling Hallie about the person.
        static func notFoundOffer(_ result: Result, typed: String,
                                  graph: GedcomFamilyGraph?) -> Result {
            // No "covers people born up to YYYY" here either (see
            // coverageNote): the tree's latest date is not its reach.
            var prose = result.prose
            let name = typed.prefix(1).uppercased() + typed.dropFirst()
            prose += " If you tell me about \(name) — “let me tell you about \(name)” — I'll remember it."
            return Result(
                route: result.route,
                outcome: result.outcome,
                prose: prose,
                basisLine: result.basisLine,
                queryDescription: result.queryDescription,
                citations: result.citations,
                knowledgeCitations: result.knowledgeCitations,
                catalogPersonName: result.catalogPersonName,
                clarification: result.clarification,
                matchCount: result.matchCount,
                mediaAction: result.mediaAction,
                offeredActions: result.offeredActions,
                answerPlan: result.answerPlan,
                composedBy: result.composedBy,
                transcriptText: result.transcriptText,
                attachments: result.attachments,
                performsFirstOfferedAction: result.performsFirstOfferedAction,
                subjectLifeStatus: result.subjectLifeStatus,
                refinableQuery: result.refinableQuery)
        }
    }
}
