// BirthplaceClassifierTests.swift
// LOGIC table for the place-string classifier (2026-09-02, birthplace
// trail): every example Rick's tree is known to carry, colonial names
// mapped to today's borders, bare states and abbreviations, dotted
// abbreviations kept whole (codex #1014 item 1), names that spanned
// today's borders held as ambiguous, and strings that must stay unknown
// rather than be guessed. Pure.

import Testing
@testable import VideoScanCore

struct BirthplaceClassifierTests {

    typealias C = BirthplaceClassifier

    struct Row {
        let place: String
        let country: String?
        let continent: C.Continent?
        let historical: Bool
        let ambiguous: Bool
        init(_ place: String, _ country: String?, _ continent: C.Continent?,
             historical: Bool = false, ambiguous: Bool = false) {
            self.place = place; self.country = country; self.continent = continent
            self.historical = historical; self.ambiguous = ambiguous
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
        // Dotted abbreviations are tokens, not separators (codex #1014).
        Row("U.S.A.", "United States", .northAmerica),
        Row("U.S.", "United States", .northAmerica),
        Row("Brockton, Massachusetts, U.S.", "United States", .northAmerica),
        Row("Boston Mass. U.S.A.", "United States", .northAmerica),
        Row("Lowell, Mass. U.S.A.", "United States", .northAmerica),
        Row("Washington, D.C.", "United States", .northAmerica),
        Row("St. Louis, Mo.", "United States", .northAmerica),
        Row("Mt. Vernon. New York", "United States", .northAmerica),
        Row("U.K.", "United Kingdom", .europe),
        Row("London, U.K.", "United Kingdom", .europe),
        Row("Cork, Ireland.", "Ireland", .europe),
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
        Row("Montreal, Lower Canada", "Canada", .northAmerica, historical: true),
        Row("Kingston, Upper Canada", "Canada", .northAmerica, historical: true),
        Row("Montreal, Province of Quebec", "Canada", .northAmerica, historical: true),
        // Names that spanned today's borders: recognised, never counted.
        Row("Montreal, New France", nil, nil, historical: true, ambiguous: true),
        Row("Nouvelle-France", nil, nil, historical: true, ambiguous: true),
        Row("Grand-Pré, Acadia", nil, nil, historical: true, ambiguous: true),
        Row("Port-Royal, Acadie", nil, nil, historical: true, ambiguous: true),
        Row("Halifax, British North America", nil, nil, historical: true, ambiguous: true),
        Row("Boston, British America", nil, nil, historical: true, ambiguous: true),
        Row("Minsk, Russia", nil, nil, historical: true, ambiguous: true),
        Row("Vilna, Russian Empire", nil, nil, historical: true, ambiguous: true),
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
        Row("A", nil, nil),
        Row("K", nil, nil),
    ]

    @Test func classifierTable() {
        for row in Self.table {
            let place = C.classify(row.place)
            #expect(place.raw == row.place)
            #expect(place.country == row.country, Comment(rawValue: "country of “\(row.place)”"))
            #expect(place.continent == row.continent, Comment(rawValue: "continent of “\(row.place)”"))
            #expect(place.mappedFromHistoricalName == row.historical, Comment(rawValue: "historical flag of “\(row.place)”"))
            #expect(place.isAmbiguous == row.ambiguous, Comment(rawValue: "ambiguous flag of “\(row.place)”"))
            #expect(place.isUnknown == (row.continent == nil && !row.ambiguous), Comment(rawValue: "isUnknown of “\(row.place)”"))
        }
        #expect(Self.table.count >= 25)
        #expect(Self.table.filter { $0.continent == nil && !$0.ambiguous }.count >= 5)
        #expect(Self.table.filter { $0.place.contains(".") && $0.continent != nil }.count >= 6)
        #expect(Self.table.filter(\.ambiguous).count >= 5)
    }

    /// The bug codex #1014 named: with no comma, every period used to be a
    /// separator, so "U.S.A." became "A" and "U.K." became "K".
    @Test func dottedAbbreviationsAreNeverSplitIntoLetters() {
        for (place, country) in [("U.S.A.", "United States"), ("U.S.", "United States"),
                                 ("U.K.", "United Kingdom"), ("N.Y.", "United States"),
                                 ("Mass.", "United States"), ("Boston Mass. U.S.A.", "United States")] {
            let c = C.classify(place)
            #expect(c.country == country, Comment(rawValue: place))
            #expect(!c.isUnknown, Comment(rawValue: place))
            #expect(c.recordedCountry?.count ?? 0 > 1, Comment(rawValue: "“\(place)” decided by a single letter"))
        }
        #expect(C.components(of: "U.S.A.") == ["U.S.A."])
        #expect(C.components(of: "Quebec. Canada") == ["Quebec", "Canada"])
        #expect(C.components(of: "Mt. Vernon. New York") == ["Mt. Vernon", "New York"])
        #expect(C.components(of: "Boston Mass. U.S.A.") == ["Boston Mass. U.S.A."])
        #expect(C.components(of: "Lowell, Mass. U.S.A.").map { $0.trimmingCharacters(in: .whitespaces) } == ["Lowell", "Mass. U.S.A."])
    }

    /// An ambiguous name never satisfies a stop rule in either direction.
    @Test func ambiguousNamesAreNeitherInsideNorOutsideAnywhere() {
        for place in ["Montreal, New France", "Grand-Pré, Acadia", "Halifax, British North America",
                      "Boston, British America", "Minsk, Russia", "Vilna, Russian Empire"] {
            let c = C.classify(place)
            #expect(c.isAmbiguous, Comment(rawValue: place))
            #expect(!c.isUnknown, Comment(rawValue: place))
            #expect(!c.isOutside(country: C.unitedStates), Comment(rawValue: place))
            #expect(!c.isOutside(country: C.canada), Comment(rawValue: place))
            for continent in C.Continent.allCases {
                #expect(!c.isIn(continent), Comment(rawValue: "\(place) in \(continent)"))
            }
            #expect(c.country == nil && c.continent == nil, Comment(rawValue: place))
        }
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
        #expect(C.classify("Boston, U.S.A.").recordedCountry == "U.S.A")
        #expect(C.classify("Montreal, New France").recordedCountry == "New France")
        #expect(C.classify("Nowhere").recordedCountry == nil)
    }
}
