// HallieBareNameRouteTests.swift
// GH #184 item 4 (live 2026-09-11 22:05Z): "hallie mae mcgill" went to a
// presence search and surfaced a video whose caption mentioned "Mae
// Mcgill"; "tell me about hallie mae mcgill" gave the biography. A bare
// utterance that is EXACTLY a known person's name opens the biography.
// LOGIC on a small tree + People tab; the exact oracle's negatives are the
// regression class (a name plus anything else keeps its road); SCALE on
// 20k synthetic profiles with a time budget.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
@Suite("A bare exact name opens the biography", .serialized)
struct HallieBareNameRouteTests {

    private static let tree = GedcomFamilyGraph(gedcomText: """
    0 HEAD
    0 @I1@ INDI
    1 NAME Hallie Mae /McGill/
    1 SEX F
    1 BIRT
    2 DATE 1876
    2 PLAC Stoughton, Massachusetts
    0 @I2@ INDI
    1 NAME Richard Harding /Breen/ Jr
    1 SEX M
    1 BIRT
    2 DATE 1959
    0 @I3@ INDI
    1 NAME Richard Harding /Breen/ Sr
    1 SEX M
    1 BIRT
    2 DATE 1933
    0 @I4@ INDI
    1 NAME John /Smith/
    1 SEX M
    1 BIRT
    2 DATE 1800
    0 @I5@ INDI
    1 NAME John /Smith/
    1 SEX M
    1 BIRT
    2 DATE 1850
    0 @I6@ INDI
    1 NAME Mary /English/
    1 SEX F
    1 BIRT
    2 DATE 1820
    0 TRLR
    """)

    private func context() -> HallieTurnExecutor.Context {
        .init(
            profiles: [
                .init(stableID: "donna", canonicalName: "Donna", aliases: ["Mom"]),
                .init(stableID: "rick", canonicalName: "Rick"),
            ],
            graph: Self.tree,
            speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae"))
    }

    private func pre(_ question: String, playAfterAnswer: Bool = false,
                     context: HallieTurnExecutor.Context) -> HallieTurnExecutor.PreTranslation {
        HallieTurnExecutor.preTranslation(
            question: question, playAfterAnswer: playAfterAnswer, memory: .init(),
            isKnownPerson: { HallieTurnExecutor.isKnownPerson($0, context: context) },
            isInnerCircleName: { HallieTurnExecutor.isInnerCircleName($0, context: context) },
            identity: HallieTurnExecutor.nameIdentity { context })
    }

    private func biographyIntent(_ pre: HallieTurnExecutor.PreTranslation) -> HallieTurnExecutor.Intent? {
        guard case .run(let intent) = pre, case .graph(let payload) = intent.ast,
              payload.operation == .biography else { return nil }
        return intent
    }

    // MARK: - The live miss

    @Test func aBareTreeNameOpensTheBiographyNotAVideoSearch() async throws {
        let context = context()
        for typed in ["hallie mae mcgill", "Hallie Mae McGill?", "  hallie mae mcgill.  "] {
            let intent = try #require(biographyIntent(pre(typed, context: context)), Comment(rawValue: typed))
            #expect(intent.originalQuestion == typed)
            let result = try await HallieTurnExecutor.execute(.init(intent: intent), context: context)
            #expect(result.route == .graph, Comment(rawValue: typed))
            #expect(result.outcome == .answered, Comment(rawValue: typed))
            #expect(result.prose.contains("Hallie Mae McGill"), Comment(rawValue: result.prose))
            #expect(!result.prose.lowercased().contains("video"), Comment(rawValue: result.prose))
        }
    }

    @Test func aPeopleTabNameOrAliasOpensTheBiography() throws {
        let context = context()
        for typed in ["donna", "Donna", "Mom", "rick"] {
            let intent = try #require(biographyIntent(pre(typed, context: context)), Comment(rawValue: typed))
            if case .graph(let payload) = intent.ast {
                #expect(payload.people == [typed.trimmingCharacters(in: .whitespaces)])
            }
        }
    }

    @Test func namesakesTakeTheBiographyRoadsWhichOneChips() async throws {
        let context = context()
        let intent = try #require(biographyIntent(pre("john smith", context: context)))
        let result = try await HallieTurnExecutor.execute(.init(intent: intent), context: context)
        #expect(result.route == .graph)
        #expect(result.outcome == .needsClarification)
        #expect(result.clarification?.candidates.count == 2)
    }

    @Test func generationalSuffixesAreToleratedTheWayTheBiographyRoadTolerates() async throws {
        let context = context()
        // Without a suffix: both Richards answer to it — the road asks.
        let both = try #require(biographyIntent(pre("richard harding breen", context: context)))
        let asks = try await HallieTurnExecutor.execute(.init(intent: both), context: context)
        #expect(asks.outcome == .needsClarification)
        #expect(asks.clarification?.candidates.count == 2)
        // With one (period tolerant): only Jr.
        let junior = try #require(biographyIntent(pre("Richard Harding Breen Jr.", context: context)))
        let one = try await HallieTurnExecutor.execute(.init(intent: junior), context: context)
        #expect(one.outcome == .answered, Comment(rawValue: one.prose))
        #expect(one.prose.contains("1959"), Comment(rawValue: one.prose))
    }

    // MARK: - What is NOT a bare name (the regression class)

    @Test(arguments: [
        "rick's family tree", "tim's brother", "videos of donna", "mae mcgill",
        "hallie", "english", "him", "show donna", "donna in 1994",
        "tell me about donna", "donna and rick", "hallie mae mcgill's mother",
        "", "   ", "?",
    ])
    func aNamePlusAnythingElseIsNotABareName(typed: String) {
        let context = context()
        #expect(HallieBareNameQuestion.detect(typed, isExactPersonName: {
            HallieTurnExecutor.isExactPersonName($0, context: context)
        }) == nil, Comment(rawValue: typed))
        #expect(biographyIntent(pre(typed, context: context))?.originalQuestion != typed
                || typed == "tell me about donna", Comment(rawValue: typed))
    }

    @Test func aNameWithExtraWordsKeepsThePresenceRoad() {
        // "mae mcgill" is not her whole name: the translator's presence
        // search, exactly as before (the live caption hit was for THIS).
        guard case .translate(let question, _) = pre("mae mcgill", context: context()) else {
            Issue.record("expected the translator for a partial name"); return
        }
        #expect(question == "mae mcgill")
    }

    @Test func theFamilyCardAndKinshipShapesAreNotRobbed() {
        let context = context()
        guard case .run(let tree) = pre("rick's family tree", context: context),
              case .graph(let payload) = tree.ast else {
            Issue.record("rick's family tree must stay the person-tree shape"); return
        }
        #expect(payload.operation == .familyTree)
        if case .run(let kin) = pre("tim's brother", context: context), case .graph(let payload) = kin.ast {
            #expect(payload.operation != .biography || payload.people != ["tim's brother"])
        }
    }

    @Test func aPeeledPlayVerbKeepsTheMediaRoad() {
        // The client arrives with playAfterAnswer after peeling "play":
        // "play donna" is a media ask, never a biography.
        #expect(biographyIntent(pre("donna", playAfterAnswer: true, context: context())) == nil)
    }

    // MARK: - The exact oracle

    @Test func theExactOracleAcceptsWholeNamesOnly() {
        let context = context()
        let exact = { HallieTurnExecutor.isExactPersonName($0, context: context) }
        #expect(exact("Hallie Mae McGill"))
        #expect(exact("hallie mae mcgill"))
        #expect(exact("Richard Harding Breen Jr."))
        #expect(exact("richard harding breen junior"))
        #expect(exact("richard harding breen"))
        #expect(exact("mary english"))
        #expect(exact("Donna"))
        #expect(exact("mom"))
        #expect(exact("rick"))
        // Subsets, surnames alone, diminutives and near misses are NOT exact.
        #expect(!exact("mae mcgill"))
        #expect(!exact("english"))
        #expect(!exact("hallie"))
        #expect(!exact("Richard H. Breen"))
        #expect(!exact("richard breen"))
        #expect(!exact("donna hudson"))
        #expect(!exact("john"))
        #expect(!exact(""))
    }

    @Test func theExactOracleWithoutSourcesAcceptsNothing() {
        let empty = HallieTurnExecutor.Context(profiles: nil, graph: nil)
        #expect(!HallieTurnExecutor.isExactPersonName("Donna", context: empty))
        #expect(HallieBareNameQuestion.detect("donna", isExactPersonName: { _ in false }) == nil)
    }

    // MARK: - Scale

    @Test func theExactOracleStaysCheapAcrossTwentyThousandProfiles() {
        let profiles = (0..<20_000).map {
            HallieTurnExecutor.ProfileSnapshot(
                stableID: "p\($0)", canonicalName: "Person \($0)", aliases: ["P\($0)", "Nick \($0)"])
        }
        let context = HallieTurnExecutor.Context(profiles: profiles, graph: Self.tree)
        // O(profiles) per ask by design (the live tab holds ~13); the budget
        // pins that a 20k tab still answers a turn's worth of asks in time.
        let start = Date()
        var hits = 0
        for i in stride(from: 0, to: 20_000, by: 2_000) {
            if HallieTurnExecutor.isExactPersonName("Person \(i)", context: context) { hits += 1 }
            if HallieTurnExecutor.isExactPersonName("Nobody \(i)", context: context) { hits += 1 }
        }
        #expect(hits == 10)
        #expect(Date().timeIntervalSince(start) < 2.0)
    }
}
