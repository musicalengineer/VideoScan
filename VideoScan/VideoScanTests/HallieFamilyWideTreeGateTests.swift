// HallieFamilyWideTreeGateTests.swift
// codex's replay of 2026-09-21 (binary 9818ff51): six whole-family tree
// questions — "how many grandchildren are there", "list everyone in the
// family", "what do you know about the Breen family", "tell me what it was
// like growing up in this family", "what would you say our family is known
// for", "when did the latta family come to america?" — were refused with
// "I read that as a family-tree question, but I couldn't tell who it is
// about". The translator had returned a catalog shape naming nobody, and
// the tree-mode gate knew only two roads for that: one person → rewrite,
// else decline. At the 2026-09-18 baseline the translator returned
// `familyTree` (with `surname=breen` / `surname=latta`) and they answered.
//
// Pinned here: the gate's third road — nobody named + a whole-family word
// → the `familyTree` graph operation, with the surname the sentence
// names — and that the one-person rewrite, the media switch and the
// honest decline for a no-family, no-person catalog shape all still hold.

import Foundation
import Testing
@testable import VideoScan

@Suite("Hallie mode gate: whole-family questions take the family-tree road")
struct HallieFamilyWideTreeGateTests {
    typealias Gate = HallieModeGate
    private let memory = HallieTurnExecutor.ConversationMemory()

    private func tree(_ ast: ArchivistQueryAST, _ q: String) -> Gate.Outcome {
        Gate.reconcile(ast: ast, mode: .tree, question: q, memory: memory)
    }

    @Test(arguments: hallieSocialClusterB)
    func aWholeFamilyAskWithNobodyNamedIsTheFamilyTreeOperation(row: HallieSocialReplayRow) {
        guard case .familyWide(let surname) = row.expect else {
            Issue.record("row \(row.id) is not a family-wide row")
            return
        }
        let outcome = tree(row.ast, row.question)
        guard case .rewrite(let ast, let note) = outcome else {
            Issue.record("\(row): expected a rewrite, got \(outcome)")
            return
        }
        #expect(ast == .graph(.init(people: [], operation: .familyTree, surname: surname)), Comment(rawValue: "\(row): \(ast)"))
        #expect(note.hasPrefix("read “\(row.question)” as a question about the whole family"), Comment(rawValue: note))
        #expect(note.hasSuffix("not a catalog search"), Comment(rawValue: note))
    }

    /// The surname the sentence names, or nil for "the whole family".
    @Test(arguments: [
        ("what do you know about the Breen family", "breen"),
        ("when did the latta family come to america?", "latta"),
        ("tell me about our McGill family", "mcgill"),
        ("what do you know about the Breens", "breen"),
        ("tell me about the Lattas?", "latta"),
        ("list everyone in the family", nil),
        ("tell me about the whole family", nil),
        ("tell me about our immediate family", nil),
        ("what happened at the Christmas party", nil),
        ("what do you know about the breens", nil),
    ] as [(String, String?)])
    func theSurnameOfTheFamily(question: String, surname: String?) {
        #expect(Gate.surnameOfFamily(in: question) == surname, Comment(rawValue: question))
    }

    /// A whole-family cue is a family word or a "came to america" phrase;
    /// a sentence with neither is about no family.
    @Test func theWholeFamilyCue() {
        #expect(Gate.familyWideAsk(in: "how many grandchildren are there")?.cue == "grandchildren")
        #expect(Gate.familyWideAsk(in: "list everyone in the family")?.cue == "everyone")
        #expect(Gate.familyWideAsk(in: "when did the lattas come over")?.cue == "came over" || Gate.familyWideAsk(in: "when did the lattas come over")?.cue == "come over")
        #expect(Gate.familyWideAsk(in: "what do you know about the Breens")?.cue == "the breens")
        #expect(Gate.familyWideAsk(in: "who was born in 1950") == nil)
        #expect(Gate.familyWideAsk(in: "the christmas tape") == nil)
        #expect(Gate.familyWideAsk(in: "what happened at the Christmas party") == nil)
        // A scope phrase names WHERE, not WHAT: no whole-family ask here
        // (HallieTwoModeReplayTests row 6 keeps its honest decline).
        #expect(Gate.familyWideAsk(in: "who is the highest royalty or title in my family tree?") == nil)
        #expect(Gate.familyWideAsk(in: "who was king in the family tree") == nil)
        #expect(Gate.familyWideAsk(in: "list everyone in the family tree")?.cue == "everyone")
    }

    /// The roads that already existed are untouched: one named person is
    /// still rewritten to that person's operation; a media ask still
    /// switches to the catalog; a no-person, no-family catalog shape is
    /// still the honest decline; unknown and catalog modes keep the AST.
    @Test func theOtherRoadsStillHold() {
        #expect(tree(.presence(.init(people: ["john hastings"], keywords: ["living"])),
                     "what did John Hastings do for a living?")
                == .rewrite(.graph(.init(people: ["john hastings"], operation: .biography)),
                            note: "read “what did John Hastings do for a living?” as a family-tree question about john hastings, not a catalog search"))
        // One person AND a family word: the person's road, not the overview.
        if case .rewrite(let ast, _) = tree(.presence(.init(people: ["rick"], keywords: ["grandchildren"])),
                                             "how many grandchildren does rick have") {
            #expect(ast != .graph(.init(people: [], operation: .familyTree)))
            if case .graph(let g) = ast { #expect(g.people == ["rick"]) } else { Issue.record("expected a graph AST") }
        } else {
            Issue.record("expected the one-person rewrite")
        }
        #expect(tree(.presence(.init(people: ["donna"], yearStart: 1990, yearEnd: 1993, keywords: ["cape"])),
                     "show me Donna down the cape in the early 90s")
                == .switchToCatalog(note: "read “show me Donna down the cape in the early 90s” as a catalog search (“show”), not a family-tree question"))
        #expect(tree(.presence(.init(mediaKind: .video, keywords: ["family"])), "show me family videos")
                == .switchToCatalog(note: "read “show me family videos” as a catalog search (“videos”), not a family-tree question"))
        if case .decline(let result) = tree(.presence(.init(yearStart: 1950, yearEnd: 1950)), "who was born in 1950") {
            #expect(result.prose.contains("couldn't tell who it is about"))
        } else {
            Issue.record("expected the honest decline for a no-person, no-family shape")
        }
        let familyPresence = ArchivistQueryAST.presence(.init(keywords: ["grandchildren"]))
        #expect(Gate.reconcile(ast: familyPresence, mode: .unknown, question: "how many grandchildren are there", memory: memory) == .keep)
        #expect(Gate.reconcile(ast: familyPresence, mode: .catalog, question: "how many grandchildren are there", memory: memory) == .keep)
    }
}
