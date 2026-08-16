import Foundation
import Testing
@testable import VideoScan

struct ArchivistQueryPlannerTests {
    private let profiles = [
        POIProfile(name: "Daniel Breen", referencePath: "/synthetic/dan",
                   aliases: ["birthday boy", "Dan"]),
        POIProfile(name: "Matthew Breen", referencePath: "/synthetic/matt",
                   aliases: ["birthday boy", "Matt"]),
        POIProfile(name: "Richard Breen", referencePath: "/synthetic/rick",
                   aliases: ["Rick"]),
    ]

    @Test func canonicalAliasFlowsThroughProductionComposition() {
        let plan = ArchivistQueryPlanner.plan(
            question: "videos of Rick in 1998",
            spec: NLQuerySpec(people: ["Rick"], yearStart: 1998,
                              yearEnd: 1998),
            profiles: profiles,
            playAfterAnswer: false)
        #expect(plan == .search(
            query: "people:richard people:breen year:1998",
            isCount: false, preface: nil, playAfterAnswer: false))
    }

    @Test func countIntentSurvivesResolutionAndComposition() {
        let plan = ArchivistQueryPlanner.plan(
            question: "how many videos of Dan?",
            spec: NLQuerySpec(people: ["Dan"], intent: "COUNT"),
            profiles: profiles,
            playAfterAnswer: false)
        #expect(plan == .search(
            query: "people:daniel people:breen", isCount: true,
            preface: nil, playAfterAnswer: false))
    }

    @Test func aliasAmbiguityPreservesPendingPlayIntent() {
        let plan = ArchivistQueryPlanner.plan(
            question: "play birthday boy",
            spec: NLQuerySpec(people: ["birthday boy"]),
            profiles: profiles,
            playAfterAnswer: true)
        #expect(plan == .personAmbiguity(
            typedName: "birthday boy",
            candidates: ["Daniel Breen", "Matthew Breen"],
            playAfterAnswer: true))
    }

    @Test func unknownCorrectionPreservesPendingPlayIntent() {
        let plan = ArchivistQueryPlanner.plan(
            question: "play Alex",
            spec: NLQuerySpec(people: ["Alex"]),
            profiles: profiles,
            playAfterAnswer: true)
        #expect(plan == .unknownPerson(
            typedName: "Alex",
            knownNames: ["Daniel Breen", "Matthew Breen", "Richard Breen"],
            playAfterAnswer: true))
    }

    @Test func resolvedClarificationBypassesTheSameAmbiguousAlias() {
        let plan = ArchivistQueryPlanner.plan(
            question: "play birthday boy",
            spec: NLQuerySpec(people: ["birthday boy"]),
            profiles: profiles,
            resolvedPeople: ["Daniel Breen"],
            playAfterAnswer: true)
        #expect(plan == .search(
            query: "people:daniel people:breen", isCount: false,
            preface: nil, playAfterAnswer: true))
    }

    @Test func reciprocalAliasesContinueWithoutReenteringResolver() {
        let reciprocal = [
            POIProfile(name: "Tim", referencePath: "/synthetic/tim",
                       aliases: ["Timmy"]),
            POIProfile(name: "Timmy", referencePath: "/synthetic/timmy",
                       aliases: ["Tim"]),
        ]
        let spec = NLQuerySpec(people: ["Timmy"])
        #expect(ArchivistQueryPlanner.plan(
            question: "videos of Timmy", spec: spec, profiles: reciprocal,
            playAfterAnswer: false) == .personAmbiguity(
                typedName: "Timmy", candidates: ["Tim", "Timmy"],
                playAfterAnswer: false))

        let pending = ArchivistPersonClarification(
            question: "videos of Timmy", spec: spec,
            candidates: ["Tim", "Timmy"], playAfterAnswer: false)
        #expect(pending.classify("Timmy") == .select("Timmy"))
        #expect(ArchivistQueryPlanner.plan(
            question: pending.question, spec: pending.spec,
            profiles: reciprocal, resolvedPeople: ["Timmy"],
            playAfterAnswer: pending.playAfterAnswer) == .search(
                query: "people:timmy", isCount: false, preface: nil,
                playAfterAnswer: false))
    }

    @Test func clarificationReplyNeverGuessesBetweenTwoPeople() {
        let pending = ArchivistPersonClarification(
            question: "videos of Timmy", spec: NLQuerySpec(people: ["Timmy"]),
            candidates: ["Tim", "Timmy"], playAfterAnswer: true)
        #expect(pending.classify("yes") == .needsExplicitChoice)
        #expect(pending.classify("no") == .reject)
        #expect(pending.classify("Tim.") == .select("Tim"))
        #expect(pending.classify("I mean Timmy") == .select("Timmy"))
        #expect(pending.classify("yes, Timmy") == .select("Timmy"))
        #expect(pending.classify("Timmy please") == .select("Timmy"))
        #expect(pending.classify("show Christmas") == .newQuestion)

        let single = ArchivistPersonClarification(
            question: pending.question, spec: pending.spec,
            candidates: ["Timmy"], playAfterAnswer: false)
        #expect(single.classify("yes") == .select("Timmy"))
    }

    @Test func clarificationStateIsConsumedExactlyOnce() {
        let value = ArchivistPersonClarification(
            question: "videos of Timmy", spec: NLQuerySpec(people: ["Timmy"]),
            candidates: ["Tim", "Timmy"], playAfterAnswer: true)

        var pending: ArchivistPersonClarification? = value
        #expect(ArchivistPersonClarification.consume(&pending, reply: "yes")
                == .needsExplicitChoice)
        #expect(pending == value)

        #expect(ArchivistPersonClarification.consume(
            &pending, reply: "I mean Timmy") == .select("Timmy"))
        #expect(pending == nil)
        #expect(ArchivistPersonClarification.consume(&pending, reply: "Tim")
                == nil)
    }

    @Test func personClarificationChipsBypassTranslationAndAliasResolution() {
        let spec = NLQuerySpec(people: ["Timmy"], intent: "count")
        let pending = ArchivistPersonClarification(
            question: "how many videos of Timmy?", spec: spec,
            candidates: ["Tim", "Timmy"], playAfterAnswer: true)
        let chips = ArchivistMessage.personClarificationChips(for: pending)
        #expect(chips.map(\.label) == ["Tim", "Timmy"])

        for (chip, expected) in zip(chips, pending.candidates) {
            guard case .resolvedPeople(let question, let carriedSpec,
                                       let canonicalNames, let wantsPlay)
                    = chip.action else {
                Issue.record("person choice re-entered the ask/translator path")
                continue
            }
            #expect(question == pending.question)
            #expect(carriedSpec == spec)
            #expect(canonicalNames == [expected])
            #expect(wantsPlay)
        }
    }

    @Test func resolvedKinshipEvidenceGoesStraightToDeterministicPlanner() {
        let spec = ArchivistQueryPlanner.kinshipCatalogSpec(
            translated: NLQuerySpec(
                people: ["Rick"], yearStart: 1995, yearEnd: 1995,
                keywords: ["father at Christmas"], intent: "filter"),
            resolvedNames: ["Daniel Breen", "Matthew Breen"],
            relationWord: "father")
        // kinshipCatalogSpec uses the same fail-closed sanitizer as the
        // production query grammar, whose wire values are canonical lowercase.
        #expect(spec?.keywords == ["christmas"])
        guard let spec else {
            Issue.record("bounded resolved kinship names should prepare")
            return
        }
        let plan = ArchivistQueryPlanner.plan(
            question: "show videos of Rick's father at Christmas in 1995",
            spec: spec,
            profiles: profiles,
            resolvedPeople: spec.people,
            playAfterAnswer: true)

        #expect(plan == .search(
            query: "people:daniel people:breen people:matthew people:breen "
                + "year:1995 christmas",
            isCount: false, preface: nil, playAfterAnswer: true))
    }

    @Test func kinshipQuestionIntentIsClassifiedBeforeCatalogContinuation() {
        #expect(ArchivistQueryPlanner.kinshipContinuation(
            for: "Who was Rick's father?", matchedPhrase: "Rick's father",
            playAfterAnswer: false)
            == .factOnly)
        #expect(ArchivistQueryPlanner.kinshipContinuation(
            for: "When was Rick's father born?", matchedPhrase: "Rick's father",
            playAfterAnswer: false)
            == .birthDate)
        #expect(ArchivistQueryPlanner.kinshipContinuation(
            for: "When did Rick's father die?", matchedPhrase: "Rick's father",
            playAfterAnswer: false)
            == .deathDate)
        #expect(ArchivistQueryPlanner.kinshipContinuation(
            for: "Rick's father at Christmas", matchedPhrase: "Rick's father",
            playAfterAnswer: false)
            == .catalogSearch)
        #expect(ArchivistQueryPlanner.kinshipContinuation(
            for: "Do we have Rick's father at Christmas?",
            matchedPhrase: "Rick's father", playAfterAnswer: false)
            == .catalogSearch)
        #expect(ArchivistQueryPlanner.kinshipContinuation(
            for: "When did Rick's father appear?",
            matchedPhrase: "Rick's father", playAfterAnswer: false)
            == .catalogSearch)
    }

    @Test func tooManyResolvedKinshipNameTokensFailClosed() {
        let spec = ArchivistQueryPlanner.kinshipCatalogSpec(
            translated: NLQuerySpec(yearStart: 1995, yearEnd: 1995),
            resolvedNames: [
                "Daniel Joseph Breen", "Matthew Richard Breen",
                "Timothy Edward Breen",
            ],
            relationWord: "sons")
        #expect(spec == nil)
    }

    @Test func emptyTranslationUsesVisibleLiteralFallback() {
        let plan = ArchivistQueryPlanner.plan(
            question: "the red bicycle",
            spec: NLQuerySpec(), profiles: profiles,
            playAfterAnswer: false)
        #expect(plan == .search(
            query: "the red bicycle", isCount: false,
            preface: ArchivistQueryPlanner.literalFallbackPreface,
            playAfterAnswer: false))
    }

    @Test(.timeLimit(.minutes(1)))
    func oversizedPersonListRejectsWithinExplicitBudget() {
        let spec = NLQuerySpec(
            people: Array(repeating: "Rick", count: 100_000))
        let started = ContinuousClock.now
        let plan = ArchivistQueryPlanner.plan(
            question: "oversized", spec: spec, profiles: profiles,
            playAfterAnswer: true)
        let elapsed = started.duration(to: .now)

        #expect(plan == .tooManyPeople(limit: 6))
        #expect(elapsed < .milliseconds(100),
                "planner rejection exceeded 100 ms: \(elapsed)")
    }

    @Test func localClarificationCapturesAndDisarmsPlayLatch() {
        var pending = true
        let continuation = ArchivistPlayIntentPolicy.take(from: &pending)
        #expect(continuation)
        #expect(!pending)

        // Taking an already-disarmed latch cannot resurrect old intent.
        #expect(!ArchivistPlayIntentPolicy.take(from: &pending))
        #expect(!pending)
    }
}
