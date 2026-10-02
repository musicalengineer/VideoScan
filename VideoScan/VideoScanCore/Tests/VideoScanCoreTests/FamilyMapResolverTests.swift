// FamilyMapResolverTests.swift
// LOGIC table for BirthplaceUnitResolver (GH #227 Stage 1): every real
// spelling from design §1, the historic / modern county variants, the
// colonial forms folding to states, the lone country → country outline,
// the ambiguous bare names that must stay nil, and what stops the scan.
// SCALE: 40k places under the budget. SENSOR: every key the resolver can
// emit is well-formed and the border file's required key set is stable.
// Pure — no file, no network.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("FamilyMap birthplace → unit resolver")
struct FamilyMapResolverTests {

    typealias R = BirthplaceUnitResolver

    struct Row {
        let place: String
        let key: String
        let matched: String?
        init(_ place: String, _ key: String, matched: String? = nil) {
            self.place = place; self.key = key; self.matched = matched
        }
    }

    /// Place → expected unit key. A bare country key means country-only.
    static let table: [Row] = [
        // ---- England: design §1 counties and their spellings ----------
        Row("Sheffield, West Riding, Yorkshire, England", "eng-yorkshire", matched: "Yorkshire"),
        Row("Leeds, Yorkshire, England, United Kingdom", "eng-yorkshire"),
        Row("Hull, East Riding of Yorkshire, England", "eng-yorkshire"),
        Row("Bradford, West Yorkshire, England", "eng-yorkshire"),
        Row("Whitby, North Riding, Yorkshire, England", "eng-yorkshire"),
        Row("Yorks., England", "eng-yorkshire", matched: "Yorks."),
        Row("Ipswich, Suffolk, England", "eng-suffolk"),
        Row("Canterbury, Kent, England", "eng-kent"),
        Row("Colchester, Essex, England", "eng-essex"),
        Row("Chester, Cheshire, England", "eng-cheshire"),
        Row("Liverpool, Lancashire, England", "eng-lancashire"),
        Row("Norwich, Norfolk, England", "eng-norfolk"),
        Row("Exeter, Devon, England", "eng-devon"),
        Row("Plymouth, Devonshire, England", "eng-devon"),
        Row("Taunton, Somerset, England", "eng-somerset"),
        Row("Bath, Somersetshire, England", "eng-somerset"),
        Row("Carlisle, Cumberland, England", "eng-cumberland"),
        Row("Kendal, Westmorland, England", "eng-westmorland"),
        Row("Kendal, Westmoreland, England", "eng-westmorland"),
        Row("St Ives, Huntingdonshire, England", "eng-huntingdonshire"),
        Row("Boston, Lincolnshire, England", "eng-lincolnshire"),
        Row("County Durham, England", "eng-durham"),
        Row("Leicestershire, England, United Kingdom", "eng-leicestershire"),
        Row("Lewes, East Sussex, England", "eng-sussex"),
        Row("Chichester, West Sussex, England", "eng-sussex"),
        Row("London, England", "eng-middlesex"),
        Row("Greater London, England", "eng-middlesex"),
        Row("Stepney, Middlesex, England", "eng-middlesex"),
        // Old written short forms.
        Row("Shrewsbury, Salop, England", "eng-shropshire"),
        Row("Winchester, Hants, England", "eng-hampshire"),
        Row("Northants, England", "eng-northamptonshire"),
        Row("Oxon, England", "eng-oxfordshire"),
        Row("Bucks, England", "eng-buckinghamshire"),
        Row("Berks, England", "eng-berkshire"),
        Row("Wilts, England", "eng-wiltshire"),
        Row("Lincs, England", "eng-lincolnshire"),
        Row("Cambs, England", "eng-cambridgeshire"),
        Row("Beds, England", "eng-bedfordshire"),
        Row("Herts, England", "eng-hertfordshire"),
        Row("Notts, England", "eng-nottinghamshire"),
        Row("Leics, England", "eng-leicestershire"),
        Row("Warwicks, England", "eng-warwickshire"),
        Row("Staffs, England", "eng-staffordshire"),
        Row("Worcs, England", "eng-worcestershire"),
        Row("Glos, England", "eng-gloucestershire"),
        Row("Middx, England", "eng-middlesex"),
        // Modern names folded to the historic county.
        Row("Manchester, Greater Manchester, England", "eng-lancashire"),
        Row("Penrith, Cumbria, England", "eng-cumberland"),
        // Country only.
        Row("England", "eng", matched: "England"),
        Row("Old England", "eng"),
        Row("Eng.", "eng"),
        Row("Inglaterra", "eng"),
        Row("Somewhere, England, United Kingdom", "eng"),

        // ---- Scotland ----------------------------------------------------
        Row("Aberdeen, Aberdeenshire, Scotland", "sct-aberdeenshire"),
        Row("Aberdeen, Scotland", "sct-aberdeenshire"),
        Row("Aberdeen-shire, Scotland", "sct-aberdeenshire"),
        Row("Perthshire, Scotland", "sct-perthshire"),
        Row("Perth, Scotland", "sct-perthshire"),
        Row("Midlothian, Scotland", "sct-midlothian"),
        Row("Edinburgh, Edinburghshire, Scotland", "sct-midlothian"),
        Row("Fife, Scotland", "sct-fife"),
        Row("Fifeshire, Scotland", "sct-fife"),
        Row("Lanarkshire, Scotland", "sct-lanarkshire"),
        Row("Ayrshire, Scotland", "sct-ayrshire"),
        Row("Dundee, Forfarshire, Scotland", "sct-angus"),
        Row("Angus, Scotland", "sct-angus"),
        Row("Haddingtonshire, Scotland", "sct-east-lothian"),
        Row("Linlithgowshire, Scotland", "sct-west-lothian"),
        Row("Elginshire, Scotland", "sct-morayshire"),
        Row("Argyllshire, Scotland", "sct-argyllshire"),
        Row("Argyll, Scotland", "sct-argyllshire"),
        Row("Inverness-shire, Scotland", "sct-inverness-shire"),
        Row("Inverness, Scotland", "sct-inverness-shire"),
        Row("Ross and Cromarty, Scotland", "sct-ross-shire"),
        Row("Cromarty, Scotland", "sct-cromartyshire"),
        Row("Lothian, Scotland", "sct"),
        Row("Schotland", "sct"),
        Row("Scotland", "sct"),

        // ---- Wales -------------------------------------------------------
        Row("Monmouthshire, Wales", "wls-monmouthshire"),
        Row("Cardiff, Glamorgan, Wales", "wls-glamorgan"),
        Row("Glamorganshire, Wales", "wls-glamorgan"),
        Row("Denbighshire, Wales", "wls-denbighshire"),
        Row("Montgomeryshire, Wales", "wls-montgomeryshire"),
        Row("Caernarfonshire, Wales", "wls-caernarfonshire"),
        Row("Caernarvonshire, Wales", "wls-caernarfonshire"),
        Row("Carnarvonshire, Wales", "wls-caernarfonshire"),
        Row("Brecknockshire, Wales", "wls-brecknockshire"),
        Row("Breconshire, Wales", "wls-brecknockshire"),
        Row("Cardiganshire, Wales", "wls-cardiganshire"),
        Row("Ceredigion, Wales", "wls-cardiganshire"),
        Row("Anglesey, Wales", "wls-anglesey"),
        Row("Ynys Mon, Wales", "wls-anglesey"),
        Row("Merioneth, Wales", "wls-merionethshire"),
        Row("Merionethshire, Wales", "wls-merionethshire"),
        Row("Cymru", "wls"),

        // ---- Ireland and Northern Ireland --------------------------------
        Row("County Antrim, Ireland", "nir-antrim", matched: "County Antrim"),
        Row("Co. Antrim, Ireland", "nir-antrim"),
        Row("Antrim, Ireland", "nir-antrim"),
        Row("Belfast, Antrim, Ulster, Ireland", "nir-antrim"),
        Row("Derry, Ireland", "nir-londonderry"),
        Row("County Londonderry, Northern Ireland", "nir-londonderry"),
        Row("Co. Cork, Ireland", "irl-cork"),
        Row("Cork, County Cork, Ireland", "irl-cork"),
        Row("Kilkenny, Ireland", "irl-kilkenny"),
        Row("Wexford, Ireland", "irl-wexford"),
        Row("Galway, Ireland", "irl-galway"),
        Row("Queen's County, Ireland", "irl-laois"),
        Row("King's County, Ireland", "irl-offaly"),
        Row("Ulster, Ireland", "irl"),
        Row("Munster, Ireland", "irl"),
        Row("Ulster", "irl"),
        Row("Ireland", "irl"),
        Row("Cork, Ireland.", "irl-cork"),
        Row("Belfast, Northern Ireland", "nir"),

        // ---- United States: modern, abbreviated, colonial ----------------
        Row("Chelsea, Suffolk, Massachusetts, United States", "usa-massachusetts"),
        Row("Boston, Suffolk, Massachusetts, USA", "usa-massachusetts"),
        Row("Yorkshire, Virginia, United States", "usa-virginia"),
        Row("Massachusetts", "usa-massachusetts"),
        Row("Providence, Rhode Island", "usa-rhode-island"),
        Row("Hartford, Connecticut", "usa-connecticut"),
        Row("Charleston, South Carolina", "usa-south-carolina"),
        Row("Portland, Maine", "usa-maine"),
        Row("Albany, New York", "usa-new-york"),
        Row("NH", "usa-new-hampshire"),
        Row("VT", "usa-vermont"),
        Row("Louisville, KY", "usa-kentucky"),
        Row("Lowell, Mass.", "usa-massachusetts", matched: "Mass."),
        Row("Lowell, Mass. U.S.A.", "usa-massachusetts"),
        Row("Boston Mass. U.S.A.", "usa-massachusetts"),
        Row("Albany, N.Y.", "usa-new-york"),
        Row("Raleigh, N.C.", "usa-north-carolina"),
        Row("Boston MA", "usa-massachusetts"),
        Row("Washington, D.C.", "usa-district-of-columbia"),
        Row("St. Louis, Mo.", "usa-missouri"),
        Row("Ontario, California", "usa-california"),   // a city in a state, not the province
        Row("Shrewsbury, Worcester, Massachusetts Bay Colony, British Colonial America", "usa-massachusetts", matched: "Massachusetts Bay Colony"),
        Row("Sudbury, Middlesex, Massachusetts Bay Colony", "usa-massachusetts"),
        Row("Massachusetts Bay, British Colonial America", "usa-massachusetts"),
        Row("Province of Massachusetts Bay", "usa-massachusetts"),
        Row("Plymouth, Plymouth Colony", "usa-massachusetts"),
        Row("Colony of New Plymouth", "usa-massachusetts"),
        Row("Hartford, Connecticut Colony", "usa-connecticut"),
        Row("New Haven Colony", "usa-connecticut"),
        Row("Saybrook Colony", "usa-connecticut"),
        Row("Province of New Hampshire", "usa-new-hampshire"),
        Row("Colony of New Hampshire", "usa-new-hampshire"),
        Row("Colony of Rhode Island and Providence Plantations", "usa-rhode-island"),
        Row("New York Colony, British Colonial America", "usa-new-york"),
        Row("Province of Pennsylvania", "usa-pennsylvania"),
        Row("Colony of Virginia", "usa-virginia"),
        Row("Boston, Massachusetts, New England", "usa-massachusetts"),
        Row("Boston Massachusetts Bay Colony", "usa-massachusetts"),
        // Country only.
        Row("Province of Carolina", "usa"),
        Row("Carolina, British Colonial America", "usa"),
        Row("British Colonial America", "usa"),
        Row("New England", "usa"),
        Row("New Netherland", "usa"),
        Row("United States", "usa"),
        Row("USA", "usa"),
        Row("U.S.A.", "usa"),
        Row("Suffolk, United States", "usa"),

        // ---- Canada ------------------------------------------------------
        Row("Stukley, Shefford, Quebec, Canada", "can-quebec"),
        Row("Québec", "can-quebec"),
        Row("Quebec. Canada", "can-quebec"),
        Row("Nova Scotia, Canada", "can-nova-scotia"),
        Row("Halifax, Nova Scotia", "can-nova-scotia"),
        Row("New Brunswick, Canada", "can-new-brunswick"),
        Row("Saint John, Nb", "can-new-brunswick"),
        Row("Saint John, NB, Canada", "can-new-brunswick"),
        Row("Saint John, nb, Canada", "can-new-brunswick"),
        Row("Kingston, Upper Canada", "can-ontario"),
        Row("Montreal, Lower Canada", "can-quebec"),
        Row("Montreal, Province of Quebec", "can-quebec"),
        Row("Montreal, New France", "can"),
        Row("Grand-Pré, Acadia", "can"),
        Row("Canada", "can"),
        Row("Dominion of Canada", "can"),
    ]

    @Test func everySpellingResolvesToItsUnit() {
        for row in Self.table {
            let hit = R.resolve(row.place)
            #expect(hit?.unitKey == row.key, "\(row.place) → \(hit?.unitKey ?? "nil")")
            guard let hit else { continue }
            #expect(hit.isCountryOnly == FamilyMapKey.isCountryKey(row.key), "\(row.place)")
            #expect(hit.country == FamilyMapKey.country(of: row.key), "\(row.place)")
            #expect(hit.kind == (hit.isCountryOnly ? .country : hit.country.unitKind), "\(row.place)")
            if let matched = row.matched { #expect(hit.matchedComponent == matched, "\(row.place)") }
        }
    }

    @Test func unrecognisedAndOffMapPlacesAreNil() {
        let nils: [String?] = [
            nil, "", "   ", "\n",
            "Europe", "Somewhere", "Warsaw, Poland", "Minsk, Russia", "Isle of Man",
            "United Kingdom", "Great Britain", "U.K.",
            "Perth, WA, Australia", "Perth, Australia", "Sydney, New South Wales, Australia",
            // Ambiguous without a country: honest nil, never a guess.
            "Ipswich, Suffolk", "Cambridge, Middlesex", "Perth", "Antrim", "Down", "Derry",
            // Lower-case two-letter words are words.
            "Portland, or", "me", "in",
        ]
        for place in nils {
            #expect(R.resolve(place) == nil, "\(place ?? "nil") → \(R.resolve(place)?.unitKey ?? "nil")")
        }
    }

    @Test func theRightmostCountryConstrainsTheCounty() {
        #expect(R.resolve("Yorkshire, Virginia, United States")?.unitKey == "usa-virginia")
        #expect(R.resolve("Boston, Lincolnshire, England")?.unitKey == "eng-lincolnshire")
        #expect(R.resolve("Boston, Suffolk, Massachusetts, USA")?.unitKey == "usa-massachusetts")
        #expect(R.resolve("Berkshire, Massachusetts, England")?.unitKey == "eng-berkshire",
                "a US state to the left of England is not an English unit; the scan continues")
        #expect(R.resolve("Kent, Ontario, Canada")?.unitKey == "can-ontario")
        #expect(R.resolve("Boston, MA, England")?.unitKey == "eng", "postal codes need a US search set")
    }

    /// Codex #1782 (1): "County Middlesex" / "Suffolk County" / "Co. Essex"
    /// alone resolved while the bare name honestly refused. Ambiguity must
    /// survive decoration: the County / Co. wrapping is stripped BEFORE the
    /// ambiguity check, so a decorated name behaves exactly like the bare
    /// one — nil alone, the unit with a country to its right.
    @Test func decorationDoesNotDefeatTheAmbiguityRule() {
        for place in ["County Middlesex", "Middlesex County", "Suffolk County", "Co. Essex", "Co Essex",
                      "Windsor, Essex County", "County Durham", "Perth County", "Co. Antrim", "Antrim County",
                      "Salem, Essex County"] {
            #expect(R.resolve(place) == nil, "\(place) → \(R.resolve(place)?.unitKey ?? "nil")")
        }
        #expect(R.resolve("County Middlesex, England")?.unitKey == "eng-middlesex")
        #expect(R.resolve("Suffolk County, England")?.unitKey == "eng-suffolk")
        #expect(R.resolve("Co. Essex, England")?.unitKey == "eng-essex")
        #expect(R.resolve("County Durham, England")?.unitKey == "eng-durham")
        #expect(R.resolve("Windsor, Essex County, Ontario, Canada")?.unitKey == "can-ontario")
        #expect(R.resolve("Salem, Essex County, Massachusetts")?.unitKey == "usa-massachusetts")
        #expect(R.resolve("Co. Antrim, Ireland")?.unitKey == "nir-antrim")
        #expect(R.resolve("Perth County, Scotland")?.unitKey == "sct-perthshire")
        // "-shire" is a spelling, never a decoration: the shire form of an
        // ambiguous bare name is unmistakable on its own.
        #expect(R.resolve("Somersetshire")?.unitKey == "eng-somerset")
        #expect(R.resolve("Yorkshire")?.unitKey == "eng-yorkshire")
        #expect(R.undecorated("county middlesex") == "middlesex")
        #expect(R.undecorated("middlesex county") == "middlesex")
        #expect(R.undecorated("co essex") == "essex")
        #expect(R.undecorated("somersetshire") == "somersetshire")
        #expect(R.undecorated("county") == "county", "the word alone is not a decoration of nothing")
    }

    /// Codex #1782 (2): a foreign token to the LEFT of a supported country
    /// used to stop the scan ("France, England" → nil). The contract: the
    /// rightmost recognised supported country wins; foreign tokens to its
    /// left cannot be units of it and are skipped; the scan goes on
    /// leftward for a unit of the established country.
    @Test func theRightmostSupportedCountryWinsOverAForeignTokenToItsLeft() throws {
        let france = try #require(R.resolve("France, England"))
        #expect(france.unitKey == "eng" && france.isCountryOnly)
        #expect(R.resolve("Quebec, France, Canada")?.unitKey == "can-quebec")
        #expect(R.resolve("Sheffield, Yorkshire, Germany, England")?.unitKey == "eng-yorkshire")
        #expect(R.resolve("Boston, Massachusetts, Prussia, United States")?.unitKey == "usa-massachusetts")
        // With no supported country to its right a foreign country still
        // ends the search: "Perth, WA, Australia" is never Washington.
        #expect(R.resolve("Perth, WA, Australia") == nil)
        #expect(R.resolve("Yorkshire, Poland") == nil)
        #expect(R.resolve("England, Poland") == nil, "the rightmost recognised country is Poland")
        #expect(R.resolve("France, United Kingdom") == nil, "a coarse name is not a country")
    }

    @Test func hitCarriesTheDecidingComponentAndTheCallerKeepsTheRaw() throws {
        let raw = "Shrewsbury, Worcester, Massachusetts Bay Colony, British Colonial America"
        let hit = try #require(R.resolve(raw))
        #expect(hit.matchedComponent == "Massachusetts Bay Colony")
        #expect(hit.unitKey == "usa-massachusetts")
        #expect(!hit.isCountryOnly)
        let only = try #require(R.resolve("  England  "))
        #expect(only.matchedComponent == "England")
        #expect(only.isCountryOnly)
        #expect(only.kind == .country)
    }

    @Test func normalisationFoldsCaseDotsDiacriticsAndStrayMarks() {
        #expect(R.normalizedKey("  Yorks.  ") == "yorks")
        #expect(R.normalizedKey("(Wales)") == "wales")
        #expect(R.normalizedKey("England>") == "england")
        #expect(R.normalizedKey("U.S.A.") == "u s a")
        #expect(R.normalizedKey("Inverness-shire") == "inverness-shire")
        #expect(R.normalizedKey("Queen's County") == "queen's county")
        #expect(R.normalizedKey("Québec") == "quebec")
        #expect(R.normalizedKey("Ynys Môn") == "ynys mon")
        #expect(R.normalizedKey("").isEmpty)
        #expect(R.normalizedKey("...").isEmpty)
        // The ASCII fast path and the Foundation path agree (on component
        // text — commas were split off before either runs).
        for s in ["Massachusetts Bay Colony", "Co. Antrim", "N.Y.", "  East   Lothian ", "St. Louis Mo.", "(Wales)"] {
            #expect(R.normalizedKey(s) == R.slowNormalizedKey(s), "\(s)")
        }
    }

    // MARK: Sensor — the keys the border file must carry

    @Test func everyEmittableKeyIsWellFormedAndTheRequiredSetIsStable() {
        let keys = R.allUnitKeys
        for key in keys {
            #expect(FamilyMapKey.country(of: key) != nil, "\(key)")
            #expect(key == key.lowercased(), "\(key)")
            #expect(!key.hasSuffix("-"), "\(key)")
        }
        // The §1 counties, states and provinces the map cannot do without.
        let required = [
            "eng-yorkshire", "eng-suffolk", "eng-kent", "eng-essex", "eng-cheshire", "eng-lancashire",
            "eng-norfolk", "eng-devon", "eng-somerset", "eng-cumberland", "eng-westmorland", "eng-huntingdonshire",
            "sct-aberdeenshire", "sct-perthshire", "sct-midlothian", "sct-fife", "sct-lanarkshire", "sct-ayrshire",
            "sct-angus", "sct-east-lothian",
            "wls-monmouthshire", "wls-glamorgan", "wls-denbighshire", "wls-montgomeryshire",
            "nir-antrim", "irl-kilkenny", "irl-wexford", "irl-galway",
            "usa-massachusetts", "usa-rhode-island", "usa-connecticut", "usa-virginia", "usa-south-carolina",
            "usa-maine", "usa-new-york", "usa-new-hampshire", "usa-vermont",
            "can-quebec", "can-nova-scotia", "can-new-brunswick",
            "eng", "sct", "wls", "nir", "irl", "usa", "can",
        ]
        for key in required { #expect(keys.contains(key), "\(key)") }
        // 39 ENG (Yorkshire whole), 34 SCT (Ross-shire and Cromartyshire apart),
        // 13 WLS, 6 NIR, 26 IRL, 51 USA (+DC), 13 CAN, 7 countries; Western
        // Europe (2026-09-30): 13 FRA régions, 16 DEU Länder, 12 NLD and 11
        // BEL provinces, 13 more countries.
        #expect(keys.count == 39 + 34 + 13 + 6 + 26 + 51 + 13 + 7 + (13 + 16 + 12 + 11 + 13), "\(keys.count) keys")
        #expect(keys.contains("sct-argyllshire") && !keys.contains("sct-argyll"))
        #expect(keys.contains("sct-ross-shire") && keys.contains("sct-cromartyshire"))
        #expect(!keys.contains("eng-london"))
    }

    // MARK: Scale

    /// 40k places from the table, cycled, with the raw string varied so
    /// nothing is memoised. Budget 150 ms (Debug, load-aware).
    @Test func fortyThousandPlacesUnderBudget() {
        let places = Self.table.map(\.place) + ["Warsaw, Poland", "Ipswich, Suffolk", "", "Somewhere"]
        let n = 40_000
        let inputs: [String] = (0..<n).map { i in
            let p = places[i % places.count]
            return i % 3 == 0 ? "Farm \(i), " + p : p
        }
        _ = R.allUnitKeys   // the tables are built once, outside the measured loop
        var resolved = 0
        // Thread CPU time (GH #208): a pure loop, budgeted on what it consumed.
        var wall: Duration = .zero
        let loadBefore = TimingBudget.sampleLoad()
        let cpu = TimingBudget.measureThreadCPUTime {
            wall = ContinuousClock().measure {
                for s in inputs where R.resolve(s) != nil { resolved += 1 }
            }
        }
        print("[family-map] resolve 40k: cpu \(cpu), wall \(wall), \(resolved) resolved (\(TimingBudget.loadDescription()))")
        expectWithinTimingBudget("40k place resolves (CPU)", measured: cpu, budget: .milliseconds(150),
                                 loadBefore: loadBefore)
        #expect(resolved > n * 9 / 10)
    }
}
