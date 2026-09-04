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
// 2026-09-04 — THE PEOPLE TAB IS CONSULTED FIRST. The relation set used to
// come from the GEDCOM alone, and the GEDCOM records no siblings at all for
// Rick, so his own brother could not be reached. See
// `peopleTabApposition` for the live failure and Rick's ruling.
//
// C++ readers: `Kin` is a tagged union (std::variant) over the three
// traversal shapes the graph already has; `parse` is a pure function of
// the text, `answer` is where the two stores are consulted.

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

    /// The People-tab overlay's word for this kin shape, or nil when a typed
    /// relationship row cannot express it: great-grand… and beyond (no such
    /// row exists), and every maternal/paternal ask (a row records no side).
    /// Nil means "the tree alone answers this one", exactly as before.
    var overlayRelation: (relation: KinshipRelation, sex: PersonSex?)? {
        switch kin {
        case .single(let relation):
            return KinshipRelation.parse(term: relation.rawValue)
        case .extended(let relation, let side):
            guard side == nil else { return nil }
            return KinshipRelation.parse(term: relation.rawValue)
        case .deep:
            return nil
        }
    }
}

// MARK: - Answer

extension HallieLineageAnswer {

    /// One person the apposed name could be, from EITHER store.
    ///
    /// C++ readers: this stands in for `std::variant<Hit, Person>`. Swift
    /// would express that as an enum with payloads, but every caller wants
    /// the same four accessors off either arm, and one struct with two
    /// optionals reads better than a `switch` inside each accessor.
    struct AppositionCandidate {
        /// The People-tab row, when that is where this person came from.
        let hit: FamilyKinshipOverlay.Hit?
        /// The tree record, when the GEDCOM walk produced this person.
        let treePerson: GedcomFamilyGraph.Person?
        /// "brother", "paternal grandmother" — the word for THIS person.
        let label: String

        var isPeopleTab: Bool { hit != nil }
        var name: String { treePerson?.name ?? hit?.member.name ?? "" }
        var displayName: String { treePerson?.name ?? hit?.member.displayName ?? "" }
        var gedcomID: String? { treePerson?.id ?? hit?.member.gedcomID }

        /// Dedupe key across the two stores: a bridged People-tab row and
        /// the tree record it points at are ONE person, named once.
        var identity: String {
            if let id = gedcomID { return "tree:" + id }
            if let hit { return "overlay:" + hit.member.node.auditID }
            return "name:" + PersonResolver.normalize(name)
        }
    }

    /// The relatives the PEOPLE TAB records in this relation for `subject`.
    ///
    /// ─────────────────────────────────────────────────────────────────
    /// RICK'S RULING, 2026-09-04 (Director) — the same ruling
    /// `HallieVitalDates` carries for birth and death dates:
    ///
    ///   "The people tab should be the source for the immediate
    ///    contemporary people in the people tab."
    ///
    /// The GEDCOM is a FamilySearch import that records NO siblings at all
    /// for Rick — it is provably wrong about this family, as it is about
    /// both his parents' dates. His own People profile carries
    /// `sibling → Tim`, `sibling → Ellen`, `sibling → Beth`. Live
    /// 2026-09-04 18:51:37Z, the evening before the demo:
    ///
    ///   "tell me about my brother tim"
    ///   → "The family tree doesn't record a brother for Richard Harding
    ///      Breen Jr, so I can't check for a Tim."   (route=graph, declined)
    ///
    /// while "who is Tim" answered fully from the same People profile.
    ///
    /// Nil when the overlay holds no row for the relation — which is every
    /// tree-only person and every relation word a typed row cannot express
    /// — and then the tree walk stands exactly as it did before.
    ///
    /// Memory: bounded by the PROFILE count (tens), never by the tree's
    /// person count; `relatives` walks at most three hops of the overlay.
    static func peopleTabApposition(
        _ q: HallieKinshipApposition,
        subject: GedcomFamilyGraph.Person,
        context: HallieTurnExecutor.Context
    ) -> (overlay: FamilyKinshipOverlay, hits: [FamilyKinshipOverlay.Hit])? {
        guard let wanted = q.overlayRelation,
              let overlay = HallieTurnExecutor.kinshipOverlay(context: context),
              !overlay.isEmpty else { return nil }
        // The subject's tree vertex, plus whatever profile claims the typed
        // spelling (or the owner's name, for "my …") — both name the same
        // person for THIS question, so their rows are unioned. The same
        // shape `ArchivistGraphExecutor.anchorNodes` uses.
        var anchors: [FamilyKinshipOverlay.Node] = [overlay.node(gedcomID: subject.id)]
        let typed = q.possessor ?? context.speakers.ownerName
        if let typed, !typed.trimmingCharacters(in: .whitespaces).isEmpty {
            for node in overlay.nodes(claiming: typed, ownerName: context.speakers.ownerName)
            where !anchors.contains(node) {
                anchors.append(node)
            }
        }
        // Several PROFILES claim the possessor: which one is the ordinary
        // route's question, and never a silent pick here.
        let profileClaimants = anchors.filter {
            if case .profile = $0 { return true } else { return false }
        }
        guard profileClaimants.count <= 1 else { return nil }

        var hits: [FamilyKinshipOverlay.Hit] = []
        var seen = Set<FamilyKinshipOverlay.Node>()
        for anchor in anchors {
            for hit in overlay.relatives(of: anchor, relation: wanted.relation, sex: wanted.sex)
            where seen.insert(hit.member.node).inserted {
                hits.append(hit)
            }
        }
        return hits.isEmpty ? nil : (overlay, hits)
    }

    /// Does the apposed name name THIS candidate? A tree record is matched
    /// by the graph's own tolerant matcher (nicknames, married surnames); a
    /// People-tab person by their canonical spelling, or by any spelling the
    /// People tab's own resolver says is theirs (aliases).
    ///
    /// Deliberately NOT "somebody somewhere is called that": the name is
    /// only ever read against people who ALREADY hold the relation, so a
    /// relationship neither store records can never become the wrong
    /// person — "my brother Fred", with no Fred anybody's brother, still
    /// declines.
    static func appositionNameMatches(
        _ candidate: AppositionCandidate,
        typed: String,
        tokens: [String],
        graph: GedcomFamilyGraph,
        overlay: FamilyKinshipOverlay?,
        ownerName: String?
    ) -> Bool {
        if let record = candidate.gedcomID.flatMap({ graph.people[$0] }),
           graph.matches(record, namedLikeTokens: tokens) {
            return true
        }
        guard let hit = candidate.hit else { return false }
        if PersonResolver.normalize(hit.member.name) == PersonResolver.normalize(typed) {
            return true
        }
        return overlay?.nodes(claiming: typed, ownerName: ownerName)
            .contains(hit.member.node) ?? false
    }

    /// The relation set, then the name: exactly one → biography; several
    /// → which-one chips; none → the set, honestly. Never a guard sentence.
    ///
    /// The People tab is consulted BEFORE the tree and its rows lead the
    /// candidate set (Rick's ruling, above). The tree is still walked and
    /// still answers on its own for the ~39,000 people who are only in it.
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
        var basis = ArchivistBiographyPolicy.gedcomBasis + (note.map { " " + $0 } ?? "")
        let aName = ("aeiou".contains(q.name.lowercased().first ?? "x") ? "an " : "a ") + q.name

        // ── The People tab, first ──────────────────────────────────────
        let peopleTab = peopleTabApposition(q, subject: subject, context: context)
        var candidates = peopleTabCandidates(q, peopleTab: peopleTab)
        if let peopleTab { basis = overlayBasis(basis, peopleTab: peopleTab) }

        // ── Then the family tree ───────────────────────────────────────
        let tree = treeApposition(q, subject: subject, graph: graph, aName: aName)
        if let missingHop = tree.missingHop, candidates.isEmpty {
            // A hop the tree never recorded, and the People tab has nothing
            // either — a typed row does not need the tree's intermediate
            // people to exist, so this decline waits on it.
            return Result(route: .graph, outcome: .declined, prose: missingHop, basisLine: basis,
                          queryDescription: description, citations: [], catalogPersonName: subject.name,
                          offeredActions: [.openFamilyTreePerson(personID: subject.id, personName: subject.name)])
        }
        var identities = Set(candidates.map(\.identity))
        for relative in tree.relatives {
            let candidate = AppositionCandidate(
                hit: nil, treePerson: relative.person, label: relative.label)
            if identities.insert(candidate.identity).inserted { candidates.append(candidate) }
        }
        let plural = tree.plural

        guard let tokens = GedcomFamilyGraph.namedLikeTokens(q.name) else {
            return Result(route: .graph, outcome: .declined,
                          prose: "I need a name to pick from \(HallieLineageQuestion.possessive(ownerLabel)) \(plural).",
                          basisLine: basis, queryDescription: description, citations: [], catalogPersonName: nil)
        }
        if candidates.isEmpty {
            // Neither store records the relation: today's honest decline,
            // word for word.
            let word = plural.hasSuffix("s") ? String(plural.dropLast()) : plural
            return Result(
                route: .graph, outcome: .declined,
                prose: "The family tree doesn't record a \(word) for \(subject.name), so I can't check for \(aName).",
                basisLine: basis + " Looked for \(plural) of \(subject.name): none recorded.",
                queryDescription: description, citations: [], catalogPersonName: subject.name,
                offeredActions: [.openFamilyTreePerson(personID: subject.id, personName: subject.name)])
        }
        let matches = candidates.filter {
            appositionNameMatches($0, typed: q.name, tokens: tokens, graph: graph,
                                  overlay: peopleTab?.overlay, ownerName: context.speakers.ownerName)
        }
        if matches.isEmpty {
            return appositionNoMatch(q, candidates: candidates, plural: plural, aName: aName,
                                     ownerLabel: ownerLabel, subject: subject,
                                     basis: basis, description: description)
        }
        if matches.count > 1 {
            return appositionWhichOne(q, matches: matches, candidateCount: candidates.count,
                                      plural: plural, ownerLabel: ownerLabel,
                                      basis: basis, description: description)
        }
        let found = matches[0]
        guard let record = found.gedcomID.flatMap({ graph.people[$0] }) else {
            // Known to the People tab and to no tree record: answer from
            // the profile, which is the whole point of the ruling.
            return peopleTabAppositionAnswer(
                found, q: q, ownerLabel: ownerLabel, basis: basis,
                description: description, context: context)
        }
        return treeAppositionAnswer(q, found: found, record: record, tokens: tokens,
                                    setNames: candidates.map(\.displayName), plural: plural,
                                    ownerLabel: ownerLabel, subject: subject, graph: graph,
                                    basis: basis, description: description)
    }

    // MARK: The two stores, each in its own step

    /// The People-tab half of the candidate set, in overlay order.
    private static func peopleTabCandidates(
        _ q: HallieKinshipApposition,
        peopleTab: (overlay: FamilyKinshipOverlay, hits: [FamilyKinshipOverlay.Hit])?
    ) -> [AppositionCandidate] {
        guard let peopleTab else { return [] }
        var candidates: [AppositionCandidate] = []
        var identities = Set<String>()
        for hit in peopleTab.hits {
            // The word for THIS person: "brother" for a male sibling row,
            // the neutral "sibling" when no sex is recorded.
            let word = q.overlayRelation
                .map { $0.relation.term(sex: hit.member.sex ?? $0.sex) } ?? q.relationWord
            let candidate = AppositionCandidate(hit: hit, treePerson: nil, label: word)
            if identities.insert(candidate.identity).inserted { candidates.append(candidate) }
        }
        return candidates
    }

    /// The basis line with the People-tab clause in front of the tree's.
    /// ONE "Basis:" per line: the tree clause loses its own prefix and
    /// follows the store that outranks it.
    private static func overlayBasis(
        _ basis: String,
        peopleTab: (overlay: FamilyKinshipOverlay, hits: [FamilyKinshipOverlay.Hit])
    ) -> String {
        let storedOn = Array(Set(peopleTab.hits.flatMap { $0.hops.map(\.storedOn) })).sorted()
        let derived = ArchivistGraphExecutor.derivedNamesByNote(
            peopleTab.hits, overlay: peopleTab.overlay)
        let treeClause = basis.hasPrefix("Basis: ")
            ? String(basis.dropFirst("Basis: ".count)) : basis
        return ArchivistGraphExecutor.overlayBasisPrefix + " "
            + ArchivistGraphExecutor.overlayStoredOnClause(storedOn: storedOn, namesByNote: derived)
            + "; " + treeClause
            + ArchivistGraphExecutor.overlayWarningClause(
                peopleTab.overlay.derivationWarnings(touching: peopleTab.hits.map(\.member.node)))
    }

    /// The GEDCOM half: the relation set, the plural word for the prose,
    /// and — for an extended relation only — the prose for the one decline
    /// the tree alone can produce (an intermediate hop it never recorded).
    private static func treeApposition(
        _ q: HallieKinshipApposition,
        subject: GedcomFamilyGraph.Person,
        graph: GedcomFamilyGraph,
        aName: String
    ) -> (relatives: [(person: GedcomFamilyGraph.Person, label: String)],
          plural: String, missingHop: String?) {
        switch q.kin {
        case .single(let r):
            return (graph.relatives(r, of: subject).map { ($0, r.rawValue) },
                    ArchivistGraphExecutor.pluralize(r.rawValue), nil)
        case .extended(let e, let side):
            let word = (side.map { "\($0.rawValue) " } ?? "") + e.rawValue
            let plural = ArchivistGraphExecutor.pluralize(word)
            switch graph.relatives(e, side: side, of: subject) {
            case .found(let paths):
                var relatives: [(person: GedcomFamilyGraph.Person, label: String)] = []
                var seen: Set<String> = []
                for path in paths where seen.insert(path.relative.id).inserted {
                    let first = path.hops.first?.label ?? ""
                    let sideLabel = side == nil && e.startsAtParents
                        ? (first.contains("father") ? "paternal " : first.contains("mother") ? "maternal " : "")
                        : (side.map { "\($0.rawValue) " } ?? "")
                    relatives.append((path.relative, sideLabel + e.rawValue))
                }
                return (relatives, plural, nil)
            case .missingHop(let reached, let missing):
                let recorded = reached.map { "\($0.label) (\($0.person.name))" }.joined(separator: " → ")
                let prose = reached.isEmpty
                    ? "The family tree doesn't record \(missing) for \(subject.name), so I can't reach a \(word) — and can't check for \(aName)."
                    : "The family tree records \(HallieLineageQuestion.possessive(subject.name)) \(recorded), but not \(missing) — so I can't reach a \(word) to check for \(aName)."
                return ([], plural, prose)
            }
        case .deep(let depth, let sex, let side):
            let word = (side.map { "\($0.rawValue) " } ?? "")
                + GedcomFamilyGraph.generationLabel(generations: depth, sex: sex ?? "")
            let relatives = ancestors(of: subject, depth: depth, side: side, graph: graph)
                .filter { sex == nil || $0.sex == sex }
                .map { ($0, word) }
            return (relatives, word + "s", nil)
        }
    }

    // MARK: The three endings

    /// The relation IS recorded — by one store or both — and nobody holding
    /// it goes by that name. Say who they are; never reach past the set for
    /// a namesake.
    private static func appositionNoMatch(
        _ q: HallieKinshipApposition,
        candidates: [AppositionCandidate], plural: String, aName: String,
        ownerLabel: String, subject: GedcomFamilyGraph.Person,
        basis: String, description: String
    ) -> Result {
        let setNames = candidates.map(\.displayName)
        let singular = plural.hasSuffix("s") ? String(plural.dropLast()) : plural
        let list = setNames.count == 1 ? setNames[0]
            : setNames.dropLast().joined(separator: ", ") + " and " + setNames[setNames.count - 1]
        let verb = setNames.count == 1 ? "\(singular) is" : "\(plural) are"
        return Result(
            route: .graph, outcome: .declined,
            prose: "\(HallieLineageQuestion.possessive(ownerLabel)) \(verb) \(list) — I don't find \(aName) there.",
            basisLine: basis + " Checked \(candidates.count) \(plural) of \(subject.name) by name (nicknames and married surnames allowed).",
            queryDescription: description, citations: [], catalogPersonName: nil,
            offeredActions: candidates.prefix(4).compactMap { candidate in
                candidate.gedcomID.map {
                    HallieTurnExecutor.OfferedAction.openFamilyTreePerson(
                        personID: $0, personName: candidate.displayName)
                }
            })
    }

    /// Two people could be meant — one per store, or two in one store. Ask,
    /// with chips; never a refusal and never a silent pick.
    private static func appositionWhichOne(
        _ q: HallieKinshipApposition,
        matches: [AppositionCandidate], candidateCount: Int, plural: String,
        ownerLabel: String, basis: String, description: String
    ) -> Result {
        let labels = matches.map { m -> String in
            let years = m.treePerson.flatMap(HalliePersonCard.yearsText)
            return years.map { "\(m.displayName) (\($0))" } ?? m.displayName
        }
        return Result(
            route: .graph, outcome: .needsClarification,
            prose: "\(ownerLabel) has \(matches.count) \(plural) named \(q.name) — " + labels.joined(separator: " or ") + "? Tap one and I'll tell you about them.",
            basisLine: basis + " \(matches.count) of \(candidateCount) \(plural) match the name.",
            queryDescription: description, citations: [], catalogPersonName: nil,
            offeredActions: zip(matches, labels).map { m, label in .ask(question: "who is \(m.name)", label: label) })
    }

    /// The one relative, from the tree's own record — unchanged prose.
    private static func treeAppositionAnswer(
        _ q: HallieKinshipApposition,
        found: AppositionCandidate, record: GedcomFamilyGraph.Person, tokens: [String],
        setNames: [String], plural: String, ownerLabel: String,
        subject: GedcomFamilyGraph.Person, graph: GedcomFamilyGraph,
        basis: String, description: String
    ) -> Result {
        let years = HalliePersonCard.yearsText(record).map { " (\($0))" } ?? ""
        let tense = record.deathDate != nil ? "was" : "is"
        var displayName = record.name
        if let married = graph.marriedSurname(of: record, satisfying: tokens) {
            displayName += " (\(married))"
        }
        let whoIs = "\(displayName)\(years) \(tense) \(HallieLineageQuestion.possessive(ownerLabel)) \(found.label)."
        let bio = ArchivistBiographyPolicy.biography(personID: record.id, in: graph).text
        let assets = FamilyAssetConfigurationCenter.shared.snapshot().makeStore()
        var attachments: [HallieAttachment] = []
        if let url = assets.photoURLs(for: record).first {
            attachments.append(.photo(HalliePhotoAttachment(personName: record.name, fileURL: url)))
        }
        return Result(
            route: .graph, outcome: .answered,
            prose: whoIs + " " + bio,
            basisLine: basis + " \(HallieLineageQuestion.possessive(subject.name)) \(plural): \(setNames.joined(separator: ", ")); \(q.name) matched \(record.name).",
            queryDescription: description + " → \(record.name)",
            citations: [], catalogPersonName: record.name,
            offeredActions: [.openFamilyTreePerson(personID: record.id, personName: record.name)],
            attachments: attachments)
    }

    /// The answer for a relative the PEOPLE TAB knows and the tree does not
    /// — Tim, in the live failure. The kinship sentence comes from the
    /// overlay row; everything after it is the SAME People-tab biography
    /// "who is Tim" gives today (`HallieTurnExecutor.PeopleTab.answer`), so
    /// the two questions cannot answer differently about one man.
    private static func peopleTabAppositionAnswer(
        _ found: AppositionCandidate,
        q: HallieKinshipApposition,
        ownerLabel: String,
        basis: String,
        description: String,
        context: HallieTurnExecutor.Context
    ) -> Result {
        let possessive = q.possessor == nil
            ? "your" : HallieLineageQuestion.possessive(ownerLabel)
        let profile = found.hit?.member.profileStableID
            .flatMap { id in (context.profiles ?? []).first { $0.stableID == id } }
        let tense = profile?.deathdate != nil ? "was" : "is"
        let sentence = "\(found.displayName) \(tense) \(possessive) \(found.label)."
        guard let profile else {
            // The row names someone with no profile of their own: the
            // relationship is known, the person is not. Say both, and never
            // borrow another \(found.displayName) to fill the gap.
            return Result(
                route: .graph, outcome: .answered,
                prose: sentence + " The People tab records the relationship, but there's no profile for "
                    + "\(found.displayName) yet — tell me about \(found.displayName) and I'll remember it.",
                basisLine: basis,
                queryDescription: description + " → \(found.name)",
                citations: [], catalogPersonName: nil)
        }
        let inner = HallieTurnExecutor.PeopleTab.answer(
            profile: profile,
            payload: .init(people: [profile.canonicalName], operation: .biography),
            context: context,
            queryDescription: description + " → \(profile.canonicalName)")
        return Result(
            route: .graph, outcome: .answered,
            prose: sentence + " " + inner.prose,
            basisLine: basis + " " + inner.basisLine,
            queryDescription: description + " → \(profile.canonicalName)",
            citations: inner.citations,
            catalogPersonName: inner.catalogPersonName,
            offeredActions: inner.offeredActions,
            attachments: inner.attachments,
            subjectLifeStatus: inner.subjectLifeStatus)
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
