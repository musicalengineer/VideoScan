// USPlaceNames.swift (VideoScanCore)
// ONE answer to "does this place name an American state?" for every place
// reader (generated-input sweep, 2026-10-01).
//
// Before this file each reader kept its own list. The research-link reader
// knew the full names and postal codes but not the old written forms, so
// "Kent, Conn" went to the English archives, "Ireland, Ind." to the Irish
// ones and "Antrim, N. H." to PRONI; the classifier knew "Conn." but not
// "Va." inside a comma-less place ("Portsmouth Va. US"); the map resolver
// had a third copy. Five readers, three vocabularies, drifting apart. Now
// BirthplaceClassifier (classify / region), LifeAndTimes.region,
// FamilyTreeResearchLinks.regions, BirthplaceUnitResolver and the app's
// origin-trail / research-hint readers all ask here.
//
// Three kinds of spelling, three rules:
//   • Full names ("New Hampshire", "District of Columbia"): any case.
//   • Written short forms ("Conn.", "Penna.", "Mass", "N. H.", "Ind.",
//     "Tenn.", "Wis."): any case, dots and spaces optional — none of them
//     is an everyday word in a place string.
//   • Two-letter postal codes ("NH", "Va.", "Ky."), and the short forms that
//     ARE ordinary words elsewhere ("Del." — Spanish "del"; "Mont." —
//     French "mont"; "Ark.", "Neb.", "Kan.", "Cal."): only upper-case, or
//     Capitalised with the period. Lower-case "in", "or", "me", "del" are
//     words, never states.
//
// Pure tables and string work. C++ readers: an `enum` with no cases is a
// namespace of static constants and functions.

import Foundation

public enum USPlaceNames {

    /// Full state names (lower-case key) → canonical name.
    static let fullNames: [String: String] = {
        var t: [String: String] = [:]
        for name in USStateCodes.names.values { t[name.lowercased()] = name }
        return t
    }()

    /// Historical written forms, keyed as `BirthplaceClassifier.normalize`
    /// writes them (lower-case, periods → spaces, spaces collapsed), so
    /// "N.H.", "N. H." and "n h" are one key, and "Penna." is "penna".
    static let writtenForms: [String: String] = [
        // New England
        "mass": "Massachusetts", "massachusets": "Massachusetts", "massachusettes": "Massachusetts",
        "massachussets": "Massachusetts", "conn": "Connecticut", "n h": "New Hampshire",
        "r i": "Rhode Island",
        // The rest, alphabetically by state
        "ala": "Alabama", "ariz": "Arizona", "calif": "California", "colo": "Colorado",
        "d c": "District of Columbia", "washington dc": "District of Columbia",
        "washington d c": "District of Columbia", "fla": "Florida", "ill": "Illinois", "ind": "Indiana",
        "kans": "Kansas", "mich": "Michigan", "minn": "Minnesota", "miss": "Mississippi",
        "nebr": "Nebraska", "nev": "Nevada", "n j": "New Jersey", "n m": "New Mexico", "n y": "New York",
        "n c": "North Carolina", "n carolina": "North Carolina", "n d": "North Dakota",
        "n dakota": "North Dakota", "okla": "Oklahoma", "ore": "Oregon", "oreg": "Oregon",
        "penn": "Pennsylvania", "penna": "Pennsylvania", "s c": "South Carolina",
        "s carolina": "South Carolina", "s d": "South Dakota", "s dakota": "South Dakota",
        "tenn": "Tennessee", "tex": "Texas", "wash": "Washington", "w va": "West Virginia",
        "w virginia": "West Virginia", "wis": "Wisconsin", "wisc": "Wisconsin", "wyo": "Wyoming",
    ]

    /// Short forms that are also words or names somewhere a GEDCOM place
    /// might be written: accepted only when Capitalised or upper-case.
    static let capitalisedForms: [String: String] = [
        "del": "Delaware", "mont": "Montana", "ark": "Arkansas", "neb": "Nebraska",
        "kan": "Kansas", "cal": "California",
    ]

    /// The New England states, by canonical name.
    public static let newEnglandStates: Set<String> = [
        "Connecticut", "Maine", "Massachusetts", "New Hampshire", "Rhode Island", "Vermont",
    ]

    /// Every key that names a state in ANY case (full names and written
    /// forms). The map resolver enters these as case-free aliases.
    static var caseFreeForms: [String: String] { fullNames.merging(writtenForms) { a, _ in a } }

    // MARK: - One component

    /// The state one recorded component or token names, or nil. `recorded`
    /// is the text as written — case matters for postal codes ("ME" yes,
    /// "me" no). Dots and spaces are optional ("N.H." = "N. H." = "NH").
    public static func stateName(recorded: String) -> String? {
        let trimmed = recorded.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isLetter || $0 == "." || $0 == " " }) else { return nil }
        let key = BirthplaceClassifier.normalize(trimmed)
        if let name = fullNames[key] ?? writtenForms[key] { return name }
        let letters = trimmed.filter { $0.isLetter }
        if letters.count == 2, let name = USStateCodes.names[letters.uppercased()] {
            if letters == letters.uppercased() { return name }
            // "Ky.", "Va.", "Me." — the old written forms, with the period.
            if letters.first?.isUppercase == true, trimmed.hasSuffix(".") { return name }
            return nil
        }
        if let name = capitalisedForms[key], letters.first?.isUppercase == true { return name }
        return nil
    }

    /// True for the two-letter postal forms under the case rule ("KY",
    /// "Ky.", "N.Y."; never "ky" or "Ky") — `BirthplaceClassifier`'s
    /// original `usAbbreviation` contract, kept for its callers.
    public static func isPostalAbbreviation(_ recorded: String) -> Bool {
        let letters = recorded.filter { $0.isLetter }
        guard letters.count == 2,
              recorded.allSatisfy({ $0.isLetter || $0 == "." || $0 == " " }),
              USStateCodes.names[letters.uppercased()] != nil else { return false }
        if letters == letters.uppercased() { return true }
        return letters.first?.isUppercase == true && recorded.hasSuffix(".")
    }

    // MARK: - A comma part

    /// Country words that may FOLLOW a state inside one comma part
    /// ("Portsmouth Va. US", "Durham N. H. U.S.A."), normalised.
    static let trailingCountryKeys: Set<String> = [
        "us", "u s", "usa", "u s a", "united states", "united states of america", "america",
    ]

    /// The state a comma part names: the whole part, or — once trailing
    /// country words are set aside — its last one to three whitespace
    /// tokens ("Scotland CT", "Durham N. H. U.S.", "Derry New Hampshire").
    /// Never a token in the MIDDLE of a part: "Dublin, Co Dublin" must not
    /// find Colorado in the all-caps "CO DUBLIN".
    public static func stateName(endOf part: String) -> String? {
        if let name = stateName(recorded: part) { return name }
        var tokens = part.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var stripped = true
        while stripped, tokens.count > 1 {
            stripped = false
            for k in stride(from: min(4, tokens.count - 1), through: 1, by: -1) {
                let tail = BirthplaceClassifier.normalize(tokens.suffix(k).joined(separator: " "))
                if trailingCountryKeys.contains(tail) {
                    tokens.removeLast(k)
                    stripped = true
                    break
                }
            }
        }
        guard !tokens.isEmpty else { return nil }
        for k in stride(from: min(3, tokens.count), through: 1, by: -1) {
            if let name = stateName(recorded: tokens.suffix(k).joined(separator: " ")) { return name }
        }
        return nil
    }

    // MARK: - A whole place

    /// Country-level words for the United States, matched anywhere as
    /// whole words. No town names: "Boston" is also Lincolnshire's.
    static let countryPhrases = ["united states", "usa", "u s a", "new england"]

    /// True when the place names the United States anywhere: a country
    /// word, a state written in full, or a comma part that ends in a state
    /// form. Whether an explicit OTHER country outranks it is the caller's
    /// rule (see `FamilyTreeResearchLinks.regions`).
    public static func mentionsUnitedStates(_ place: String) -> Bool {
        let words = " " + FamilyTreeResearchLinks.normalisedWords(place) + " "
        if countryPhrases.contains(where: { words.contains(" \($0) ") }) { return true }
        if fullNames.keys.contains(where: { words.contains(" \($0) ") }) { return true }
        for part in place.split(separator: ",") {
            let text = String(part)
            if BirthplaceClassifier.coarseUS.contains(BirthplaceClassifier.normalize(text)) { return true }
            if stateName(endOf: text) != nil { return true }
        }
        return false
    }
}
