// HalliePersonaQuestionTests.swift
// GH #184 item 5 (live 2026-09-11 22:05Z): "where were you born, hallie?"
// → route temporal, "I need to know who you mean — and which video". A life
// fact asked of Hallie herself, in the second person with no third party,
// is answered on the persona road with her namesake's biography offered.
// The negatives pin what the guard must NOT claim: a third party, the
// owner, a search or media word, a year, a request lead, and the
// capability / command questions that run ahead of it.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
@Suite("Second-person life facts go to the persona road", .serialized)
struct HalliePersonaQuestionTests {

    private static let tree = GedcomFamilyGraph(gedcomText: """
    0 HEAD
    0 @I1@ INDI
    1 NAME Hallie Mae /McGill/
    1 SEX F
    1 BIRT
    2 DATE 1876
    2 PLAC Stoughton, Massachusetts
    0 @I2@ INDI
    1 NAME Donna /Hudson/
    1 SEX F
    1 BIRT
    2 DATE 1959
    0 TRLR
    """)

    private func context(graph: GedcomFamilyGraph? = tree,
                         archivist: String? = "Hallie Mae") -> HallieTurnExecutor.Context {
        .init(
            profiles: [
                .init(stableID: "donna", canonicalName: "Donna", aliases: ["Mom"]),
                .init(stableID: "rick", canonicalName: "Rick"),
            ],
            graph: graph,
            speakers: .init(ownerName: "Rick Breen", archivistName: archivist))
    }

    private func detect(_ text: String, context: HallieTurnExecutor.Context) -> HalliePersonaQuestion.Ask? {
        HalliePersonaQuestion.detect(text, isInnerCircleName: {
            HallieTurnExecutor.isInnerCircleName($0, context: context)
        })
    }

    private func pre(_ question: String, context: HallieTurnExecutor.Context) -> HallieTurnExecutor.PreTranslation {
        HallieTurnExecutor.preTranslation(
            question: question, playAfterAnswer: false, memory: .init(),
            isKnownPerson: { HallieTurnExecutor.isKnownPerson($0, context: context) },
            isInnerCircleName: { HallieTurnExecutor.isInnerCircleName($0, context: context) },
            identity: HallieTurnExecutor.nameIdentity { context })
    }

    private func persona(_ pre: HallieTurnExecutor.PreTranslation) -> HallieTurnExecutor.Result? {
        guard case .answer(let result) = pre, result.route == .conversation,
              result.queryDescription?.hasPrefix("persona:") == true else { return nil }
        return result
    }

    // MARK: - The live miss

    @Test func whereWereYouBornHallieIsAnsweredFromHerRoleWithTheNamesakeOffered() throws {
        let context = context()
        let result = try #require(persona(pre("where were you born, hallie?", context: context)))
        #expect(result.outcome == .answered)
        #expect(result.queryDescription == "persona: birthplace")
        #expect(result.prose.contains("archivist"), Comment(rawValue: result.prose))
        #expect(result.prose.contains("named after Hallie Mae McGill"), Comment(rawValue: result.prose))
        #expect(result.offeredActions == [
            .ask(question: "tell me about Hallie Mae McGill", label: "Tell me about Hallie Mae McGill"),
        ])
        #expect(result.basisLine.contains("Hallie Mae McGill"))
        #expect(result.citations.isEmpty)
        #expect(result.composedBy == .template)
        #expect(result.answerPlan?.shape == .fixed)
    }

    @Test func theOfferedChipOpensTheNamesakesBiography() async throws {
        let context = context()
        let result = try #require(persona(pre("where were you born, hallie?", context: context)))
        guard case .ask(let question, _)? = result.offeredActions.first else {
            Issue.record("no chip"); return
        }
        guard case .run(let intent) = pre(question, context: context),
              case .graph(let payload) = intent.ast else {
            Issue.record("the chip must be a graph biography ask"); return
        }
        #expect(payload.operation == .biography)
        let biography = try await HallieTurnExecutor.execute(.init(intent: intent), context: context)
        #expect(biography.route == .graph)
        #expect(biography.outcome == .answered)
        #expect(biography.prose.contains("1876"), Comment(rawValue: biography.prose))
    }

    @Test func withoutANamesakeTheReplyStaysHonestAndOffersNothing() throws {
        let context = context(graph: nil)
        let result = try #require(persona(pre("when were you born?", context: context)))
        #expect(result.queryDescription == "persona: birthdate")
        #expect(!result.prose.contains("named after"), Comment(rawValue: result.prose))
        #expect(result.offeredActions.isEmpty)
    }

    @Test(arguments: [
        ("where were you born, hallie?", HalliePersonaQuestion.Ask.birthplace),
        ("Hallie, where were you born", .birthplace),
        ("what town were you born in", .birthplace),
        ("when were you born", .birthdate),
        ("what year were you born hallie", .birthdate),
        ("when is your birthday", .birthdate),
        ("how old are you", .age),
        ("how old are you, hallie mae?", .age),
        ("when did you die", .death),
        ("are you still alive", .death),
        ("where are you from", .origin),
        ("where did you grow up, hallie", .origin),
        ("who was your father", .relatives("father")),
        ("who were your parents", .relatives("parents")),
        ("did you have children", .relatives("children")),
        ("did you have any kids", .relatives("kids")),
        ("who was your husband", .relatives("husband")),
        ("were you married", .relatives("husband")),
        ("what was your mother's job", .relatives("mother")),
        ("tell me about your family", .relatives("family")),
        ("tell me where you were born", .birthplace),
        ("can you tell me when you were born", .birthdate),
    ])
    func lifeFactsAskedOfHallieAreDetected(text: String, ask: HalliePersonaQuestion.Ask) {
        #expect(detect(text, context: context()) == ask, Comment(rawValue: text))
    }

    // MARK: - What stays out

    @Test(arguments: [
        // A third party: temporal / presence questions about real people.
        "how old was Donna in this video",
        "how old was donna in this video",
        "where were you and Donna in 1994",
        "where were you and donna in 1994",
        "when was Donna born",
        "where was Hallie Mae McGill born",
        "how old was Rick when Donna was born",
        // The owner: the relationship road.
        "how am I related to you",
        "how are you related to me",
        "where was my dad born",
        // Requests, search and media words, years.
        "can you tell me about Donna's childhood",
        "do you know where donna was born",
        "did you find any videos of my friend",
        "show me videos of you as a kid",
        "what videos do you have from 1994",
        // Capability and commands run ahead and keep their questions.
        "what can you do",
        "who are you, hallie",
        "how are you",
        // Not a life fact at all.
        "what do you think about the weather",
        "where were you when the moon landing happened",
        "",
    ])
    func thirdPartiesTheOwnerRequestsAndArchiveCuesAreNotPersonaQuestions(text: String) {
        let context = context()
        #expect(detect(text, context: context) == nil, Comment(rawValue: text))
        #expect(persona(pre(text, context: context)) == nil, Comment(rawValue: text))
    }

    @Test func aThirdPartyWithYouAndAYearKeepsThePresenceRoad() {
        // Decision (GH #184 item 5): "where were you and Donna in 1994" is
        // an archive question — Donna and the year make it one — so it goes
        // on to the translator as before; the presence route already drops
        // the speaker pronouns from its people list, so the search is for
        // Donna in 1994. Nothing here binds "you" to the owner.
        guard case .translate(let question, _) = pre("where were you and Donna in 1994", context: context()) else {
            Issue.record("expected the translator"); return
        }
        #expect(question == "where were you and Donna in 1994")
    }

    @Test func howOldWasDonnaInThisVideoStaysTemporal() {
        // No selection in this fixture, so the words go to the translator
        // (which reads them as an age ask); the point is that the persona
        // road never touches a question with a real person in it.
        let context = context()
        if case .answer(let result) = pre("how old was Donna in this video", context: context) {
            #expect(result.route != .conversation)
        }
    }

    @Test func whatCanYouDoStillHitsTheCapabilityReply() {
        guard case .answer(let result) = pre("what can you do", context: context()) else {
            Issue.record("what can you do must be answered locally"); return
        }
        #expect(result.route == .help || result.route == .capability, Comment(rawValue: "\(result.route)"))
    }

    @Test func theReplyUsesTheConfiguredArchivistName() {
        let result = HalliePersonaQuestion.answer(.age, archivistName: "Injected Hallie", namesake: nil)
        #expect(result.prose.contains("I'm Injected Hallie, the family's archivist"))
        let fallback = HalliePersonaQuestion.answer(.age, archivistName: nil, namesake: nil)
        #expect(fallback.prose.contains("I'm Hallie Mae, the family's archivist"))
    }

    @Test func theNamesakeResolvesThroughHerNameLadderOnlyWhenUnique() {
        // "Hallie Mae" is not her whole tree name; "Hallie" alone names
        // exactly one person in this tree — the ladder's last rung.
        #expect(HallieTurnExecutor.archivistNamesake(context: context()) == "Hallie Mae McGill")
        // A pinned tree spelling wins outright.
        let pinned = HallieTurnExecutor.Context(
            profiles: [], graph: Self.tree,
            speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie",
                            archivistPersonName: "Hallie Mae McGill"))
        #expect(HallieTurnExecutor.archivistNamesake(context: pinned) == "Hallie Mae McGill")
        // Two Hallie Maes: no rung is unique, no namesake is claimed.
        let twoHallies = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Hallie Mae /McGill/
        1 SEX F
        0 @I2@ INDI
        1 NAME Hallie Mae /Breen/
        1 SEX F
        0 TRLR
        """)
        let ambiguous = HallieTurnExecutor.Context(
            profiles: [], graph: twoHallies,
            speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae"))
        #expect(HallieTurnExecutor.archivistNamesake(context: ambiguous) == nil)
        #expect(HallieTurnExecutor.archivistNamesake(context: context(graph: nil)) == nil)
    }

    @Test func withoutTheIdentityOraclesTheStepIsSkipped() {
        // Older callers that pass no `identity` keep the old road exactly.
        let context = context()
        let pre = HallieTurnExecutor.preTranslation(
            question: "where were you born, hallie?", playAfterAnswer: false, memory: .init(),
            isKnownPerson: { HallieTurnExecutor.isKnownPerson($0, context: context) },
            isInnerCircleName: { HallieTurnExecutor.isInnerCircleName($0, context: context) })
        #expect(persona(pre) == nil)
    }
}
