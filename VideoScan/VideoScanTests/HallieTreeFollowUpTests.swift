// HallieTreeFollowUpTests.swift
// "show me" after a family-tree answer (design §3.5): one remembered offer
// is performed, several become a choice, none becomes an offer built from
// the subject; a stale personID is refused; and the handler is consulted
// in tree mode only — a "show me" after a catalog list keeps today's
// media-action road.

import Foundation
import Testing
@testable import VideoScan

@Suite("Hallie tree follow-up: show me")
struct HallieTreeFollowUpTests {
    typealias Exec = HallieTurnExecutor
    typealias Memory = Exec.ConversationMemory

    private let open = Exec.OfferedAction.openFamilyTreePerson(personID: "@I7@", personName: "Richard Harding Breen Jr")
    private let photo = HalliePhotoAttachment(personName: "Richard Harding Breen Jr", fileURL: URL(fileURLWithPath: "/isolated/rick.jpg"), personGedcomID: "@I7@")

    private func treeMemory(offers: [Exec.OfferedAction], photo: HalliePhotoAttachment? = nil,
                            subject: String? = "Richard Harding Breen Jr") -> Memory {
        var memory = Memory()
        memory.record(intent: nil, result: .init(
            route: .graph, outcome: .answered, prose: "Rick was born in 1959.",
            basisLine: "Basis: fixture.", queryDescription: "shape=graph operation=biography",
            citations: [], catalogPersonName: subject, offeredActions: offers,
            attachments: photo.map { [.photo($0)] } ?? []))
        #expect(memory.mode == .tree)
        return memory
    }

    @Test func theShapesAreTheEllipticalFormsOnly() {
        for q in ["show me", "Show me!", "show it", "let me see", "let me see it", "open it",
                  "ok show me", "please show me", "lets see", "show me that", "can I see it?"] {
            #expect(HallieTreeFollowUp.isShowMe(q), Comment(rawValue: q))
        }
        for q in ["show me the photo", "show me the second one", "show me rick's family tree",
                  "show", "show more", "show me videos of donna", "let me see his parents"] {
            #expect(!HallieTreeFollowUp.isShowMe(q), Comment(rawValue: q))
        }
    }

    @Test func oneOfferIsPerformed() {
        let memory = treeMemory(offers: [open])
        let result = HallieTreeFollowUp.turn(question: "show me", memory: memory)
        #expect(result?.route == .graph)
        #expect(result?.outcome == .answered)
        #expect(result?.immediateOfferedAction == open)
        #expect(result?.offeredActions == [open])
        #expect(result?.mode == .tree)
        #expect(result?.catalogPersonName == "Richard Harding Breen Jr")
    }

    @Test func onePhotoIsReAttached() {
        let memory = treeMemory(offers: [], photo: photo)
        let result = HallieTreeFollowUp.turn(question: "let me see it", memory: memory)
        #expect(result?.outcome == .answered)
        #expect(result?.attachments == [.photo(photo)])
        #expect(result?.immediateOfferedAction == nil)
        #expect(result?.prose == "Here's the photo of Richard Harding Breen Jr again.")
    }

    @Test func severalOffersBecomeAChoice() {
        let memory = treeMemory(offers: [open], photo: photo)
        let result = HallieTreeFollowUp.turn(question: "show me", memory: memory)
        #expect(result?.outcome == .answered)
        #expect(result?.immediateOfferedAction == nil, "nothing is performed without a choice")
        #expect(result?.offeredActions.count == 2)
        #expect(result?.offeredActions.first == open)
        #expect(result?.offeredActions.last == .ask(question: "photos of Richard Harding Breen Jr",
                                                    label: "The photo of Richard Harding Breen Jr"))
        #expect(result?.prose.hasPrefix("Which would you like — ") == true, Comment(rawValue: result?.prose ?? ""))
    }

    @Test func noOfferBecomesAnOfferBuiltFromTheSubject() {
        let memory = treeMemory(offers: [.ask(question: "who were his parents", label: "His parents")])
        let result = HallieTreeFollowUp.turn(question: "show me", memory: memory)
        #expect(result?.outcome == .declined)
        #expect(result?.prose == "Show you what — a photo of Richard Harding Breen Jr, or Richard Harding Breen Jr’s place in the family tree?")
        #expect(result?.offeredActions == [
            .ask(question: "photos of Richard Harding Breen Jr", label: "A photo of Richard Harding Breen Jr"),
            .ask(question: "show Richard Harding Breen Jr’s family tree", label: "Richard Harding Breen Jr’s family tree"),
        ])
        #expect(result?.mode == .tree)
    }

    @Test func noOfferAndNoSubjectAsksWhat() {
        var memory = Memory()
        memory.record(intent: nil, result: .init(
            route: .graph, outcome: .declined, prose: "Who do you mean?",
            basisLine: "Basis: fixture.", queryDescription: nil, citations: [], catalogPersonName: nil))
        let result = HallieTreeFollowUp.turn(question: "show me", memory: memory)
        #expect(result?.outcome == .declined)
        #expect(result?.prose == "Show you what? Ask me about someone in the family first.")
    }

    @Test func aStalePersonIDIsRefusedNeverFired() {
        let memory = treeMemory(offers: [open])
        let refused = HallieTreeFollowUp.turn(question: "show me", memory: memory, isTreePersonID: { _ in false })
        #expect(refused?.outcome == .declined)
        #expect(refused?.immediateOfferedAction == nil)
        #expect(refused?.prose.contains("has changed since") == true, Comment(rawValue: refused?.prose ?? ""))
        // The same offer with a live id is performed; a name-only offer
        // carries no id and is never refused.
        let live = HallieTreeFollowUp.turn(question: "show me", memory: memory, isTreePersonID: { $0 == "@I7@" })
        #expect(live?.immediateOfferedAction == open)
        let named = treeMemory(offers: [.openFamilyTree(personName: "Rick")])
        #expect(HallieTreeFollowUp.turn(question: "show me", memory: named, isTreePersonID: { _ in false })?
                    .immediateOfferedAction == .openFamilyTree(personName: "Rick"))
    }

    @Test func notAShowMeIsNil() {
        let memory = treeMemory(offers: [open])
        #expect(HallieTreeFollowUp.turn(question: "show me his parents", memory: memory) == nil)
        #expect(HallieTreeFollowUp.turn(question: "show more", memory: memory) == nil)
    }

    /// Through the real pre-translation: in tree mode the handler fires;
    /// after a catalog list the same words keep the media-action road.
    @Test func consultedInTreeModeOnly() {
        let treeMode = treeMemory(offers: [open])
        let context = Exec.Context()
        let inTree = Exec.preTranslation(
            question: "show me", playAfterAnswer: false, memory: treeMode,
            isKnownPerson: { Exec.isKnownPerson($0, context: context) })
        guard case .answer(let shown) = inTree else {
            Issue.record("expected the tree follow-up, got \(inTree)")
            return
        }
        #expect(shown.immediateOfferedAction == open)

        var catalogMode = Memory()
        let citation = Exec.Citation(recordID: UUID(), fullPath: "/Fixture/donna_0.mov", filename: "donna_0.mov",
                                     playbackSeconds: nil, bases: [])
        catalogMode.record(
            intent: .init(originalQuestion: "videos of donna", ast: .presence(.init(people: ["donna"]))),
            result: .init(route: .presence, outcome: .answered, prose: "One.", basisLine: "Basis: fixture.",
                          queryDescription: "shape=presence", citations: [citation], catalogPersonName: nil, matchCount: 1))
        #expect(catalogMode.mode == .catalog)
        let inCatalog = Exec.preTranslation(
            question: "show me", playAfterAnswer: false, memory: catalogMode,
            isKnownPerson: { Exec.isKnownPerson($0, context: context) })
        guard case .answer(let action) = inCatalog else {
            Issue.record("expected the media action, got \(inCatalog)")
            return
        }
        #expect(action.route == .followUp)
        #expect(action.mediaAction?.kind == .show)
        #expect(action.mediaAction?.citations == [citation])
    }
}
