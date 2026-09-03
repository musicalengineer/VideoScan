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
// Two rules from the codex #1014 review:
//
// * Dotted abbreviations are TOKENS, never separators. "U.S.A.", "U.K.",
//   "N.Y.", "Mass." survive intact; the only period that splits a place
//   is one followed by whitespace whose left-hand fragment is not a
//   known abbreviation ("Quebec. Canada" → two components, "Mt. Vernon"
//   → one).
// * A historical name is mapped to a present-day country ONLY when the
//   ground it named lies inside one country today. A name that spans
//   today's borders (New France, Acadia, British North America, British
//   America, Russia / the Russian Empire) is `.ambiguous`: recognised,
//   reported verbatim, and never inside or outside anywhere — so it can
//   never satisfy a stop rule.
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
        /// historical state split across today's borders (Prussia), for
        /// an ambiguous name, and for an unknown place.
        public let country: String?
        /// Set whenever the place is recognised and its ground is on one
        /// continent for certain — a historical European state still has
        /// a continent. Nil for ambiguous and unknown places.
        public let continent: Continent?
        /// True when the recorded name was a colonial-era or historical
        /// name mapped to today's borders (the prose says so).
        public let mappedFromHistoricalName: Bool
        /// True for a recognised historical name whose ground lies across
        /// more than one present-day border ("New France", "Russia").
        /// Never inside or outside anywhere; the trail reports it as
        /// recorded and walks on.
        public let isAmbiguous: Bool

        public init(raw: String, recordedCountry: String?, country: String?, continent: Continent?,
                    mappedFromHistoricalName: Bool, isAmbiguous: Bool = false) {
            self.raw = raw
            self.recordedCountry = recordedCountry
            self.country = country
            self.continent = continent
            self.mappedFromHistoricalName = mappedFromHistoricalName
            self.isAmbiguous = isAmbiguous
        }

        /// Nothing in the tables matched — the walk reports the place
        /// verbatim and never treats it as inside or outside anywhere.
        /// An ambiguous place is recognised, so it is NOT unknown.
        public var isUnknown: Bool { continent == nil && !isAmbiguous }

        public static func unknown(_ raw: String) -> Place {
            Place(raw: raw, recordedCountry: nil, country: nil, continent: nil,
                  mappedFromHistoricalName: false)
        }

        /// The stop-rule test for "outside <country>": known, and not that
        /// country. An unknown or ambiguous place is never "outside" anything.
        public func isOutside(country name: String) -> Bool {
            guard continent != nil, !isAmbiguous else { return false }
            return country != name
        }

        public func isIn(_ target: Continent) -> Bool { !isAmbiguous && continent == target }
    }

    // MARK: - Classification

    public static func classify(_ raw: String) -> Place {
        let parts = components(of: raw)
        guard let last = parts.last(where: { !normalize($0).isEmpty }) else {
            return .unknown(raw)
        }
        if let place = lookup(last, raw: raw) { return place }
        // "Lowell, Mass. U.S.A." — the last comma component is itself two
        // dotted tokens; the rightmost token decides.
        if let tail = last.split(separator: " ").last.map(String.init), tail != last,
           let place = lookup(tail, raw: raw) {
            return place
        }
        return .unknown(raw)
    }

    /// One component → a Place, or nil when the tables do not know it.
    static func lookup(_ component: String, raw: String) -> Place? {
        let key = normalize(component)
        let recorded = component.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if let entry = countries[key] {
            return Place(raw: raw, recordedCountry: recorded, country: entry.country,
                         continent: entry.continent, mappedFromHistoricalName: entry.historical,
                         isAmbiguous: entry.ambiguous)
        }
        if usStates.contains(key) || usAbbreviation(component.trimmingCharacters(in: .whitespaces)) {
            return Place(raw: raw, recordedCountry: recorded, country: unitedStates,
                         continent: .northAmerica, mappedFromHistoricalName: false)
        }
        if canadianProvinces.contains(key) {
            return Place(raw: raw, recordedCountry: recorded, country: canada,
                         continent: .northAmerica, mappedFromHistoricalName: false)
        }
        return nil
    }

    /// The place's components: split on commas; with no comma at all,
    /// split on a period followed by whitespace whose left-hand word is
    /// not an abbreviation ("Quebec. Canada" → ["Quebec", "Canada"];
    /// "Mt. Vernon. New York" → ["Mt. Vernon", "New York"]; "U.S.A." and
    /// "Boston Mass. U.S.A." keep their dotted tokens whole).
    static func components(of raw: String) -> [String] {
        // No trimming here: `normalize` and the recorded-name trim do it,
        // and this runs once per person on a 131k-person walk.
        let commaParts = raw.split(separator: ",").map(String.init)
        if commaParts.count > 1 { return commaParts }
        return periodComponents(of: raw)
    }

    static func periodComponents(of raw: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            let ch = raw[index]
            let next = raw.index(after: index)
            if ch == ".", next < raw.endIndex, raw[next].isWhitespace,
               !isAbbreviation(lastWord(of: current)) {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
            index = next
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts.filter { !$0.isEmpty }
    }

    static func lastWord(of text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
    }

    /// A word that is written with a trailing period and is NOT the end
    /// of a place: single letters ("U.S.A.", "N.Y."), the old written
    /// state forms ("Mass.", "Conn."), and the place words ("St.", "Mt.").
    static func isAbbreviation(_ word: String) -> Bool {
        let letters = word.filter { $0.isLetter }
        guard !letters.isEmpty else { return false }
        if letters.count == 1 { return true }
        let key = normalize(word)
        return usStates.contains(key) && key.count <= 5 || placeWordAbbreviations.contains(key)
    }

    static let placeWordAbbreviations: Set<String> = [
        "st", "ste", "mt", "ft", "pt", "co", "twp", "dist", "no", "jr", "sr", "dr", "mrs", "mr",
        "sto", "sta", "hts", "jct", "pk", "sq",
    ]

    public static let unitedStates = "United States"
    public static let canada = "Canada"
    public static let unitedKingdom = "United Kingdom"

    // MARK: - Tables

    struct Entry {
        let country: String?
        let continent: Continent?
        let historical: Bool
        let ambiguous: Bool
    }

    /// Lower-cased, diacritic-folded, period-free keys.
    static let countries: [String: Entry] = {
        var t: [String: Entry] = [:]
        func add(_ names: [String], _ country: String?, _ continent: Continent, historical: Bool = false) {
            for n in names { t[n] = Entry(country: country, continent: continent, historical: historical, ambiguous: false) }
        }
        /// A recognised historical name whose ground crosses today's
        /// borders: never inside or outside anywhere.
        func ambiguous(_ names: [String]) {
            for n in names { t[n] = Entry(country: nil, continent: nil, historical: true, ambiguous: true) }
        }
        // United States — present-day names and the colonial-era names of
        // the same ground (each one lies inside today's United States).
        add(["united states", "united states of america", "usa", "us", "u s", "u s a", "america",
             "the united states", "new england"], unitedStates, .northAmerica)
        add(["british colonial america", "colonial america", "american colonies",
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
        // Canada — present-day and the names of ground that is Canada today.
        add(["canada"], canada, .northAmerica)
        add(["lower canada", "upper canada", "canada east", "canada west", "province of canada",
             "province of quebec", "province of ontario", "colony of nova scotia",
             "colony of new brunswick", "colony of newfoundland", "dominion of canada"],
            canada, .northAmerica, historical: true)
        // Names that spanned today's US/Canada border, or Europe and Asia:
        // recognised, never counted (codex #1014 item 1).
        ambiguous(["new france", "nouvelle-france", "nouvelle france", "acadia", "acadie",
                   "british north america", "british america",
                   "russia", "russian empire", "imperial russia"])
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
        "district of columbia", "washington dc", "washington d c", "d c",
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
    /// "Mo." / "Ky." (capitalised, with the period) are the old written
    /// forms and count too; "Portland, or" does not.
    static func usAbbreviation(_ recorded: String) -> Bool {
        let letters = recorded.filter { $0.isLetter }
        guard letters.count == 2,
              recorded.allSatisfy({ $0.isLetter || $0 == "." || $0 == " " }),
              usAbbreviations.contains(letters.uppercased()) else { return false }
        if letters == letters.uppercased() { return true }
        return letters.first?.isUppercase == true && recorded.hasSuffix(".")
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
