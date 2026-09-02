// LifeStatusTests.swift
// Rick, 2026-09-01: "should not speak of people in the catalog like me,
// donna, tim, beth … in the past tense like 'rick was …' — it makes it
// sound like he's passed on. Dad and Ma Breen are passed on as can be seen
// in the bio data; anyone in the family tree above them can be assumed
// passed-on."
//
// One rule (LifeStatus) decides living / passed on; the biography card,
// the composer prompt, the verifier and the research privacy guard all
// read it. These tests pin the rule on a synthetic tree, the card's tense
// for a living subject (and the UNCHANGED past tense for an ancestor), the
// verifier's rejection of "Rick was a …" for a living subject, and the
// kinship overlay carrying the subject's status. Pure: no files, no model.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let treeText = """
0 HEAD
0 @I1@ INDI
1 NAME Rick /Breen/
1 SEX M
1 BIRT
2 DATE 4 MAR 1959
1 FAMC @F1@
1 FAMS @F2@
0 @I2@ INDI
1 NAME Dad /Breen/
1 SEX M
1 BIRT
2 DATE 22 FEB 1929
1 DEAT
2 DATE 1 JUL 2008
1 FAMS @F1@
0 @I3@ INDI
1 NAME Ma /Breen/
1 SEX F
1 BIRT
2 DATE 31 AUG 1930
1 DEAT
2 DATE 2023
1 FAMS @F1@
0 @I4@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 BIRT
2 DATE 4 AUG 1959
1 FAMS @F2@
0 @I5@ INDI
1 NAME Dan /Breen/
1 SEX M
1 FAMC @F2@
0 @I6@ INDI
1 NAME Old /Ancestor/
1 SEX M
1 BIRT
2 DATE 1900
0 @I7@ INDI
1 NAME Undated /Ancestor/
1 SEX M
1 FAMS @F3@
0 @I8@ INDI
1 NAME Dead /Child/
1 SEX F
1 DEAT
2 DATE 1950
1 FAMC @F3@
0 @I9@ INDI
1 NAME Undated /Offspring/
1 SEX F
1 FAMC @F4@
0 @I10@ INDI
1 NAME Old /Parent/
1 SEX M
1 BIRT
2 DATE 1850
1 FAMS @F4@
0 @I11@ INDI
1 NAME Undated /Widow/
1 SEX F
1 FAMS @F5@
0 @I12@ INDI
1 NAME Dead /Spouse/
1 SEX M
1 DEAT
2 DATE 1900
1 FAMS @F5@
0 @I13@ INDI
1 NAME Isolated /Stub/
0 @I14@ INDI
1 NAME Living /Widow/
1 SEX F
1 BIRT
2 DATE 1959
1 FAMS @F6@
0 @I15@ INDI
1 NAME Late /Spouse/
1 SEX M
1 BIRT
2 DATE 1958
1 DEAT
2 DATE 2020
1 FAMS @F6@
0 @F1@ FAM
1 HUSB @I2@
1 WIFE @I3@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I1@
1 WIFE @I4@
1 CHIL @I5@
0 @F3@ FAM
1 HUSB @I7@
1 CHIL @I8@
0 @F4@ FAM
1 HUSB @I10@
1 CHIL @I9@
0 @F5@ FAM
1 HUSB @I12@
1 WIFE @I11@
0 @F6@ FAM
1 HUSB @I15@
1 WIFE @I14@
0 TRLR
"""

private func graph() -> GedcomFamilyGraph { GedcomFamilyGraph(gedcomText: treeText) }
private func person(_ id: String) -> GedcomFamilyGraph.Person { graph().people[id]! }
/// A fixed clock so "100 years ago" is 1926 whatever day the suite runs.
private let now: Date = {
    var parts = DateComponents()
    parts.year = 2026; parts.month = 9; parts.day = 1
    return Calendar(identifier: .gregorian).date(from: parts)!
}()
private func status(_ id: String, withGraph: Bool = true) -> LifeStatus {
    LifeStatus.of(person(id), in: withGraph ? graph() : nil, now: now,
                  calendar: Calendar(identifier: .gregorian))
}

@Suite("LifeStatus — the one living / passed-on rule")
struct LifeStatusRuleTests {

    @Test func recordedDeathIsDeceased() {
        #expect(status("@I2@") == .deceased)
        #expect(status("@I2@", withGraph: false) == .deceased)
        #expect(LifeStatus.hasRecordedDeath(person("@I2@")))
        #expect(!LifeStatus.hasRecordedDeath(person("@I1@")))
    }

    @Test func bornAHundredYearsAgoIsPresumedDeceased() {
        #expect(LifeStatus.presumedLivingYears == 100)
        #expect(status("@I6@") == .presumedDeceased)
        #expect(status("@I6@", withGraph: false) == .presumedDeceased, "record alone is enough")
    }

    /// Rick's rule: anyone above someone who has passed on has passed on.
    @Test func ancestorOfTheDeceasedIsPresumedDeceased() {
        #expect(status("@I7@") == .presumedDeceased)
        #expect(status("@I7@", withGraph: false) == .living, "the record alone cannot tell")
    }

    @Test func childOfSomeoneBornLongAgoIsPresumedDeceased() {
        #expect(status("@I9@") == .presumedDeceased)
    }

    @Test func spouseOfSomeoneLongDeadIsPresumedDeceased() {
        #expect(status("@I11@") == .presumedDeceased)
    }

    @Test func theContemporaryFamilyIsLiving() {
        #expect(status("@I1@") == .living, "Rick, born 1959, parents both passed on")
        #expect(status("@I4@") == .living, "Donna, born 1959")
        #expect(status("@I5@") == .living, "an undated child of living parents")
        #expect(status("@I14@") == .living, "a widow born 1959 whose husband died recently")
        #expect(status("@I1@").isLiving)
        #expect(!status("@I2@").isLiving)
    }

    @Test func anIsolatedUndatedRecordIsLivingByRule() {
        #expect(status("@I13@") == .living)
    }

    @Test func peopleTabProfileIsLivingUnlessADeathIsRecorded() {
        var rick = POIProfile(name: "Rick", referencePath: "")
        #expect(LifeStatus.of(profile: rick) == .living)
        rick.deathdate = now
        #expect(LifeStatus.of(profile: rick) == .deceased)
        // A pinned tree record's verdict comes through when the profile
        // records no death (Dad's profile pinned to his record).
        #expect(LifeStatus.ofProfile(deathdate: nil, bridged: person("@I2@"), in: graph(),
                                     now: now) == .deceased)
        #expect(LifeStatus.ofProfile(deathdate: nil, bridged: person("@I1@"), in: graph(),
                                     now: now) == .living)
    }

    @Test func researchPrivacyGuardReadsTheSameRule() {
        #expect(ResearchEligibility.presumedLivingYears == LifeStatus.presumedLivingYears)
        guard case .refused(let reason) = ResearchEligibility.evaluate(person("@I1@"), now: now) else {
            Issue.record("Rick must be refused"); return
        }
        #expect(reason.contains("presumed living"))
        // The record alone still refuses the undated ancestor (no dates);
        // with the graph the family settles it and research is allowed.
        guard case .refused = ResearchEligibility.evaluate(person("@I7@"), now: now) else {
            Issue.record("record-only verdict must stay refused"); return
        }
        guard case .eligible = ResearchEligibility.evaluate(person("@I7@"), graph: graph(), now: now) else {
            Issue.record("an ancestor of the deceased is researchable"); return
        }
    }
}

@Suite("LifeStatus — biography card tense")
struct LifeStatusBiographyCardTests {

    @Test func livingSubjectIsSpokenOfInThePresentTense() {
        let card = HallieBiographyCard.card(for: person("@I1@"), in: graph())
        #expect(card.lifeStatus == .living)
        #expect(card.plan.subjectLifeStatus == .living)
        #expect(card.prose.hasPrefix("Rick Breen was born 4 March 1959. "), "a birth stays in the past")
        #expect(card.prose.contains("He is the child of Dad Breen and Ma Breen."), Comment(rawValue: card.prose))
        #expect(card.prose.contains("He is married to Donna Hudson."), Comment(rawValue: card.prose))
        #expect(card.prose.contains("He has 1 recorded child, Dan Breen."), Comment(rawValue: card.prose))
        #expect(!card.prose.contains(" was the child"))
        #expect(!card.prose.contains(" was married"))
        #expect(!card.prose.contains(" had "))
    }

    @Test func livingSubjectWhoseSpouseHasPassedOnKeepsThatMarriageInThePast() {
        let card = HallieBiographyCard.card(for: person("@I14@"), in: graph())
        #expect(card.lifeStatus == .living)
        #expect(card.prose.contains("She was married to Late Spouse."), Comment(rawValue: card.prose))
    }

    /// The departed keep exactly the wording they had — no ancestor prose
    /// changes (HallieBiographyCardTests pins Matthew Rice's whole card).
    @Test func ancestorProseIsUnchanged() {
        let card = HallieBiographyCard.card(for: person("@I2@"), in: graph())
        #expect(card.lifeStatus == .deceased)
        #expect(card.plan.subjectLifeStatus == .deceased)
        #expect(card.prose
                == "Dad Breen was born 22 February 1929 and died 1 July 2008. "
                    + "He was married to Ma Breen. "
                    + "He had 1 recorded child, Rick Breen. "
                    + "His family tree includes 2 recorded descendants across 2 generations.")
    }

    @Test func aVerdictPassedInByTheExecutorWins() {
        // The People-tab profile recorded a death the tree does not have.
        let card = HallieBiographyCard.card(for: person("@I1@"), in: graph(), lifeStatus: .deceased)
        #expect(card.prose.contains("He was married to Donna Hudson."))
        #expect(card.plan.subjectLifeStatus == .deceased)
    }

    @Test func marriageClauseSplitsPresentAndPast() {
        let marriages = graph().marriages(of: person("@I1@"))
        #expect(HallieBiographyCard.marriageClause(marriages) == "was married to Donna Hudson")
        #expect(HallieBiographyCard.marriageClause(marriages, subjectLiving: true, spouseLiving: { _ in true })
                == "is married to Donna Hudson")
        #expect(HallieBiographyCard.marriageClause(marriages, subjectLiving: true, spouseLiving: { _ in false })
                == "was married to Donna Hudson")
    }
}

@Suite("LifeStatus — composer prompt and verifier")
struct LifeStatusCompositionTests {

    private func plan(_ life: LifeStatus?, subject: String = "Rick Breen") -> HallieAnswerPlan {
        HallieAnswerPlan(
            route: .graph, shape: .biography, subject: subject,
            claims: [
                .init(id: "c1", text: "\(subject) was born 4 March 1959.", evidenceIDs: ["@I1@"]),
                .init(id: "c2", text: "He is the child of Dad Breen and Ma Breen.", evidenceIDs: ["@I1@"]),
                .init(id: "c3", text: "He is married to Donna Hudson.", evidenceIDs: ["@I1@"]),
            ],
            fallbackText: "\(subject) was born 4 March 1959. He is the child of Dad Breen and Ma Breen.",
            subjectLifeStatus: life)
    }

    private func verify(_ text: String, _ life: LifeStatus?, subject: String = "Rick Breen")
        -> HallieCompositionVerifier.Verification {
        HallieCompositionVerifier.verify(text, plan: plan(life, subject: subject), personaName: "Hallie Mae")
    }

    @Test func promptTellsTheModelTheTense() {
        let living = HallieGroundedComposer.userPrompt(plan: plan(.living), history: [])
        #expect(living.contains("Subject is living: use the present tense"))
        let gone = HallieGroundedComposer.userPrompt(plan: plan(.presumedDeceased), history: [])
        #expect(gone.contains("Subject has passed on: use the past tense"))
        let unknown = HallieGroundedComposer.userPrompt(plan: plan(nil), history: [])
        #expect(!unknown.contains("Subject is living") && !unknown.contains("passed on"))
        #expect(HallieGroundedComposer.systemPrompt(personaName: "Hallie Mae").contains("Subject is living"))
    }

    @Test func verifierRejectsAFinishedLifeForALivingSubject() {
        let v = verify("Rick Breen was a software engineer [c2].", .living)
        #expect(v.kept.isEmpty)
        #expect(v.dropped.first?.reason == .finishedLifeForLiving)
        for text in [
            "He was the child of Dad Breen and Ma Breen [c2].",
            "Rick Breen was married to Donna Hudson [c3].",
            "Dan, Mark, and Timmy were sons of Rick Breen [c2].",
            "Rick had four brothers [c2].",
            "He had 1 recorded child, Dan Breen [c2].",
        ] {
            #expect(verify(text, .living).dropped.first?.reason == .finishedLifeForLiving, Comment(rawValue: text))
        }
    }

    @Test func verifierKeepsABirthAndThePresentTense() {
        for text in [
            "Rick Breen was born 4 March 1959 [c1].",
            "Rick Breen was born and raised there [c1].",
            "He is the child of Dad Breen and Ma Breen [c2].",
            "Rick Breen is married to Donna Hudson [c1][c3].",
        ] {
            let v = verify(text, .living)
            #expect(v.dropped.isEmpty, Comment(rawValue: text + " → " + (v.dropped.first?.reason.rawValue ?? "")))
        }
    }

    @Test func verifierLeavesTheDepartedAndUnknownAlone() {
        for life in [LifeStatus.deceased, .presumedDeceased] {
            let v = verify("Rick Breen was married to Donna Hudson [c1][c3].", life)
            #expect(v.dropped.isEmpty, Comment(rawValue: life.rawValue))
        }
        #expect(verify("Rick Breen was married to Donna Hudson [c1][c3].", nil).dropped.isEmpty)
    }

    @Test func verifierKnowsTheSubjectsShortAndBridgedNames() {
        let v = verify("Rick was a Marine [c2].", .living,
                       subject: "Richard Harding Breen Jr (Rick in the People tab)")
        #expect(v.dropped.first?.reason == .finishedLifeForLiving)
        #expect(verify("Richard was a Marine [c2].", .living,
                       subject: "Richard Harding Breen Jr (Rick in the People tab)")
                .dropped.first?.reason == .finishedLifeForLiving)
    }

    @Test func aTemplatedResultCarriesItsVerdictIntoTheDerivedPlan() {
        let result = HallieTurnExecutor.Result(
            route: .graph, outcome: .answered,
            prose: "Rick's brothers: Tim.", basisLine: "Basis: fixture.",
            queryDescription: nil, citations: [], catalogPersonName: "Rick",
            subjectLifeStatus: .living)
        let derived = HallieAnswerPlan.derive(from: result)
        #expect(derived.subjectLifeStatus == .living)
        #expect(derived.isComposable)
        #expect(HallieAnswerPlan.derive(from: result.adding(attachments: [])).subjectLifeStatus == .living)
    }
}

@Suite("LifeStatus — People-tab kinship answers")
struct LifeStatusKinshipOverlayTests {

    private let rickID = UUID(), bethID = UUID(), ellenID = UUID(), timID = UUID()

    private func profiles(rickDeath: Date? = nil) -> [ArchivistGraphProfileSnapshot] {
        [
            .init(stableID: "rick", canonicalName: "Rick",
                  kinships: [
                    Kinship(relation: .sibling, relativeTo: .profile(id: bethID)),
                    Kinship(relation: .sibling, relativeTo: .profile(id: ellenID)),
                    Kinship(relation: .sibling, relativeTo: .profile(id: timID)),
                  ],
                  sex: .male, deathdate: rickDeath, uuid: rickID),
            .init(stableID: "beth", canonicalName: "Beth", sex: .female, uuid: bethID),
            // Ellen's sex was never recorded (the real gallery, 2026-08-31).
            .init(stableID: "ellen", canonicalName: "Ellen", sex: nil, uuid: ellenID),
            .init(stableID: "tim", canonicalName: "Tim", sex: .male, uuid: timID),
        ]
    }

    private func ask(_ relation: ArchivistGraphQuery.Relation,
                     rickDeath: Date? = nil) -> ArchivistGraphResult {
        ArchivistGraphExecutor.execute(
            .init(people: ["Rick"], operation: .kinship, relation: relation),
            inputs: .init(graph: GedcomFamilyGraph(gedcomText: "0 HEAD\n0 TRLR"),
                          profiles: profiles(rickDeath: rickDeath)))
    }

    /// "who are my brothers and sisters" reaches the executor as ONE
    /// question with relation `siblings`: both sexes, and a sibling whose
    /// sex is unrecorded is still listed (no sex filter on a neutral word).
    @Test func brothersAndSistersIsOneAnswerWithBothSexes() {
        let r = ask(.siblings)
        #expect(r.conclusion == .answered)
        #expect(r.prose == "Rick's siblings: Beth, Ellen, Tim.")
        #expect(r.subjectLifeStatus == .living, "Rick's profile records no death")
    }

    @Test func genderedWordsStillFailClosedOnAnUnrecordedSex() {
        #expect(ask(.brother).prose == "Rick's brother: Tim.")
        // Ellen's sex is unrecorded, so a GENDERED word leaves her out
        // without a word — the neutral "siblings" above is the one that
        // lists her. (Flagged for a follow-up: the "I can't tell" wording
        // only fires when there are NO hits at all.)
        #expect(ask(.sister).prose == "Rick's sister: Beth.")
    }

    @Test func aProfileWithARecordedDeathIsPassedOn() {
        #expect(ask(.siblings, rickDeath: Date()).subjectLifeStatus == .deceased)
    }
}
