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
//
// codex #1014 (adversarial review of the first cut) — four rules here:
//
// * The generations/Europe form needs a BIRTH or ANCESTRY cue: "how many
//   generations back did Donna travel to Europe?" is not a trail.
// * An explicit possessive name anywhere in the sentence is the subject;
//   a pronoun only stands in when no name is possessive ("trace Donna's
//   line … her ancestors" is Donna). A given name that is also a function
//   word ("Will Breen") is never stripped from the front of a name.
// * Ties: several ancestors at the nearest matching generation are all
//   named; "the first ancestor" is said only when there is exactly one.
// * Paging is bound to the TREE: the continuation carries a tree token
//   and the person's display name, and "show more" after a reload that
//   moved @I1@ to someone else is refused, not misread.

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
    /// A last page may run this many lines over, so a 13-line trail is
    /// not a page of twelve and a page of one — on Rick's real tree
    /// Donna's maternal line leaves the United States on line 13, and
    /// the punchline belongs in the same breath (2026-09-02).
    static let trailPageSlack = 2

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
    /// The ancestry words that make a generations count a TRAIL ask
    /// (codex #1014 item 3): without one of these, or a birth / origin
    /// cue, "how many generations back did Donna travel to Europe" is
    /// about travel, not birthplaces.
    private static let trailAncestryCue = /\bancest\w*\b|\bforebears?\b|\blineage\b|\bline\b|\broots\b|\bheritage\b|\bpedigree\b/
    private static let trailOutsideUS = /\b(?:outside|out\s+of|beyond|away\s+from|not\s+in|not\s+born\s+in|left)\s+(?:of\s+)?(?:the\s+)?(?:usa|u\.?s\.?a?\.?|united\s+states|america|the\s+states|this\s+country|the\s+country)\b|\boverseas\b|\babroad\b|\bforeign(?:-born|\s+born)?\b|\b(?:another|a\s+different|some\s+other|other)\s+countr(?:y|ies)\b|\bnon-?american\b|\bimmigra\w+\b|\bemigra\w+\b|\bold\s+country\b/
    private static let trailEurope = /\beurope\b|\beuropean\b/
    private static let trailGenerationsAsk = /\bhow\s+many\s+generations?\b|\bhow\s+far\s+back\b|\bhow\s+many\s+(?:steps|hops|greats?)\b|\b(?:first|nearest|closest|earliest|most\s+recent)\s+(?:ancestor|forebear|one|person|relative)\b|\bwhich\s+generation\b|\bhow\s+many\s+generations\b/
    private static let trailGenerationCount = /\b(\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty)\s+generations?\b/

    /// The trail shapes, or nil when the sentence is not one. Two rules:
    ///
    /// 1. A generations ask with a stop ("how many generations back …
    ///    born in Europe", "first ancestor born outside America") AND a
    ///    birth / ancestry / origin cue → count to the first match; every
    ///    ancestor unless a line is named.
    /// 2. A named line with a birthplace / origin cue ("birthplaces on
    ///    Donna's mother's side", "where did X's paternal line come from")
    ///    → read the line out, stopping where the sentence says.
    ///
    /// No line, no stop → not ours: "where was donna born", "how many
    /// generations are in the tree", "show donna's family tree", "how
    /// many generations back did donna travel to europe" keep their routes.
    static func birthplaceTrailQuestion(in lower: String) -> HallieLineageQuestion? {
        guard lower.firstMatch(of: trailMediaNoun) == nil else { return nil }
        let linePhrase = lower.firstMatch(of: trailLinePhrase).map { String($0.0) }
        let europe = lower.firstMatch(of: trailEurope) != nil
        let outsideUS = lower.firstMatch(of: trailOutsideUS) != nil
        let generationsAsk = lower.firstMatch(of: trailGenerationsAsk) != nil
        let birthCue = lower.firstMatch(of: trailBirthCue) != nil
        let originCue = lower.firstMatch(of: trailOriginCue) != nil
        let ancestryCue = lower.firstMatch(of: trailAncestryCue) != nil

        let line: LineageTrail.Line? = linePhrase.map {
            $0.hasPrefix("m") ? .maternal : .paternal
        }
        let stop: LineageTrail.Stop
        if europe { stop = .continent(.europe) }
        else if outsideUS { stop = .outsideCountry(BirthplaceClassifier.unitedStates) }
        else if let n = trailGenerations(in: lower) { stop = .generations(n) }
        else { stop = .top }

        let ask: TrailAsk
        if generationsAsk, europe || outsideUS, birthCue || originCue || ancestryCue || line != nil {
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

    /// Filler words that are ALSO given names. One of these directly in
    /// front of a name word is part of the name ("will breen's maternal
    /// line" is Will Breen); in front of another filler word it is the
    /// verb ("will you read out donna's …"). A lone "will donna's line"
    /// keeps "Will Donna", and the resolver retries without it.
    static let trailNameCapableFiller: Set<String> = ["will"]

    private static let trailDeterminers: Set<String> = ["my", "our", "his", "her", "their"]
    private static let trailOwnerWords: Set<String> = ["me", "mine", "us", "ours", "myself", "ourselves"]

    /// "… of donna's maternal line" — up to five words ending in a
    /// possessive right before the line noun.
    /// A window word may carry an apostrophe (o'brien) but never a
    /// possessive — "donna's mother's side" is Donna, not "Donna's Mother".
    private static let trailPossessiveWindow = /\b((?:[a-z][a-z-]*(?:'(?!s\b)[a-z-]+)?\s+){0,4}[a-z][a-z-]*(?:'(?!s\b)[a-z-]+)?)'s\s+(?:maternal|paternal|mother'?s|father'?s|mom'?s|dad'?s|ancest\w*|forebears|famil\w*|line|lineage|side|birth\w*|roots|heritage|pedigree)\b/
    /// "my maternal line" / "her ancestors" — a determiner in front of
    /// the line noun.
    private static let trailDeterminerPhrase = /\b(my|our|his|her|their)\s+(?:maternal|paternal|mother'?s|father'?s|mom'?s|dad'?s|ancest\w*|forebears|famil\w*|line|lineage|birth\w*|roots|heritage|pedigree)\b/
    /// "first ancestor of donna born outside america" / "ancestors of me".
    private static let trailAncestorsOf = /\bancestors?\s+of\s+(.+?)(?:\s+(?:born|who|that|were|was|to)\b|$)/

    /// The person the trail is about. See `TrailSubject`. Precedence
    /// (codex #1014 item 3): an explicit possessive name anywhere in the
    /// sentence, then "ancestors of X", then a determiner ("my", "her"),
    /// then the owner.
    static func trailSubject(in lower: String) -> TrailSubject {
        for hit in lower.matches(of: trailPossessiveWindow) {
            let words = stripFiller(String(hit.1).split(separator: " ").map(String.init))
            // "her mother's side" / "my mother's side": a determiner-led
            // window is not a name; the determiner rule below reads it.
            guard let first = words.first, !trailDeterminers.contains(first) else { continue }
            return subject(fromWords: words)
        }
        if let m = lower.firstMatch(of: trailAncestorsOf) {
            let raw = String(m.1).split(separator: " ").map(String.init)
            if raw.count == 1, let only = raw.first {
                if trailOwnerWords.contains(only) { return .owner }
                if HalliePronounContinuity.isThirdPersonPronoun(only) { return .pronoun(capitalizedName(only)) }
            }
            let words = stripFiller(raw)
            if !words.isEmpty { return subject(fromWords: words) }
        }
        if let m = lower.firstMatch(of: trailDeterminerPhrase) {
            let word = String(m.1)
            return HalliePronounContinuity.isThirdPersonPronoun(word)
                ? .pronoun(capitalizedName(word)) : .owner
        }
        return .owner
    }

    /// Filler off the FRONT of a possessive window. A name-capable filler
    /// word ("will") stays when the word after it is not filler.
    static func stripFiller(_ input: [String]) -> [String] {
        var words = input
        while let first = words.first, trailSubjectFiller.contains(first) {
            if trailNameCapableFiller.contains(first), words.count >= 2,
               !trailSubjectFiller.contains(words[1]) { break }
            words.removeFirst()
        }
        return words
    }

    private static func subject(fromWords words: [String]) -> TrailSubject {
        guard !words.isEmpty else { return .owner }
        let name = words.joined(separator: " ")
        // Two people are not one line; leave the sentence to the shapes
        // that can say so.
        if words.contains("and") || words.contains("or") || words.contains("&") { return .rejected }
        guard name.firstMatch(of: /^[a-z][a-z .'-]*$/) != nil else { return .rejected }
        if trailOwnerWords.contains(name) { return .owner }
        if HalliePronounContinuity.isThirdPersonPronoun(name) { return .pronoun(capitalizedName(name)) }
        return .named(capitalizedName(name))
    }

    // MARK: Paging ("show more")

    /// One read-out segment of a query description, as `trailQueryDescription`
    /// writes it — also found inside a joined "two questions: A + B".
    private static let trailSegment = /birthplace trail (\w+) stop=(\S+) (list|firstMatch): (.+?) \[([^\]]+)\] tree=(\S+) shown (\d+)-(\d+) of (\d+)/

    /// The next page of the trail the last answer was reading out, from
    /// its query description; nil when the last answer was not a trail,
    /// or held MORE than one read-out (a joined pair of trails: "show
    /// more" would be ambiguous, and the join offers no chip for it).
    /// A page past the end is still returned so the answer can say the
    /// trail was complete. The continuation carries the tree token and
    /// the person's display name; the page answer re-validates both.
    static func birthplaceTrailContinuation(queryDescription: String?) -> HallieLineageQuestion? {
        guard let segment = trailContinuationSegment(in: queryDescription),
              let line = LineageTrail.Line(rawValue: segment.line),
              let stop = HallieLineageAnswer.trailStop(fromKey: segment.stopKey) else { return nil }
        return .birthplaceTrailPage(personID: segment.personID, personName: segment.personName,
                                    treeToken: segment.treeToken, line: line, stop: stop, from: segment.to + 1)
    }

    /// A read-out segment of a query description, parsed.
    struct TrailSegment: Equatable {
        let line: String
        let stopKey: String
        let personName: String
        let personID: String
        let treeToken: String
        let from: Int
        let to: Int
        let total: Int
        var isUnfinished: Bool { to < total }
    }

    /// The ONE read-out "show more" would continue, or nil. A lone
    /// read-out is continued even when complete (the answer then says the
    /// trail was whole); among several, only a single unfinished one is.
    /// The join uses the same rule to decide whether to offer the chip.
    static func trailContinuationSegment(in queryDescription: String?) -> TrailSegment? {
        guard let queryDescription else { return nil }
        let lists: [TrailSegment] = queryDescription.matches(of: trailSegment).compactMap { m in
            guard m.3 == "list", let from = Int(m.7), let to = Int(m.8), let total = Int(m.9) else { return nil }
            return TrailSegment(line: String(m.1), stopKey: String(m.2), personName: String(m.4),
                                personID: String(m.5), treeToken: String(m.6), from: from, to: to, total: total)
        }
        if lists.count == 1 { return lists[0] }
        let unfinished = lists.filter(\.isUnfinished)
        return unfinished.count == 1 ? unfinished[0] : nil
    }
}

// MARK: - Answers

extension HallieLineageAnswer {

    static let trailQueryPrefix = "birthplace trail "
    /// The chip a paged read-out offers; the join drops it when two
    /// read-outs would both claim "show more".
    static let trailShowMoreAction = HallieTurnExecutor.OfferedAction.ask(question: "show more", label: "Show more")
    /// The refusal when "show more" arrives after the tree changed.
    static let trailStaleProse = "That list is from an earlier tree; ask again."

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
        + " Birthplaces from the imported family tree; countries read from the recorded place names; colonial names mapped to today’s borders; names that spanned today’s borders are reported but not counted."

    // MARK: Tree identity

    /// A token naming THIS tree, so a paged read-out is never continued
    /// against a different one (codex #1014 item 4): the source file's
    /// SHA-256 when the graph was read from a file, the source hashes of
    /// an in-memory merge, else a digest of every record (text parses —
    /// tests and imports). Deterministic across processes; no randomness.
    static func trailTreeToken(_ graph: GedcomFamilyGraph) -> String {
        if let fingerprint = graph.sourceFingerprint, !fingerprint.isEmpty {
            return String(fingerprint.prefix(16))
        }
        // FNV-1a, 64-bit: a tiny stable hash, the way C++ would write it.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func feed(_ s: String) {
            for byte in s.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            hash ^= 0xff
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let sourceHashes = graph.sourceProvenance.compactMap(\.sha256)
        if !sourceHashes.isEmpty, sourceHashes.count == graph.sourceProvenance.count {
            for h in sourceHashes { feed(h) }
        } else {
            // O(people): once per trail answer, only for graphs with no
            // source hash at all. 39k records ≈ tens of milliseconds.
            for id in graph.people.keys.sorted() {
                feed(id)
                if let p = graph.people[id] {
                    feed(p.name)
                    feed(p.birthDate ?? "")
                }
            }
            for id in graph.rootPersonIDs { feed(id) }
        }
        return String(hash, radix: 16)
    }

    // MARK: Entry points

    /// Entry from the question: resolve the person the ordinary way and walk.
    static func birthplaceTrail(person typed: String?,
                                line: LineageTrail.Line,
                                stop: LineageTrail.Stop,
                                ask: HallieLineageQuestion.TrailAsk,
                                context: HallieTurnExecutor.Context) -> Result {
        guard let graph = context.graph else { return noTree(context) }
        switch resolve(typed, context: context, graph: graph) {
        case .failure(let r):
            // "will donna's maternal line …" (codex #1014 item 3): the
            // detector keeps a name-capable verb in front of a name, so
            // "Will Donna" is tried first; when the tree has nobody by
            // that name and the rest resolves, the rest is the person.
            if let typed, r?.outcome == .declined,
               let retried = trailRetryWithoutLeadingVerb(typed, context: context, graph: graph) {
                return trailAnswer(of: retried.person, isOwner: false, line: line, stop: stop, ask: ask,
                                   from: 1, graph: graph, basisNote: retried.note)
            }
            return r ?? noTree(context)
        case .success(let p, let note):
            return trailAnswer(of: p, isOwner: typed == nil, line: line, stop: stop, ask: ask,
                               from: 1, graph: graph, basisNote: note)
        }
    }

    static func trailRetryWithoutLeadingVerb(_ typed: String,
                                             context: HallieTurnExecutor.Context,
                                             graph: GedcomFamilyGraph) -> (person: GedcomFamilyGraph.Person, note: String)? {
        let words = typed.split(separator: " ").map(String.init)
        guard words.count >= 2, let first = words.first,
              HallieLineageQuestion.trailNameCapableFiller.contains(first.lowercased()) else { return nil }
        let rest = words.dropFirst().joined(separator: " ")
        guard case .success(let person, _) = resolve(rest, context: context, graph: graph) else { return nil }
        return (person, "I read “\(typed)” as \(rest).")
    }

    /// Entry from "show more": the person by GEDCOM pointer, the page after
    /// the last one shown — only when the tree is the one the read-out
    /// came from and the pointer still names the same person.
    static func birthplaceTrailPage(personID: String,
                                    personName: String,
                                    treeToken: String,
                                    line: LineageTrail.Line,
                                    stop: LineageTrail.Stop,
                                    from: Int,
                                    context: HallieTurnExecutor.Context) -> Result {
        guard let graph = context.graph else { return noTree(context) }
        guard trailTreeToken(graph) == treeToken,
              let person = graph.people[personID], person.name == personName else {
            return Result(route: .graph, outcome: .declined,
                          prose: trailStaleProse,
                          basisLine: "Basis: the family tree changed since that trail was read out, so its page was not continued.",
                          queryDescription: "birthplace trail page: tree changed (\(personName) [\(personID)])",
                          citations: [], catalogPersonName: nil)
        }
        let isOwner = context.speakers.ownerName.map {
            HallieLineageQuestion.normalize($0) == HallieLineageQuestion.normalize(person.name)
        } ?? false
        return trailAnswer(of: person, isOwner: isOwner, line: line, stop: stop, ask: .list,
                           from: from, graph: graph, basisNote: nil)
    }

    // MARK: Prose

    /// One line of the read-out: "3. Ethel Cote — 1908, Stukley, Shefford,
    /// Quebec, Canada (first born outside the United States)." A place
    /// that spanned today's borders is read as recorded and marked.
    static func trailLine(_ step: LineageTrail.Step, number: Int, stop: LineageTrail.Stop) -> String {
        let year = step.birthYear.map(String.init) ?? "birth year not recorded"
        let place = step.placeText ?? "birthplace not recorded"
        let marker: String
        if step.matchesStop {
            marker = " (first \(trailBornPhrase(stop)))"
        } else if step.birthplace?.isAmbiguous == true {
            marker = " (borders changed; not counted)"
        } else {
            marker = ""
        }
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
        let token = trailTreeToken(graph)

        // Nothing to walk: the honest decline, same words as the line card.
        // (An all-ancestors walk with no match also has a one-step path —
        // the generation count is what says whether anything was walked.)
        guard walk.generationsWalked > 0 else {
            return Result(
                route: .graph, outcome: .declined,
                prose: "The family tree doesn’t record \(who) \(trailParentWord(line)), so I can’t trace that line.",
                basisLine: basis,
                queryDescription: trailQueryDescription(person, token: token, line: line, stop: stop, ask: ask, from: 1, to: 1, total: 1),
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
                                         basis: basis, token: token, card: card, ask: ask)
        case .list:
            return trailListAnswer(walk, person: person, line: line, stop: stop, from: from,
                                   basis: basis, token: token, card: card, ask: ask)
        }
    }

    static func trailQueryDescription(_ person: GedcomFamilyGraph.Person, token: String,
                                      line: LineageTrail.Line, stop: LineageTrail.Stop,
                                      ask: HallieLineageQuestion.TrailAsk,
                                      from: Int, to: Int, total: Int) -> String {
        "\(trailQueryPrefix)\(line.rawValue) stop=\(trailStopKey(stop)) \(ask.rawValue): \(person.name) [\(person.id)] tree=\(token) shown \(from)-\(to) of \(total)"
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
                                basis: String, token: String, card: (String) -> HallieAttachment,
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
                queryDescription: trailQueryDescription(person, token: token, line: line, stop: stop, ask: ask, from: total, to: total, total: total),
                citations: [], catalogPersonName: person.name, offeredActions: chips,
                answerPlan: HallieAnswerPlan(route: .graph, shape: .fixed, fallbackText: prose))
        }

        let remaining = total - start + 1
        let end = remaining <= pageSize + HallieLineageQuestion.trailPageSlack
            ? total : min(total, start + pageSize - 1)
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
            actions.append(trailShowMoreAction)
        } else {
            sentences.append(trailEndingSentence(walk, line: line, stop: stop))
        }
        let prose = sentences.joined(separator: " ")
        return Result(
            route: .graph, outcome: .answered, prose: prose, basisLine: basis,
            queryDescription: trailQueryDescription(person, token: token, line: line, stop: stop, ask: ask, from: start, to: end, total: total),
            citations: [], catalogPersonName: person.name,
            offeredActions: actions,
            answerPlan: HallieAnswerPlan(route: .graph, shape: .fixed, fallbackText: prose),
            attachments: [card(title)])
    }

    /// Ties named in full before "and N more".
    static let trailTieNames = 3

    /// "born 1904 in Glasgow, Scotland" for a tie entry.
    static func trailBornDetail(_ step: LineageTrail.Step) -> String {
        let year = step.birthYear.map(String.init) ?? "a year not recorded"
        let place = step.placeText ?? "a place not recorded"
        return "born \(year) in \(place)"
    }

    /// "you → Eileen Latta → Mary McGill".
    static func trailPathWords(_ path: [LineageTrail.Step], isOwner: Bool) -> String {
        path.enumerated().map { i, step in i == 0 && isOwner ? "you" : step.person.name }
            .joined(separator: " → ")
    }

    static func trailFirstMatchAnswer(_ walk: LineageTrail.Result,
                                      person: GedcomFamilyGraph.Person, isOwner: Bool,
                                      line: LineageTrail.Line, stop: LineageTrail.Stop,
                                      basis: String, token: String, card: (String) -> HallieAttachment,
                                      ask: HallieLineageQuestion.TrailAsk) -> Result {
        let who = HallieLineageQuestion.possessive(person.name)
        let onLine = line == .allAncestors ? "on any line" : "on that line"
        let born = trailBornPhrase(stop)
        let total = walk.steps.count
        let query = trailQueryDescription(person, token: token, line: line, stop: stop, ask: ask, from: 1, to: total, total: total)

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
        let generations = "\(spelledCount(g)) generation\(g == 1 ? "" : "s")."
        var prose: String
        var chips: [HallieTurnExecutor.OfferedAction] = []
        if walk.matches.count <= 1 {
            let path = trailPathWords(walk.steps, isOwner: isOwner)
            prose = "\(generations) \(match.person.name), \(trailBornDetail(match)), is the first ancestor \(born) \(onLine): \(path)."
            chips.append(.openFamilyTreePerson(personID: match.person.id, personName: match.person.name))
        } else {
            // Several at the same distance (codex #1014 item 2): all are
            // named, none is "the" first.
            let ties = walk.matches
            let shown = Array(ties.prefix(trailTieNames))
            let entries = shown.map { "\($0.person.name) (\(trailBornDetail($0)))" }
            let more = ties.count - shown.count
            // "A (…) and B (…)." / "A (…), B (…), C (…) and 2 more."
            let named = more > 0
                ? entries.joined(separator: ", ") + " and \(more) more"
                : HallieNameQualifier.joined(entries, conjunction: "and")
            let where_ = line == .allAncestors ? "at that distance" : "at that distance on that line"
            prose = "\(generations) \(spelledCount(ties.count)) ancestors \(born) \(where_): \(named)."
            let paths = walk.matchPaths.prefix(shown.count).map { trailPathWords($0, isOwner: isOwner) }
            if !paths.isEmpty { prose += " Paths: " + paths.joined(separator: "; ") + "." }
            chips = shown.map { .openFamilyTreePerson(personID: $0.person.id, personName: $0.person.name) }
        }
        // Notes on the way up: a colonial name read as today's country,
        // a name that spanned today's borders read but not counted.
        let onTheWay = walk.matchPaths.flatMap { $0.dropLast() }
        if let mapped = onTheWay.first(where: { $0.birthplace?.mappedFromHistoricalName == true && $0.birthplace?.country != nil }),
           let recorded = mapped.birthplace?.recordedCountry, let country = mapped.birthplace?.country {
            prose += " (\(mapped.person.name)’s “\(recorded)” is read as today’s \(country).)"
        }
        if let ambiguous = onTheWay.first(where: { $0.birthplace?.isAmbiguous == true }),
           let raw = ambiguous.placeText {
            prose += " (\(ambiguous.person.name)’s birthplace is recorded as “\(raw)” — borders changed; not counted.)"
        }
        chips.append(.openFamilyTreePerson(personID: person.id, personName: person.name))
        let title = walk.matches.count <= 1
            ? "\(who) line to \(match.person.name)"
            : "\(who) line to \(match.person.name) (one of \(walk.matches.count))"
        return Result(
            route: .graph, outcome: .answered, prose: prose, basisLine: basis,
            queryDescription: query, citations: [], catalogPersonName: person.name,
            offeredActions: chips,
            answerPlan: HallieAnswerPlan(route: .graph, shape: .fixed, fallbackText: prose),
            attachments: [card(title)])
    }
}
