import Foundation
import Testing
@testable import VideoScan

// MARK: - HallieTurnExecutor.executePresenceLike — characterization
//
// Written 2026-10-25 BEFORE the 221-line / CCN 44 presence turn was split
// into named steps (payload rewrites → one query + the tagged-name
// fallback → prose shape → basis → result). Each test pins one question
// shape or answer branch as it behaved on the unchanged code — exact prose,
// exact basis notes, the order notes appear in, what is nil. The refactor
// must leave every test green; the production entry (`execute(_:context:)`)
// is used so the real route reaches the function.
//
// Red/green record (deliberate mutations on the UNCHANGED function, each
// reverted before the refactor):
//
//   mutation                                                     | red test
//   -------------------------------------------------------------|------------------------------------------
//   count noun "catalog item" → "video"                          | countOnlyPhrasesTheNumberAndCitesAtMostFive
//   drop the correction-announcement prefix                      | spellingCorrectionIsAnnouncedBeforeTheProse
//   refinementNote appended AFTER notes instead of before        | basisPrefixIsRefinementNoteThenNotesInOrder
//
// Green on the unchanged code, green after the refactor.

@Suite("Hallie presence turn — characterization")
struct HalliePresenceLikeCharacterizationTests {

    private typealias Exec = HallieTurnExecutor

    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func date(_ year: Int, _ month: Int = 6, _ day: Int = 15) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func tagged(_ path: String, _ names: String..., inferred: Date? = nil,
                        resolved: Date? = nil, place: String? = nil) -> ArchivistPresenceRecordSnapshot {
        ArchivistPresenceRecordSnapshot(
            fullPath: path,
            directory: (path as NSString).deletingLastPathComponent,
            volumeName: "X",
            inferredDate: inferred,
            confirmedPeople: names.map { ConfirmedTag(name: $0, confirmedAt: stamp) },
            resolvedDate: resolved,
            userPlace: place)
    }

    private func donnaProfile(birthdate: Date? = nil) -> Exec.ProfileSnapshot {
        .init(stableID: "donna", canonicalName: "Donna", aliases: [], birthdate: birthdate)
    }

    private func ask(_ question: String, _ payload: ArchivistQueryAST.Presence,
                     context: Exec.Context,
                     citationOffset: Int = 0,
                     refinementNote: String? = nil,
                     refinementChange: String? = nil,
                     order: Exec.OrderRequest? = nil,
                     countOnly: Bool = false) async throws -> Exec.Result {
        try await Exec.execute(
            .init(intent: .init(originalQuestion: question, ast: .presence(payload),
                                citationOffset: citationOffset,
                                refinementNote: refinementNote,
                                refinementChange: refinementChange,
                                order: order, countOnly: countOnly)),
            context: context)
    }

    // MARK: Plain list, miss, offer

    @Test func plainListAnswerCarriesCountPlanAndBasis() async throws {
        let context = Exec.Context(
            presenceRecords: [tagged("/Volumes/X/a.mov", "Donna"), tagged("/Volumes/X/b.mov", "Donna")],
            profiles: [donnaProfile()])
        let r = try await ask("show me Donna", .init(people: ["Donna"]), context: context)
        #expect(r.route == .presence)
        #expect(r.outcome == .answered)
        #expect(r.prose == "I found 2 catalog items matching that.")
        #expect(r.basisLine == "Basis: 2 cited of 2 matching catalog items.")
        #expect(r.citations.map(\.filename) == ["a.mov", "b.mov"])
        #expect(r.matchCount == 2)
        #expect(r.answerPlan != nil)
        #expect(r.retryOffer == nil)
        #expect(r.queryDescription?.hasPrefix("shape=presence") == true)
    }

    @Test func personOnlyMissForAPeopleTabPersonDeclinesWithoutAnOffer() async throws {
        // B6: a People-tab person nobody is tagged with never falls back to a
        // word search — the honest sentence is "not tagged yet".
        let context = Exec.Context(
            presenceRecords: [tagged("/Volumes/X/Donna/a.mov", "Matt")],
            profiles: [donnaProfile(), .init(stableID: "matt", canonicalName: "Matt")])
        let r = try await ask("show me Donna", .init(people: ["Donna"]), context: context)
        #expect(r.outcome == .declined)
        #expect(r.prose.hasPrefix("I don't have any videos tagged with Donna yet."), Comment(rawValue: r.prose))
        #expect(r.basisLine == "Basis: no matching catalog evidence.")
        #expect(r.citations.isEmpty)
        #expect(r.matchCount == 0)
        #expect(r.answerPlan == nil)
        #expect(r.retryOffer == nil)
        #expect(!r.basisLine.contains("searched it as a place or word"))
    }

    @Test func personPlusWordMissOffersTheRetryFromTheExecutedQuery() async throws {
        // Nobody is tagged Donna at all: the composer cannot relax the words
        // into "but I have N videos of Donna", so it offers the retry.
        let context = Exec.Context(
            presenceRecords: [tagged("/Volumes/X/a.mov", "Matt")],
            profiles: [donnaProfile(), .init(stableID: "matt", canonicalName: "Matt")])
        let r = try await ask("Donna at the parade", .init(people: ["Donna"], keywords: ["parade"]), context: context)
        #expect(r.outcome == .declined)
        #expect(r.prose.contains("Want me to try without the words, or with a different name?"), Comment(rawValue: r.prose))
        #expect(r.retryOffer?.dropped == .words)
        #expect(r.retryOffer?.question == "Donna at the parade")
        // The offer is the EXECUTED query minus what the sentence offered to drop.
        #expect(r.retryOffer?.ast == .presence(.init(people: ["Donna"])))
    }

    @Test func personPlusWordMissRelaxesTheWordsWhenThePersonHasVideos() async throws {
        let context = Exec.Context(
            presenceRecords: [tagged("/Volumes/X/a.mov", "Donna")],
            profiles: [donnaProfile()])
        let r = try await ask("Donna at the parade", .init(people: ["Donna"], keywords: ["parade"]), context: context)
        #expect(r.outcome == .declined)
        #expect(r.prose == "I don't see “parade” mentioned anywhere, but I have 1 video of Donna — want those?")
        #expect(r.retryOffer == nil)
    }

    // MARK: Spelling recovery

    @Test func ambiguousSpellingDeclinesBeforeAnyCatalogQuery() async throws {
        let context = Exec.Context(
            presenceRecords: [tagged("/Volumes/X/a.mov", "Timmy")],
            profiles: [
                .init(stableID: "tim", canonicalName: "Tim", aliases: ["Timmy"]),
                .init(stableID: "tj", canonicalName: "Timothy Jr", aliases: ["Timmy"]),
            ])
        let r = try await ask("show me Timmy", .init(people: ["Timmy"]), context: context)
        #expect(r.outcome == .declined)
        #expect(r.prose == "I found more than one close family name. Did you mean Tim or Timothy Jr?")
        #expect(r.basisLine == "Basis: spelling recovery was ambiguous; no catalog query was performed.")
        #expect(r.queryDescription == "shape=presence")
        #expect(r.citations.isEmpty)
    }

    @Test func spellingCorrectionIsAnnouncedBeforeTheProse() async throws {
        let context = Exec.Context(
            presenceRecords: [tagged("/Volumes/X/a.mov", "Donna")],
            profiles: [donnaProfile()])
        let r = try await ask("show me Dona", .init(people: ["Dona"]), context: context)
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose == "I took “Dona” to mean Donna. I found 1 catalog item matching that.")
        #expect(r.basisLine.hasPrefix("Basis: spelling recovery “Dona” → People profile “Donna”; "), Comment(rawValue: r.basisLine))
    }

    // MARK: Speaker kinship

    @Test func unresolvableKinshipDeclinesWithTheTreeBasis() async throws {
        let context = Exec.Context(
            presenceRecords: [tagged("/Volumes/X/a.mov", "Richard Breen")],
            profiles: [])
        let r = try await ask("show me videos of my dad", .init(people: ["my dad"]), context: context)
        #expect(r.outcome == .declined)
        #expect(r.prose.contains("“my dad”"), Comment(rawValue: r.prose))
        #expect(r.basisLine == "Basis: the question names a relative of the speaker that the family tree could not resolve; no catalog query was performed.")
        #expect(r.citations.isEmpty)
    }

    @Test func resolvedKinshipRebindsThePersonAndDropsTheSpentKeyword() async throws {
        // People-tab relationships: "Rick Breen is child of Richard Breen".
        let context = Exec.Context(
            presenceRecords: [tagged("/Volumes/X/a.mov", "Richard Breen"), tagged("/Volumes/X/b.mov", "Donna")],
            profiles: [
                .init(stableID: "rick", canonicalName: "Rick Breen", aliases: [],
                      kinships: [Kinship(relation: .child, relativeTo: .profile(name: "Richard Breen"))], sex: .male),
                .init(stableID: "richard", canonicalName: "Richard Breen", aliases: [], sex: .male),
            ],
            speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie"))
        // B5: `person="my dad"` AND `keyword="dad"` — the word is spent on the
        // identity and must not survive into the content search.
        let r = try await ask("show me videos of my dad", .init(people: ["my dad"], keywords: ["dad"]), context: context)
        #expect(r.outcome == .answered, Comment(rawValue: r.prose + " | " + r.basisLine))
        #expect(r.citations.map(\.filename) == ["a.mov"])
        #expect(r.basisLine.hasPrefix("Basis: 'my dad' = Richard Breen, father of Rick Breen in the People tab relationships; "), Comment(rawValue: r.basisLine))
        #expect(!r.basisLine.contains("setting aside keywords"), Comment(rawValue: r.basisLine))
    }

    @Test func treeOnlyKinshipRebindsThePersonButKeepsTheKinWord() async throws {
        // As it IS (2026-10-25): the GEDCOM path binds "my dad" but does not
        // mark the kin phrase as spent, so a translator keyword "dad" stays a
        // content term and the composer relaxes it.
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Rick /Breen/
        1 SEX M
        1 FAMC @F1@
        0 @I2@ INDI
        1 NAME Richard /Breen/
        1 SEX M
        1 FAMS @F1@
        0 @F1@ FAM
        1 HUSB @I2@
        1 CHIL @I1@
        0 TRLR
        """)
        let context = Exec.Context(
            presenceRecords: [tagged("/Volumes/X/a.mov", "Richard Breen"), tagged("/Volumes/X/b.mov", "Donna")],
            profiles: [],
            graph: graph,
            speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie"))
        let bare = try await ask("show me videos of my dad", .init(people: ["my dad"]), context: context)
        #expect(bare.outcome == .answered, Comment(rawValue: bare.prose + " | " + bare.basisLine))
        #expect(bare.citations.map(\.filename) == ["a.mov"])
        #expect(bare.basisLine.hasPrefix("Basis: 'my dad' = Richard Breen, father of Rick Breen in the family tree; "), Comment(rawValue: bare.basisLine))

        let withWord = try await ask("show me videos of my dad", .init(people: ["my dad"], keywords: ["dad"]), context: context)
        #expect(withWord.outcome == .declined)
        #expect(withWord.prose == "I don't see “dad” mentioned anywhere, but I have 1 video of Richard Breen — want those?")
        #expect(withWord.basisLine == "Basis: 'my dad' = Richard Breen, father of Rick Breen in the family tree; no evidence for the full request; 1 cited of 1 after setting aside keywords.")
    }

    // MARK: Pronouns, topic words, unknown names, place facet

    @Test func speakerPronounsAreDroppedWithOneNote() async throws {
        let context = Exec.Context(
            presenceRecords: [tagged("/Volumes/X/Media/home.mov", "Donna")],
            profiles: [donnaProfile()])
        let r = try await ask("show me something of my videos",
                              .init(people: ["Donna"], keywords: ["my", "me"]), context: context)
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.citations.map(\.filename) == ["home.mov"])
        #expect(r.basisLine.hasPrefix("Basis: “my”, “me” means you or me, not a search word, so I left it out; "), Comment(rawValue: r.basisLine))
    }

    @Test func topicWordInThePeopleSlotIsSearchedAsAWord() async throws {
        let context = Exec.Context(
            presenceRecords: [
                tagged("/Volumes/X/Cape/beach.mov", "Donna"),
                tagged("/Volumes/X/Home/kitchen.mov", "Donna"),
            ],
            profiles: [donnaProfile()])
        let r = try await ask("find donna down the cape", .init(people: ["Donna", "cape"]), context: context)
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.citations.map(\.filename) == ["beach.mov"])
        #expect(r.basisLine.contains("“cape” is a place or occasion, not a person, so I searched it as a word"), Comment(rawValue: r.basisLine))
    }

    @Test func droppedTopicWordIsRestoredOnAFreshTranslationOnly() async throws {
        let context = Exec.Context(
            presenceRecords: [
                tagged("/Volumes/X/Christmas2006/tree.mov", "Donna", inferred: date(2006, 12, 25)),
                tagged("/Volumes/X/Summer2006/beach.mov", "Donna", inferred: date(2006, 7, 4)),
            ],
            profiles: [donnaProfile()])
        let fresh = try await ask("Christmas videos from 2006", .init(yearStart: 2006, yearEnd: 2006), context: context)
        #expect(fresh.outcome == .answered, Comment(rawValue: fresh.prose))
        #expect(fresh.citations.map(\.filename) == ["tree.mov"])
        #expect(fresh.basisLine.contains("is in the question but the translator left it out, so I searched for it too"), Comment(rawValue: fresh.basisLine))

        // A paging re-run carries the previous AST on purpose: nothing restored.
        let paged = try await ask("Christmas videos from 2006", .init(yearStart: 2006, yearEnd: 2006),
                                  context: context, citationOffset: 1)
        #expect(!paged.basisLine.contains("translator left it out"), Comment(rawValue: paged.basisLine))
    }

    @Test func unknownNameIsDemotedToAWordAndSaysSo() async throws {
        let context = Exec.Context(
            presenceRecords: [
                tagged("/Volumes/X/Franklin/parade.mov", "Donna"),
                tagged("/Volumes/X/Cape/beach.mov", "Donna"),
            ],
            profiles: [donnaProfile()])
        let r = try await ask("pull up anything from Franklin", .init(people: ["Franklin"]), context: context)
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.citations.map(\.filename) == ["parade.mov"])
        #expect(r.basisLine.hasPrefix("Basis: “Franklin” isn't a person I know, so I searched it as a place or word; "), Comment(rawValue: r.basisLine))
    }

    @Test func unknownNameStaysAPersonWhenThereIsNothingToKnowPeopleFrom() async throws {
        // No profiles read, no tree, no CyberBrain, no records: "unknown" is
        // meaningless, so the name is kept as a person and the miss says so.
        let context = Exec.Context(presenceRecords: [], profiles: nil)
        let r = try await ask("pull up anything from Franklin", .init(people: ["Franklin"]), context: context)
        #expect(r.outcome == .declined)
        #expect(r.prose.hasPrefix("I don't have any videos tagged with Franklin yet."), Comment(rawValue: r.prose))
        #expect(!r.basisLine.contains("isn't a person I know"))
    }

    private func franklinTree() -> GedcomFamilyGraph {
        GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Benjamin /Franklin/
        1 SEX M
        1 BIRT
        2 DATE 1706
        0 @I2@ INDI
        1 NAME Robert /Goushill/
        1 SEX M
        0 TRLR
        """)
    }

    @Test func treeKnownUntaggedNameFallsBackToWordsWhenTheWordSearchHits() async throws {
        let context = Exec.Context(
            presenceRecords: [
                tagged("/Volumes/X/Franklin/Franklin_1990_p216.mkv", "Donna"),
                tagged("/Volumes/X/Cape/beach.mov", "Donna"),
            ],
            profiles: [donnaProfile()],
            graph: franklinTree())
        let r = try await ask("pull up anything from Franklin", .init(people: ["Franklin"]), context: context)
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.citations.map(\.filename) == ["Franklin_1990_p216.mkv"])
        #expect(r.basisLine.hasPrefix("Basis: no one in the catalog is tagged “Franklin”, so I searched it as a place or word; "), Comment(rawValue: r.basisLine))
        // The executed query the retry would re-run is the WORD form.
        #expect(r.retryOffer == nil)
    }

    @Test func bothSearchesEmptyKeepTheHonestDecline() async throws {
        let context = Exec.Context(
            presenceRecords: [tagged("/Volumes/X/Cape/beach.mov", "Donna")],
            profiles: [donnaProfile()],
            graph: franklinTree())
        let r = try await ask("pull up anything from Goushill", .init(people: ["Goushill"]), context: context)
        #expect(r.outcome == .declined)
        #expect(r.prose.hasPrefix("I don't have any videos tagged with Goushill yet."), Comment(rawValue: r.prose))
        #expect(!r.basisLine.contains("searched it as a place or word"))
        #expect(r.matchCount == 0)
    }

    @Test func fallbackNeverRunsWithAKeywordOrOnAPage() async throws {
        let context = Exec.Context(
            presenceRecords: [tagged("/Volumes/X/Franklin/parade.mov", "Donna")],
            profiles: [donnaProfile()],
            graph: franklinTree())
        let withWord = try await ask("Franklin parade", .init(people: ["Franklin"], keywords: ["parade"]), context: context)
        #expect(withWord.outcome == .declined)
        #expect(!withWord.basisLine.contains("no one in the catalog is tagged"))

        let paged = try await ask("pull up anything from Franklin", .init(people: ["Franklin"]),
                                  context: context, citationOffset: 25)
        #expect(paged.outcome == .declined)
        #expect(!paged.basisLine.contains("no one in the catalog is tagged"))
    }

    @Test func ricksOwnPlaceBecomesTheExactPlaceFacet() async throws {
        let context = Exec.Context(
            presenceRecords: [
                tagged("/Volumes/X/a.mov", "Donna", place: "Cape Cod"),
                tagged("/Volumes/X/cape cod talk.mov", "Donna"),
            ],
            profiles: [donnaProfile()])
        let r = try await ask("videos of Donna at Cape Cod",
                              .init(people: ["Donna"], keywords: ["cape cod"]), context: context)
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.citations.map(\.filename) == ["a.mov"])
        #expect(r.basisLine.contains("“Cape Cod” is one of your places, so I matched the Place field exactly (not words in transcripts or file names)"), Comment(rawValue: r.basisLine))
    }

    // MARK: Age phrase → birth-year band

    @Test func agePhraseBecomesAYearBandFromTheProfileBirthYear() async throws {
        let context = Exec.Context(
            presenceRecords: [
                tagged("/Volumes/X/a.mov", "Donna", inferred: date(1961)),
                tagged("/Volumes/X/b.mov", "Donna", inferred: date(1990)),
            ],
            profiles: [donnaProfile(birthdate: date(1960, 3, 4))])
        let r = try await ask("show me Donna as a baby", .init(people: ["Donna"], keywords: ["baby"]), context: context)
        #expect(r.outcome == .answered, Comment(rawValue: r.prose + " | " + r.basisLine))
        #expect(r.citations.map(\.filename) == ["a.mov"])
        #expect(r.basisLine.contains("using Donna's birth year 1960 from the People profile (“baby” = 1960–1962)"), Comment(rawValue: r.basisLine))
    }

    @Test func agePhraseWithoutABirthYearIsSearchedAsAWord() async throws {
        let context = Exec.Context(
            presenceRecords: [tagged("/Volumes/X/a.mov", "Donna", inferred: date(1961))],
            profiles: [donnaProfile()])
        let r = try await ask("show me Donna as a baby", .init(people: ["Donna"], keywords: ["baby"]), context: context)
        #expect(r.outcome == .declined, Comment(rawValue: r.prose))
        #expect(r.basisLine.contains("I don't know Donna's birth year, so “baby” was searched as a word"), Comment(rawValue: r.basisLine))
    }

    @Test func anExplicitYearWinsOverTheAgePhrase() async throws {
        let context = Exec.Context(
            presenceRecords: [tagged("/Volumes/X/a.mov", "Donna", inferred: date(1961))],
            profiles: [donnaProfile(birthdate: date(1960, 3, 4))])
        let r = try await ask("Donna as a baby in 1990",
                              .init(people: ["Donna"], yearStart: 1990, yearEnd: 1990, keywords: ["baby"]), context: context)
        #expect(!r.basisLine.contains("birth year"), Comment(rawValue: r.basisLine))
    }

    // MARK: Answer shapes: count, paging, refinement, ordered

    @Test func countOnlyPhrasesTheNumberAndCitesAtMostFive() async throws {
        let records = (1...7).map { tagged("/Volumes/X/\($0).mov", "Donna") }
        let context = Exec.Context(presenceRecords: records, profiles: [donnaProfile()])
        let many = try await ask("how many of Donna", .init(people: ["Donna"]), context: context, countOnly: true)
        #expect(many.prose == "7 catalog items.")
        #expect(many.citations.count == 5)
        #expect(many.matchCount == 7)
        #expect(many.answerPlan != nil)

        let one = try await ask("and the 90s?", .init(people: ["Donna"]), context:
            Exec.Context(presenceRecords: [records[0]], profiles: [donnaProfile()]),
            refinementChange: "from the 90s", countOnly: true)
        #expect(one.prose == "1 catalog item from the 90s.")

        let none = try await ask("and the 80s?", .init(people: ["Donna"], keywords: ["zzz"]), context: context,
                                 refinementChange: "from the 80s", countOnly: true)
        #expect(none.prose == "Nothing from the 80s.")
        #expect(none.outcome == .declined)
    }

    @Test func pagingSaysHereAreMoreOrThatIsAll() async throws {
        let records = (1...30).map { tagged("/Volumes/X/\($0).mov", "Donna") }
        let context = Exec.Context(presenceRecords: records, profiles: [donnaProfile()])
        let more = try await ask("show more", .init(people: ["Donna"]), context: context, citationOffset: 25)
        #expect(more.prose == "Here are 5 more (items 26–30 of 30).")
        #expect(more.citations.count == 5)
        #expect(more.matchCount == 30)

        let done = try await ask("show more", .init(people: ["Donna"]), context: context, citationOffset: 30)
        #expect(done.prose == "That's all of them — I've already shown all 30.")
        #expect(done.outcome == .answered)
        #expect(done.citations.isEmpty)
    }

    @Test func refinedTurnLeadsWithTheChangeAndOffersNoRetry() async throws {
        let context = Exec.Context(
            presenceRecords: [tagged("/Volumes/X/Westford/a.mov", "Donna")],
            profiles: [donnaProfile()])
        let hit = try await ask("in Westford", .init(people: ["Donna"], keywords: ["westford"]), context: context,
                                refinementNote: "refining: donna · westford", refinementChange: "Narrowed to Westford")
        #expect(hit.prose == "Narrowed to Westford — 1 catalog item.")
        #expect(hit.basisLine.hasPrefix("Basis: refining: donna · westford; "), Comment(rawValue: hit.basisLine))

        let miss = try await ask("in Boston", .init(people: ["Donna"], keywords: ["boston"]), context: context,
                                 refinementNote: "refining: donna · boston", refinementChange: "Narrowed to Boston")
        #expect(miss.prose == "Narrowed to Boston — nothing matched. I didn't find a match for that in the archive. Try removing a name, place, or year, and I'll look again.")
        #expect(miss.outcome == .declined)
        #expect(miss.retryOffer == nil, "a refinement's 'nothing matched' offers nothing")
    }

    @Test func basisPrefixIsRefinementNoteThenNotesInOrder() async throws {
        let context = Exec.Context(
            presenceRecords: [tagged("/Volumes/X/Media/home.mov", "Donna")],
            profiles: [donnaProfile()])
        let r = try await ask("show me my videos of Donna", .init(people: ["Donna"], keywords: ["my"]),
                              context: context, refinementNote: "refining: donna")
        #expect(r.basisLine.hasPrefix("Basis: refining: donna; “my” means you or me, not a search word, so I left it out; 1 cited of 1 matching catalog items."),
                Comment(rawValue: r.basisLine))
    }

    @Test func orderedRequestTakesTheDateOrderedPathWithRecoveredNames() async throws {
        let context = Exec.Context(
            presenceRecords: [
                tagged("/Volumes/X/old.mov", "Donna", resolved: date(1990)),
                tagged("/Volumes/X/new.mov", "Donna", resolved: date(2005)),
            ],
            profiles: [donnaProfile()])
        let ast = ArchivistQueryAST.presence(.init(people: ["Dona"]))
        let r = try await ask("and the newest?", .init(people: ["Dona"]), context: context,
                              order: .init(order: .newest, ordinal: 1, scope: .list(ast, anyOfPeople: false)))
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.hasPrefix("The newest of "), Comment(rawValue: r.prose))
        #expect(r.prose.contains("new.mov"), Comment(rawValue: r.prose))
        #expect(r.citations.first?.filename == "new.mov")
        #expect(r.basisLine.contains("spelling recovery “Dona” → People profile “Donna”"), Comment(rawValue: r.basisLine))
    }
}
