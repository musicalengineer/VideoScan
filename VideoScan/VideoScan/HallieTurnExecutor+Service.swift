// HallieTurnExecutor+Service.swift
// The answer to a military-service question (HallieServiceQuestion) is
// what the family said about it — CyberBrain passages that mention
// service, quoted and attributed — never the tree's birth-and-death
// biography and never a search for "marine corps" as a surname.
//
// The subject arrives already resolved by the ordinary person-fact road:
// a which-one chip (`selectedIdentity`), the owner's relative from the
// tree (executeRelativeFact → a GEDCOM chip), or a typed name. A tree
// person reaches CyberBrain by the GEDCOM pointer when the archive
// declares it and by exact name otherwise — the live archive still
// carries Ancestry pointers the merged FamilySearch tree does not know
// (the "GEDCOM bridge is not available" line), and Richard Harding Breen
// Sr must not lose his Marine Corps passage to that gap.

import Foundation
import VideoScanCore

extension HallieTurnExecutor {

    enum ServiceAnswer {

        static let topicDescription = "topic=military-service"

        /// Nil when the question is not about service, or when the subject
        /// cannot be pinned to anyone — the ordinary biography path then
        /// offers its which-one chips or near-miss suggestions, and the
        /// continuation lands here again with a selection.
        static func execute(
            payload: ArchivistQueryAST.Graph,
            request: Request,
            context: Context
        ) -> Result? {
            guard payload.operation == .biography else { return nil }
            let question = request.intent.originalQuestion
            if payload.people.isEmpty, HallieServiceQuestion.isFamilyWideAsk(question) {
                return familyWide(context: context)
            }
            guard HallieServiceQuestion.isServiceQuestion(question),
                  let requestedName = payload.people.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !requestedName.isEmpty else { return nil }
            guard let index = context.cyberBrain else { return nil }

            var person: CyberBrainPerson?
            var treeName: String?
            switch request.selectedIdentity {
            case .cyberBrainPersonID(let id):
                person = index.person(id: id)
            case .gedcomPersonID(let id):
                let treePerson = context.graph?.people[id]
                treeName = treePerson?.name
                person = index.people(gedcomPersonID: id).first
                if person == nil, let name = treePerson?.name,
                   case .resolved(let byName) = index.resolve(name) {
                    person = byName
                }
            case .profileStableID:
                return nil
            case nil:
                switch index.resolve(requestedName) {
                case .resolved(let found): person = found
                case .ambiguous: return nil
                case .notFound:
                    // The family has no passage about this name. When the
                    // name is someone we know, say so honestly instead of
                    // answering a different question with the tree's
                    // biography; an unknown name keeps the ordinary
                    // not-found flow (suggestions, roster, offer).
                    guard isKnownPerson(requestedName, context: context) else { return nil }
                    return nothingRecorded(about: displayName(requestedName), requested: requestedName)
                }
            }
            guard let person else {
                return nothingRecorded(about: treeName ?? displayName(requestedName), requested: requestedName)
            }
            let passages = servicePassages(for: person, index: index)
            guard !passages.isEmpty else {
                return nothingRecorded(about: person.canonicalName, requested: requestedName)
            }
            let sentences = passages.map { quoted($0.item, source: $0.source) }
            return answered(
                prose: sentences.joined(separator: " "),
                passages: passages,
                index: index,
                queryDescription: "shape=graph operation=biography person=\(requestedName) \(topicDescription)",
                catalogPersonName: person.canonicalName)
        }

        /// Everyone the family has a service passage about.
        private static func familyWide(context: Context) -> Result? {
            guard let index = context.cyberBrain else { return nil }
            var found: [(person: CyberBrainPerson, passages: [Passage])] = []
            for person in index.archive.people {
                let passages = servicePassages(for: person, index: index)
                if !passages.isEmpty { found.append((person, passages)) }
            }
            found.sort { $0.person.canonicalName < $1.person.canonicalName }
            let queryDescription = "shape=graph operation=biography scope=family \(topicDescription)"
            guard !found.isEmpty else {
                return Result(
                    route: .graph, outcome: .declined,
                    prose: "I don't have anything from the family about military service yet. If you tell me — “let me tell you about someone” — I'll remember it.",
                    basisLine: "Basis: Breen Family CyberBrain; no passage mentions service.",
                    queryDescription: queryDescription, citations: [], catalogPersonName: nil,
                    answerPlan: nil)
            }
            let limited = found.prefix(6)
            let sentences = limited.map { entry in
                entry.person.canonicalName + " — " + quoted(entry.passages[0].item, source: entry.passages[0].source)
            }
            let lead = limited.count == 1
                ? "One person the family told me about served: "
                : "The family told me about \(limited.count) people who served: "
            return answered(
                prose: lead + sentences.joined(separator: " "),
                passages: limited.flatMap { $0.passages.prefix(1) },
                index: index,
                queryDescription: queryDescription,
                catalogPersonName: limited.count == 1 ? limited.first?.person.canonicalName : nil)
        }

        typealias Passage = (item: CyberBrainItem, source: CyberBrainSource?)

        static func servicePassages(for person: CyberBrainPerson, index: CyberBrainIndex,
                                    limit: Int = 3) -> [Passage] {
            index.evidence(for: person.id, privacyCeiling: appPrivacyCeiling, limit: 50)
                .filter { HallieServiceQuestion.mentionsService($0.text) }
                .prefix(limit)
                .map { ($0, $0.sourceIDs.first.flatMap { index.source(id: $0) }) }
        }

        private static func quoted(_ item: CyberBrainItem, source: CyberBrainSource?) -> String {
            let lead = FamilyKnowledgeSupplement.attributionLead(source, item: item)
            return lead.prefix(1).uppercased() + lead.dropFirst() + ": “" + item.text + "”"
        }

        private static func answered(
            prose: String, passages: [Passage], index: CyberBrainIndex,
            queryDescription: String, catalogPersonName: String?
        ) -> Result {
            var citations: [KnowledgeCitation] = []
            for passage in passages {
                guard let source = passage.source,
                      !citations.contains(where: { $0.id == source.id }) else { continue }
                citations.append(KnowledgeCitation(
                    id: source.id, title: source.title,
                    attribution: source.attribution, locator: source.locator))
            }
            let itemIDs = passages.map(\.item.id).joined(separator: ", ")
            return Result(
                route: .graph, outcome: .answered, prose: prose,
                basisLine: "Basis: Breen Family CyberBrain; family knowledge: \(itemIDs).",
                queryDescription: queryDescription, citations: [],
                knowledgeCitations: citations, catalogPersonName: catalogPersonName,
                // Quoted family passages are never re-phrased by the model.
                answerPlan: HallieAnswerPlan(route: .graph, shape: .fixed, fallbackText: prose))
        }

        private static func nothingRecorded(about name: String, requested: String) -> Result {
            Result(
                route: .graph, outcome: .declined,
                prose: "I don't have anything from the family about \(name)'s military service. If you tell me — “let me tell you about \(name)” — I'll remember it.",
                basisLine: "Basis: Breen Family CyberBrain; no passage about \(name) mentions service. The family tree records no service facts.",
                queryDescription: "shape=graph operation=biography person=\(requested) \(topicDescription)",
                citations: [], catalogPersonName: nil)
        }

        /// "dad" → "Dad", "my dad" → "your dad"; a typed name keeps its case.
        private static func displayName(_ requested: String) -> String {
            let lower = requested.lowercased()
            if lower.hasPrefix("my ") { return "your " + requested.dropFirst(3) }
            if lower.hasPrefix("our ") { return "your " + requested.dropFirst(4) }
            if RelativeFactSubject.bareKinWords[lower] != nil { return "your " + lower }
            return requested
        }
    }
}
