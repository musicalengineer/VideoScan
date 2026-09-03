// HallieBirthplaceTrail.swift
// The birthplace TRAIL as Hallie answers it (Rick, 2026-09-02, for his
// brother's demo): "trace the birth locations of Donna's maternal line and
// read them out until you get outside the USA", "how many generations
// back before you get to European birthplaces".
//
// Detection is a regex table like the other lineage shapes (model-free);
// the walk is `LineageTrail` (VideoScanCore); the answer is a numbered
// list or a "N generations. <name> …" sentence, written so the voice can
// read it straight — no citation markup inside the list. A trail longer
// than twelve lines pages: "show more" continues it from conversation
// memory (the last answer's query description carries the page).

import Foundation
import VideoScanCore

// MARK: - Detection

extension HallieLineageQuestion {

    /// What the trail is asked to produce.
    enum TrailAsk: String, Sendable, Equatable {
        /// Read the birthplaces out, generation by generation.
        case list
        /// Count the generations to the first match and name the person.
        case firstMatch
    }

    /// Lines per page of a read-out trail; the rest is "show more".
    static let trailPageSize = 12

    /// The subject of a trail sentence: the owner ("my", nothing named), a
    /// pronoun (resolved from conversation memory by the executor), a
    /// name, or a shape that is not ours after all ("donna and rick's").
    enum TrailSubject: Equatable {
        case owner
        case pronoun(String)
        case named(String)
        case rejected
    }

    // The vocabulary. Every regex runs on `normalize`d text (lower case,
    // straight apostrophes, no trailing punctuation).
    private static let trailMediaNoun = /\b(?:video|photo|picture|clip|movie|footage|film|image|portrait)s?\b/
    /// "maternal line" / "mother's side" / "paternal birthplaces" — the
    /// line word must be followed by a line noun, so "maternal
    /// grandmother" (a kinship ask) stays out.
    /// Swift's `\b` is a UNICODE word boundary: "line's" is one word, so
    /// the possessive is spelled out rather than left to the boundary.
    private static let trailLinePhrase = /\b(?:maternal|paternal|mother'?s|father'?s|mom'?s|dad'?s)\s+(?:line|side|lineage|ancestors|ancestry|forebears|birth\s*places?|birth\s+locations?)(?:'s)?\b/
    private static let trailBirthCue = /\bbirth\s*places?\b|\bbirth\s+locations?\b|\bplaces?\s+of\s+birth\b|\bborn\b|\bbirths\b/
    private static let trailOriginCue = /\b(?:come|came|comes|coming)\s+from\b|\borigins?\b|\boriginat\w+\b/
    private static let trailOutsideUS = /\b(?:outside|out\s+of|beyond|away\s+from|not\s+in|not\s+born\s+in|left)\s+(?:of\s+)?(?:the\s+)?(?:usa|u\.?s\.?a?\.?|united\s+states|america|the\s+states|this\s+country|the\s+country)\b|\boverseas\b|\babroad\b|\bforeign(?:-born|\s+born)?\b|\b(?:another|a\s+different|some\s+other|other)\s+countr(?:y|ies)\b|\bnon-?american\b|\bimmigra\w+\b|\bemigra\w+\b|\bold\s+country\b/
    private static let trailEurope = /\beurope\b|\beuropean\b/
    private static let trailGenerationsAsk = /\bhow\s+many\s+generations?\b|\bhow\s+far\s+back\b|\bhow\s+many\s+(?:steps|hops|greats?)\b|\b(?:first|nearest|closest|earliest|most\s+recent)\s+(?:ancestor|forebear|one|person|relative)\b|\bwhich\s+generation\b|\bhow\s+many\s+generations\b/
    private static let trailGenerationCount = /\b(\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty)\s+generations?\b/

    /// The trail shapes, or nil when the sentence is not one. Two rules:
    ///
    /// 1. A generations ask with a stop ("how many generations back …
    ///    born in Europe", "first ancestor born outside America") → count
    ///    to the first match; every ancestor unless a line is named.
    /// 2. A named line with a birthplace / origin cue ("birthplaces on
    ///    Donna's mother's side", "where did X's paternal line come from")
    ///    → read the line out, stopping where the sentence says.
    ///
    /// No line, no stop → not ours: "where was donna born", "how many
    /// generations are in the tree", "show donna's family tree" keep
    /// their routes.
    static func birthplaceTrailQuestion(in lower: String) -> HallieLineageQuestion? {
        guard lower.firstMatch(of: trailMediaNoun) == nil else { return nil }
        let linePhrase = lower.firstMatch(of: trailLinePhrase).map { String($0.0) }
        let europe = lower.firstMatch(of: trailEurope) != nil
        let outsideUS = lower.firstMatch(of: trailOutsideUS) != nil
        let generationsAsk = lower.firstMatch(of: trailGenerationsAsk) != nil
        let birthCue = lower.firstMatch(of: trailBirthCue) != nil
        let originCue = lower.firstMatch(of: trailOriginCue) != nil

        let line: LineageTrail.Line? = linePhrase.map {
            $0.hasPrefix("m") ? .maternal : .paternal
        }
        let stop: LineageTrail.Stop
        if europe { stop = .continent(.europe) }
        else if outsideUS { stop = .outsideCountry(BirthplaceClassifier.unitedStates) }
        else if let n = trailGenerations(in: lower) { stop = .generations(n) }
        else { stop = .top }

        let ask: TrailAsk
        if generationsAsk, europe || outsideUS {
            ask = .firstMatch
        } else if line != nil, birthCue || originCue || europe || outsideUS {
            ask = .list
        } else {
            return nil
        }
        let person: String?
        switch trailSubject(in: lower) {
        case .rejected: return nil
        case .owner: person = nil
        case .pronoun(let p): person = p
        case .named(let n): person = n
        }
        return .birthplaceTrail(person: person, line: line ?? .allAncestors, stop: stop, ask: ask)
    }

    /// "6 generations" / "six generations" → 6. Own parser: the shared
    /// `generations(in:)` caps at the card's twelve; the trail walks
    /// twenty.
    static func trailGenerations(in text: String) -> Int? {
        guard let m = text.firstMatch(of: trailGenerationCount) else { return nil }
        let raw = String(m.1)
        if let n = Int(raw) { return min(max(1, n), LineageTrail.generationCap) }
        return numberWords.firstIndex(of: raw).map { $0 + 1 }
    }

    static let numberWords = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                              "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
                              "eighteen", "nineteen", "twenty"]

    /// Words that may sit between the start of a possessive window and
    /// the name proper ("the birth locations of donna's" → "donna").
    /// Stripped from the FRONT only, so a name is never eaten from
    /// behind. Kin words are included so "aunt mary's maternal line" is
    /// Mary, the way the resolver wants her.
    private static let trailSubjectFiller: Set<String> = [
        "the", "a", "an", "of", "on", "for", "about", "out", "read", "list", "me", "until", "till",
        "and", "from", "in", "to", "with", "does", "did", "do", "where", "how", "far", "back", "many",
        "generations", "generation", "you", "get", "need", "go", "find", "someone", "somebody", "born",
        "before", "your", "what", "is", "are", "were", "was", "if", "then", "tell", "who", "show", "all",
        "give", "walk", "follow", "trace", "take", "run", "through", "down", "up", "along", "please",
        "hallie", "can", "could", "would", "will", "ok", "okay", "so", "just", "now", "birth", "birthplace",
        "birthplaces", "place", "places", "location", "locations", "both", "each", "every", "tree",
        "family", "line", "side", "when", "at", "that", "this", "which", "one", "first", "nearest",
        "closest", "ancestor", "ancestors", "starting", "start", "begin", "beginning", "using", "off",
        "aunt", "uncle", "cousin", "grandma", "grandpa", "grandmother", "grandfather", "mother", "father",
        "mom", "dad", "sister", "brother", "wife", "husband", "ma", "pa", "nana", "gram",
    ]

    /// The person the trail is about. See `TrailSubject`.
    static func trailSubject(in lower: String) -> TrailSubject {
        // "my maternal line" / "her ancestors" — a determiner in front of
        // the line noun.
        if let m = lower.firstMatch(of: /\b(my|our|his|her|their)\s+(?:maternal|paternal|mother'?s|father'?s|mom'?s|dad'?s|ancest\w*|forebears|famil\w*|line|lineage|birth\w*)\b/) {
            let word = String(m.1)
            return HalliePronounContinuity.isThirdPersonPronoun(word)
                ? .pronoun(capitalizedName(word)) : .owner
        }
        // "… of donna's maternal line" — up to five words ending in a
        // possessive right before the line noun.
        // A window word may carry an apostrophe (o'brien) but never a
        // possessive — "donna's mother's side" is Donna, not "Donna's Mother".
        if let hit = lower.firstMatch(of: /\b((?:[a-z][a-z-]*(?:'(?!s\b)[a-z-]+)?\s+){0,4}[a-z][a-z-]*(?:'(?!s\b)[a-z-]+)?)'s\s+(?:maternal|paternal|mother'?s|father'?s|mom'?s|dad'?s|ancest\w*|forebears|famil\w*|line|lineage|side|birth\w*)\b/) {
            var words = String(hit.1).split(separator: " ").map(String.init)
            while let first = words.first, trailSubjectFiller.contains(first) { words.removeFirst() }
            return subject(fromWords: words)
        }
        // "first ancestor of donna born outside america" / "ancestors of me".
        if let m = lower.firstMatch(of: /\bancestors?\s+of\s+(.+?)(?:\s+(?:born|who|that|were|was|to)\b|$)/) {
            var words = String(m.1).split(separator: " ").map(String.init)
            if let only = words.first, words.count == 1,
               ["me", "mine", "us", "ours", "myself", "ourselves"].contains(only) { return .owner }
            if let only = words.first, words.count == 1, HalliePronounContinuity.isThirdPersonPronoun(only) {
                return .pronoun(capitalizedName(only))
            }
            while let first = words.first, trailSubjectFiller.contains(first) { words.removeFirst() }
            return subject(fromWords: words)
        }
        return .owner
    }

    private static func subject(fromWords words: [String]) -> TrailSubject {
        guard !words.isEmpty else { return .owner }
        let name = words.joined(separator: " ")
        // Two people are not one line; leave the sentence to the shapes
        // that can say so.
        if words.contains("and") || words.contains("or") || words.contains("&") { return .rejected }
        guard name.firstMatch(of: /^[a-z][a-z .'-]*$/) != nil else { return .rejected }
        if ["me", "us", "mine", "ours", "myself", "ourselves"].contains(name) { return .owner }
        if HalliePronounContinuity.isThirdPersonPronoun(name) { return .pronoun(capitalizedName(name)) }
        return .named(capitalizedName(name))
    }

    // MARK: Paging ("show more")

    /// The next page of the trail the last answer was reading out, from
    /// its query description; nil when the last answer was not a trail.
    /// A page past the end is still returned so the answer can say the
    /// trail was complete.
    static func birthplaceTrailContinuation(queryDescription: String?) -> HallieLineageQuestion? {
        guard let queryDescription, queryDescription.hasPrefix(HallieLineageAnswer.trailQueryPrefix),
              let m = queryDescription.firstMatch(of: /^birthplace trail (\w+) stop=(\S+) (list|firstMatch): .* \[([^\]]+)\] shown (\d+)-(\d+) of (\d+)$/),
              let line = LineageTrail.Line(rawValue: String(m.1)),
              let stop = HallieLineageAnswer.trailStop(fromKey: String(m.2)),
              m.3 == "list",
              let to = Int(m.6) else { return nil }
        return .birthplaceTrailPage(personID: String(m.4), line: line, stop: stop, from: to + 1)
    }
}

// MARK: - Answers

extension HallieLineageAnswer {

    static let trailQueryPrefix = "birthplace trail "

    /// The stop rule as a key for the query description (no spaces, so
    /// the continuation can parse it back).
    static func trailStopKey(_ stop: LineageTrail.Stop) -> String {
        switch stop {
        case .top: return "top"
        case .outsideCountry(let c): return "outside:" + c.replacingOccurrences(of: " ", with: "_")
        case .continent(let c): return "continent:" + c.rawValue.replacingOccurrences(of: " ", with: "_")
        case .generations(let n): return "generations:\(n)"
        }
    }

    static func trailStop(fromKey key: String) -> LineageTrail.Stop? {
        if key == "top" { return .top }
        if key.hasPrefix("outside:") {
            return .outsideCountry(String(key.dropFirst("outside:".count)).replacingOccurrences(of: "_", with: " "))
        }
        if key.hasPrefix("continent:") {
            let name = String(key.dropFirst("continent:".count)).replacingOccurrences(of: "_", with: " ")
            return BirthplaceClassifier.Continent(rawValue: name).map { .continent($0) }
        }
        if key.hasPrefix("generations:"), let n = Int(key.dropFirst("generations:".count)) {
            return .generations(n)
        }
        return nil
    }

    /// The stop rule in words, for the prose and the basis line.
    static func trailStopPhrase(_ stop: LineageTrail.Stop) -> String {
        switch stop {
        case .top: return "where the tree ends"
        case .outsideCountry(let c): return "the first birth outside \(c == BirthplaceClassifier.unitedStates ? "the United States" : c)"
        case .continent(let c): return "the first birth in \(c.rawValue)"
        case .generations(let n): return "\(n) generation\(n == 1 ? "" : "s")"
        }
    }

    /// "born outside the United States" / "born in Europe".
    static func trailBornPhrase(_ stop: LineageTrail.Stop) -> String {
        switch stop {
        case .outsideCountry(let c): return "born outside \(c == BirthplaceClassifier.unitedStates ? "the United States" : c)"
        case .continent(let c): return "born in \(c.rawValue)"
        case .top, .generations: return "born there"
        }
    }

    static func trailLineWords(_ line: LineageTrail.Line) -> String {
        switch line {
        case .maternal: return "maternal line"
        case .paternal: return "paternal line"
        case .allAncestors: return "ancestors"
        }
    }

    static func trailParentWord(_ line: LineageTrail.Line) -> String {
        switch line {
        case .maternal: return "mother"
        case .paternal: return "father"
        case .allAncestors: return "parents"
        }
    }

    static func trailCardLine(_ line: LineageTrail.Line) -> GedcomFamilyGraph.Line {
        switch line {
        case .maternal: return .maternal
        case .paternal: return .paternal
        case .allAncestors: return .both
        }
    }

    static func spelledCount(_ n: Int) -> String {
        guard n >= 1, n <= HallieLineageQuestion.numberWords.count else { return String(n) }
        return HallieLineageQuestion.numberWords[n - 1].capitalized
    }

    static let trailBasis = ArchivistBiographyPolicy.gedcomBasis
        + " Birthplaces from the imported family tree; countries read from the recorded place names; colonial names mapped to today’s borders."

    /// Entry from the question: resolve the person the ordinary way and walk.
    static func birthplaceTrail(person typed: String?,
                                line: LineageTrail.Line,
                                stop: LineageTrail.Stop,
                                ask: HallieLineageQuestion.TrailAsk,
                                context: HallieTurnExecutor.Context) -> Result {
        guard let graph = context.graph else { return noTree(context) }
        switch resolve(typed, context: context, graph: graph) {
        case .failure(let r):
            return r ?? noTree(context)
        case .success(let p, let note):
            return trailAnswer(of: p, isOwner: typed == nil, line: line, stop: stop, ask: ask,
                               from: 1, graph: graph, basisNote: note)
        }
    }

    /// Entry from "show more": the person by GEDCOM pointer, the page after
    /// the last one shown.
    static func birthplaceTrailPage(personID: String,
                                    line: LineageTrail.Line,
                                    stop: LineageTrail.Stop,
                                    from: Int,
                                    context: HallieTurnExecutor.Context) -> Result {
        guard let graph = context.graph else { return noTree(context) }
        guard let person = graph.people[personID] else {
            return Result(route: .graph, outcome: .declined,
                          prose: "I’ve lost the thread of that trail — ask for it again and I’ll start from the top.",
                          basisLine: "Basis: the family tree no longer has the person the last trail was about.",
                          queryDescription: "birthplace trail page: person \(personID) missing",
                          citations: [], catalogPersonName: nil)
        }
        let isOwner = context.speakers.ownerName.map {
            HallieLineageQuestion.normalize($0) == HallieLineageQuestion.normalize(person.name)
        } ?? false
        return trailAnswer(of: person, isOwner: isOwner, line: line, stop: stop, ask: .list,
                           from: from, graph: graph, basisNote: nil)
    }

    /// One line of the read-out: "3. Ethel Cote — 1908, Stukley, Shefford,
    /// Quebec, Canada (first born outside the United States)."
    static func trailLine(_ step: LineageTrail.Step, number: Int, stop: LineageTrail.Stop) -> String {
        let year = step.birthYear.map(String.init) ?? "birth year not recorded"
        let place = step.placeText ?? "birthplace not recorded"
        let marker = step.matchesStop ? " (first \(trailBornPhrase(stop)))" : ""
        return "\(number). \(step.person.name) — \(year), \(place)\(marker)."
    }

    static func trailAnswer(of person: GedcomFamilyGraph.Person,
                            isOwner: Bool,
                            line: LineageTrail.Line,
                            stop: LineageTrail.Stop,
                            ask: HallieLineageQuestion.TrailAsk,
                            from: Int,
                            graph: GedcomFamilyGraph,
                            basisNote: String?) -> Result {
        let walk = LineageTrail.walk(line: line, from: person, stop: stop, graph: graph)
        let who = HallieLineageQuestion.possessive(person.name)
        let basis = trailBasis
            + " Walk: \(trailLineWords(line)); stop: \(trailStopPhrase(stop))."
            + (basisNote.map { " " + $0 } ?? "")
        let cardLine = trailCardLine(line)

        // Nothing to walk: the honest decline, same words as the line card.
        // (An all-ancestors walk with no match also has a one-step path —
        // the generation count is what says whether anything was walked.)
        guard walk.generationsWalked > 0 else {
            return Result(
                route: .graph, outcome: .declined,
                prose: "The family tree doesn’t record \(who) \(trailParentWord(line)), so I can’t trace that line.",
                basisLine: basis,
                queryDescription: trailQueryDescription(person, line: line, stop: stop, ask: ask, from: 1, to: 1, total: 1),
                citations: [], catalogPersonName: person.name,
                offeredActions: [.openFamilyTreePerson(personID: person.id, personName: person.name)])
        }

        func card(_ title: String) -> HallieAttachment {
            .lineage(HallieLineageCard(
                title: title,
                root: HalliePersonCard(person),
                line: cardLine,
                generations: walk.ancestors.map { step in
                    HallieLineageCard.Generation(
                        generation: step.generation,
                        label: HallieAttachmentBuilder.generationLabel(step.generation, line: cardLine),
                        people: [HalliePersonCard(step.person)])
                },
                requested: walk.generationsWalked))
        }

        switch ask {
        case .firstMatch:
            return trailFirstMatchAnswer(walk, person: person, isOwner: isOwner, line: line, stop: stop,
                                         basis: basis, card: card, ask: ask)
        case .list:
            return trailListAnswer(walk, person: person, line: line, stop: stop, from: from,
                                   basis: basis, card: card, ask: ask)
        }
    }

    static func trailQueryDescription(_ person: GedcomFamilyGraph.Person,
                                      line: LineageTrail.Line, stop: LineageTrail.Stop,
                                      ask: HallieLineageQuestion.TrailAsk,
                                      from: Int, to: Int, total: Int) -> String {
        "\(trailQueryPrefix)\(line.rawValue) stop=\(trailStopKey(stop)) \(ask.rawValue): \(person.name) [\(person.id)] shown \(from)-\(to) of \(total)"
    }

    /// Why the read-out ended, in one sentence; only on the last page.
    static func trailEndingSentence(_ walk: LineageTrail.Result, line: LineageTrail.Line,
                                    stop: LineageTrail.Stop) -> String {
        let last = walk.lastGeneration.first?.name ?? walk.steps.last?.person.name ?? ""
        switch walk.ending {
        case .stopped:
            let name = walk.match?.person.name ?? last
            return "\(name) is the first on that line \(trailBornPhrase(stop)), so I stopped there."
        case .top:
            let ends = "The tree records no \(trailParentWord(line)) for \(last), so that is where the line ends."
            switch stop {
            case .outsideCountry, .continent:
                return "No one on that line is recorded as \(trailBornPhrase(stop)). " + ends
            case .top, .generations:
                return ends
            }
        case .ranOut:
            return "Three generations in a row have no recorded birthplace, so the trail runs out at \(last)."
        case .generationCap:
            if case .generations(let n) = stop {
                return "That is \(n) generation\(n == 1 ? "" : "s"), as you asked."
            }
            return "I stopped at \(LineageTrail.generationCap) generations; the tree may go further."
        }
    }

    static func trailListAnswer(_ walk: LineageTrail.Result,
                                person: GedcomFamilyGraph.Person,
                                line: LineageTrail.Line, stop: LineageTrail.Stop, from: Int,
                                basis: String, card: (String) -> HallieAttachment,
                                ask: HallieLineageQuestion.TrailAsk) -> Result {
        let who = HallieLineageQuestion.possessive(person.name)
        let total = walk.steps.count
        let pageSize = HallieLineageQuestion.trailPageSize
        let start = max(1, from)
        let title = "\(who) \(trailLineWords(line)) birthplaces"
        let chips: [HallieTurnExecutor.OfferedAction] = [
            .openFamilyTreePerson(personID: person.id, personName: person.name),
        ]

        // "show more" after the last page.
        guard start <= total else {
            let prose = "That was the whole trail — \(walk.generationsWalked) generation\(walk.generationsWalked == 1 ? "" : "s") back from \(person.name). " + trailEndingSentence(walk, line: line, stop: stop)
            return Result(
                route: .graph, outcome: .answered, prose: prose, basisLine: basis,
                queryDescription: trailQueryDescription(person, line: line, stop: stop, ask: ask, from: total, to: total, total: total),
                citations: [], catalogPersonName: person.name, offeredActions: chips,
                answerPlan: HallieAnswerPlan(route: .graph, shape: .fixed, fallbackText: prose))
        }

        let end = min(total, start + pageSize - 1)
        var sentences: [String] = []
        if start == 1 {
            let gens = walk.generationsWalked
            sentences.append("Here are the birthplaces on \(who) \(trailLineWords(line)), \(gens) generation\(gens == 1 ? "" : "s") back:")
        } else {
            sentences.append("Continuing \(who) \(trailLineWords(line)) birthplaces, \(start) to \(end) of \(total):")
        }
        for (offset, step) in walk.steps[(start - 1)..<end].enumerated() {
            sentences.append(trailLine(step, number: start + offset, stop: stop))
        }
        var actions = chips
        if end < total {
            let remaining = total - end
            sentences.append("\(remaining) more generation\(remaining == 1 ? "" : "s") further back — say “show more” to continue.")
            actions.append(.ask(question: "show more", label: "Show more"))
        } else {
            sentences.append(trailEndingSentence(walk, line: line, stop: stop))
        }
        let prose = sentences.joined(separator: " ")
        return Result(
            route: .graph, outcome: .answered, prose: prose, basisLine: basis,
            queryDescription: trailQueryDescription(person, line: line, stop: stop, ask: ask, from: start, to: end, total: total),
            citations: [], catalogPersonName: person.name,
            offeredActions: actions,
            answerPlan: HallieAnswerPlan(route: .graph, shape: .fixed, fallbackText: prose),
            attachments: [card(title)])
    }

    static func trailFirstMatchAnswer(_ walk: LineageTrail.Result,
                                      person: GedcomFamilyGraph.Person, isOwner: Bool,
                                      line: LineageTrail.Line, stop: LineageTrail.Stop,
                                      basis: String, card: (String) -> HallieAttachment,
                                      ask: HallieLineageQuestion.TrailAsk) -> Result {
        let who = HallieLineageQuestion.possessive(person.name)
        let onLine = line == .allAncestors ? "on any line" : "on that line"
        let born = trailBornPhrase(stop)
        let total = walk.steps.count
        let query = trailQueryDescription(person, line: line, stop: stop, ask: ask, from: 1, to: total, total: total)

        guard let match = walk.match else {
            let n = walk.generationsWalked
            let gens = "\(n) generation\(n == 1 ? "" : "s")"
            let prose: String
            switch walk.ending {
            case .ranOut:
                prose = "I walked \(gens) of \(who) \(trailLineWords(line)) and found nobody recorded as \(born); the trail runs out there — three generations in a row have no recorded birthplace."
            case .generationCap:
                prose = "I walked \(gens) of \(who) \(trailLineWords(line)) — my limit — and found nobody recorded as \(born)."
            case .top, .stopped:
                let ends = walk.lastGeneration.count == 1
                    ? "the tree ends at \(walk.lastGeneration[0].name)"
                    : "the tree ends there"
                prose = "None of \(who) recorded \(trailLineWords(line)) were \(born): I walked \(gens) and \(ends)."
            }
            return Result(
                route: .graph, outcome: .answered, prose: prose, basisLine: basis,
                queryDescription: query, citations: [], catalogPersonName: person.name,
                offeredActions: [.openFamilyTreePerson(personID: person.id, personName: person.name)],
                answerPlan: HallieAnswerPlan(route: .graph, shape: .fixed, fallbackText: prose))
        }

        let g = match.generation
        let year = match.birthYear.map(String.init) ?? "a year not recorded"
        let place = match.placeText ?? "a place not recorded"
        let path = walk.steps.enumerated().map { i, step in
            i == 0 && isOwner ? "you" : step.person.name
        }.joined(separator: " → ")
        var prose = "\(spelledCount(g)) generation\(g == 1 ? "" : "s"). \(match.person.name), born \(year) in \(place), is the first ancestor \(born) \(onLine): \(path)."
        if let mapped = walk.steps.first(where: { $0.birthplace?.mappedFromHistoricalName == true && !$0.matchesStop }),
           let recorded = mapped.birthplace?.recordedCountry, let country = mapped.birthplace?.country {
            prose += " (\(mapped.person.name)’s “\(recorded)” is read as today’s \(country).)"
        }
        return Result(
            route: .graph, outcome: .answered, prose: prose, basisLine: basis,
            queryDescription: query, citations: [], catalogPersonName: person.name,
            offeredActions: [
                .openFamilyTreePerson(personID: match.person.id, personName: match.person.name),
                .openFamilyTreePerson(personID: person.id, personName: person.name),
            ],
            answerPlan: HallieAnswerPlan(route: .graph, shape: .fixed, fallbackText: prose),
            attachments: [card("\(who) line to \(match.person.name)")])
    }
}
