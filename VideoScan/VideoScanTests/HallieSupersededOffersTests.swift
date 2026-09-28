// HallieSupersededOffersTests.swift
//
// THE LIVE FAILURE, 2026-09-26 14:15 ET (session 627FCBEB, Rick, app),
// defect C of the "find videos of dad" exchange:
//
//   14:14:45  "find videos of dad" → answered for Dafydd ab Einion (b. ~1360)
//             with the chip "Open in Family Tree: Dafydd ab Einion …".
//   14:15:07  "dad breen not someone from 5 centuries ago" → the model timed
//             out for 21 s; the template answered about Richard Harding
//             Breen Sr at 14:15:28.
//   14:15:28  "Opening the Family Tree tab focused on Dafydd ab Einion" —
//             a second assistant bubble in the same second; 14:15:29
//             "[family-tree] focus kind=record-id result=applied".
//
// The only code that writes that bubble is the window's chip handler
// (openFamilyTreeTab(announce: true)); the commit path's auto-focus sink
// announces nothing and logs "Hallie focus requested", which is absent. So
// the stale chip from the SUPERSEDED answer was tapped the instant thinking
// ended — a tap during thinking is dropped silently, which is how one lands
// on the first frame after. The chip should not have been live at all: the
// conversation had already moved from Dafydd to Richard Sr, and memory's
// tree.lastOffers (what "show me" acts on) already forgets an earlier
// answer's offers. The transcript now does the same.
//
// Five dimensions: 1 logic (the pure retire + the commit sink), 2 scale
// n/a, 3 media n/a, 4 isolation (inert sinks, no window, no defaults),
// 5 sensor — an immediate action is only ever performed for the result's
// OWN person, and an answer about the same person retires nothing.

import Foundation
import Testing
@testable import VideoScan

@Suite("Hallie — a superseded tree offer is retired, never performed")
@MainActor
struct HallieSupersededOffersTests {
    private typealias Commit = HallieResponseCommit
    private typealias Exec = HallieTurnExecutor

    private static let dafydd = "Dafydd ab Einion \"Y Giwn Llwyd\""
    private static let dafyddID = "@IB21341@"
    private static let richardSr = "Richard Harding Breen Sr"
    private static let richardSrID = "@I2@"

    private static let openDafydd = ArchivistMessage.Chip(
        label: "Open in Family Tree: \(dafydd)",
        action: .openFamilyTreePerson(personID: dafyddID, personName: dafydd))
    private static let openRichard = ArchivistMessage.Chip(
        label: "Open in Family Tree: \(richardSr)",
        action: .openFamilyTreePerson(personID: richardSrID, personName: richardSr))
    private static let askService = ArchivistMessage.Chip(
        label: richardSr, action: .askText("how did Richard Harding Breen Sr serve", playAfterAnswer: false))
    private static let breens = ArchivistMessage.Chip(
        label: "Open in Family Tree: the Breens", action: .openFamilyTreeSurname("Breen"))

    // MARK: - The pure function

    @Test func aStaleTreeChipIsRetiredWhenTheSubjectChanges() {
        let user = ArchivistMessage(role: .user, text: "find videos of dad")
        let stale = ArchivistMessage(role: .assistant, text: "Dafydd … no film.", chips: [Self.openDafydd, Self.breens])
        let retired = HallieSupersededOffers.retire(in: [user, stale], keeping: Self.richardSr)
        #expect(retired.count == 2)
        #expect(retired[0] == user, "user bubbles are never touched")
        #expect(retired[1].id == stale.id, "bubble identity survives")
        #expect(retired[1].text == stale.text)
        #expect(retired[1].chips == [Self.breens], "the surname chip is not a person offer")
    }

    @Test func theCurrentPersonsOwnChipAndTheAskChipsStay() {
        let bubble = ArchivistMessage(role: .assistant, text: "Richard Sr …",
                                      chips: [Self.openRichard, Self.askService, Self.openDafydd])
        let retired = HallieSupersededOffers.retire(in: [bubble], keeping: Self.richardSr)
        #expect(retired[0].chips == [Self.openRichard, Self.askService])
    }

    @Test func theSamePersonRetiresNothing() {
        let bubble = ArchivistMessage(role: .assistant, text: "Dafydd …", chips: [Self.openDafydd])
        let retired = HallieSupersededOffers.retire(in: [bubble], keeping: Self.dafydd)
        #expect(retired[0].chips == [Self.openDafydd])
        #expect(retired[0] == bubble)
    }

    @Test func spellingDifferencesDoNotCountAsAnotherPerson() {
        #expect(!HallieSupersededOffers.isSuperseded(Self.openRichard, by: "richard harding breen sr"))
        #expect(HallieSupersededOffers.isSuperseded(Self.openDafydd, by: Self.richardSr))
        #expect(!HallieSupersededOffers.isSuperseded(Self.askService, by: Self.dafydd))
    }

    // MARK: - The commit path

    @MainActor
    private final class Capture {
        var state = Commit.State()
        var messages: [ArchivistMessage] = []
        var retired: [String] = []
        var retiredSubjects: [HallieSupersededOffers.Subject] = []
        var focused: [(String, String)] = []
        var events: [String] = []

        var sinks: Commit.Sinks {
            .init(
                isSpeechEnabled: { false },
                speakPrepared: { _, _ in },
                speak: { _, _ in },
                recordForID: { _ in nil },
                publishState: { self.state = $0 },
                appendMessage: { self.events.append("message"); self.messages.append($0) },
                performMediaAction: { _ in },
                play: { _ in },
                openFamilyTreePerson: { self.events.append("focus"); self.focused.append(($0, $1)) },
                recompileFamilyTree: { _ in },
                acceptImmediateOffer: { _ in },
                retireSupersededOffers: { subject in
                    self.events.append("retire")
                    self.retired.append(subject.name)
                    self.retiredSubjects.append(subject)
                    self.messages = HallieSupersededOffers.retire(in: self.messages, keeping: subject)
                })
        }

        @discardableResult
        func apply(_ response: HallieAppTurnCoordinator.Response, question: String) -> Bool {
            let id = UUID()
            return Commit.apply(response, question: question, modelName: "fixture-model",
                                requestID: id, activeRequestID: id, isCancelled: false,
                                state: state, sinks: sinks)
        }
    }

    private func result(prose: String, person: String, outcome: Exec.Outcome = .answered,
                        offers: [Exec.OfferedAction] = [],
                        immediate: Exec.OfferedAction? = nil) -> Exec.Result {
        .init(route: .graph, outcome: outcome, prose: prose, basisLine: "Basis: fixture.",
              queryDescription: "fixture", citations: [], catalogPersonName: person,
              offeredActions: offers, immediateOfferedAction: immediate)
    }

    private func response(_ result: Exec.Result, intent: Exec.Intent? = nil) -> HallieAppTurnCoordinator.Response {
        .init(result: result, responderHost: "fixture.invalid", biographyPhoto: nil,
              capturedReferentID: nil, citations: [], pendingClarification: nil,
              playAfterAnswer: false, executedIntent: intent)
    }

    /// Turn 1 as it was: the pre-film decline for Dafydd, with its offer.
    private func afterTurnOne() -> Capture {
        let capture = Capture()
        let dafydd = result(
            prose: "Dafydd ab Einion was born about 1360 … there can’t be film of him.",
            person: Self.dafydd, outcome: .declined,
            offers: [.openFamilyTreePerson(personID: Self.dafyddID, personName: Self.dafydd)])
        capture.apply(response(dafydd), question: "find videos of dad")
        #expect(capture.messages.count == 1)
        #expect(capture.messages[0].chips.map(\.label) == ["Open in Family Tree: \(Self.dafydd)"])
        #expect(capture.state.memory.lastSubject == Self.dafydd)
        #expect(capture.retired.isEmpty || capture.retired == [Self.dafydd])
        return capture
    }

    /// THE live turn 2: the correction lands on Richard Sr; the Dafydd chip
    /// on turn 1's bubble is gone before turn 2's bubble appears, memory
    /// offers nothing about Dafydd, and nothing was focused.
    @Test func theCorrectionRetiresTheRejectedPersonsChip() {
        let capture = afterTurnOne()
        let correction = Exec.Intent(
            originalQuestion: "dad breen not someone from 5 centuries ago",
            ast: .graph(.init(people: ["dad breen"], operation: .biography)))
        capture.apply(
            response(result(prose: "Here is what the family archive currently supports about Richard Harding Breen Sr.",
                            person: Self.richardSr,
                            offers: [.ask(question: "how did Richard Harding Breen Sr serve", label: Self.richardSr)]),
                     intent: correction),
            question: correction.originalQuestion)
        #expect(capture.retired.last == Self.richardSr, Comment(rawValue: capture.retired.joined(separator: " | ")))
        #expect(capture.messages.count == 2)
        #expect(capture.messages[0].chips.isEmpty, Comment(rawValue: capture.messages[0].chips.map(\.label).joined(separator: " | ")))
        #expect(capture.messages[1].chips.map(\.label) == [Self.richardSr])
        #expect(capture.state.memory.tree.lastOffers.isEmpty)
        #expect(capture.state.memory.lastSubject == Self.richardSr)
        #expect(capture.focused.isEmpty, "nothing opens the tree on its own")
        // Order: the retirement happens before the new bubble is appended.
        let retireIndex = capture.events.lastIndex(of: "retire") ?? -1
        let messageIndex = capture.events.lastIndex(of: "message") ?? -1
        #expect(retireIndex >= 0 && retireIndex < messageIndex, Comment(rawValue: capture.events.joined(separator: ",")))
    }

    /// Another answer about the SAME person keeps its chips and does not
    /// call the sink again.
    @Test func anAnswerAboutTheSamePersonRetiresNothing() {
        let capture = afterTurnOne()
        let before = capture.retired.count
        capture.apply(
            response(result(prose: "Dafydd ab Einion again.", person: Self.dafydd,
                            offers: [.openFamilyTreePerson(personID: Self.dafyddID, personName: Self.dafydd)])),
            question: "tell me about him")
        #expect(capture.retired.count == before)
        #expect(capture.messages.count == 2)
        #expect(capture.messages[0].chips.map(\.label) == ["Open in Family Tree: \(Self.dafydd)"])
    }

    /// SENSOR: an immediate action is performed only for the result's OWN
    /// person; a superseded person never rides along.
    @Test func anImmediateActionOpensOnlyTheAnswersOwnPerson() {
        let capture = afterTurnOne()
        capture.apply(
            response(result(prose: "Opening the family tree on Richard Harding Breen Sr.",
                            person: Self.richardSr,
                            offers: [.openFamilyTreePerson(personID: Self.richardSrID, personName: Self.richardSr)],
                            immediate: .openFamilyTreePerson(personID: Self.richardSrID, personName: Self.richardSr))),
            question: "center the tree on dad breen")
        #expect(capture.focused.map(\.1) == [Self.richardSr])
        #expect(capture.messages[0].chips.isEmpty, "the Dafydd chip was retired first")
        #expect(capture.messages[1].chips.map(\.label) == ["Open in Family Tree: \(Self.richardSr)"])
    }

    // MARK: - GH #202: namesakes are different people (retire by id)
    //
    // Night hardening 2026-09-27 D1: the conversation moves from Mary
    // O'Connor (b. 1650) to Mary O'Connor (b. 1904). Same name, so the
    // name comparison retired nothing and the 1650 chip stayed live — a tap
    // opened the record the conversation had just moved away from. Same
    // class as the Dafydd miss, one step subtler.

    private static let mary = "Mary O'Connor"
    private static let mary1650ID = "@I1650@"
    private static let mary1904ID = "@I1904@"

    private func maryAnswer(born year: Int, id: String?) -> Exec.Result {
        result(prose: "\(Self.mary) was born in \(year).", person: Self.mary,
               offers: id.map { [.openFamilyTreePerson(personID: $0, personName: Self.mary)] } ?? [])
    }

    @Test func aNamesakesChipIsRetiredWhenTheConversationSwitchesToTheOther() {
        let capture = Capture()
        capture.apply(response(maryAnswer(born: 1650, id: Self.mary1650ID)), question: "who was mary o'connor")
        #expect(capture.messages.count == 1)
        #expect(capture.messages[0].chips.count == 1)
        capture.apply(response(maryAnswer(born: 1904, id: Self.mary1904ID)),
                      question: "no, the mary o'connor born in 1904")
        #expect(capture.messages.count == 2)
        #expect(capture.messages[0].chips.isEmpty,
                Comment(rawValue: "stale 1650 chip still live: " + capture.messages[0].chips.map(\.label).joined(separator: " | ")))
        #expect(capture.messages[1].chips.map(\.action)
                == [.openFamilyTreePerson(personID: Self.mary1904ID, personName: Self.mary)],
                "the current answer's own chip is never touched")
    }

    /// The first Mary's id is remembered across an answer that names her
    /// without a tree chip (a catalog answer), so the later switch to the
    /// namesake still retires her chip.
    @Test func theSubjectsIDSurvivesAnAnswerThatNamesHerWithoutOne() {
        let capture = Capture()
        capture.apply(response(maryAnswer(born: 1650, id: Self.mary1650ID)), question: "who was mary o'connor")
        capture.apply(response(maryAnswer(born: 1650, id: nil)), question: "tell me more about her")
        #expect(capture.messages[0].chips.count == 1, "same person, nothing retired")
        capture.apply(response(maryAnswer(born: 1904, id: Self.mary1904ID)),
                      question: "the one born in 1904")
        #expect(capture.messages[0].chips.isEmpty,
                Comment(rawValue: capture.messages[0].chips.map(\.label).joined(separator: " | ")))
        #expect(capture.messages[2].chips.count == 1)
    }

    /// The sink is told WHO by id, not just by name.
    @Test func theSinkReceivesTheSubjectsTreeID() {
        let capture = Capture()
        capture.apply(response(maryAnswer(born: 1650, id: Self.mary1650ID)), question: "who was mary o'connor")
        capture.apply(response(maryAnswer(born: 1904, id: Self.mary1904ID)), question: "the 1904 one")
        #expect(capture.retiredSubjects.last == .init(name: Self.mary, personID: Self.mary1904ID))
        #expect(capture.state.memory.lastSubjectPersonID == Self.mary1904ID)
    }

    /// Name fallback, unchanged: the same name with no id on the new
    /// answer cannot be told apart, so nothing is retired on a guess.
    @Test func theSameNameWithoutAnIDRetiresNothing() {
        let capture = Capture()
        capture.apply(response(maryAnswer(born: 1650, id: Self.mary1650ID)), question: "who was mary o'connor")
        let before = capture.retired.count
        capture.apply(response(maryAnswer(born: 1904, id: nil)), question: "and the other one")
        #expect(capture.retired.count == before)
        #expect(capture.messages[0].chips.count == 1)
    }

    @Test func idsDecideWhenBothAreKnownNamesOtherwise() {
        typealias Subject = HallieSupersededOffers.Subject
        let open1650 = ArchivistMessage.Chip(
            label: "Open in Family Tree: \(Self.mary)",
            action: .openFamilyTreePerson(personID: Self.mary1650ID, personName: Self.mary))
        let openByName = ArchivistMessage.Chip(
            label: "Open in Family Tree: \(Self.mary)", action: .openFamilyTree(personName: Self.mary))
        // Namesakes by id.
        #expect(HallieSupersededOffers.isSuperseded(open1650, by: Subject(name: Self.mary, personID: Self.mary1904ID)))
        #expect(!HallieSupersededOffers.isSuperseded(open1650, by: Subject(name: Self.mary, personID: Self.mary1650ID)))
        // One record under another spelling is the same person.
        #expect(!HallieSupersededOffers.isSuperseded(open1650, by: Subject(name: "Mary Connor", personID: Self.mary1650ID)))
        // No id on either side: by name, as before.
        #expect(!HallieSupersededOffers.isSuperseded(open1650, by: Subject(name: Self.mary)))
        #expect(!HallieSupersededOffers.isSuperseded(openByName, by: Subject(name: Self.mary, personID: Self.mary1904ID)))
        #expect(HallieSupersededOffers.isSuperseded(openByName, by: Subject(name: Self.richardSr, personID: Self.richardSrID)))
        #expect(!HallieSupersededOffers.isSuperseded(Self.breens, by: Subject(name: Self.mary, personID: Self.mary1904ID)))
    }

    /// Memory takes the id from the answer's own chip for exactly that
    /// name; two ids for one name (a which-one among namesakes) is no id.
    @Test func memoryTakesOnlyAnUnambiguousID() {
        let both = result(prose: "Which Mary O'Connor?", person: Self.mary,
                          offers: [.openFamilyTreePerson(personID: Self.mary1650ID, personName: Self.mary),
                                   .openFamilyTreePerson(personID: Self.mary1904ID, personName: Self.mary)])
        #expect(Exec.ConversationMemory.personID(of: Self.mary, offeredBy: both) == nil)
        let other = result(prose: "Richard …", person: Self.mary,
                           offers: [.openFamilyTreePerson(personID: Self.richardSrID, personName: Self.richardSr)])
        #expect(Exec.ConversationMemory.personID(of: Self.mary, offeredBy: other) == nil,
                "another person's chip is not the subject's id")
        #expect(Exec.ConversationMemory.personID(of: "mary o'connor", offeredBy: maryAnswer(born: 1904, id: Self.mary1904ID))
                == Self.mary1904ID)

        var memory = Exec.ConversationMemory()
        memory.record(intent: nil, result: maryAnswer(born: 1650, id: Self.mary1650ID))
        #expect(memory.lastSubjectPersonID == Self.mary1650ID)
        memory.record(intent: nil, result: maryAnswer(born: 1650, id: nil))
        #expect(memory.lastSubjectPersonID == Self.mary1650ID, "same name, no id: kept")
        memory.record(intent: nil, result: result(prose: "Richard …", person: Self.richardSr))
        #expect(memory.lastSubjectPersonID == nil, "another person with no id: the old id is dropped")
        memory.reset()
        #expect(memory.lastSubjectPersonID == nil)
    }

    /// SENSOR: the window hands the sink's Subject (id included) to the
    /// pure retire, and the commit compares Subjects, not bare names.
    @Test func theWindowAndCommitCompareSubjectsNotNames() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("VideoScan")
        let commit = try String(contentsOf: dir.appendingPathComponent("HallieResponseCommit.swift"), encoding: .utf8)
        #expect(commit.contains("var retireSupersededOffers: (HallieSupersededOffers.Subject) -> Void"))
        #expect(commit.contains("subject.isDifferentPerson(from: previousSubject ?? .init(name: \"\"))"))
        #expect(!commit.contains("PersonResolver.normalize(subject) != PersonResolver.normalize(previousSubject"),
                "the name-only comparison is gone")
        let window = try String(contentsOf: dir.appendingPathComponent("ArchivistChatWindow.swift"), encoding: .utf8)
        #expect(window.contains("messages = HallieSupersededOffers.retire(in: messages, keeping: subject)"))
    }
}
