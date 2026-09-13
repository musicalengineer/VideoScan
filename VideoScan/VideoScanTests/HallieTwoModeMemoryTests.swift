// HallieTwoModeMemoryTests.swift
// ConversationMemory's two-mode state (docs/hallie_two_mode_design.md
// §3.1–3.2): the transition table, declines that keep the chosen mode,
// reset, force/unforce, the count scope and tree offers, the
// whole-catalog follow-up snapshot — and the isolation dimension: three
// memories share nothing, and the mode is never persisted, so a poisoned
// `archivist.*` UserDefaults cannot pre-set it.

import Foundation
import Testing
@testable import VideoScan

@Suite("Hallie two-mode memory", .serialized)
struct HallieTwoModeMemoryTests {
    typealias Exec = HallieTurnExecutor
    typealias Memory = Exec.ConversationMemory

    private func result(
        route: Exec.Route, outcome: Exec.Outcome = .answered,
        person: String? = nil, matchCount: Int? = nil,
        offers: [Exec.OfferedAction] = [], refinable: Exec.RefinableQuery? = nil,
        query: String? = nil, mode: HallieMode? = nil,
        attachments: [HallieAttachment] = []
    ) -> Exec.Result {
        .init(route: route, outcome: outcome, prose: "fixture", basisLine: "Basis: fixture.",
              queryDescription: query, citations: [], catalogPersonName: person,
              matchCount: matchCount, offeredActions: offers, attachments: attachments,
              refinableQuery: refinable, mode: mode)
    }

    private func intent(_ q: String, _ ast: ArchivistQueryAST, countOnly: Bool = false) -> Exec.Intent {
        .init(originalQuestion: q, ast: ast, countOnly: countOnly)
    }

    // MARK: Transition table

    @Test func routesMoveTheModeByFamilyAndNeutralRoutesLeaveIt() {
        var memory = Memory()
        #expect(memory.mode == .unknown)
        #expect(memory.effectiveMode == .unknown)

        memory.record(intent: intent("videos of donna", .presence(.init(people: ["donna"]))),
                      result: result(route: .presence, matchCount: 3))
        #expect(memory.mode == .catalog)

        memory.record(intent: intent("tell me about rick", .graph(.init(people: ["rick"], operation: .biography))),
                      result: result(route: .graph, person: "Rick"))
        #expect(memory.mode == .tree)

        for neutral in [Exec.Route.followUp, .capability, .help, .smalltalk, .conversation] {
            memory.record(intent: nil, result: result(route: neutral))
            #expect(memory.mode == .tree, Comment(rawValue: "\(neutral) must not move the mode"))
        }

        memory.record(intent: intent("how old was timmy", .temporal(.init(subject: "timmy", operation: .age, reference: .currentSelection))),
                      result: result(route: .temporal))
        #expect(memory.mode == .catalog)
        memory.record(intent: nil, result: result(route: .telling))
        #expect(memory.mode == .tree)
        memory.record(intent: nil, result: result(route: .aggregate))
        #expect(memory.mode == .catalog)
        memory.record(intent: intent("who is in x.mov", .record(.init(reference: .file(name: "x.mov"), operations: [.people]))),
                      result: result(route: .record))
        #expect(memory.mode == .catalog)
    }

    @Test func aDeclineKeepsTheModeTheAnswerChose() {
        var memory = Memory()
        memory.record(intent: nil, result: result(route: .followUp, outcome: .declined, mode: .tree))
        #expect(memory.mode == .tree, "a follow-up decline carrying mode=tree moves the session to tree")
        // A catalog decline with an explicit verdict overrides the route family.
        memory.record(intent: nil, result: result(route: .graph, outcome: .declined, mode: .catalog))
        #expect(memory.mode == .catalog)
    }

    @Test func resetClearsModeAndForce() {
        var memory = Memory()
        memory.record(intent: nil, result: result(route: .graph, person: "Rick"))
        memory.force(.catalog)
        #expect(memory.mode == .tree)
        #expect(memory.forcedMode == .catalog)
        #expect(memory.effectiveMode == .catalog)
        memory.record(intent: nil, result: result(route: .reset))
        #expect(memory.mode == .unknown)
        #expect(memory.forcedMode == nil)
        #expect(memory.effectiveMode == .unknown)
    }

    @Test func forceAndUnforce() {
        var memory = Memory()
        memory.force(.tree)
        #expect(memory.effectiveMode == .tree)
        // Recording keeps moving the automatic mode underneath.
        memory.record(intent: nil, result: result(route: .presence, matchCount: 1))
        #expect(memory.mode == .catalog)
        #expect(memory.effectiveMode == .tree)
        memory.unforce()
        #expect(memory.effectiveMode == .catalog)
    }

    // MARK: Count scope

    @Test func countScopeFollowsCountsAndClearsOnOtherAnswers() {
        var memory = Memory()
        // A catalog-wide count leaves the whole catalog.
        memory.record(intent: nil, result: result(
            route: .aggregate, refinable: .wholeCatalog, query: "catalog-stats total"))
        #expect(memory.catalog.countScope == .wholeCatalog)
        #expect(memory.followUpSnapshot?.ast == .presence(.init(mediaKind: nil)))
        #expect(memory.followUpSnapshot?.items.isEmpty == true)

        // A count question answered with a match count → that query.
        let nineties = ArchivistQueryAST.presence(.init(yearStart: 1990, yearEnd: 1999))
        memory.record(intent: intent("how many of those are from the 90s?", nineties),
                      result: result(route: .presence, matchCount: 8))
        #expect(memory.catalog.countScope == .query(nineties))
        #expect(memory.catalog.resultCount == 8)

        // A count-only re-run keeps it alive even without "how many".
        let eighties = ArchivistQueryAST.presence(.init(yearStart: 1980, yearEnd: 1989))
        memory.record(intent: intent("and the 80s?", eighties, countOnly: true),
                      result: result(route: .presence, matchCount: 6))
        #expect(memory.catalog.countScope == .query(eighties))

        // An unrelated list clears it.
        memory.record(intent: intent("videos of donna", .presence(.init(people: ["donna"]))),
                      result: result(route: .presence, matchCount: 3))
        #expect(memory.catalog.countScope == nil)

        // A count, then a tree question, clears it (mode flips).
        memory.record(intent: intent("how many videos of donna", .presence(.init(people: ["donna"]))),
                      result: result(route: .presence, matchCount: 3))
        #expect(memory.catalog.countScope != nil)
        memory.record(intent: nil, result: result(route: .graph, person: "Rick"))
        #expect(memory.catalog.countScope == nil)
        #expect(memory.mode == .tree)

        // A catalog-stats answer that is NOT a count (archived, disk) leaves none.
        memory.record(intent: nil, result: result(route: .aggregate, query: "catalog-stats archived"))
        #expect(memory.catalog.countScope == nil)
    }

    @Test func aCountThatFoundNothingLeavesNoScope() {
        var memory = Memory()
        memory.record(intent: intent("how many videos of nobody", .presence(.init(people: ["nobody"]))),
                      result: result(route: .presence, outcome: .declined, matchCount: 0))
        #expect(memory.catalog.countScope == nil)
    }

    // MARK: Tree offers

    @Test func treeOffersAreKeptFromTreeAnswersAndClearedByCatalogAnswers() {
        var memory = Memory()
        let open = Exec.OfferedAction.openFamilyTreePerson(personID: "@I7@", personName: "Rick")
        memory.record(intent: nil, result: result(
            route: .graph, person: "Rick",
            offers: [open, .ask(question: "who were his parents", label: "His parents"),
                     .openPeopleTab, .recompileFamilyTree]))
        #expect(memory.tree.lastOffers == [open], "only show-able offers are kept")
        #expect(memory.tree.subject == "Rick")

        // A tree answer with no show-able offer clears them.
        memory.record(intent: nil, result: result(route: .graph, person: "Rick",
                                                  offers: [.ask(question: "x", label: "x")]))
        #expect(memory.tree.lastOffers.isEmpty)

        memory.record(intent: nil, result: result(
            route: .graph, person: "Rick", offers: [open, .revealFolder(url: URL(fileURLWithPath: "/isolated"), label: "Reveal")]))
        #expect(memory.tree.lastOffers.count == 2)
        memory.record(intent: nil, result: result(route: .presence, matchCount: 1))
        #expect(memory.tree.lastOffers.isEmpty, "a catalog answer clears the tree offers")
    }

    @Test func thePhotoShownRidesOnTheTreeContext() {
        var memory = Memory()
        let photo = HalliePhotoAttachment(personName: "Rick", fileURL: URL(fileURLWithPath: "/isolated/rick.jpg"))
        memory.record(intent: nil, result: result(route: .graph, person: "Rick", attachments: [.photo(photo)]))
        #expect(memory.tree.lastPhoto == photo)
        #expect(memory.lastPhotoAttachment == photo)
        memory.record(intent: nil, result: result(route: .graph, person: "Donna"))
        #expect(memory.tree.lastPhoto == nil)
    }

    // MARK: The whole-catalog snapshot only synthesizes for the count path

    @Test func theWholeCatalogSnapshotDoesNotAppearForOtherRefinables() {
        var memory = Memory()
        memory.record(intent: nil, result: result(
            route: .temporal, refinable: .list(.presence(.init(people: ["timmy"])), anyOfPeople: false)))
        #expect(memory.followUpSnapshot == nil, "only .wholeCatalog is synthesized; a list refinable without an AST stays nil")
        var fresh = Memory()
        #expect(fresh.followUpSnapshot == nil)
        fresh.record(intent: nil, result: result(route: .graph, person: "Rick"))
        #expect(fresh.followUpSnapshot == nil)
    }

    // MARK: Isolation

    @Test func threeMemoriesShareNothing() {
        var app = Memory(), shell = Memory(), web = Memory()
        app.record(intent: nil, result: result(route: .graph, person: "Rick"))
        shell.force(.catalog)
        #expect(app.mode == .tree)
        #expect(shell.mode == .unknown && shell.effectiveMode == .catalog)
        #expect(web.mode == .unknown && web.forcedMode == nil)
    }

    /// The mode is never persisted: no `archivist.*` key can pre-set it.
    @Test func poisonedUserDefaultsCannotPresetTheMode() {
        let defaults = UserDefaults.standard
        let keys = ["archivist.mode", "archivist.hallieMode", "archivist.forcedMode",
                    "archivist.conversation.mode", "hallie.mode", "HallieMode"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        for key in keys { defaults.set("tree", forKey: key) }
        let memory = Memory()
        #expect(memory.mode == .unknown)
        #expect(memory.forcedMode == nil)
        #expect(memory.effectiveMode == .unknown)
        // And nothing this type does writes one back.
        var written = Memory()
        written.force(.tree)
        written.record(intent: nil, result: result(route: .graph, person: "Rick"))
        for key in keys { #expect(defaults.string(forKey: key) == "tree", Comment(rawValue: key)) }
    }
}
