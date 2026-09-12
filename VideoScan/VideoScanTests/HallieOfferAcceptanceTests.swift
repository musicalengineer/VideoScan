// HallieOfferAcceptanceTests.swift
// Live 2026-09-11 22:01Z: "I looked for videos of richard harding breen sr
// with “wife” and found nothing in the catalog. Want me to try without the
// words, or with a different name?" → Rick: "sure" → "I couldn't tell how
// “sure” narrows down my last answer…" → "yes" → the same. Hallie asked a
// question and then did not recognise the answer to it.
//
// The gallery offer after a biography already had a "yes" road (a
// one-candidate clarification). The not-found offer had none: a declined
// presence turn left nothing in memory that a bare affirmative could
// take. Now the memory keeps the offer — the same search without the
// words (or the year) — and a bare "yes"/"sure"/"ok" right after runs it.
// Without an offer pending the old honest decline stands. Pure fixture,
// no model.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
@Suite("A bare yes takes Hallie's own not-found offer", .serialized)
struct HallieOfferAcceptanceTests {
    typealias Exec = HallieTurnExecutor
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(_ path: String, people: [String], year: Int) -> ArchivistPresenceRecordSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: year, month: 6, day: 15, hour: 12))!
        return ArchivistPresenceRecordSnapshot(
            fullPath: path,
            directory: (path as NSString).deletingLastPathComponent,
            volumeName: "Fixture",
            inferredDate: date,
            confirmedPeople: people.map { ConfirmedTag(name: $0, confirmedAt: stamp) },
            transcript: nil)
    }

    /// 60 Donna videos 1990–2019 and none of Dad — the live catalog shape
    /// for the person Rick asked about.
    private func donnaOnly() -> [ArchivistPresenceRecordSnapshot] {
        (0..<60).map { record("/Fixture/donna_\($0).mov", people: ["Donna"], year: 1990 + $0 / 2) }
    }

    /// Dad is a People-tab person with no videos (live): known, so the
    /// executor keeps him as a person rather than demoting the name to a
    /// search word.
    private let dadProfile = Exec.ProfileSnapshot(
        stableID: "dad", canonicalName: "Richard Harding Breen Sr", aliases: ["Dad"])

    /// Enough Dad videos that dropping the word is NOT a near miss the
    /// relaxed offer would make on its own (ArchivistPresenceExecutor
    /// .relaxedOfferLimit = 200), so the plain not-found offer is what
    /// Hallie says — and taking it has something to show.
    private func manyDad() -> [ArchivistPresenceRecordSnapshot] {
        (0..<201).map { record("/Fixture/dad_\($0).mov", people: ["Richard Harding Breen Sr"], year: 1960 + $0 % 40) }
    }

    /// One turn as the app and the shell run it. With `translated` the
    /// turn is executed as the model's AST directly — what happened live,
    /// where the translator produced the presence search — so the fixture
    /// does not depend on which questions the model-free step claims.
    private func run(
        _ text: String,
        memory: inout Exec.ConversationMemory,
        context: Exec.Context,
        translated: ArchivistQueryAST? = nil
    ) async throws -> (pre: Exec.PreTranslation, result: Exec.Result) {
        if let translated {
            let intent = Exec.Intent(originalQuestion: text, ast: translated)
            let result = try await Exec.execute(Exec.Request(intent: intent), context: context)
            memory.record(intent: intent, result: result)
            return (.translate(question: text, playAfterAnswer: false), result)
        }
        let pre = Exec.preTranslation(
            question: text, playAfterAnswer: false, memory: memory,
            isKnownPerson: { Exec.isKnownPerson($0, context: context) })
        switch pre {
        case .translate:
            Issue.record("\(text): unexpectedly needed translation")
            throw CancellationError()
        case .run(let intent):
            let result = try await Exec.execute(Exec.Request(intent: intent), context: context)
            memory.record(intent: intent, result: result)
            return (pre, result)
        case .answer(let result):
            memory.record(intent: nil, result: result)
            return (pre, result)
        }
    }

    /// The live sentence, with the name in the profile's own casing (the
    /// executor canonicalises a known person before it speaks).
    private static let liveOffer =
        "I looked for videos of Richard Harding Breen Sr with “wife” and found nothing in the catalog. "
        + "Want me to try without the words, or with a different name?"

    // MARK: The live sequence

    @Test func sureAfterTheNotFoundOfferRetriesWithoutTheWords() async throws {
        let context = Exec.Context(presenceRecords: donnaOnly(), profiles: [dadProfile])
        var memory = Exec.ConversationMemory()
        let asked = try await run(
            "who was his wife", memory: &memory, context: context,
            translated: .cross(.init(people: ["richard harding breen sr"], keywords: ["wife"])))
        #expect(asked.result.route == .cross)
        #expect(asked.result.outcome == .declined)
        #expect(asked.result.prose == Self.liveOffer)
        #expect(asked.result.queryDescription == "shape=presence person=Richard Harding Breen Sr keyword=wife")

        let taken = try await run("sure", memory: &memory, context: context)
        guard case .run(let intent) = taken.pre else {
            Issue.record("\"sure\" should take the offer; got \(taken.pre)")
            return
        }
        // The executed search minus its words: the name as the executor
        // canonicalised it, not as the translator typed it.
        #expect(intent.ast == .presence(.init(people: ["Richard Harding Breen Sr"])))
        #expect(taken.result.route == .presence)
        #expect(taken.result.queryDescription == "shape=presence person=Richard Harding Breen Sr")
        #expect(!taken.result.prose.contains("narrows down"))
        #expect(!taken.result.prose.contains("“wife”"))

        // The offer was taken; a second "yes" has nothing left to accept.
        let again = try await run("yes", memory: &memory, context: context)
        #expect(again.result.route == .followUp)
        #expect(again.result.prose.hasPrefix("I couldn't tell how “yes” narrows down my last answer."))
    }

    @Test func yesAfterTheOfferShowsWhatDroppingTheWordFinds() async throws {
        let context = Exec.Context(presenceRecords: manyDad())
        var memory = Exec.ConversationMemory()
        let asked = try await run(
            "videos of dad with wife", memory: &memory, context: context,
            translated: .presence(.init(people: ["Richard Harding Breen Sr"], mediaKind: .video, keywords: ["wife"])))
        #expect(asked.result.outcome == .declined)
        #expect(asked.result.prose.hasSuffix("Want me to try without the words, or with a different name?"),
                Comment(rawValue: asked.result.prose))

        for word in ["yes", "yes please", "ok", "Sure!", "go ahead", "yeah"] {
            var branch = memory
            let taken = try await run(word, memory: &branch, context: context)
            guard case .run(let intent) = taken.pre else {
                Issue.record("\"\(word)\" should take the offer; got \(taken.pre)")
                continue
            }
            #expect(intent.ast == .presence(.init(people: ["Richard Harding Breen Sr"], mediaKind: .video)),
                    Comment(rawValue: "\(word): \(intent.ast)"))
            #expect(taken.result.route == .presence)
            #expect(taken.result.outcome == .answered, Comment(rawValue: "\(word): \(taken.result.prose)"))
            #expect(taken.result.matchCount == 201)
            #expect(taken.result.basisLine.contains("without the words"), Comment(rawValue: taken.result.basisLine))
        }
    }

    @Test func yesAfterAYearOnlyMissRetriesWithoutTheYear() async throws {
        let context = Exec.Context(presenceRecords: donnaOnly())
        var memory = Exec.ConversationMemory()
        let asked = try await run(
            "donna in 1985", memory: &memory, context: context,
            translated: .presence(.init(people: ["Donna"], yearStart: 1985, yearEnd: 1985)))
        #expect(asked.result.outcome == .declined)
        #expect(asked.result.prose.hasSuffix("Want me to try without the year, or with a different name?"),
                Comment(rawValue: asked.result.prose))
        let taken = try await run("yes", memory: &memory, context: context)
        guard case .run(let intent) = taken.pre else {
            Issue.record("\"yes\" should take the offer; got \(taken.pre)")
            return
        }
        #expect(intent.ast == .presence(.init(people: ["Donna"])))
        #expect(taken.result.outcome == .answered)
        #expect(taken.result.matchCount == 60)
    }

    // MARK: No offer pending — the honest decline stands

    @Test func aBareYesWithNothingOfferedStillDeclinesHonestly() async throws {
        let context = Exec.Context(presenceRecords: donnaOnly())
        var memory = Exec.ConversationMemory()
        // Nothing in memory at all: the follow-up resolver has no last
        // answer to refine, so the word goes on to the translator exactly
        // as before — nothing is run locally and no offer is invented.
        let fresh = Exec.preTranslation(
            question: "yes", playAfterAnswer: false, memory: memory,
            isKnownPerson: { Exec.isKnownPerson($0, context: context) })
        guard case .translate(let question, _) = fresh else {
            Issue.record("with nothing in memory a bare yes keeps its old road; got \(fresh)")
            return
        }
        #expect(question == "yes")

        // After an ordinary list answer there is no offer either.
        _ = try await run("videos of donna", memory: &memory, context: context,
                          translated: .presence(.init(people: ["Donna"])))
        let after = try await run("sure", memory: &memory, context: context)
        #expect(after.result.route == .followUp)
        #expect(after.result.prose.hasPrefix("I couldn't tell how “sure” narrows down my last answer."))
    }

    /// A person-only miss offers no retry ("I don't have any videos tagged
    /// with X yet") — there is nothing to drop, so "yes" declines as before.
    @Test func aPersonOnlyMissLeavesNoOfferToTake() async throws {
        let context = Exec.Context(presenceRecords: donnaOnly(), profiles: [dadProfile])
        var memory = Exec.ConversationMemory()
        let asked = try await run("videos of dad", memory: &memory, context: context,
                                  translated: .presence(.init(people: ["Richard Harding Breen Sr"])))
        #expect(asked.result.outcome == .declined)
        #expect(!asked.result.prose.contains("Want me to try"))
        let after = try await run("yes", memory: &memory, context: context)
        #expect(after.result.route == .followUp)
    }

    // MARK: The words

    @Test func bareAffirmativesAndNothingElse() {
        for text in ["yes", "Yes.", "sure", "Sure!", "ok", "okay", "yeah", "yep", "yup", "please",
                     "yes please", "go ahead", "sure, go ahead", "of course", "why not",
                     "ok hallie", "hallie, yes", "yes thanks"] {
            #expect(HallieOfferAcceptance.isBareAffirmative(text), Comment(rawValue: text))
        }
        for text in ["no", "nope", "not now", "yes but only the 90s", "yes, Donna", "with donna",
                     "sure what about tim", "yes and the newest", "help", "", "?", "y tho",
                     "show me", "play the first one"] {
            #expect(!HallieOfferAcceptance.isBareAffirmative(text), Comment(rawValue: text))
        }
    }

    /// The sentence and its offer are decided together, from the executed
    /// query's facets: only a person with words or a year offers a retry.
    @Test func theNotFoundSentenceAndItsOfferAreDecidedTogether() {
        typealias Composer = ArchivistPresenceAnswerComposer
        let words = Composer.noEvidence(for: "shape=presence person=Dad keyword=wife")
        #expect(words.retryOffer == .words)
        #expect(words.prose.hasSuffix("Want me to try without the words, or with a different name?"))
        let year = Composer.noEvidence(for: "shape=presence person=Dad year=1985")
        #expect(year.retryOffer == .year)
        #expect(year.prose.hasSuffix("Want me to try without the year, or with a different name?"))
        // Words win over a year: the sentence names the words, so does the offer.
        #expect(Composer.noEvidence(for: "shape=presence person=Dad years=1990...1995 keyword=wife").retryOffer == .words)
        for query in ["shape=presence person=Dad", "shape=presence keyword=wife",
                      "shape=presence year=1985 keyword=wife", "shape=presence mediaKind=video", ""] {
            let miss = Composer.noEvidence(for: query)
            #expect(miss.retryOffer == nil, Comment(rawValue: query))
            #expect(!miss.prose.contains("Want me to try"), Comment(rawValue: miss.prose))
        }
    }

    /// The offer is the EXECUTED search minus what the sentence named.
    @Test func theOfferIsTheExecutedSearchMinusWhatWasNamed() {
        typealias Offer = HallieOfferAcceptance.Offer
        let executed = ArchivistQueryAST.Presence(
            people: ["Richard Harding Breen Sr"], yearStart: 1990, yearEnd: 1995, mediaKind: .video, keywords: ["wife"])
        let words = Offer(question: "videos of my dad with wife in the early 90s", executed: executed, dropping: .words)
        #expect(words.ast == .presence(.init(people: ["Richard Harding Breen Sr"], yearStart: 1990, yearEnd: 1995, mediaKind: .video)))
        #expect(words.note == "taking my offer: without the words")
        #expect(words.question == "videos of my dad with wife in the early 90s")
        let year = Offer(question: "q", executed: .init(people: ["Donna"], yearStart: 1985, yearEnd: 1985), dropping: .year)
        #expect(year.ast == .presence(.init(people: ["Donna"])))
        #expect(year.note == "taking my offer: without the year")
    }

    /// Memory copies the answer's own payload and nothing else: a decline
    /// with no offer — whatever its route, AST or prose — leaves none.
    @Test func memoryKeepsOnlyWhatTheAnswerOffered() {
        let intent = Exec.Intent(
            originalQuestion: "videos of dad with wife",
            ast: .presence(.init(people: ["Dad"], keywords: ["wife"])))
        func declined(retryOffer: HallieOfferAcceptance.Offer?, prose: String) -> Exec.Result {
            Exec.Result(
                route: .presence, outcome: .declined, prose: prose, basisLine: "Basis: fixture.",
                queryDescription: "shape=presence person=Dad keyword=wife", citations: [],
                catalogPersonName: nil, retryOffer: retryOffer)
        }
        let offer = HallieOfferAcceptance.Offer(
            question: intent.originalQuestion, executed: .init(people: ["Dad"], keywords: ["wife"]), dropping: .words)

        var memory = Exec.ConversationMemory()
        memory.record(intent: intent, result: declined(retryOffer: offer, prose: "… Want me to try without the words, or with a different name?"))
        #expect(memory.pendingOffer == offer)

        // The same decline, same AST, even the same prose — no payload, no offer.
        memory = Exec.ConversationMemory()
        memory.record(intent: intent, result: declined(retryOffer: nil, prose: "… Want me to try without the words, or with a different name?"))
        #expect(memory.pendingOffer == nil)

        // One reply: any recorded turn replaces it.
        memory = Exec.ConversationMemory()
        memory.record(intent: intent, result: declined(retryOffer: offer, prose: "miss"))
        memory.record(intent: nil, result: Exec.Result(
            route: .smalltalk, outcome: .answered, prose: "Hello.", basisLine: "",
            queryDescription: nil, citations: [], catalogPersonName: nil))
        #expect(memory.pendingOffer == nil)
    }

    // MARK: Declines that offered nothing leave nothing (codex #1352)

    /// Two People-tab profiles both answer to "Timmy": the presence path
    /// asks "Did you mean Tim Breen or Timothy Breen Jr?" BEFORE any
    /// catalog query — a decline with no retry in it. A "yes" must not
    /// drop "guitar" and rerun the unresolved name.
    @Test func yesAfterADidYouMeanDoesNotRunAStrippedSearch() async throws {
        let profiles = [
            Exec.ProfileSnapshot(stableID: "tim", canonicalName: "Tim Breen", aliases: ["Timmy"]),
            Exec.ProfileSnapshot(stableID: "timothy", canonicalName: "Timothy Breen Jr", aliases: ["Timmy"]),
        ]
        let context = Exec.Context(presenceRecords: donnaOnly(), profiles: profiles)
        var memory = Exec.ConversationMemory()
        let asked = try await run(
            "videos of timmy with guitar", memory: &memory, context: context,
            translated: .presence(.init(people: ["timmy"], keywords: ["guitar"])))
        #expect(asked.result.outcome == .declined)
        #expect(asked.result.prose == "I found more than one close family name. Did you mean Tim Breen or Timothy Breen Jr?",
                Comment(rawValue: asked.result.prose))
        #expect(asked.result.basisLine.contains("no catalog query was performed"))
        #expect(asked.result.retryOffer == nil)
        #expect(memory.pendingOffer == nil)
        // "guitar" is still part of what memory holds.
        #expect(memory.lastExchange?.ast == .presence(.init(people: ["timmy"], keywords: ["guitar"])))

        let after = try await run("yes", memory: &memory, context: context)
        if case .run(let intent) = after.pre {
            Issue.record("\"yes\" must not run a search after a which-one; ran \(intent.ast)")
        }
        #expect(after.result.route == .followUp)
        #expect(after.result.prose.hasPrefix("I couldn't tell how “yes” narrows down my last answer."),
                Comment(rawValue: after.result.prose))
        #expect(!after.result.basisLine.contains("taking my offer"))
        // Nothing was dropped: the last search memory knows still has the word.
        #expect(memory.lastExchange?.ast == .presence(.init(people: ["timmy"], keywords: ["guitar"])))
    }

    /// "my dad" with no owner set declines before querying ("I don't know
    /// who “my dad” is because no one has told me who is using the
    /// archive…"). Same route, same AST shape as the live miss; no offer.
    @Test func yesAfterAnUnresolvedSpeakerKinshipLeavesNoOffer() async throws {
        let context = Exec.Context(presenceRecords: donnaOnly(), speakers: .none)
        var memory = Exec.ConversationMemory()
        let asked = try await run(
            "videos of my dad with guitar", memory: &memory, context: context,
            translated: .presence(.init(people: ["my dad"], keywords: ["guitar"])))
        #expect(asked.result.outcome == .declined)
        #expect(asked.result.prose.hasPrefix("I don't know who “my dad” is"), Comment(rawValue: asked.result.prose))
        #expect(asked.result.basisLine.contains("no catalog query was performed"))
        #expect(asked.result.retryOffer == nil)
        #expect(memory.pendingOffer == nil)

        let after = try await run("yes", memory: &memory, context: context)
        if case .run(let intent) = after.pre {
            Issue.record("\"yes\" must not run a search after an unresolved relative; ran \(intent.ast)")
        }
        #expect(after.result.route == .followUp)
        #expect(!after.result.basisLine.contains("taking my offer"))
    }

    /// A refinement of the offer, not an acceptance of it, keeps its own
    /// road: "yes but only the 90s" is not a bare affirmative.
    @Test func aQualifiedYesIsNotABareAcceptance() async throws {
        let context = Exec.Context(presenceRecords: manyDad())
        var memory = Exec.ConversationMemory()
        _ = try await run(
            "videos of dad with wife", memory: &memory, context: context,
            translated: .presence(.init(people: ["Richard Harding Breen Sr"], keywords: ["wife"])))
        for text in ["no", "yes but only the 90s", "with donna", "not now"] {
            var branch = memory
            let pre = Exec.preTranslation(
                question: text, playAfterAnswer: false, memory: branch,
                isKnownPerson: { Exec.isKnownPerson($0, context: context) })
            if case .run(let intent) = pre {
                #expect(intent.ast != .presence(.init(people: ["Richard Harding Breen Sr"])),
                        Comment(rawValue: "\(text) must not take the offer"))
            }
            _ = branch
        }
    }
}
