import Foundation
import Testing
@testable import VideoScan

// MARK: - HallieTurnExecutor.execute (the AST router) — characterization
//
// Written 2026-10-29 BEFORE the CCN 41 router was split into one named
// route function per AST case. Each test pins a guard or basis note the
// router itself owns (not the route executors behind it), as it behaved on
// the unchanged code. `profiles: nil` makes the temporal and aggregate
// lanes end on a fixed decline, so the basis prefixes are exact strings.
//
// Red/green record (deliberate mutations on the UNCHANGED router, each
// reverted before the refactor):
//
//   mutation                                                | red test
//   --------------------------------------------------------|------------------------------------------
//   drop `!isRefinement` from the invented-year guard       | refinedTurnKeepsItsInheritedYear
//   never prefix the invented-year basis note               | inventedYearIsDroppedAndSaidFirst
//   drop the tree-mode `inMode(.tree)` stamp                | treeModeAgeAnswerIsStampedTree
//   skip the commonAncestor branch (falls to the graph lane)| commonAncestorNeedsExactlyTwoNames
//
// Green on the unchanged code, green after the refactor.

@Suite("Hallie turn router — characterization")
struct HallieTurnExecutorDispatchCharacterizationTests {

    private typealias Exec = HallieTurnExecutor

    private static let noProfiles = "Basis: profile evidence could not be read."

    private func ask(_ question: String, _ ast: ArchivistQueryAST,
                     context: Exec.Context = .init(profiles: nil),
                     refinementNote: String? = nil) async throws -> Exec.Result {
        try await Exec.execute(
            .init(intent: .init(originalQuestion: question, ast: ast,
                                refinementNote: refinementNote)),
            context: context)
    }

    private func age(_ subject: String, _ reference: ArchivistQueryAST.Temporal.Reference) -> ArchivistQueryAST {
        .temporal(.init(subject: subject, operation: .age, reference: reference))
    }

    // MARK: Temporal guards

    @Test func inventedYearIsDroppedAndSaidFirst() async throws {
        let r = try await ask("how old was donna when she passed?", age("donna", .explicitYear(1994)))
        #expect(r.route == .temporal)
        #expect(r.outcome == .declined)
        #expect(r.basisLine == "Basis: the translator supplied year 1994, which the question never mentions, so it was ignored; profile evidence could not be read.")
    }

    @Test func statedYearTheTranslatorDroppedIsRestored() async throws {
        let r = try await ask("how old was donna in 1985", age("donna", .currentSelection))
        #expect(r.route == .temporal)
        #expect(r.basisLine == "Basis: the question says 1985; the translator left it out, so I counted to 1985; profile evidence could not be read.")
    }

    @Test func yearTheQuestionStatesIsKeptWithoutANote() async throws {
        let r = try await ask("how old was donna in 1994", age("donna", .explicitYear(1994)))
        #expect(r.basisLine == Self.noProfiles)
    }

    @Test func refinedTurnKeepsItsInheritedYear() async throws {
        let r = try await ask("what about rick?", age("rick", .explicitYear(1994)),
                              refinementNote: "refining: rick")
        #expect(r.basisLine == Self.noProfiles)
    }

    @Test func astOnlyEntryHasNoQuestionToJudgeAgainst() async throws {
        let r = try await Exec.execute(age("donna", .explicitYear(1994)), context: .init(profiles: nil))
        #expect(r.route == .temporal)
        #expect(r.basisLine == Self.noProfiles)
    }

    @Test func mediaAskMisreadAsAgeIsSearchedInstead() async throws {
        let r = try await ask("Christmas videos from 2006", age("", .currentSelection),
                              context: .init(profiles: []))
        #expect(r.route == .presence)
        #expect(r.basisLine.hasPrefix("Basis: the question has a media word and no age word, so it is not an age question; I searched the catalog; "),
                Comment(rawValue: r.basisLine))
    }

    @Test func treeModeAgeAnswerIsStampedTree() async throws {
        let r = try await ask("how old was donna in 1994", age("donna", .explicitYear(1994)),
                              context: .init(profiles: nil, mode: .tree))
        #expect(r.mode == .tree)
        let unknown = try await ask("how old was donna in 1994", age("donna", .explicitYear(1994)))
        #expect(unknown.mode == nil)
    }

    // MARK: Aggregate guards

    @Test func aggregateWithoutProfilesDeclinesHonestly() async throws {
        let r = try await ask("who appears with donna most",
                              .aggregate(.init(operation: .coOccurrence, anchorPeople: ["donna"])))
        #expect(r.route == .aggregate)
        #expect(r.outcome == .declined)
        #expect(r.basisLine == Self.noProfiles)
        #expect(r.queryDescription == "shape=aggregate")
    }

    @Test func treeModeNeverTurnsAnUnresolvedAnchorIntoACatalogSearch() async throws {
        let profiles = [Exec.ProfileSnapshot(
            stableID: "rick", canonicalName: "Richard Harding Breen Jr", aliases: ["Dicky"])]
        let speakers = Exec.Speakers(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil)
        let question = "show rick playing guitar"
        let ast = ArchivistQueryAST.aggregate(.init(operation: .coOccurrence, anchorPeople: ["rick"]))
        let catalog = try await ask(question, ast, context: .init(profiles: profiles, speakers: speakers))
        #expect(catalog.route == .presence)
        let tree = try await ask(question, ast, context: .init(profiles: profiles, speakers: speakers, mode: .tree))
        #expect(tree.route == .aggregate)
        #expect(!tree.basisLine.contains("not a co-occurrence anchor"))
    }

    // MARK: Graph and cross

    @Test func commonAncestorNeedsExactlyTwoNames() async throws {
        let r = try await ask("common ancestor of donna",
                              .graph(.init(people: ["donna"], operation: .commonAncestor)),
                              context: .init(profiles: []))
        #expect(r.route == .graph)
        #expect(r.prose == "That identity choice is no longer available.")
    }

    @Test func crossMergesSpokenTermsIntoTheKeywordSearch() async throws {
        let record = ArchivistPresenceRecordSnapshot(
            fullPath: "/Volumes/X/parade.mov", directory: "/Volumes/X", volumeName: "X",
            inferredDate: nil, confirmedPeople: [], resolvedDate: nil, userPlace: nil)
        let other = ArchivistPresenceRecordSnapshot(
            fullPath: "/Volumes/X/beach.mov", directory: "/Volumes/X", volumeName: "X",
            inferredDate: nil, confirmedPeople: [], resolvedDate: nil, userPlace: nil)
        let r = try await ask("videos where someone says parade",
                              .cross(.init(transcript: ["parade"])),
                              context: .init(presenceRecords: [record, other], profiles: []))
        #expect(r.route == .cross)
        #expect(r.citations.map(\.filename) == ["parade.mov"], Comment(rawValue: r.prose))
    }
}
