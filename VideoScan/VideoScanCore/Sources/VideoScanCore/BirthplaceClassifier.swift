// BirthplaceClassifier.swift
// Reads the country and continent out of a GEDCOM place string (Rick,
// 2026-09-02: "listing the birth locations on her maternal side … how
// many generations go back before you get to European birthplaces").
//
// A GEDCOM PLAC is a comma list from the smallest place to the largest:
// "Chelsea, Suffolk, Massachusetts, United States". The RIGHTMOST
// component decides — that is the country, a US state (which implies the
// country), a Canadian province, or a colonial-era name that is mapped to
// the country holding that ground today ("Massachusetts Bay Colony" →
// United States). Anything the tables do not know is `.unknown` and the
// caller must say so; nothing is ever guessed from a town name.
//
// Pure: a table lookup, no I/O. C++ readers: this is a `namespace` of
// static functions and constant tables; `enum` with no cases is Swift's
// idiom for a type that can never be instantiated.

import Foundation

public enum BirthplaceClassifier {

    public enum Continent: String, Sendable, Equatable, CaseIterable {
        case northAmerica = "North America"
        case southAmerica = "South America"
        case europe = "Europe"
        case asia = "Asia"
        case africa = "Africa"
        case oceania = "Oceania"
    }

    /// What a place string says about where the birth happened.
    public struct Place: Sendable, Equatable {
        /// The place string as recorded, untouched.
        public let raw: String
        /// The component that decided the classification, as recorded
        /// ("British Colonial America", "KY", "Ireland"); nil when nothing
        /// was recognised.
        public let recordedCountry: String?
        /// The present-day sovereign country, when one holds that ground
        /// today ("United States", "United Kingdom", "Canada"). Nil for a
        /// historical state split across today's borders (Prussia) and for
        /// an unknown place.
        public let country: String?
        /// Set whenever the place is recognised at all — a historical
        /// state still has a continent.
        public let continent: Continent?
        /// True when the recorded name was a colonial-era or historical
        /// name mapped to today's borders (the prose says so).
        public let mappedFromHistoricalName: Bool

        /// Nothing in the tables matched — the walk reports the place
        /// verbatim and never treats it as inside or outside anywhere.
        public var isUnknown: Bool { continent == nil }

        public static func unknown(_ raw: String) -> Place {
            Place(raw: raw, recordedCountry: nil, country: nil, continent: nil,
                  mappedFromHistoricalName: false)
        }

        /// The stop-rule test for "outside <country>": known, and not that
        /// country. An unknown place is never "outside" anything.
        public func isOutside(country name: String) -> Bool {
            guard continent != nil else { return false }
            return country != name
        }

        public func isIn(_ target: Continent) -> Bool { continent == target }
    }

    // MARK: - Classification

    public static func classify(_ raw: String) -> Place {
        let components = raw.split(separator: ",").map(String.init)
        // "Quebec. Canada" — some exports use a period between the last
        // two components; only tried when there is no comma at all.
        let parts: [String] = components.count > 1
            ? components
            : raw.split(separator: ".").map(String.init)
        guard let last = parts.last(where: { !normalize($0).isEmpty }) else {
            return .unknown(raw)
        }
        let key = normalize(last)
        let recorded = last.trimmingCharacters(in: CharacterSet(charactersIn: " ."))

        if let entry = countries[key] {
            return Place(raw: raw, recordedCountry: recorded, country: entry.country,
                         continent: entry.continent, mappedFromHistoricalName: entry.historical)
        }
        if usStates.contains(key) || usAbbreviation(recorded) {
            return Place(raw: raw, recordedCountry: recorded, country: unitedStates,
                         continent: .northAmerica, mappedFromHistoricalName: false)
        }
        if canadianProvinces.contains(key) {
            return Place(raw: raw, recordedCountry: recorded, country: canada,
                         continent: .northAmerica, mappedFromHistoricalName: false)
        }
        return .unknown(raw)
    }

    public static let unitedStates = "United States"
    public static let canada = "Canada"
    public static let unitedKingdom = "United Kingdom"

    // MARK: - Tables

    struct Entry {
        let country: String?
        let continent: Continent
        let historical: Bool
    }

    /// Lower-cased, diacritic-folded, period-free keys.
    static let countries: [String: Entry] = {
        var t: [String: Entry] = [:]
        func add(_ names: [String], _ country: String?, _ continent: Continent, historical: Bool = false) {
            for n in names { t[n] = Entry(country: country, continent: continent, historical: historical) }
        }
        // United States — present-day names and the colonial-era names of
        // the same ground.
        add(["united states", "united states of america", "usa", "us", "u s", "u s a", "america",
             "the united states", "new england"], unitedStates, .northAmerica)
        add(["british colonial america", "colonial america", "british america", "american colonies",
             "thirteen colonies", "massachusetts bay colony", "massachusetts bay",
             "province of massachusetts bay", "colony of massachusetts bay", "plymouth colony",
             "connecticut colony", "colony of connecticut", "new haven colony",
             "province of new hampshire", "new hampshire colony", "province of new york",
             "new york colony", "new netherland", "new netherlands", "province of pennsylvania",
             "pennsylvania colony", "colony of virginia", "virginia colony", "province of maryland",
             "maryland colony", "province of north carolina", "province of south carolina",
             "province of carolina", "province of new jersey", "new jersey colony",
             "colony of rhode island and providence plantations", "rhode island colony",
             "delaware colony", "province of georgia", "province of maine"],
            unitedStates, .northAmerica, historical: true)
        // Canada — present-day and the names it went by.
        add(["canada"], canada, .northAmerica)
        add(["new france", "acadia", "acadie", "lower canada", "upper canada", "canada east",
             "canada west", "british north america", "province of canada"],
            canada, .northAmerica, historical: true)
        add(["mexico"], "Mexico", .northAmerica)
        add(["cuba"], "Cuba", .northAmerica)
        add(["jamaica"], "Jamaica", .northAmerica)
        add(["bermuda"], "Bermuda", .northAmerica)
        add(["bahamas", "the bahamas"], "Bahamas", .northAmerica)
        add(["barbados"], "Barbados", .northAmerica)

        // The British Isles.
        add(["ireland", "eire", "republic of ireland"], "Ireland", .europe)
        add(["england", "scotland", "wales", "northern ireland", "united kingdom", "uk", "u k",
             "great britain", "britain", "isle of man", "guernsey", "channel islands"],
            unitedKingdom, .europe)
        // The continent: present-day countries.
        add(["germany", "deutschland"], "Germany", .europe)
        add(["netherlands", "the netherlands", "holland"], "Netherlands", .europe)
        add(["france"], "France", .europe)
        add(["italy"], "Italy", .europe)
        add(["poland"], "Poland", .europe)
        add(["sweden"], "Sweden", .europe)
        add(["norway"], "Norway", .europe)
        add(["denmark"], "Denmark", .europe)
        add(["finland"], "Finland", .europe)
        add(["iceland"], "Iceland", .europe)
        add(["spain"], "Spain", .europe)
        add(["portugal"], "Portugal", .europe)
        add(["austria"], "Austria", .europe)
        add(["hungary"], "Hungary", .europe)
        add(["switzerland"], "Switzerland", .europe)
        add(["belgium"], "Belgium", .europe)
        add(["luxembourg"], "Luxembourg", .europe)
        add(["russia"], "Russia", .europe)
        add(["lithuania"], "Lithuania", .europe)
        add(["latvia"], "Latvia", .europe)
        add(["estonia"], "Estonia", .europe)
        add(["greece"], "Greece", .europe)
        add(["czech republic", "czechia"], "Czech Republic", .europe)
        add(["slovakia"], "Slovakia", .europe)
        add(["croatia"], "Croatia", .europe)
        add(["slovenia"], "Slovenia", .europe)
        add(["serbia"], "Serbia", .europe)
        add(["romania"], "Romania", .europe)
        add(["bulgaria"], "Bulgaria", .europe)
        add(["ukraine"], "Ukraine", .europe)
        add(["belarus"], "Belarus", .europe)
        add(["malta"], "Malta", .europe)
        // Historical European states and regions. The ground is in Europe
        // for certain; the present-day country only where it is one country.
        add(["prussia", "austria-hungary", "austria hungary", "silesia", "pomerania", "galicia",
             "holy roman empire"], nil, .europe, historical: true)
        add(["bavaria", "saxony", "hesse", "hessen", "wurttemberg", "baden", "westphalia",
             "rhineland", "palatinate", "mecklenburg", "brandenburg", "schleswig-holstein"],
            "Germany", .europe, historical: true)
        add(["bohemia", "moravia"], "Czech Republic", .europe, historical: true)
        add(["alsace", "lorraine", "brittany", "normandy", "corsica", "burgundy"], "France", .europe, historical: true)
        add(["sicily", "sardinia", "tuscany", "piedmont", "lombardy", "kingdom of naples"], "Italy", .europe, historical: true)
        add(["flanders"], "Belgium", .europe, historical: true)

        add(["australia"], "Australia", .oceania)
        add(["new zealand"], "New Zealand", .oceania)
        add(["india"], "India", .asia)
        add(["china"], "China", .asia)
        add(["japan"], "Japan", .asia)
        add(["philippines"], "Philippines", .asia)
        add(["south africa"], "South Africa", .africa)
        add(["egypt"], "Egypt", .africa)
        add(["brazil"], "Brazil", .southAmerica)
        add(["argentina"], "Argentina", .southAmerica)
        add(["chile"], "Chile", .southAmerica)
        return t
    }()

    static let usStates: Set<String> = [
        "alabama", "alaska", "arizona", "arkansas", "california", "colorado", "connecticut",
        "delaware", "florida", "georgia", "hawaii", "idaho", "illinois", "indiana", "iowa", "kansas",
        "kentucky", "louisiana", "maine", "maryland", "massachusetts", "michigan", "minnesota",
        "mississippi", "missouri", "montana", "nebraska", "nevada", "new hampshire", "new jersey",
        "new mexico", "new york", "north carolina", "north dakota", "ohio", "oklahoma", "oregon",
        "pennsylvania", "rhode island", "south carolina", "south dakota", "tennessee", "texas",
        "utah", "vermont", "virginia", "washington", "west virginia", "wisconsin", "wyoming",
        "district of columbia", "washington dc", "washington d c",
        // Old written short forms.
        "mass", "conn", "penn", "penna", "calif", "wash", "tenn", "minn", "wisc", "okla", "nebr",
        "colo", "ariz", "ind", "ill", "mich", "kans", "tex", "fla", "ala", "miss", "ore", "oreg",
        "n carolina", "s carolina", "n dakota", "s dakota", "w virginia",
    ]

    static let usAbbreviations: Set<String> = [
        "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA", "HI", "ID", "IL", "IN", "IA",
        "KS", "KY", "LA", "ME", "MD", "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ",
        "NM", "NY", "NC", "ND", "OH", "OK", "OR", "PA", "RI", "SC", "SD", "TN", "TX", "UT", "VT",
        "VA", "WA", "WV", "WI", "WY", "DC",
    ]

    static let canadianProvinces: Set<String> = [
        "quebec", "ontario", "nova scotia", "new brunswick", "prince edward island", "pei",
        "newfoundland", "newfoundland and labrador", "labrador", "manitoba", "saskatchewan",
        "alberta", "british columbia", "yukon", "northwest territories", "nunavut",
    ]

    /// "KY" / "N.Y." / "Mass." are a state only when written as an
    /// upper-case abbreviation — "in", "or", "me" in lower case are words.
    static func usAbbreviation(_ recorded: String) -> Bool {
        let letters = recorded.filter { $0.isLetter }
        guard letters.count == 2, letters == letters.uppercased(),
              recorded.allSatisfy({ $0.isLetter || $0 == "." || $0 == " " }) else { return false }
        return usAbbreviations.contains(String(letters))
    }

    /// Lower-cased, diacritics folded, periods removed, spaces collapsed.
    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .replacingOccurrences(of: ".", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
    }
}
