// BirthplaceClassifierTests.swift
// LOGIC table for the place-string classifier (2026-09-02, birthplace
// trail): every example Rick's tree is known to carry, colonial names
// mapped to today's borders, bare states and abbreviations, and five
// strings that must stay unknown rather than be guessed. Pure.

import Testing
@testable import VideoScanCore

struct BirthplaceClassifierTests {

    typealias C = BirthplaceClassifier

    struct Row {
        let place: String
        let country: String?
        let continent: C.Continent?
        let historical: Bool
        init(_ place: String, _ country: String?, _ continent: C.Continent?, historical: Bool = false) {
            self.place = place; self.country = country; self.continent = continent; self.historical = historical
        }
    }

    static let table: [Row] = [
        // United States, present-day spellings.
        Row("Chelsea, Suffolk, Massachusetts, United States", "United States", .northAmerica),
        Row("Brockton, Massachusetts, USA", "United States", .northAmerica),
        Row("Boston, Massachusetts, U.S.A.", "United States", .northAmerica),
        Row("Wilmington, New Hanover, North Carolina", "United States", .northAmerica),
        Row("Massachusetts", "United States", .northAmerica),
        Row("KY", "United States", .northAmerica),
        Row("Louisville, KY", "United States", .northAmerica),
        Row("Albany, N.Y.", "United States", .northAmerica),
        Row("Lowell, Mass.", "United States", .northAmerica),
        Row("New England", "United States", .northAmerica),
        // Colonial-era names → the country holding that ground today.
        Row("Shrewsbury, Worcester, Massachusetts Bay Colony, British Colonial America", "United States", .northAmerica, historical: true),
        Row("Sudbury, Middlesex, Massachusetts Bay Colony", "United States", .northAmerica, historical: true),
        Row("Plymouth, Plymouth Colony", "United States", .northAmerica, historical: true),
        Row("Hartford, Connecticut Colony", "United States", .northAmerica, historical: true),
        // Canada.
        Row("Stukley, Shefford, Quebec, Canada", "Canada", .northAmerica),
        Row("Nova Scotia, Canada", "Canada", .northAmerica),
        Row("Halifax, Nova Scotia", "Canada", .northAmerica),
        Row("Québec", "Canada", .northAmerica),
        Row("Quebec. Canada", "Canada", .northAmerica),
        Row("Montreal, New France", "Canada", .northAmerica, historical: true),
        // The British Isles.
        Row("Ireland", "Ireland", .europe),
        Row("County Antrim, Ireland", "Ireland", .europe),
        Row("Cork, County Cork, Ireland", "Ireland", .europe),
        Row("England", "United Kingdom", .europe),
        Row("Scotland", "United Kingdom", .europe),
        Row("Wales", "United Kingdom", .europe),
        Row("United Kingdom", "United Kingdom", .europe),
        Row("Belfast, Northern Ireland", "United Kingdom", .europe),
        Row("Glasgow, Lanarkshire, Scotland", "United Kingdom", .europe),
        // The continent.
        Row("Germany", "Germany", .europe),
        Row("Prussia", nil, .europe, historical: true),
        Row("Berlin, Prussia", nil, .europe, historical: true),
        Row("Netherlands", "Netherlands", .europe),
        Row("Holland", "Netherlands", .europe),
        Row("France", "France", .europe),
        Row("Italy", "Italy", .europe),
        Row("Poland", "Poland", .europe),
        Row("Sweden", "Sweden", .europe),
        Row("Norway", "Norway", .europe),
        Row("Munich, Bavaria", "Germany", .europe, historical: true),
        Row("Palermo, Sicily", "Italy", .europe, historical: true),
        // Elsewhere.
        Row("Sydney, Australia", "Australia", .oceania),
        Row("Mexico", "Mexico", .northAmerica),
        // Unknown — never guessed.
        Row("", nil, nil),
        Row("Unknown", nil, nil),
        Row("At sea", nil, nil),
        Row("Cheshire", nil, nil),
        Row("Springfield", nil, nil),
        Row("Boston, Massachusetts, Earth", nil, nil),
        Row("in", nil, nil),
        Row("Portland, or", nil, nil),
    ]

    @Test func classifierTable() {
        for row in Self.table {
            let place = C.classify(row.place)
            #expect(place.raw == row.place)
            #expect(place.country == row.country, Comment(rawValue: "country of “\(row.place)”"))
            #expect(place.continent == row.continent, Comment(rawValue: "continent of “\(row.place)”"))
            #expect(place.mappedFromHistoricalName == row.historical, Comment(rawValue: "historical flag of “\(row.place)”"))
            #expect(place.isUnknown == (row.continent == nil), Comment(rawValue: "isUnknown of “\(row.place)”"))
        }
        #expect(Self.table.count >= 25)
        #expect(Self.table.filter { $0.continent == nil }.count >= 5)
    }

    @Test func outsideAndInsideRules() {
        let us = C.classify("Brockton, Massachusetts, USA")
        let canada = C.classify("Quebec, Canada")
        let ireland = C.classify("County Cork, Ireland")
        let prussia = C.classify("Prussia")
        let colonial = C.classify("Sudbury, Massachusetts Bay Colony, British Colonial America")
        let unknown = C.classify("Somewhere")

        #expect(!us.isOutside(country: C.unitedStates))
        #expect(!colonial.isOutside(country: C.unitedStates))
        #expect(canada.isOutside(country: C.unitedStates))
        #expect(ireland.isOutside(country: C.unitedStates))
        #expect(prussia.isOutside(country: C.unitedStates))
        // An unknown place is neither inside nor outside anywhere.
        #expect(!unknown.isOutside(country: C.unitedStates))
        #expect(!unknown.isIn(.europe))

        #expect(ireland.isIn(.europe))
        #expect(prussia.isIn(.europe))
        #expect(!canada.isIn(.europe))
        #expect(!us.isIn(.europe))
    }

    @Test func recordedCountryIsTheDecidingComponentAsWritten() {
        #expect(C.classify("Shrewsbury, Worcester, Massachusetts Bay Colony, British Colonial America").recordedCountry == "British Colonial America")
        #expect(C.classify("Louisville, KY").recordedCountry == "KY")
        #expect(C.classify("Cork, Ireland.").recordedCountry == "Ireland")
        #expect(C.classify("Nowhere").recordedCountry == nil)
    }
}
