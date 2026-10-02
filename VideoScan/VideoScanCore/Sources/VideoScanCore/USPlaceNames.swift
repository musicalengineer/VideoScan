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
//     words, never states; so are "Co." (County) and "Mt." (Mount), and
//     "Co. Cork" is an Irish county (`isIrishCountyPhrase`).
//   • Position: a bare postal code names a state only in STATE position —
//     the end of a comma part, after any country words. "CO DUBLIN" and
//     "MT VERNON" carry no state (adversarial review 2026-10-01).
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
        let upperCase = letters == letters.uppercased()
        let capitalisedWithPeriod = letters.first?.isUppercase == true && trimmed.hasSuffix(".")
        if letters.count == 2, let name = USStateCodes.names[letters.uppercased()] {
            // "N.H.", "R.I.", "D.C." are dotted INITIALS; "W.I." (West
            // Indies) and "W.A." (Western Australia) only look like them —
            // Wisconsin and Washington are one word, so no record ever
            // wrote them so. Adversarial review 2026-10-01 (ea7b6739).
            if isDottedInitials(trimmed), !areInitials(letters.uppercased(), of: name) { return nil }
            if upperCase { return name }
            // "Ky.", "Va.", "Me." — the old written forms, with the period.
            // Never "Co." (County) or "Mt." (Mount): adversarial review
            // 2026-10-01 (efdf169d) — "Fenlane, Co. Cork" was Colorado.
            // Colorado is "Colo." or the postal "CO"; Montana "Mont." or "MT".
            if capitalisedWithPeriod, !dottedPlaceWords.contains(letters.uppercased()) { return name }
            return nil
        }
        // "Del.", "Mont.", "DEL" — never the bare word "Mont" ("Mont
        // Saint-Michel") or "Del" ("Puerto Del Rosario"): adversarial
        // review 2026-10-01 (cafe2e2d).
        if let name = capitalisedForms[key], upperCase || capitalisedWithPeriod { return name }
        return nil
    }

    /// Two-letter postal codes whose Capitalised dotted form is a place
    /// word, not a state: "Co." is County, "Mt." is Mount.
    static let dottedPlaceWords: Set<String> = ["CO", "MT"]

    /// "N.H.", "N. H", "W.I." — a period BETWEEN the two letters.
    static func isDottedInitials(_ trimmed: String) -> Bool {
        guard let first = trimmed.firstIndex(where: { $0.isLetter }),
              let last = trimmed.lastIndex(where: { $0.isLetter }), first < last else { return false }
        return trimmed[trimmed.index(after: first)..<last].contains(".")
    }

    /// True when `letters` are the initials of `name`'s words, "of" skipped
    /// ("NH" New Hampshire, "DC" District of Columbia).
    static func areInitials(_ letters: String, of name: String) -> Bool {
        let initials = name.split(separator: " ").filter { $0 != "of" }.compactMap(\.first)
        return String(initials).uppercased() == letters
    }

    // MARK: - The Irish county prefix

    /// The 32 counties (normalised; both names where a county has two).
    static let irishCounties: Set<String> = [
        "antrim", "armagh", "carlow", "cavan", "clare", "cork", "derry", "londonderry", "donegal",
        "down", "dublin", "fermanagh", "galway", "kerry", "kildare", "kilkenny", "laois",
        "queen's county", "queens county", "leitrim", "limerick", "longford", "louth", "mayo", "meath",
        "monaghan", "offaly", "king's county", "kings county", "roscommon", "sligo", "tipperary",
        "tyrone", "waterford", "westmeath", "wexford", "wicklow",
    ]

    /// True for "Co. Cork", "Co Mayo", "CO DUBLIN", "County Down": the
    /// Irish county prefix followed by an Irish county. Such a phrase is
    /// Irish, and its "Co"/"CO" is never Colorado (adversarial review
    /// 2026-10-01, efdf169d). "Kent Co." (the US suffix form) is not one.
    public static func isIrishCountyPhrase(_ recorded: String) -> Bool {
        let key = BirthplaceClassifier.normalize(recorded)
        for prefix in ["co ", "county "] where key.hasPrefix(prefix) {
            if irishCounties.contains(String(key.dropFirst(prefix.count))) { return true }
        }
        return false
    }

    /// True for the two-letter postal forms under the case rule ("KY",
    /// "Ky.", "N.Y."; never "ky" or "Ky") — `BirthplaceClassifier`'s
    /// original `usAbbreviation` contract, kept for its callers.
    public static func isPostalAbbreviation(_ recorded: String) -> Bool {
        let letters = recorded.filter { $0.isLetter }
        guard letters.count == 2,
              recorded.allSatisfy({ $0.isLetter || $0 == "." || $0 == " " }),
              let name = USStateCodes.names[letters.uppercased()] else { return false }
        if isDottedInitials(recorded), !areInitials(letters.uppercased(), of: name) { return false }
        if letters == letters.uppercased() { return true }
        return letters.first?.isUppercase == true && recorded.hasSuffix(".")
            && !dottedPlaceWords.contains(letters.uppercased())
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
