// HallieTurnExecutor+Presence.swift
// Presence and cross-evidence turns: paging, refinement notes, and the
// deterministic "as a baby" → birth-year band step. Everything the model
// could not know (birth years) is resolved here from profiles / CyberBrain /
// GEDCOM and cited in the basis line.

import Foundation
import VideoScanCore

extension HallieTurnExecutor {

    /// Where a birth year came from, for the basis line.
    struct BirthYearEvidence: Sendable, Equatable {
        let personName: String
        let year: Int
        let source: String
    }

    /// "find donna down the cape in the 90s" → people=[Donna, cape]
    /// (clean replay 2026-09-25): a curated place/occasion word in the
    /// people slot is a topic keyword — the tree's Cape family must not
    /// make it a person. Inner-circle names (People tab, CyberBrain) stay.
    static func demoteTopicPeople(
        _ effective: inout ArchivistQueryAST.Presence, context: Context
    ) -> String? {
        guard let people = effective.people, !people.isEmpty else { return nil }
        let topics = people.filter {
            HallieDroppedTopicWord.isTopicWord($0) && !isInnerCircleName($0, context: context)
        }
        guard !topics.isEmpty else { return nil }
        let kept = people.filter { !topics.contains($0) }
        effective.people = kept.isEmpty ? nil : kept
        effective.keywords = (effective.keywords ?? []) + topics
        let quoted = topics.map { "“\($0)”" }.joined(separator: ", ")
        return "\(quoted) is a place or occasion, not a person, so I searched it as a word"
    }

    /// Puts back a curated topic word the translator dropped; returns the
    /// basis note, or nil when nothing was restored.
    static func restoreDroppedTopicWords(
        _ effective: inout ArchivistQueryAST.Presence,
        original payload: ArchivistQueryAST.Presence,
        request: Request
    ) -> String? {
        let intent = request.intent
        let isReRun = intent.refinementNote != nil || intent.refinementChain != nil
            || intent.refinementChange != nil || intent.citationOffset > 0
        guard !isReRun else { return nil }
        let restored = HallieDroppedTopicWord.missing(
            question: intent.originalQuestion,
            people: (payload.people ?? []) + (effective.people ?? []),
            terms: effective.keywords ?? [])
        guard !restored.isEmpty else { return nil }
        effective.keywords = (effective.keywords ?? []) + restored
        return HallieDroppedTopicWord.note(restored)
    }

    /// The presence / cross turn, in the order the steps have always run:
    /// rewrite the payload (names, kinship, pronouns, topic words, unknown
    /// names, age phrase, place) → the ordered path OR one catalog query with
    /// the untagged-name fallback → the prose shape → the basis line → the
    /// typed result. Each step is a named helper below; the comments that
    /// explain WHY a step exists travel with it. (2026-10-25: split from one
    /// 221-line function, CCN 44, with no change in prose, notes or order.)
    static func executePresenceLike(
        _ payload: ArchivistQueryAST.Presence,
        route: Route,
        request: Request,
        context: Context,
        dependencies: Dependencies
    ) async throws -> Result {
        var rewrite: PresenceRewrite
        switch rewritePresencePayload(payload, route: route, request: request, context: context) {
        case .decline(let result):
            return result
        case .proceed(let rewritten):
            rewrite = rewritten
        }

        // Hand-entered place (Rick 2026-09-12): "videos at Cape Cod", "Donna
        // in Westford", "what do we have from Montana". A term that is one
        // of Rick's OWN places — the distinct userPlace values in the
        // catalog, nothing seeded — becomes the EXACT place facet instead
        // of a word search, so a transcript that says "cape cod" no longer
        // answers for a video shot there. Runs after every keyword rewrite
        // above so nothing re-inserts the consumed term (HalliePlaceFacet).
        let knownPlaces = HalliePlaceFacet.knownPlaces(in: context.presenceRecords)
        if let detection = HalliePlaceFacet.apply(
            to: &rewrite.effective, question: request.intent.originalQuestion, knownPlaces: knownPlaces) {
            rewrite.notes.append(detection.note)
        }

        // "and the newest?": the same question, every match, in date
        // order (+DateOrdered). Names have been recovered and rebound
        // above, so the ordered run sees the canonical people.
        if let ordered = request.intent.order {
            return try await executeOrdered(
                rewrite.effective, order: ordered, route: route, intent: request.intent,
                notes: rewrite.notes, context: context)
        }

        let queried = try await runPresenceQuery(
            rewrite.effective, request: request, context: context, dependencies: dependencies,
            knownPlaces: knownPlaces, notes: &rewrite.notes)
        let answer = ArchivistPresenceAnswerComposer.compose(queried.result)
        let prose = presenceProse(
            answer: answer, result: queried.result, request: request,
            announcements: rewrite.correctionAnnouncements)
        let basis = presenceBasis(answer.basisLine, request: request, notes: rewrite.notes)
        return presenceListResult(
            route: route, request: request, executed: queried.effective, result: queried.result,
            answer: answer, prose: prose, basisLine: basis)
    }

    // MARK: Payload rewrites

    /// The payload after every deterministic rewrite, with what the basis
    /// line says about each, and the spelling corrections the prose
    /// announces up front. (For Rick: a plain value struct passed `inout`
    /// through the steps — a non-const reference, no hidden state.)
    struct PresenceRewrite: Sendable {
        var effective: ArchivistQueryAST.Presence
        var notes: [String] = []
        var correctionAnnouncements: [String] = []
    }

    /// What rewriting decided: carry on with the rewritten payload, or give
    /// this decline instead of searching (ambiguous spelling, unresolved kin).
    enum PresenceRewriteOutcome {
        case proceed(PresenceRewrite)
        case decline(Result)
    }

    /// Steps 1–9 of the turn, in their original order. Every step is a note
    /// in the basis line or a decline; none touches the catalog.
    static func rewritePresencePayload(
        _ payload: ArchivistQueryAST.Presence,
        route: Route,
        request: Request,
        context: Context
    ) -> PresenceRewriteOutcome {
        var rewrite = PresenceRewrite(effective: payload)

        if let note = demoteTopicPeople(&rewrite.effective, context: context) { rewrite.notes.append(note) }
        // Tag-only names ("Bonnie", "Hudson Family") before spelling
        // recovery can mistake "the Hudsons" for a typo (+HallieTagOnlyName).
        rewrite.notes.append(contentsOf: mapTagOnlyNames(
            &rewrite.effective, question: request.intent.originalQuestion, context: context))
        // A year the question never says (the current year leaking in) is
        // not a constraint (+HallieInventedPresenceYears).
        rewrite.notes.append(contentsOf: dropInventedPresenceYears(&rewrite.effective, request: request))

        if let declined = recoverPeopleSpelling(&rewrite, route: route, request: request, context: context) {
            return .decline(declined)
        }
        if let declined = rebindSpeakerKinship(
            &rewrite, original: payload, route: route, request: request, context: context) {
            return .decline(declined)
        }

        // "can you play a video for me?" (eval ic009, 2026-09-01): a first-
        // or second-person pronoun the translator kept as a name or a word
        // is you or me, never a search term. Kinship rebinding above has
        // already had its chance to turn "my dad" into a person.
        let droppedPronouns = dropSpeakerPronouns(&rewrite.effective)
        if !droppedPronouns.isEmpty {
            rewrite.notes.append("“\(droppedPronouns.joined(separator: "”, “"))” means you or me, not a search word, so I left it out")
        }

        // "Christmas videos from 2006" arrived as year=2006 alone (live
        // 09-22, 09-24, 09-25) and the answer counted every 2006 item. A
        // holiday / family-event / family-place word the reader said is put
        // back (+HallieDroppedTopicWord). Fresh translations only: a
        // refinement or paging re-run carries the previous AST on purpose.
        if let note = restoreDroppedTopicWords(&rewrite.effective, original: payload, request: request) {
            rewrite.notes.append(note)
        }

        demoteUnknownPeople(&rewrite, context: context)
        applyAgePhraseYearBand(&rewrite, original: payload, context: context)
        return .proceed(rewrite)
    }

    /// Spelling recovery against the People gallery: a typed name becomes
    /// the profile's canonical tag (announced in the prose and the basis);
    /// more than one close family name is a decline, not a guess.
    private static func recoverPeopleSpelling(
        _ rewrite: inout PresenceRewrite, route: Route, request: Request, context: Context
    ) -> Result? {
        guard let people = rewrite.effective.people, !people.isEmpty else { return nil }
        let recovery = recoverPresencePeople(people, context: context)
        if !recovery.ambiguous.isEmpty {
            let choices = recovery.ambiguous.joined(separator: " or ")
            return Result(
                route: route,
                outcome: .declined,
                prose: "I found more than one close family name. Did you mean \(choices)?",
                basisLine: "Basis: spelling recovery was ambiguous; no catalog query was performed.",
                queryDescription: description(of: request.intent.ast),
                citations: [],
                catalogPersonName: nil)
        }
        rewrite.effective.people = recovery.people
        for correction in recovery.corrections {
            rewrite.notes.append(
                "spelling recovery “\(correction.typed)” → People profile “\(correction.canonical)”")
            rewrite.correctionAnnouncements.append(
                "I took “\(correction.typed)” to mean \(correction.canonical).")
        }
        return nil
    }

    /// "videos of my dad": a first-person relative is resolved through the
    /// speaker and the family tree, or declined by name (+SpeakerKinship).
    /// Reads the ORIGINAL people slot (the phrase as the translator left it).
    private static func rebindSpeakerKinship(
        _ rewrite: inout PresenceRewrite,
        original payload: ArchivistQueryAST.Presence,
        route: Route, request: Request, context: Context
    ) -> Result? {
        let kin = SpeakerKinship.rebind(
            people: payload.people ?? [],
            question: request.intent.originalQuestion,
            speakers: context.speakers,
            graph: context.graph,
            cyberBrain: context.cyberBrain,
            kinshipOverlay: kinshipOverlay(context: context))
        if let failure = kin.failure {
            return Result(
                route: route,
                outcome: .declined,
                prose: failure,
                basisLine: "Basis: the question names a relative of the speaker that the family tree could not resolve; no catalog query was performed.",
                queryDescription: description(of: request.intent.ast),
                citations: [],
                catalogPersonName: nil)
        }
        if !kin.notes.isEmpty {
            rewrite.effective.people = kin.people
            rewrite.notes.append(contentsOf: kin.notes)
        }
        // B5, 2026-09-06: a kinship term spent on an identity is not also a
        // content keyword. The translator emits both — `person="my dad"` AND
        // `keyword="dad"` — and the keyword survived into the catalog query,
        // so "show me videos of my dad" became "videos of Richard with
        // 'dad'" and found nothing, twice on 2026-09-05 (rows 301 and 916 of
        // the conversation log). No filename, transcript or caption in the
        // archive says "dad" about Dad; the word was never evidence, it was
        // the question's way of naming him. Dropped silently: a note here
        // would explain a term the user never meant as a search word.
        if let existing = rewrite.effective.keywords, kin.consumedKinPhrase != nil {
            let kept = existing.filter { !kin.spentKeyword($0) }
            if kept.count != existing.count { rewrite.effective.keywords = kept.isEmpty ? nil : kept }
        }
        return nil
    }

    /// "pull up anything from Franklin": the translator took a place for
    /// a person. A name nobody knows — no profile, no tree, no CyberBrain,
    /// no person tag anywhere in the catalog — is searched as a place or
    /// word instead, and the basis says so (overnight cycle 9).
    /// Only when there is something to know people FROM: with no
    /// profiles, tree, CyberBrain or records at all, "unknown" means
    /// nothing and the name stays a person.
    private static func demoteUnknownPeople(_ rewrite: inout PresenceRewrite, context: Context) {
        let hasIdentitySources = (context.profiles?.isEmpty == false) || context.graph != nil
            || context.cyberBrain != nil || !context.presenceRecords.isEmpty
        guard hasIdentitySources, let people = rewrite.effective.people, !people.isEmpty else { return }
        let taggedNames = Set(context.presenceRecords
            .flatMap { $0.confirmedPeople.map { PersonResolver.normalize($0.name) } })
        var keep: [String] = []
        var demoted: [String] = []
        for name in people {
            let known = isKnownPerson(name, context: context, acceptSurname: true)
                || taggedNames.contains(PersonResolver.normalize(name))
            if known { keep.append(name) } else { demoted.append(name) }
        }
        if !demoted.isEmpty {
            rewrite.effective.people = keep.isEmpty ? nil : keep
            rewrite.effective.keywords = (rewrite.effective.keywords ?? []) + demoted
            rewrite.notes.append(contentsOf: demoted.map {
                "“\($0)” isn't a person I know, so I searched it as a place or word"
            })
        }
    }

    /// "as a baby" / "as a kid" / "as a teenager" → a year band from the
    /// FIRST named person's birth year. Only when the AST has no explicit
    /// years (an explicit year is the user's word and wins) and only when
    /// exactly one source vouches for the birth year. Reads the ORIGINAL
    /// payload's keywords and people, as it always has.
    private static func applyAgePhraseYearBand(
        _ rewrite: inout PresenceRewrite, original payload: ArchivistQueryAST.Presence, context: Context
    ) {
        guard payload.yearStart == nil, payload.yearEnd == nil,
              let detection = ArchivistAgePhrase.detect(in: payload.keywords ?? []),
              let person = payload.people?.first else { return }
        if let evidence = birthYear(of: person, context: context),
           let years = ArchivistAgePhrase.years(
               birthYear: evidence.year, band: detection.band) {
            rewrite.effective.yearStart = years.lowerBound
            rewrite.effective.yearEnd = years.upperBound
            rewrite.effective.keywords = (payload.keywords ?? []).filter {
                $0 != detection.keyword
            }
            if rewrite.effective.keywords?.isEmpty == true { rewrite.effective.keywords = nil }
            rewrite.notes.append(
                "using \(evidence.personName)'s birth year \(evidence.year) "
                + "from \(evidence.source) "
                + "(“\(detection.keyword)” = \(years.lowerBound)–\(years.upperBound))")
        } else {
            rewrite.notes.append(
                "I don't know \(person)'s birth year, so “\(detection.keyword)” "
                + "was searched as a word")
        }
    }

    // MARK: The catalog query

    /// What the catalog said, and the payload that was actually executed
    /// (the untagged-name fallback may have turned the names into words).
    struct PresenceQueryOutcome: Sendable {
        let effective: ArchivistQueryAST.Presence
        let result: ArchivistPresenceResult
    }

    /// One presence query off the main actor, then — when the only
    /// constraint is a name no catalog record is tagged with — the same words
    /// tried once more as a place / filename / folder / transcript search.
    private static func runPresenceQuery(
        _ effective: ArchivistQueryAST.Presence,
        request: Request, context: Context, dependencies: Dependencies,
        knownPlaces: [String], notes: inout [String]
    ) async throws -> PresenceQueryOutcome {
        let query = ArchivistPresenceQuery(
            effective, citationOffset: request.intent.citationOffset,
            aliases: presenceAliases(for: effective.people ?? [], context: context))
        let records = context.presenceRecords
        let execute = dependencies.executePresence
        let result = try await detached {
            execute(query, records)
        }
        // "pull up anything from Franklin" when the family tree DOES know a
        // Franklin (eval cs018, 2026-09-01): the name survived demotion as
        // a person, nobody is tagged with it, and the search came back
        // empty — while a folder named Franklin sat there. When the only
        // constraint is a name no catalog record is tagged with, the same
        // words are tried once as a place / filename / folder / transcript
        // search before declining. Both empty → the honest decline stands.
        if result.conclusion != .present,
           request.intent.citationOffset == 0,
           let people = effective.people, !people.isEmpty,
           (effective.keywords ?? []).isEmpty,
           let asWords = try await retryUntaggedNamesAsWords(
               effective, people: people, request: request, context: context,
               execute: execute, knownPlaces: knownPlaces, notes: &notes) {
            return asWords
        }
        return PresenceQueryOutcome(effective: effective, result: result)
    }

    /// The fallback itself. nil = not attempted (a People-tab person, or a
    /// tagged name) or attempted and also empty — the caller's result stands.
    /// The place-facet note is appended as soon as the words are prepared,
    /// whether or not the word search then hits (as it always has).
    private static func retryUntaggedNamesAsWords(
        _ effective: ArchivistQueryAST.Presence,
        people: [String], request: Request, context: Context,
        execute: @Sendable @escaping (ArchivistPresenceQuery, [ArchivistPresenceRecordSnapshot]) -> ArchivistPresenceResult,
        knownPlaces: [String], notes: inout [String]
    ) async throws -> PresenceQueryOutcome? {
        let records = context.presenceRecords
        let taggedNames = Set(records.flatMap {
            $0.confirmedPeople.map { PersonResolver.normalize($0.name) }
        })
        // B6, 2026-09-06: never for someone in the People tab. Live
        // 2026-09-05 row 914, "show me videos of Dad": the name resolved
        // to Rick's father, nobody in the catalog is tagged with him, and
        // this fallback answered with 123 videos of OTHER people saying
        // the word "Richard" — presented as videos of Dad. The honest
        // answer is that no video is tagged with him yet. The fallback
        // still earns its keep for a tree-only name, where "Franklin" or
        // "Hudson" really might be the place on the box.
        let anyIsFamily = people.contains {
            HallieTurnExecutor.isPeopleTabPerson($0, context: context)
        }
        guard !anyIsFamily,
              people.allSatisfy({ !taggedNames.contains(PersonResolver.normalize($0)) }) else { return nil }
        var asWords = effective
        asWords.people = nil
        asWords.keywords = people
        // The same place step for the demoted name (2026-09-12):
        // "videos of Franklin" with a record placed at Franklin, MA.
        if let detection = HalliePlaceFacet.apply(
            to: &asWords, question: request.intent.originalQuestion, knownPlaces: knownPlaces) {
            notes.append(detection.note)
        }
        let wordQuery = ArchivistPresenceQuery(asWords, citationOffset: 0)
        let wordResult = try await detached {
            execute(wordQuery, records)
        }
        guard wordResult.conclusion == .present else { return nil }
        let names = people.map { "“\($0)”" }.joined(separator: ", ")
        notes.append(
            "no one in the catalog is tagged \(names), so I searched it as a place or word")
        return PresenceQueryOutcome(effective: asWords, result: wordResult)
    }

    // MARK: Prose, basis, result

    /// Which sentence the list answer leads with — decided once, then one
    /// switch. The order of these cases IS the precedence.
    enum PresenceProseShape: Equatable, Sendable {
        /// A COUNT re-run (design §3.5, Intent.countOnly): the number is the
        /// answer; `scope` is the refinement's lead, if any, with its space.
        case count(scope: String)
        /// A "show more" page of an answered list.
        case page(offset: Int)
        /// A refined turn says what changed and what is left.
        case refined(change: String)
        /// The composer's own sentence.
        case composed
    }

    static func presenceProseShape(for request: Request, result: ArchivistPresenceResult) -> PresenceProseShape {
        if request.intent.countOnly {
            return .count(scope: request.intent.refinementChange.map { " " + $0 } ?? "")
        }
        if result.conclusion == .present, request.intent.citationOffset > 0 {
            return .page(offset: request.intent.citationOffset)
        }
        if let change = request.intent.refinementChange {
            return .refined(change: change)
        }
        return .composed
    }

    /// The prose and the citations it stands on.
    struct PresenceProse: Sendable {
        let prose: String
        let evidenceCitations: [ArchivistEvidenceCitation]
        let shown: Int
        let total: Int
    }

    private static func presenceProse(
        answer: ArchivistFactualAnswer, result: ArchivistPresenceResult,
        request: Request, announcements: [String]
    ) -> PresenceProse {
        // A COUNT re-run (design §3.5, Intent.countOnly) cites at most a
        // handful; the number is the answer.
        let countExamples = 5
        let evidenceCitations = request.intent.countOnly
            ? Array(result.evidence.citations.prefix(countExamples))
            : result.evidence.citations
        let shown = evidenceCitations.count
        let total = result.evidence.totalMatchCount
        var prose: String
        switch presenceProseShape(for: request, result: result) {
        case .count(let scope):
            // The same noun the list answers use ("N catalog items"), so a
            // golden count reads the same whether the scope named a kind.
            let noun = "catalog item"
            prose = result.conclusion == .present
                ? "\(total) \(noun)\(total == 1 ? "" : "s")\(scope)."
                : "Nothing\(scope)."
        case .page(let offset):
            prose = shown == 0
                ? "That's all of them — I've already shown all \(total)."
                : "Here are \(shown) more (items \(offset + 1)–\(offset + shown) of \(total))."
        case .refined(let change):
            // "Narrowed to Westford, around 2005 — 3 catalog items."
            prose = result.conclusion == .present
                ? "\(change) — \(total) catalog item\(total == 1 ? "" : "s")."
                : "\(change) — nothing matched. " + ArchivistPresenceAnswerComposer.noEvidenceProse
        case .composed:
            prose = answer.prose
        }
        if !announcements.isEmpty {
            prose = announcements.joined(separator: " ") + " " + prose
        }
        return PresenceProse(prose: prose, evidenceCitations: evidenceCitations, shown: shown, total: total)
    }

    /// The basis line: the refinement note first, then every rewrite note in
    /// the order it was made, then the composer's own "N cited of M".
    static func presenceBasis(_ composed: String, request: Request, notes: [String]) -> String {
        var prefixes: [String] = []
        if let note = request.intent.refinementNote { prefixes.append(note) }
        prefixes.append(contentsOf: notes)
        guard !prefixes.isEmpty else { return composed }
        return "Basis: " + prefixes.joined(separator: "; ") + "; "
            + composed.dropFirst("Basis: ".count)
    }

    private static func presenceListResult(
        route: Route, request: Request,
        executed effective: ArchivistQueryAST.Presence,
        result: ArchivistPresenceResult, answer: ArchivistFactualAnswer,
        prose: PresenceProse, basisLine: String
    ) -> Result {
        let citations = normalize(prose.evidenceCitations)
        // The typed plan behind the list answer: the count sentence plus
        // each cited item and why it matched. A model may rephrase these
        // and nothing else (HallieGroundedComposer); the basis line stays
        // deterministic.
        let plan: HallieAnswerPlan? = result.conclusion == .present
            ? HallieAnswerPlan.presenceList(
                route: route,
                prose: prose.prose,
                totalMatchCount: prose.total,
                shownCount: prose.shown,
                citations: citations)
            : nil
        // The retry the not-found sentence just offered, as the search a
        // bare "yes" runs: the query that was EXECUTED (names recovered,
        // "my dad" bound, a demoted name already a word) minus what the
        // sentence named. Only when that sentence is what the reply says —
        // a refinement's "nothing matched" replaces it above and offers
        // nothing. Codex #1352: never from the AST and a decline.
        let retryOffer = request.intent.refinementChange == nil
            ? answer.retryOffer.map {
                HallieOfferAcceptance.Offer(
                    question: request.intent.originalQuestion, executed: effective, dropping: $0)
            }
            : nil
        return Result(
            route: route,
            outcome: result.conclusion == .present ? .answered : .declined,
            prose: prose.prose,
            basisLine: basisLine,
            queryDescription: result.interpretedQuery,
            citations: citations,
            catalogPersonName: nil,
            matchCount: result.conclusion == .present ? prose.total : 0,
            answerPlan: plan,
            retryOffer: retryOffer)
    }

    /// First- and second-person words that must never reach the catalog
    /// as a person or a keyword.
    static let speakerPronouns: Set<String> = [
        "i", "me", "my", "mine", "myself", "we", "us", "our", "ours", "ourselves",
        "you", "your", "yours", "yourself", "yourselves",
    ]

    /// Removes speaker pronouns from `people` and `keywords`; returns what
    /// was dropped, in order, for the basis line. Empty lists become nil so
    /// downstream "no constraints" logic sees them as absent.
    static func dropSpeakerPronouns(_ payload: inout ArchivistQueryAST.Presence) -> [String] {
        func isPronoun(_ word: String) -> Bool {
            speakerPronouns.contains(
                word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,?!'’")))
        }
        var dropped: [String] = []
        if let people = payload.people {
            let kept = people.filter { word in
                if isPronoun(word) { dropped.append(word); return false }
                return true
            }
            payload.people = kept.isEmpty ? nil : kept
        }
        if let keywords = payload.keywords {
            let kept = keywords.filter { word in
                if isPronoun(word) { dropped.append(word); return false }
                return true
            }
            payload.keywords = kept.isEmpty ? nil : kept
        }
        return dropped
    }

    /// The other names each person term is tagged under, from the People
    /// tab: a term that is exactly one profile's own name, or an alias of
    /// exactly one profile, brings that profile's other spellings — MINUS
    /// any spelling a different profile also answers to. Rick's tab has a
    /// brother "Tim" whose profile lists "Timmy", and a son "Timmy": widening
    /// "Tim" to "Timmy" would hand the brother the son's videos. Never widen
    /// a search across two people. Ledger row 17, 2026-09-07.
    static func presenceAliases(for people: [String], context: Context) -> [String: [String]] {
        guard let profiles = context.profiles, !profiles.isEmpty else { return [:] }
        var out: [String: [String]] = [:]
        for typed in people {
            let key = PersonResolver.normalize(typed)
            guard !key.isEmpty else { continue }
            // Live 2026-09-21 ("find videos of tim" → "I don't have any
            // videos tagged with Timothy yet"): Rick renamed his People
            // profiles to legal given names on 2026-09-19/20, so TWO
            // profiles are named Timothy and Dad's is named Richard, while
            // the catalog tags still say "Tim", "Timmy" and "Dad" — the
            // strings captured when the videos were tagged. The typed
            // spelling resolves to ONE profile (by name, alias, full-name
            // form, kin-word alias or pinned tree name), and that profile
            // is searched under every string it has been known by.
            guard let profile = uniqueProfile(spelling: key, profiles: profiles, graph: context.graph)
            else { continue }
            let othersClaim = Set(profiles.lazy
                .filter { $0.stableID != profile.stableID }
                .flatMap { knownSpellings(of: $0, graph: context.graph) }
                .map(PersonResolver.normalize))
            var seen: Set<String> = [key]
            let spellings = knownSpellings(of: profile, graph: context.graph).filter {
                let k = PersonResolver.normalize($0)
                return !othersClaim.contains(k) && seen.insert(k).inserted
            }
            if !spellings.isEmpty { out[key] = spellings }
        }
        return out
    }

    /// Every string this person has been known by: the profile's name,
    /// its aliases, the full-name forms the family-name fields imply, the
    /// bare kin word of a "Dad Breen"-shaped alias ("Dad"), and the name
    /// of the tree person the profile is pinned to. Order is stable
    /// (name, aliases, forms, kin words, tree name) and duplicates are
    /// removed on the normalized key. Tags keyed by POI UUID would make
    /// this unnecessary; until then this is the join.
    static func knownSpellings(of profile: ProfileSnapshot, graph: GedcomFamilyGraph?) -> [String] {
        var out: [String] = [profile.canonicalName] + profile.aliases + profile.fullNameForms
        out.append(profile.displayFullName)
        for alias in profile.aliases {
            if let kin = bareKinWord(inAlias: alias, of: profile) { out.append(kin) }
        }
        if case .familySearchID(let id)? = profile.treeIdentity,
           let person = graph?.person(familySearchID: id) {
            out.append(person.name)
        }
        var seen: Set<String> = []
        return out.filter {
            let k = PersonResolver.normalize($0)
            return !k.isEmpty && seen.insert(k).inserted
        }
    }

    /// "Dad Breen" → "Dad", "Gramma Breen" → "Gramma": a two-word alias
    /// whose second word is one of the profile's own family names and
    /// whose first is a kin term. Nothing else is derived.
    private static let kinTerms: Set<String> = [
        "dad", "daddy", "father", "pop", "papa", "pa", "pops",
        "mom", "mommy", "mother", "mum", "mama", "ma",
        "grampa", "grandpa", "gramps", "grampy", "granddad", "grandad", "grandfather",
        "gramma", "grandma", "granny", "gran", "nana", "nanna", "grandmother",
        "uncle", "aunt", "auntie",
    ]

    private static func bareKinWord(inAlias alias: String, of profile: ProfileSnapshot) -> String? {
        let words = alias.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count == 2 else { return nil }
        let family = Set([profile.surname, profile.maidenName].compactMap { $0 }.map(PersonResolver.normalize))
        guard family.contains(PersonResolver.normalize(words[1])),
              kinTerms.contains(PersonResolver.normalize(words[0])) else { return nil }
        return words[0]
    }

    /// The ONE profile a normalized spelling names: by its own name first
    /// (exact-name-wins, 2026-09-03), then by alias, then by any other
    /// known spelling. Two profiles answering at the same tier → nil.
    private static func uniqueProfile(
        spelling key: String, profiles: [ProfileSnapshot], graph: GedcomFamilyGraph?
    ) -> ProfileSnapshot? {
        let byName = profiles.filter { PersonResolver.normalize($0.canonicalName) == key }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 { return nil }
        let byAlias = profiles.filter { $0.aliases.contains { PersonResolver.normalize($0) == key } }
        if byAlias.count == 1 { return byAlias[0] }
        if byAlias.count > 1 { return nil }
        let byAny = profiles.filter {
            knownSpellings(of: $0, graph: graph).contains { PersonResolver.normalize($0) == key }
        }
        return byAny.count == 1 ? byAny[0] : nil
    }

    private struct PresencePeopleRecovery {
        let people: [String]
        let corrections: [(typed: String, canonical: String)]
        let ambiguous: [String]
    }

    /// Reconcile translator-produced names with the People gallery. A
    /// CyberBrain identity may contribute its fuller spelling (for example,
    /// profile "Rick" ↔ archive identity "Rick Breen"), but the resulting
    /// catalog query always uses the People profile's canonical tag.
    private static func recoverPresencePeople(
        _ typedPeople: [String],
        context: Context
    ) -> PresencePeopleRecovery {
        guard let profiles = context.profiles, !profiles.isEmpty else {
            return PresencePeopleRecovery(
                people: typedPeople, corrections: [], ambiguous: [])
        }
        let cyberPeople = context.cyberBrain?.archive.people ?? []
        let candidates = profiles.map { profile -> (
            identity: String, canonical: String, spellings: [String]
        ) in
            // Every spelling the person is known by (2026-09-21), so a
            // typed "Dad" is the profile aliased "Dad Breen" exactly,
            // never a fuzzy match on a namesake.
            let profileSpellings = knownSpellings(of: profile, graph: context.graph)
            let profileKeys = Set(profileSpellings.map(PersonResolver.normalize))
            let linkedSpellings = cyberPeople.filter { person in
                let personKeys = Set(
                    ([person.canonicalName] + person.aliases)
                        .map(PersonResolver.normalize))
                return !profileKeys.isDisjoint(with: personKeys)
            }.flatMap { [$0.canonicalName] + $0.aliases }
            return (
                identity: profile.stableID,
                canonical: profile.canonicalName,
                spellings: profileSpellings + linkedSpellings)
        }

        var result: [String] = []
        var corrections: [(typed: String, canonical: String)] = []
        for typed in typedPeople {
            let key = PersonResolver.normalize(typed)
            let exactIDs = Set(candidates.compactMap { candidate in
                candidate.spellings.contains {
                    PersonResolver.normalize($0) == key
                } ? candidate.identity : nil
            })
            // The name someone TYPED exactly as a profile's own name wins
            // over profiles that merely list it as an alias: "Timmy" is
            // Timmy, even though Tim's profile knows "Timmy" too (cycle 4:
            // "show me Timmy as a baby" → "Did you mean Tim or Timmy?").
            let canonicalExactIDs = candidates.compactMap { candidate in
                PersonResolver.normalize(candidate.canonical) == key ? candidate.identity : nil
            }
            let matchedIDs: [String]
            if canonicalExactIDs.count == 1 {
                matchedIDs = canonicalExactIDs
            } else if !exactIDs.isEmpty {
                matchedIDs = exactIDs.sorted()
            } else {
                matchedIDs = HallieSpellingRecovery.bestMatches(
                    typed: typed,
                    candidates: candidates.map {
                        (identity: $0.identity, spellings: $0.spellings)
                    })
            }
            if matchedIDs.count > 1 {
                let names = candidates.filter {
                    matchedIDs.contains($0.identity)
                }.map(\.canonical).sorted()
                return PresencePeopleRecovery(
                    people: typedPeople, corrections: [], ambiguous: names)
            }
            guard let matchedID = matchedIDs.first,
                  let match = candidates.first(where: {
                      $0.identity == matchedID
                  }) else {
                result.append(typed)
                continue
            }
            // A canonical name two profiles share ("Timothy" ×2 since the
            // 2026-09-19 renames) names nobody in particular: the typed
            // spelling that DID pick one profile stays the search identity,
            // and presenceAliases widens it to that profile's other names.
            let canonicalKey = PersonResolver.normalize(match.canonical)
            let canonicalShared = candidates.filter {
                PersonResolver.normalize($0.canonical) == canonicalKey
            }.count > 1
            if canonicalShared, canonicalKey != key {
                result.append(typed)
                continue
            }
            result.append(match.canonical)
            if canonicalKey != key {
                corrections.append((typed: typed, canonical: match.canonical))
            }
        }
        return PresencePeopleRecovery(
            people: result, corrections: corrections, ambiguous: [])
    }

    /// One vouched birth year for a typed name, or nil when nobody knows it or
    /// more than one identity answers to the name (never guess between them).
    /// Order: People profile → CyberBrain (→ GEDCOM pointer) → GEDCOM name.
    static func birthYear(of typedName: String, context: Context) -> BirthYearEvidence? {
        let key = PersonResolver.normalize(typedName)
        guard !key.isEmpty else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        if let profiles = context.profiles {
            // Exact name wins here too (2026-09-03). Before, "Tim" matched
            // both the brother NAMED Tim and the son who ALIASES Tim, so
            // this returned nil and "Tim in the 70s" lost its era anchor —
            // the same collision as the which-Tim question.
            let matches = PersonNameClaim.narrow(
                profiles, typed: typedName,
                name: { $0.canonicalName }, aliases: { $0.aliases })
            let ids = Set(matches.map(\.stableID))
            if ids.count == 1, let profile = matches.first,
               let birthdate = profile.birthdate {
                return BirthYearEvidence(
                    personName: profile.canonicalName,
                    year: calendar.component(.year, from: birthdate),
                    source: "the People profile")
            }
            if ids.count > 1 { return nil }
        }
        if let cyberBrain = context.cyberBrain {
            switch cyberBrain.resolve(typedName) {
            case .resolved(let person):
                if let gedcomID = person.gedcomPersonID,
                   let gedcomPerson = context.graph?.people[gedcomID],
                   let year = gedcomPerson.birthYear {
                    return BirthYearEvidence(
                        personName: person.canonicalName,
                        year: year,
                        source: "the family tree")
                }
            case .ambiguous:
                return nil
            case .notFound:
                break
            }
        }
        if let graph = context.graph {
            let matches = graph.people(matching: typedName)
            if matches.count == 1, let year = matches[0].birthYear {
                return BirthYearEvidence(
                    personName: matches[0].name,
                    year: year,
                    source: "the family tree")
            }
        }
        return nil
    }

    /// Whether the presence/cross payload carries an age phrase — the app
    /// coordinator uses this to decide whether profiles/GEDCOM/CyberBrain
    /// need loading for a presence turn at all.
    static func needsBirthYearSources(_ ast: ArchivistQueryAST) -> Bool {
        switch ast {
        case .presence(let payload):
            return payload.yearStart == nil && payload.yearEnd == nil
                && payload.people?.isEmpty == false
                && ArchivistAgePhrase.detect(in: payload.keywords ?? []) != nil
        case .cross(let payload):
            return payload.yearStart == nil && payload.yearEnd == nil
                && payload.people?.isEmpty == false
                && ArchivistAgePhrase.detect(
                    in: (payload.keywords ?? []) + (payload.transcript ?? [])) != nil
        default:
            return false
        }
    }
}
