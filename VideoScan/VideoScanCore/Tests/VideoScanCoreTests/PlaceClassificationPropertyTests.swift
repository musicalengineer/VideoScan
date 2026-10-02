// PlaceClassificationPropertyTests.swift
// Generated-input properties for the five place readers (Rick approved
// 2026-10-01, after a substring rule classed "Boston, Suffolk,
// Massachusetts" as England and "Derry, New Hampshire" as Ireland):
//
//   BirthplaceClassifier.classify / .region, FamilyTreeResearchLinks.regions,
//   LifeAndTimes.region(ofPlace:), BirthplaceUnitResolver.resolve (which is
//   what FamilyTreeBirthCountries flies a flag from — the app-target sweep
//   is in VideoScanTests/GeneratedInputPropertyTests.swift).
//
// Properties:
//   P1  A US place built from real US towns/counties that share a name with
//       British-Isles ground (Suffolk, Essex, Kent, Wales, Derry, Antrim,
//       Plymouth, Dover, Belfast, Dublin …), in varied comma layouts and
//       state / country spellings, is NEVER British Isles in any reader —
//       and every reader that can name the state names the right one.
//   P2  The mirror: English / Scottish / Welsh / Irish / Northern Irish
//       places in varied forms map to that country in every reader.
//   P3  "New South Wales" is never Wales.
//   P4  Northern Ireland timing: touched by Ireland-scoped events before
//       1922 only, by British-scoped events from 1921 on.
//
// Synthetic, public-repo safe: real US / UK / Irish / Australian PLACE
// names only, no person names at all.

import Foundation
import Testing
@testable import VideoScanCore

// MARK: - Vocabulary

/// A US state and the ways a record writes it.
struct USStateForm {
    let name: String          // canonical, as FamilyMapKey knows it
    let forms: [String]       // "New Hampshire", "NH", "N.H." …
    let newEngland: Bool
}

enum PlaceVocabulary {

    static let states: [String: USStateForm] = {
        let list: [USStateForm] = [
            USStateForm(name: "Massachusetts", forms: ["Massachusetts", "MA", "Mass.", "Mass", "Ma."], newEngland: true),
            USStateForm(name: "New Hampshire", forms: ["New Hampshire", "NH", "N.H.", "N. H."], newEngland: true),
            USStateForm(name: "Connecticut", forms: ["Connecticut", "CT", "Conn.", "Conn"], newEngland: true),
            USStateForm(name: "Maine", forms: ["Maine", "ME", "Me."], newEngland: true),
            USStateForm(name: "Vermont", forms: ["Vermont", "VT", "Vt."], newEngland: true),
            USStateForm(name: "Rhode Island", forms: ["Rhode Island", "RI", "R.I."], newEngland: true),
            USStateForm(name: "New York", forms: ["New York", "NY", "N.Y."], newEngland: false),
            USStateForm(name: "Pennsylvania", forms: ["Pennsylvania", "PA", "Penn.", "Penna.", "Pa."], newEngland: false),
            USStateForm(name: "Delaware", forms: ["Delaware", "DE"], newEngland: false),
            USStateForm(name: "Ohio", forms: ["Ohio", "OH"], newEngland: false),
            USStateForm(name: "Kentucky", forms: ["Kentucky", "KY", "Ky."], newEngland: false),
            USStateForm(name: "Indiana", forms: ["Indiana", "IN", "Ind."], newEngland: false),
            USStateForm(name: "Arkansas", forms: ["Arkansas", "AR"], newEngland: false),
            USStateForm(name: "Virginia", forms: ["Virginia", "VA", "Va."], newEngland: false),
            USStateForm(name: "Michigan", forms: ["Michigan", "MI", "Mich."], newEngland: false),
            USStateForm(name: "Minnesota", forms: ["Minnesota", "MN", "Minn."], newEngland: false),
            USStateForm(name: "Washington", forms: ["Washington", "WA", "Wash."], newEngland: false),
            USStateForm(name: "North Carolina", forms: ["North Carolina", "NC", "N.C."], newEngland: false),
            USStateForm(name: "Georgia", forms: ["Georgia", "GA", "Ga."], newEngland: false),
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
    }()

    /// Real US (town, county, state) triples whose town or county is also a
    /// British-Isles (or European) place name. Town "" = county only.
    static let usPlaces: [(town: String, county: String, state: String)] = [
        ("Boston", "Suffolk", "Massachusetts"), ("Salem", "Essex", "Massachusetts"),
        ("Ipswich", "Essex", "Massachusetts"), ("Quincy", "Norfolk", "Massachusetts"),
        ("Cambridge", "Middlesex", "Massachusetts"), ("Plymouth", "Plymouth", "Massachusetts"),
        ("Wales", "Hampden", "Massachusetts"), ("Worcester", "Worcester", "Massachusetts"),
        ("Bristol", "Bristol", "Rhode Island"), ("Derry", "Rockingham", "New Hampshire"),
        ("Antrim", "Hillsborough", "New Hampshire"), ("Londonderry", "Rockingham", "New Hampshire"),
        ("Dublin", "Cheshire", "New Hampshire"), ("Manchester", "Hillsborough", "New Hampshire"),
        ("Dover", "Strafford", "New Hampshire"), ("Portsmouth", "Rockingham", "New Hampshire"),
        ("Durham", "Strafford", "New Hampshire"), ("Kent", "Litchfield", "Connecticut"),
        ("Manchester", "Hartford", "Connecticut"), ("Windsor", "Hartford", "Connecticut"),
        ("Scotland", "Windham", "Connecticut"), ("Waterford", "New London", "Connecticut"),
        ("Derby", "New Haven", "Connecticut"), ("Belfast", "Waldo", "Maine"), ("York", "York", "Maine"),
        ("Bath", "Sagadahoc", "Maine"), ("Limerick", "York", "Maine"), ("Bangor", "Penobscot", "Maine"),
        ("Newry", "Oxford", "Maine"), ("Paris", "Oxford", "Maine"), ("Norway", "Oxford", "Maine"),
        ("Poland", "Androscoggin", "Maine"), ("Essex", "Chittenden", "Vermont"),
        ("Londonderry", "Windham", "Vermont"), ("Kent", "Portage", "Ohio"), ("Dublin", "Franklin", "Ohio"),
        ("Oxford", "Butler", "Ohio"), ("Glasgow", "Barren", "Kentucky"), ("Dover", "Kent", "Delaware"),
        ("", "Kent", "Delaware"), ("", "Sussex", "Delaware"), ("Lancaster", "Lancaster", "Pennsylvania"),
        ("York", "York", "Pennsylvania"), ("Chester", "Delaware", "Pennsylvania"),
        ("Bristol", "Bucks", "Pennsylvania"), ("Somerset", "Somerset", "Pennsylvania"),
        ("Durham", "Durham", "North Carolina"), ("Ireland", "Dubois", "Indiana"),
        ("Edinburgh", "Johnson", "Indiana"), ("England", "Lonoke", "Arkansas"),
        ("Portsmouth", "Norfolk", "Virginia"), ("", "Middlesex", "Virginia"), ("", "Essex", "Virginia"),
        ("Plymouth", "Wayne", "Michigan"), ("", "Kent", "Michigan"), ("Kilkenny", "Le Sueur", "Minnesota"),
        ("Aberdeen", "Grays Harbor", "Washington"), ("Kent", "King", "Washington"),
        ("Dublin", "Laurens", "Georgia"), ("", "Suffolk", "New York"), ("", "Essex", "New York"),
    ]

    static let usCountryForms = ["", "USA", "U.S.A.", "United States", "United States of America", "US", "U.S."]

    // The mirror: (town, county, country-forms) per British-Isles country.
    struct IslesPlace {
        let town: String
        let county: String
        let countyForms: [String]
    }

    static func isles(_ town: String, _ county: String, irish: Bool = false) -> IslesPlace {
        let forms = irish ? [county, "County \(county)", "Co. \(county)", "Co \(county)"] : [county]
        return IslesPlace(town: town, county: county, countyForms: forms)
    }

    static let england = [
        isles("Ipswich", "Suffolk"), isles("Norwich", "Norfolk"), isles("Chelmsford", "Essex"),
        isles("Canterbury", "Kent"), isles("Plymouth", "Devon"), isles("Bristol", "Gloucestershire"),
        isles("Manchester", "Lancashire"), isles("Leeds", "Yorkshire"), isles("Durham", "Durham"),
        isles("Cambridge", "Cambridgeshire"), isles("Dover", "Kent"), isles("Truro", "Cornwall"),
        isles("Taunton", "Somerset"), isles("Dorchester", "Dorset"), isles("Lincoln", "Lincolnshire"),
        isles("Boston", "Lincolnshire"), isles("Portsmouth", "Hampshire"), isles("Salisbury", "Wiltshire"),
        isles("Chester", "Cheshire"), isles("York", "Yorkshire"),
    ]
    static let scotland = [
        isles("Glasgow", "Lanarkshire"), isles("Edinburgh", "Midlothian"), isles("Aberdeen", "Aberdeenshire"),
        isles("Perth", "Perthshire"), isles("Paisley", "Renfrewshire"), isles("Ayr", "Ayrshire"),
        isles("Dundee", "Angus"), isles("Inverness", "Inverness-shire"), isles("Kirkcaldy", "Fife"),
    ]
    static let wales = [
        isles("Cardiff", "Glamorgan"), isles("Swansea", "Glamorgan"), isles("Carmarthen", "Carmarthenshire"),
        isles("Bangor", "Caernarfonshire"), isles("Wrexham", "Denbighshire"), isles("Newport", "Monmouthshire"),
        isles("Tenby", "Pembrokeshire"),
    ]
    static let ireland = [
        isles("Cork", "Cork", irish: true), isles("Ballina", "Mayo", irish: true), isles("Galway", "Galway", irish: true),
        isles("Limerick", "Limerick", irish: true), isles("Kilkenny", "Kilkenny", irish: true),
        isles("Tralee", "Kerry", irish: true), isles("Waterford", "Waterford", irish: true),
        isles("Wexford", "Wexford", irish: true), isles("Sligo", "Sligo", irish: true), isles("Ennis", "Clare", irish: true),
    ]
    static let northernIreland = [
        isles("Belfast", "Antrim", irish: true), isles("Lisburn", "Antrim", irish: true),
        isles("Derry", "Londonderry", irish: true), isles("Coleraine", "Londonderry", irish: true),
        isles("Armagh", "Armagh", irish: true), isles("Newry", "Down", irish: true),
        isles("Enniskillen", "Fermanagh", irish: true), isles("Omagh", "Tyrone", irish: true),
    ]

    static let newSouthWalesTowns = ["Sydney", "Newcastle", "Wollongong", "Bathurst", "Goulburn", "Orange", "Dubbo"]
}

// MARK: - Generated inputs

/// One generated place — kept STRUCTURED (components with roles plus the
/// rendering choices) so the shrinker can only drop what is optional: a
/// US place always keeps its state, a British-Isles place its county and
/// country. Shrinking the raw text instead turned "Ireland, Dubois, Ind."
/// into "Ireland" — no longer a US place at all.
struct GeneratedPlace: CustomStringConvertible {
    enum Expected: Equatable {
        case us(state: String, newEngland: Bool)
        case england, scotland, wales, ireland
        /// `writtenAsIreland`: the record says "…, Ireland" (pre-1922 style).
        case northernIreland(writtenAsIreland: Bool)
        case newSouthWales
        /// "Ballina, Co. Mayo" — an Irish county with its prefix and no
        /// country at all (adversarial review 2026-10-01, efdf169d).
        case irishCountyNoCountry(northern: Bool)
        /// Foreign places carrying a US-looking short form: "W.I.", "W.A.",
        /// undotted "Mont" / "Del", and bare "Down" beside an English
        /// county (adversarial review 2026-10-01: ea7b6739, cafe2e2d, 0bb392bd).
        case foreignLookalike(downInEngland: Bool)
    }
    struct Part: Equatable {
        var text: String
        /// Never dropped by the shrinker.
        var essential: Bool
        /// A simpler spelling the shrinker may switch to ("Suffolk County"
        /// → "Suffolk", "N. H." → "New Hampshire").
        var plain: String?
    }
    var parts: [Part]
    var separator = ", "
    /// "Derry New Hampshire": words only, no commas.
    var noCommas = false
    var trailingComma = false
    var padded = false
    var upperCase = false
    var lowerCase = false
    let expected: Expected

    var text: String {
        let words = parts.map(\.text).filter { !$0.isEmpty }
        var s = noCommas ? words.joined(separator: " ") : words.joined(separator: separator)
        if trailingComma, !noCommas { s += "," }
        if padded { s = "  " + s + " " }
        if upperCase { s = s.uppercased() } else if lowerCase { s = s.lowercased() }
        return s
    }
    var hasCommas: Bool { text.contains(",") }
    var description: String { "\"\(text)\"" }

    /// Simpler variants that are still the same kind of place.
    var shrinks: [GeneratedPlace] {
        var out: [GeneratedPlace] = []
        for i in parts.indices where !parts[i].essential {
            var c = self
            c.parts.remove(at: i)
            out.append(c)
        }
        for i in parts.indices {
            if let plain = parts[i].plain, plain != parts[i].text {
                var c = self
                c.parts[i].text = plain
                out.append(c)
            }
        }
        for flag in [\GeneratedPlace.trailingComma, \.padded, \.upperCase, \.lowerCase] where self[keyPath: flag] {
            var c = self
            c[keyPath: flag] = false
            out.append(c)
        }
        if separator != ", " {
            var c = self
            c.separator = ", "
            out.append(c)
        }
        return out
    }
}

enum PlaceGenerator {
    typealias Part = GeneratedPlace.Part

    static func style(_ p: inout GeneratedPlace, _ g: inout SeededGenerator) {
        p.separator = g.pick([", ", ",", " , ", ",  ", ", "])
        p.trailingComma = g.chance(0.05)
        p.padded = g.chance(0.05)
    }

    static func usPlace(_ g: inout SeededGenerator) -> GeneratedPlace {
        let p = g.pick(PlaceVocabulary.usPlaces)
        guard let state = PlaceVocabulary.states[p.state] else { preconditionFailure("vocabulary: no state \(p.state)") }
        let stateText = g.pick(state.forms)
        let country = g.pick(PlaceVocabulary.usCountryForms)
        let county: String = {
            switch g.int(0...3) {
            case 0: return p.county + " County"
            case 1: return p.county + " Co."
            default: return p.county
            }
        }()
        let townPart = Part(text: p.town, essential: false)
        let countyPart = Part(text: county, essential: false, plain: p.county)
        let statePart = Part(text: stateText, essential: true, plain: state.name)
        let countryPart = Part(text: country, essential: false)
        let first = p.town.isEmpty ? countyPart : townPart
        var parts: [Part]
        var noCommas = false
        switch g.int(0...5) {
        case 0: parts = [townPart, countyPart, statePart, countryPart]
        case 1: parts = [townPart, countyPart, statePart]
        case 2: parts = [first, statePart, countryPart]
        case 3: parts = [first, statePart]
        case 4: parts = [countyPart, statePart, countryPart]
        default:
            parts = [first, statePart, countryPart]
            noCommas = true
        }
        var place = GeneratedPlace(parts: parts, expected: .us(state: state.name, newEngland: state.newEngland))
        style(&place, &g)
        place.noCommas = noCommas
        // Case: ALL CAPS anywhere; lower case only when the state is written
        // in full (lower-case "me", "in", "n. h." are not codes, by design).
        if g.chance(0.1) {
            place.upperCase = true
        } else if g.chance(0.1), stateText == state.name {
            place.lowerCase = true
        }
        return place
    }

    static func islesPlace(_ g: inout SeededGenerator) -> GeneratedPlace {
        let place: PlaceVocabulary.IslesPlace
        let expected: GeneratedPlace.Expected
        let countryForms: [[String]]
        switch g.int(0...4) {
        case 0:
            place = g.pick(PlaceVocabulary.england)
            expected = .england
            countryForms = [["England"], ["England", "United Kingdom"], ["England", "UK"], ["Eng."], ["England", "Great Britain"]]
        case 1:
            place = g.pick(PlaceVocabulary.scotland)
            expected = .scotland
            countryForms = [["Scotland"], ["Scotland", "United Kingdom"], ["Scotland", "UK"]]
        case 2:
            place = g.pick(PlaceVocabulary.wales)
            expected = .wales
            countryForms = [["Wales"], ["Wales", "United Kingdom"], ["Wales", "UK"]]
        case 3:
            place = g.pick(PlaceVocabulary.ireland)
            expected = .ireland
            countryForms = [["Ireland"], ["Eire"], ["Republic of Ireland"]]
        default:
            place = g.pick(PlaceVocabulary.northernIreland)
            let asIreland = g.chance(0.4)
            expected = .northernIreland(writtenAsIreland: asIreland)
            countryForms = asIreland ? [["Ireland"]]
                : [["Northern Ireland"], ["Northern Ireland", "United Kingdom"], ["Northern Ireland", "UK"]]
        }
        let country = g.pick(countryForms)
        var parts: [Part] = []
        if g.chance(0.7) { parts.append(Part(text: place.town, essential: false)) }
        parts.append(Part(text: g.pick(place.countyForms), essential: true, plain: place.county))
        parts.append(Part(text: country[0], essential: true))
        if country.count > 1 { parts.append(Part(text: country[1], essential: false)) }
        var generated = GeneratedPlace(parts: parts, expected: expected)
        style(&generated, &g)
        generated.upperCase = g.chance(0.1)
        return generated
    }

    static func newSouthWales(_ g: inout SeededGenerator) -> GeneratedPlace {
        let state = g.pick(["New South Wales", "Colony of New South Wales"])
        var parts: [Part] = []
        if g.chance(0.8) { parts.append(Part(text: g.pick(PlaceVocabulary.newSouthWalesTowns), essential: false)) }
        parts.append(Part(text: state, essential: true, plain: "New South Wales"))
        if g.chance(0.5) { parts.append(Part(text: "Australia", essential: false)) }
        var place = GeneratedPlace(parts: parts, expected: .newSouthWales)
        style(&place, &g)
        place.noCommas = g.chance(0.15)
        place.upperCase = g.chance(0.1)
        return place
    }

    /// P5 input: "Ballina, Co. Mayo", "CO DUBLIN", "Lisburn County Antrim".
    static func irishCountyNoCountry(_ g: inout SeededGenerator) -> GeneratedPlace {
        let northern = g.chance(0.35)
        let place = g.pick(northern ? PlaceVocabulary.northernIreland : PlaceVocabulary.ireland)
        let county = g.pick(["Co. \(place.county)", "Co \(place.county)", "County \(place.county)"])
        var parts: [Part] = []
        if g.chance(0.7) { parts.append(Part(text: place.town, essential: false)) }
        parts.append(Part(text: county, essential: true))
        var generated = GeneratedPlace(parts: parts, expected: .irishCountyNoCountry(northern: northern))
        style(&generated, &g)
        generated.noCommas = g.chance(0.2)
        generated.upperCase = g.chance(0.15)
        return generated
    }

    /// P6 input: foreign places that carry a US-looking short form.
    static func foreignLookalike(_ g: inout SeededGenerator) -> GeneratedPlace {
        switch g.int(0...3) {
        case 0:
            let (town, island) = g.pick([("Kingston", "Jamaica"), ("Bridgetown", "Barbados"),
                                         ("Port of Spain", "Trinidad"), ("St. John's", "Antigua"),
                                         ("Basseterre", "St. Kitts")])
            let mark = g.pick(["W.I.", "W. I.", "B.W.I."])
            var p = GeneratedPlace(parts: [Part(text: town, essential: false), Part(text: island, essential: false),
                                           Part(text: mark, essential: true)],
                                   expected: .foreignLookalike(downInEngland: false))
            style(&p, &g)
            p.upperCase = g.chance(0.1)
            return p
        case 1:
            let town = g.pick(["Perth", "Fremantle", "Bunbury", "Geraldton", "Kalgoorlie"])
            var p = GeneratedPlace(parts: [Part(text: town, essential: false), Part(text: g.pick(["W.A.", "W. A."]), essential: true)],
                                   expected: .foreignLookalike(downInEngland: false))
            style(&p, &g)
            return p
        case 2:
            let name = g.pick(["Mont Saint-Michel", "Mont Blanc", "Mont Ventoux", "Puerto Del Rosario",
                               "Castel Del Monte", "Villa Del Rio"])
            var p = GeneratedPlace(parts: [Part(text: name, essential: true)], expected: .foreignLookalike(downInEngland: false))
            style(&p, &g)
            return p
        default:
            let county = g.pick(["Kent", "Surrey", "Sussex", "Essex", "Devon", "Hampshire", "Yorkshire", "Lancashire"])
            var parts = [Part(text: "Down", essential: true), Part(text: county, essential: true)]
            let country = g.pick(["", "England", "United Kingdom", "UK"])
            if !country.isEmpty { parts.append(Part(text: country, essential: false)) }
            var p = GeneratedPlace(parts: parts, expected: .foreignLookalike(downInEngland: true))
            style(&p, &g)
            p.upperCase = g.chance(0.1)
            return p
        }
    }

    static func shrink(_ p: GeneratedPlace) -> [GeneratedPlace] { p.shrinks }
}

// MARK: - Oracles: what each reader must say

/// The five place readers. Each property runs once per reader, so a bug in
/// one reader cannot mask another's, and each turns green on its own fix.
enum PlaceReader: String, CaseIterable, CustomTestStringConvertible {
    case classify, region, researchLinks, lifeAndTimes, unitResolver
    var testDescription: String { rawValue }
}

enum PlaceOracle {
    typealias Region = BirthplaceClassifier.BirthRegion
    static let islesRegions: Set<Region> = [.england, .ireland, .scotland, .wales]
    static let islesResearch: Set<FamilyTreeResearchLinks.Region> = [.england, .ireland, .scotland, .wales]
    static let islesLifeRegions: Set<LifeAndTimes.Region> = [.britain, .england, .ireland, .northernIreland, .scotland, .wales]
    static let islesMap: Set<FamilyMap.Country> = [.england, .scotland, .wales, .ireland, .northernIreland]

    static func research(_ s: Set<FamilyTreeResearchLinks.Region>) -> String { "\(s.map(\.rawValue).sorted())" }

    /// P1a — the headline property: no reader ever says British Isles.
    static func usNeverIsles(_ reader: PlaceReader, _ p: GeneratedPlace) -> String? {
        switch reader {
        case .classify:
            guard let c = BirthplaceClassifier.classify(p.text).country,
                  c == BirthplaceClassifier.unitedKingdom || c == "Ireland" else { return nil }
            return "classify.country = \(c)"
        case .region:
            let r = BirthplaceClassifier.region(p.text)
            return islesRegions.contains(r) ? "region = \(r)" : nil
        case .researchLinks:
            let r = FamilyTreeResearchLinks.regions(ofPlace: p.text)
            return r.isDisjoint(with: islesResearch) ? nil : "regions = \(research(r))"
        case .lifeAndTimes:
            guard let r = LifeAndTimes.region(ofPlace: p.text), islesLifeRegions.contains(r) else { return nil }
            return "LifeAndTimes.region = \(r)"
        case .unitResolver:
            guard let c = BirthplaceUnitResolver.resolve(p.text)?.country, islesMap.contains(c) else { return nil }
            return "resolver country = \(c)"
        }
    }

    /// P1b — the strong form: the reader names the right state (or, for
    /// the readers that only know countries, the United States).
    /// Tolerated, and documented: with NO commas the comma-component
    /// readers (classify, region, LifeAndTimes) may say "unknown", and the
    /// token-wise region reader may say "US, state not recorded" for a
    /// multi-word state ("New Hampshire U.S.") — coarse, never wrong. The
    /// unit resolver reads phrases, so it is held to the exact state in
    /// every layout.
    static func usState(_ reader: PlaceReader, _ p: GeneratedPlace) -> String? {
        guard case .us(let state, let newEngland) = p.expected else { return nil }
        let loose = !p.hasCommas
        switch reader {
        case .classify:
            let place = BirthplaceClassifier.classify(p.text)
            if place.country == BirthplaceClassifier.unitedStates || (loose && place.isUnknown) { return nil }
            return "classify.country = \(place.country ?? "nil")"
        case .region:
            let r = BirthplaceClassifier.region(p.text)
            let want: Region = newEngland ? .newEngland : .restOfUS
            if r == want || (loose && (r == .unknown || r == .unitedStatesUnspecified)) { return nil }
            return "region = \(r), want \(want)"
        case .researchLinks:
            let r = FamilyTreeResearchLinks.regions(ofPlace: p.text)
            return r == [.unitedStates] ? nil : "regions = \(research(r)), want [unitedStates]"
        case .lifeAndTimes:
            let r = LifeAndTimes.region(ofPlace: p.text)
            if r == .unitedStates || (loose && r == nil) { return nil }
            return "LifeAndTimes.region = \(r.map(\.rawValue) ?? "nil")"
        case .unitResolver:
            let key = BirthplaceUnitResolver.resolve(p.text)?.unitKey
            let want = FamilyMapKey.unitKey(country: .unitedStates, name: state)
            return key == want ? nil : "resolver = \(key ?? "nil"), want \(want)"
        }
    }

    struct IslesWant {
        let region: Region
        let country: String
        let research: FamilyTreeResearchLinks.Region
        let life: LifeAndTimes.Region
        let map: FamilyMap.Country
    }

    static func islesWant(_ e: GeneratedPlace.Expected) -> IslesWant? {
        let uk = BirthplaceClassifier.unitedKingdom
        switch e {
        case .england: return IslesWant(region: .england, country: uk, research: .england, life: .england, map: .england)
        case .scotland: return IslesWant(region: .scotland, country: uk, research: .scotland, life: .scotland, map: .scotland)
        case .wales: return IslesWant(region: .wales, country: uk, research: .wales, life: .wales, map: .wales)
        case .ireland: return IslesWant(region: .ireland, country: "Ireland", research: .ireland, life: .ireland, map: .ireland)
        case .northernIreland(let asIreland):
            // The region table counts the island as Ireland; Life & Times
            // and the map know Northern Ireland from its county / town.
            return IslesWant(region: .ireland, country: asIreland ? "Ireland" : uk, research: .ireland,
                             life: .northernIreland, map: .northernIreland)
        default: return nil
        }
    }

    /// P2 — the mirror.
    static func isles(_ reader: PlaceReader, _ p: GeneratedPlace) -> String? {
        guard let want = islesWant(p.expected) else { return nil }
        switch reader {
        case .classify:
            let c = BirthplaceClassifier.classify(p.text).country
            return c == want.country ? nil : "classify.country = \(c ?? "nil"), want \(want.country)"
        case .region:
            let r = BirthplaceClassifier.region(p.text)
            return r == want.region ? nil : "region = \(r), want \(want.region)"
        case .researchLinks:
            // Never a WRONG region; exactly the right one whenever the
            // country is spelled out in full ("Eng." is a spelling only the
            // region table documents).
            let r = FamilyTreeResearchLinks.regions(ofPlace: p.text)
            let abbreviated = p.text.lowercased().contains("eng.")
            if r.isSubset(of: [want.research]), !(r.isEmpty && !abbreviated) { return nil }
            return "regions = \(research(r)), want [\(want.research.rawValue)]"
        case .lifeAndTimes:
            let r = LifeAndTimes.region(ofPlace: p.text)
            return r == want.life ? nil : "LifeAndTimes.region = \(r.map(\.rawValue) ?? "nil"), want \(want.life)"
        case .unitResolver:
            let c = BirthplaceUnitResolver.resolve(p.text)?.country
            return c == want.map ? nil : "resolver country = \(c.map { "\($0)" } ?? "nil"), want \(want.map)"
        }
    }

    static let usRegions: Set<Region> = [.newEngland, .restOfUS, .unitedStatesUnspecified]

    /// No reader calls the place American.
    static func notUS(_ reader: PlaceReader, _ p: GeneratedPlace) -> String? {
        switch reader {
        case .classify:
            return BirthplaceClassifier.classify(p.text).country == BirthplaceClassifier.unitedStates
                ? "classify.country = United States" : nil
        case .region:
            let r = BirthplaceClassifier.region(p.text)
            return usRegions.contains(r) ? "region = \(r)" : nil
        case .researchLinks:
            return FamilyTreeResearchLinks.regions(ofPlace: p.text).contains(.unitedStates) ? "regions ∋ unitedStates" : nil
        case .lifeAndTimes:
            return LifeAndTimes.region(ofPlace: p.text) == .unitedStates ? "LifeAndTimes.region = unitedStates" : nil
        case .unitResolver:
            return BirthplaceUnitResolver.resolve(p.text)?.country == .unitedStates ? "resolver country = unitedStates" : nil
        }
    }

    /// P5 — "Co. <Irish county>" with no country: never American, and the
    /// region / Life & Times readers say Ireland (Northern Ireland for the
    /// six counties when the county is its own comma part).
    static func irishCounty(_ reader: PlaceReader, _ p: GeneratedPlace) -> String? {
        guard case .irishCountyNoCountry(let northern) = p.expected else { return nil }
        if let wrong = notUS(reader, p) { return wrong }
        switch reader {
        case .region:
            let r = BirthplaceClassifier.region(p.text)
            return r == .ireland ? nil : "region = \(r), want ireland"
        case .lifeAndTimes:
            let r = LifeAndTimes.region(ofPlace: p.text)
            if northern, p.hasCommas { return r == .northernIreland ? nil : "LifeAndTimes.region = \(r.map(\.rawValue) ?? "nil"), want northernIreland" }
            return r == .ireland || r == .northernIreland ? nil : "LifeAndTimes.region = \(r.map(\.rawValue) ?? "nil"), want the island"
        default:
            return nil
        }
    }

    /// P6 — foreign look-alikes are never American, and "Down" beside an
    /// English county is never Northern Ireland.
    static func foreign(_ reader: PlaceReader, _ p: GeneratedPlace) -> String? {
        guard case .foreignLookalike(let downInEngland) = p.expected else { return nil }
        if let wrong = notUS(reader, p) { return wrong }
        guard downInEngland else { return nil }
        switch reader {
        case .lifeAndTimes:
            return LifeAndTimes.region(ofPlace: p.text) == .northernIreland ? "LifeAndTimes.region = northernIreland" : nil
        case .unitResolver:
            return BirthplaceUnitResolver.resolve(p.text)?.country == .northernIreland ? "resolver country = northernIreland" : nil
        default:
            return nil
        }
    }

    /// P3.
    static func notWales(_ reader: PlaceReader, _ p: GeneratedPlace) -> String? {
        switch reader {
        case .classify:
            return BirthplaceClassifier.classify(p.text).country == BirthplaceClassifier.unitedKingdom ? "classify.country = United Kingdom" : nil
        case .region:
            return BirthplaceClassifier.region(p.text) == .wales ? "region = wales" : nil
        case .researchLinks:
            return FamilyTreeResearchLinks.regions(ofPlace: p.text).contains(.wales) ? "regions ∋ wales" : nil
        case .lifeAndTimes:
            return LifeAndTimes.region(ofPlace: p.text) == .wales ? "LifeAndTimes.region = wales" : nil
        case .unitResolver:
            return BirthplaceUnitResolver.resolve(p.text)?.country == .wales ? "resolver country = wales" : nil
        }
    }
}

// MARK: - Suites

// Two-argument parameterization: Swift Testing runs the cartesian product,
// reader × batch (5 × 8 = 40 cases) — like a gtest TEST_P over a Combine()
// of two value lists.
@Suite("Place classification — generated inputs")
struct PlaceClassificationPropertyTests {

    @Test("P1a: a US place sharing a British-Isles name is never British Isles",
          arguments: PlaceReader.allCases, Property.batches)
    func usPlaceNeverBritishIsles(reader: PlaceReader, batch: Int) {
        Property.check("us-never-isles/\(reader)", batch: batch, generate: PlaceGenerator.usPlace,
                       shrink: PlaceGenerator.shrink) { PlaceOracle.usNeverIsles(reader, $0) }
    }

    @Test("P1b: a US place maps to its own state (or the United States)",
          arguments: PlaceReader.allCases, Property.batches)
    func usPlaceMapsToItsState(reader: PlaceReader, batch: Int) {
        Property.check("us-state/\(reader)", batch: batch, generate: PlaceGenerator.usPlace,
                       shrink: PlaceGenerator.shrink) { PlaceOracle.usState(reader, $0) }
    }

    @Test("P2: English, Scottish, Welsh, Irish and Northern Irish places map to that country",
          arguments: PlaceReader.allCases, Property.batches)
    func islesPlaceMapsCorrectly(reader: PlaceReader, batch: Int) {
        Property.check("isles-mirror/\(reader)", batch: batch, generate: PlaceGenerator.islesPlace,
                       shrink: PlaceGenerator.shrink) { PlaceOracle.isles(reader, $0) }
    }

    @Test("P3: New South Wales is never Wales", arguments: PlaceReader.allCases, Property.batches)
    func newSouthWalesIsNeverWales(reader: PlaceReader, batch: Int) {
        Property.check("nsw-not-wales/\(reader)", batch: batch, cases: 250, generate: PlaceGenerator.newSouthWales,
                       shrink: PlaceGenerator.shrink) { PlaceOracle.notWales(reader, $0) }
    }

    @Test("P5: an Irish county with its Co./County prefix and no country is Irish, never Colorado",
          arguments: PlaceReader.allCases, Property.batches)
    func irishCountyWithoutCountryIsIrish(reader: PlaceReader, batch: Int) {
        Property.check("irish-county-no-country/\(reader)", batch: batch, cases: 250,
                       generate: PlaceGenerator.irishCountyNoCountry,
                       shrink: PlaceGenerator.shrink) { PlaceOracle.irishCounty(reader, $0) }
    }

    @Test("P6: W.I., W.A., undotted Mont/Del and Down-beside-an-English-county are never American",
          arguments: PlaceReader.allCases, Property.batches)
    func foreignLookalikesAreNeverAmerican(reader: PlaceReader, batch: Int) {
        Property.check("foreign-lookalike/\(reader)", batch: batch, cases: 250,
                       generate: PlaceGenerator.foreignLookalike,
                       shrink: PlaceGenerator.shrink) { PlaceOracle.foreign(reader, $0) }
    }

    @Test("generator coverage: the adversarial-review shapes all occur")
    func adversarialShapesCoverage() {
        var coDot = 0, westIndies = 0, westernAustralia = 0, undotted = 0, downKent = 0
        for index in 0..<1_000 {
            var g = SeededGenerator(seed: Property.seed(property: "adv-coverage", batch: 0, index: index))
            let irish = PlaceGenerator.irishCountyNoCountry(&g).text.lowercased()
            if irish.contains("co. ") { coDot += 1 }
            let t = PlaceGenerator.foreignLookalike(&g).text.lowercased()
            if t.contains("w.i.") || t.contains("w. i.") { westIndies += 1 }
            if t.contains("w.a.") || t.contains("w. a.") { westernAustralia += 1 }
            if t.hasPrefix("mont ") || t.contains(" del ") { undotted += 1 }
            if t.hasPrefix("down,") || t.hasPrefix("down ,") { downKent += 1 }
        }
        for (label, n) in [("Co. <county>", coDot), ("W.I.", westIndies), ("W.A.", westernAustralia),
                           ("undotted Mont/Del", undotted), ("Down, <English county>", downKent)] {
            #expect(n > 20, "\(label) generated: \(n) of 1,000")
        }
    }

    @Test("P4: Northern Ireland is touched by Irish events before 1922 and British events from 1921")
    func northernIrelandTiming() {
        Property.check("ni-timing", batch: 0, cases: 2_000, generate: { g -> (Int, LifeAndTimes.Region) in
            (g.int(1600...2025), g.pick([.ireland, .england, .scotland, .wales, .britain, .france, .unitedStates]))
        }, describe: { "year \($0.0), scope \($0.1)" }) { input in
            let (year, scope) = input
            let touched = LifeAndTimes.Region.northernIreland.touched(by: [scope], in: year)
            let want: Bool
            switch scope {
            case .ireland: want = year < 1922
            case .england, .scotland, .wales, .britain: want = year >= 1921
            default: want = false
            }
            return touched == want ? nil : "touched = \(touched), want \(want)"
        }
    }

    /// The generator really makes the layouts the properties claim.
    @Test("generator coverage: every layout, spelling and style occurs")
    func generatorCoverage() {
        var noCommas = 0, upper = 0, lower = 0, dotted = 0, oldForm = 0, countyDecorated = 0, countryCase = 0
        for index in 0..<2_000 {
            var g = SeededGenerator(seed: Property.seed(property: "place-coverage", batch: 0, index: index))
            let p = PlaceGenerator.usPlace(&g)
            if p.noCommas { noCommas += 1 }
            if p.upperCase { upper += 1 }
            if p.lowerCase { lower += 1 }
            let t = p.text
            if t.contains("N.H.") || t.contains("N. H.") || t.contains("R.I.") || t.contains("N.Y.") { dotted += 1 }
            if t.contains("Mass") || t.contains("Conn") || t.contains("Penn") { oldForm += 1 }
            if t.contains(" County") || t.contains(" Co.") { countyDecorated += 1 }
            if ["Ireland", "England", "Scotland", "Wales"].contains(p.parts.first?.text ?? "") { countryCase += 1 }
        }
        for (label, n) in [("no-comma", noCommas), ("upper", upper), ("lower", lower), ("dotted", dotted),
                           ("old form", oldForm), ("county decorated", countyDecorated), ("town named a country", countryCase)] {
            #expect(n > 20, "\(label) layouts generated: \(n) of 2,000")
        }
    }

    /// The harness itself: a property that is false must be reported, with
    /// a seed — otherwise every green above is meaningless.
    @Test("harness: a false property is reported, and shrinking keeps the place a US place")
    func harnessReportsFailures() {
        var failures = 0
        withKnownIssue("deliberately false property") {
            failures = Property.check("harness-self-test", batch: 0, cases: 50, generate: PlaceGenerator.usPlace,
                                      shrink: PlaceGenerator.shrink) { p in
                p.hasCommas ? "has a comma" : nil
            }
        }
        #expect(failures > 0)
        // A property that always fails shrinks to the essential part only,
        // in its plain spelling: the state's own name.
        var g = SeededGenerator(seed: 1)
        let place = PlaceGenerator.usPlace(&g)
        let (minimal, _) = Property.shrunk(place, reason: "", shrink: PlaceGenerator.shrink) { _ in "always" }
        guard case .us(let state, _) = minimal.expected else {
            Issue.record("not a US place")
            return
        }
        #expect(minimal.text == state)
    }
}
