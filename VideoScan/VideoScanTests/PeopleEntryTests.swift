// PeopleEntryTests.swift
// People tab (Rick 2026-10-07): a family is a PEER of a person in the UI —
// one selection value, one arrow-key order (families first, then people in
// gallery order) — while underneath a family is never a POIProfile.
//
// Dimensions (feature-test checklist): Logic — ordering, neighbour walk,
// selection round-trip through the two stored keys; Isolation — a stale
// (trashed) family key falls back to the person; Sensor — a family never
// resolves to a person profile, even one sharing its uuid, and selecting a
// family never writes the person's settings; Scale — the merged order and
// walk over 100k synthetic people inside a time budget.

import Foundation
import Testing
@testable import VideoScan

@Suite("People — families and people as peers")
struct PeopleEntryTests {

    private func person(_ name: String, uuid: UUID = UUID()) -> POIProfile {
        POIProfile(name: name, referencePath: "", uuid: uuid)
    }

    // MARK: Logic — one order, families first

    @Test func familiesComeFirstThenPeopleInGalleryOrder() {
        let breen = FamilyGroup(name: "Rick & Donna Breen Family")
        let oconnor = FamilyGroup(name: "O'Connor Family")
        let donna = person("Donna"), tim = person("Tim"), dan = person("Dan")
        let order = PeopleEntryList.ordered(families: [breen, oconnor], people: [donna, tim, dan])
        #expect(order == [.family(breen.uuid), .family(oconnor.uuid),
                          .person(donna.uuid), .person(tim.uuid), .person(dan.uuid)],
                "gallery order kept: families as given, people as given (no re-sort)")
        let familyFlags = order.map { $0.isFamily }
        #expect(familyFlags == [true, true, false, false, false])
    }

    @Test func arrowsWalkAcrossTheFamilyPersonBoundaryAndStopAtTheEnds() {
        let breen = FamilyGroup(name: "Breen Family")
        let donna = person("Donna"), tim = person("Tim")
        let order = PeopleEntryList.ordered(families: [breen], people: [donna, tim])

        #expect(PeopleEntryList.neighbor(of: .family(breen.uuid), in: order, step: .next) == .person(donna.uuid))
        #expect(PeopleEntryList.neighbor(of: .person(donna.uuid), in: order, step: .previous) == .family(breen.uuid))
        #expect(PeopleEntryList.neighbor(of: .family(breen.uuid), in: order, step: .previous) == nil, "← on the first: stop")
        #expect(PeopleEntryList.neighbor(of: .person(tim.uuid), in: order, step: .next) == nil, "→ on the last: stop")
        #expect(PeopleEntryList.neighbor(of: nil, in: order, step: .next) == .family(breen.uuid), "no selection → first card")
        #expect(PeopleEntryList.neighbor(of: .person(UUID()), in: order, step: .previous) == .family(breen.uuid),
                "a selection not displayed (filtered / scanning) → first card")
        #expect(PeopleEntryList.neighbor(of: nil, in: [], step: .next) == nil)
    }

    @Test func aPersonAndAFamilyWithTheSameUUIDAreDifferentEntries() {
        let shared = UUID()
        #expect(PeopleEntry.person(shared) != PeopleEntry.family(shared))
        let order: [PeopleEntry] = [.family(shared), .person(shared)]
        #expect(PeopleEntryList.neighbor(of: .family(shared), in: order, step: .next) == .person(shared))
    }

    // MARK: Logic — selection round-trip through the stored keys

    @Test func selectingAFamilyRoundTripsAndLeavesThePersonAlone() {
        let breen = FamilyGroup(name: "Breen Family")
        let donna = person("Donna")
        let stored = PeopleEntryList.storage(for: .family(breen.uuid))
        #expect(stored.profileUUID == nil, "a family never writes the person's active profile")
        // The person's key still holds Donna; the family key wins.
        let read = PeopleEntryList.selection(familyUUID: stored.familyUUID,
                                             familyIDs: [breen.uuid],
                                             activeProfileUUID: donna.uuid)
        #expect(read == .family(breen.uuid))
    }

    @Test func selectingAPersonRoundTripsAndClearsTheFamily() {
        let breen = FamilyGroup(name: "Breen Family")
        let tim = person("Tim")
        let stored = PeopleEntryList.storage(for: .person(tim.uuid))
        #expect(stored.familyUUID.isEmpty, "a person's page replaces a family's")
        #expect(stored.profileUUID == tim.uuid)
        let read = PeopleEntryList.selection(familyUUID: stored.familyUUID,
                                             familyIDs: [breen.uuid],
                                             activeProfileUUID: stored.profileUUID)
        #expect(read == .person(tim.uuid))
    }

    // MARK: Isolation — stale or garbage stored keys

    @Test func aTrashedOrGarbageFamilyKeyFallsBackToThePerson() {
        let donna = person("Donna")
        let gone = UUID()
        #expect(PeopleEntryList.selection(familyUUID: gone.uuidString, familyIDs: [],
                                          activeProfileUUID: donna.uuid) == .person(donna.uuid))
        #expect(PeopleEntryList.selection(familyUUID: "not-a-uuid", familyIDs: [gone],
                                          activeProfileUUID: donna.uuid) == .person(donna.uuid))
        #expect(PeopleEntryList.selection(familyUUID: "", familyIDs: [gone], activeProfileUUID: nil) == nil)
    }

    // MARK: Sensor — a family is never treated as a person profile

    @Test func aFamilyIsNeverResolvedToAProfile() {
        // Worst case: a profile that happens to carry the family's uuid.
        let breen = FamilyGroup(name: "Breen Family")
        let impostor = person("Breen Family", uuid: breen.uuid)
        let donna = person("Donna")
        let profiles = [impostor, donna]

        #expect(PeopleEntryList.profile(for: .family(breen.uuid), in: profiles) == nil,
                "a family entry never reaches person code (face matching, Hallie, tree identity)")
        #expect(PeopleEntryList.profile(for: .person(donna.uuid), in: profiles)?.uuid == donna.uuid)
        #expect(PeopleEntryList.family(for: .person(breen.uuid), in: [breen]) == nil,
                "and a person entry is never a family")
        #expect(PeopleEntryList.family(for: .family(breen.uuid), in: [breen]) == breen)
        #expect(PeopleEntryList.profile(for: nil, in: profiles) == nil)
    }

    @Test func theEntryModelNeverBuildsAProfile() throws {
        let source = try SourceTree.appSource(named: "PeopleEntry.swift")
        let code = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!code.contains("POIProfile("), "the entry model never constructs a person profile")
        #expect(!code.contains("save("), "the entry model never writes anything")
    }

    // MARK: Scale — 100k people, one walk

    @Test func orderingAndWalkingAHundredThousandPeopleStaysFast() {
        let families = (0..<5).map { FamilyGroup(name: "Family \($0)") }
        let people = (0..<100_000).map { POIProfile(name: "P\($0)", referencePath: "", uuid: UUID()) }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let order = PeopleEntryList.ordered(families: families, people: people)
            #expect(order.count == 100_005)
            let last = PeopleEntryList.neighbor(of: .person(people[people.count - 2].uuid), in: order, step: .next)
            #expect(last == .person(people[people.count - 1].uuid))
        }
        #expect(elapsed < .milliseconds(500), "merged order + one arrow step over 100k people: \(elapsed)")
    }
}
