// HallieVitalDatesTests.swift
//
// Rick's brother caught it live, demo eve 2026-09-04: "tell me about Ma"
// (reading the family tree) and "how old is Ma" (reading the People
// profile) disagreed about the same woman's dates — 89 vs 92 at death.
// Same evening, same shape, on Dad.
//
// RICK'S RULING, made 2026-09-04, cited here because the previous attempt
// at this fix asserted a factual ruling that had not been made:
//
//   "The people tab should be the source for the immediate contemporary
//    people in the people tab."
//
// Asked directly which store holds the truth, he answered: the People
// profiles are right and the family tree is wrong. The real numbers, from
// him:
//
//   Ma  (Eileen Latta)        TRUE  born 31 Aug 1933, died 1 June 2023 (89)
//                             tree  born 31 Aug 1930, died 3 March 2023 (92)
//   Dad (Richard H Breen Sr)  TRUE  died 25 June 2008
//                             tree  died 22 June 2008
//
// These tests pin the fix at the shared seam (HallieVitalDates) and at both
// of the routes that read it.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@MainActor
@Suite("Hallie vital-date precedence — the People profile wins", .serialized)
struct HallieVitalDatesTests {

    // MARK: - Fixtures

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: year, month: month, day: day,
            hour: 12))!
    }

    /// Rick's Ma as the FamilySearch import records her — both dates wrong.
    private static let maTree = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Eileen /Latta/
    1 SEX F
    1 _FSFTID EILA-TA1
    1 BIRT
    2 DATE 31 AUG 1930
    2 PLAC Chelsea, Suffolk, Massachusetts, United States
    1 DEAT
    2 DATE 3 MAR 2023
    2 PLAC Stoughton, Norfolk, Massachusetts, United States
    0 TRLR
    """

    /// Rick's Dad as the import records him — the birth date is right, the
    /// death date is three days out.
    private static let dadTree = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Richard Harding /Breen/ Sr
    1 SEX M
    1 _FSFTID RHBS-R01
    1 BIRT
    2 DATE 22 FEB 1929
    2 PLAC Boston, Suffolk, Massachusetts, United States
    1 DEAT
    2 DATE 22 JUN 2008
    2 PLAC Brockton, Plymouth, Massachusetts, United States
    0 TRLR
    """

    /// A record with a birth date but no death at all — for the per-field
    /// merge, where each field comes from its own store.
    private static let birthOnlyTree = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Aunt /Test/
    1 SEX F
    1 _FSFTID TEST-PN1
    1 BIRT
    2 DATE 15 MAR 1945
    0 TRLR
    """

    /// Two tree people, so a pin collision has something to collide on.
    private static let twoPeopleTree = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Eileen /Latta/
    1 SEX F
    1 _FSFTID EILA-TA1
    1 BIRT
    2 DATE 31 AUG 1930
    1 DEAT
    2 DATE 3 MAR 2023
    0 @I2@ INDI
    1 NAME Someone /Else/
    1 SEX M
    1 _FSFTID ELSE-XX1
    1 BIRT
    2 DATE 1 JAN 1900
    0 TRLR
    """

    private func maProfile(stableID: String = "ma") -> HallieVitalProfile {
        HallieVitalProfile(
            stableID: stableID, canonicalName: "Ma",
            treeIdentity: .familySearchID("EILA-TA1"),
            birthdate: date(1933, 8, 31), deathdate: date(2023, 6, 1))
    }

    private func dadProfile(stableID: String = "dad") -> HallieVitalProfile {
        HallieVitalProfile(
            stableID: stableID, canonicalName: "Dad",
            treeIdentity: .familySearchID("RHBS-R01"),
            birthdate: date(1929, 2, 22), deathdate: date(2008, 6, 25))
    }

    // MARK: - Rule 1: the profile's date wins

    /// Ma, with Rick's real numbers. The tree says 1930/2023-03-03 and is
    /// wrong on both; the profile says 1933/2023-06-01 and is right.
    @Test func theProfileDateWinsForBothFieldsOnMa() {
        let graph = GedcomFamilyGraph(gedcomText: Self.maTree)
        let profile = maProfile()
        let resolved = HallieVitalDates.resolve(
            profile: profile, among: [profile], graph: graph)

        #expect(resolved.birthdate?.date == date(1933, 8, 31))
        #expect(resolved.birthdate?.provenance == .poiProfile(profileID: "ma"))
        #expect(resolved.deathdate?.date == date(2023, 6, 1))
        #expect(resolved.deathdate?.provenance == .poiProfile(profileID: "ma"))
    }

    /// Dad: 25 June 2008, not the tree's 22 June 2008.
    @Test func theProfileDateWinsForDadsDeath() {
        let graph = GedcomFamilyGraph(gedcomText: Self.dadTree)
        let profile = dadProfile()
        let resolved = HallieVitalDates.resolve(
            profile: profile, among: [profile], graph: graph)

        #expect(resolved.birthdate?.date == date(1929, 2, 22))
        #expect(resolved.deathdate?.date == date(2008, 6, 25))
        #expect(resolved.deathdate?.provenance == .poiProfile(profileID: "dad"))
    }

    /// "whether or not a tree bridge exists" — an unpinned profile, and a
    /// profile with a pin no installed tree can answer, both behave the
    /// same as one with a resolving pin: the profile's date is spoken.
    @Test func theProfileDateWinsWithNoTreeBridgeAtAll() {
        let graph = GedcomFamilyGraph(gedcomText: Self.maTree)
        let unpinned = HallieVitalProfile(
            stableID: "tim", canonicalName: "Tim", birthdate: date(1960, 6, 21))
        for installed: GedcomFamilyGraph? in [nil, graph] {
            let resolved = HallieVitalDates.resolve(
                profile: unpinned, among: [unpinned], graph: installed)
            #expect(resolved.birthdate?.date == date(1960, 6, 21))
            #expect(resolved.birthdate?.provenance == .poiProfile(profileID: "tim"))
            #expect(resolved.deathdate == nil)
        }
    }

    // MARK: - Rule 2: per-field merge, each field from its own store

    /// The profile holds a death date; the tree holds the birth date. Each
    /// is spoken from its own store — precedence is per field, not per
    /// person.
    @Test func eachFieldComesFromItsOwnStore() {
        let graph = GedcomFamilyGraph(gedcomText: Self.birthOnlyTree)
        let profile = HallieVitalProfile(
            stableID: "aunt", canonicalName: "Aunt Test",
            treeIdentity: .familySearchID("TEST-PN1"),
            birthdate: nil, deathdate: date(2020, 1, 10))
        let resolved = HallieVitalDates.resolve(
            profile: profile, among: [profile], graph: graph)

        #expect(resolved.birthdate?.date == date(1945, 3, 15))
        #expect(resolved.birthdate?.provenance == .gedcomTree(personID: "@I1@"))
        #expect(resolved.deathdate?.date == date(2020, 1, 10))
        #expect(resolved.deathdate?.provenance == .poiProfile(profileID: "aunt"))

        // And the biography route speaks exactly that split: the tree's own
        // birth string, the profile's death date.
        let person = graph.person(familySearchID: "TEST-PN1")!
        let bio = HallieVitalDates.resolve(
            treePerson: person, profiles: [profile], graph: graph,
            throughProfileStableID: nil)
        #expect(bio.profileBirthdate == nil)          // the tree's stands
        #expect(bio.profileDeathdate == date(2020, 1, 10))
        let (answer, _, _) = HallieBiographyCard.answer(
            for: person, in: graph,
            profileBirthdate: bio.profileBirthdate, profileDeathdate: bio.profileDeathdate)
        #expect(answer.text.contains("15 March 1945"), Comment(rawValue: answer.text))
        #expect(answer.text.contains("10 January 2020"), Comment(rawValue: answer.text))
    }

    // MARK: - Rule 3: nobody without a profile is affected

    /// The other ~39,237. A tree person no profile owns is untouched.
    @Test func aTreePersonWithNoProfileIsUnchanged() {
        let graph = GedcomFamilyGraph(gedcomText: Self.twoPeopleTree)
        let person = graph.person(familySearchID: "ELSE-XX1")!
        let resolved = HallieVitalDates.resolve(
            treePerson: person, profiles: [maProfile()], graph: graph,
            throughProfileStableID: nil)
        #expect(resolved == .none)
        #expect(resolved.profileBirthdate == nil)
        #expect(resolved.profileDeathdate == nil)

        let baseline = HallieBiographyCard.vitalsClause(person)
        let withSeam = HallieBiographyCard.vitalsClause(
            person, profileBirthdate: resolved.profileBirthdate,
            profileDeathdate: resolved.profileDeathdate)
        #expect(baseline == withSeam)
        #expect(withSeam?.contains("1 January 1900") == true, Comment(rawValue: withSeam ?? "nil"))
    }

    /// A profile that owns the record but records no dates at all leaves
    /// the tree exactly as it was.
    @Test func aProfileWithNoDatesLeavesTheTreeUnchanged() {
        let graph = GedcomFamilyGraph(gedcomText: Self.maTree)
        let person = graph.person(familySearchID: "EILA-TA1")!
        let dateless = HallieVitalProfile(
            stableID: "ma", canonicalName: "Ma",
            treeIdentity: .familySearchID("EILA-TA1"))
        let resolved = HallieVitalDates.resolve(
            treePerson: person, profiles: [dateless], graph: graph,
            throughProfileStableID: "ma")
        #expect(resolved.profileBirthdate == nil)
        #expect(resolved.profileDeathdate == nil)

        let clause = HallieBiographyCard.vitalsClause(
            person, profileBirthdate: resolved.profileBirthdate,
            profileDeathdate: resolved.profileDeathdate)
        #expect(clause == HallieBiographyCard.vitalsClause(person))
        #expect(clause?.contains("31 August 1930") == true, Comment(rawValue: clause ?? "nil"))
        #expect(clause?.contains("3 March 2023") == true, Comment(rawValue: clause ?? "nil"))

        // The age route agrees: no dates anywhere but the tree's, so the
        // tree's are what it counts from.
        let age = HallieVitalDates.resolve(
            profile: dateless, among: [dateless], graph: graph)
        #expect(age.birthdate?.provenance == .gedcomTree(personID: "@I1@"))
        #expect(age.birthdate?.date == date(1930, 8, 31))
    }

    // MARK: - Unique pin ownership

    /// Two profiles pinned to ONE tree person: neither owns it, so neither
    /// can override its biography and neither inherits its dates. (Review
    /// finding, 2026-09-04: the previous attempt accepted any resolving
    /// pin, so both would have inherited.)
    @Test func collidingTreePinsAreRejectedForBothProfiles() {
        let graph = GedcomFamilyGraph(gedcomText: Self.twoPeopleTree)
        let first = HallieVitalProfile(
            stableID: "ma", canonicalName: "Ma",
            treeIdentity: .familySearchID("EILA-TA1"),
            birthdate: date(1933, 8, 31), deathdate: date(2023, 6, 1))
        let second = HallieVitalProfile(
            stableID: "mother", canonicalName: "Mother",
            treeIdentity: .familySearchID("EILA-TA1"),
            birthdate: nil, deathdate: nil)
        let profiles = [first, second]
        let ownership = HallieVitalDates.pinOwnership(profiles: profiles, graph: graph)

        #expect(ownership.collidedTreePersonIDs == ["@I1@"])
        #expect(ownership.profileStableID(owning: "@I1@") == nil)
        #expect(ownership.treePersonID(ownedBy: "ma") == nil)
        #expect(ownership.treePersonID(ownedBy: "mother") == nil)

        // The biography route: the tree stands, both ways round.
        let person = graph.person(familySearchID: "EILA-TA1")!
        for order in [profiles, profiles.reversed()] {
            let resolved = HallieVitalDates.resolve(
                treePerson: person, profiles: Array(order), graph: graph,
                throughProfileStableID: nil)
            #expect(resolved == .none)
        }

        // The age route: the dateless profile inherits NOTHING from the
        // person it half-claims.
        let inherited = HallieVitalDates.resolve(
            profile: second, graph: graph, ownership: ownership)
        #expect(inherited.birthdate == nil)
        #expect(inherited.deathdate == nil)
        // …and the one that has its own dates still speaks them.
        let own = HallieVitalDates.resolve(
            profile: first, graph: graph, ownership: ownership)
        #expect(own.birthdate?.date == date(1933, 8, 31))
        #expect(own.deathdate?.date == date(2023, 6, 1))
    }

    /// A duplicate snapshot of one stable ID that disagrees about the pin
    /// is refused rather than resolved to one of the two readings.
    @Test func duplicateSnapshotsDisagreeingAboutThePinOwnNothing() {
        let graph = GedcomFamilyGraph(gedcomText: Self.twoPeopleTree)
        let a = HallieVitalProfile(
            stableID: "ma", canonicalName: "Ma",
            treeIdentity: .familySearchID("EILA-TA1"), birthdate: date(1933, 8, 31))
        let b = HallieVitalProfile(
            stableID: "ma", canonicalName: "Ma",
            treeIdentity: .familySearchID("ELSE-XX1"), birthdate: date(1933, 8, 31))
        for order in [[a, b], [b, a]] {
            let ownership = HallieVitalDates.pinOwnership(profiles: order, graph: graph)
            #expect(ownership.treePersonID(ownedBy: "ma") == nil)
            #expect(ownership.profileStableID(owning: "@I1@") == nil)
            #expect(ownership.profileStableID(owning: "@I2@") == nil)
        }
    }

    /// The question came through one profile while a DIFFERENT profile owns
    /// the tree record by pin: ownership is contested, so the tree stands.
    @Test func contestedOwnershipLeavesTheTreeAlone() {
        let graph = GedcomFamilyGraph(gedcomText: Self.maTree)
        let person = graph.person(familySearchID: "EILA-TA1")!
        let pinned = maProfile(stableID: "ma")
        let asker = HallieVitalProfile(
            stableID: "other", canonicalName: "Other",
            birthdate: date(1900, 1, 1), deathdate: date(1990, 1, 1))
        let resolved = HallieVitalDates.resolve(
            treePerson: person, profiles: [pinned, asker], graph: graph,
            throughProfileStableID: "other")
        #expect(resolved == .none)
    }

    // MARK: - Isolation: poisoned duplicate profile snapshots

    /// Two snapshots of ONE stable ID differing only in `deathdate` (and,
    /// separately, only in `treeIdentity`). Both used to pass
    /// `sameProfileMeaning`, and `deterministicProfile` then picked between
    /// them by name and stable ID — which are identical — so the answer
    /// depended on arrival order. It must now fail closed, either way round.
    @Test func poisonedDuplicateProfilesAreOrderIndependent() {
        let graph = GedcomFamilyGraph(gedcomText: Self.maTree)
        let base = HallieTurnExecutor.ProfileSnapshot(
            stableID: "ma", canonicalName: "Ma", aliases: ["Eileen"],
            birthdate: date(1933, 8, 31),
            treeIdentity: .familySearchID("EILA-TA1"),
            deathdate: date(2023, 6, 1))
        let differentDeath = HallieTurnExecutor.ProfileSnapshot(
            stableID: "ma", canonicalName: "Ma", aliases: ["Eileen"],
            birthdate: date(1933, 8, 31),
            treeIdentity: .familySearchID("EILA-TA1"),
            deathdate: date(2023, 3, 3))
        let differentPin = HallieTurnExecutor.ProfileSnapshot(
            stableID: "ma", canonicalName: "Ma", aliases: ["Eileen"],
            birthdate: date(1933, 8, 31),
            treeIdentity: nil,
            deathdate: date(2023, 6, 1))

        for poison in [differentDeath, differentPin] {
            #expect(!HallieTurnExecutor.sameProfileMeaning(base, poison))
            for order in [[base, poison], [poison, base]] {
                let byName = HallieTurnExecutor.temporalResolution(
                    "Ma", profiles: order, selectedIdentity: nil, graph: graph)
                #expect(byName == .missing(requested: "Ma"))
                let byID = HallieTurnExecutor.temporalResolution(
                    "Ma", profiles: order,
                    selectedIdentity: .profileStableID("ma"), graph: graph)
                #expect(byID == .missing(requested: "Ma"))
            }
        }

        // A genuine duplicate — same meaning in every field — still resolves.
        let honest = base
        let resolution = HallieTurnExecutor.temporalResolution(
            "Ma", profiles: [base, honest], selectedIdentity: nil, graph: graph)
        guard case .resolved(_, let snapshot) = resolution else {
            Issue.record("identical duplicates must still resolve"); return
        }
        #expect(snapshot.deathdate == date(2023, 6, 1))
    }

    /// `sameProfileMeaning` must split on EVERY field the executor consumes
    /// factually. Walk them one at a time; if you add a field to
    /// ProfileSnapshot, add a row here and to `sameProfileMeaning`.
    @Test func everyFactualFieldSplitsTheMeaning() {
        let base = HallieTurnExecutor.ProfileSnapshot(
            stableID: "p", canonicalName: "Ma", aliases: ["Eileen"],
            birthdate: date(1933, 8, 31), note: "a note",
            kinships: [], sex: .female, uuid: UUID(),
            treeIdentity: .familySearchID("EILA-TA1"), deathdate: date(2023, 6, 1))
        let variants: [(String, HallieTurnExecutor.ProfileSnapshot)] = [
            ("canonicalName", .init(stableID: "p", canonicalName: "Eileen Latta",
                                    aliases: base.aliases, birthdate: base.birthdate,
                                    note: base.note, kinships: base.kinships, sex: base.sex,
                                    uuid: base.uuid, treeIdentity: base.treeIdentity,
                                    deathdate: base.deathdate)),
            ("aliases", .init(stableID: "p", canonicalName: base.canonicalName,
                              aliases: ["Mum"], birthdate: base.birthdate,
                              note: base.note, kinships: base.kinships, sex: base.sex,
                              uuid: base.uuid, treeIdentity: base.treeIdentity,
                              deathdate: base.deathdate)),
            ("birthdate", .init(stableID: "p", canonicalName: base.canonicalName,
                                aliases: base.aliases, birthdate: date(1930, 8, 31),
                                note: base.note, kinships: base.kinships, sex: base.sex,
                                uuid: base.uuid, treeIdentity: base.treeIdentity,
                                deathdate: base.deathdate)),
            ("note", .init(stableID: "p", canonicalName: base.canonicalName,
                           aliases: base.aliases, birthdate: base.birthdate,
                           note: "a different note", kinships: base.kinships, sex: base.sex,
                           uuid: base.uuid, treeIdentity: base.treeIdentity,
                           deathdate: base.deathdate)),
            ("sex", .init(stableID: "p", canonicalName: base.canonicalName,
                          aliases: base.aliases, birthdate: base.birthdate,
                          note: base.note, kinships: base.kinships, sex: .male,
                          uuid: base.uuid, treeIdentity: base.treeIdentity,
                          deathdate: base.deathdate)),
            ("uuid", .init(stableID: "p", canonicalName: base.canonicalName,
                           aliases: base.aliases, birthdate: base.birthdate,
                           note: base.note, kinships: base.kinships, sex: base.sex,
                           uuid: UUID(), treeIdentity: base.treeIdentity,
                           deathdate: base.deathdate)),
            ("treeIdentity", .init(stableID: "p", canonicalName: base.canonicalName,
                                   aliases: base.aliases, birthdate: base.birthdate,
                                   note: base.note, kinships: base.kinships, sex: base.sex,
                                   uuid: base.uuid,
                                   treeIdentity: .familySearchID("ELSE-XX1"),
                                   deathdate: base.deathdate)),
            ("deathdate", .init(stableID: "p", canonicalName: base.canonicalName,
                                aliases: base.aliases, birthdate: base.birthdate,
                                note: base.note, kinships: base.kinships, sex: base.sex,
                                uuid: base.uuid, treeIdentity: base.treeIdentity,
                                deathdate: date(2023, 3, 3))),
        ]
        for (field, variant) in variants {
            #expect(!HallieTurnExecutor.sameProfileMeaning(base, variant),
                    Comment(rawValue: "differing \(field) must not read as the same person"))
            #expect(!HallieTurnExecutor.sameProfileMeaning(variant, base),
                    Comment(rawValue: "differing \(field), other way round"))
        }
        #expect(HallieTurnExecutor.sameProfileMeaning(base, base))
    }

    // MARK: - Rule 5: logged once, never spoken

    @Test func disagreementIsLoggedOnceNotPerTurn() {
        let graph = GedcomFamilyGraph(gedcomText: Self.maTree)
        // A stable ID unique to this run so the process-lifetime log cannot
        // be polluted by, or mistaken for, another test's key.
        let stableID = "disagree-\(UUID().uuidString)"
        let key = stableID + ".birthdate"
        #expect(!HallieVitalDates.loggedDisagreementKeysForTesting.contains(key))

        let profile = maProfile(stableID: stableID)
        for _ in 0..<3 {
            _ = HallieVitalDates.resolve(profile: profile, among: [profile], graph: graph)
        }
        // The set can only ever hold the key once; three resolutions that
        // each saw a genuine disagreement still leave exactly one entry,
        // which is what makes the underlying os_log fire at most once for
        // this person+field, ever.
        #expect(HallieVitalDates.loggedDisagreementKeysForTesting.contains(key))
        #expect(HallieVitalDates.loggedDisagreementKeysForTesting
            .filter { $0 == key }.count == 1)
    }

    @Test func agreeingStoresNeverLogADisagreement() {
        let graph = GedcomFamilyGraph(gedcomText: Self.maTree)
        let stableID = "agree-\(UUID().uuidString)"
        let profile = HallieVitalProfile(
            stableID: stableID, canonicalName: "Test Subject",
            treeIdentity: .familySearchID("EILA-TA1"),
            birthdate: date(1930, 8, 31),   // agrees with the tree
            deathdate: date(2023, 3, 3))    // agrees with the tree
        _ = HallieVitalDates.resolve(profile: profile, among: [profile], graph: graph)
        #expect(!HallieVitalDates.loggedDisagreementKeysForTesting.contains(stableID + ".birthdate"))
        #expect(!HallieVitalDates.loggedDisagreementKeysForTesting.contains(stableID + ".deathdate"))
    }

    /// Rule 5's other half: the disagreement never reaches the answer.
    @Test func theDisagreementIsNeverSpoken() {
        let graph = GedcomFamilyGraph(gedcomText: Self.maTree)
        let person = graph.person(familySearchID: "EILA-TA1")!
        let profile = maProfile()
        let bio = HallieVitalDates.resolve(
            treePerson: person, profiles: [profile], graph: graph,
            throughProfileStableID: "ma")
        let (answer, _, _) = HallieBiographyCard.answer(
            for: person, in: graph,
            profileBirthdate: bio.profileBirthdate, profileDeathdate: bio.profileDeathdate)
        for banned in ["disagree", "conflict", "the family tree says", "1930", "3 March 2023"] {
            #expect(!answer.text.lowercased().contains(banned.lowercased()),
                    Comment(rawValue: "spoken answer must not mention '\(banned)': \(answer.text)"))
        }
    }

    // MARK: - Rule 6: the basis names the store

    @Test func theBasisLineNamesWhichStoreTheDateCameFrom() {
        // Age route, profile-sourced.
        let graph = GedcomFamilyGraph(gedcomText: Self.maTree)
        let profile = maProfile()
        let resolved = HallieVitalDates.resolve(
            profile: profile, among: [profile], graph: graph)
        let subject = ArchivistTemporalSubjectSnapshot(
            stableID: "ma", canonicalName: "Ma",
            birthdate: resolved.birthdate?.date,
            birthdateProvenance: resolved.birthdate?.provenance,
            deathdate: resolved.deathdate?.date,
            deathdateProvenance: resolved.deathdate?.provenance)
        let age = ArchivistTemporalExecutor.executePresentAge(
            .init(subject: "Ma", operation: .age, reference: .currentSelection),
            subject: .resolved(requested: "Ma", subject: subject),
            now: date(2026, 9, 4))
        #expect(age.basisLine.contains("Ma's People profile"), Comment(rawValue: age.basisLine))

        // Age route, tree-sourced (the profile left the field empty).
        let birthOnly = GedcomFamilyGraph(gedcomText: Self.birthOnlyTree)
        let dateless = HallieVitalProfile(
            stableID: "aunt", canonicalName: "Aunt Test",
            treeIdentity: .familySearchID("TEST-PN1"))
        let fromTree = HallieVitalDates.resolve(
            profile: dateless, among: [dateless], graph: birthOnly)
        let treeSubject = ArchivistTemporalSubjectSnapshot(
            stableID: "aunt", canonicalName: "Aunt Test",
            birthdate: fromTree.birthdate?.date,
            birthdateProvenance: fromTree.birthdate?.provenance)
        let treeAge = ArchivistTemporalExecutor.executePresentAge(
            .init(subject: "Aunt Test", operation: .age, reference: .currentSelection),
            subject: .resolved(requested: "Aunt Test", subject: treeSubject),
            now: date(2026, 9, 4))
        #expect(treeAge.basisLine.contains("the family tree"), Comment(rawValue: treeAge.basisLine))

        // Biography route.
        #expect(HallieBiographyCard.vitalDatesBasis(
            profileName: "Ma", birth: date(1933, 8, 31), death: date(2023, 6, 1))
            == " Birth and death dates are from Ma's People profile.")
        #expect(HallieBiographyCard.vitalDatesBasis(
            profileName: "Ma", birth: nil, death: date(2023, 6, 1))
            == " The death date is from Ma's People profile.")
        #expect(HallieBiographyCard.vitalDatesBasis(
            profileName: "Ma", birth: nil, death: nil) == "")
    }

    /// The group basis used to say "People profile birthdates" for everyone
    /// unconditionally, so one store's dates could be shown under the other
    /// store's name (review finding, 2026-09-04). A mixed group must name
    /// each subject's own store.
    @Test func theGroupBasisNamesEachSubjectsOwnStore() {
        let fromProfile = ArchivistTemporalSubjectSnapshot(
            stableID: "ma", canonicalName: "Ma", birthdate: date(1933, 8, 31),
            birthdateProvenance: .poiProfile(profileID: "ma"),
            deathdate: date(2023, 6, 1),
            deathdateProvenance: .poiProfile(profileID: "ma"))
        let fromTree = ArchivistTemporalSubjectSnapshot(
            stableID: "aunt", canonicalName: "Aunt Test", birthdate: date(1945, 3, 15),
            birthdateProvenance: .gedcomTree(personID: "@I1@"))

        let mixed = ArchivistTemporalExecutor.executeGroup(
            subjects: [fromProfile, fromTree], phrase: "'them'", ask: .age,
            reference: .explicitYear(2000))
        #expect(!mixed.basisLine.hasPrefix("Basis: People profile birthdates"),
                Comment(rawValue: mixed.basisLine))
        #expect(mixed.basisLine.contains("Ma 1933-08-31 from Ma's People profile"),
                Comment(rawValue: mixed.basisLine))
        #expect(mixed.basisLine.contains("Aunt Test 1945-03-15 from the family tree"),
                Comment(rawValue: mixed.basisLine))

        // An all-profile group keeps the wording it always had.
        let allProfiles = ArchivistTemporalExecutor.executeGroup(
            subjects: [fromProfile], phrase: "'them'", ask: .age,
            reference: .explicitYear(2000))
        #expect(allProfiles.basisLine.hasPrefix("Basis: People profile birthdates Ma 1933-08-31"),
                Comment(rawValue: allProfiles.basisLine))
    }

    // MARK: - Sensor

    private struct VitalCase {
        let fixture: String
        let familySearchID: String
        let stableID: String
        let name: String
        let profileBirth: Date
        let profileDeath: Date
        let spokenBirth: String
        let spokenDeath: String
        let treeDeathSpoken: String
        let expectedAge: Int
    }

    /// SENSOR — do not delete.
    ///
    /// Demo eve 2026-09-04, in front of Rick's brother: "tell me about Ma"
    /// (biography, reading the tree) and "how old is Ma" (temporal, reading
    /// the People profile) gave two different sets of dates and two
    /// different ages at death for the same woman, 92 and 89.
    ///
    /// Rick's ruling that day: "The people tab should be the source for the
    /// immediate contemporary people in the people tab" — the People
    /// profiles are right, the family tree is wrong. His numbers:
    ///
    ///   Ma  born 31 Aug 1933, died 1 June 2023, age 89
    ///       (tree, wrong: born 31 Aug 1930, died 3 March 2023, age 92)
    ///   Dad died 25 June 2008
    ///       (tree, wrong: died 22 June 2008)
    ///
    /// This runs BOTH real composers — ArchivistTemporalExecutor for the age
    /// and HallieBiographyCard for the biography — from one HallieVitalDates
    /// resolution, and pins that they state the same dates. If it goes red,
    /// the two routes have drifted apart again.
    @Test func theAgeRouteAndTheBiographyRouteNeverDisagreeAboutADeathDate() {
        let cases = [
            VitalCase(
                fixture: Self.maTree, familySearchID: "EILA-TA1",
                stableID: "ma", name: "Ma",
                profileBirth: date(1933, 8, 31), profileDeath: date(2023, 6, 1),
                spokenBirth: "31 August 1933", spokenDeath: "1 June 2023",
                treeDeathSpoken: "3 March 2023", expectedAge: 89),
            VitalCase(
                fixture: Self.dadTree, familySearchID: "RHBS-R01",
                stableID: "dad", name: "Dad",
                profileBirth: date(1929, 2, 22), profileDeath: date(2008, 6, 25),
                spokenBirth: "22 February 1929", spokenDeath: "25 June 2008",
                treeDeathSpoken: "22 June 2008", expectedAge: 79),
        ]
        for testCase in cases {
            let graph = GedcomFamilyGraph(gedcomText: testCase.fixture)
            let profile = HallieVitalProfile(
                stableID: testCase.stableID, canonicalName: testCase.name,
                treeIdentity: .familySearchID(testCase.familySearchID),
                birthdate: testCase.profileBirth, deathdate: testCase.profileDeath)

            // ── The age route ────────────────────────────────────────────
            let resolved = HallieVitalDates.resolve(
                profile: profile, among: [profile], graph: graph)
            let subject = ArchivistTemporalSubjectSnapshot(
                stableID: testCase.stableID, canonicalName: testCase.name,
                birthdate: resolved.birthdate?.date,
                birthdateProvenance: resolved.birthdate?.provenance,
                deathdate: resolved.deathdate?.date,
                deathdateProvenance: resolved.deathdate?.provenance)
            let age = ArchivistTemporalExecutor.executePresentAge(
                .init(subject: testCase.name, operation: .age, reference: .currentSelection),
                subject: .resolved(requested: testCase.name, subject: subject),
                now: date(2026, 9, 4))
            #expect(age.value == .exactAge(testCase.expectedAge), Comment(rawValue: age.prose))
            #expect(age.basisLine.contains("\(testCase.name)'s People profile"),
                    Comment(rawValue: age.basisLine))

            // ── The biography route, for the SAME person ─────────────────
            let person = graph.person(familySearchID: testCase.familySearchID)!
            let bio = HallieVitalDates.resolve(
                treePerson: person, profiles: [profile], graph: graph,
                throughProfileStableID: testCase.stableID)
            let (answer, _, _) = HallieBiographyCard.answer(
                for: person, in: graph,
                profileBirthdate: bio.profileBirthdate, profileDeathdate: bio.profileDeathdate)

            // ── They agree, and on Rick's numbers ────────────────────────
            #expect(answer.text.contains(testCase.spokenBirth), Comment(rawValue: answer.text))
            #expect(answer.text.contains(testCase.spokenDeath), Comment(rawValue: answer.text))
            #expect(!answer.text.contains(testCase.treeDeathSpoken), Comment(rawValue: answer.text))
            #expect(bio.profileBirthdate == resolved.birthdate?.date)
            #expect(bio.profileDeathdate == resolved.deathdate?.date)

            // The age route's own rendering of the death day is the same
            // string the biography speaks — one date, one house format.
            #expect(HallieDateStyle.spoken(
                ArchivistTemporalExecutor.canonicalDay(testCase.profileDeath)!,
                calendar: HallieVitalDates.utcCalendar) == testCase.spokenDeath)

            // Places still come from the tree, untouched (rule 4).
            #expect(answer.text.contains(person.birthPlace ?? "—"), Comment(rawValue: answer.text))
        }
    }
}
