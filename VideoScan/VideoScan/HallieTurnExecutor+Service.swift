// HallieTurnExecutor+Service.swift
// Military service: one person's ("did my dad serve?"), the whole family's
// ("who in our family served in the Civil War?"), and the offer after a
// biography ("Would you like to hear how Richard Harding Breen Sr served
// his country?") whose "yes" tells the brief story.
//
// Where the answer comes from, in order:
//   1. the family's structured service records (CyberBrain life events that
//      carry `service`, Rick 2026-09-23) — the brief story, verbatim, and
//      one source line;
//   2. older free-text passages that mention service (2026-09-11), quoted
//      and attributed, for people with no structured record;
//   3. military facts the family tree itself records (`_MILT`, a typed
//      military EVEN — GedcomFamilyGraph+Military), verbatim, cited to the
//      tree. Never inferred from birth years: a person is listed under a
//      war only for a fact whose own words name it or whose own DATE falls
//      in its years (WorldKnowledge), and the fact is quoted as dated.
// Never the tree's birth-and-death biography, never a search for "marine
// corps" as a surname, and never a model's phrasing: every answer here is
// `.fixed` (HallieAnswerPlan) — the composer is not asked, so it cannot add
// a fact.
//
// The subject of a one-person ask arrives already resolved by the ordinary
// person-fact road: a which-one chip (`selectedIdentity`), the owner's
// relative from the tree (executeRelativeFact → a GEDCOM chip), or a typed
// name. A tree person reaches CyberBrain by the GEDCOM pointer when the
// archive declares it and by exact name otherwise — the live archive still
// carries Ancestry pointers the merged FamilySearch tree does not know.
//
// Memory: a family-wide ask walks CyberBrain (tens of people) and the
// tree's people once (39k today; each person's military list is empty for
// all but a few hundred). No copies of the tree; results are capped
// (`maximumListed`) before any string is built.

import Foundation
import VideoScanCore

extension HallieTurnExecutor {

    enum ServiceAnswer {

        static let topicDescription = "topic=military-service"
        /// Names listed in one family-wide answer before "and N more".
        static let maximumListed = 6
        /// Stories told for one person in one answer.
        static let maximumStories = 3
        static let treeCitationID = "gedcom:military-facts"

        // MARK: - Entry

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
            if payload.people.isEmpty, let ask = HallieServiceQuestion.familyAsk(question) {
                return familyWide(ask, context: context)
            }
            guard HallieServiceQuestion.isServiceQuestion(question),
                  let requestedName = payload.people.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !requestedName.isEmpty else { return nil }
            let index = context.cyberBrain

            var person: CyberBrainPerson?
            var treePerson: GedcomFamilyGraph.Person?
            switch request.selectedIdentity {
            case .cyberBrainPersonID(let id):
                guard let found = index?.person(id: id) else { return nil }
                person = found
                treePerson = bridgedTreePerson(for: found, graph: context.graph)
            case .gedcomPersonID(let id):
                treePerson = context.graph?.people[id]
                person = index?.people(gedcomPersonID: id).first
                if person == nil, let name = treePerson?.name, let index,
                   case .resolved(let byName) = index.resolve(name) {
                    person = byName
                }
            case .profileStableID:
                return nil
            case nil:
                if let index {
                    switch index.resolve(requestedName) {
                    case .resolved(let found): person = found
                    case .ambiguous: return nil
                    case .notFound: break
                    }
                }
                if let person {
                    treePerson = bridgedTreePerson(for: person, graph: context.graph)
                } else {
                    let named = exactTreePeople(named: requestedName, graph: context.graph)
                    if named.count > 1 { return nil }          // which-one chips, then back here
                    treePerson = named.first
                    // The family has no passage about this name and the
                    // tree no single record. When the name is someone we
                    // know, say so honestly instead of answering a
                    // different question with the tree's biography; an
                    // unknown name keeps the ordinary not-found flow.
                    if treePerson == nil {
                        guard isKnownPerson(requestedName, context: context) else { return nil }
                        return nothingRecorded(about: displayName(requestedName), requested: requestedName)
                    }
                }
            }
            guard person != nil || treePerson != nil else {
                return nothingRecorded(about: displayName(requestedName), requested: requestedName)
            }
            return personAnswer(person: person, treePerson: treePerson,
                                requested: requestedName, context: context)
        }

        // MARK: - One person

        private static func personAnswer(
            person: CyberBrainPerson?,
            treePerson: GedcomFamilyGraph.Person?,
            requested: String,
            context: Context
        ) -> Result {
            let name = person?.canonicalName ?? treePerson?.name ?? displayName(requested)
            let queryDescription = "shape=graph operation=biography person=\(requested) \(topicDescription)"
            var sentences: [String] = []
            var citations: [KnowledgeCitation] = []
            var itemIDs: [String] = []

            if let person, let index = context.cyberBrain {
                let stories = storyItems(for: person, index: index)
                if !stories.isEmpty {
                    for item in stories {
                        let source = item.sourceIDs.first.flatMap { index.source(id: $0) }
                        sentences.append(HallieServiceStory.story(item: item, source: source))
                        cite(item, index: index, into: &citations)
                        itemIDs.append(item.id)
                    }
                } else {
                    for passage in servicePassages(for: person, index: index) {
                        sentences.append(quoted(passage.item, source: passage.source, person: person))
                        cite(passage.item, index: index, into: &citations)
                        itemIDs.append(passage.item.id)
                    }
                }
            }
            if let treePerson, !treePerson.militaryFacts.isEmpty,
               let sentence = HallieServiceStory.treeSentence(name: name, facts: treePerson.militaryFacts) {
                sentences.append(sentence)
                citations.append(treeCitation(for: treePerson))
                itemIDs.append("gedcom:\(treePerson.id)")
            }
            guard !sentences.isEmpty else {
                return nothingRecorded(about: name, requested: requested)
            }
            let prose = sentences.joined(separator: " ")
            return Result(
                route: .graph, outcome: .answered, prose: prose,
                basisLine: basisLine(itemIDs: itemIDs),
                queryDescription: queryDescription, citations: [],
                knowledgeCitations: citations, catalogPersonName: name,
                // The family's own words are never re-phrased by the model.
                answerPlan: HallieAnswerPlan(route: .graph, shape: .fixed, fallbackText: prose))
        }

        // MARK: - The whole family

        private struct Listed {
            let name: String
            let line: String
            let storyPerson: CyberBrainPerson?
            let citations: [KnowledgeCitation]
            let itemIDs: [String]
        }

        /// What the family itself said, for one family-wide ask.
        private struct FamilyStories {
            var listed: [Listed] = []
            /// Wars the family HAS stories from (for the "no record" line).
            var storiedWars: Set<HallieServiceQuestion.War> = []
            /// Tree records / names already listed from the family's words.
            var treeIDs: Set<String> = []
            var names: Set<String> = []
        }

        typealias TreeMatch = (person: GedcomFamilyGraph.Person, facts: [GedcomFamilyGraph.MilitaryFact])

        /// Everyone the family has a service record or passage about — for
        /// one war / branch when the question names one — plus the tree's
        /// facts, then the offer.
        private static func familyWide(_ ask: HallieServiceQuestion.FamilyAsk, context: Context) -> Result {
            let stories = familyStories(ask, context: context)
            let tree = treeMatches(ask, graph: context.graph, excluding: stories)
            let scope = ask.war?.name ?? ask.otherWar ?? ask.branch?.name
            let queryDescription = "shape=graph operation=biography scope=family \(topicDescription)"
                + ((ask.war?.name ?? ask.otherWar).map { " war=\($0)" } ?? "")
                + (ask.branch.map { " branch=\($0.rawValue)" } ?? "")
            guard !stories.listed.isEmpty || !tree.isEmpty else {
                return nothingForWar(scope: scope, isWar: ask.branch == nil,
                                     storiedWars: stories.storiedWars, queryDescription: queryDescription)
            }
            var paragraphs: [String] = []
            var citations: [KnowledgeCitation] = []
            var itemIDs: [String] = []
            let shown = Array(stories.listed.prefix(maximumListed))
            if !shown.isEmpty {
                paragraphs.append(familyLead(count: shown.count, scope: scope) + " " + shown.map(\.line).joined(separator: " "))
                for entry in shown {
                    for citation in entry.citations where !citations.contains(where: { $0.id == citation.id }) {
                        citations.append(citation)
                    }
                    itemIDs += entry.itemIDs
                }
            }
            if !tree.isEmpty {
                paragraphs.append(treeParagraph(tree, scope: scope, afterStories: !shown.isEmpty))
                citations.append(KnowledgeCitation(
                    id: treeCitationID, title: "Imported family tree (GEDCOM) — military facts",
                    attribution: nil, locator: nil))
                itemIDs.append(treeCitationID)
            }
            let prose = paragraphs.joined(separator: " ")
            let result = Result(
                route: .graph, outcome: .answered, prose: prose,
                basisLine: basisLine(itemIDs: itemIDs),
                queryDescription: queryDescription, citations: [],
                knowledgeCitations: citations,
                catalogPersonName: shown.count == 1 && tree.isEmpty ? shown.first?.name : nil,
                answerPlan: HallieAnswerPlan(route: .graph, shape: .fixed, fallbackText: prose))
            return offeringStories(on: result, people: shown.compactMap(\.storyPerson), context: context)
        }

        private static func familyStories(_ ask: HallieServiceQuestion.FamilyAsk, context: Context) -> FamilyStories {
            var found = FamilyStories()
            guard let index = context.cyberBrain else { return found }
            for person in index.archive.people.sorted(by: { $0.canonicalName < $1.canonicalName }) {
                let stories = storyItems(for: person, index: index)
                found.storiedWars.formUnion(stories.compactMap { $0.service?.conflict.flatMap(HallieServiceQuestion.War.init) })
                let entry = stories.isEmpty
                    ? passageEntry(for: person, ask: ask, index: index)
                    : storyEntry(for: person, stories: stories, ask: ask, index: index)
                guard let entry else { continue }
                found.listed.append(entry)
                // Listed from the family's own words: the tree's facts for
                // the same person are not listed a second time.
                if let tree = bridgedTreePerson(for: person, graph: context.graph) { found.treeIDs.insert(tree.id) }
                found.names.insert(PersonResolver.normalize(person.canonicalName))
            }
            return found
        }

        /// A structured record for the war / branch asked about.
        private static func storyEntry(for person: CyberBrainPerson, stories: [CyberBrainItem],
                                       ask: HallieServiceQuestion.FamilyAsk, index: CyberBrainIndex) -> Listed? {
            let matching = stories.filter { item in
                guard let record = item.service else { return false }
                if let branch = ask.branch, !branch.matches(record.force) { return false }
                if let war = ask.war { return record.conflict == war.conflict }
                return ask.otherWar == nil
            }
            guard let record = matching.first?.service else { return nil }
            var citations: [KnowledgeCitation] = []
            matching.forEach { cite($0, index: index, into: &citations) }
            return Listed(name: person.canonicalName,
                          line: HallieServiceStory.summaryLine(name: person.canonicalName, record: record),
                          storyPerson: person, citations: citations, itemIDs: matching.map(\.id))
        }

        /// An older free-text passage: listed under a war / branch only when
        /// its own words name it.
        private static func passageEntry(for person: CyberBrainPerson, ask: HallieServiceQuestion.FamilyAsk,
                                         index: CyberBrainIndex) -> Listed? {
            guard ask.otherWar == nil else { return nil }
            let passage = servicePassages(for: person, index: index).first { passage in
                if let branch = ask.branch, !branch.matches(passage.item.text) { return false }
                guard let war = ask.war else { return true }
                return HallieServiceQuestion.war(namedIn: passage.item.text) == war
            }
            guard let passage else { return nil }
            var citations: [KnowledgeCitation] = []
            cite(passage.item, index: index, into: &citations)
            return Listed(name: person.canonicalName,
                          line: person.canonicalName + " — " + quoted(passage.item, source: passage.source, person: person),
                          storyPerson: nil, citations: citations, itemIDs: [passage.item.id])
        }

        /// The tree's own military facts for the ask, minus people already
        /// listed from the family's words. Most recent generations first
        /// (nearest to the family today), then by name — stable run to run.
        private static func treeMatches(_ ask: HallieServiceQuestion.FamilyAsk, graph: GedcomFamilyGraph?,
                                        excluding stories: FamilyStories) -> [TreeMatch] {
            guard ask.otherWar == nil, let graph else { return [] }
            var matches: [TreeMatch] = []
            for person in graph.people.values where !person.militaryFacts.isEmpty {
                if stories.treeIDs.contains(person.id)
                    || stories.names.contains(PersonResolver.normalize(person.name)) { continue }
                let facts = person.militaryFacts.filter { fact in
                    if let branch = ask.branch,
                       !branch.matches([fact.value, fact.type, fact.note].compactMap { $0 }.joined(separator: " ")) {
                        return false
                    }
                    guard let war = ask.war else { return true }
                    return HallieServiceStory.war(of: fact, birthYear: person.birthYear) == war
                }
                if !facts.isEmpty { matches.append((person, facts)) }
            }
            return matches.sorted {
                let a = $0.person.birthYear ?? Int.min, b = $1.person.birthYear ?? Int.min
                return a != b ? a > b : $0.person.name < $1.person.name
            }
        }

        private static func familyLead(count: Int, scope: String?) -> String {
            let people = count == 1 ? "one person" : "\(count) people"
            return "The family has told me about \(people) who served" + (scope.map { " in \($0)" } ?? "") + ":"
        }

        /// A fact is tied to a war by its own words or its own date
        /// (HallieServiceStory.war(of:)) — said, not implied.
        private static func treeParagraph(_ tree: [TreeMatch], scope: String?, afterStories: Bool) -> String {
            let shown = tree.prefix(maximumListed)
            let lead = afterStories ? "The family tree also records" : "The family tree records"
            let tied = scope.map { " tied to \($0) by its own words or date" } ?? ""
            var sentence: String
            if tree.count == 1 {
                sentence = "\(lead) a military fact\(tied) for one person: "
            } else {
                sentence = "\(lead) military facts\(tied) for \(tree.count) people"
                    + (tree.count > shown.count ? ", including: " : ": ")
            }
            return sentence + shown.map { HallieServiceStory.treeListLine(person: $0.person, facts: $0.facts) }
                .joined(separator: "; ") + "."
        }

        /// One story → "Would you like to hear his story?"; several → pick a
        /// name. A tree-only answer offers nothing (there is no story).
        private static func offeringStories(on result: Result, people: [CyberBrainPerson],
                                            context: Context) -> Result {
            guard let first = people.first else { return result }
            let offer = people.count == 1
                ? "Would you like to hear \(storyPronounPhrase(first, context: context)) story?"
                : "Whose story would you like to hear?"
            let clarification = makeClarification(
                intent: storyIntent(for: first), stage: .serviceOffer,
                candidates: people.map(storyCandidate), context: context)
            return result.offering(offer, clarification: clarification)
        }

        /// "his" story / "her" story / "Chris O'Connor's" story.
        private static func storyPronounPhrase(_ person: CyberBrainPerson, context: Context) -> String {
            let sex = bridgedTreePerson(for: person, graph: context.graph)?.sex
            return HallieServiceStory.possessivePronoun(sex: sex)
                ?? HallieServiceStory.possessive(person.canonicalName)
        }

        /// No record for the war asked about: say so plainly, point at the
        /// stories the family DOES have, and invite a new one.
        private static func nothingForWar(scope: String?, isWar: Bool,
                                          storiedWars: Set<HallieServiceQuestion.War>,
                                          queryDescription: String) -> Result {
            var prose: String
            if let scope {
                prose = "Nobody in the family has told me about service in \(scope), and the family tree I have records "
                    + (isWar ? "no military service from those years." : "none.")
                let others = HallieServiceQuestion.War.allCases.filter(storiedWars.contains).map(\.name)
                if !others.isEmpty {
                    prose += " I do have family stories from " + joinedList(others) + " — ask me about those."
                }
            } else {
                prose = "I don't have anything from the family about military service yet, and the family tree I have records none."
            }
            prose += " If you know of someone who served, tell me — say “let me tell you about” and their name — and I'll remember it."
            return Result(
                route: .graph, outcome: .declined, prose: prose,
                basisLine: "Basis: Breen Family CyberBrain has no service record or passage for this, and the family tree records no military fact for it.",
                queryDescription: queryDescription, citations: [], catalogPersonName: nil,
                answerPlan: HallieAnswerPlan(route: .graph, shape: .fixed, fallbackText: prose))
        }

        // MARK: - The offer after a biography

        /// The biography answer with the service offer appended, or the same
        /// answer when the subject has no structured story, the story is
        /// already in the biography, or anything else is pending. One
        /// question at a time: the offer takes the answer's single
        /// follow-up question (the gallery offer then steps aside).
        static func offeringStory(
            on result: Result,
            payload: ArchivistQueryAST.Graph,
            request: Request,
            context: Context
        ) -> Result {
            guard payload.operation == .biography, result.route == .graph,
                  result.outcome == .answered, result.clarification == nil,
                  result.queryDescription?.contains(topicDescription) != true,
                  let index = context.cyberBrain,
                  let name = result.catalogPersonName,
                  let person = biographySubject(named: name, request: request, index: index, graph: context.graph),
                  let first = storyItems(for: person, index: index).first,
                  let record = first.service,
                  // A person whose only knowledge IS the story had it told
                  // as the biography: nothing left to offer.
                  !result.prose.contains(first.text) else { return result }
            let pronoun = HallieServiceStory.possessivePronoun(
                sex: bridgedTreePerson(for: person, graph: context.graph)?.sex)
            let sentence = HallieServiceStory.offerSentence(
                name: person.canonicalName, record: record, pronoun: pronoun)
            let clarification = makeClarification(
                intent: storyIntent(for: person), stage: .serviceOffer,
                candidates: [storyCandidate(person)], context: context)
            return result.offering(sentence, clarification: clarification)
        }

        /// Which CyberBrain person a finished biography was about: the chip
        /// the user picked, else the one person whose canonical name or
        /// alias IS the answer's subject. A tree pick with no declared
        /// pointer bridges by name only when the tree has exactly one
        /// person of that name — never onto a namesake.
        private static func biographySubject(
            named name: String, request: Request, index: CyberBrainIndex, graph: GedcomFamilyGraph?
        ) -> CyberBrainPerson? {
            switch request.selectedIdentity {
            case .cyberBrainPersonID(let id):
                return index.person(id: id)
            case .gedcomPersonID(let id):
                if let declared = index.people(gedcomPersonID: id).first { return declared }
                guard exactTreePeople(named: name, graph: graph).count == 1 else { return nil }
                return exactCyberBrainPerson(named: name, index: index)
            case .profileStableID, nil:
                return exactCyberBrainPerson(named: name, index: index)
            }
        }

        private static func exactCyberBrainPerson(named name: String, index: CyberBrainIndex) -> CyberBrainPerson? {
            let key = FamilyIdentityText.normalized(name)
            let matches = index.archive.people.filter { person in
                ([person.canonicalName] + person.aliases).contains { FamilyIdentityText.normalized($0) == key }
            }
            return matches.count == 1 ? matches[0] : nil
        }

        /// The intent a "yes" resumes: this person's service, by name, with
        /// the chosen identity carried by the continuation.
        static func storyIntent(for person: CyberBrainPerson) -> Intent {
            .init(originalQuestion: "tell me about \(HallieServiceStory.possessive(person.canonicalName)) military service",
                  ast: .graph(.init(people: [person.canonicalName], operation: .biography)))
        }

        private static func storyCandidate(_ person: CyberBrainPerson) -> Candidate {
            Candidate(id: .cyberBrainPersonID(person.id),
                      canonicalName: person.canonicalName, label: person.canonicalName)
        }

        // MARK: - Evidence

        /// The person's structured service stories, capped.
        static func storyItems(for person: CyberBrainPerson, index: CyberBrainIndex) -> [CyberBrainItem] {
            Array(index.serviceItems(for: person.id, privacyCeiling: appPrivacyCeiling).prefix(maximumStories))
        }

        typealias Passage = (item: CyberBrainItem, source: CyberBrainSource?)

        static func servicePassages(for person: CyberBrainPerson, index: CyberBrainIndex,
                                    limit: Int = 3) -> [Passage] {
            index.evidence(for: person.id, privacyCeiling: appPrivacyCeiling, limit: 50)
                .filter { $0.service == nil && !serviceSentences(in: $0.text, about: person).isEmpty }
                .prefix(limit)
                .map { ($0, $0.sourceIDs.first.flatMap { index.source(id: $0) }) }
        }

        /// The sentences of a passage that speak of THIS person's service:
        /// a service word, and the person's own name (or a sentence-initial
        /// "he"/"she") in the same sentence. A research note about Ellen that
        /// says her husband "was … a soldier" is not about Ellen's service
        /// (live data, 2026-09-23).
        static func serviceSentences(in text: String, about person: CyberBrainPerson) -> [String] {
            let names = Set(([person.canonicalName] + person.aliases.filter { !CyberBrainIndex.isPossessiveAlias(FamilyIdentityText.normalized($0)) })
                .flatMap { FamilyIdentityText.tokens($0) }
                .filter { $0.count >= 3 })
            return sentences(of: text).filter { sentence in
                guard HallieServiceQuestion.mentionsService(sentence) else { return false }
                let words = Set(FamilyIdentityText.tokens(sentence))
                if !words.isDisjoint(with: names) { return true }
                let lower = sentence.lowercased()
                return lower.hasPrefix("he ") || lower.hasPrefix("she ")
            }
        }

        private static func sentences(of text: String) -> [String] {
            text.replacingOccurrences(of: "\n", with: ". ")
                .components(separatedBy: ". ")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        /// Passages longer than this are quoted by their service sentences.
        static let maximumQuotedCharacters = 280

        /// The tree record a CyberBrain person stands for: the declared
        /// pointer when the tree knows it, else the ONE tree person with
        /// exactly that name; nil when there is none or several.
        static func bridgedTreePerson(for person: CyberBrainPerson,
                                      graph: GedcomFamilyGraph?) -> GedcomFamilyGraph.Person? {
            guard let graph else { return nil }
            if let id = person.gedcomPersonID, let found = graph.people[id] { return found }
            let named = exactTreePeople(named: person.canonicalName, graph: graph)
            return named.count == 1 ? named[0] : nil
        }

        /// Tree people whose name (or an alternate name) IS `name`. Uses the
        /// tree's name index, then an exact comparison.
        static func exactTreePeople(named name: String, graph: GedcomFamilyGraph?) -> [GedcomFamilyGraph.Person] {
            guard let graph else { return [] }
            let key = PersonResolver.normalize(name)
            guard !key.isEmpty else { return [] }
            return graph.people(namedLike: name).filter { person in
                ([person.name] + person.alternateNames).contains { PersonResolver.normalize($0) == key }
            }
        }

        private static func quoted(_ item: CyberBrainItem, source: CyberBrainSource?,
                                   person: CyberBrainPerson? = nil) -> String {
            let lead = FamilyKnowledgeSupplement.attributionLead(source, item: item)
            var text = item.text
            if text.count > maximumQuotedCharacters, let person {
                let picked = serviceSentences(in: text, about: person)
                if !picked.isEmpty {
                    text = picked.map { $0.hasSuffix(".") ? $0 : $0 + "." }.joined(separator: " ") + " …"
                }
            }
            return lead.prefix(1).uppercased() + lead.dropFirst() + ": “" + text + "”"
        }

        private static func cite(_ item: CyberBrainItem, index: CyberBrainIndex,
                                 into citations: inout [KnowledgeCitation]) {
            for sourceID in item.sourceIDs {
                guard let source = index.source(id: sourceID),
                      !citations.contains(where: { $0.id == source.id }) else { continue }
                citations.append(KnowledgeCitation(
                    id: source.id, title: source.title,
                    attribution: source.attribution, locator: source.locator))
            }
        }

        private static func treeCitation(for person: GedcomFamilyGraph.Person) -> KnowledgeCitation {
            KnowledgeCitation(id: "gedcom:\(person.id)", title: "Imported family tree (GEDCOM)",
                              attribution: nil, locator: nil)
        }

        private static func basisLine(itemIDs: [String]) -> String {
            let family = itemIDs.filter { !$0.hasPrefix("gedcom:") }
            let tree = itemIDs.filter { $0.hasPrefix("gedcom:") }
            var parts: [String] = []
            if !family.isEmpty { parts.append("Breen Family CyberBrain; family knowledge: \(family.joined(separator: ", "))") }
            if !tree.isEmpty { parts.append("family tree military facts: \(tree.joined(separator: ", "))") }
            return "Basis: " + parts.joined(separator: "; ") + "."
        }

        private static func nothingRecorded(about name: String, requested: String) -> Result {
            let prose = "I don't have anything from the family about \(name)'s military service, and the family tree records none. If you tell me — “let me tell you about \(name)” — I'll remember it."
            return Result(
                route: .graph, outcome: .declined,
                prose: prose,
                basisLine: "Basis: Breen Family CyberBrain has no service record or passage about \(name); the family tree records no military fact for them.",
                queryDescription: "shape=graph operation=biography person=\(requested) \(topicDescription)",
                citations: [], catalogPersonName: nil,
                answerPlan: HallieAnswerPlan(route: .graph, shape: .fixed, fallbackText: prose))
        }

        /// "dad" → "your dad", "my dad" → "your dad"; a typed name keeps its case.
        private static func displayName(_ requested: String) -> String {
            let lower = requested.lowercased()
            if lower.hasPrefix("my ") { return "your " + requested.dropFirst(3) }
            if lower.hasPrefix("our ") { return "your " + requested.dropFirst(4) }
            if RelativeFactSubject.bareKinWords[lower] != nil { return "your " + lower }
            return requested
        }

        private static func joinedList(_ items: [String]) -> String {
            switch items.count {
            case 0: return ""
            case 1: return items[0]
            case 2: return items[0] + " and " + items[1]
            default: return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
            }
        }
    }
}

extension HallieTurnExecutor.Result {
    /// No which-one question is pending: either nothing is, or only an
    /// OFFER Hallie made after a complete answer (gallery / service story).
    /// Presentation that belongs to a finished biography — its photo, its
    /// kind word — keys on this, not on `clarification == nil`.
    var needsNoChoice: Bool {
        clarification == nil || clarification?.stage.isOffer == true
    }
}
