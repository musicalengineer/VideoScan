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
    /// "describe X" / "what was X like" / "X's appearance/personality" —
    /// answered DETERMINISTICALLY from the family's told accounts, voiced
    /// as attributed testimony (Rick 2026-08-25: a prompt nudge left it
    /// to the model's mood; a description ask must always speak).
    enum DescriptionFocus: String, Sendable { case appearance, personality, general }
    case personDescription(person: String, focus: DescriptionFocus = .general)
    /// "show me a photo of X" — the stored portrait as an attachment;
    /// no language model involved.
    case personPhoto(person: String)
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
        if isGedcomAwareness(lower) { return .gedcomAwareness }

        // "show me a photo of Fred Lamb" (typos in the lead words are the
        // translator's problem no longer — this is deterministic).
        if let m = lower.firstMatch(of: /\b(?:photo|picture|portrait|image)s?\s+of\s+([a-z][a-z .'-]+?)\s*$/),
           lower.firstMatch(of: /\b(?:show|see|display|view|got|have|any)\b/) != nil {
            let name = HallieLineageQuestion.capitalizedName(String(m.1).trimmingCharacters(in: .whitespaces))
            return .personPhoto(person: name)
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
        return nil
    }

    /// A request to FETCH tree data, as opposed to questions about it.
    /// Requires a fetch verb and a tree/GEDCOM/FamilySearch object; "show
    /// me the family tree" and "what is GEDCOM" are not fetches.
    static func isGetFamilyTree(_ lower: String) -> Bool {
        let verbs = /\b(?:get|fetch|download|pull|import|grab|update|refresh|expand|extend|deepen)\b/
        let object = /\b(?:family ?search|gedcom|(?:family )?tree|ancestors|ancestry|generations)\b/
        guard lower.firstMatch(of: verbs) != nil, lower.firstMatch(of: object) != nil else { return false }
        if lower.contains("familysearch") || lower.contains("family search") { return true }
        return lower.firstMatch(of: /\b(?:get|fetch|download|pull|import|grab) (?:more (?:of )?)?(?:the |my |our |a )?(?:whole |entire |full |bigger |deeper |updated |new |latest )?(?:family )?(?:tree|gedcom|ancestors|ancestry)\b/) != nil
            || lower.firstMatch(of: /\b(?:more|deeper|further|older) (?:generations|ancestors)\b/) != nil
            || lower.firstMatch(of: /\b(?:update|refresh|expand|extend|deepen) (?:the |my |our )?(?:family )?tree\b/) != nil
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
        let pattern = /(?:^|\s)(?:(my|our)|([a-z][a-z .'-]*?)'s?)\s+(?:(maternal|paternal|mother'?s|father'?s)\s+)?((?:great[- ]?)*grand[a-z]+)(?:\s+on\s+(?:his|her|my|our|their|the)\s+(paternal|maternal|father'?s|mother'?s)\s+side)?\b/
        guard let m = lower.firstMatch(of: pattern) else { return nil }
        // Only the whole question: more words after the relation ("…'s
        // grandfather's farm", "… grandmother edith lucy parker") mean a
        // different shape, and the translator or trace regexes own those.
        let rest = lower[m.range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard rest.isEmpty || rest.firstMatch(of: /^(?:please|hallie|thanks|for me)\b/) != nil else { return nil }
        let words = String(m.4).replacingOccurrences(of: "-", with: " ")
        guard let parsed = GedcomFamilyGraph.extendedRelation(fromPhrase: words),
              parsed.relation.startsAtParents,
              let relation = ArchivistQueryAST.Graph.Relation(rawValue: parsed.relation.rawValue)
        else { return nil }
        let sideWord = m.3.map(String.init) ?? m.5.map(String.init)
        let side: ArchivistQueryAST.Graph.Side? = sideWord.map { $0.hasPrefix("m") ? .maternal : .paternal }
        if m.1 != nil { return .kinship(person: nil, relation: relation, side: side) }
        // possessor() strips the lead words ("tell me about"); nil means
        // nobody in particular ("the family's") → not ours.
        guard let person = possessor(in: String(m.2 ?? "") + "'s") else { return nil }
        return .kinship(person: person, relation: relation, side: side)
    }

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
        case .personDescription(let person, let focus):
            return personDescription(person, focus: focus, context: context)
        case .personPhoto(let person):
            return personPhoto(person, context: context)
        case .kinship:
            // Not answered here: preTranslation turns it into a graph
            // kinship intent and the ordinary executor route runs it.
            return nil
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
        case .none:
            return .failure(nil)
        }
    }

    private static func resolve(_ typed: String?,
                                context: HallieTurnExecutor.Context,
                                graph: GedcomFamilyGraph) -> Resolved {
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
                if linked.count > 1 {
                    return .failure(Result(
                        route: .graph, outcome: .needsClarification,
                        prose: "Which \(name) do you mean — " + linked.map(\.name).joined(separator: " or ") + "?",
                        basisLine: "Basis: Breen Family CyberBrain knows more than one person by that name; nothing was looked up.",
                        queryDescription: "lineage: resolve \(name)", citations: [], catalogPersonName: nil))
                }
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
                if owner != .failure(nil) { return owner }
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
                // Stopped by the year, by the tree, or both — say which.
                let last = card.generations.last?.people ?? []
                let beyond = last.contains { card in
                    guard let p = graph.people[card.gedcomID] else { return false }
                    return graph.relatives(.parents, of: p).contains {
                        !GedcomFamilyGraph.withinBound($0, child: p, year: untilYear)
                    }
                }
                sentences.append(beyond
                    ? "I stopped at \(untilYear) as you asked; the tree goes further back."
                    : "That is as far as the tree reaches on that line before \(untilYear).")
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
        switch resolve(typed, context: context, graph: graph) {
        case .failure(let result): return result
        case .success(let person, _):
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
            let folder = try? store.folderForPhotoRequest(person: person)
            return Result(
                route: .graph, outcome: .declined,
                prose: "I don\u{2019}t have a photo of \(person.name) yet.",
                basisLine: "Basis: no image in the archive\u{2019}s People folder for this person.",
                queryDescription: "photo: \(person.name)",
                citations: [], catalogPersonName: person.name,
                attachments: folder.map { [.photoRequest(personName: person.name, folderURL: $0)] } ?? [])
        }
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

    private static func noTree() -> Result {
        Result(route: .graph, outcome: .declined,
               prose: "I don’t have a family tree loaded, so I can’t walk the lines yet. Add a GEDCOM (.ged) file to the authorized 40_Family_Tree/GEDCOM folder and ask again.",
               basisLine: "Basis: no GEDCOM loaded; nothing was looked up.",
               queryDescription: "lineage: no tree", citations: [], catalogPersonName: nil)
    }
}
