// HallieRepairTurnTests.swift
// Live miss #4 (2026-08-28, hallie-conversation-2026-08-28.jsonl seq 4–9):
// "Can you find the closest common ancestor between me (Rick) and Donna?"
// → "Which rick do you mean?" with ten medieval namesakes → Rick typed
// "you presented me a list of people born hundreds or years ago" → Hallie
// ran a presence search for the keyword "hundreds of years ago" and
// declined. A turn about the previous answer must never become a search.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Conversation repair turns are never searches")
struct HallieRepairTurnTests {
    typealias Exec = HallieTurnExecutor

    private static let originalAsk = "Can you find the closest common ancestor between me (Rick) and Donna?"
    private static let rickComplaint = "you presented me a list of people born hundreds or years ago"

    private var context: Exec.Context {
        .init(profiles: [.init(stableID: "rick", canonicalName: "Rick")],
              graph: GedcomFamilyGraph(gedcomText: "0 HEAD\n0 TRLR\n"),
              speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
    }

    /// The live list, verbatim, plus the two people Rick actually meant by
    /// "me (Rick)" — one from the tree, one from the People tab.
    private static func medievalCandidates(withRecent: Bool = true) -> [Exec.Candidate] {
        var list: [Exec.Candidate] = [
            .init(id: .gedcomPersonID("@I1@"), canonicalName: "Anne Bourchier, of Leighs", label: "Anne Bourchier, of Leighs (b. About 1568, d. About 29 January 1669)"),
            .init(id: .gedcomPersonID("@I2@"), canonicalName: "Catherine Auker", label: "Catherine Auker (b. 1374, d. 12 July 1441)"),
            .init(id: .gedcomPersonID("@I3@"), canonicalName: "Catherine Cutherey", label: "Catherine Cutherey (b. July 1410, d. 17 July 1460)"),
            .init(id: .gedcomPersonID("@I4@"), canonicalName: "Elizabeth Mayne", label: "Elizabeth Mayne (b. 1440, d. 1525)"),
            .init(id: .gedcomPersonID("@I5@"), canonicalName: "Joan Dingley", label: "Joan Dingley (b. 1472, d. 12 June 1567)"),
            .init(id: .gedcomPersonID("@I6@"), canonicalName: "John De Holbrook V", label: "John De Holbrook V (b. about 1410, d. 12 July 1443)"),
            .init(id: .gedcomPersonID("@I7@"), canonicalName: "Richard", label: "Richard (b. 1370)"),
            .init(id: .gedcomPersonID("@I8@"), canonicalName: "Richard Cholmeley", label: "Richard Cholmeley (b. 1516, d. 17 May 1583)"),
            .init(id: .gedcomPersonID("@I9@"), canonicalName: "Richard Piell", label: "Richard Piell (b. 1350, d. 1400)"),
            .init(id: .gedcomPersonID("@I10@"), canonicalName: "Robert de Cralle", label: "Robert de Cralle (b. 1334, d. 1367)"),
        ]
        if withRecent {
            list.append(.init(id: .gedcomPersonID("@I11@"), canonicalName: "Richard Breen Jr", label: "Richard Breen Jr (b. 1959)"))
            list.append(.init(id: .profileStableID("rick"), canonicalName: "Rick", label: "Rick"))
        }
        return list
    }

    private static let relationshipIntent = Exec.Intent(
        originalQuestion: originalAsk,
        ast: .graph(.init(people: ["rick", "donna"], operation: .relationship)),
        playAfterAnswer: false)

    /// Memory after the live which-one turn: the executor asked "Which rick
    /// do you mean?" with a clarification carrying the ORIGINAL intent.
    private func memoryAfterWhichOne(withRecent: Bool = true) -> Exec.ConversationMemory {
        let clarification = Exec.makeClarification(
            intent: Self.relationshipIntent, stage: .suggestedIdentity,
            candidates: Self.medievalCandidates(withRecent: withRecent), context: context)
        let asked = Exec.Result(
            route: .graph, outcome: .needsClarification,
            prose: "Which rick do you mean?",
            basisLine: "Basis: “rick” matches more than one stable identity; no family fact was selected.",
            queryDescription: "shape=graph operation=relationship person=rick,donna",
            citations: [], catalogPersonName: nil, clarification: clarification)
        var memory = Exec.ConversationMemory()
        memory.record(intent: Self.relationshipIntent, result: asked)
        // Then the translator failed on "the one born in 1959" (live seq 6–7):
        // a decline that ran nothing must not displace the original ask.
        memory.record(intent: nil, result: Exec.Result(
            route: .followUp, outcome: .declined,
            prose: "I heard you, but I couldn't turn that into a search I trust, even on a second try.",
            basisLine: "No catalog query or media action was performed.",
            queryDescription: nil, citations: [], catalogPersonName: nil),
            question: "the one born in 1959")
        return memory
    }

    private func pre(_ q: String, memory: Exec.ConversationMemory) -> Exec.PreTranslation {
        let context = self.context
        return Exec.preTranslation(
            question: q, playAfterAnswer: false, memory: memory,
            isKnownPerson: { _ in false },
            rosterAnswer: { Exec.PeopleTab.rosterAnswer(context: context) },
            lineageAnswer: { HallieLineageAnswer.answer($0, context: context) })
    }

    // MARK: The live miss

    @Test func ricksExactSentenceAfterTheMedievalWhichOneIsRepairedNotSearched() throws {
        let memory = memoryAfterWhichOne()
        #expect(memory.lastExchange?.question == Self.originalAsk, "the original ask survives the failed clarification reply")
        #expect(memory.lastExchange?.candidates.count == 12)

        guard case .answer(let r) = pre(Self.rickComplaint, memory: memory) else {
            Issue.record("the complaint was handed to the translator (a search)"); return
        }
        #expect(r.outcome == .repaired)
        #expect(r.route == .followUp)
        #expect(r.citations.isEmpty, "no catalog search")
        #expect(r.clarification == nil)
        #expect(r.prose.contains("You asked “\(Self.originalAsk)”"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("how the two are related"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("born centuries ago"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("Which one did you mean?"), Comment(rawValue: r.prose))
        // Narrowed to the People-tab profile first, then the recent tree birth;
        // none of the medieval names is offered again.
        #expect(r.offeredActions == [
            .ask(question: "Rick", label: "Rick"),
            .ask(question: "Richard Breen Jr (b. 1959)", label: "Richard Breen Jr (b. 1959)"),
        ])
        for medieval in ["Catherine Auker", "Robert de Cralle", "Richard Piell", "1374", "1334"] {
            #expect(!r.prose.contains(medieval), "medieval candidate still offered: \(medieval)")
        }
        #expect(r.queryDescription == "repair: which-one narrowed 12→2 (recent)")
        #expect(r.basisLine.contains("no catalog query, tree lookup, or model call"))
        // The chip text is a candidate label, so the still-pending which-one
        // selects it exactly (window / shell / web keep the clarification).
        let candidates = Self.medievalCandidates()
        #expect(Exec.clarificationSelection("Richard Breen Jr (b. 1959)", from: candidates) == .gedcomPersonID("@I11@"))
        #expect(Exec.clarificationSelection("the one born in 1959", from: candidates) == .gedcomPersonID("@I11@"))
    }

    @Test func noRecentCandidateIsSaidHonestlyAndTheAskIsReoffered() throws {
        let memory = memoryAfterWhichOne(withRecent: false)
        guard case .answer(let r) = pre(Self.rickComplaint, memory: memory) else {
            Issue.record("expected a repair"); return
        }
        #expect(r.outcome == .repaired)
        #expect(r.prose.contains("Everyone I offered was born centuries ago"), Comment(rawValue: r.prose))
        #expect(r.offeredActions.first == .ask(question: Self.originalAsk, label: "Ask again: Can you find the closest common ancestor…"))
        #expect(r.queryDescription == "repair: which-one had no recent candidate (10 offered)")
    }

    @Test func noIMeantTheLivingOneNarrowsTheSameWay() throws {
        guard case .answer(let r) = pre("no, I meant the living one", memory: memoryAfterWhichOne()) else {
            Issue.record("expected a repair"); return
        }
        #expect(r.outcome == .repaired)
        #expect(r.offeredActions.map(\.self) == [
            .ask(question: "Rick", label: "Rick"),
            .ask(question: "Richard Breen Jr (b. 1959)", label: "Richard Breen Jr (b. 1959)"),
        ])
    }

    @Test func thatsWrongAfterAWhichOneReoffersTheListProfilesFirst() throws {
        guard case .answer(let r) = pre("that's wrong", memory: memoryAfterWhichOne()) else {
            Issue.record("expected a repair"); return
        }
        #expect(r.outcome == .repaired)
        #expect(r.offeredActions.count == HallieRepairTurn.maximumChips)
        #expect(r.offeredActions.first == .ask(question: "Rick", label: "Rick"))
        #expect(r.queryDescription == "repair: which-one narrowed 12→4")
    }

    // MARK: No prior answer → normal routing

    @Test func theSameSentenceWithNothingToRepairRoutesNormally() {
        let turn = pre(Self.rickComplaint, memory: .init())
        if case .answer(let r) = turn {
            #expect(r.outcome != .repaired, "nothing to repair; must not claim a repair")
        }
        guard case .translate(let q, _) = turn else {
            Issue.record("expected normal (translate) routing, got \(turn)"); return
        }
        #expect(q == Self.rickComplaint)
    }

    // MARK: "that's wrong" after an answered turn

    @Test func thatsWrongAfterAnAnsweredTurnRestatesTheOriginalAsk() throws {
        let intent = Exec.Intent(
            originalQuestion: "when was Martha Lamson born",
            ast: .graph(.init(people: ["Martha Lamson"], operation: .birth)),
            playAfterAnswer: false)
        var memory = Exec.ConversationMemory()
        memory.record(intent: intent, result: Exec.Result(
            route: .graph, outcome: .answered,
            prose: "Martha Lamson was born in 1634 in Ipswich, Massachusetts.",
            basisLine: "Basis: family tree.", queryDescription: "shape=graph operation=birth",
            citations: [], catalogPersonName: "Martha Lamson"))
        guard case .answer(let r) = pre("that's wrong", memory: memory) else {
            Issue.record("expected a repair"); return
        }
        #expect(r.outcome == .repaired)
        #expect(r.route == .followUp)
        #expect(r.prose == "Sorry about that. You asked “when was Martha Lamson born”, and I took it as a question about when Martha Lamson was born. My answer was: “Martha Lamson was born in 1634 in Ipswich, Massachusetts.”. Tell me what was off — a different person, year, or place — or ask it another way and I'll look again.")
        #expect(r.offeredActions == [
            .ask(question: "when was Martha Lamson born", label: "Ask again: when was Martha Lamson born"),
            .ask(question: "help", label: "Show me what I can ask"),
        ])
        #expect(r.queryDescription == "repair: restated “when was Martha Lamson born”")
    }

    @Test func aRepairDoesNotDisplaceTheExchangeItRepairs() {
        var memory = memoryAfterWhichOne()
        guard case .answer(let r) = pre("that's wrong", memory: memory) else {
            Issue.record("expected a repair"); return
        }
        memory.record(intent: nil, result: r, question: "that's wrong")
        #expect(memory.lastExchange?.question == Self.originalAsk)
        // A second complaint still points at the same ask.
        guard case .answer(let again) = pre("that list is useless", memory: memory) else {
            Issue.record("expected a second repair"); return
        }
        #expect(again.prose.contains("You asked “\(Self.originalAsk)”"))
        // Small talk and help never become the exchange to repair.
        memory.record(intent: nil, result: Exec.commandResult(.help))
        #expect(memory.lastExchange?.question == Self.originalAsk)
        memory.reset()
        #expect(memory.lastExchange == nil)
    }

    // MARK: The detector's edges

    @Test(arguments: [
        "you presented me a list of people born hundreds or years ago",
        "those people are from the 1300s",
        "that's wrong",
        "that is not what I asked",
        "you gave me the wrong list",
        "no, I meant the living one",
        "why did you pick those?",
        "that list is useless",
        "Hallie, that's not right",
        "wrong",
    ])
    func repairTurnsAreDetected(text: String) {
        #expect(HallieRepairTurn.isRepair(text), Comment(rawValue: text))
    }

    @Test(arguments: [
        "people born hundreds of years ago in the tree",
        "who was born hundreds of years ago",
        "can you find richard breen jr family tree?",
        "show me the ones you listed",
        "who is the oldest person you know about",
        "can you show people born in the 1300s",
        "tell me about that one",
        "the one born in 1959",
        "no",
        "what did you find for Donna?",
        "Hi Hallie",
    ])
    func ordinaryQuestionsAreNotRepairs(text: String) {
        #expect(!HallieRepairTurn.isRepair(text), Comment(rawValue: text))
    }

    @Test func aFreshQuestionAboutOldPeopleRoutesNormallyEvenWithHistory() {
        let turn = pre("people born hundreds of years ago in the tree", memory: memoryAfterWhichOne())
        if case .answer(let r) = turn { #expect(r.outcome != .repaired) }
    }

    @Test func recentNarrowingKeepsProfilesAndRecentBirthsNewestFirst() {
        let list: [Exec.Candidate] = [
            .init(id: .gedcomPersonID("a"), canonicalName: "A", label: "A (b. 1374)"),
            .init(id: .gedcomPersonID("b"), canonicalName: "B", label: "B (b. 1931, d. 2001)"),
            .init(id: .gedcomPersonID("c"), canonicalName: "C", label: "C"),
            .init(id: .gedcomPersonID("d"), canonicalName: "D", label: "D (b. 1959)"),
            .init(id: .profileStableID("p"), canonicalName: "P", label: "P"),
        ]
        #expect(HallieRepairTurn.recentCandidates(list, cutoff: 1901).map(\.canonicalName) == ["P", "D", "B"])
        #expect(HallieRepairTurn.birthYear(of: list[1]) == 1931)
        #expect(HallieRepairTurn.birthYear(of: list[2]) == nil)
    }

    @Test func outcomeLabelForTheTranscriptLog() {
        #expect(Exec.label(Exec.Outcome.repaired) == "repaired")
    }
}
