// FamilyMapEuropeQAFindingsTests.swift
// QA red tests for 49ee605c (Western Europe stage). Each fails on 49ee605c.
// QA's original four tests are kept verbatim; the cases below "Added with
// the Manager's rulings" pin the rulings the fix follows. RED on 49ee605c:
// 10 tests, 45 issues. Generic places only, no personal data.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("FamilyMap Western Europe — QA findings (#227)")
struct FamilyMapEuropeQAFindingsTests {
    typealias R = BirthplaceUnitResolver

    // P1-A — BirthplaceUnitResolver.swift:437. Canadian postal code at the
    // end of a comma-less part ("Halifax NS") placed on d1aee8c5, nil now.
    @Test(arguments: [
        ("Halifax NS", "can-nova-scotia"),
        ("Halifax N.S.", "can-nova-scotia"),
        ("Pictou Co NS", "can-nova-scotia"),
        ("Saint John NB", "can-new-brunswick"),
        ("Charlottetown PEI", "can-prince-edward-island"),
        ("Toronto ON", "can-ontario"),
    ])
    func canadianCodeAtTheEndOfAPartStillPlaces(_ row: (String, String)) {
        #expect(R.resolve(row.0)?.unitKey == row.1, "\(row.0) → \(R.resolve(row.0)?.unitKey ?? "nil")")
    }

    @Test func theDutchNlCaseStillResolvesToTheNetherlands() {
        #expect(R.resolve("Bergen Op Zoom (Noord-Brabant) Nl")?.unitKey == "nld-north-brabant")
    }

    // P1-B — BirthplaceUnitResolver.swift:326-342 (phrase-from-the-right
    // match inside one component) + the new Europe country tables. A
    // New-World colony / town named after a European country or province
    // lands in Europe. All nil on d1aee8c5.
    @Test(arguments: [
        "New Sweden", "Fort Christina, New Sweden", "New Sweden Colony",
        "New Spain", "Mexico City, New Spain", "Nueva España",
        "Nieuw Nederland", "New Amsterdam, Nieuw Nederland",
        "New Holland", "New Holland, Lancaster",
        "New Utrecht, Long Island", "New Bavaria",
    ])
    func aNewWorldNamesakeIsNeverEuropean(_ place: String) {
        let hit = R.resolve(place)
        #expect(hit == nil || hit?.country.isWesternEurope == false,
                "\(place) → \(hit?.unitKey ?? "nil")")
    }

    // P1-C — BirthplaceUnitResolver.swift:381-387 (`.foreign` skipped once a
    // country is established). The +Europe header (lines 34-35, 51-53) says
    // East/West Prussia, Posen, Bohemia, Silesia are off the map; with the
    // usual country written to their right they shade Germany / Austria.
    @Test(arguments: [
        "Königsberg, East Prussia, Germany",
        "Königsberg, Ostpreußen, Preußen",
        "Danzig, West Prussia, Germany",
        "Posen, Prussia",
        "Breslau, Silesia, Prussia",
        "Prague, Bohemia, Austria",
        "Lemberg, Galicia, Austria",
    ])
    func groundOutsideTodaysCountryIsNotPlacedInIt(_ place: String) {
        #expect(R.resolve(place) == nil, "\(place) → \(R.resolve(place)?.unitKey ?? "nil")")
    }

    // P2-D — bare names that are also common North American places, accepted
    // with no country (all nil on d1aee8c5).
    @Test(arguments: ["Piedmont", "Zeeland", "Holland", "Antwerp", "Flanders", "Friesland"])
    func aBareNameSharedWithNorthAmericaNeedsItsCountry(_ place: String) {
        #expect(R.resolve(place) == nil, "\(place) → \(R.resolve(place)?.unitKey ?? "nil")")
    }

    // ---- Added with the Manager's rulings (2026-09-30) -------------------

    /// P1-B: the colonies are named explicitly — New Netherland, New Sweden
    /// and New Amsterdam are ground in today's United States; New Spain and
    /// New Holland are recognised and off the map; a "New …" town keeps
    /// its US state.
    @Test func theNewWorldColoniesAreNamedExplicitly() {
        #expect(R.resolve("New Sweden")?.unitKey == "usa")
        #expect(R.resolve("Nieuw Nederland")?.unitKey == "usa")
        #expect(R.resolve("New Amsterdam, Nieuw Nederland")?.unitKey == "usa-new-york")
        #expect(R.resolve("New Utrecht, Long Island")?.unitKey == "usa-new-york")
        #expect(R.resolve("Germany Flats")?.unitKey == "usa-new-york")
        #expect(R.resolve("New Spain") == nil && R.resolve("Nueva España") == nil && R.resolve("New Holland") == nil)
        #expect(R.resolve("New Holland, Lancaster, Pennsylvania")?.unitKey == "usa-pennsylvania")
        #expect(R.resolve("New Bavaria, Henry, Ohio")?.unitKey == "usa-ohio")
        // The European originals are untouched.
        #expect(R.resolve("Sweden")?.unitKey == "swe" && R.resolve("Utrecht, Netherlands")?.unitKey == "nld-utrecht")
    }

    /// P1-C (Manager ruling): a historic subregion is placed where it is
    /// TODAY, whatever country is written to its right — the same "today's
    /// flag" policy as the card.
    @Test(arguments: [
        ("Strasbourg, Alsace, Germany", "fra-grand-est"),
        ("Metz, Lorraine, Germany", "fra-grand-est"),
        ("Colmar, Elsass-Lothringen, Deutschland", "fra-grand-est"),
        ("Bozen, South Tyrol, Austria", "ita"),
        ("Bozen, Tyrol, Austria", "ita"),
        ("Trieste, Austria", "ita"),
        ("Nice, Sardinia", "fra-provence-alpes-cote-d-azur"),
        ("Chambéry, Savoy, Sardinia", "fra-auvergne-rhone-alpes"),
    ])
    func aHistoricSubregionIsPlacedWhereItIsToday(_ row: (String, String)) {
        #expect(R.resolve(row.0)?.unitKey == row.1, "\(row.0) → \(R.resolve(row.0)?.unitKey ?? "nil")")
    }

    @Test func theRulingKeepsTheSimpleCases() {
        #expect(R.resolve("Austria")?.unitKey == "aut")
        #expect(R.resolve("Vienna, Austria")?.unitKey == "aut")
        #expect(R.resolve("Prussia")?.unitKey == "deu")
        #expect(R.resolve("Koblenz, Rhineland, Prussia")?.unitKey == "deu")
        #expect(R.resolve("Galicia, Spain")?.unitKey == "esp", "Spain's Galicia is not Austria's")
        #expect(R.resolve("Stralsund, Western Pomerania, Prussia")?.unitKey == "deu-mecklenburg-vorpommern")
        #expect(R.resolve("Alsace")?.unitKey == "fra-grand-est")
        #expect(R.resolve("Nice") == nil, "a town name alone still needs its country")
    }

    /// P2-D: the Dutch / Flemish names need their country only when bare.
    @Test func theNamesThatNeedACountryStillResolveWithOne() {
        #expect(R.resolve("Holland, Netherlands")?.unitKey == "nld")
        #expect(R.resolve("Leiden, Zuid-Holland, Holland")?.unitKey == "nld-south-holland")
        #expect(R.resolve("Middelburg, Zeeland, Holland")?.unitKey == "nld-zeeland")
        #expect(R.resolve("Zeeland, Netherlands")?.unitKey == "nld-zeeland")
        #expect(R.resolve("Antwerp, Belgium")?.unitKey == "bel-antwerp")
        #expect(R.resolve("Friesland, Nederland")?.unitKey == "nld-friesland")
        #expect(R.resolve("Ghent, East Flanders, Flanders")?.unitKey == "bel-east-flanders")
        #expect(R.resolve("Turin, Piedmont, Italy")?.unitKey == "ita")
        #expect(R.resolve("Holland, Ottawa, Michigan")?.unitKey == "usa-michigan")
    }

    // P2-E (the "Yorkshire, England, France" / "Quebec, Canada, France"
    // pins) is restored in FamilyMapResolverAdversarialTests, where it was.
}
