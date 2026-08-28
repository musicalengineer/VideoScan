// HallieLineageQuestion.swift
// Deterministic routes for the lineage shapes Rick asked for on 2026-08-22:
//   "show Rick's maternal line back 5 generations"
//   "show the family tree for the Latta family" / "starting with the Lattas"
//   "trace the family back to Ireland"
//   "what is GEDCOM?" / "where does your family tree come from?"
//
// These run BEFORE the model translator (HallieTurnExecutor.preTranslation)
// because the translator's closed graph vocabulary has no generation
// counts, surname roots, or place trails — and a deterministic answer with a
// card is exactly what the family wants to see. Detection is narrow on
// purpose: when the shape is not really ours (a person where a surname was
// expected) `HallieLineageAnswer.answer` returns nil and the question goes
// on as typed.

import Foundation
import VideoScanCore

enum HallieLineageQuestion: Equatable, Sendable {
    /// `person` nil = the owner ("my", "Rick's" when Rick is the owner is
    /// still a name and resolves normally).
    /// `untilYear` = "… back to 1600" / "before 1700" / "until the 1600s"
    /// (2026-08-26): the walk stops at that year instead of where the
    /// tree ends. C++ readers: an associated value with a default is like
    /// a defaulted constructor argument — `.ancestorLine(person:line:
    /// generations:)` still builds the case.
    case ancestorLine(person: String?, line: GedcomFamilyGraph.Line, generations: Int,
                      untilYear: Int? = nil)
    case surnameTree(surname: String)
    case originTrail(person: String?, country: String?, line: GedcomFamilyGraph.Line)
    case gedcomAwareness
    /// "get more of the family tree" / "download the tree from FamilySearch"
    /// — points at the Family Tree tab's Get Family Tree sheet (Rick
    /// 2026-08-25: "maybe via Hallie if we can make it simple english").
    case getFamilyTree
    /// "did we only get the gedcom for Rick?" / "have we pulled the tree
    /// for Donna's side?" (live 2026-08-27, asked twice): a question about
    /// what the loaded tree COVERS — its source file, whom it was pulled
    /// for, whether a person / surname is in it — not a fetch. `person`
    /// and `surname` are whatever the sentence named (lowercase surname,
    /// as `.surnameTree`).
    case gedcomProvenance(person: String?, surname: String?)
    /// "describe X" / "what was X like" / "X's appearance/personality" —
    /// answered DETERMINISTICALLY from the family's told accounts, voiced
    /// as attributed testimony (Rick 2026-08-25: a prompt nudge left it
    /// to the model's mood; a description ask must always speak).
    enum DescriptionFocus: String, Sendable { case appearance, personality, general }
    case personDescription(person: String, focus: DescriptionFocus = .general)
    /// "show me a photo of X" — the stored portrait as an attachment;
    /// no language model involved.
    case personPhoto(person: String)
    /// "videos of X" where X turns out to be a family-tree person who
    /// predates photography (WorldKnowledge, Rick 2026-08-26): answered
    /// with one honest line, never a keyword search. For everyone else the
    /// answer is nil and the question continues to the presence route as
    /// typed — this shape only ever SUPPRESSES a search, it never runs one.
    case personVideos(person: String)
    /// "tell me about Rick Breen's great great grandpa on his paternal
    /// side" / "who was Donna's maternal grandmother" / "my great grandpa"
    /// (live 2026-08-26: the line regex below swallowed "paternal side"
    /// and made the whole prefix the person). A multi-hop ancestor
    /// relation with an optional side, parsed deterministically and
    /// handed to the ordinary graph kinship route as a ready-made AST —
    /// same clarification chips, People-tab fallback and family-knowledge
    /// supplement as a translated question. `person` nil = the owner.
    case kinship(person: String?, relation: ArchivistQueryAST.Graph.Relation,
                 side: ArchivistQueryAST.Graph.Side?)
    /// "great great great grandpa" / "3rd great grandfather" / "5x great
    /// grandmother" (2026-08-26): the closed `ExtendedRelation` stops at
    /// great-great, so deeper asks fell to the translator. `depth` is the
    /// number of generations above the person (great-great-grandfather =
    /// 4, 3rd-great = 5); `sex` "M"/"F"/nil filters the final hop; `side`
    /// picks the first hop. Answered by a plain ancestor walk that lists
    /// every qualifying ancestor with the path, like the ≤ great-great
    /// route does.
    case deepAncestor(person: String?, depth: Int, sex: String?,
                      side: ArchivistQueryAST.Graph.Side?)
    /// "rick's grandma muriel" / "my uncle Bill" / "Donna's sister Nancy"
    /// (live 2026-08-26): a kinship word AND a name for the same person —
    /// the relation set filtered by the name. Parsed and answered in one
    /// place, HallieKinshipApposition.
    case kinshipNamed(HallieKinshipApposition)

    /// "the oldest person in the tree" / "who lived the longest" / "the
    /// deepest ancestor of Rick" / "first born in Ireland" (live
    /// 2026-08-26: the first answered with the tree SUMMARY, the second —
    /// "oldest photo of the oldest person" — became a transcript search
    /// for "oldest photo"). A ranking over the graph, answered with the
    /// person (ties → up to 3) and the who-is biography sentence. `media`
    /// = the noun when the person phrase sits inside a media request
    /// ("photo of the oldest person in the tree"): the person is resolved
    /// FIRST and the media ask is re-issued with the name.
    enum SuperlativeKind: Equatable, Sendable {
        case earliestBorn, latestBorn, longestLived, latestDied, earliestMarried
        case mostChildren, deepestAncestor
        case firstBornIn(place: String)
    }
    enum SuperlativeScope: Equatable, Sendable {
        case wholeTree
        case surname(String)
        /// nil = the owner.
        case ancestorsOf(String?)
    }
    case superlative(kind: SuperlativeKind, scope: SuperlativeScope, media: String? = nil)
    /// "how are Rick and Donna related" / "common ancestor of X and Y" /
    /// "are X and Y related" / "what do X and Y have in common ancestrally"
    /// (2026-08-27: the merged two-root tree makes this answerable). The
    /// ancestor sets intersected, nearest first, with both descent paths
    /// and the cousin term. `nil` = the owner ("me and Donna").
    case commonAncestor(a: String?, b: String?)

    static let defaultGenerations = 5
    static let maxGenerations = 12
    /// A year bound replaces the generation cap: 1959 → 1600 is ~13
    /// generations, more than the card's usual 12.
    static let yearBoundGenerations = 40
    static let treeDepth = 6

    // MARK: Detection (pure text)

    static func detect(_ text: String) -> HallieLineageQuestion? {
        let lower = normalize(text)
        guard !lower.isEmpty else { return nil }
        // A year bound ("… back to 1600", 2026-08-26) is peeled off first
        // so every shape below parses the sentence it always did; it is
        // then re-attached to the ancestor walk. A trace with no country
        // and a year is an ancestor walk too ("trace my line back to 1700").
        guard let year = yearBound(in: lower) else { return detectShape(lower) }
        let stripped = lower.replacing(yearBoundPhrase, with: "")
            .trimmingCharacters(in: .whitespaces)
        switch detectShape(stripped) {
        case .ancestorLine(let person, let line, _, _)?:
            let gens = generations(in: lower) ?? yearBoundGenerations
            return .ancestorLine(person: person, line: line, generations: gens, untilYear: year)
        case .originTrail(let person, nil, let line)?:
            return .ancestorLine(person: person, line: line, generations: yearBoundGenerations, untilYear: year)
        case nil:
            // "rick's ancestors before 1800" — no generation count, no
            // trace verb; the year is the whole ask. Ancestry words only
            // (never "family" alone: "videos of the family from 1990 to
            // 1995" is a media question).
            if stripped.firstMatch(of: /\b(?:video|photo|picture|clip|movie|footage|film|image)s?\b/) == nil,
               let m = stripped.firstMatch(of: /^(.*?)\b(?:ancest\w*|pedigree|lineage|line|family tree)\b/) {
                return .ancestorLine(person: possessor(in: String(m.1)) ?? namedTarget(in: stripped),
                                     line: lineWord(in: stripped),
                                     generations: yearBoundGenerations, untilYear: year)
            }
            return nil
        case let other:
            return other
        }
    }

    private static func detectShape(_ lower: String) -> HallieLineageQuestion? {
        if isGetFamilyTree(lower) { return .getFamilyTree }
        if let provenance = gedcomProvenanceQuestion(in: lower) { return provenance }
        if isGedcomAwareness(lower) { return .gedcomAwareness }
        // "how are rick and donna related" — two people, one relatedness
        // word; never a media ask ("videos of rick and donna" has none).
        if let pair = commonAncestorQuestion(in: lower) { return pair }

        // Superlatives BEFORE the photo shape: "photo of the oldest person
        // in the tree" is a person to find first, not a person named "the
        // oldest person in the tree".
        if let sup = superlativeQuestion(in: lower) { return sup }
        // "show me a photo of Fred Lamb" (typos in the lead words are the
        // translator's problem no longer — this is deterministic).
        // The name may carry a namesake qualifier — "(b. 1651)", "born
        // 1651", "who died in 1737" (HallieNameQualifier; TEMPORARY, see
        // that file); nothing else with digits, so "photos of donna from
        // 1992" stays a media search.
        if let m = lower.firstMatch(of: /\b(?:photo|picture|portrait|image)s?\s+of\s+([a-z][a-z .'-]+?(?:\s*\([^)]*\)|\s+(?:who\s+)?(?:born|b\.|died|d\.)\s+(?:in\s+)?\d{4})?)\s*$/),
           lower.firstMatch(of: /\b(?:show|see|display|view|got|have|any|there)\b/) != nil,
           // "photos of me and donna" is a catalog search for two people,
           // never a portrait of a person named "Me And Donna".
           m.1.firstMatch(of: /\b(?:and|with)\b|&|,/) == nil {
            // "are there are photos of …" (live 2026-08-27, a typo): "there"
            // is a lead word too.
            let name = HallieLineageQuestion.capitalizedName(String(m.1).trimmingCharacters(in: .whitespaces))
            return .personPhoto(person: name)
        }
        // "show me his photo" / "her picture" — the pronoun is the person;
        // preTranslation resolves it from conversation memory.
        if let m = lower.firstMatch(of: /\b(his|her|their)\s+(?:photo|picture|portrait|image)s?\s*$/),
           lower.firstMatch(of: /\b(?:show|see|display|view|got|have|any|find|there)\b/) != nil {
            return .personPhoto(person: HallieLineageQuestion.capitalizedName(String(m.1)))
        }
        // "describe X", "what was X like", "X's appearance/personality/character".
        if let m = lower.firstMatch(of: /^describe\s+(?:the\s+)?([a-z][a-z .'-]+?)(?:'s?\s+(?:physical\s+)?(?:appearance|personality|character|looks|traits))?(?:\s+(?:and|as)\b.*)?$/) {
            let name = String(m.1).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                return .personDescription(person: HallieLineageQuestion.capitalizedName(name),
                                          focus: descriptionFocus(in: lower))
            }
        }
        if let m = lower.firstMatch(of: /\bwhat (?:was|is|were) ([a-z][a-z .'-]+?) like\b/) {
            return .personDescription(person: HallieLineageQuestion.capitalizedName(String(m.1)),
                                      focus: descriptionFocus(in: lower))
        }
        if let m = lower.firstMatch(of: /\b([a-z][a-z .'-]+?)'s\s+(?:physical\s+)?(?:appearance|personality|character|looks)\b/) {
            // "tell me about donna's appearance" — drop the lead words so
            // only the name survives.
            var tokens = String(m.1).split(separator: " ").map(String.init)
            let leads: Set<String> = ["tell", "me", "about", "show", "please",
                                      "hallie", "describe", "us", "what", "was", "is", "the"]
            while let first = tokens.first, leads.contains(first) { tokens.removeFirst() }
            if !tokens.isEmpty {
                return .personDescription(
                    person: HallieLineageQuestion.capitalizedName(tokens.joined(separator: " ")),
                    focus: descriptionFocus(in: lower))
            }
        }

        // "trace (the|our|my|X's) (family|ancestors|links|side…) back to
        // Ireland" — "links"/"side"/"heritage" joined the vocabulary and
        // maternal/paternal restrict the walked line (Rick live, 8/24).
        // Destination forms accept more verbs than bare "trace" — "find my
        // family links back to England" (live, 8/24). Verb+family-word+
        // destination together keep "find videos of donna" out.
        // "… as far back as you can go" / "… as far back as possible" is a
        // depth wish, not a destination; drop it before the trace shapes
        // so "back" inside it can't be mistaken for "back to <country>"
        // (live 2026-08-26). A named start person with no destination
        // becomes an ancestor line at full depth (see `traceTarget`).
        let trace = lower.replacing(/\s+as far (?:back )?as (?:you can(?: go)?|possible|it goes|we can)\s*$/, with: "")
        if let m = trace.firstMatch(of: /\b(?:trace|follow|find|walk|take)\b(.*?)\b(?:back|down|up)(?:\s+to\s+([a-z][a-z .'-]*))?$/) {
            let subject = String(m.1)
            if subject.firstMatch(of: /\b(?:famil\w*|ancest\w*|roots?|line|lineage|links?|side|heritage|people|tree)\b/) != nil {
                let country = m.2.map { String($0).trimmingCharacters(in: .whitespaces) }
                return traceQuestion(person: possessor(in: subject) ?? namedTarget(in: subject),
                                     country: country?.capitalized,
                                     line: lineWord(in: subject))
            }
        }
        // "trace my paternal links to old puritan boston" — no "back".
        if let m = trace.firstMatch(of: /\b(?:trace|follow|walk)\b(.*?)\bto\s+([a-z][a-z .'-]*)$/) {
            let subject = String(m.1)
            if subject.firstMatch(of: /\b(?:famil\w*|ancest\w*|roots?|line|lineage|links?|side|heritage|people|tree)\b/) != nil {
                return traceQuestion(person: possessor(in: subject) ?? namedTarget(in: subject),
                                     country: String(m.2).trimmingCharacters(in: .whitespaces).capitalized,
                                     line: lineWord(in: subject))
            }
        }
        if let m = trace.firstMatch(of: /\btrace\b(.*?)\b(?:ancestors|ancestry|family|roots|line|lineage|links?|side|heritage|people)\b/) {
            // "trace the parker family tree from my great great grandmother
            // edith lucy parker" — the start person is named AFTER the family
            // word, so look in the remainder too (live 2026-08-26).
            let rest = String(trace[m.range.upperBound...])
            return traceQuestion(person: possessor(in: String(m.1)) ?? namedTarget(in: rest),
                                 country: nil, line: lineWord(in: trace))
        }
        // "where does the family come from" / "where did we come from originally"
        if lower.firstMatch(of: /\bwhere (?:did|does|do) (?:the |our |my |we |us )?(?:family|ancestors|people)?\s*(?:originally )?come from\b/) != nil
            || lower.firstMatch(of: /\bwhat country (?:did|does|is) (?:the |our |my )?family (?:come )?from\b/) != nil {
            return .originTrail(person: nil, country: nil, line: .both)
        }

        // "X's great great grandpa on his paternal side" / "my maternal
        // grandmother" — AFTER the trace shapes (where a kinship word is an
        // apposition: "from my great great grandmother edith lucy parker")
        // and BEFORE the line shape, which would otherwise read "paternal
        // side" as a line request and swallow the kinship words into the
        // person (live 2026-08-26).
        // "find rick's grandma muriel and tell me about her": relation +
        // name = one person (live 2026-08-26). After the trace shapes (a
        // trace's start person is the same words after "from"), before
        // the relation-only parser, which steps aside for a trailing name.
        if let named = HallieKinshipApposition.parse(lower) { return .kinshipNamed(named) }
        if let kin = kinshipQuestion(in: lower) { return kin }

        // "(show me) rick's maternal line back 5 generations"
        if let m = lower.firstMatch(of: /(?:^|\s)(.*?)\b(maternal|paternal|mother'?s|father'?s)\s+(?:line|side|ancestors|ancestry|lineage)\b(.*)$/) {
            let line: GedcomFamilyGraph.Line = String(m.2).hasPrefix("m") ? .maternal : .paternal
            let gens = generations(in: String(m.3)) ?? defaultGenerations
            return .ancestorLine(person: possessor(in: String(m.1)) ?? namedTarget(in: String(m.3)),
                                 line: line, generations: gens)
        }
        // "rick's ancestors back 4 generations" / "my ancestry 6 generations"
        if let m = lower.firstMatch(of: /(?:^|\s)(.*?)\b(?:ancestors|ancestry|pedigree)\b(.*?\b(\d+|[a-z]+)\s+generations?)/) {
            let gens = generations(in: String(m.2)) ?? defaultGenerations
            return .ancestorLine(person: possessor(in: String(m.1)) ?? namedTarget(in: String(m.2)),
                                 line: .both, generations: gens)
        }

        // "the family tree from rick breen all the way back to 1600" (live
        // 2026-08-26): a named start and a "back" → an ancestor walk at
        // full depth; "back to <year>" stops the walk at that year.
        let wantsDepth = trace != lower   // "… as far back as you can go" was stripped
        if let m = trace.firstMatch(of: /family tree (?:for|of|from|starting (?:with|from|at)) (the )?([a-z][a-z .'-]+?)(\s+(?:all the way |as far )?back(?:wards?)?(?:\s+to\s+(?:the\s+)?(?:\d{4}s?|[a-z]+))?)?\s*$/),
           m.3 != nil || wantsDepth {
            let name = String(m.2).trimmingCharacters(in: .whitespaces)
            if m.1 != nil {
                return .surnameTree(surname: name.replacingOccurrences(of: " family", with: ""))
            }
            return .ancestorLine(person: capitalizedName(name), line: .both, generations: maxGenerations)
        }
        // "family tree for the latta family" / "the lattas' family tree" /
        // "starting with the latta family" / "the hudson family tree"
        if let m = lower.firstMatch(of: /family tree (?:for|of|starting (?:with|from)) (?:the )?(?:current |present |whole |entire |modern |immediate |original |early )?([a-z][a-z'-]+)(?:'s?)?(?:\s+family|\s+clan|\s+side)?\s*$/) {
            return .surnameTree(surname: String(m.1))
        }
        if let m = lower.firstMatch(of: /\bstarting (?:with|from) (?:the )?([a-z][a-z'-]+)(?:\s+family|\s+clan)?\s*$/),
           lower.contains("tree") || lower.contains("descend") {
            return .surnameTree(surname: String(m.1))
        }
        if let m = lower.firstMatch(of: /\bthe ([a-z][a-z'-]+) family(?:'s)? tree\b/) {
            return .surnameTree(surname: String(m.1))
        }
        // "videos of nathaniel parker sr" — last, and only so the answer
        // can decline for a pre-photography person; see `.personVideos`.
        if let m = lower.firstMatch(of: /\b(?:videos?|films?|footage|movies?|clips?|home movies)\s+of\s+([a-z][a-z .'-]+?)\s*$/) {
            let name = String(m.1).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, name.split(separator: " ").count <= 5 {
                return .personVideos(person: HallieLineageQuestion.capitalizedName(name))
            }
        }
        // "show me his videos" — same pronoun rule as the photo shape.
        if let m = lower.firstMatch(of: /\b(his|her|their)\s+(?:videos?|films?|footage|movies?|clips?|home movies)\s*$/),
           lower.firstMatch(of: /\b(?:show|see|play|find|got|have|any|there)\b/) != nil {
            return .personVideos(person: HallieLineageQuestion.capitalizedName(String(m.1)))
        }
        return nil
    }

    /// The person a photo / video ask is about, when this is one of those
    /// shapes; nil for every other shape.
    var mediaAskPerson: String? {
        switch self {
        case .personPhoto(let person), .personVideos(let person): return person
        default: return nil
        }
    }

    /// The same media ask about a different person (a pronoun resolved from
    /// conversation memory). Other shapes are returned unchanged.
    func replacingMediaAskPerson(with name: String) -> HallieLineageQuestion {
        switch self {
        case .personPhoto: return .personPhoto(person: name)
        case .personVideos: return .personVideos(person: name)
        default: return self
        }
    }

    /// A request to FETCH tree data, as opposed to questions about it.
    /// Requires a fetch verb and a tree/GEDCOM/FamilySearch object; "show
    /// me the family tree" and "what is GEDCOM" are not fetches.
    /// "did we (only) get …", "have you pulled …", "do we have …": the
    /// fetch verb inside an interrogative / past clause. A question about
    /// what we HAVE, never a fetch (live 2026-08-27: "did we only get the
    /// gedcom for Rick" drew the download pitch). "can you fetch" /
    /// "could you get" are requests and are NOT in this list.
    static let interrogativeFetchClause =
        /\b(?:did|do|does|have|has|had)\s+(?:we|you|i|they)\s+(?:only\s+|already\s+|ever\s+|just\s+)?(?:get|got|gotten|fetch(?:ed)?|download(?:ed)?|pull(?:ed)?|import(?:ed)?|grab(?:bed)?|load(?:ed)?|have)\b/

    /// Clause seams for the per-clause veto (codex #754): "do we have the
    /// gedcom, and can you fetch more ancestors?" is a question AND a
    /// request; the request clause wins.
    static let clauseSeam = /\s*(?:,\s*(?:and|but|or)\s+|\s+(?:and|but)\s+|[?;])\s*/

    static func isGetFamilyTree(_ lower: String) -> Bool {
        lower.split(separator: clauseSeam).contains { clause in
            isFetchClause(String(clause))
        }
    }

    /// One clause: a fetch verb + a tree object, phrased as a request or
    /// an imperative. A clause whose fetch verb sits inside "did we /
    /// have you / do we …" is a question about what we have, not a fetch.
    private static func isFetchClause(_ lower: String) -> Bool {
        let verbs = /\b(?:get|fetch|download|pull|import|grab|update|refresh|expand|extend|deepen)\b/
        let object = /\b(?:family ?search|gedcom|(?:family )?tree|ancestors|ancestry|generations)\b/
        guard lower.firstMatch(of: verbs) != nil, lower.firstMatch(of: object) != nil else { return false }
        if lower.firstMatch(of: interrogativeFetchClause) != nil { return false }
        if lower.contains("familysearch") || lower.contains("family search") { return true }
        return lower.firstMatch(of: /\b(?:get|fetch|download|pull|import|grab) (?:more (?:of )?)?(?:the |my |our |a )?(?:whole |entire |full |bigger |deeper |updated |new |latest )?(?:family )?(?:tree|gedcom|ancestors|ancestry)\b/) != nil
            || lower.firstMatch(of: /\b(?:more|deeper|further|older) (?:generations|ancestors)\b/) != nil
            || lower.firstMatch(of: /\b(?:update|refresh|expand|extend|deepen) (?:the |my |our )?(?:family )?tree\b/) != nil
    }

    /// The interrogative fetch clause with a tree object AND a named
    /// person or surname → a coverage question. With neither ("where did
    /// we get the gedcom") this steps aside for `.gedcomAwareness`, which
    /// reports the file's folder and date (codex #754). Person = up to
    /// three name tokens after "from"/"for" (trace start first: "from
    /// donna … for rick" is about Donna); surname = "the hudson line/
    /// side/family" or "for the hudsons".
    static func gedcomProvenanceQuestion(in lower: String) -> HallieLineageQuestion? {
        guard lower.firstMatch(of: interrogativeFetchClause) != nil,
              lower.firstMatch(of: /\b(?:gedcom|family ?search|(?:family )?tree|ancestors|ancestry)\b/) != nil
        else { return nil }
        var surname: String?
        if let m = lower.firstMatch(of: /\bthe ([a-z][a-z'-]+) (?:line|side|family|branch|lineage)\b/) {
            surname = String(m.1)
        } else if let m = lower.firstMatch(of: /\b(?:for|of|from) the ([a-z][a-z'-]+s)\b/) {
            surname = String(m.1)
        }
        let stop: Set<String> = ["the", "my", "our", "your", "a", "an", "this", "that", "it", "or", "and",
                                 "but", "did", "do", "does", "have", "has", "we", "you", "i", "they",
                                 "only", "yet", "already", "just", "from", "for", "of", "familysearch",
                                 "family", "search", "gedcom", "tree", "ancestors", "ancestry", "side",
                                 "line", "branch", "lineage", "here", "there", "back", "then"]
        var person: String?
        for m in lower.matches(of: /\b(?:from|for)\s+((?:[a-z][a-z'-]*\s*){1,3})/) where person == nil {
            var tokens: [String] = []
            for raw in String(m.1).split(separator: " ") {
                let word = raw.replacingOccurrences(of: "'s", with: "").replacingOccurrences(of: "'", with: "")
                if stop.contains(word) || word == surname { break }
                tokens.append(word)
            }
            if !tokens.isEmpty { person = capitalizedName(tokens.joined(separator: " ")) }
        }
        guard person != nil || surname != nil else { return nil }
        return .gedcomProvenance(person: person, surname: surname)
    }

    /// Two names joined by "and" plus a relatedness word. Each pattern
    /// captures exactly the two names; "me" / "i" / "myself" become the
    /// owner (nil). A media noun anywhere means a catalog ask — not ours.
    static func commonAncestorQuestion(in lower: String) -> HallieLineageQuestion? {
        guard lower.firstMatch(of: mediaNoun) == nil else { return nil }
        let patterns: [Regex<(Substring, Substring, Substring)>] = [
            /\b(?:how|so how)\s+(?:is|are|was|were)\s+([a-z][a-z .'-]*?)\s+(?:and|&)\s+([a-z][a-z .'-]*?)\s+(?:related|connected|linked|kin)\b/,
            /\b(?:how|so how)\s+(?:is|are|was|were)\s+([a-z][a-z .'-]*?)\s+related\s+to\s+([a-z][a-z .'-]*?)\s*$/,
            /^(?:so\s+)?(?:is|are|was|were)\s+([a-z][a-z .'-]*?)\s+(?:and|&)\s+([a-z][a-z .'-]*?)\s+(?:related|connected|kin|cousins|blood relatives|relatives)(?:\s+(?:at all|somehow|by blood))?\s*$/,
            /^(?:so\s+)?(?:is|are|was|were)\s+([a-z][a-z .'-]*?)\s+related\s+to\s+([a-z][a-z .'-]*?)\s*$/,
            // "most recent" / "latest" / "recent" common ancestor, and a
            // trailing "born 1959" qualifier (Rick 2026-08-28 live).
            /\b(?:nearest|closest|common|shared|most recent|latest|recent|first)\s+(?:common\s+|shared\s+)?ancestors?\s+(?:of|between|for|shared by)\s+([a-z][a-z .'-]*?)\s+(?:and|&)\s+([a-z][a-z .'-]*?)(?:\s+(?:born|b\.)\s+(?:in\s+)?\d{4})?\s*$/,
            /\b(?:do|did|does)\s+([a-z][a-z .'-]*?)\s+(?:and|&)\s+([a-z][a-z .'-]*?)\s+(?:share|have)\s+(?:an?\s+|any\s+)?(?:common\s+|shared\s+)?ancestors?\b/,
            /\bwhat\s+(?:do|does|did)\s+([a-z][a-z .'-]*?)\s+(?:and|&)\s+([a-z][a-z .'-]*?)\s+have\s+in\s+common\s+(?:ancestrally|genealogically|in the (?:family )?tree|as ancestors)\b/,
            /\b([a-z][a-z .'-]*?)\s+(?:and|&)\s+([a-z][a-z .'-]*?)'?s?\s+(?:nearest\s+|closest\s+)?(?:common|shared)\s+ancestors?\b/,
            /\bwho\s+(?:is|was)\s+(?:the\s+)?(?:nearest\s+|closest\s+|most recent\s+)?(?:common|shared)\s+ancestor\s+(?:of|between)\s+([a-z][a-z .'-]*?)\s+(?:and|&)\s+([a-z][a-z .'-]*?)(?:\s+(?:born|b\.)\s+(?:in\s+)?\d{4})?\s*$/,
            /\bwhere\s+(?:do|does|did)\s+([a-z][a-z .'-]*?)(?:'s)?\s+(?:and|&)\s+([a-z][a-z .'-]*?)(?:'s)?\s+(?:lines?|trees?|famil(?:y|ies)|ancestr(?:y|ies))\s+(?:meet|cross|join|connect|converge)\b/,
        ]
        for pattern in patterns {
            guard let m = lower.firstMatch(of: pattern) else { continue }
            guard let a = commonAncestorName(String(m.1)), let b = commonAncestorName(String(m.2)) else { continue }
            // Both the owner ("me and myself") is nobody's question.
            if a.name == nil && b.name == nil { return nil }
            return .commonAncestor(a: a.name, b: b.name)
        }
        return nil
    }

    /// The typed side of a pair: `(name: nil)` for the owner, nil when the
    /// words are not a person at all ("they", "the family").
    private static func commonAncestorName(_ raw: String) -> (name: String?, Void)? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        for lead in ["the ", "my wife ", "my husband "] where s.hasPrefix(lead) && s.count > lead.count {
            if lead == "the " { return nil }
            s = String(s.dropFirst(lead.count))
        }
        s = s.replacing(/'s?$/, with: "")
        let owner: Set<String> = ["me", "i", "myself", "my", "mine"]
        let nobody: Set<String> = ["they", "them", "we", "us", "you", "he", "she", "it", "family", "everyone", "anyone", "people", "each other"]
        if owner.contains(s) { return (nil, ()) }
        if nobody.contains(s) || s.isEmpty { return nil }
        guard s.split(separator: " ").count <= 5 else { return nil }
        return (capitalizedName(s), ())
    }

    static func isGedcomAwareness(_ lower: String) -> Bool {
        if lower.contains("gedcom") {
            let cues = ["what is", "what's", "whats", "explain", "where", "which file", "come from",
                        "source", "how do you", "tell me about", "mean", "loaded", "using"]
            return cues.contains { lower.contains($0) } || lower.split(separator: " ").count <= 3
        }
        return lower.firstMatch(of: /\bwhere (?:does|did|is) (?:your|the) (?:family )?tree (?:come from|from|loaded)/) != nil
            || lower.firstMatch(of: /\bhow do you know (?:the|our|my) family tree\b/) != nil
            || lower.firstMatch(of: /\bwhat (?:family )?tree (?:file )?(?:are you|do you) (?:using|reading)\b/) != nil
    }

    // MARK: Helpers

    static func normalize(_ text: String) -> String {
        var s = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = s.last, "?!.".contains(last) { s.removeLast() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// "show me rick's" → "rick"; "my" / "our" / "me" → nil (the owner);
    /// "the family" → nil. Strips leading verbs and articles.
    /// Words a question puts in front of the person that are not part of
    /// the name. Longer forms first ("tell me about" before "tell me") so
    /// "about" is not left behind as a first name (live 2026-08-26:
    /// "About Rick Breen's …" was looked up in the tree).
    static let leadWords = [
        "please ", "hallie ", "show me ", "show ", "tell me about ", "tell me ", "tell us about ",
        "give me ", "what about ", "what is ", "what's ", "who is ", "who was ", "who were ",
        "who's ", "about ", "list ", "can you ", "could you ", "draw ", "display ", "trace ",
        "find ",
    ]

    static func possessor(in fragment: String) -> String? {
        var s = fragment.trimmingCharacters(in: .whitespaces)
        var stripped = true
        while stripped {
            stripped = false
            for lead in leadWords where s.hasPrefix(lead) {
                s = String(s.dropFirst(lead.count))
                stripped = true
            }
        }
        // Trailing nouns the question attached to the person: "rick's
        // ancestors" → "rick's"; "the family" → "the".
        while let m = s.firstMatch(of: /\s*\b(?:family|ancestors|ancestry|roots|line|lineage|links?|heritage|tree|people|side|pedigree|maternal|paternal|mother'?s|father'?s)\b\s*$/) {
            s = String(s[s.startIndex..<m.range.lowerBound])
        }
        s = s.trimmingCharacters(in: .whitespaces)
        let owners: Set<String> = ["", "my", "our", "me", "mine", "us", "we", "the", "this", "that", "of"]
        if let m = s.firstMatch(of: /^(.+?)'s?$/) {
            let name = String(m.1).trimmingCharacters(in: .whitespaces)
            return owners.contains(name) ? nil : capitalizedName(name)
        }
        if owners.contains(s) || s.hasPrefix("the ") { return nil }
        if s.firstMatch(of: /^(?:of |for )?([a-z][a-z .'-]*)$/) != nil {
            let name = s.replacingOccurrences(of: "^(?:of |for )", with: "", options: .regularExpression)
            return owners.contains(name) ? nil : capitalizedName(name)
        }
        return nil
    }

    /// A possessive or first-person MULTI-HOP ancestor phrase:
    ///   "<lead words> <person>'s [maternal|paternal] (great )*grand<x>
    ///    [on his|her|my|the paternal|maternal|father's|mother's side]"
    ///   "my/our (great )*grand<x> …"
    /// Single-hop words (father, mother, brother…) are left to the
    /// translator, whose closed vocabulary already handles them; this
    /// exists because "great great grandpa on his paternal side" had no
    /// deterministic home. The relation words come from the graph's own
    /// `extendedRelation(fromPhrase:)` table so nothing is named here that
    /// the traversal cannot walk; an unknown word ("grandson") → nil.
    static func kinshipQuestion(in lower: String) -> HallieLineageQuestion? {
        // The relation word: "(great )*grand<x>", "3rd great grand<x>",
        // "5x great grand<x>", "three times great grand<x>".
        let pattern = /(?:^|\s)(?:(my|our)|([a-z][a-z .'-]*?)'s?)\s+(?:(maternal|paternal|mother'?s|father'?s)\s+)?((?:(?:\d+|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|twelfth)(?:st|nd|rd|th)?[- ]?(?:x|times)?[- ]?great[- ]?|(?:great[- ]?)+)?grand[a-z]+)(?:\s+on\s+(?:his|her|my|our|their|the)\s+(paternal|maternal|father'?s|mother'?s)\s+side)?\b/
        guard let m = lower.firstMatch(of: pattern) else { return nil }
        // Only the whole question: more words after the relation ("…'s
        // grandfather's farm", "… grandmother edith lucy parker") mean a
        // different shape, and the translator or trace regexes own those.
        let rest = lower[m.range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard rest.isEmpty || rest.firstMatch(of: /^(?:please|hallie|thanks|for me)\b/) != nil else { return nil }
        let sideWord = m.3.map(String.init) ?? m.5.map(String.init)
        let side: ArchivistQueryAST.Graph.Side? = sideWord.map { $0.hasPrefix("m") ? .maternal : .paternal }
        // possessor() strips the lead words ("tell me about"); nil means
        // nobody in particular ("the family's") → not ours.
        let person: String?
        if m.1 != nil {
            person = nil
        } else if let named = possessor(in: String(m.2 ?? "") + "'s") {
            person = named
        } else {
            return nil
        }
        guard let counted = greatCount(in: String(m.4)) else { return nil }
        let (greats, noun) = counted
        if greats <= 2 {
            // The closed vocabulary's own table names the relation (and
            // refuses words the traversal cannot walk, e.g. "grandson").
            let words = String(repeating: "great ", count: greats) + noun
            guard let parsed = GedcomFamilyGraph.extendedRelation(fromPhrase: words),
                  parsed.relation.startsAtParents,
                  let relation = ArchivistQueryAST.Graph.Relation(rawValue: parsed.relation.rawValue)
            else { return nil }
            return .kinship(person: person, relation: relation, side: side)
        }
        guard let sex = grandparentSex(noun) else { return nil }
        return .deepAncestor(person: person, depth: greats + 2, sex: sex, side: side)
    }

    /// "great great great grandpa" → (3, "grandpa"); "3rd great
    /// grandfather" → (3, "grandfather"); "5x great grandmother" → (5,
    /// "grandmother"); "grandma" → (0, "grandma"). Nil when the noun is
    /// not a grand-word.
    static func greatCount(in phrase: String) -> (Int, String)? {
        let words = phrase.replacingOccurrences(of: "-", with: " ")
            .split(separator: " ").map(String.init)
        guard let noun = words.last, noun.hasPrefix("grand") else { return nil }
        let ordinals = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
                        "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "twelfth": 12]
        var counted = 0
        var explicit: Int?
        for word in words.dropLast() {
            if word == "great" { counted += 1; continue }
            if word == "x" || word == "times" { continue }
            if let n = ordinals[word] { explicit = n; continue }
            // "3rd", "5x", "4times" — the digits carry the number.
            let digits = word.trimmingCharacters(in: CharacterSet.decimalDigits.inverted)
            if !digits.isEmpty, let n = Int(digits) { explicit = n; continue }
        }
        // "3rd great grandfather" = 3 greats: the number IS the count and
        // the single "great" after it is spelling, not another step.
        return (min(explicit ?? counted, 40), noun)
    }

    /// "M" / "F" / "" (grandparents) for the deep walk; nil = not an
    /// ancestor word the walk can name ("grandson").
    static func grandparentSex(_ noun: String) -> String? {
        switch noun {
        case "grandfather", "grandpa", "granddad", "grandad", "grampa", "grandpop", "grandfathers", "grandpas": return "M"
        case "grandmother", "grandma", "granny", "nana", "gram", "grandmothers", "grandmas": return "F"
        case "grandparents", "grandparent": return ""
        default: return nil
        }
    }

    // MARK: Superlatives

    static let mediaNoun = /\b(photo|picture|portrait|image|video|clip|movie|footage|film|snapshot)s?\b/

    static func superlativeQuestion(in lower: String) -> HallieLineageQuestion? {
        // Media wrapper: "<anything> photo of (the) <person phrase>".
        if let m = lower.firstMatch(of: /\b(photo|picture|portrait|image|video|clip|movie|footage|film|snapshot)s?\s+of\s+(.+)$/) {
            let phrase = String(m.2).trimmingCharacters(in: .whitespaces)
            guard phrase.firstMatch(of: mediaNoun) == nil,
                  let parsed = superlativeKindAndScope(in: phrase) else { return nil }
            return .superlative(kind: parsed.0, scope: parsed.1, media: String(m.1))
        }
        // A media question that is not the wrapper shape ("oldest video in
        // the catalog") belongs to the catalog routes.
        guard lower.firstMatch(of: mediaNoun) == nil,
              let parsed = superlativeKindAndScope(in: lower) else { return nil }
        return .superlative(kind: parsed.0, scope: parsed.1, media: nil)
    }

    private static let superlativeWords = /\b(?:oldest|eldest|youngest|earliest|latest|first|last|longest|most|deepest|farthest|furthest|distant|largest|biggest|recent(?:ly)?|how far back)\b/

    /// The kind and scope of a superlative person phrase, or nil when
    /// the phrase is not one ("who was rick's oldest son" is a kinship
    /// question the translator lists in full).
    static func superlativeKindAndScope(in text: String) -> (SuperlativeKind, SuperlativeScope)? {
        guard text.firstMatch(of: superlativeWords) != nil else { return nil }
        // A superlative on a kin word ("oldest son", "first cousin") or on
        // a thing ("oldest house") is not a ranking over the tree.
        if text.firstMatch(of: /\b(?:oldest|eldest|youngest|first|last)\s+(?:born\s+)?(?:son|daughter|child|kid|brother|sister|sibling|grand\w+|boy|girl|cousin|uncle|aunt|nephew|niece|wife|husband|marriage)\b/) != nil {
            return nil
        }
        let kind: SuperlativeKind
        if let m = text.firstMatch(of: /\b(?:first|earliest|oldest)\b.*\bborn\s+in\s+(?:the\s+)?([a-z][a-z .'-]+?)\s*$/) {
            kind = .firstBornIn(place: capitalizedName(String(m.1).trimmingCharacters(in: .whitespaces)))
        } else if text.firstMatch(of: /\b(?:deepest|farthest|furthest|most distant|remotest)\b[a-z' ]*\bancestors?\b/) != nil
                    || text.firstMatch(of: /\bancestors?\b.*\b(?:farthest|furthest|deepest|most distant)\s+back\b/) != nil
                    || text.firstMatch(of: /\bhow far back\b.*\b(?:go|goes|reach|reaches)\b/) != nil {
            kind = .deepestAncestor
        } else if text.firstMatch(of: /\b(?:lived?|living)\s+(?:the\s+)?longest\b|\blongest[- ](?:lived|living|life)\b|\b(?:oldest|greatest|highest)\s+age\b|\bmost\s+years\b/) != nil {
            kind = .longestLived
        } else if text.firstMatch(of: /\b(?:most\s+recent(?:ly)?|last|latest)\b[a-z' ]*\b(?:died|death|passed|die)\b|\b(?:died|passed(?: away)?)\s+(?:most\s+recently|last|latest)\b/) != nil {
            kind = .latestDied
        } else if text.firstMatch(of: /\b(?:earliest|first|oldest)\b[a-z' ]*\b(?:married|marriage|marry|wedding|wed)\b|\b(?:married|wed)\s+(?:first|earliest)\b/) != nil {
            kind = .earliestMarried
        } else if text.firstMatch(of: /\bmost\s+(?:children|kids|sons|daughters|offspring|descendants)\b|\b(?:largest|biggest)\s+(?:family|brood|household)\b/) != nil {
            kind = .mostChildren
        } else if text.firstMatch(of: /\byoungest\b|\b(?:latest|most\s+recent(?:ly)?|last)\s+(?:born|birth)\b|\bborn\s+(?:last|most\s+recently|latest)\b/) != nil {
            kind = .latestBorn
        } else if text.firstMatch(of: /\boldest\b|\beldest\b|\bearliest\s+(?:birth|born)\b|\bborn\s+(?:first|earliest)\b|\bfirst\s+(?:person\s+|one\s+)?born\b|\bearliest\b[a-z' ]*\bbirth\b/) != nil {
            // "oldest" alone must be about a person: "oldest person", "the
            // oldest breen", "oldest member of the family"…
            guard text.firstMatch(of: /\b(?:persons?|people|members?|relatives?|ancestors?|forebears?|ones?|man|men|woman|women|male|female|birth|born|individuals?|humans?|guys?|lady|family|tree|surname|named|lineage|line)\b/) != nil
                || text.firstMatch(of: /\b(?:oldest|eldest)\s+[a-z]+s?\s*$/) != nil else { return nil }
            kind = .earliestBorn
        } else {
            return nil
        }

        // Scope. Deepest-ancestor is always "of somebody" (default: owner).
        var scope: SuperlativeScope = .wholeTree
        // "my/our family tree" is the whole tree, not an ancestor scope.
        if let m = text.firstMatch(of: /\b(?:of|among|in|from)\s+(?:(my|our)|([a-z][a-z .'-]*?)'s?)\s+(?:ancestors|ancestry|forebears|line|lineage|pedigree)\b/) {
            scope = .ancestorsOf(m.1 != nil ? nil : possessor(in: String(m.2 ?? "") + "'s"))
            if case .ancestorsOf(nil) = scope, m.2 != nil { scope = .wholeTree }
        } else if let m = text.firstMatch(of: /\bancestors?\s+of\s+(?:(me|mine|myself|ours|us)|([a-z][a-z .'-]*?))\s*$/) {
            scope = .ancestorsOf(m.1 != nil ? nil : capitalizedName(String(m.2 ?? "")))
        } else if let m = text.firstMatch(of: /\b(?:my|our)\s+(?:oldest|earliest|deepest|farthest|furthest|most distant|remotest)\s+ancestor/) {
            _ = m; scope = .ancestorsOf(nil)
        } else if let m = text.firstMatch(of: /\b(?:named|surnamed|called|with the (?:last name|surname|family name))\s+([a-z]+)\b/) {
            scope = .surname(String(m.1))
        } else if let m = text.firstMatch(of: /\b(?:in|of|among)\s+the\s+([a-z]+)\s+(?:family|clan|line)\b/) {
            scope = .surname(String(m.1))
        } else if let m = text.firstMatch(of: /\b(?:of|among|in)\s+the\s+([a-z]+)s\s*$/) {
            scope = .surname(String(m.1))   // "of the breens"
        } else if let m = text.firstMatch(of: /\b(?:oldest|eldest|youngest|earliest|first|last)\s+([a-z]+)\b/),
                  !superlativeStopWords.contains(String(m.1)) {
            scope = .surname(String(m.1))   // "the oldest breen"
        }
        if kind == .deepestAncestor, case .wholeTree = scope { scope = .ancestorsOf(nil) }
        return (kind, scope)
    }

    /// Words that follow "oldest" without naming a surname.
    private static let superlativeStopWords: Set<String> = [
        "person", "people", "member", "members", "one", "ones", "ancestor", "ancestors", "relative",
        "relatives", "man", "woman", "male", "female", "birth", "born", "living", "recorded", "known",
        "age", "family", "married", "marriage", "child", "children", "kid", "kids", "of", "in", "the",
        "generation", "individual", "human", "guy", "lady", "to", "and", "with", "that", "who", "whom",
        "year", "years", "date", "dated", "death", "died", "life", "lived", "surviving", "known", "name",
        "named", "entry", "record", "records", "recorded", "surname", "tree", "line", "photo", "picture",
    ]

    /// Shape for the trace verbs once the start person is known. A NAMED
    /// start with no destination ("trace the tree from Edith Lucy Parker
    /// as far back as you can go") is an ancestor walk at full depth —
    /// an origin trail with no country would only report birthplaces.
    /// The unnamed / possessive forms keep their 2026-08-22 behaviour.
    static func traceQuestion(person: String?, country: String?,
                              line: GedcomFamilyGraph.Line) -> HallieLineageQuestion {
        if let person, country == nil {
            return .ancestorLine(person: person, line: line, generations: maxGenerations)
        }
        return .originTrail(person: person, country: country, line: line)
    }

    /// Kinship words that can sit between a preposition and the actual
    /// name as an apposition: "from my great great grandmother edith lucy
    /// parker", "from Richard Breen Sr great grandmother edith lucy parker".
    /// The NAME AFTER the last kinship phrase wins — the kinship words are
    /// descriptive, and a name plus a relation is one person, not two.
    private static let kinshipApposition =
        /(?:\b(?:great|grand)[- ]?)*\b(?:grand)?(?:mother|father|mom|dad|parents?|aunt|uncle|cousin|sister|brother|wife|husband|son|daughter|ancestor)s?\b/

    /// "… from <name>" / "starting with <name>" / "of <name>" / "for <name>"
    /// anywhere in `fragment` → the capitalized name; nil when nothing is
    /// named or the object is the owner / a "the …" family reference
    /// (surname forms are handled by their own regexes). Trailing
    /// "family/tree/back/N generations" words are stripped.
    static func namedTarget(in fragment: String) -> String? {
        guard let m = fragment.firstMatch(of: /\b(?:from|starting (?:with|from|at)|beginning (?:with|at)|of|for)\s+(.+)$/) else {
            return nil
        }
        var s = String(m.1).trimmingCharacters(in: .whitespaces)
        // Peel trailing non-name words one at a time ("donna back 5
        // generations" → "donna back" → "donna").
        while let t = s.firstMatch(of: /\s*\b(?:as far (?:back )?as .*|back(?:wards?)?|(?:\d+|[a-z]+)\s+generations?|family|tree|line|lineage|ancestors|ancestry|side|onwards?)\s*$/) {
            s = String(s[s.startIndex..<t.range.lowerBound])
        }
        // Apposition: keep what follows the LAST kinship phrase, if anything does.
        if let last = s.matches(of: kinshipApposition).last {
            let after = String(s[last.range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !after.isEmpty else { return nil }
            s = after
        }
        // "of the lattas" / "for the breen family" is a family reference,
        // not a person — the surname regexes own those.
        if s.hasPrefix("the ") { return nil }
        s = s.replacing(/^(?:my|our|his|her|their)\s+/, with: "")
        s = s.replacing(/'s?$/, with: "").trimmingCharacters(in: .whitespaces)
        let owners: Set<String> = ["", "my", "our", "me", "mine", "us", "we", "the", "this", "that", "here", "there"]
        if owners.contains(s) { return nil }
        guard s.firstMatch(of: /^[a-z][a-z .'-]*$/) != nil else { return nil }
        return capitalizedName(s)
    }

    static func capitalizedName(_ name: String) -> String {
        name.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
    }

    /// "maternal" / "mother's" → .maternal; "paternal" / "father's" →
    /// .paternal; anything else → .both.
    static func lineWord(in text: String) -> GedcomFamilyGraph.Line {
        if text.firstMatch(of: /\b(?:maternal|mother'?s)\b/) != nil { return .maternal }
        if text.firstMatch(of: /\b(?:paternal|father'?s)\b/) != nil { return .paternal }
        return .both
    }

    static func descriptionFocus(in text: String) -> DescriptionFocus {
        if text.firstMatch(of: /\b(?:appearance|looks|physical)\b/) != nil { return .appearance }
        if text.firstMatch(of: /\b(?:personality|character|traits)\b/) != nil { return .personality }
        return .general
    }

    /// Cue words for ranking told accounts under a focused ask. Ranking
    /// only — accounts are never edited or excluded by these.
    static let appearanceCues: Set<String> = [
        "slim", "tall", "short", "hair", "eyes", "attractive", "beautiful",
        "handsome", "striking", "blonde", "blond", "brunette", "redhead",
        "looks", "looked", "pretty", "petite", "wore", "smile",
    ]
    static let personalityCues: Set<String> = [
        "kind", "smart", "funny", "gracious", "warm", "generous", "patient",
        "gentle", "caring", "easy", "going", "standards", "angelic", "loving",
        "wise", "stubborn", "determined", "hardworking", "witty", "quiet",
        "outgoing", "personality",
    ]

    static func generations(in text: String) -> Int? {
        guard let m = text.firstMatch(of: /(\d+|one|two|three|four|five|six|seven|eight|nine|ten|twelve)\s+generations?/) else { return nil }
        let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                     "eight": 8, "nine": 9, "ten": 10, "twelve": 12]
        let raw = String(m.1)
        let n = Int(raw) ?? words[raw] ?? defaultGenerations
        return min(max(1, n), maxGenerations)
    }

    static func possessive(_ name: String) -> String {
        name.hasSuffix("s") ? name + "’" : name + "’s"
    }

    /// "back to 1600" / "before 1700" / "until the 1600s" / "as far as
    /// 1750" → the year. "the 1600s" reads as 1600 (the start of that
    /// century). Only four-digit years between 1000 and 2100.
    /// Deliberately without "back": stripping "to 1600" from "all the way
    /// back to 1600" leaves the "back" the depth shapes key on.
    static let yearBoundPhrase = /\s*\b(?:before|until|till|up to|as far back as|as far as|to)\s+(?:the\s+)?(\d{4})s?\b/
    static func yearBound(in text: String) -> Int? {
        guard let m = text.firstMatch(of: yearBoundPhrase),
              let year = Int(m.1), (1000...2100).contains(year) else { return nil }
        return year
    }
}

// MARK: - Answers

enum HallieLineageAnswer {
    typealias Result = HallieTurnExecutor.Result

    /// Nil = not ours after all; let the question continue as typed.
    static func answer(_ question: HallieLineageQuestion,
                       context: HallieTurnExecutor.Context) -> Result? {
        switch question {
        case .gedcomAwareness:
            return gedcomAwareness(context.graph)
        case .getFamilyTree:
            return getFamilyTreeAnswer(context.graph)
        case .gedcomProvenance(let person, let surname):
            return gedcomProvenance(person: person, surname: surname, context: context)
        case .commonAncestor(let a, let b):
            return commonAncestor(a, b, context: context)
        case .personDescription(let person, let focus):
            return personDescription(person, focus: focus, context: context)
        case .personPhoto(let person):
            return personPhoto(person, context: context)
        case .personVideos(let person):
            return personVideos(person, context: context)
        case .kinship:
            // Not answered here: preTranslation turns it into a graph
            // kinship intent and the ordinary executor route runs it.
            return nil
        case .kinshipNamed(let apposition):
            return kinshipApposition(apposition, context: context)
        case .superlative(let kind, let scope, _):
            guard let graph = context.graph else { return noTree() }
            return superlative(kind, scope: scope, graph: graph, context: context)
        case .deepAncestor(let person, let depth, let sex, let side):
            guard let graph = context.graph else { return noTree() }
            switch resolve(person, context: context, graph: graph) {
            case .failure(let r): return r
            case .success(let p, let note):
                return deepAncestors(of: p, depth: depth, sex: sex, side: side, graph: graph, basisNote: note)
            }
        case .surnameTree(let surname):
            guard let graph = context.graph else { return noTree() }
            return surnameTree(surname, graph: graph)
        case .ancestorLine(let person, let line, let generations, let untilYear):
            guard let graph = context.graph else { return noTree() }
            switch resolve(person, context: context, graph: graph) {
            case .failure(let r): return r
            case .success(let p, let note):
                return ancestorLine(of: p, line: line, generations: generations, untilYear: untilYear,
                                    graph: graph, basisNote: note)
            }
        case .originTrail(let person, let country, let line):
            guard let graph = context.graph else { return noTree() }
            switch resolve(person, context: context, graph: graph) {
            case .failure(let r): return r
            case .success(let p, let note):
                return originTrail(of: p, country: country, line: line, graph: graph, basisNote: note)
            }
        }
    }

    // MARK: Person resolution (shared resolver, same rules as every graph route)

    /// `note` = how "you" was pinned when it took a fallback step, for the
    /// basis line; nil for an ordinary named lookup.
    enum Resolved: Equatable {
        case success(GedcomFamilyGraph.Person, note: String? = nil)
        case failure(Result?)
    }

    /// The owner fallback chain (2026-08-26). Used when no person was
    /// typed, or the typed name IS the signed-in owner (so "Rick's line"
    /// and "my line" resolve identically). Steps, in order:
    ///   (i)   CyberBrain gedcomPersonID — handled by the caller first.
    ///   (ii)  `people(namedLike:)`: diminutive- and suffix-tolerant
    ///         ("Rick Breen" ~ "Richard Harding Breen Jr"). One hit → it.
    ///         Several → the tree root if it is among them (never silently
    ///         Sr over Jr), else ask which one.
    ///   (iii) No hit at all → the tree root person (first INDI in file
    ///         order; getmyancestors/FamilySearch put the home person
    ///         first — an assumption, so the basis line says "tree root").
    static func resolveOwner(_ name: String, graph: GedcomFamilyGraph,
                             familySearchID: String? = nil) -> Resolved {
        // The chain itself lives in HallieOwnerResolver (shared with the
        // graph kinship route and "my dad" rebinding, 2026-08-26).
        switch HallieOwnerResolver.resolve(name, graph: graph, familySearchID: familySearchID) {
        case .one(let person, let note):
            return .success(person, note: note)
        case .many(let like):
            return .failure(Result(
                route: .graph, outcome: .needsClarification,
                prose: "Which \(name) do you mean — " + like.prefix(4).map(\.name).joined(separator: " or ") + "?",
                basisLine: "Basis: the family tree has \(like.count) people matching \(name) and no root marker to prefer; nothing was looked up.",
                queryDescription: "lineage: resolve \(name)", citations: [], catalogPersonName: nil))
        case .none(let reason):
            // A stale explicit FamilySearch pin fails closed with the honest
            // line (codex #707 item 4); an ordinary miss keeps the generic
            // decline from the caller.
            guard let reason else { return .failure(nil) }
            return .failure(Result(
                route: .graph, outcome: .declined,
                prose: reason,
                basisLine: "Basis: the configured FamilySearch ID is not in the installed tree; nothing was looked up.",
                queryDescription: "lineage: stale owner pin", citations: [], catalogPersonName: nil))
        }
    }

    /// `resolve` with the which-one case exposed, for callers that can
    /// offer chips (the photo ask) instead of a declined sentence.
    enum Detailed: Equatable {
        case success(GedcomFamilyGraph.Person, note: String? = nil)
        case ambiguous([GedcomFamilyGraph.Person])
        case failure(Result?)
    }

    static func resolve(_ typed: String?,
                        context: HallieTurnExecutor.Context,
                        graph: GedcomFamilyGraph) -> Resolved {
        switch resolveDetailed(typed, context: context, graph: graph) {
        case .success(let p, let note): return .success(p, note: note)
        case .failure(let r): return .failure(r)
        case .ambiguous(let people):
            let name = typed ?? context.speakers.ownerName ?? ""
            return .failure(whichOne(name, among: people))
        }
    }

    /// The declined which-one sentence, with each namesake's years so the
    /// next reply can say "the one born in 1651".
    static func whichOne(_ typed: String, among people: [GedcomFamilyGraph.Person]) -> Result {
        let labels = people.map { ArchivistBiographyPolicy.disambiguationCandidate(for: $0).label }
        return Result(
            route: .graph, outcome: .needsClarification,
            prose: "Which \(HallieLineageQuestion.capitalizedName(typed)) do you mean — " + HallieNameQualifier.joined(labels, conjunction: "or") + "?",
            basisLine: "Basis: the family tree has \(people.count) people by that name; nothing was looked up.",
            queryDescription: "lineage: resolve \(typed)", citations: [], catalogPersonName: nil)
    }

    /// "Nathaniel Parker born 1651" (HallieNameQualifier — TEMPORARY, see
    /// that file): the namesakes by the bare name, narrowed by the exact
    /// year. One → that person; several still → which-one with years;
    /// none → the honest miss naming the years the tree does have. Nil =
    /// no qualifier, or no namesake at all (the ordinary resolver then
    /// says "I don't find …").
    static func resolveQualified(_ typed: String, graph: GedcomFamilyGraph) -> Detailed? {
        guard let qualified = HallieNameQualifier.parse(typed) else { return nil }
        let namesakes = graph.people(namedLike: qualified.name)
        guard !namesakes.isEmpty else { return nil }
        let picked = qualified.select(namesakes)
        switch picked.count {
        case 1:
            return .success(picked[0])
        case 0:
            let shown = HallieLineageQuestion.capitalizedName(qualified.name)
            let plural = namesakes.count == 1 ? shown : shown + "s"
            let have = namesakes.count == 1
                ? "I have one \(shown), \(HallieNameQualifier.yearsPhrase(namesakes, kind: qualified.kind))"
                : "I have \(HallieNameQualifier.countWord(namesakes.count)) \(plural), \(HallieNameQualifier.yearsPhrase(namesakes, kind: qualified.kind))"
            let neither = namesakes.count == 2 ? "neither" : (namesakes.count == 1 ? "not" : "none")
            return .failure(Result(
                route: .graph, outcome: .declined,
                prose: "\(have) — \(neither) \(qualified.kind.description).",
                basisLine: "Basis: family tree dates for the \(namesakes.count) namesake\(namesakes.count == 1 ? "" : "s"); nothing else was looked up.",
                queryDescription: "lineage: resolve \(typed) (no namesake \(qualified.kind.description))",
                citations: [], catalogPersonName: nil))
        default:
            return .ambiguous(picked)
        }
    }

    static func resolveDetailed(_ typed: String?,
                                context: HallieTurnExecutor.Context,
                                graph: GedcomFamilyGraph) -> Detailed {
        if let typed, let qualified = resolveQualified(typed, graph: graph) {
            return qualified
        }
        guard let name = typed ?? context.speakers.ownerName else {
            return .failure(Result(
                route: .graph, outcome: .needsClarification,
                prose: "Whose line would you like? For example: “show Donna’s maternal line back five generations.”",
                basisLine: "Basis: no person named and no owner is signed in; nothing was looked up.",
                queryDescription: "lineage: person missing", citations: [], catalogPersonName: nil))
        }
        // Step 0 (2026-08-26): the owner's FamilySearch ID pins "me" / the
        // owner's own name to one record before any name or alias lookup.
        let isOwnerSpelling = typed == nil
            || HallieOwnerResolver.isOwnerSpelling(name, owner: context.speakers.ownerName)
        if isOwnerSpelling,
           case .one(let pinned, let note) = HallieOwnerResolver.resolve(
               name, graph: graph, familySearchID: context.speakers.ownerFamilySearchID),
           graph.person(familySearchID: context.speakers.ownerFamilySearchID) != nil {
            return .success(pinned, note: note)
        }
        // Same bridge the kinship routes use: the family CyberBrain knows
        // that "Rick" is a particular GEDCOM record even when the tree
        // spells him "Richard Harding Breen Jr".
        if let index = context.cyberBrain {
            switch index.resolve(name) {
            case .resolved(let known):
                if let id = known.gedcomPersonID, let p = graph.people[id] { return .success(p) }
            case .ambiguous(let people):
                let linked = people.compactMap { $0.gedcomPersonID.flatMap { graph.people[$0] } }
                if linked.count == 1 { return .success(linked[0]) }
                if linked.count > 1 { return .ambiguous(linked) }
            case .notFound:
                break
            }
        }
        let inputs = ArchivistGraphInputs(
            graph: graph,
            profiles: (context.profiles ?? []).map {
                ArchivistGraphProfileSnapshot(stableID: $0.stableID, canonicalName: $0.canonicalName, aliases: $0.aliases)
            })
        let query = ArchivistGraphQuery(people: [name], operation: .familyTree, relation: nil,
                                        side: nil, surname: nil, voices: [:])
        switch ArchivistGraphExecutor.resolveSubject(name, selection: .unresolved, inputs: inputs, query: query) {
        case .person(let p, _, _):
            return .success(p)
        case .result(let r):
            // The owner ("my line", or their own name typed) gets the
            // fallback chain before the honest decline: the tree spells
            // Rick "Richard Harding Breen Jr" (live 2026-08-26).
            if isOwnerSpelling {
                let owner = resolveOwner(name, graph: graph,
                                         familySearchID: context.speakers.ownerFamilySearchID)
                switch owner {
                case .success(let p, let note): return .success(p, note: note)
                case .failure(let r?): return .failure(r)
                case .failure(nil): break
                }
            }
            // Several namesakes: the caller decides between chips and a
            // declined sentence (`resolve` picks the sentence).
            let namesakes = r.candidates.compactMap { graph.people[$0.id] }
            if r.conclusion == .personAmbiguous, namesakes.count > 1 {
                // A bare name that several people share, exactly one of
                // them a root of the tree (Rick 2026-08-28 live: "Donna"
                // → Agatha Donna Knauss b. 1520 vs Donna Hudson b. 1959):
                // the root is who the family means. Stated in the basis.
                let roots = namesakes.filter { graph.rootPersonIDs.contains($0.id) }
                if roots.count == 1 {
                    let others = namesakes.count - 1
                    return .success(roots[0], note: "“\(name)” taken as \(roots[0].name), a root of this tree (\(others) other namesake\(others == 1 ? "" : "s") in it).")
                }
                return .ambiguous(namesakes)
            }
            // The resolver's own honest answer (not found / which one?).
            return .failure(Result(
                route: .graph,
                outcome: r.conclusion == .answered ? .answered : .declined,
                prose: r.prose, basisLine: r.basisLine,
                queryDescription: "lineage: resolve \(name)", citations: [], catalogPersonName: nil))
        }
    }

    // MARK: Ancestor line

    static func ancestorLine(of person: GedcomFamilyGraph.Person,
                             line: GedcomFamilyGraph.Line,
                             generations: Int,
                             untilYear: Int? = nil,
                             graph: GedcomFamilyGraph,
                             basisNote: String? = nil) -> Result {
        let assets = FamilyAssetConfigurationCenter.shared.snapshot().makeStore()
        let card = HallieAttachmentBuilder.lineage(
            of: person, line: line, generations: generations, untilYear: untilYear, in: graph,
            photo: { assets.photoURLs(for: $0).first })
        var sentences: [String] = []
        if card.generations.isEmpty {
            let who = line == .maternal ? "mother" : line == .paternal ? "father" : "parents"
            if let untilYear {
                sentences.append("The family tree records no \(who) for \(person.name) born in or after \(untilYear), so there is nothing to walk back to \(untilYear).")
            } else {
                sentences.append("The family tree doesn’t record \(HallieLineageQuestion.possessive(person.name)) \(who), so I can’t walk that line.")
            }
        } else {
            let bound = untilYear.map { " back to \($0)" } ?? ""
            sentences.append("Here is \(card.title)\(bound), \(card.generations.count) generation\(card.generations.count == 1 ? "" : "s") back:")
            for gen in card.generations {
                let names = gen.people.map { p -> String in
                    var s = p.name
                    if let y = p.years { s += " (\(y))" }
                    if let place = p.birthPlace { s += ", born \(place)" }
                    return s
                }.joined(separator: "; ")
                sentences.append("\(gen.label.capitalized): \(names).")
            }
            if let untilYear {
                // Stopped by the year (PROVEN by a dated parent past it),
                // by a date gap (undated parents nobody can place), or by
                // the tree itself — say which (codex #707 major 7).
                let walked = graph.ancestorLine(of: person, line: line,
                                                generations: generations, untilYear: untilYear)
                let gap = graph.yearBoundGap(of: person, generations: walked, untilYear: untilYear)
                if !gap.provenBeyond.isEmpty {
                    sentences.append("I stopped at \(untilYear) as you asked; the tree goes further back.")
                } else if gap.hasDateGap {
                    let n = gap.undatedUnwalked.count
                    let above = gap.undatedFrontier.map(\.name).joined(separator: " and ")
                    sentences.append("That is as far as the dates take that line back to \(untilYear) — \(n) ancestor\(n == 1 ? "" : "s") above \(above) \(n == 1 ? "has" : "have") no recorded dates, so the line may reach further.")
                } else {
                    sentences.append("That is as far as the tree reaches on that line before \(untilYear).")
                }
            } else if !card.reachedAll, let last = card.generations.last?.people.first {
                let who = line == .maternal ? "mother" : line == .paternal ? "father" : "parents"
                sentences.append("The tree stops there — no \(who) recorded for \(last.name).")
            }
        }
        return Result(
            route: .graph, outcome: card.generations.isEmpty ? .declined : .answered,
            prose: sentences.joined(separator: " "),
            basisLine: ArchivistBiographyPolicy.gedcomBasis + (basisNote.map { " " + $0 } ?? ""),
            queryDescription: "lineage \(line.rawValue) ×\(generations)"
                + (untilYear.map { " until \($0)" } ?? "") + ": \(person.name)",
            citations: [], catalogPersonName: person.name,
            offeredActions: [.openFamilyTreePerson(
                personID: person.id, personName: person.name)],
            attachments: card.generations.isEmpty ? [] : [.lineage(card)])
    }

    // MARK: Superlatives

    /// First four-digit run in a raw GEDCOM date ("12 JUN 1888" → 1888).
    static func year(in raw: String?) -> Int? {
        guard let raw, let m = raw.firstMatch(of: /(\d{4})/) else { return nil }
        return Int(m.1)
    }

    static func scopePhrase(_ scope: HallieLineageQuestion.SuperlativeScope, person: GedcomFamilyGraph.Person?) -> String {
        switch scope {
        case .wholeTree: return "the family tree"
        case .surname(let s): return "the \(s.capitalized) family"
        case .ancestorsOf: return "\(HallieLineageQuestion.possessive(person?.name ?? "your")) ancestors"
        }
    }

    static func superlative(_ kind: HallieLineageQuestion.SuperlativeKind,
                            scope: HallieLineageQuestion.SuperlativeScope,
                            graph: GedcomFamilyGraph,
                            context: HallieTurnExecutor.Context) -> Result {
        // The people to rank, plus (for an ancestor scope) how many
        // generations up each one sits.
        var pool: [GedcomFamilyGraph.Person] = []
        var generationOf: [String: Int] = [:]
        var anchor: GedcomFamilyGraph.Person? = nil
        var basisNote: String? = nil
        var scopeLabel = ""
        switch scope {
        case .wholeTree:
            pool = Array(graph.people.values)
        case .surname(let typed):
            let resolved = resolvedSurname(typed, graph: graph)
            pool = graph.people(withSurname: resolved)
            guard !pool.isEmpty else {
                return Result(route: .graph, outcome: .declined,
                              prose: "I don’t find anyone named \(typed.capitalized) in the family tree.",
                              basisLine: ArchivistBiographyPolicy.gedcomBasis,
                              queryDescription: "superlative: \(kind) surname=\(typed)", citations: [], catalogPersonName: nil)
            }
        case .ancestorsOf(let typed):
            switch resolve(typed, context: context, graph: graph) {
            case .failure(let r):
                return r ?? Result(route: .graph, outcome: .declined,
                                   prose: "I don’t find \(typed ?? "you") in the family tree.",
                                   basisLine: ArchivistBiographyPolicy.gedcomBasis,
                                   queryDescription: "superlative: \(kind) ancestors of \(typed ?? "owner")",
                                   citations: [], catalogPersonName: nil)
            case .success(let p, let note):
                anchor = p
                basisNote = note
                for gen in graph.ancestorLine(of: p, line: .both, generations: 60) {
                    for a in gen.people { pool.append(a); generationOf[a.id] = gen.generation }
                }
                guard !pool.isEmpty else {
                    return Result(route: .graph, outcome: .declined,
                                  prose: "The family tree records no parents for \(p.name), so there are no ancestors to rank.",
                                  basisLine: ArchivistBiographyPolicy.gedcomBasis + (note.map { " " + $0 } ?? ""),
                                  queryDescription: "superlative: \(kind) ancestors of \(p.name)",
                                  citations: [], catalogPersonName: p.name,
                                  offeredActions: [.openFamilyTreePerson(personID: p.id, personName: p.name)])
                }
            }
        }
        scopeLabel = scopePhrase(scope, person: anchor)

        // The ranking key per kind; nil = the record lacks the fact and
        // is not ranked. `higherIsBetter` picks max vs min.
        let key: (GedcomFamilyGraph.Person) -> Int?
        let higherIsBetter: Bool
        let fact: String            // what the key measures, for the prose
        let describeKey: (Int) -> String
        switch kind {
        case .earliestBorn:
            key = { $0.birthYear }; higherIsBetter = false; fact = "earliest birth year"
            describeKey = { "born \($0)" }
        case .latestBorn:
            key = { $0.birthYear }; higherIsBetter = true; fact = "latest birth year"
            describeKey = { "born \($0)" }
        case .longestLived:
            key = { p in
                guard let b = p.birthYear, let d = p.deathYear, d >= b else { return nil }
                return d - b
            }
            higherIsBetter = true; fact = "longest recorded life"
            describeKey = { "about \($0) years" }
        case .latestDied:
            key = { $0.deathYear }; higherIsBetter = true; fact = "most recent death"
            describeKey = { "died \($0)" }
        case .earliestMarried:
            key = { graph.marriages(of: $0).compactMap { Self.year(in: $0.date) }.min() }
            higherIsBetter = false; fact = "earliest recorded marriage"
            describeKey = { "married \($0)" }
        case .mostChildren:
            key = { let n = graph.relatives(.children, of: $0).count; return n > 0 ? n : nil }
            higherIsBetter = true; fact = "most recorded children"
            describeKey = { "\($0) child\($0 == 1 ? "" : "ren")" }
        case .deepestAncestor:
            key = { generationOf[$0.id] }; higherIsBetter = true; fact = "deepest recorded ancestor"
            describeKey = { "\($0) generations back" }
        case .firstBornIn(let place):
            let token = GedcomFamilyGraph.normalizedPlaceToken(place)
            key = { p in
                guard let where_ = p.birthPlace, GedcomFamilyGraph.place(where_, mentions: token) else { return nil }
                return p.birthYear
            }
            higherIsBetter = false; fact = "earliest birth in \(place)"
            describeKey = { "born \($0)" }
        }
        let ranked = pool.compactMap { p -> (GedcomFamilyGraph.Person, Int)? in
            key(p).map { (p, $0) }
        }
        guard let best = (higherIsBetter ? ranked.map(\.1).max() : ranked.map(\.1).min()) else {
            let what: String
            switch kind {
            case .firstBornIn(let place): what = "a birthplace in \(place)"
            case .longestLived: what = "both a birth and a death year"
            case .earliestMarried: what = "a marriage date"
            case .mostChildren: what = "any children"
            case .latestDied: what = "a death year"
            default: what = "a birth year"
            }
            return Result(route: .graph, outcome: .declined,
                          prose: "Nobody in \(scopeLabel) has \(what) recorded, so I can’t rank them by that.",
                          basisLine: ArchivistBiographyPolicy.gedcomBasis + " Looked at \(pool.count) people." + (basisNote.map { " " + $0 } ?? ""),
                          queryDescription: "superlative: \(kind) scope=\(scope)", citations: [], catalogPersonName: nil)
        }
        var winners: [GedcomFamilyGraph.Person] = []
        for (person, value) in ranked where value == best { winners.append(person) }
        winners.sort { a, b in a.name == b.name ? a.id < b.id : a.name < b.name }
        let shown: [GedcomFamilyGraph.Person] = Array(winners.prefix(3))
        func bio(_ p: GedcomFamilyGraph.Person) -> String {
            ArchivistBiographyPolicy.biography(personID: p.id, in: graph).text
        }
        var sentences: [String] = []
        let keyText = describeKey(best)
        if shown.count == 1 {
            sentences.append("The \(fact) in \(scopeLabel) is \(keyText): \(bio(shown[0]))")
        } else {
            let bios: String = shown.map(bio).joined(separator: " ")
            let more: String = winners.count > shown.count ? " And \(winners.count - shown.count) more." : ""
            sentences.append("\(winners.count) people share the \(fact) in \(scopeLabel) (\(keyText)): " + bios + more)
        }
        if case .firstBornIn = kind, let place = shown[0].birthPlace {
            sentences.append("The record says \(place).")
        }
        let assets = FamilyAssetConfigurationCenter.shared.snapshot().makeStore()
        var attachments: [HallieAttachment] = []
        if let url = assets.photoURLs(for: shown[0]).first {
            attachments.append(.photo(HalliePhotoAttachment(personName: shown[0].name, fileURL: url)))
        }
        let names: String = shown.map { $0.name }.joined(separator: ", ")
        let basis: String = ArchivistBiographyPolicy.gedcomBasis
            + " Ranked \(ranked.count) of \(pool.count) people in \(scopeLabel) that record the fact."
            + (basisNote.map { " " + $0 } ?? "")
        let chips: [HallieTurnExecutor.OfferedAction] = shown.map {
            HallieTurnExecutor.OfferedAction.openFamilyTreePerson(personID: $0.id, personName: $0.name)
        }
        return Result(
            route: .graph, outcome: .answered,
            prose: sentences.joined(separator: " "),
            basisLine: basis,
            queryDescription: "superlative: \(kind) scope=\(scope) → \(names)",
            citations: [], catalogPersonName: shown[0].name,
            offeredActions: chips,
            attachments: attachments)
    }

    /// `lead` in front of another answer's prose; everything else (route,
    /// chips, attachments, basis) is the other answer's.
    static func prefixing(_ lead: String, to r: Result) -> Result {
        Result(route: r.route, outcome: r.outcome, prose: lead + " " + r.prose,
               basisLine: r.basisLine, queryDescription: r.queryDescription,
               citations: r.citations, knowledgeCitations: r.knowledgeCitations,
               catalogPersonName: r.catalogPersonName, clarification: r.clarification,
               matchCount: r.matchCount, mediaAction: r.mediaAction,
               offeredActions: r.offeredActions, answerPlan: r.answerPlan,
               composedBy: r.composedBy, transcriptText: r.transcriptText,
               attachments: r.attachments)
    }

    // MARK: Deep ancestors (great × 3 and beyond)

    /// Budgets for the deep-ancestor walk (codex #707 blocker 1): the
    /// old walk kept EVERY full path, so pedigree collapse (the same
    /// couple reached along several lines) grew paths as 2^depth through
    /// the 40-great bound — a freeze or an OOM on a real tree. The walk
    /// below is a visited/predecessor BFS: one path per (person, depth),
    /// reconstructed from a predecessor map only for the people it
    /// names. These caps make even a pathological GEDCOM finish.
    static let deepAncestorMaxResults = 25
    static let deepAncestorMaxExpanded = 50_000
    static let deepAncestorTimeBudget: TimeInterval = 0.15

    /// Every ancestor exactly `depth` generations above `person` (first
    /// hop through `side` when given, final hop filtered by `sex`), each
    /// with ONE route the tree records — the same shape the ≤ great-great
    /// kinship route answers with, so a wrong link stays visible.
    ///
    /// C++ readers: `levels[l]` is the set of people at generation l+1
    /// (insertion order kept for stable prose) and `pred[l][id]` is the
    /// id of the child they were reached through — a plain BFS
    /// predecessor map; a route is rebuilt by following it downward.
    static func deepAncestors(of person: GedcomFamilyGraph.Person,
                              depth: Int,
                              sex: String?,
                              side: ArchivistQueryAST.Graph.Side?,
                              graph: GedcomFamilyGraph,
                              basisNote: String? = nil) -> Result {
        let sexFilter = (sex?.isEmpty ?? true) ? nil : sex
        let sideWord = side.map { "\($0.rawValue) " } ?? ""
        let noun = sideWord + GedcomFamilyGraph.generationLabel(generations: depth, sex: sexFilter ?? "")
        let depth = max(1, depth)
        func hopLabel(_ reached: GedcomFamilyGraph.Person, from previous: GedcomFamilyGraph.Person?) -> String {
            let word = reached.sex == "M" ? "father" : reached.sex == "F" ? "mother" : "parent"
            guard let previous else { return word }
            return (previous.sex == "M" ? "his " : previous.sex == "F" ? "her " : "their ") + word
        }

        // ---- Walk: one visit per (person, level); predecessor map.
        var levels: [[GedcomFamilyGraph.Person]] = []
        var pred: [[String: String]] = []
        var frontier = [person]
        var expanded = 0
        var budgetHit = false
        var stoppedAtLevel: Int? = nil
        let started = Date()
        /// The route from `person` (exclusive) up to `id` at 1-based `level`.
        func route(to id: String, level: Int) -> [GedcomFamilyGraph.Person] {
            var out: [GedcomFamilyGraph.Person] = []
            var cur = id
            for l in stride(from: level, through: 1, by: -1) {
                guard let p = graph.people[cur] else { break }
                out.append(p)
                guard let below = pred[l - 1][cur] else { break }
                cur = below
            }
            return out.reversed()
        }
        walk: for level in 1...depth {
            var next: [GedcomFamilyGraph.Person] = []
            var seenHere: Set<String> = []
            var predHere: [String: String] = [:]
            for from in frontier {
                if expanded >= deepAncestorMaxExpanded
                    || Date().timeIntervalSince(started) > deepAncestorTimeBudget {
                    budgetHit = true
                    break
                }
                expanded += 1
                let parents: [GedcomFamilyGraph.Person]
                if level == 1, let side {
                    parents = graph.relatives(side == .maternal ? .mother : .father, of: from)
                } else {
                    parents = graph.relatives(.parents, of: from)
                }
                for parent in parents where !seenHere.contains(parent.id) {
                    // A malformed GEDCOM can make someone their own
                    // ancestor; the route check keeps the walk acyclic.
                    if parent.id == person.id
                        || route(to: from.id, level: level - 1).contains(where: { $0.id == parent.id }) { continue }
                    seenHere.insert(parent.id)
                    predHere[parent.id] = from.id
                    next.append(parent)
                }
            }
            if next.isEmpty && !budgetHit {
                stoppedAtLevel = level
                break walk
            }
            levels.append(next)
            pred.append(predHere)
            frontier = next
            if budgetHit { break walk }
        }

        let base = "Basis: imported family tree (GEDCOM); ancestor walk \(depth) generations up"
            + (side.map { ", first hop through the \($0.rawValue) side" } ?? "") + "."
            + (basisNote.map { " " + $0 } ?? "")
        let query = "deep ancestor ×\(depth) \(sexFilter ?? "any"): \(person.name)"
        let openPerson: [HallieTurnExecutor.OfferedAction] =
            [.openFamilyTreePerson(personID: person.id, personName: person.name)]

        // ---- The tree ran out before `depth`: say exactly where.
        if let stoppedAtLevel {
            let reached = levels.last.flatMap { $0.first }.map { route(to: $0.id, level: stoppedAtLevel - 1) } ?? []
            let from = reached.last ?? person
            let reachedText = reached.enumerated().map { i, p in
                "\(hopLabel(p, from: i == 0 ? nil : reached[i - 1])) (\(p.name))"
            }.joined(separator: " → ")
            let missingWord = reached.isEmpty && side != nil
                ? (side == .maternal ? "a mother" : "a father") : "parents"
            let prose = reached.isEmpty
                ? "The family tree doesn’t record \(missingWord) for \(person.name), so I can’t reach a \(noun)."
                : "The family tree records \(HallieLineageQuestion.possessive(person.name)) \(reachedText), but no parents for \(from.name) — so I can’t reach a \(noun) (\(reached.count) of \(depth) generations recorded)."
            return Result(route: .graph, outcome: .declined, prose: prose, basisLine: base,
                          queryDescription: query, citations: [], catalogPersonName: person.name,
                          offeredActions: openPerson)
        }

        // ---- The budget ran out before the asked-for generation: honest
        // decline rather than a partial generation presented as the answer.
        if budgetHit && levels.count < depth {
            return Result(
                route: .graph, outcome: .declined,
                prose: "\(HallieLineageQuestion.possessive(person.name)) ancestry fans out too far for me to reach a \(noun) in one go — I examined \(expanded) people across \(levels.count) generation\(levels.count == 1 ? "" : "s") and stopped. Try one line (paternal or maternal) or a smaller count.",
                basisLine: base + " Walk stopped at its budget.",
                queryDescription: query, citations: [], catalogPersonName: person.name,
                offeredActions: openPerson)
        }

        // ---- Results at `depth`, one route each.
        let atDepth = (levels.last ?? []).filter { sexFilter == nil || $0.sex == sexFilter }
            .sorted { $0.name < $1.name }
        guard !atDepth.isEmpty else {
            let word = sexFilter == "M" ? "male" : "female"
            let names = (levels.last ?? []).map(\.name)
            return Result(route: .graph, outcome: .declined,
                          prose: "The tree reaches \(depth) generations above \(person.name) (\(names.joined(separator: ", "))), but records nobody \(word) there, so I can’t name a \(noun).",
                          basisLine: base + (budgetHit ? " Walk stopped at its budget; there may be more." : ""),
                          queryDescription: query, citations: [], catalogPersonName: person.name,
                          offeredActions: openPerson)
        }
        let shown = Array(atDepth.prefix(deepAncestorMaxResults))
        let paths = shown.map { route(to: $0.id, level: depth) }
        let lines = paths.map { path -> String in
            let relative = path[path.count - 1]
            var text = relative.name
            if let years = HalliePersonCard.yearsText(relative) { text += " (\(years))" }
            let route = ([person.name] + path.enumerated().map { i, p in
                "\(hopLabel(p, from: i == 0 ? nil : path[i - 1])) \(p.name)"
            }).joined(separator: " → ")
            return "\(text) (\(route))"
        }
        let plural = paths.count == 1 ? noun : noun + "s"
        var prose = "\(HallieLineageQuestion.possessive(person.name)) \(plural): " + lines.joined(separator: "; ") + "."
        let more = atDepth.count - shown.count
        if more > 0 {
            prose += " There are \(more) more at that generation I haven’t listed (\(atDepth.count) in all)."
        }
        if budgetHit {
            prose += " I stopped the walk at its budget (\(expanded) people examined), so there may be others."
        }
        return Result(
            route: .graph, outcome: .answered,
            prose: prose,
            basisLine: base + (budgetHit ? " Walk stopped at its budget; there may be more." : ""),
            queryDescription: query,
            citations: [], catalogPersonName: person.name,
            offeredActions: paths.prefix(3).map { .openFamilyTreePerson(personID: $0[$0.count - 1].id, personName: $0[$0.count - 1].name) })
    }

    // MARK: Surname tree

    static func surnameTree(_ typed: String, graph: GedcomFamilyGraph) -> Result? {
        let assets = FamilyAssetConfigurationCenter.shared.snapshot().makeStore()
        let resolved = resolvedSurname(typed, graph: graph)
        guard let card = HallieAttachmentBuilder.tree(
            surname: resolved, depth: HallieLineageQuestion.treeDepth, in: graph,
            photo: { assets.photoURLs(for: $0).first }) else {
            // Not a surname in the tree → maybe a person ("family tree for
            // Donna"); let the normal route handle it.
            return nil
        }
        let surname = card.surname ?? typed.capitalized
        let all = graph.people(withSurname: resolved)
        var sentences = ["In the family tree, the \(surname) family starts with "
            + card.roots.map { root -> String in
                var s = root.person.name
                if let y = root.person.years { s += " (\(y))" }
                if let place = root.person.birthPlace { s += ", born \(place)" }
                return s
            }.joined(separator: " and ") + "."]
        sentences.append("The tree records \(all.count) \(all.count == 1 ? "person" : "people") named \(surname); the card shows \(card.peopleCount) across \(card.depth + 1) generations from \(card.roots.count == 1 ? "that root" : "those roots").")
        return Result(
            route: .graph, outcome: .answered,
            prose: sentences.joined(separator: " "),
            basisLine: ArchivistBiographyPolicy.gedcomBasis,
            queryDescription: "family tree: surname \(surname)",
            citations: [], catalogPersonName: nil,
            offeredActions: [.openFamilyTreeSurname(surname)],
            attachments: [.tree(card)]
                + (assets.crestURL(surname: surname).map { [.crest(surname: surname, fileURL: $0)] } ?? []))
    }

    /// Keep real surnames ending in `s` (Ross, Davis, Hayes) exact.  Only
    /// interpret a trailing `s` as a spoken plural when the exact surname
    /// is absent and the singular form is present in this GEDCOM.
    static func resolvedSurname(
        _ typed: String,
        graph: GedcomFamilyGraph
    ) -> String {
        let recorded = graph.people(withSurname: typed)
            .compactMap(\.surname)
        guard !recorded.isEmpty else { return typed }
        if let exact = recorded.first(where: {
            $0.compare(typed, options: [.caseInsensitive, .diacriticInsensitive])
                == .orderedSame
        }) {
            return exact
        }
        let grouped = Dictionary(grouping: recorded) {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive],
                       locale: Locale(identifier: "en_US_POSIX"))
        }
        return grouped.count == 1 ? recorded[0] : typed
    }

    // MARK: Origin trail

    static func originTrail(of person: GedcomFamilyGraph.Person,
                            country: String?,
                            line: GedcomFamilyGraph.Line = .both,
                            graph: GedcomFamilyGraph,
                            basisNote: String? = nil) -> Result {
        let maxGen = HallieLineageQuestion.maxGenerations
        let stops = graph.originTrail(of: person, country: country, line: line, maxGenerations: maxGen)
        let anyPlaces = graph.originTrail(of: person, country: nil, line: line, maxGenerations: maxGen)
        let who = HallieLineageQuestion.possessive(person.name)
        var sentences: [String] = []
        var card: HallieLineageCard? = nil

        func describe(_ s: GedcomFamilyGraph.OriginStop) -> String {
            var t = s.person.name
            if let y = HalliePersonCard.yearsText(s.person) { t += " (\(y))" }
            return t + ", " + HallieAttachmentBuilder.generationLabel(s.generation, line: .both).replacingOccurrences(of: "parents", with: "parent")
                + " — born \(s.place)"
        }
        func trailCard(to targets: [GedcomFamilyGraph.Person], title: String) -> HallieLineageCard? {
            let gens = graph.ancestorPaths(from: person, to: targets, maxGenerations: maxGen)
            guard !gens.isEmpty else { return nil }
            return HallieLineageCard(
                title: title,
                root: HalliePersonCard(person),
                line: .both,
                generations: gens.map { g in
                    HallieLineageCard.Generation(
                        generation: g.generation,
                        label: HallieAttachmentBuilder.generationLabel(g.generation, line: .both),
                        people: g.people.map { HalliePersonCard($0) })
                },
                requested: gens.count)
        }

        if let country {
            if stops.isEmpty {
                sentences.append("Following \(who) ancestors back, the tree records nobody born in \(country).")
                if anyPlaces.isEmpty {
                    sentences.append("It records no birthplaces on those lines at all — places come from the GEDCOM’s PLAC lines, which this tree doesn’t have yet.")
                } else {
                    let countries = Self.countries(in: anyPlaces)
                    sentences.append("The places it does reach: " + countries.prefix(5).map(\.name).joined(separator: ", ") + ".")
                }
            } else {
                let nearest = Array(stops.prefix(4))
                sentences.append("The nearest of \(who) ancestors born in \(country) is \(describe(nearest[0])).")
                if nearest.count > 1 {
                    sentences.append("Further back: " + nearest.dropFirst().map(describe).joined(separator: "; ") + ".")
                }
                if stops.count > nearest.count {
                    sentences.append("\(stops.count - nearest.count) more \(country)-born ancestors lie further back.")
                }
                card = trailCard(to: nearest.map(\.person), title: "\(who) line back to \(country)")
            }
        } else {
            if anyPlaces.isEmpty {
                sentences.append("The tree records no birthplaces for \(who) ancestors, so I can’t trace where the family came from yet. Places come from the GEDCOM’s PLAC lines.")
            } else {
                let countries = Self.countries(in: anyPlaces)
                let abroad = countries.filter { !$0.isHome }
                if abroad.isEmpty {
                    sentences.append("Every recorded birthplace on \(who) lines is in " + countries.map(\.name).joined(separator: " and ") + ".")
                } else {
                    sentences.append("Following \(who) ancestors back, the lines reach " + abroad.prefix(5).map { c in
                        "\(c.name) (\(describe(c.nearest)))"
                    }.joined(separator: "; ") + ".")
                    card = trailCard(to: abroad.prefix(4).map(\.nearest.person), title: "\(who) lines abroad")
                }
            }
        }
        return Result(
            route: .graph, outcome: (country != nil ? !stops.isEmpty : !anyPlaces.isEmpty) ? .answered : .declined,
            prose: sentences.joined(separator: " "),
            basisLine: ArchivistBiographyPolicy.gedcomBasis + (basisNote.map { " " + $0 } ?? ""),
            queryDescription: "origin trail: \(person.name)" + (country.map { " → \($0)" } ?? ""),
            citations: [], catalogPersonName: person.name,
            offeredActions: [.openFamilyTreePerson(
                personID: person.id, personName: person.name)],
            attachments: card.map { [.lineage($0)] } ?? [])
    }

    /// Countries reached by a place trail, nearest ancestor first per
    /// country. The "country" is the last comma component, normalised so
    /// "USA" / "United States" / "United States of America" / a bare US
    /// state read as home.
    struct CountryStop: Equatable { let name: String; let nearest: GedcomFamilyGraph.OriginStop; let isHome: Bool }
    static func countries(in stops: [GedcomFamilyGraph.OriginStop]) -> [CountryStop] {
        var seen: [String: CountryStop] = [:]
        var order: [String] = []
        for s in stops {
            // Last component; GEDCOMs sometimes carry "Quebec. Canada".
            let last = s.place.split(whereSeparator: { $0 == "," || $0 == "." })
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .last(where: { !$0.isEmpty }) ?? s.place
            let (name, home) = Self.canonicalCountry(last)
            if seen[name] == nil {
                seen[name] = CountryStop(name: name, nearest: s, isHome: home)
                order.append(name)
            }
        }
        return order.compactMap { seen[$0] }
    }

    static let usStates: Set<String> = ["massachusetts", "ma", "new york", "ny", "vermont", "vt", "connecticut", "ct", "new hampshire", "nh", "maine", "me", "rhode island", "ri", "kentucky", "ky", "north carolina", "nc", "south carolina", "sc", "virginia", "va", "mississippi", "ms", "pennsylvania", "pa", "new jersey", "nj", "ohio", "oh", "illinois", "il", "california", "ca", "texas", "tx", "florida", "fl", "georgia", "ga", "maryland", "md", "delaware", "de", "tennessee", "tn", "indiana", "in", "michigan", "mi", "wisconsin", "wi", "minnesota", "mn", "missouri", "mo", "iowa", "ia", "louisiana", "la", "alabama", "al", "arkansas", "ar", "colorado", "co", "oregon", "or", "washington", "wa", "nevada", "nv", "arizona", "az", "utah", "ut", "kansas", "ks", "nebraska", "ne", "oklahoma", "ok", "west virginia", "wv"]

    static func canonicalCountry(_ raw: String) -> (String, Bool) {
        let k = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        switch k {
        case "usa", "us", "u.s.a", "united states", "united states of america", "america": return ("the United States", true)
        case "northern ireland", "ireland", "eire": return ("Ireland", false)
        case "united kingdom", "uk", "great britain": return ("the United Kingdom", false)
        default:
            if usStates.contains(k) { return ("the United States", true) }
            return (raw.trimmingCharacters(in: .whitespaces).capitalized, false)
        }
    }

    // MARK: GEDCOM awareness

    static func gedcomAwareness(_ graph: GedcomFamilyGraph?) -> Result {
        let what = "GEDCOM is the standard text format family-tree programs use to exchange a tree — people, families, dates and places — so a tree built in one program can be read by another."
        var parts = [what]
        if let graph {
            var source = "My family tree comes from "
            if let name = graph.sourceFileName { source += "the GEDCOM file “\(name)”" } else { source += "a GEDCOM file" }
            if let dir = graph.sourceDirectory { source += " in \(dir)" }
            if let date = graph.sourceModifiedAt {
                source += " (last changed \(date.formatted(date: .abbreviated, time: .omitted)))"
            }
            source += ": \(graph.people.count) people and \(graph.familyCount) families."
            if let merged = mergedProvenanceSentence(graph) { source += " " + merged }
            parts.append(source)
            parts.append("Drop a newer .ged file in that folder and I’ll read it next time.")
        } else {
            parts.append("No family tree is loaded right now — add a .ged file to the authorized 40_Family_Tree/GEDCOM folder and I’ll read it.")
        }
        return Result(
            route: .capability, outcome: .answered,
            prose: parts.joined(separator: " "),
            basisLine: "Basis: capability answer; the tree’s file name, folder and counts come from the loaded GEDCOM, nothing else was looked up.",
            queryDescription: "capability gedcom", citations: [], catalogPersonName: nil)
    }

    /// "describe X": the family's told accounts, quoted with their teller.
    /// Deterministic — shape .fixed, never the model. Confirmed archive
    /// passages read plainly; told-not-yet-verified ones carry the teller.
    static func personDescription(_ typed: String,
                                  focus: HallieLineageQuestion.DescriptionFocus = .general,
                                  context: HallieTurnExecutor.Context) -> Result? {
        guard let index = context.cyberBrain else { return nil }
        guard case .resolved(let person) = index.resolve(typed) else {
            // Unknown to the CyberBrain: let the normal biography route
            // answer (GEDCOM-only people still get dates and kin).
            return nil
        }
        let accounts = index.familyAccounts(
            forPersonID: person.id,
            privacyCeiling: HallieTurnExecutor.appPrivacyCeiling)
        guard !accounts.isEmpty else {
            return Result(
                route: .graph, outcome: .declined,
                prose: "No one has told me about \(person.canonicalName) that way yet. Say \u{201C}let me tell you about \(person.canonicalName)\u{201D} and I\u{2019}ll remember every word.",
                basisLine: "Basis: Breen Family CyberBrain — no family accounts recorded for this person.",
                queryDescription: "describe: \(person.canonicalName)",
                citations: [], catalogPersonName: person.canonicalName)
        }
        var sentences: [String] = []
        // Newest accounts first; under a focused ask ("physical
        // appearance"), accounts containing matching cue words rank ahead
        // regardless of age. Ranking only — nothing is edited or dropped.
        let cues: Set<String>
        switch focus {
        case .appearance: cues = HallieLineageQuestion.appearanceCues
        case .personality: cues = HallieLineageQuestion.personalityCues
        case .general: cues = []
        }
        func matchesFocus(_ account: CyberBrainIndex.FamilyAccount) -> Bool {
            guard !cues.isEmpty else { return false }
            let words = Set(account.text.lowercased()
                .split(whereSeparator: { !$0.isLetter }).map(String.init))
            return !words.isDisjoint(with: cues)
        }
        let ordered = accounts.sorted {
            let a = matchesFocus($0), b = matchesFocus($1)
            if a != b { return a }
            return ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
        for account in ordered.prefix(3) {
            let quote = Self.trimmedQuote(account.text)
            if let teller = account.attribution, account.confidence != .confirmed {
                sentences.append("According to \(teller): \u{201C}\(quote)\u{201D}")
            } else if let teller = account.attribution {
                sentences.append("\(teller) recorded: \u{201C}\(quote)\u{201D}")
            } else {
                sentences.append("The family archive records: \u{201C}\(quote)\u{201D}")
            }
        }
        return Result(
            route: .graph, outcome: .answered,
            prose: sentences.joined(separator: " "),
            basisLine: "Basis: Breen Family CyberBrain family accounts, quoted verbatim with their tellers; told items are family testimony, not yet verified against documents.",
            queryDescription: "describe: \(person.canonicalName)",
            citations: [], catalogPersonName: person.canonicalName)
    }

    /// First ~240 characters of an account, cut at a sentence end.
    static func trimmedQuote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 240 else { return trimmed }
        let head = String(trimmed.prefix(240))
        if let cut = head.lastIndex(where: { ".!?".contains($0) }) {
            return String(head[...cut])
        }
        return head + "\u{2026}"
    }

    /// "show me a photo of X": the stored portrait as an attachment, or
    /// the folder prompt when there is none yet.
    static func personPhoto(_ typed: String,
                            context: HallieTurnExecutor.Context) -> Result? {
        guard let graph = context.graph else { return nil }
        // A pronoun that got this far had nothing to stand for
        // (preTranslation resolves the ones it can): ask, never look up "Him".
        if HalliePronounContinuity.isThirdPersonPronoun(typed) {
            return pronounAsk(typed)
        }
        switch resolveDetailed(typed, context: context, graph: graph) {
        case .failure(let result): return result
        case .success(let person, _): return personPhoto(person: person)
        case .ambiguous:
            // Several namesakes: not answered here — the executor's photo
            // ask offers the chips and resumes the ask for the chosen one
            // (preTranslation hands it over; +PhotoAsk).
            return nil
        }
    }

    /// The photo answer for a RESOLVED tree person: the stored portrait, the
    /// photography-floor line, or the folder card. Shared by the
    /// deterministic shape and the executor's photo ask (chips path).
    static func personPhoto(person: GedcomFamilyGraph.Person) -> Result {
        let store = FamilyAssetConfigurationCenter.shared.snapshot().makeStore()
        if let url = store.photoURLs(for: person).first {
            return Result(
                route: .graph, outcome: .answered,
                prose: "Here\u{2019}s \(person.name).",
                basisLine: "Basis: portrait from the Master Archive\u{2019}s 40_Family_Tree folder for this person.",
                queryDescription: "photo: \(person.name)",
                citations: [], catalogPersonName: person.name,
                offeredActions: [.openFamilyTreePerson(personID: person.id, personName: person.name)],
                attachments: [.photo(HalliePhotoAttachment(personName: person.name, fileURL: url))])
        }
        // Died before photography (WorldKnowledge, photograph medium):
        // the honest line, and no folder card — there is nothing to ask
        // the family for except a painting, which the line already says.
        if let line = photographyFloorLine(person, medium: .photograph) {
            return Result(
                route: .graph, outcome: .declined,
                prose: line,
                basisLine: "Basis: family tree dates; \(WorldKnowledge.Medium.photograph.fact.statement) No search was run.",
                queryDescription: "photo: \(person.name) (before photography)",
                citations: [], catalogPersonName: person.name,
                offeredActions: [.openFamilyTreePerson(personID: person.id, personName: person.name)])
        }
        let folder = try? store.folderForPhotoRequest(person: person)
        return Result(
            route: .graph, outcome: .declined,
            prose: "I don\u{2019}t have a photo of \(person.name) yet.",
            basisLine: "Basis: no image in the archive\u{2019}s People folder for this person.",
            queryDescription: "photo: \(person.name)",
            citations: [], catalogPersonName: person.name,
            attachments: folder.map { [.photoRequest(personName: person.name, folderURL: $0)] } ?? [])
    }

    /// "videos of X" for a tree person who died before motion pictures
    /// (WorldKnowledge, FILM medium — its own fact, 1888, not the
    /// photograph's): one honest line instead of a presence search. Nil
    /// (= continue as typed) for anyone else, for an unresolved name, for
    /// an ambiguous one, and for an unknown death year — the presence
    /// route already owns those conversations.
    static func personVideos(_ typed: String,
                             context: HallieTurnExecutor.Context) -> Result? {
        guard let graph = context.graph else { return nil }
        if HalliePronounContinuity.isThirdPersonPronoun(typed) { return pronounAsk(typed) }
        guard case .success(let person, _) = resolve(typed, context: context, graph: graph),
              let line = photographyFloorLine(person, medium: .film) else { return nil }
        return Result(
            route: .graph, outcome: .declined,
            prose: line,
            basisLine: "Basis: family tree dates; \(WorldKnowledge.Medium.film.fact.statement) No search was run.",
            queryDescription: "videos: \(person.name) (before motion pictures)",
            citations: [], catalogPersonName: person.name,
            offeredActions: [.openFamilyTreePerson(personID: person.id, personName: person.name)])
    }

    /// "Who do you mean?" for a media ask whose person is a bare pronoun.
    static func pronounAsk(_ pronoun: String) -> Result {
        let key = pronoun.lowercased()
        return Result(
            route: .graph, outcome: .declined,
            prose: HalliePronounContinuity.whoDoYouMean(key),
            basisLine: "Basis: a pronoun names no one without a previous answer; nothing was looked up.",
            queryDescription: "media ask: pronoun \(key) (no subject)",
            citations: [], catalogPersonName: nil)
    }

    /// The WorldKnowledge floor for ONE medium, logged once per suppressed
    /// offer ("[hallie] film offer suppressed: Nathaniel Parker Sr (d. 1737
    /// < film 1888)"). Nil unless the person's KNOWN death year precedes
    /// that medium — an unknown death never suppresses.
    static func photographyFloorLine(_ person: GedcomFamilyGraph.Person,
                                     medium: WorldKnowledge.Medium) -> String? {
        guard let line = WorldKnowledge.photography.impossibilityLine(person: person, medium: medium),
              let note = WorldKnowledge.photography.impossibilityNote(person: person, medium: medium) else { return nil }
        appLog.write("[hallie] \(medium.rawValue) offer suppressed: \(person.name) (\(note))")
        return line
    }

    /// Deterministic pointer at the Get Family Tree sheet. Says what will
    /// happen (Terminal, your own password, install after it parses) so the
    /// chip is not a surprise; the app performs nothing until it is tapped.
    static func getFamilyTreeAnswer(_ graph: GedcomFamilyGraph?) -> Result {
        let have = graph.map { "The tree I have now holds \($0.people.count) people from \($0.sourceFileName ?? "the loaded GEDCOM"). " } ?? "I don’t have a family tree loaded yet. "
        return Result(
            route: .graph, outcome: .answered,
            prose: have
                + "I can fetch more from FamilySearch: tap Get Family Tree, choose how many ancestor steps, "
                + "and I’ll hand a getmyancestors command to Terminal — you type your FamilySearch password there, never here. "
                + "When the download finishes and parses, you can install it into the archive.",
            basisLine: "Basis: Get Family Tree (getmyancestors via Terminal); nothing was downloaded or changed; no model call.",
            queryDescription: "lineage: get family tree", citations: [], catalogPersonName: nil,
            offeredActions: [.getFamilyTree])
    }

    /// "did we only get the gedcom for Rick?" — what the loaded tree
    /// covers: its file, its first record (stated as the assumption it
    /// is), whether the named person is in it, and — the part that
    /// matters — how far the graph can actually WALK back from that
    /// person. Surname presence is never a traceability claim (codex on
    /// 0508bdab: the real Donna Hudson has no parents attached, and a
    /// 16k-person GEDCOM can hold unrelated Hudsons). Only the ancestor
    /// walk earns "I can trace". Deterministic; no model call.
    static func gedcomProvenance(person: String?, surname: String?,
                                 context: HallieTurnExecutor.Context) -> Result {
        guard let graph = context.graph else { return noTree() }
        var parts: [String] = []
        var source = "The tree I have comes from "
        source += graph.sourceFileName.map { "the GEDCOM file “\($0)”" } ?? "a GEDCOM file"
        let fromFamilySearch = graph.people.values.contains { $0.familySearchID != nil }
        source += " — \(graph.people.count) people and \(graph.familyCount) families."
        if fromFamilySearch {
            source += " Its records carry FamilySearch IDs, so I take it to be a FamilySearch export."
        }
        if let merged = mergedProvenanceSentence(graph) {
            source += " " + merged
        } else if let root = graph.rootPerson {
            let born = root.birthYear.map { " (b. \($0))" } ?? ""
            source += " Its first record is \(root.name)\(born); exports usually put the home person first, so I assume it was pulled for \(root.name) — the file doesn’t say."
        }
        parts.append(source)

        var offer = false
        let carriers = surname.map { graph.people(withSurname: $0) } ?? []
        let surnameDisplay = surname.map { carriers.first?.surname ?? HallieLineageQuestion.capitalizedName($0) }
        var ancestorIDs: Set<String> = []     // everyone the walk reached
        var selfIDs: Set<String> = []         // the named person's own record(s)
        var personFound = false

        if let person {
            // The same resolver the ancestor walks use: owner pinning,
            // CyberBrain aliases ("Rick" → "Richard Harding Breen Jr"),
            // indexed lookup. Several namesakes → all of them are walked
            // and the deepest speaks for the name.
            let found: [GedcomFamilyGraph.Person]
            switch resolveDetailed(person, context: context, graph: graph) {
            case .success(let p, _): found = [p]
            case .ambiguous(let people): found = people
            case .failure: found = []
            }
            if found.isEmpty {
                parts.append("I don’t find “\(person)” in it.")
                offer = true
            } else {
                personFound = true
                let shown = found.prefix(3).map { p in
                    p.name + (p.birthYear.map { " (b. \($0))" } ?? "")
                }.joined(separator: ", ")
                let more = found.count > 3 ? " and \(found.count - 3) more" : ""
                parts.append("\(person) is in it: \(shown)\(more).")
                // The walk is the evidence. Several namesakes → the
                // deepest one speaks for the name.
                var deepest = 0
                for p in found {
                    let walked = graph.ancestorLine(of: p, line: .both, generations: 60)
                    deepest = max(deepest, walked.count)
                    selfIDs.insert(p.id)
                    for gen in walked { for a in gen.people { ancestorIDs.insert(a.id) } }
                }
                let pronoun: String
                switch found.first?.sex {
                case "F": pronoun = "her"
                case "M": pronoun = "his"
                default: pronoun = "their"
                }
                if deepest > 0 {
                    parts.append("I can trace \(deepest) generation\(deepest == 1 ? "" : "s") back from \(person).")
                    if let surnameDisplay {
                        let connected = carriers.filter { ancestorIDs.contains($0.id) }.count
                        let stray = carriers.filter { !ancestorIDs.contains($0.id) && !selfIDs.contains($0.id) }.count
                        if connected > 0 {
                            parts.append("\(connected) of \(pronoun) recorded ancestors carr\(connected == 1 ? "ies" : "y") the surname \(surnameDisplay).")
                        } else if carriers.isEmpty {
                            parts.append("No one in it carries the surname \(surnameDisplay).")
                        }
                        if stray > 0 {
                            parts.append("The \(stray) other \(surnameDisplay)\(stray == 1 ? "" : "s") in the tree \(stray == 1 ? "isn’t" : "aren’t") among \(pronoun) recorded ancestors, so I can’t say they connect to \(person).")
                        }
                    }
                } else {
                    let lineName = surnameDisplay.map { "\($0) line" } ?? "line"
                    parts.append("But \(pronoun) record has no parents attached, so \(pronoun) \(lineName) stops there in this tree.")
                    let stray = carriers.filter { !selfIDs.contains($0.id) }.count
                    if let surnameDisplay, stray > 0 {
                        parts.append("The \(stray) other \(surnameDisplay)\(stray == 1 ? "" : "s") in the tree \(stray == 1 ? "isn’t" : "aren’t") connected to \(person).")
                    }
                    offer = true
                }
            }
        }
        if let surnameDisplay, !personFound {
            if carriers.isEmpty {
                parts.append("No one in it carries the surname \(surnameDisplay), so I can’t trace that line from this tree.")
                offer = true
            } else {
                parts.append("\(carriers.count) \(carriers.count == 1 ? "person carries" : "people carry") the surname \(surnameDisplay); whether they connect to anyone you mean, I can only tell from a named person’s record.")
            }
        }
        if offer {
            // Honest about what the sheet does (codex #754): it pulls for
            // the signed-in FamilySearch user and REPLACES the active tree;
            // it cannot add a side to this one.
            let side = person.map { HallieLineageQuestion.possessive($0) + " side" } ?? "that side"
            let record = person.map { "\($0)’s record" } ?? "a record on that side"
            parts.append("Get Family Tree pulls from the signed-in FamilySearch account; you can replace the current tree with it or add it to the current tree by FamilySearch ID, so covering \(side) means starting a pull from \(record) there and adding it.")
        }
        return Result(
            route: .graph, outcome: .answered,
            prose: parts.joined(separator: " "),
            basisLine: "Basis: the loaded GEDCOM’s file name and counts; its first record is ASSUMED to be the home person (a VideoScan merge names its roots explicitly) and FamilySearch IDs are taken as a sign of a FamilySearch export (neither is stated in the file); name/surname counts and an ancestor walk from the named person; nothing was downloaded or changed; no model call.",
            queryDescription: "lineage: gedcom provenance" + (person.map { " person=\($0)" } ?? "") + (surname.map { " surname=\($0)" } ?? ""),
            citations: [], catalogPersonName: nil,
            offeredActions: offer ? [.getFamilyTree] : [])
    }

    /// "It was merged by VideoScan from A and B by FamilySearch ID; its
    /// roots are Richard Harding Breen Jr and Donna Hudson, so it was
    /// pulled for both." Nil for an ordinary single-root export.
    static func mergedProvenanceSentence(_ graph: GedcomFamilyGraph) -> String? {
        let roots = graph.roots
        // A merge is recognised by its own flag / several source names —
        // never by root count: re-pulling Rick's tree and adding it to the
        // old one has ONE root and is still a derived artifact (codex #780).
        let merged = graph.isMergedArtifact || graph.sourceFileNames.count > 1
        guard merged || roots.count > 1 else { return nil }
        let names = HallieNameQualifier.joined(roots.map { r in
            r.name + (r.birthYear.map { " (b. \($0))" } ?? "")
        }, conjunction: "and")
        var s = ""
        if merged {
            let from = graph.sourceFileNames.isEmpty ? "two exports" : HallieNameQualifier.joined(graph.sourceFileNames.map { "“\($0)”" }, conjunction: "and")
            s += "It is a VideoScan merge artifact derived from \(from) by FamilySearch ID — lossy: names, vitals, links and FamilySearch IDs only; the source files remain the record. "
        } else {
            s += "It names \(roots.count) home people; "
        }
        if roots.count > 1 {
            s += "its roots are \(names), so I take it to have been pulled for " + HallieNameQualifier.joined(roots.map(\.name), conjunction: "and") + "."
        } else if let root = roots.first {
            s += "Its root is \(root.name)" + (root.birthYear.map { " (b. \($0))" } ?? "") + ", so I take it to have been pulled for \(root.name)."
        } else {
            s += "It names no home person."
        }
        return s
    }

    // MARK: Common ancestor

    /// "How are Rick and Donna related?" Both names go through the same
    /// resolver as every lineage shape; the graph does the intersection.
    /// Honest on both empty sides: no parents attached → "that side isn't
    /// in the tree yet" with the Get Family Tree chip; nothing shared →
    /// say how far each side was walked.
    static func commonAncestor(_ typedA: String?, _ typedB: String?,
                               context: HallieTurnExecutor.Context) -> Result? {
        guard let graph = context.graph else { return noTree() }
        var notes: [String] = []
        // C++ readers: a two-case enum instead of std::variant — the
        // resolved person, or the answer that stops the question.
        enum Side { case ok(GedcomFamilyGraph.Person), stop(Result) }
        func person(_ typed: String?) -> Side {
            switch resolveDetailed(typed, context: context, graph: graph) {
            case .success(let p, let note):
                if let note { notes.append(note) }
                return .ok(p)
            case .ambiguous(let people):
                return .stop(whichOne(typed ?? context.speakers.ownerName ?? "", among: people))
            case .failure(let r):
                return .stop(r ?? Result(
                    route: .graph, outcome: .declined,
                    prose: "I don’t find \(typed ?? "you") in the family tree.",
                    basisLine: ArchivistBiographyPolicy.gedcomBasis,
                    queryDescription: "common ancestor: resolve \(typed ?? "owner")",
                    citations: [], catalogPersonName: nil))
            }
        }
        let sideA = person(typedA), sideB = person(typedB)
        // Neither side is a person the tree knows ("how are astronomy and
        // philosophy related", codex #776): not ours — the question goes
        // on as typed instead of a graph decline.
        if case .stop(let ra) = sideA, case .stop(let rb) = sideB,
           ra.outcome != .needsClarification, rb.outcome != .needsClarification {
            return nil
        }
        let pa: GedcomFamilyGraph.Person, pb: GedcomFamilyGraph.Person
        switch sideA { case .stop(let r): return r; case .ok(let p): pa = p }
        switch sideB { case .stop(let r): return r; case .ok(let p): pb = p }
        let basis = ArchivistBiographyPolicy.gedcomBasis
            + " Ancestor sets of both people intersected; nearest by total generations first."
            + (notes.isEmpty ? "" : " " + notes.joined(separator: " "))
        let query = "common ancestor: \(pa.name) & \(pb.name)"
        let chips: [HallieTurnExecutor.OfferedAction] = [
            .openFamilyTreePerson(personID: pa.id, personName: pa.name),
            .openFamilyTreePerson(personID: pb.id, personName: pb.name),
        ]
        // Direct kin first (codex #776): parent/child, spouses, siblings,
        // grandparents and the rest are named as such — never as cousins
        // through a shared grandparent.
        // …but a marriage or in-law link is NOT an answer to "common
        // ancestor" (Rick 2026-08-28: "closest common ancestor of rick and
        // donna" → "Donna Hudson is Rick's wife"). Blood kinds short-circuit;
        // affinal kinds are mentioned as an aside after the blood answer,
        // and only stand alone when the ancestor walk finds nothing.
        let direct = graph.directRelation(between: pa.id, and: pb.id)
        let affinalKinds: Set<GedcomFamilyGraph.DirectRelation.Kind> = [.spouses, .parentInLaw, .siblingInLaw]
        let affinalAside = direct.flatMap { affinalKinds.contains($0.kind) ? $0 : nil }
        if let direct, affinalAside == nil {
            let line = direct.path.count > 2 ? " Line: " + direct.path.map(\.name).joined(separator: " → ") + "." : ""
            return Result(route: .graph, outcome: .answered,
                          prose: direct.term + "." + line,
                          basisLine: basis.replacingOccurrences(of: "Ancestor sets of both people intersected; nearest by total generations first.",
                                                                with: "Direct relation from the recorded parent/spouse links (\(direct.kind.rawValue)); no cousin math needed."),
                          queryDescription: query + " → \(direct.kind.rawValue)", citations: [],
                          catalogPersonName: pb.name,
                          offeredActions: pa.id == pb.id ? [chips[0]] : chips)
        }
        let hits = graph.commonAncestors(of: pa.id, and: pb.id)
        let possA = HallieLineageQuestion.possessive(pa.name)
        let possB = HallieLineageQuestion.possessive(pb.name)
        let asideSentence = affinalAside.map { " (" + $0.term + ".)" } ?? ""
        if hits.isEmpty {
            let dA = graph.ancestorDepth(of: pa.id), dB = graph.ancestorDepth(of: pb.id)
            let missing = [(pa, dA), (pb, dB)].filter { $0.1 == 0 }.map(\.0)
            if !missing.isEmpty {
                let sides = HallieNameQualifier.joined(missing.map { HallieLineageQuestion.possessive($0.name) + " side" }, conjunction: "and")
                let verb = missing.count == 1 ? "isn’t" : "aren’t"
                let records = HallieNameQualifier.joined(missing.map(\.name), conjunction: "or")
                return Result(
                    route: .graph, outcome: .declined,
                    prose: "\(sides) \(verb) in the tree yet — it records no parents for \(records), so there is no shared ancestor to find.\(asideSentence) Get Family Tree can pull that ancestry from FamilySearch and add it to the current tree by FamilySearch ID.",
                    basisLine: basis, queryDescription: query, citations: [], catalogPersonName: nil,
                    offeredActions: chips + [.getFamilyTree])
            }
            return Result(
                route: .graph, outcome: .declined,
                prose: "\(pa.name) and \(pb.name) share no recorded ancestor: I walked \(dA) generation\(dA == 1 ? "" : "s") above \(pa.name) and \(dB) above \(pb.name) without meeting.\(asideSentence) A deeper pull on either side could still connect them.",
                basisLine: basis, queryDescription: query, citations: [], catalogPersonName: nil,
                offeredActions: chips)
        }
        let nearest = hits[0]
        let z = nearest.person
        let born = z.birthYear.map { " (b. \($0))" } ?? ""
        let labelA = GedcomFamilyGraph.generationLabel(generations: nearest.depthA, sex: z.sex)
        let labelB = GedcomFamilyGraph.generationLabel(generations: nearest.depthB, sex: z.sex)
        var sentences: [String] = []
        let n = hits.count
        sentences.append("\(pa.name) and \(pb.name) share \(n) recorded ancestor\(n == 1 ? "" : "s"); the nearest is \(z.name)\(born) — \(possA) \(labelA) and \(possB) \(labelB), making them \(nearest.kinshipTerm).")
        func line(_ path: [GedcomFamilyGraph.Person]) -> String {
            path.map(\.name).joined(separator: " → ")
        }
        if let affinalAside { sentences.append(affinalAside.term + " — so this is the blood connection behind the marriage.") }
        sentences.append("\(possA) line: \(line(nearest.pathA)). \(possB) line: \(line(nearest.pathB)).")
        if n > 1 {
            let others = hits.dropFirst().prefix(3).map { h in
                h.person.name + (h.person.birthYear.map { " (b. \($0))" } ?? "") + " (\(h.depthA)/\(h.depthB) generations up)"
            }
            sentences.append("Also shared: " + others.joined(separator: "; ") + (n - 1 > others.count ? "; and \(n - 1 - others.count) more." : "."))
        }
        return Result(
            route: .graph, outcome: .answered,
            prose: sentences.joined(separator: " "),
            basisLine: basis + " Cousin term from the two depths (degree = nearer depth − 1, removed = the difference).",
            queryDescription: query + " → \(z.name)",
            citations: [], catalogPersonName: z.name,
            offeredActions: [.openFamilyTreePerson(personID: z.id, personName: z.name)] + chips)
    }

    static func noTree() -> Result {
        Result(route: .graph, outcome: .declined,
               prose: "I don’t have a family tree loaded, so I can’t walk the lines yet. Add a GEDCOM (.ged) file to the authorized 40_Family_Tree/GEDCOM folder and ask again.",
               basisLine: "Basis: no GEDCOM loaded; nothing was looked up.",
               queryDescription: "lineage: no tree", citations: [], catalogPersonName: nil)
    }
}
