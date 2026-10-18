// DisplayValueDerivationTests.swift
// LOGIC (cutover B1, Rick's go §10 decision 1): what each content SHOWS,
// derived from every copy's curated evidence — sets are unions, people are
// unions with a both-sides name in conflict, scalars agree or show nothing
// with conflict = 1, a copy that carries nothing does not vote, and a value
// the DDL cannot hold is never invented into one (counted as unreadable).
//
// Suite (filter by SUITE): DisplayValueDerivationTests

import Testing
@testable import VideoScanCore

@Suite("DisplayValueDerivation — the display choice per content")
struct DisplayValueDerivationTests {

    private static let d = PoisonedCatalogFixture.digest("display")

    private static func src(_ occurrence: String, _ field: CatalogDDL.KnowledgeField, _ value: CatalogJSONValue,
                            digest: String = d) -> DisplayValueDerivation.Source {
        DisplayValueDerivation.Source(digest: digest, occurrence: occurrence, field: field, value: value)
    }

    @Test func copiesThatAgreeShowTheValue() {
        let rows = DisplayValueDerivation.derive(sources: [Self.src("a", .starRating, .int(2)), Self.src("b", .starRating, .int(2))])
        #expect(rows.stars == [.init(digest: Self.d, value: 2, conflict: false)])
    }

    @Test func copiesThatDisagreeShowNothingWithConflict() {
        let rows = DisplayValueDerivation.derive(sources: [Self.src("a", .starRating, .int(2)), Self.src("b", .starRating, .int(3))])
        #expect(rows.stars == [.init(digest: Self.d, value: nil, conflict: true)])
        #expect(rows.conflictCount == 1)
    }

    @Test func aCopyWithoutTheFieldDoesNotVote() {
        let rows = DisplayValueDerivation.derive(sources: [Self.src("a", .userNotes, .string("lake")), Self.src("b", .tags, .array([.string("Gold")]))])
        #expect(rows.userNotes == [.init(digest: Self.d, value: "lake", conflict: false)])
    }

    @Test func aDateIsPairedWithTheConfidenceOfTheSameCopy() {
        let rows = DisplayValueDerivation.derive(sources: [
            Self.src("a", .userDate, .string("1990")), Self.src("a", .userDateConfidence, .string("known")),
            Self.src("b", .userDate, .string("1990")), Self.src("b", .userDateConfidence, .string("estimated")),
        ])
        #expect(rows.userDates == [.init(digest: Self.d, value: nil, conflict: true)], "same year, different confidence: a conflict")
    }

    @Test func aMatchingDatePairShowsBoth() {
        let rows = DisplayValueDerivation.derive(sources: [
            Self.src("a", .userDate, .string("1990-06")), Self.src("a", .userDateConfidence, .string("known")),
        ])
        #expect(rows.userDates == [.init(digest: Self.d, value: .init(value: "1990-06", confidence: "known"), conflict: false)])
    }

    @Test func setsAreUnionsAndNeverConflict() {
        let rows = DisplayValueDerivation.derive(sources: [
            Self.src("a", .tags, .array([.string("Gold"), .string("Follow Up")])),
            Self.src("b", .tags, .array([.string("Gold"), .string("Lake")])),
        ])
        #expect(rows.workflowTags.map(\.tag) == ["Gold", "Follow Up", "Lake"])
        #expect(rows.conflictCount == 0)
    }

    @Test func confirmedNamesUnionWithTheEarliestDate() {
        func tag(_ name: String, _ at: Int64) -> CatalogJSONValue {
            .object(["name": .string(name), "confirmedAt": .string(CatalogJSONDate.format(at))])
        }
        let rows = DisplayValueDerivation.derive(sources: [
            Self.src("a", .confirmedByUserPeople, .array([tag("Donna", 2_000)])),
            Self.src("b", .confirmedByUserPeople, .array([tag("Donna", 1_000), tag("Matt", 3_000)])),
        ])
        #expect(rows.people.map(\.name) == ["Donna", "Matt"])
        #expect(rows.people.first?.confirmedAt == 1_000)
    }

    @Test func aNameConfirmedOnOneCopyAndRejectedOnAnotherKeepsBothInConflict() {
        let rows = DisplayValueDerivation.derive(sources: [
            Self.src("a", .confirmedByUserPeople, .array([.object(["name": .string("Eileen"), "confirmedAt": .string("2026-01-01T00:00:00Z")])])),
            Self.src("b", .rejectedPeople, .array([.string("Eileen")])),
        ])
        #expect(rows.people.count == 2)
        #expect(rows.people.filter { !$0.conflict }.isEmpty)
        #expect(rows.conflictCount == 2)
    }

    @Test func aValueTheTableCannotHoldIsNeverInvented() {
        let stars = DisplayValueDerivation.derive(sources: [Self.src("a", .starRating, .int(7))])
        #expect(stars.stars == [.init(digest: Self.d, value: nil, conflict: true)])
        #expect(stars.unreadable == 1)
        let date = DisplayValueDerivation.derive(sources: [Self.src("a", .userDate, .string("summer 1990"))])
        #expect(date.userDates.first?.value == nil)
        let tags = DisplayValueDerivation.derive(sources: [Self.src("a", .tags, .array([.string("  "), .string("Gold")]))])
        #expect(tags.workflowTags.map(\.tag) == ["Gold"])
        #expect(tags.unreadable == 1)
    }

    @Test func digestsAreKeptApartAndFieldsOutsideTheDisplayAreIgnored() {
        let other = PoisonedCatalogFixture.digest("other")
        let rows = DisplayValueDerivation.derive(sources: [
            Self.src("a", .starRating, .int(1)), Self.src("b", .starRating, .int(3), digest: other),
            Self.src("a", .lineage, .object(["derivedFrom": .string("x")])),
        ])
        #expect(rows.stars.count == 2)
        #expect(rows.rowCount == 2)
    }

    @Test func theUserDateShapeIsTheDDLs() {
        #expect(DisplayParse.isUserDate("1990"))
        #expect(DisplayParse.isUserDate("1990-06"))
        #expect(DisplayParse.isUserDate("1990-06-30"))
        #expect(!DisplayParse.isUserDate("1990-6"))
        #expect(!DisplayParse.isUserDate("1990-26"))
        #expect(!DisplayParse.isUserDate("c. 1990"))
    }
}
