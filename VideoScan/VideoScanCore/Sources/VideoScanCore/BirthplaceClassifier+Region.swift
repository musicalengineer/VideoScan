// BirthplaceClassifier+Region.swift (VideoScanCore)
// The Family Tree Walk's birth REGION (Rick 2026-09-27): not "which country
// holds that ground today" (the classifier's job) but the handful of regions
// a New England family's story is told in — New England, the rest of the
// US, England ("Old England"), Ireland, Scotland, Wales, Canada, elsewhere.
//
// Why a separate answer: the classifier maps Massachusetts AND Ohio to the
// United States and England AND Scotland to the United Kingdom. Both are
// right for continent questions and useless for "how many were born in New
// England vs Old England".
//
// Rule: scan the PLAC components from the RIGHT (largest place first). A
// country-level component (United States, United Kingdom, America) is
// COARSE — remember it and keep scanning left for something finer (a state,
// England). The first FINE component decides. "Boston, Suffolk,
// Massachusetts, United States" → US (coarse) → Massachusetts → New England.
// "Leicestershire, England, United Kingdom" → UK (coarse) → England.
// Nothing fine found → the coarse answer ("United States, state not
// recorded"), then the classifier's country (Germany → other), then unknown.
//
// "New England" is a WHOLE component, never a substring: "england" must
// not match it (codex #1180), and "Old England" is England.
//
// Table-driven; pure. (C++: a namespace-scope lookup table + one function.)

import Foundation

extension BirthplaceClassifier {

    /// The regions the tree walk counts births by. `unitedStatesUnspecified`
    /// is not in Rick's list on purpose-by-honesty: a place recorded only as
    /// "USA" or "British Colonial America" is certainly American and cannot
    /// be called New England or not.
    public enum BirthRegion: String, Sendable, Codable, CaseIterable, Equatable {
        case newEngland
        case restOfUS
        case unitedStatesUnspecified
        case england
        case ireland
        case scotland
        case wales
        case canada
        case other
        case unknown

        public var label: String {
            switch self {
            case .newEngland: return "New England"
            case .restOfUS: return "Rest of US"
            case .unitedStatesUnspecified: return "US (state not recorded)"
            case .england: return "England"
            case .ireland: return "Ireland"
            case .scotland: return "Scotland"
            case .wales: return "Wales"
            case .canada: return "Canada"
            case .other: return "Elsewhere"
            case .unknown: return "Unknown"
            }
        }
    }

    /// One recorded place → its region. Nil / empty place → `.unknown`.
    public static func region(_ raw: String?) -> BirthRegion {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .unknown }
        let parts = components(of: raw)
        var coarse: BirthRegion?
        for component in parts.reversed() {
            switch regionOfComponent(component) {
            case .fine(let r): return r
            case .coarse(let r): if coarse == nil { coarse = r }
            case .none: continue
            }
        }
        if let coarse { return coarse }
        // Nothing in the region tables: fall back on the country classifier
        // (Germany, Prussia, Mexico …) — recognised = elsewhere.
        let place = classify(raw)
        if place.isAmbiguous || place.isUnknown { return .unknown }
        switch place.country {
        case unitedStates?: return .unitedStatesUnspecified
        case canada?: return .canada
        default: return .other
        }
    }

    private enum ComponentRegion {
        case fine(BirthRegion)
        case coarse(BirthRegion)
        case none
    }

    /// One component, whole first; failing that its whitespace PHRASES
    /// from the right, longest first at each position ("Mass. U.S.A." →
    /// "U.S.A." coarse, then "Mass." fine). Phrases, not single tokens, so
    /// "Sydney New South Wales" is New South Wales — never its last word
    /// "Wales" (generated-input F3) — and "Derry New Hampshire" is New
    /// Hampshire. The same scan as BirthplaceUnitResolver's.
    private static func regionOfComponent(_ component: String) -> ComponentRegion {
        let whole = regionOfToken(component)
        if case .none = whole {} else { return whole }
        let tokens = component.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count > 1 else { return .none }
        var coarse: ComponentRegion = .none
        var end = tokens.count
        while end > 0 {
            var consumed = 1
            // The whole component (length == tokens.count) was tried above.
            for length in stride(from: min(4, end), through: 1, by: -1) where length < tokens.count {
                let phrase = regionOfToken(tokens[(end - length)..<end].joined(separator: " "))
                if case .fine(let r) = phrase { return .fine(r) }
                if case .coarse(let r) = phrase {
                    if case .none = coarse { coarse = .coarse(r) }
                    consumed = length
                    break
                }
            }
            end -= consumed
        }
        return coarse
    }

    private static func regionOfToken(_ raw: String) -> ComponentRegion {
        // Stray punctuation from hand-typed places ("England>", "(Wales)").
        let recorded = raw.trimmingCharacters(in: CharacterSet.letters.union(.whitespaces).union(CharacterSet(charactersIn: ".")).inverted)
        let key = normalize(recorded)
        guard !key.isEmpty else { return .none }
        if let fine = regionTable[key] { return .fine(fine) }
        if coarseUS.contains(key) { return .coarse(.unitedStatesUnspecified) }
        if coarseOther.contains(key) { return .coarse(.other) }
        if elsewhere.contains(key) { return .fine(.other) }
        // A state in any spelling the shared reader knows: full names,
        // the old written forms ("Penn.", "Ind.", "N. H."), and the postal
        // codes under the case rule ("Ma." yes; "me" in lower case is a
        // word) — generated-input F1/F4.
        if let state = USPlaceNames.stateName(recorded: recorded) {
            return .fine(USPlaceNames.newEnglandStates.contains(state) ? .newEngland : .restOfUS)
        }
        if usStates.contains(key) { return .fine(.restOfUS) }
        if canadianProvinces.contains(key) { return .fine(.canada) }
        if let entry = countries[key] {
            if entry.ambiguous { return .fine(.unknown) }
            if entry.country == unitedStates { return .fine(.restOfUS) }   // "province of new york", "virginia colony"
            if entry.country == canada { return .fine(.canada) }
            return .fine(.other)
        }
        return .none
    }

    /// Normalized key → a FINE region. Colonial spellings included.
    static let regionTable: [String: BirthRegion] = {
        var t: [String: BirthRegion] = [:]
        func add(_ names: [String], _ region: BirthRegion) { for n in names { t[n] = region } }
        add([
            "new england",
            // The six states and their old written forms.
            "connecticut", "conn", "ct",
            "massachusetts", "mass", "massachusets", "massachusettes", "massachussets",
            "maine", "district of maine", "province of maine",
            "new hampshire", "n h", "province of new hampshire", "new hampshire colony",
            "rhode island", "r i", "rhode island colony", "rhode island and providence plantations",
            "colony of rhode island and providence plantations", "providence plantations",
            "vermont", "vt", "new connecticut", "republic of vermont",
            // Colonial names of New England ground.
            "massachusetts bay colony", "massachusetts bay", "province of massachusetts bay",
            "colony of massachusetts bay", "plymouth colony", "plimoth colony", "plymouth plantation",
            "new plymouth", "colony of new plymouth", "connecticut colony", "colony of connecticut",
            "new haven colony", "saybrook colony",
        ], .newEngland)
        // The old written short form and the names FamilySearch users type
        // in their own languages (seen on Rick's tree 2026-09-27: "Eng.",
        // "Inglaterra", "Angleterre", "Schotland" …).
        add(["england", "old england", "kingdom of england", "eng", "engl",
             "inglaterra", "angleterre", "engeland", "england uk", "inghilterra"], .england)
        add(["ireland", "eire", "republic of ireland", "irish free state", "northern ireland", "ire",
             "kingdom of ireland", "irlanda", "irlande", "ierland", "irland"], .ireland)
        add(["scotland", "kingdom of scotland", "scot", "schotland", "escocia", "ecosse", "schottland", "scozia"], .scotland)
        add(["wales", "cymru", "gales", "pays de galles"], .wales)
        return t
    }()

    /// Country-level names for the US and its colonial whole: coarse.
    static let coarseUS: Set<String> = [
        "united states", "united states of america", "usa", "us", "u s", "u s a", "america",
        "the united states", "british colonial america", "colonial america", "american colonies",
        "thirteen colonies", "british america colonies",
    ]

    /// Country-level names that contain England/Scotland/Wales/N. Ireland:
    /// coarse — a finer component to the left decides; alone they are
    /// "elsewhere" (a UK birth whose constituent country was not recorded).
    static let coarseOther: Set<String> = [
        "united kingdom", "uk", "u k", "great britain", "britain", "kingdom of great britain",
        "united kingdom of great britain and ireland", "reino unido", "royaume-uni", "royaume uni",
        "verenigd koninkrijk", "vereinigtes konigreich", "regno unito",
    ]

    /// Recognised places outside every named region (the classifier does
    /// not know these spellings): elsewhere.
    static let elsewhere: Set<String> = [
        "europe", "danmark", "nederland", "deutschland", "sverige", "norge", "france", "espana",
        "belgique", "belgie", "schweiz", "suisse", "osterreich", "italia", "polska",
    ]
}
