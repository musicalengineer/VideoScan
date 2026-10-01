// HallieAncestorStatisticsQuestion.swift
// Statistics over the family's ANCESTOR LINES (GH #214, #200; Rick approved
// 2026-10-01):
//
//   "how many of our ancestors were born in New England vs Old England?"
//   "how many of Donna's ancestors were born in Ireland or France?"
//   "what was the average age at death of our ancestors?"
//   "how deep is our deepest line?" / "how many generations back does our
//    tree go?"
//   "who is the earliest ancestor in my family tree?"   (#200 item 1)
//
// "Our ancestors" and "my ancestors" said by the owner mean the owner's AND
// the partner's lines together, reported per side (Rick, #214). "My side",
// "my line" and "my own ancestors" are the owner alone; a named person
// ("Donna's", "ancestors of X") is that person alone.
//
// Same contract as HallieTreeStatisticsQuestion (docs/hallie_intent_
// recognizer_design.md): recognized only when the WHOLE sentence is
// accounted for. A time filter, a continent, "outside the US", a maternal /
// paternal side, a place this vocabulary cannot name — any of them ABSTAINS
// here, and the sentence goes on to the whole-tree statistics recognizer or
// the translator instead of being answered narrowly.
//
// Pure text → value. No graph, no model, no I/O. The answer is in
// HallieAncestorStatisticsAnswer.swift; the arithmetic in VideoScanCore's
// TreeLineStatistics.

import Foundation
import VideoScanCore

enum HallieAncestorStatisticsQuestion: Equatable, Sendable {

    /// Whose ancestors.
    enum Who: Equatable, Sendable {
        /// "our / my ancestors" — the owner and the owner's partner.
        case ours
        /// "my side", "my line", "my own ancestors" — the owner alone.
        case owner
        /// A typed name, resolved by the answer through the lineage chain.
        case person(String)
    }

    /// A place as the question named it, and what it counts.
    struct NamedPlace: Equatable, Sendable {
        let label: String
        let place: TreeLineStatistics.Place
    }

    case birthplaces(who: Who, places: [NamedPlace])
    case ageAtDeath(who: Who)
    case deepestLine(who: Who)
    case earliest(who: Who)

    var who: Who {
        switch self {
        case .birthplaces(let w, _), .ageAtDeath(let w), .deepestLine(let w), .earliest(let w): return w
        }
    }

    // MARK: - Vocabulary

    private static let countAsk = /\bhow\s+many\b|\bnumber\s+of\b|\bcount\b|\bcompare[ds]?\b|\bvs\.?\b|\bversus\b|\bproportion\b|\bpercentage\b|\bshare\s+of\b|\bwhat\s+fraction\b/
    private static let averageAsk = /\baverage\b|\bmean\b|\bmedian\b|\btypical\b|\busual\b/
    private static let ageAtDeathWords = /\bage\s+at\s+death\b|\bage\s+(?:when|that|they)\s+(?:they\s+)?died\b|\blife\s*spans?\b|\bhow\s+long\s+did\b.*\blive\b|\bdied\s+at\s+what\s+age\b|\bwhat\s+age\s+did\b.*\bdie\b/
    private static let ancestorNoun = /\b(?:ancestors?|ancestry|forebears?|forefathers?|lines?|sides?|lineage)\b/
    /// A constraint none of these shapes can hold → abstain.
    private static let unsupported = /\bmarried\b|\bspouse\b|\bchildren\b|\bsons?\b|\bdaughters?\b|\bsurname\b|\bnamed\b|\bcalled\b|\bphotos?\b|\bvideos?\b|\bpic(?:ture)?s?\b|\bimages?\b|\bportraits?\b|\balive\b|\bliving\b|\bdeceased\b|\bmaternal\b|\bpaternal\b|\bmother'?s\s+(?:side|line)\b|\bfather'?s\s+(?:side|line)\b|\boutside\b|\babroad\b|\boverseas\b|\bforeign\b|\beurope\b|\basia\b|\bafrica\b|\bcentury\b|\bcenturies\b|\bdecades?\b|\bper\s+generation\b|\bby\s+generation\b/
    private static let anyYear = /\b\d{3,4}s?\b/
    /// A kin or sex word in the scope ("my mom's line", "our female
    /// ancestors") is a constraint, not a person's name (QA P3-2): both
    /// statistics recognizers abstain rather than count "My Mom" or the
    /// whole tree. Shared with HallieTreeStatisticsQuestion.
    static let kinOrSexScope = /\b(?:female|male|women|men|woman|man)\b|\b(?:mom|mum|mommy|mother|dad|daddy|father|grand\w+|wife|husband|aunt|uncle|cousin|brother|sister|nephew|niece|son|daughter)(?:'s|s'|s)\b/
    /// "the quill line", "on the lark side", "the quill family", "of the
    /// polwenna branch": a scope this reader cannot resolve to a person
    /// (QA P2-4) — never "ours", and never a PERSON named "Polwenna Branch"
    /// (generated-input AF3). Not a scope: "the other side" (the lineage
    /// reader's own phrase), "the deepest line", "the family line".
    private static let unreadFamilyScope = /\bthe\s+(?!(?:other|same|whole|direct|deepest|longest|oldest|earliest|first|family|two|both)\b)[a-z][a-z'-]*(?:\s+[a-z][a-z'-]*)?\s+(?:family|line|side|clan|branch|lineage)\b/
    /// "… ancestors WHO VOTED", "… THAT fought in a war": a relative clause
    /// narrowing the ancestors, which none of these shapes can hold
    /// (generated-input AF3). The shapes' own predicates are not
    /// constraints: "ancestors who were born in …" (birthplaces), "who
    /// died …" (age at death).
    private static let relativeClause = /\b(?:ancestors?|ancestry|forebears?|forefathers?|relatives|people|lines?|sides?|branch(?:es)?|family|families)\s+(?:who|that|which|whom|whose)\b(?!\s+(?:(?:were|was|are|is)\s+)?born\b)(?!\s+died\b)/
    /// Any constraint the age-at-death and birthplace shapes cannot hold.
    private static func hasUnreadConstraint(_ q: String) -> Bool {
        q.firstMatch(of: unreadFamilyScope) != nil || q.firstMatch(of: relativeClause) != nil
    }
    /// "in Ireland", "in the civil war" … — a place or event filter the
    /// earliest / deepest shapes cannot hold. "in my/our/the family tree"
    /// and "in donna's tree" are scope, not filters.
    private static let inFilter = /\bin\s+(?!(?:my|our|the\s+(?:family\s+)?tree\b|this|his|her|their)\b)(?![a-z.'-]+'s?\s)[a-z]+/

    // MARK: - Recognition

    /// Nil = ABSTAIN (not one of these shapes, or one carrying a constraint
    /// it cannot hold).
    static func detect(_ question: String) -> HallieAncestorStatisticsQuestion? {
        let q = question.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ?.!"))
        guard q.firstMatch(of: unsupported) == nil,
              q.firstMatch(of: kinOrSexScope) == nil else { return nil }

        if let earliest = earliestAncestor(q) { return earliest }
        if let deepest = deepestLine(q) { return deepest }
        if let ages = ageAtDeath(q) { return ages }
        return birthplaces(q)
    }

    // MARK: Shapes

    /// "who is the earliest ancestor in my family tree" — no born/birth
    /// word (#200: the superlative reader owns "earliest born …").
    private static func earliestAncestor(_ q: String) -> HallieAncestorStatisticsQuestion? {
        guard q.firstMatch(of: /\b(?:earliest|first|oldest\s+known|furthest\s+back)\s+(?:known\s+|recorded\s+|documented\s+)?ancestors?\b/) != nil,
              q.firstMatch(of: /\bborn\b|\bbirth/) == nil,
              q.firstMatch(of: anyYear) == nil,
              // "first ancestor to come to America", "earliest ancestor from
              // Ireland", "… in England": an immigration or place question,
              // not a ranking of the whole line.
              q.firstMatch(of: /\b(?:came|come|comes|arrive\w*|immigra\w*|emigra\w*|settle\w*|moved?|lived?|from)\b/) == nil,
              q.firstMatch(of: inFilter) == nil,
              // "first ancestor TO fight / to serve", "… WITH a will", "…
              // (that) WE have …", "… WHO …": a qualified ancestor, not the
              // earliest of the line (QA P2-4).
              q.firstMatch(of: /\bancestors?\s+(?:to|with|we|i|you|that|who|whom|which|whose)\b/) == nil,
              let who = scopeOrOurs(q)
        else { return nil }
        return .earliest(who: who)
    }

    /// The scope, defaulting to ours — but NIL when the sentence names a
    /// family line this reader could not resolve ("the quill line", "on the
    /// lark side"), which must never be answered as ours (QA P2-4).
    private static func scopeOrOurs(_ q: String) -> Who? {
        // Checked FIRST: the person reader would take "of the polwenna
        // branch" for someone named Polwenna Branch (generated-input AF3).
        if q.firstMatch(of: unreadFamilyScope) != nil { return nil }
        return who(in: q, allowTree: true) ?? .ours
    }

    /// "how deep is our deepest line" / "how many generations back does our
    /// tree go". Never a birthplace trail ("… before you reach Europe").
    private static func deepestLine(_ q: String) -> HallieAncestorStatisticsQuestion? {
        let asks = q.firstMatch(of: /\b(?:deepest|longest)\s+(?:recorded\s+|known\s+|documented\s+)?(?:line|lines|lineage|branch)\b/) != nil
            || q.firstMatch(of: /\bhow\s+many\s+generations\b.*\b(?:go(?:es)?|reach(?:es)?|run|runs)\s+back\b/) != nil
            || q.firstMatch(of: /\bhow\s+many\s+generations\s+back\s+(?:does|do|can)\b.*\b(?:go|reach)\b/) != nil
            || q.firstMatch(of: /\bhow\s+many\s+generations\s+(?:does|do)\s+(?:our|my|the|[a-z']+'s?)\s+(?:family\s+tree|tree|line|lines|ancestry)\s+(?:have|cover|span)\b/) != nil
        guard asks,
              q.firstMatch(of: /\bborn\b|\bbirth|\buntil\b|\btill\b|\bbefore\b|\bafter\b|\bto\s+(?:the\s+)?[a-z]+\s*$/) == nil,
              q.firstMatch(of: anyYear) == nil,
              q.firstMatch(of: inFilter) == nil,   // "… does our line go in Ireland"
              let who = scopeOrOurs(q) else { return nil }
        return .deepestLine(who: who)
    }

    /// "average age at death of our ancestors" / "oldest age at death on
    /// Donna's side". An ancestor scope is required — "average lifespan of
    /// people in the tree" is the whole-tree route's.
    private static func ageAtDeath(_ q: String) -> HallieAncestorStatisticsQuestion? {
        let measured = q.firstMatch(of: ageAtDeathWords) != nil
        let wantsAverage = q.firstMatch(of: averageAsk) != nil
        let ageAtDeathPhrase = q.firstMatch(of: /\bage\s+at\s+death\b/) != nil
        guard measured, wantsAverage || ageAtDeathPhrase,
              q.firstMatch(of: /\bborn\b/) == nil, q.firstMatch(of: anyYear) == nil,
              q.firstMatch(of: ancestorNoun) != nil,
              // "… on the marrowby line", "… who fought in a war" (AF3).
              !hasUnreadConstraint(q),
              let who = who(in: q, allowTree: false) else { return nil }
        return .ageAtDeath(who: who)
    }

    /// "how many of our ancestors were born in New England vs Old England /
    /// Ireland / France".
    private static func birthplaces(_ q: String) -> HallieAncestorStatisticsQuestion? {
        guard q.firstMatch(of: countAsk) != nil,
              q.firstMatch(of: ancestorNoun) != nil,
              q.firstMatch(of: anyYear) == nil,
              // "… on the fenlane side were born …", "… who voted were
              // born …" (AF3).
              !hasUnreadConstraint(q),
              let who = who(in: q, allowTree: false),
              let m = q.firstMatch(of: /\b(?:born|birth\s*places?|places?\s+of\s+birth)\s+(?:in|at)\s+(.+)$/) else { return nil }
        var tail = String(m.1)
        // The scope phrase may follow the places ("born in ireland among
        // donna's ancestors"): cut there.
        if let cut = tail.firstMatch(of: /\s+(?:among|on|in|of|for|within|across)\s+(?:my|our|[a-z][a-z .'-]*?'s?)\s+(?:own\s+)?(?:ancestors?|ancestry|forebears?|lines?|sides?|lineage|family\s+tree|tree|family)\b.*$|\s+(?:among|of)\s+(?:the\s+)?ancestors?\s+of\b.*$/) {
            tail = String(tail[tail.startIndex..<cut.range.lowerBound])
        }
        tail = tail.replacing(/\s+(?:in\s+total|total|altogether|overall|respectively)\s*$/, with: "")
        let parts = tail.split(separator: /\s*(?:,|\/|&|\bvs\.?|\bversus\b|\bor\b|\band\b|\bcompared\s+(?:with|to)\b|\bthan\b)\s*/)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty, parts.count <= 8 else { return nil }
        var places: [NamedPlace] = []
        for part in parts {
            // Every named place must be one we can count, or we abstain.
            guard let named = namedPlace(part) else { return nil }
            if !places.contains(named) { places.append(named) }
        }
        return .birthplaces(who: who, places: places)
    }

    // MARK: Scope

    /// The ancestors the sentence is about. Nil = no ancestor scope.
    /// `allowTree`: "in my/our family tree" counts as ours (the earliest /
    /// deepest shapes, where "ancestor" or "line" is already in the ask).
    static func who(in q: String, allowTree: Bool) -> Who? {
        if q.firstMatch(of: /\bmy\s+own\b|\bmy\s+(?:side|line)\b|\bmy\s+(?:own\s+)?(?:branch|lineage)\b/) != nil { return .owner }
        if q.firstMatch(of: /\b(?:my|our)\s+(?:direct\s+|recorded\s+|known\s+)?(?:ancestors?|ancestry|forebears?|forefathers?|family\s+lines?|lines|deepest|earliest|first|oldest|longest)\b|\bour\s+(?:own\s+)?(?:sides?|line|lineage)\b|\b(?:both|the\s+two)\s+(?:of\s+our\s+)?(?:sides|lines|families)\b/) != nil {
            return .ours
        }
        // "ancestors of donna (hudson)" before the shared reader, which only
        // knows this form at the end of the sentence.
        if let m = q.firstMatch(of: /\bancestors?\s+of\s+([a-z][a-z .'-]*?)\s+(?:were|was|born|who|that|have|had|lived|died|came)\b/),
           let name = HallieLineageQuestion.scopeName(String(m.1)) {
            return isOwnerWord(name) ? .ours : .person(name)
        }
        if let scope = HallieLineageQuestion.personScope(in: q) {
            switch scope.scope {
            case .ancestorsOf(let name?), .otherSideOf(let name?):
                return isOwnerWord(name) ? .ours : .person(name)
            case .ancestorsOf(nil), .otherSideOf(nil):
                return .ours
            case .wholeTree:
                if allowTree, q.firstMatch(of: /\b(?:my|our)\s+(?:family\s+)?tree\b/) != nil { return .ours }
            case .descendantsOf, .surname:
                return nil
            }
        }
        // "donna's deepest line" / "donna's ancestors" with no preposition.
        // A REAL possessive only: with the "'s" optional, "the lark side"
        // and "our female ancestors" were read as people (QA P2-4 / P3-2).
        if let m = q.firstMatch(of: /\b([a-z][a-z.'-]*(?:\s+[a-z][a-z.'-]*){0,3}?)(?:'s|s')\s+(?:own\s+)?(?:ancestors?|ancestry|forebears?|lines?|sides?|lineage|deepest|earliest|first|oldest|longest|family\s+tree|tree)\b/),
           let name = HallieLineageQuestion.scopeName(String(m.1)), !isOwnerWord(name) {
            return .person(name)
        }
        if allowTree, q.firstMatch(of: /\b(?:my|our)\s+(?:family\s+)?tree\b/) != nil { return .ours }
        return nil
    }

    private static func isOwnerWord(_ name: String) -> Bool {
        ["me", "my", "mine", "us", "our", "ours", "we", "myself", "ourselves"].contains(name.lowercased())
    }

    // MARK: Places

    private static let americanRegions: Set<BirthplaceClassifier.BirthRegion> = [.newEngland, .restOfUS, .unitedStatesUnspecified]

    /// One named place → what it counts; nil = not a place we can count
    /// (a state, a city, a continent, a typo) → the whole question abstains.
    static func namedPlace(_ raw: String) -> NamedPlace? {
        var p = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .?!'\""))
        p = p.replacing(/^(?:in|from|at)\s+/, with: "")
        p = p.replacing(/^the\s+(?=(?:us|usa|u\.s\.|u\.s\.a\.|states|united\s+states|uk|u\.k\.|united\s+kingdom|netherlands|rest\b))/, with: "")
        switch p {
        case "new england": return NamedPlace(label: "New England", place: .regions([.newEngland]))
        case "old england": return NamedPlace(label: "Old England", place: .regions([.england]))
        case "england": return NamedPlace(label: "England", place: .regions([.england]))
        case "ireland", "eire": return NamedPlace(label: "Ireland", place: .regions([.ireland]))
        case "scotland": return NamedPlace(label: "Scotland", place: .regions([.scotland]))
        case "wales": return NamedPlace(label: "Wales", place: .regions([.wales]))
        case "canada": return NamedPlace(label: "Canada", place: .regions([.canada]))
        case "us", "usa", "u.s.", "u.s.a.", "america", "united states", "united states of america", "states":
            return NamedPlace(label: "the United States", place: .regions(americanRegions))
        case "rest of the us", "rest of the country", "rest of america", "rest of the united states",
             "other states", "elsewhere in the us", "elsewhere in america":
            return NamedPlace(label: "the rest of the US", place: .regions([.restOfUS]))
        case "uk", "u.k.", "united kingdom", "britain", "great britain":
            return NamedPlace(label: "the United Kingdom", place: .country(BirthplaceClassifier.unitedKingdom))
        default:
            break
        }
        // A COUNTRY named as itself (France, Germany, Holland …). A region,
        // state or city classifies to its country too — and counting
        // "Massachusetts" as the whole United States would be a wrong
        // answer — so only the country's own name or alias is accepted.
        let aliases: [String: String] = ["holland": "Netherlands", "the netherlands": "Netherlands",
                                         "netherlands": "Netherlands", "deutschland": "Germany"]
        if let alias = aliases[p] { return NamedPlace(label: alias, place: .country(alias)) }
        let classified = BirthplaceClassifier.classify(p)
        guard !classified.isAmbiguous, let country = classified.country,
              country.lowercased() == p,
              country != BirthplaceClassifier.unitedStates,
              country != BirthplaceClassifier.unitedKingdom else { return nil }
        return NamedPlace(label: country, place: .country(country))
    }
}
