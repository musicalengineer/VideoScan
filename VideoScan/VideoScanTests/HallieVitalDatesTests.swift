// HallieVitalDatesTests.swift
// Rick's brother caught it live, demo eve 2026-09-04: "tell me about Ma"
// (the family tree) and "how old is Ma" (the People profile) disagreed
// about the same woman's dates — 89 vs 92 at death. Same evening, same
// shape, on Dad. These tests pin the fix at the shared seam
// (HallieVitalDates) and at both of the routes that read it.

import Foundation
import Testing
@testable import VideoScan

@MainActor
@Suite("Hallie vital-date precedence (tree vs People profile)", .serialized)
struct HallieVitalDatesTests {

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: year, month: month, day: day,
            hour: 12))!
    }

    /// Rick's real Ma: profile says born 1933-08-31 / died 2023-06-01
    /// (age 89); the tree says born 31 August 1930 / died 3 March 2023
    /// (age 92). Rick has NOT said which is factually right — only that
    /// the bridged tree wins the spoken answer.
    private static let maTree = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Eileen /Latta/
    1 SEX F
    1 _FSFTID EILA-TA1
    1 BIRT
    2 DATE 31 AUG 1930
    1 DEAT
    2 DATE 3 MAR 2023
    0 TRLR
    """

    /// Rick's real Dad: profile says born 1929-02-21 / died 2008-06-25;
    /// the tree says born 22 February 1929 / died 22 June 2008.
    private static let dadTree = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Richard Harding /Breen/ Sr
    1 SEX M
    1 _FSFTID RHBS-R01
    1 BIRT
    2 DATE 22 FEB 1929
    1 DEAT
    2 DATE 22 JUN 2008
    0 TRLR
    """

    /// A bridged person whose tree record has no death date at all, only
    /// a birth — for rule 3 (tree wins for what it HAS; a field it lacks
    /// falls back to the profile).
    private static let noDeathInTree = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Aunt /Test/
    1 SEX F
    1 _FSFTID TEST-PN1
    1 BIRT
    2 DATE 15 MAR 1945
    0 TRLR
    """

    // MARK: - Rule 1: bridged, stores disagree → tree wins (both fields)

    @Test func bridgedPersonTreeWinsForBothBirthAndDeath() {
        let graph = GedcomFamilyGraph(gedcomText: Self.maTree)
        let resolved = HallieVitalDates.resolve(
            stableID: "ma", canonicalName: "Ma",
            treeIdentity: .familySearchID("EILA-TA1"),
            profileBirthdate: date(1933, 8, 31),
            profileDeathdate: date(2023, 6, 1),
            graph: graph)

        #expect(resolved.birthdate?.date == date(1930, 8, 31))
        #expect(resolved.birthdate?.provenance == .gedcomTree(personID: "@I1@"))
        #expect(resolved.deathdate?.date == date(2023, 3, 3))
        #expect(resolved.deathdate?.provenance == .gedcomTree(personID: "@I1@"))
    }

    @Test func bridgedPersonTreeWinsOnDadToo() {
        let graph = GedcomFamilyGraph(gedcomText: Self.dadTree)
        let resolved = HallieVitalDates.resolve(
            stableID: "dad", canonicalName: "Dad",
            treeIdentity: .familySearchID("RHBS-R01"),
            profileBirthdate: date(1929, 2, 21),
            profileDeathdate: date(2008, 6, 25),
            graph: graph)

        #expect(resolved.birthdate?.date == date(1929, 2, 22))
        #expect(resolved.deathdate?.date == date(2008, 6, 22))
    }

    // MARK: - Rule 2: unbridged → profile date, unchanged (Tim)

    @Test func unbridgedProfileUsesItsOwnDateUnchanged() {
        // No treeIdentity at all, and — separately — a tree installed
        // that has nothing to say about this stableID either way; both
        // must behave identically to "no tree installed".
        let graph = GedcomFamilyGraph(gedcomText: Self.maTree)
        for installedGraph: GedcomFamilyGraph? in [nil, graph] {
            let resolved = HallieVitalDates.resolve(
                stableID: "tim", canonicalName: "Tim",
                treeIdentity: nil,
                profileBirthdate: date(1960, 6, 21),
                profileDeathdate: nil,
                graph: installedGraph)
            #expect(resolved.birthdate?.date == date(1960, 6, 21))
            #expect(resolved.birthdate?.provenance == .poiProfile(profileID: "tim"))
            #expect(resolved.deathdate == nil)
        }

        // Confirmed live via the age route itself: "Tim is 66 today".
        let subject = ArchivistTemporalSubjectSnapshot(
            stableID: "tim", canonicalName: "Tim", birthdate: date(1960, 6, 21))
        let result = ArchivistTemporalExecutor.executePresentAge(
            .init(subject: "Tim", operation: .age, reference: .currentSelection),
            subject: .resolved(requested: "Tim", subject: subject),
            now: date(2026, 9, 4))
        #expect(result.prose == "Tim is 66 today — born 21 June 1960.")
    }

    // MARK: - Rule 3: bridged, tree lacks a field → falls back to profile

    /// My ruling: a tree bridge means the tree is authoritative for what
    /// it HAS. The tree here has a birth but no death at all; the
    /// profile's own death is not something the tree contradicts — it is
    /// the only evidence for that field — so it is used exactly as an
    /// unbridged profile's would be, and the birthdate still comes from
    /// the tree because the tree DOES have one.
    @Test func bridgedPersonFallsBackToProfileForAFieldTheTreeLacks() {
        let graph = GedcomFamilyGraph(gedcomText: Self.noDeathInTree)
        let resolved = HallieVitalDates.resolve(
            stableID: "aunt-test", canonicalName: "Aunt Test",
            treeIdentity: .familySearchID("TEST-PN1"),
            profileBirthdate: date(1946, 1, 1), // deliberately different from the tree's
            profileDeathdate: date(2020, 1, 10),
            graph: graph)

        // Birth: tree HAS it → tree wins, even though the profile disagrees.
        #expect(resolved.birthdate?.date == date(1945, 3, 15))
        #expect(resolved.birthdate?.provenance == .gedcomTree(personID: "@I1@"))
        // Death: tree LACKS it entirely → falls back to the profile.
        #expect(resolved.deathdate?.date == date(2020, 1, 10))
        #expect(resolved.deathdate?.provenance == .poiProfile(profileID: "aunt-test"))
    }

    /// The same rule 3 fallback, exercised through `HallieBiographyCard`
    /// as the biography route actually calls it: the tree's own missing
    /// raw death string, not `HallieVitalDates`, is what
    /// `HallieBiographyCard` tests directly — the fallback `Date` it is
    /// handed is only spoken when the tree said nothing.
    @Test func biographyRouteSpeaksTheProfileFallbackWhenTheTreeHasNoDeath() {
        let graph = GedcomFamilyGraph(gedcomText: Self.noDeathInTree)
        let person = graph.person(familySearchID: "TEST-PN1")!
        let resolved = HallieVitalDates.resolve(
            stableID: "aunt-test", canonicalName: "Aunt Test",
            treeIdentity: .familySearchID("TEST-PN1"),
            profileBirthdate: date(1946, 1, 1),
            profileDeathdate: date(2020, 1, 10),
            graph: graph)
        let (answer, _, _) = HallieBiographyCard.answer(
            for: person, in: graph,
            fallbackBirthdate: resolved.birthdate?.date,
            fallbackDeathdate: resolved.deathdate?.date)

        // Birth is the tree's own (15 March 1945), never the profile's
        // conflicting one (1946); death is the profile's fallback,
        // because the tree recorded no death at all.
        #expect(answer.text.contains("15 March 1945"))
        #expect(answer.text.contains("10 January 2020"))
        #expect(!answer.text.contains("1946"))
    }

    // MARK: - Rule 4: disagreement logged once, not per turn

    @Test func disagreementIsLoggedOnceNotPerTurn() {
        let graph = GedcomFamilyGraph(gedcomText: Self.maTree)
        // A stableID unique to this test so the process-lifetime log
        // cannot be polluted by, or mistaken for, another test's key.
        let stableID = "disagreement-once-\(UUID().uuidString)"
        let key = stableID + ".birthdate"
        #expect(!HallieVitalDates.loggedDisagreementKeysForTesting.contains(key))

        for _ in 0..<3 {
            _ = HallieVitalDates.resolve(
                stableID: stableID, canonicalName: "Test Subject",
                treeIdentity: .familySearchID("EILA-TA1"),
                profileBirthdate: date(1933, 8, 31), // disagrees with the tree's 1930-08-31
                profileDeathdate: nil,
                graph: graph)
        }

        // The Set can only ever hold the key once; three calls that each
        // saw a genuine disagreement still result in exactly one entry —
        // which is what makes `logOnce` fire the underlying `os_log` call
        // at most once for this person+field, ever.
        #expect(HallieVitalDates.loggedDisagreementKeysForTesting.contains(key))
    }

    @Test func agreeingStoresNeverLogADisagreement() {
        let graph = GedcomFamilyGraph(gedcomText: Self.maTree)
        let stableID = "no-disagreement-\(UUID().uuidString)"
        _ = HallieVitalDates.resolve(
            stableID: stableID, canonicalName: "Test Subject",
            treeIdentity: .familySearchID("EILA-TA1"),
            profileBirthdate: date(1930, 8, 31), // agrees with the tree
            profileDeathdate: date(2023, 3, 3), // agrees with the tree
            graph: graph)
        #expect(!HallieVitalDates.loggedDisagreementKeysForTesting.contains(stableID + ".birthdate"))
        #expect(!HallieVitalDates.loggedDisagreementKeysForTesting.contains(stableID + ".deathdate"))
    }

    // MARK: - Sensor: the two routes must never again disagree

    /// Demo eve 2026-09-04, in front of Rick's brother: "tell me about Ma"
    /// (biography, reading the tree) and "how old is Ma" (temporal,
    /// reading the People profile) gave 89 and 92 for the same woman's
    /// age at death — same shape on Dad. This sensor runs BOTH real
    /// composers (`ArchivistTemporalExecutor.executePresentAge` and
    /// `HallieBiographyCard.answer`) from the SAME `HallieVitalDates`
    /// resolution and pins that they now state the same dates. If this
    /// ever goes red, the two routes have drifted apart again.
    private struct VitalDateCase {
        let fixture: String
        let familySearchID: String
        let stableID: String
        let name: String
        let profileBirth: Date
        let profileDeath: Date
        let treeBirthSpoken: String
        let treeDeathSpoken: String
        let profileOnlyDeathAge: Int
        let expectedAge: Int
    }

    @Test func theAgeRouteAndTheBiographyRouteNeverDisagreeAboutADeathDate() {
        let cases = [
            VitalDateCase(
                fixture: Self.maTree, familySearchID: "EILA-TA1",
                stableID: "ma", name: "Ma",
                profileBirth: date(1933, 8, 31), profileDeath: date(2023, 6, 1),
                treeBirthSpoken: "31 August 1930", treeDeathSpoken: "3 March 2023",
                profileOnlyDeathAge: 89, expectedAge: 92),
            VitalDateCase(
                fixture: Self.dadTree, familySearchID: "RHBS-R01",
                stableID: "dad", name: "Dad",
                profileBirth: date(1929, 2, 21), profileDeath: date(2008, 6, 25),
                treeBirthSpoken: "22 February 1929", treeDeathSpoken: "22 June 2008",
                profileOnlyDeathAge: 79, expectedAge: 79),
        ]
        for testCase in cases {
            let graph = GedcomFamilyGraph(gedcomText: testCase.fixture)
            let resolved = HallieVitalDates.resolve(
                stableID: testCase.stableID, canonicalName: testCase.name,
                treeIdentity: .familySearchID(testCase.familySearchID),
                profileBirthdate: testCase.profileBirth, profileDeathdate: testCase.profileDeath,
                graph: graph)

            // The age route: the tree's dates, never the profile's.
            let subject = ArchivistTemporalSubjectSnapshot(
                stableID: testCase.stableID, canonicalName: testCase.name,
                birthdate: resolved.birthdate?.date,
                birthdateProvenance: resolved.birthdate?.provenance,
                deathdate: resolved.deathdate?.date,
                deathdateProvenance: resolved.deathdate?.provenance)
            let ageResult = ArchivistTemporalExecutor.executePresentAge(
                .init(subject: testCase.name, operation: .age, reference: .currentSelection),
                subject: .resolved(requested: testCase.name, subject: subject),
                now: date(2026, 9, 4))
            #expect(ageResult.value == .exactAge(testCase.expectedAge), Comment(rawValue: testCase.name))
            #expect(ageResult.prose.contains(testCase.treeDeathSpoken), Comment(rawValue: ageResult.prose))
            #expect(ageResult.basisLine.contains("the family tree"), Comment(rawValue: ageResult.basisLine))

            // The biography route, from the SAME resolution.
            let person = graph.person(familySearchID: testCase.familySearchID)!
            let (answer, _, _) = HallieBiographyCard.answer(
                for: person, in: graph,
                fallbackBirthdate: resolved.birthdate?.date,
                fallbackDeathdate: resolved.deathdate?.date)
            #expect(answer.text.contains(testCase.treeBirthSpoken), Comment(rawValue: answer.text))
            #expect(answer.text.contains(testCase.treeDeathSpoken), Comment(rawValue: answer.text))

            // The tonight-specific regression: the age route's computed
            // age must not be the profile-only figure Rick's brother
            // heard live (89 for Ma; Dad's happened to already match).
            #expect(ageResult.value != .exactAge(testCase.profileOnlyDeathAge)
                || testCase.profileOnlyDeathAge == testCase.expectedAge,
                Comment(rawValue: "must not silently fall back to the profile-only age"))
        }
    }
}
