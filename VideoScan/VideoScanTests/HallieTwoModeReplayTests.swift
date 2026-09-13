// HallieTwoModeReplayTests.swift
// Sensor suite for docs/hallie_two_mode_design.md §2 — the seven observed
// misroutes that motivate the Catalog / Family-tree session mode. Written
// FIRST (step 0) to pin what the deterministic chain does TODAY, so the
// later steps flip each expectation in a visible diff rather than by
// silent drift. Pure fixture: no model, no disk. The translator is stood
// in for by the AST the real model returned in the graded replay
// (advisory artifact, 2026-09-13).
//
// Reading guide for each case: "TODAY" = the misroute this test pins at
// step 0; "AFTER" = what the mode design says the same turn must do once
// steps 1–4 land. When a case's "AFTER" arrives, the assertion is edited
// here and the commit shows the flip.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let tree = """
0 HEAD
0 @I1@ INDI
1 NAME John /Hastings/
1 SEX M
1 BIRT
2 DATE 11 OCT 1372
2 PLAC Kenilworth, Warwickshire, England
1 DEAT
2 DATE 30 DEC 1389
1 FAMS @F1@
0 @I2@ INDI
1 NAME Philippa /Mortimer/
1 SEX F
1 BIRT
2 DATE 1375
1 FAMS @F1@
0 @F1@ FAM
1 HUSB @I1@
1 WIFE @I2@
1 MARR
2 DATE 1385
0 @I6@ INDI
1 NAME Edward III /Plantagenet/
1 SEX M
1 BIRT
2 DATE 13 NOV 1312
2 PLAC Windsor Castle, Berkshire, England
1 DEAT
2 DATE 21 JUN 1377
0 @I7@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 BIRT
2 DATE 1959
0 TRLR
"""

@Suite("Two-mode replay sensors (design §2)")
struct HallieTwoModeReplayTests {
    typealias Exec = HallieTurnExecutor
    private let graph = GedcomFamilyGraph(gedcomText: tree)
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Fixture

    private func record(_ path: String, people: [String]) -> ArchivistPresenceRecordSnapshot {
        ArchivistPresenceRecordSnapshot(
            fullPath: path,
            directory: (path as NSString).deletingLastPathComponent,
            volumeName: "Fixture",
            inferredDate: nil,
            confirmedPeople: people.map { ConfirmedTag(name: $0, confirmedAt: stamp) },
            transcript: nil)
    }

    /// 6 videos in the 80s, 8 in the 90s, 4 in the 2000s — decades are
    /// distinguishable by count so a REPLACED year filter is visible.
    private func catalogRecords() -> [ArchivistPresenceRecordSnapshot] {
        (0..<6).map { record("/Fixture/198\($0)/donna_80s_\($0).mov", people: ["Donna"]) }
            + (0..<8).map { record("/Fixture/199\($0)/donna_90s_\($0).mov", people: ["Donna"]) }
            + (0..<4).map { record("/Fixture/200\($0)/donna_00s_\($0).mov", people: ["Donna"]) }
    }

    private var stats: HallieCatalogStats {
        HallieCatalogStats(fileCount: 18, uniqueFileCount: 18, grossBytes: 0, uniqueBytes: 0,
                           duplicateFiles: 0, duplicateBytes: 0, volumeCount: 1,
                           archivedVerified: 0, archivedUnverified: 0,
                           totalDurationSeconds: 0, earliestYear: 1980, latestYear: 2003)
    }

    private var context: Exec.Context {
        .init(presenceRecords: catalogRecords(), profiles: [], graph: graph,
              speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
    }

    private func pre(_ q: String, memory: Exec.ConversationMemory = .init(),
                     catalogStats: HallieCatalogStats? = nil) -> Exec.PreTranslation {
        let context = self.context
        return Exec.preTranslation(
            question: q, playAfterAnswer: false, memory: memory,
            isKnownPerson: { Exec.isKnownPerson($0, context: context) },
            catalogStats: catalogStats,
            lineageAnswer: { HallieLineageAnswer.answer($0, context: context) },
            identity: Exec.nameIdentity { context })
    }

    /// One turn end to end: pre-translation, then the stand-in translator
    /// (`translated`) when the chain asked for one, then execution and
    /// memory. Mirrors HallieConversationMemoryTests.run.
    private func run(
        _ text: String,
        memory: inout Exec.ConversationMemory,
        translated: ArchivistQueryAST? = nil,
        catalogStats: HallieCatalogStats? = nil
    ) async throws -> Exec.Result {
        let context = self.context
        switch pre(text, memory: memory, catalogStats: catalogStats) {
        case .translate(let question, let play):
            let ast = try #require(translated, "\(text): unexpectedly needed translation")
            let intent = Exec.Intent(originalQuestion: text, ast: ast, playAfterAnswer: play)
            _ = question
            let result = try await Exec.execute(.init(intent: intent), context: context)
            memory.record(intent: intent, result: result)
            return result
        case .run(let intent):
            #expect(translated == nil, "\(text): resolved locally but a translation was supplied")
            let result = try await Exec.execute(.init(intent: intent), context: context)
            memory.record(intent: intent, result: result)
            return result
        case .answer(let result):
            #expect(translated == nil, "\(text): answered locally but a translation was supplied")
            memory.record(intent: nil, result: result, question: text)
            return result
        }
    }

    private func memoryAfterBiography(of typed: String, expecting name: String) async throws -> Exec.ConversationMemory {
        let intent = Exec.Intent(
            originalQuestion: "tell me about \(typed)",
            ast: .graph(.init(people: [typed], operation: .biography)))
        let answered = try await Exec.execute(.init(intent: intent), context: context)
        #expect(answered.outcome == .answered, Comment(rawValue: answered.prose))
        #expect(answered.catalogPersonName == name)
        var memory = Exec.ConversationMemory()
        memory.record(intent: intent, result: answered)
        return memory
    }

    // MARK: 1. strict-005 residue — an "about X" whose X the tree rejects

    /// TODAY: no lane claims "tell me all about <unknown>", so the sentence
    /// goes to the translator and becomes a catalog search for "all about".
    /// AFTER: the explicit tree cue ("tell me all about") puts the turn in
    /// tree mode, where an unresolved biography subject is an honest "not
    /// in the tree" decline — never a search.
    @Test func tellMeAllAboutSomebodyNotInTheTreeGoesToTheTranslator() {
        let q = "tell me all about Zebulon Nobody"
        #expect(pre(q) == .translate(question: q, playAfterAnswer: false))
    }

    // MARK: 2. strict-004 / -015 residue — the pronoun rewrite is mode-blind

    /// TODAY: "what did he do for a living" after John Hastings' biography
    /// is rewritten to his name and translated; when the model answers
    /// with a presence AST the executor runs the catalog search as-is and
    /// the kin/occupation words become keywords.
    /// AFTER: the sticky tree mode reconciles a presence AST for a tree
    /// question into a graph biography (or declines) — no keyword search.
    @Test func translatorPresenceAfterABiographyRunsAsACatalogSearch() async throws {
        var memory = try await memoryAfterBiography(of: "john hastings", expecting: "John Hastings")
        let q = "what did he do for a living?"
        #expect(pre(q, memory: memory)
                == .translate(question: "what did John Hastings do for a living?", playAfterAnswer: false))
        let result = try await run(
            q, memory: &memory,
            translated: .presence(.init(people: ["john hastings"], keywords: ["living"])))
        #expect(result.route == .presence, Comment(rawValue: result.prose))
        #expect(result.queryDescription?.contains("keyword=") == true,
                Comment(rawValue: result.queryDescription ?? "nil"))
    }

    // MARK: 3. cs030 — "play the longest video in the archive"

    /// TODAY: no catalog superlative exists; the media resolver reads
    /// "archive" as content, hands the remainder to the translator with a
    /// play intent, and the model's `aggregate anchorPeople:["archive"]`
    /// dead-ends on the aggregate decline.
    /// AFTER (step 5, out of this branch's scope): a local duration
    /// superlative. Steps 1–4 only guarantee mode = catalog for the turn.
    @Test func playTheLongestVideoInTheArchiveDeadEndsOnAggregate() async throws {
        var memory = Exec.ConversationMemory()
        let q = "play the longest video in the archive"
        #expect(pre(q) == .translate(question: "the longest video in the archive", playAfterAnswer: true))
        let result = try await run(q, memory: &memory,
                                   translated: .aggregate(.init(operation: .coOccurrence, anchorPeople: ["archive"])))
        #expect(result.route == .aggregate, Comment(rawValue: result.prose))
        #expect(result.outcome == .declined, Comment(rawValue: result.prose))
    }

    // MARK: 4. cc001 → cc002 → cc003 — the count chain

    /// TODAY: the catalog-wide count leaves `.wholeCatalog` in memory but
    /// no AST, so "how many of those are from the 90s" has no follow-up
    /// snapshot, reads as a sentence, and is translated from scratch; so
    /// is "and how many from the 80s".
    /// AFTER: a sticky count scope answers both locally, and the 80s
    /// REPLACES the 90s rather than intersecting with it.
    @Test func countChainReTranslatesEveryTurn() async throws {
        var memory = Exec.ConversationMemory()
        let first = try await run("how many videos do we have?", memory: &memory, catalogStats: stats)
        #expect(first.route == .aggregate)
        #expect(first.outcome == .answered)
        #expect(first.refinableQuery == .wholeCatalog)
        #expect(memory.lastRefinable == .wholeCatalog)
        // Step 2: the whole-catalog count now leaves a referent for "of those".
        #expect(memory.followUpSnapshot?.ast == .presence(.init(mediaKind: nil)))
        #expect(memory.followUpSnapshot?.items.isEmpty == true)
        #expect(memory.catalog.countScope == .wholeCatalog)
        #expect(memory.mode == .catalog)

        let second = "How many of those are from the 90s?"
        #expect(pre(second, memory: memory) == .translate(question: second, playAfterAnswer: false))
        let nineties = try await run(second, memory: &memory,
                                     translated: .presence(.init(yearStart: 1990, yearEnd: 1999)))
        #expect(nineties.matchCount == 8, Comment(rawValue: nineties.prose))

        let third = "and how many from the 80s"
        #expect(pre(third, memory: memory) == .translate(question: third, playAfterAnswer: false))
    }

    // MARK: 5. lv260911-003 — "show me" after a biography

    /// TODAY: the biography's "Open in Family Tree" offer is not
    /// remembered, so the elliptical "show me" has nothing to act on: the
    /// refinement path declines it as an uninterpretable fragment.
    /// AFTER: tree mode + one remembered offer → that offer is performed.
    @Test func showMeAfterABiographyIsAnUninterpretableFragment() {
        var memory = Exec.ConversationMemory()
        let intent = Exec.Intent(
            originalQuestion: "tell me about rick",
            ast: .graph(.init(people: ["rick"], operation: .biography)))
        memory.record(intent: intent, result: .init(
            route: .graph, outcome: .answered,
            prose: "Richard Harding Breen Jr was born in 1959.",
            basisLine: "Basis: fixture tree.", queryDescription: "shape=graph operation=biography",
            citations: [], catalogPersonName: "Richard Harding Breen Jr",
            offeredActions: [.openFamilyTreePerson(personID: "@I7@", personName: "Richard Harding Breen Jr")]))
        #expect(memory.lastSubject == "Richard Harding Breen Jr")
        guard case .answer(let result) = pre("show me", memory: memory) else {
            Issue.record("expected the follow-up decline, got \(pre("show me", memory: memory))")
            return
        }
        #expect(result.route == .followUp)
        #expect(result.outcome == .declined)
        #expect(result.prose.hasPrefix("I couldn't tell how “show me” narrows down my last answer"),
                Comment(rawValue: result.prose))
        #expect(result.immediateOfferedAction == nil)
    }

    // MARK: 6. lv260907-002 — highest royalty / title

    /// TODAY: no lane claims it; the translator answers with a whole-tree
    /// summary. The titled-ancestors route is a separate design; this
    /// branch only guarantees the turn is read as a TREE question.
    @Test func highestTitleInMyFamilyTreeIsTranslated() {
        let q = "who is the highest royalty or title in my family tree?"
        #expect(pre(q) == .translate(question: q, playAfterAnswer: false))
    }

    // MARK: 7. lv260907-004 — "search the family tree for a title like king"

    /// TODAY: the local family-tree shape fills its person slot with
    /// "title like king" without asking the oracle, and the executor
    /// answers "I don't find title like king".
    /// AFTER: the person slot requires a known person; otherwise an honest
    /// decline naming the phrase, with no "remember it?" offer.
    @Test func searchTheFamilyTreeForATitleFillsThePersonSlotBlindly() {
        let q = "search the family tree for a title like king"
        guard case .run(let intent) = pre(q) else {
            Issue.record("expected the local family-tree shape, got \(pre(q))")
            return
        }
        #expect(intent.ast == .graph(.init(people: ["title like king"], operation: .familyTree)),
                Comment(rawValue: "\(intent.ast)"))
    }
}
