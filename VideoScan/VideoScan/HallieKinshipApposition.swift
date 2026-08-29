// HallieKinshipApposition.swift
// "Find rick's grandma muriel and tell me about her" (live 2026-08-26
// 23:35Z → "A family-tree question must identify exactly one person.").
//
// A kinship word followed by a name is ONE person, described twice: the
// relation narrows the tree to a set (Rick's grandmothers) and the name
// picks from that set. The translator handed the executor two people and
// the executor's guard leaked as prose. This file is the single parser for
// that shape and the single answerer for it, used by
//   - HallieLineageQuestion.detect (the model-free front door),
//   - ArchivistQuestionParser (the older chat-window kinship route — it
//     now steps aside so this shape is never read as "<name>'s father"),
//   - HallieTurnExecutor's graph route (when the model still produces
//     `people: [rick, muriel], relation: grandmother`).
//
// C++ readers: `Kin` is a tagged union (std::variant) over the three
// traversal shapes the graph already has; `parse` is a pure function of
// the text, `answer` is where the tree is consulted.

import Foundation
import VideoScanCore

struct HallieKinshipApposition: Equatable, Sendable {
    enum Kin: Equatable, Sendable {
        /// father, mother, brother, son… (`GedcomFamilyGraph.relatives`).
        case single(GedcomFamilyGraph.Relation)
        /// grandmother, uncle, cousin, in-laws… up to great-great.
        case extended(GedcomFamilyGraph.ExtendedRelation, side: GedcomFamilyGraph.KinshipSide?)
        /// great×3 and beyond: exactly `depth` generations up.
        case deep(depth: Int, sex: String?, side: GedcomFamilyGraph.KinshipSide?)

        /// The graph AST's closed vocabulary → the traversal shape.
        init?(astRelation: ArchivistQueryAST.Graph.Relation, side: ArchivistQueryAST.Graph.Side?) {
            let graphSide: GedcomFamilyGraph.KinshipSide? = side.map { $0 == .maternal ? .maternal : .paternal }
            if astRelation.isSingleHop {
                guard side == nil, let r = GedcomFamilyGraph.Relation(rawValue: astRelation.rawValue) else { return nil }
                self = .single(r)
            } else {
                guard let e = GedcomFamilyGraph.ExtendedRelation(rawValue: astRelation.rawValue) else { return nil }
                self = .extended(e, side: graphSide)
            }
        }
    }

    /// Nil = the owner ("my uncle Bill").
    let possessor: String?
    let kin: Kin
    /// The relation as the family said it ("grandma"), for the prose.
    let relationWord: String
    /// The apposed name, capitalized as typed ("Muriel", "George Breen").
    let name: String

    // MARK: Parse

    /// Trailing "and tell me about her/him/them" (and kin): a biography
    /// wish on the SAME person, not a second question. Stripped before the
    /// shape is read; the answer is a biography anyway.
    static let biographyTail = /\s*(?:,|;|and|then|&)?\s*(?:(?:and|then)\s+)?(?:please\s+)?(?:tell\s+(?:me|us)\s+(?:more\s+)?about|describe|talk\s+about)\s+(?:her|him|them|that\s+person|this\s+person|that\s+one)\s*$/

    private static let kinWord = /^(?:grand[a-z]+|father|dad|daddy|papa|pop|mother|mom|mommy|mama|mum|ma|parents?|brother|sister|siblings?|son|daughter|children|kids?|husband|wife|spouse|uncle|aunt|auntie|cousin|nephew|niece|(?:brother|sister|father|mother|son|daughter)[- ]in[- ]law)$/

    /// Words that end the name capture: they mean the phrase goes on
    /// ("… grandfather on his paternal side", "… sister in 1990").
    private static let stopWords: Set<String> = [
        "on", "in", "at", "from", "and", "or", "who", "was", "is", "were", "the", "a", "an",
        "with", "of", "for", "to", "side", "his", "her", "their", "my", "our", "please",
        "hallie", "family", "line", "born", "died", "when", "where", "what", "how", "back",
        "tree", "again", "too", "also", "like", "as", "by", "about", "me", "us", "you", "it",
        "that", "this", "which", "one", "farm", "house", "wedding", "funeral", "birthday",
    ]

    /// `(?:^|\s)(owner)\s+(side)?\s+(relation)\s+(name words)$` — the same
    /// owner/side/great-count shape `HallieLineageQuestion.kinshipQuestion`
    /// reads, plus the trailing name that made that parser step aside.
    private static let shape = /(?:^|\s)(my|our|[a-z][a-z .'-]*?'s?)\s+(?:(maternal|paternal|mother'?s|father'?s)\s+)?((?:(?:\d+|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|twelfth)(?:st|nd|rd|th)?[- ]?(?:x|times)?[- ]?great[- ]?|(?:great[- ]?)+)?grand[a-z]+|father|dad|daddy|papa|pop|mother|mom|mommy|mama|mum|ma|parents?|brother|sister|siblings?|son|daughter|children|kids?|husband|wife|spouse|uncle|aunt|auntie|cousin|nephew|niece|(?:brother|sister|father|mother|son|daughter)[- ]in[- ]law)\s+([a-z][a-z'-]*(?:\s+[a-z][a-z'-]*){0,3})$/

    static func parse(_ text: String) -> HallieKinshipApposition? {
        var lower = HallieLineageQuestion.normalize(text)
        lower = lower.replacing(biographyTail, with: "")
        lower = lower.replacing(/\s+(?:please|hallie)\s*$/, with: "")
        lower = HallieLineageQuestion.normalize(lower)
        // A short sentence by nature; the bound also keeps the reluctant
        // owner group from backtracking over a huge untrusted string.
        guard !lower.isEmpty, lower.count <= 240 else { return nil }
        // A media ask ("photo of rick's grandma muriel") is the
        // translator's: the person is a search term there, not a subject.
        guard lower.firstMatch(of: HallieLineageQuestion.mediaNoun) == nil else { return nil }
        guard let m = lower.firstMatch(of: shape) else { return nil }
        // "trace the parker tree FROM my great great grandmother edith
        // lucy parker": the kin phrase is a trace's start person, and the
        // trace shapes own it.
        let before = lower[..<m.range.lowerBound].trimmingCharacters(in: .whitespaces)
        guard !(before == "from" || before.hasSuffix(" from")) else { return nil }
        let owner = String(m.1)
        let sideWord = m.2.map(String.init)
        let relationPhrase = String(m.3).replacingOccurrences(of: "-", with: " ")
        let nameWords = String(m.4).split(separator: " ").map(String.init)
        // Name tokens: none a stop word or a kin word ("rick's uncle bill"
        // yes; "rick's grandfather on" no; "rick's sister's son" no).
        guard !nameWords.contains(where: { stopWords.contains($0) || $0.wholeMatch(of: kinWord) != nil }),
              GedcomFamilyGraph.namedLikeTokens(nameWords.joined(separator: " ")) != nil
        else { return nil }

        let possessor: String?
        if owner == "my" || owner == "our" {
            possessor = nil
        } else {
            // "find rick's" → "Rick" (lead words stripped); nil = "the
            // family's" — nobody in particular, not ours.
            guard let named = HallieLineageQuestion.possessor(in: owner) else { return nil }
            possessor = named
        }
        let side: GedcomFamilyGraph.KinshipSide? = sideWord.map { $0.hasPrefix("m") ? .maternal : .paternal }
        guard let kin = kin(fromPhrase: relationPhrase, side: side) else { return nil }
        return HallieKinshipApposition(
            possessor: possessor, kin: kin, relationWord: relationPhrase,
            name: HallieLineageQuestion.capitalizedName(nameWords.joined(separator: " ")))
    }

    /// "grandma" → .extended(.grandmother); "great great great grandpa" →
    /// .deep(5, "M"); "dad" → .single(.father). Nil for words the graph
    /// cannot walk, or a side on a relation that has no side.
    static func kin(fromPhrase phrase: String, side: GedcomFamilyGraph.KinshipSide?) -> Kin? {
        let words = phrase.split(separator: " ").map(String.init)
        if let noun = words.last, noun.hasPrefix("grand"),
           let (greats, _) = HallieLineageQuestion.greatCount(in: phrase) {
            if greats >= 3 {
                guard let sex = HallieLineageQuestion.grandparentSex(noun) else { return nil }
                return .deep(depth: greats + 2, sex: sex.isEmpty ? nil : sex, side: side)
            }
            let normal = String(repeating: "great ", count: greats) + noun
            guard let parsed = GedcomFamilyGraph.extendedRelation(fromPhrase: normal) else { return nil }
            return .extended(parsed.relation, side: side)
        }
        if let parsed = GedcomFamilyGraph.extendedRelation(fromPhrase: phrase) {
            guard side == nil || parsed.relation.startsAtParents else { return nil }
            return .extended(parsed.relation, side: side)
        }
        let aliases = ["pop": "father", "mum": "mother", "ma": "mother", "kid": "children", "sibling": "siblings", "parent": "parents"]
        guard side == nil,
              let single = GedcomFamilyGraph.relation(fromWord: aliases[phrase] ?? phrase) else { return nil }
        return .single(single)
    }
}

// MARK: - Answer

extension HallieLineageAnswer {

    /// The relation set, then the name: exactly one → biography; several
    /// → which-one chips; none → the set, honestly. Never a guard sentence.
    static func kinshipApposition(_ q: HallieKinshipApposition,
                                  context: HallieTurnExecutor.Context) -> Result {
        guard let graph = context.graph else { return noTree(context) }
        let subject: GedcomFamilyGraph.Person
        var note: String?
        switch resolve(q.possessor, context: context, graph: graph) {
        case .failure(let r?): return r
        case .failure(nil):
            return Result(
                route: .graph, outcome: .declined,
                prose: "I don't know who you mean by \(q.possessor ?? "you"), so I can't look up \(HallieLineageQuestion.possessive(q.possessor ?? "your")) \(q.relationWord) \(q.name).",
                basisLine: ArchivistBiographyPolicy.gedcomCheck + " No record matched the person before the apostrophe.",
                queryDescription: "kinship-apposition: \(q.possessor ?? "me") \(q.relationWord) \(q.name)",
                citations: [], catalogPersonName: nil)
        case .success(let p, let n):
            subject = p; note = n
        }
        // Who the sentence calls the owner: what was typed ("Rick"), else
        // the settings name, else the record.
        let ownerLabel = q.possessor ?? context.speakers.ownerName ?? subject.name
        let description = "kinship-apposition: \(subject.name) \(q.relationWord) \(q.name)"
        let basis = ArchivistBiographyPolicy.gedcomBasis + (note.map { " " + $0 } ?? "")
        let aName = ("aeiou".contains(q.name.lowercased().first ?? "x") ? "an " : "a ") + q.name

        // The relation set, with the route that reached each person (so
        // the who-is sentence can say "paternal").
        var relatives: [(person: GedcomFamilyGraph.Person, label: String)] = []
        let plural: String
        switch q.kin {
        case .single(let r):
            plural = ArchivistGraphExecutor.pluralize(r.rawValue)
            relatives = graph.relatives(r, of: subject).map { ($0, r.rawValue) }
        case .extended(let e, let side):
            let word = (side.map { "\($0.rawValue) " } ?? "") + e.rawValue
            plural = ArchivistGraphExecutor.pluralize(word)
            switch graph.relatives(e, side: side, of: subject) {
            case .found(let paths):
                var seen: Set<String> = []
                for path in paths where seen.insert(path.relative.id).inserted {
                    let first = path.hops.first?.label ?? ""
                    let sideLabel = side == nil && e.startsAtParents
                        ? (first.contains("father") ? "paternal " : first.contains("mother") ? "maternal " : "")
                        : (side.map { "\($0.rawValue) " } ?? "")
                    relatives.append((path.relative, sideLabel + e.rawValue))
                }
            case .missingHop(let reached, let missing):
                let recorded = reached.map { "\($0.label) (\($0.person.name))" }.joined(separator: " → ")
                let prose = reached.isEmpty
                    ? "The family tree doesn't record \(missing) for \(subject.name), so I can't reach a \(word) — and can't check for \(aName)."
                    : "The family tree records \(HallieLineageQuestion.possessive(subject.name)) \(recorded), but not \(missing) — so I can't reach a \(word) to check for \(aName)."
                return Result(route: .graph, outcome: .declined, prose: prose, basisLine: basis,
                              queryDescription: description, citations: [], catalogPersonName: subject.name,
                              offeredActions: [.openFamilyTreePerson(personID: subject.id, personName: subject.name)])
            }
        case .deep(let depth, let sex, let side):
            let word = (side.map { "\($0.rawValue) " } ?? "")
                + GedcomFamilyGraph.generationLabel(generations: depth, sex: sex ?? "")
            plural = word + "s"
            relatives = ancestors(of: subject, depth: depth, side: side, graph: graph)
                .filter { sex == nil || $0.sex == sex }
                .map { ($0, word) }
        }

        guard let tokens = GedcomFamilyGraph.namedLikeTokens(q.name) else {
            return Result(route: .graph, outcome: .declined,
                          prose: "I need a name to pick from \(HallieLineageQuestion.possessive(ownerLabel)) \(plural).",
                          basisLine: basis, queryDescription: description, citations: [], catalogPersonName: nil)
        }
        let matches = relatives.filter { graph.matches($0.person, namedLikeTokens: tokens) }
        let setNames = relatives.map(\.person.name)

        if relatives.isEmpty {
            let word = plural.hasSuffix("s") ? String(plural.dropLast()) : plural
            return Result(
                route: .graph, outcome: .declined,
                prose: "The family tree doesn't record a \(word) for \(subject.name), so I can't check for \(aName).",
                basisLine: basis + " Looked for \(plural) of \(subject.name): none recorded.",
                queryDescription: description, citations: [], catalogPersonName: subject.name,
                offeredActions: [.openFamilyTreePerson(personID: subject.id, personName: subject.name)])
        }
        if matches.isEmpty {
            let list = setNames.count == 1 ? setNames[0] : setNames.dropLast().joined(separator: ", ") + " and " + setNames[setNames.count - 1]
            let verb = setNames.count == 1 ? "\(plural.hasSuffix("s") ? String(plural.dropLast()) : plural) is" : "\(plural) are"
            return Result(
                route: .graph, outcome: .declined,
                prose: "\(HallieLineageQuestion.possessive(ownerLabel)) \(verb) \(list) — I don't find \(aName) there.",
                basisLine: basis + " Checked \(relatives.count) \(plural) of \(subject.name) by name (nicknames and married surnames allowed).",
                queryDescription: description, citations: [], catalogPersonName: nil,
                offeredActions: relatives.prefix(4).map { .openFamilyTreePerson(personID: $0.person.id, personName: $0.person.name) })
        }
        if matches.count > 1 {
            let labels = matches.map { m -> String in
                HalliePersonCard.yearsText(m.person).map { "\(m.person.name) (\($0))" } ?? m.person.name
            }
            return Result(
                route: .graph, outcome: .needsClarification,
                prose: "\(ownerLabel) has \(matches.count) \(plural) named \(q.name) — " + labels.joined(separator: " or ") + "? Tap one and I'll tell you about them.",
                basisLine: basis + " \(matches.count) of \(relatives.count) \(plural) match the name.",
                queryDescription: description, citations: [], catalogPersonName: nil,
                offeredActions: zip(matches, labels).map { m, label in .ask(question: "who is \(m.person.name)", label: label) })
        }

        let found = matches[0]
        let years = HalliePersonCard.yearsText(found.person).map { " (\($0))" } ?? ""
        let tense = found.person.deathDate != nil ? "was" : "is"
        var displayName = found.person.name
        if let married = graph.marriedSurname(of: found.person, satisfying: tokens) {
            displayName += " (\(married))"
        }
        let whoIs = "\(displayName)\(years) \(tense) \(HallieLineageQuestion.possessive(ownerLabel)) \(found.label)."
        let bio = ArchivistBiographyPolicy.biography(personID: found.person.id, in: graph).text
        let assets = FamilyAssetConfigurationCenter.shared.snapshot().makeStore()
        var attachments: [HallieAttachment] = []
        if let url = assets.photoURLs(for: found.person).first {
            attachments.append(.photo(HalliePhotoAttachment(personName: found.person.name, fileURL: url)))
        }
        return Result(
            route: .graph, outcome: .answered,
            prose: whoIs + " " + bio,
            basisLine: basis + " \(HallieLineageQuestion.possessive(subject.name)) \(plural): \(setNames.joined(separator: ", ")); \(q.name) matched \(found.person.name).",
            queryDescription: description + " → \(found.person.name)",
            citations: [], catalogPersonName: found.person.name,
            offeredActions: [.openFamilyTreePerson(personID: found.person.id, personName: found.person.name)],
            attachments: attachments)
    }

    /// Every ancestor exactly `depth` generations above `person` (first hop
    /// through `side` when given), name order, no duplicates. The plain
    /// walk `deepAncestors` also does, without the prose.
    static func ancestors(of person: GedcomFamilyGraph.Person, depth: Int,
                          side: GedcomFamilyGraph.KinshipSide?,
                          graph: GedcomFamilyGraph) -> [GedcomFamilyGraph.Person] {
        var frontier: [GedcomFamilyGraph.Person] = [person]
        var visited: Set<String> = [person.id]
        for level in 1...max(1, depth) {
            var next: [GedcomFamilyGraph.Person] = []
            for from in frontier {
                let parents: [GedcomFamilyGraph.Person]
                if level == 1, let side {
                    parents = graph.relatives(side == .maternal ? .mother : .father, of: from)
                } else {
                    parents = graph.relatives(.parents, of: from)
                }
                for parent in parents where visited.insert(parent.id).inserted {
                    next.append(parent)
                }
            }
            frontier = next
            if frontier.isEmpty { break }
        }
        return frontier.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }
}
