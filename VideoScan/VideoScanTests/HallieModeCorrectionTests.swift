// HallieModeCorrectionTests.swift
// Design §3.6 step 6 — correcting the mode by talking. Ledger row 2
// (lv260907-003): "not in videos, in family tree" right after row 1 was
// declined must re-run row 1 under tree mode; a correction with nothing
// to re-ask declines honestly and still switches; naming the OTHER
// family than the one forced returns to automatic; a pure correction
// outranks the repair step, a complaint with content does not.

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
0 @I7@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 BIRT
2 DATE 1959
0 TRLR
"""

@Suite("Mode correction by talking (design §3.6 step 6)")
struct HallieModeCorrectionTests {
    typealias Exec = HallieTurnExecutor
    typealias Correction = HallieModeCorrection.Correction
    private let graph = GedcomFamilyGraph(gedcomText: tree)
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    /// Ledger row 1 (lv260907-002), verbatim.
    private let row1 = "in the family tree going back, find the highest level of royalty or title such as lord, prince, king, etc."
    /// Ledger row 2 (lv260907-003), verbatim.
    private let row2 = "not in videos, in family tree"

    private var context: Exec.Context {
        let records = (0..<3).map { i in
            ArchivistPresenceRecordSnapshot(
                fullPath: "/Fixture/199\(i)/donna_\(i).mov", directory: "/Fixture/199\(i)", volumeName: "Fixture",
                confirmedPeople: [ConfirmedTag(name: "Donna", confirmedAt: stamp)])
        }
        return .init(presenceRecords: records, profiles: [], graph: graph,
                     speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
    }

    private func classified(_ q: String, memory: Exec.ConversationMemory = .init()) -> Exec.Classified {
        let context = self.context
        return Exec.preTranslationClassified(
            question: q, playAfterAnswer: false, memory: memory,
            isKnownPerson: { Exec.isKnownPerson($0, context: context) },
            lineageAnswer: { HallieLineageAnswer.answer($0, context: context) },
            identity: Exec.nameIdentity { context })
    }

    // MARK: Detector

    @Test func detectorReadsCorrectionsAndNothingElse() {
        #expect(HallieModeCorrection.detect("not in videos, in family tree")?.mode == .tree)
        #expect(HallieModeCorrection.detect("Not in videos — in the family tree.")?.mode == .tree)
        #expect(HallieModeCorrection.detect("I meant the catalog")?.mode == .catalog)
        #expect(HallieModeCorrection.detect("no, the archive")?.mode == .catalog)
        #expect(HallieModeCorrection.detect("check the tree instead")?.mode == .tree)
        #expect(HallieModeCorrection.detect("no, I meant the family tree")?.mode == .tree)
        #expect(HallieModeCorrection.detect("not the tree")?.mode == .catalog)
        #expect(HallieModeCorrection.detect("in the family tree, not the videos")?.mode == .tree)
        #expect(HallieModeCorrection.detect("switch to catalog mode")?.mode == .catalog)
        #expect(HallieModeCorrection.detect("try the videos")?.mode == .catalog)
        // Not corrections: the person-fact lane's own tree correction, a
        // scope with a question in it, a complaint with content, both
        // families named, neither named, a plain scope with no cue.
        #expect(HallieModeCorrection.detect("check the tree") == nil)
        #expect(HallieModeCorrection.detect("look it up in the family tree") == nil)
        #expect(HallieModeCorrection.detect("who is in the family tree") == nil)
        #expect(HallieModeCorrection.detect("no that's wrong, you gave me videos") == nil)
        #expect(HallieModeCorrection.detect("I meant the tree and the videos") == nil)
        #expect(HallieModeCorrection.detect("no, I meant it") == nil)
        #expect(HallieModeCorrection.detect("the family tree") == nil)
        #expect(HallieModeCorrection.detect("videos of donna in the archive") == nil)
        #expect(HallieModeCorrection.detect("") == nil)
    }

    @Test func forceRuleNamingTheOtherFamilyUnforces() {
        let tree = Correction(mode: .tree, phrase: "in family tree")
        let catalog = Correction(mode: .catalog, phrase: "the catalog")
        #expect(HallieModeCorrection.force(for: tree, forcedMode: nil) == .force(.tree))
        #expect(HallieModeCorrection.force(for: tree, forcedMode: .tree) == .force(.tree))
        #expect(HallieModeCorrection.force(for: catalog, forcedMode: .tree) == .unforce)
        #expect(HallieModeCorrection.force(for: tree, forcedMode: .catalog) == .unforce)
    }

    // MARK: Ledger row 2 re-runs row 1 under tree mode

    @Test func ledgerRowTwoReRunsRowOneUnderTreeMode() throws {
        // Row 1: the translator's presence AST is declined by the tree-mode
        // gate (step 4) — a decline is not a substantive exchange, so only
        // `lastAsk` remembers it.
        var memory = Exec.ConversationMemory()
        let first = classified(row1)
        #expect(first.verdict.mode == .tree, Comment(rawValue: "\(first.verdict)"))
        guard case .decline(let declined) = HallieModeGate.reconcile(
            ast: .presence(.init(keywords: ["royalty", "title", "lord", "prince", "king"])),
            mode: .tree, question: row1, memory: memory, playAfterAnswer: false) else {
            Issue.record("expected the tree-mode gate to decline the catalog search")
            return
        }
        memory.record(intent: nil, result: declined, question: row1)
        #expect(memory.lastExchange == nil)
        #expect(memory.lastAsk == row1)
        #expect(memory.mode == .tree)

        // Row 2: the correction re-asks row 1 under a forced tree verdict.
        let second = classified(row2, memory: memory)
        #expect(second.verdict == .init(mode: .tree, reason: .forced))
        #expect(second.modeForce == .force(.tree))
        switch second.decision {
        case .translate(let question, let play):
            #expect(question == row1)
            #expect(!play)
            // What a translating client does: the force rides on its Intent.
            let intent = Exec.Intent(originalQuestion: question,
                                     ast: .graph(.init(people: [], operation: .biography)),
                                     modeForce: second.modeForce)
            memory.record(intent: intent, result: declined)
        case .run(let intent):
            #expect(intent.originalQuestion == row1)
            #expect(intent.modeForce == .force(.tree))
            memory.record(intent: intent, result: declined)
        case .answer(let result):
            #expect(result.modeForce == .force(.tree), Comment(rawValue: result.prose))
            #expect(!result.prose.contains("I don't have a question to re-ask"), Comment(rawValue: result.prose))
            memory.record(intent: nil, result: result, question: row2)
        }
        #expect(memory.forcedMode == .tree)
        #expect(memory.effectiveMode == .tree)
        // The correction itself is never what gets re-asked next time.
        #expect(memory.lastAsk == row1)
    }

    @Test func aCorrectionWithNothingToReAskDeclinesHonestlyAndStillSwitches() {
        var memory = Exec.ConversationMemory()
        let turn = classified("I meant the catalog", memory: memory)
        guard case .answer(let result) = turn.decision else {
            Issue.record("expected an honest decline, got \(turn.decision)")
            return
        }
        #expect(result.route == .followUp)
        #expect(result.outcome == .declined)
        #expect(result.prose.hasPrefix("Okay — the catalog it is; I'm holding it there. I don't have a question to re-ask yet"),
                Comment(rawValue: result.prose))
        #expect(result.mode == .catalog)
        #expect(result.modeForce == .force(.catalog))
        #expect(turn.verdict == .init(mode: .catalog, reason: .forced))
        memory.record(intent: nil, result: result, question: "I meant the catalog")
        #expect(memory.forcedMode == .catalog)
        #expect(memory.lastAsk == nil, "the correction is not a question to re-ask")
    }

    @Test func namingTheOtherFamilyThanTheForcedOneReturnsToAutomatic() {
        var memory = Exec.ConversationMemory()
        memory.force(.tree)
        let turn = classified("no, the catalog", memory: memory)
        #expect(turn.modeForce == .unforce)
        #expect(turn.verdict.mode == .catalog)
        guard case .answer(let result) = turn.decision else {
            Issue.record("expected an honest decline, got \(turn.decision)")
            return
        }
        #expect(result.prose.contains("back to choosing automatically"), Comment(rawValue: result.prose))
        memory.record(intent: nil, result: result, question: "no, the catalog")
        #expect(memory.forcedMode == nil)
        // The same family as the forced one keeps the force.
        var held = Exec.ConversationMemory()
        held.force(.tree)
        #expect(classified("in the family tree, not the videos", memory: held).modeForce == .force(.tree))
    }

    @Test func aPureCorrectionOutranksTheRepairStepAndAComplaintDoesNot() async throws {
        // A substantive exchange so the repair step has something to repair.
        var memory = Exec.ConversationMemory()
        let context = self.context
        let intent = Exec.Intent(originalQuestion: "videos of donna", ast: .presence(.init(people: ["Donna"])))
        let listed = try await Exec.execute(.init(intent: intent), context: context)
        #expect(listed.outcome == .answered, Comment(rawValue: listed.prose))
        memory.record(intent: intent, result: listed)
        #expect(memory.lastExchange?.question == "videos of donna")
        #expect(memory.lastAsk == "videos of donna")

        let corrected = classified("no, I meant the family tree", memory: memory)
        #expect(corrected.verdict == .init(mode: .tree, reason: .forced))
        #expect(corrected.modeForce == .force(.tree))
        if case .answer(let result) = corrected.decision {
            #expect(result.outcome != .repaired, Comment(rawValue: result.prose))
        }

        let complaint = classified("no that's wrong, you gave me videos", memory: memory)
        #expect(complaint.modeForce == nil)
        guard case .answer(let repaired) = complaint.decision else {
            Issue.record("expected the repair step, got \(complaint.decision)")
            return
        }
        #expect(repaired.outcome == .repaired, Comment(rawValue: repaired.prose))
    }

    @Test func resetClearsTheForceAndTheLastAsk() {
        var memory = Exec.ConversationMemory()
        let turn = classified("check the tree instead", memory: memory)
        if case .answer(let result) = turn.decision {
            memory.record(intent: nil, result: result, question: "check the tree instead")
        }
        #expect(memory.forcedMode == .tree)
        memory.reset()
        #expect(memory.forcedMode == nil)
        #expect(memory.lastAsk == nil)
    }
}
