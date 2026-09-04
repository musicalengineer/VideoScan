import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - The relax-and-explain sentence
//
// Rick, 2026-09-03, from the graded eval
// (~/Library/Logs/VideoScan/hallie-eval/interim-20260902-2205.graded.jsonl,
// grader flag ~relaxed_offer, 8 occurrences): Hallie's most common "I partly
// found something" sentence read like a failure and hid a good answer.
//
//   "Nothing matches all of that. Setting aside that wording, I do have
//    148 items. Want those?"
//
// Three defects: it LED with failure while about to offer something good;
// "that wording" never said WHICH constraint was let go, so the listener
// could not tell whether Christmas, the year, or a person was dropped; and
// "items" is inventory-speak for a family's home movies.
//
// Every sensor below is one of the eight flagged questions, rebuilt from
// SYNTHETIC records (no real catalog, no UserDefaults, no network) at the
// facet shape the eval produced. They pin the WORDING only — the matching,
// the ladder order, the near-miss thresholds and the offered record set are
// unchanged and are pinned separately by HalliePresenceRelaxTests.

@Suite("Hallie relaxed offer — wording names what it dropped")
struct HallieRelaxedOfferWordingTests {
    private let confirmedAt = Date(timeIntervalSince1970: 1_700_000_000)

    /// A record with a provable path year and optional confirmed tags. The
    /// file name deliberately carries no searchable word, so a dropped
    /// keyword genuinely matches nothing.
    private func rec(year: Int, _ index: Int, people: [String] = [])
        -> ArchivistPresenceRecordSnapshot {
        ArchivistPresenceRecordSnapshot(
            fullPath: "/v/\(year)/clip-\(String(format: "%04d", index)).mov",
            confirmedPeople: people.map { ConfirmedTag(name: $0, confirmedAt: confirmedAt) })
    }

    private func query(
        people: [String] = [], yearStart: Int? = nil, yearEnd: Int? = nil,
        mediaKind: ArchivistQueryAST.MediaKind? = nil, keywords: [String] = []
    ) -> ArchivistPresenceQuery {
        ArchivistPresenceQuery(.init(
            people: people.isEmpty ? nil : people,
            yearStart: yearStart, yearEnd: yearEnd, mediaKind: mediaKind,
            keywords: keywords.isEmpty ? nil : keywords))
    }

    private func offer(
        _ q: ArchivistPresenceQuery,
        records: [ArchivistPresenceRecordSnapshot],
        dropped: RelaxedFacet,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> ArchivistFactualAnswer {
        let result = ArchivistPresenceExecutor.execute(q, records: records)
        #expect(result.conclusion == .noEvidenceButRelaxed(dropped: dropped),
                "the ladder must still relax the same facet",
                sourceLocation: sourceLocation)
        return ArchivistPresenceAnswerComposer.compose(result)
    }

    // MARK: The eight flagged questions

    /// catalog_search/cs031 — the worst one. "find the videos from Christmas
    /// 1991": 148 videos from 1991 is a fine answer, and the old sentence
    /// buried it behind "Nothing matches all of that."
    @Test func cs031_christmas1991_namesChristmasAndLeadsWith1991() {
        // 148 matching 1991 records inside a 600-record corpus keeps the
        // near-miss share rule satisfied (148 * 4 < 600), so the ladder
        // still makes the same offer it made in the eval.
        var records = (0..<148).map { rec(year: 1991, $0) }
        records += (0..<452).map { rec(year: 1975, $0) }
        let answer = offer(
            query(yearStart: 1991, yearEnd: 1991, keywords: ["Christmas"]),
            records: records, dropped: .keywords)

        #expect(answer.prose == "I don't see “Christmas” mentioned anywhere, "
                + "but I have 148 videos from 1991 — want those?")
    }

    /// conjunction/cj011 — "show me Donna and the boys at Christmas".
    /// Person resolution is somebody else's business; this pins that the
    /// people who survived are the ones the offer is described by.
    @Test func cj011_donnaAndTheBoys_namesChristmasAndKeepsEveryPerson() {
        var records = (0..<44).map {
            rec(year: 1994, $0, people: ["Donna", "Tim", "Matt"])
        }
        records += (0..<156).map { rec(year: 1975, $0) }
        let answer = offer(
            query(people: ["Donna", "Tim", "Matt"], keywords: ["Christmas"]),
            records: records, dropped: .keywords)

        #expect(answer.prose == "I don't see “Christmas” mentioned anywhere, "
                + "but I have 44 videos of Donna, Tim, and Matt — want those?")
    }

    /// catalog_search/cs011 — "show me Timmy as a baby". The one variant
    /// that was already half-right ("Setting aside the years you asked
    /// for") now says WHICH years.
    @Test func cs011_timmyAsABaby_namesTheActualYearsNotTheYearsYouAskedFor() {
        let records = (0..<2).map { rec(year: 2001, $0, people: ["Timmy"]) }
        let answer = offer(
            query(people: ["Timmy"], yearStart: 1985, yearEnd: 1986),
            records: records, dropped: .years)

        #expect(answer.prose == "I don't see anything from 1985–1986, "
                + "but I have 2 videos of Timmy — want those?")
    }

    /// catalog_search/cs012 — "I want to see Matt's graduation".
    @Test func cs012_mattsGraduation_namesGraduation() {
        let records = (0..<3).map { rec(year: 2004, $0, people: ["Matt"]) }
        let answer = offer(
            query(people: ["Matt"], keywords: ["graduation"]),
            records: records, dropped: .keywords)

        #expect(answer.prose == "I don't see “graduation” mentioned anywhere, "
                + "but I have 3 videos of Matt — want those?")
    }

    /// catalog_search/cs034 — "do we have any video of my father talking
    /// about typewriters". Rick's dad repaired typewriters; the word is the
    /// whole point of the question, so naming it is the honest answer.
    @Test func cs034_fatherAndTypewriters_namesTypewriters() {
        let records = (0..<6).map { rec(year: 1988, $0, people: ["Richard Breen"]) }
        let answer = offer(
            query(people: ["Richard Breen"], keywords: ["typewriters"]),
            records: records, dropped: .keywords)

        #expect(answer.prose == "I don't see “typewriters” mentioned anywhere, "
                + "but I have 6 videos of Richard Breen — want those?")
    }

    /// biography/bi008 — "who was my father as a young man".
    @Test func bi008_fatherAsAYoungMan_namesThePhraseItDropped() {
        let records = (0..<6).map { rec(year: 1988, $0, people: ["Richard Breen"]) }
        let answer = offer(
            query(people: ["Richard Breen"], keywords: ["young man"]),
            records: records, dropped: .keywords)

        #expect(answer.prose == "I don't see “young man” mentioned anywhere, "
                + "but I have 6 videos of Richard Breen — want those?")
    }

    /// live/lv260901-022 — "find matt in the home view catalog".
    @Test func lv260901_022_findMattInTheHomeViewCatalog_namesTheDroppedWords() {
        let records = (0..<3).map { rec(year: 2004, $0, people: ["Matt"]) }
        let answer = offer(
            query(people: ["Matt"], keywords: ["home view"]),
            records: records, dropped: .keywords)

        #expect(answer.prose == "I don't see “home view” mentioned anywhere, "
                + "but I have 3 videos of Matt — want those?")
    }

    /// catalog_search/cs027 — "i want to see the boys when they were
    /// little". THE NEGATIVE CASE. It carried the same grader flag, but it
    /// is a different code path: nothing matched at ANY relaxation, so
    /// there is nothing to offer. A genuinely empty result must still say
    /// so plainly and must NOT manufacture an offer.
    @Test func cs027_nothingAtAnyRelaxation_saysSoPlainlyAndOffersNothing() {
        let records = (0..<10).map { rec(year: 1994, $0, people: ["Donna"]) }
        let result = ArchivistPresenceExecutor.execute(
            query(people: ["boys"], keywords: ["when they were little"]),
            records: records)
        #expect(result.conclusion == .noEvidence)
        let answer = ArchivistPresenceAnswerComposer.compose(result)

        // Byte-for-byte the sentence this path produced before the wording
        // change: the decline was never the bug.
        #expect(answer.prose == "I looked for videos of boys with “when they "
                + "were little” and found nothing in the catalog. Want me to "
                + "try without the words, or with a different name?")
        #expect(!answer.prose.contains("want those?"))
        #expect(!answer.prose.contains("but I have"))
        #expect(result.evidence.citations.isEmpty)
        #expect(result.evidence.totalMatchCount == 0)
    }

    // MARK: Shape sensors

    /// The three retired defects, checked across every facet the ladder can
    /// drop. This is the regression sensor: if any of these strings comes
    /// back, the demo sentence has regressed.
    @Test(arguments: [RelaxedFacet.years, .keywords, .mediaKind])
    func noRelaxedOfferEverSaysNothingMatchesOrItems(_ facet: RelaxedFacet) {
        let facets = ArchivistPresenceAnswerComposer.ParsedFacets(
            people: ["Donna"], years: "1991", mediaKind: "photo",
            keywords: ["Christmas"])
        let prose = ArchivistPresenceAnswerComposer.relaxedOfferProse(
            dropped: facet, facets: facets, count: 12)

        #expect(!prose.contains("Nothing matches all of that"))
        #expect(!prose.contains("Setting aside"))
        #expect(!prose.contains("that wording"))
        #expect(!prose.lowercased().contains(" items"))
        #expect(!prose.lowercased().contains(" item."))
        // Leads with the miss stated SPECIFICALLY, then what exists.
        #expect(prose.hasPrefix("I don't see "))
        #expect(prose.contains(", but I have "))
        #expect(prose.hasSuffix(" — want those?"))
        // One or two sentences: she is spoken aloud.
        #expect(!prose.dropLast().contains("."))
    }

    /// The dropped facet's own value appears; a facet that SURVIVED is
    /// never described as missing.
    @Test func eachFacetIsNamedByItsOwnValue() {
        let facets = ArchivistPresenceAnswerComposer.ParsedFacets(
            people: ["Donna"], years: "1990–1994", mediaKind: "photo",
            keywords: ["Christmas", "beach"])

        let years = ArchivistPresenceAnswerComposer.relaxedOfferProse(
            dropped: .years, facets: facets, count: 5)
        #expect(years == "I don't see anything from 1990–1994, but I have "
                + "5 photos of Donna with “Christmas” and “beach” — want those?")

        let keywords = ArchivistPresenceAnswerComposer.relaxedOfferProse(
            dropped: .keywords, facets: facets, count: 5)
        #expect(keywords == "I don't see “Christmas” or “beach” mentioned "
                + "anywhere, but I have 5 photos of Donna from 1990–1994 — want those?")

        // A dropped media kind means the offer is deliberately mixed, so it
        // cannot be called videos or photos.
        let kind = ArchivistPresenceAnswerComposer.relaxedOfferProse(
            dropped: .mediaKind, facets: facets, count: 5)
        #expect(kind == "I don't see any photos, but I have 5 files of Donna "
                + "from 1990–1994 with “Christmas” and “beach” — want those?")
    }

    /// One match is singular, and still a video rather than an item.
    @Test func aSingleOfferedMatchIsOneVideo() {
        let records = [rec(year: 2001, 0, people: ["Donna"])]
        let answer = offer(
            query(people: ["Donna"], yearStart: 1990, yearEnd: 1994),
            records: records, dropped: .years)
        #expect(answer.prose == "I don't see anything from 1990–1994, "
                + "but I have 1 video of Donna — want those?")
    }

    /// The basis line is the audit trail; it still names the dropped facet
    /// in machine terms and still says the full request was not met.
    @Test func theBasisLineStillRecordsWhatWasSetAside() {
        let records = (0..<2).map { rec(year: 2001, $0, people: ["Donna"]) }
        let answer = offer(
            query(people: ["Donna"], yearStart: 1990, yearEnd: 1994),
            records: records, dropped: .years)
        #expect(answer.basisLine == "Basis: no evidence for the full request; "
                + "2 cited of 2 after setting aside years.")
    }

    // MARK: Matching is untouched

    /// The wording change must not move a single record. Same query, same
    /// corpus: the conclusion, the exact count, and the cited paths in
    /// order are the values the pre-change executor produced.
    @Test func theOfferedRecordSetIsUnchangedByTheWording() {
        let records = [
            rec(year: 2001, 0, people: ["Donna"]),
            rec(year: 2003, 1, people: ["Donna"]),
            rec(year: 1992, 2, people: ["Rick"]),
        ]
        let result = ArchivistPresenceExecutor.execute(
            query(people: ["Donna"], yearStart: 1990, yearEnd: 1994),
            records: records)

        #expect(result.conclusion == .noEvidenceButRelaxed(dropped: .years))
        #expect(result.evidence.totalMatchCount == 2)
        #expect(result.evidence.citations.map(\.fullPath)
                == ["/v/2001/clip-0000.mov", "/v/2003/clip-0001.mov"])
        #expect(result.evidence.isCitationListTruncated == false)
        #expect(result.interpretedQuery == "shape=presence person=Donna years=1990...1994")
    }

    // MARK: The offer stays a real offer

    /// The offered items are what an affirmative acts on. Wording is not
    /// part of that contract — nothing keys off "want those?" — so this
    /// pins the acceptance path itself.
    @Test func anAffirmativeAcceptsTheOfferedItems() {
        let records = (0..<3).map { rec(year: 2001, $0, people: ["Donna"]) }
        let result = ArchivistPresenceExecutor.execute(
            query(people: ["Donna"], yearStart: 1990, yearEnd: 1994),
            records: records)
        let offered = result.evidence.citations
        #expect(offered.count == 3)

        let snapshot = ArchivistFollowUpResolver.Snapshot(
            ast: .presence(.init(people: ["Donna"], yearStart: 1990, yearEnd: 1994)),
            items: offered.map {
                ArchivistFollowUpResolver.Snapshot.Item(
                    filename: $0.filename, fullPath: $0.fullPath, years: [])
            },
            shownCount: offered.count,
            totalMatchCount: result.evidence.totalMatchCount)

        for reply in ["yes, show those", "yes please show them", "show those"] {
            let resolution = ArchivistFollowUpResolver.resolve(
                reply, snapshot: snapshot, isKnownPerson: { _ in false })
            #expect(resolution == .mediaAction(verb: .show, indices: [0, 1, 2]),
                    Comment(rawValue: "“\(reply)” did not accept the offer"))
        }
    }

    /// PRODUCTION PATH. A relaxed offer is reported as `.declined`, and
    /// conversation memory drops the result set of a declined presence
    /// turn — so the items Hallie just offered are not there for the next
    /// turn to act on.
    ///
    /// This sensor records the state as it is on 2026-09-03 rather than
    /// asserting a fix: repairing it changes turn behaviour, which is a
    /// separate dispatch from this wording change. If someone later makes
    /// the offer acceptable, THIS TEST WILL FAIL and should be rewritten to
    /// expect the offered items — that failure is the intended signal.
    @Test func offeredItemsDoNotSurviveIntoConversationMemoryToday() {
        let records = (0..<3).map { rec(year: 2001, $0, people: ["Donna"]) }
        let result = ArchivistPresenceExecutor.execute(
            query(people: ["Donna"], yearStart: 1990, yearEnd: 1994),
            records: records)
        let answer = ArchivistPresenceAnswerComposer.compose(result)
        #expect(result.conclusion == .noEvidenceButRelaxed(dropped: .years))

        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "show me Donna down the cape in the early 90s",
            ast: .presence(.init(people: ["Donna"], yearStart: 1990, yearEnd: 1994)))
        let turn = HallieTurnExecutor.Result(
            route: .presence,
            outcome: .declined,
            prose: answer.prose,
            basisLine: answer.basisLine,
            queryDescription: result.interpretedQuery,
            citations: result.evidence.citations.map {
                HallieTurnExecutor.Citation(
                    recordID: $0.recordID, fullPath: $0.fullPath,
                    filename: $0.filename, playbackSeconds: nil, bases: $0.bases)
            },
            catalogPersonName: nil,
            matchCount: 0)

        var memory = HallieTurnExecutor.ConversationMemory()
        memory.record(intent: intent, result: turn)
        #expect(memory.followUpSnapshot?.items.isEmpty == true,
                Comment(rawValue: "if this now carries the offered items, "
                        + "the offer became acceptable — update this sensor "
                        + "to expect 3 items"))
    }
}
