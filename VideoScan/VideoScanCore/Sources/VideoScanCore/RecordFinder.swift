// RecordFinder.swift
// GH #230 Phase A — "Record Finder": pre-filled searches on the archives that
// hold Irish, British and military records, built from one tree person.
// Rick, 2026-09-30: "We need an automated way to pull data from the various
// irish sites so it is as easy" as FamilySearch is for the New England side.
//
// Most of those sites are human-only (Cloudflare challenge, login, or terms
// that forbid software filling in the search). So the app does the typing:
// it opens the reader's browser on the search already filled in, and the
// "I found it" bring-back (app side, RecordFinderFiling) files what they
// download. Nothing here fetches anything.
//
// THE REGISTRY IS DATA. Each archive is one `Site` value: a base URL, a list
// of query parameters drawn from the person (`Field`), and the conditions
// under which it is worth offering (`Condition`). Adding an English or
// Scottish archive is adding a value to `britain`, not writing code — the
// sources in docs/research/uk_scotland_records_survey_2026-10-01.md §5 went in that
// way. A site whose query format could not be confirmed is a `formOnly`
// site: it lands on the search form and says so (`isPrefilled == false`).
//
// How each URL shape was confirmed is recorded per site (`Verification`) and
// pinned by RecordFinderLinkTests — a redesign shows up as a red row there,
// not as a 404 for Rick.
//
// Memory/cost: one `Context` per person (a handful of string scans of the two
// place strings), then a linear pass over ~35 sites. No allocation beyond the
// links themselves; 100k people run well inside the scale test's budget.
//
// C++ readers: `indirect enum` ≈ a tagged union that may contain itself
// (heap-boxed), here a tiny expression tree for "when to offer this link".

import Foundation

public enum RecordFinder {

    // MARK: - The person

    /// Everything a template may draw on, lifted once from a tree record.
    public struct Person: Sendable, Equatable {
        public let givenName: String?
        public let surname: String?
        public let birthYear: Int?
        public let deathYear: Int?
        public let birthPlace: String?
        public let deathPlace: String?
        /// The tree records military service (a `_MILT`/`MILI` fact or a
        /// typed military event — not a US draft registration).
        public let servedInMilitary: Bool

        public init(givenName: String?, surname: String?, birthYear: Int?, deathYear: Int?,
                    birthPlace: String?, deathPlace: String?, servedInMilitary: Bool = false) {
            self.givenName = Self.clean(givenName)
            self.surname = Self.clean(surname)
            self.birthYear = birthYear
            self.deathYear = deathYear
            self.birthPlace = Self.clean(birthPlace)
            self.deathPlace = Self.clean(deathPlace)
            self.servedInMilitary = servedInMilitary
        }

        /// From a display name + GEDCOM surname: the given name is the first
        /// token that is not the surname ("Mary C Doolan", "Doolan" → "Mary").
        public init(name: String, surname: String?, birthYear: Int?, deathYear: Int?,
                    birthPlace: String?, deathPlace: String?, servedInMilitary: Bool = false) {
            let tokens = name.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let given = tokens.first.flatMap { first -> String? in
                if let surname, first.caseInsensitiveCompare(surname) == .orderedSame { return nil }
                return first
            }
            self.init(givenName: given, surname: surname, birthYear: birthYear, deathYear: deathYear,
                      birthPlace: birthPlace, deathPlace: deathPlace, servedInMilitary: servedInMilitary)
        }

        private static func clean(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    // MARK: - Template language

    /// A value a query parameter is filled from.
    public indirect enum Field: Sendable, Equatable {
        case givenName
        case surname
        /// "Given Surname" (needs the surname; given optional).
        case givenThenSurname
        /// "Surname Given" — TNA Discovery's own order.
        case surnameThenGiven
        /// The given name only when the person was born before the year —
        /// Griffith's names occupiers, so a child born later is searched by
        /// surname alone (their parents' generation).
        case givenNameIfBornBefore(Int)
        case birthYear
        case birthYearOffset(Int)
        case deathYearOffset(Int)
        /// First year of the life (birth, else death − 90) plus the offset.
        case lifeStart(Int)
        /// Last year of the life (death, else birth + 90) plus the offset.
        case lifeEnd(Int)
        /// The one year of the list the person was alive in; nil when they
        /// were alive in none or in more than one (the search then spans all).
        case singleYearAlive([Int])
        /// "Cork", "Londonderry", "Offaly" — the county parsed from the Irish place.
        case irishCounty
        /// The county as the 1901/1911 census index spells it ("King's Co.").
        case irishCensusCounty
        /// The first part of the Irish place when it is a town, not the
        /// county or the country ("Skibbereen, Co. Cork" → "Skibbereen").
        case irishTown
        /// Chapman code of an English county ("CON", "LAN").
        case englishChapman
        /// "England" / "Wales" / "Scotland" — the first of `regions` the
        /// birth place lies in.
        case birthCountry([FamilyTreeResearchLinks.Region])
        case constant(String)
        /// The first of these that has a value.
        case firstOf([Field])
    }

    public struct Parameter: Sendable, Equatable {
        public let name: String
        public let field: Field
        /// A required parameter without a value demotes the link to the
        /// site's search form; an optional one is simply left out.
        public let required: Bool

        public init(_ name: String, _ field: Field, required: Bool = false) {
            self.name = name
            self.field = field
            self.required = required
        }
    }

    /// When a site is worth offering. Unknown dates PASS date conditions —
    /// a person with no years in the tree is still worth one search.
    public indirect enum Condition: Sendable, Equatable {
        /// Birth OR death place is in the region.
        case recordedIn(FamilyTreeResearchLinks.Region)
        case bornIn(FamilyTreeResearchLinks.Region)
        case diedIn(FamilyTreeResearchLinks.Region)
        /// Alive at some point in the year (birth ≤ y ≤ death).
        case aliveIn(Int)
        case bornBefore(Int)
        case bornFrom(Int)
        case diedFrom(Int)
        case diedBefore(Int)
        case servedInMilitary
        /// The Irish county is one of the six of Northern Ireland.
        case northernIrishCounty
        case not(Condition)
        case any([Condition])
    }

    /// How the URL shape was confirmed — recorded so a reader (and the
    /// sensor test) can tell a checked link from a believed one.
    public enum Verification: Sendable, Equatable {
        /// Fetched and returned the expected content (date + how).
        case verified(String)
        /// Shape taken from captured real result pages (Wayback) or a form's
        /// field names; the live site challenges scripts. Verify once by hand.
        case browserOnly(String)
        /// No pre-fill possible (POST form, login, or terms forbid software
        /// filling in the search): the link opens the blank form.
        case formOnly(String)
    }

    public struct Site: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        /// Menu section ("Ireland", "England and Wales", …).
        public let group: String
        /// Why this link is offered. `{place}` → the place that matched
        /// the site's region.
        public let reason: String
        /// Base URL of the pre-filled search; nil for form-only sites.
        public let searchURL: String?
        /// Appended as one path component (Genuki's county pages).
        public let pathField: Field?
        public let parameters: [Parameter]
        /// Where the link lands when it cannot be pre-filled.
        public let formURL: String
        /// ALL must hold.
        public let conditions: [Condition]
        public let verification: Verification

        public init(id: String, title: String, group: String, reason: String,
                    searchURL: String?, pathField: Field? = nil, parameters: [Parameter] = [],
                    formURL: String, conditions: [Condition], verification: Verification) {
            self.id = id
            self.title = title
            self.group = group
            self.reason = reason
            self.searchURL = searchURL
            self.pathField = pathField
            self.parameters = parameters
            self.formURL = formURL
            self.conditions = conditions
            self.verification = verification
        }

        public var isFormOnly: Bool { searchURL == nil }
    }

    // MARK: - Evaluation

    /// Everything derived from the place strings, computed ONCE per person.
    public struct Context: Sendable, Equatable {
        public let person: Person
        public let birthRegions: Set<FamilyTreeResearchLinks.Region>
        public let deathRegions: Set<FamilyTreeResearchLinks.Region>
        public let irishPlace: String?
        public let irishCounty: IrishCounty?
        public let irishTown: String?
        public let englishChapman: String?

        public init(_ person: Person) {
            self.person = person
            // Each place is classified ONCE; "the place that put them in
            // region R" is then birth-first, as before.
            let birth = FamilyTreeResearchLinks.regions(birthPlace: person.birthPlace, deathPlace: nil)
            let death = FamilyTreeResearchLinks.regions(birthPlace: person.deathPlace, deathPlace: nil)
            birthRegions = birth
            deathRegions = death
            func place(_ region: FamilyTreeResearchLinks.Region) -> String? {
                birth.contains(region) ? person.birthPlace : (death.contains(region) ? person.deathPlace : nil)
            }
            let irish = place(.ireland)
            let county = irish.flatMap(IrishCounty.parse)
            irishPlace = irish
            irishCounty = county
            irishTown = irish.flatMap { RecordFinder.townPart(of: $0, county: county) }
            englishChapman = place(.england).flatMap(EnglishCounty.chapmanCode)
        }

        public var regions: Set<FamilyTreeResearchLinks.Region> { birthRegions.union(deathRegions) }

        /// The place string that put the person in `region` (birth first).
        public func place(in region: FamilyTreeResearchLinks.Region) -> String? {
            if birthRegions.contains(region) { return person.birthPlace }
            if deathRegions.contains(region) { return person.deathPlace }
            return nil
        }
    }

    public static func holds(_ condition: Condition, in context: Context) -> Bool {
        let p = context.person
        switch condition {
        case .recordedIn(let region): return context.regions.contains(region)
        case .bornIn(let region): return context.birthRegions.contains(region)
        case .diedIn(let region): return context.deathRegions.contains(region)
        case .aliveIn(let year):
            if let b = p.birthYear, b > year { return false }
            if let d = p.deathYear, d < year { return false }
            return true
        case .bornBefore(let year): return p.birthYear.map { $0 < year } ?? true
        case .bornFrom(let year): return p.birthYear.map { $0 >= year } ?? true
        case .diedFrom(let year): return p.deathYear.map { $0 >= year } ?? true
        case .diedBefore(let year): return p.deathYear.map { $0 < year } ?? true
        case .servedInMilitary: return p.servedInMilitary
        case .northernIrishCounty: return context.irishCounty?.isNorthernIreland ?? false
        case .not(let inner): return !holds(inner, in: context)
        case .any(let list): return list.contains { holds($0, in: context) }
        }
    }

    public static func value(of field: Field, in context: Context) -> String? {
        switch field {
        case .givenName, .surname, .givenThenSurname, .surnameThenGiven, .givenNameIfBornBefore:
            return nameValue(of: field, person: context.person)
        case .birthYear, .birthYearOffset, .deathYearOffset, .lifeStart, .lifeEnd, .singleYearAlive:
            return yearValue(of: field, in: context)
        case .irishCounty: return context.irishCounty?.name
        case .irishCensusCounty: return context.irishCounty?.censusName
        case .irishTown: return context.irishTown
        case .englishChapman: return context.englishChapman
        case .birthCountry(let regions):
            return regions.first { context.birthRegions.contains($0) }?.label
        case .constant(let value): return value
        case .firstOf(let fields):
            return fields.lazy.compactMap { value(of: $0, in: context) }.first
        }
    }

    private static func nameValue(of field: Field, person p: Person) -> String? {
        switch field {
        case .givenName: return p.givenName
        case .surname: return p.surname
        case .givenThenSurname:
            guard let s = p.surname else { return nil }
            return [p.givenName, s].compactMap { $0 }.joined(separator: " ")
        case .surnameThenGiven:
            guard let s = p.surname else { return nil }
            return [s, p.givenName].compactMap { $0 }.joined(separator: " ")
        case .givenNameIfBornBefore(let year):
            guard let b = p.birthYear, b < year else { return nil }
            return p.givenName
        default: return nil
        }
    }

    private static func yearValue(of field: Field, in context: Context) -> String? {
        let p = context.person
        switch field {
        case .birthYear: return p.birthYear.map(String.init)
        case .birthYearOffset(let n): return p.birthYear.map { String($0 + n) }
        case .deathYearOffset(let n): return p.deathYear.map { String($0 + n) }
        case .lifeStart(let n):
            if let b = p.birthYear { return String(b + n) }
            return p.deathYear.map { String($0 - 90 + n) }
        case .lifeEnd(let n):
            if let d = p.deathYear { return String(d + n) }
            return p.birthYear.map { String($0 + 90 + n) }
        case .singleYearAlive(let years):
            let alive = years.filter { holds(.aliveIn($0), in: context) }
            // Unknown dates make every year "alive" — that is not ONE year.
            guard alive.count == 1, p.birthYear != nil || p.deathYear != nil else { return nil }
            return String(alive[0])
        default: return nil
        }
    }

    /// The link for one site, or nil when the site does not apply.
    public static func link(for site: Site, in context: Context) -> FamilyTreeResearchLinks.Link? {
        guard site.conditions.allSatisfy({ holds($0, in: context) }) else { return nil }
        let reason = site.reason.replacingOccurrences(
            of: "{place}", with: placeForReason(site: site, context: context))
        func form() -> FamilyTreeResearchLinks.Link? {
            guard let url = URL(string: site.formURL) else { return nil }
            return FamilyTreeResearchLinks.Link(title: site.title, url: url, reason: reason,
                                                isPrefilled: false, group: site.group, siteID: site.id)
        }
        guard let base = site.searchURL else { return form() }

        var path = base
        if let pathField = site.pathField {
            guard let component = value(of: pathField, in: context) else { return form() }
            path += encode(component)
        }
        var pairs: [String] = []
        var carriesPerson = site.pathField != nil
        for parameter in site.parameters {
            guard let raw = value(of: parameter.field, in: context), !raw.isEmpty else {
                if parameter.required { return form() }
                continue
            }
            if case .constant = parameter.field {} else { carriesPerson = true }
            pairs.append(encode(parameter.name) + "=" + encode(raw))
        }
        guard carriesPerson else { return form() }
        let full = pairs.isEmpty ? path : path + "?" + pairs.joined(separator: "&")
        guard let url = URL(string: full) else { return form() }
        return FamilyTreeResearchLinks.Link(title: site.title, url: url, reason: reason,
                                            isPrefilled: true, group: site.group, siteID: site.id)
    }

    /// Every applicable link for the person, in registry order.
    public static func links(for person: Person, sites: [Site] = all) -> [FamilyTreeResearchLinks.Link] {
        let context = Context(person)
        return sites.compactMap { link(for: $0, in: context) }
    }

    /// Strict query-value encoding: only unreserved characters pass, so an
    /// apostrophe ("King's Co.") or ampersand can never split a parameter.
    public static func encode(_ value: String) -> String {
        // Byte loop over UTF-8 (≈ a C++ loop over a std::string's bytes):
        // A–Z a–z 0–9 - . _ ~ pass; every other byte becomes %XX.
        let hex: [UInt8] = Array("0123456789ABCDEF".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(value.utf8.count * 3)
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                out.append(byte)
            default:
                out.append(UInt8(ascii: "%"))
                out.append(hex[Int(byte >> 4)])
                out.append(hex[Int(byte & 0x0F)])
            }
        }
        // Every byte in `out` is ASCII, so this never fails.
        return String(bytes: out, encoding: .ascii) ?? ""
    }

    private static func placeForReason(site: Site, context: Context) -> String {
        for condition in site.conditions {
            switch condition {
            case .recordedIn(let r), .bornIn(let r), .diedIn(let r):
                if let place = context.place(in: r) { return place }
            case .any(let list):
                for case .recordedIn(let r) in list { if let place = context.place(in: r) { return place } }
                for case .bornIn(let r) in list { if let place = context.place(in: r) { return place } }
                for case .diedIn(let r) in list { if let place = context.place(in: r) { return place } }
            default: continue
            }
        }
        return context.irishPlace ?? context.person.birthPlace ?? context.person.deathPlace ?? "the record"
    }

    /// The first comma-part of an Irish place when it is a town — not the
    /// county, not "Ireland", not a "Co. X" phrase.
    static func townPart(of place: String, county: IrishCounty?) -> String? {
        guard let first = place.split(separator: ",").first?
            .trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty else { return nil }
        let lowered = first.lowercased()
        if lowered == "ireland" || lowered.hasPrefix("co ") || lowered.hasPrefix("co.")
            || lowered.hasPrefix("county ") { return nil }
        if let county, county.aliases.contains(IrishCounty.normalise(first)) { return nil }
        return first
    }

}

// MARK: - Counties

/// The 32 Irish counties with the spellings records use and the spelling
/// the 1901/1911 census index uses (checked 2026-10-01: "Londonderry",
/// "King's Co.", "Queen's Co.").
public struct IrishCounty: Sendable, Equatable {
    public let name: String
    public let censusName: String
    public let aliases: Set<String>
    public let isNorthernIreland: Bool

    public static let all: [IrishCounty] = {
        let ni: Set<String> = ["Antrim", "Armagh", "Down", "Fermanagh", "Londonderry", "Tyrone"]
        let plain = ["Antrim", "Armagh", "Carlow", "Cavan", "Clare", "Cork", "Donegal", "Down", "Dublin",
                     "Fermanagh", "Galway", "Kerry", "Kildare", "Kilkenny", "Leitrim", "Limerick",
                     "Longford", "Louth", "Mayo", "Meath", "Monaghan", "Roscommon", "Sligo",
                     "Tipperary", "Tyrone", "Waterford", "Westmeath", "Wexford", "Wicklow"]
        var out = plain.map {
            IrishCounty(name: $0, censusName: $0, aliases: [normalise($0)], isNorthernIreland: ni.contains($0))
        }
        out.append(IrishCounty(name: "Londonderry", censusName: "Londonderry",
                               aliases: ["londonderry", "derry"], isNorthernIreland: true))
        out.append(IrishCounty(name: "Offaly", censusName: "King's Co.",
                               aliases: ["offaly", "kings county", "kings co", "kings"], isNorthernIreland: false))
        out.append(IrishCounty(name: "Laois", censusName: "Queen's Co.",
                               aliases: ["laois", "leix", "queens county", "queens co", "queens"], isNorthernIreland: false))
        return out
    }()

    /// Lower-case, apostrophes and full stops dropped, whitespace collapsed:
    /// "King's Co." → "kings co".
    public static func normalise(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: ".", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static let byAlias: [String: IrishCounty] = {
        var map: [String: IrishCounty] = [:]
        for county in all { for alias in county.aliases { map[alias] = county } }
        return map
    }()

    /// The county a place string names, matching whole comma-parts from the
    /// END ("Skibbereen, County Cork, Ireland" → Cork). A "Co./County X"
    /// phrase anywhere also counts. Substrings never do ("Downpatrick" is
    /// not Down).
    public static func parse(_ place: String) -> IrishCounty? {
        let parts = place.split(separator: ",").map { normalise(String($0)) }
        for part in parts.reversed() {
            var candidate = part
            for prefix in ["county ", "co "] where candidate.hasPrefix(prefix) {
                candidate = String(candidate.dropFirst(prefix.count))
            }
            for suffix in [" city", " county", " town"] where candidate.hasSuffix(suffix) {
                candidate = String(candidate.dropLast(suffix.count))
            }
            if let hit = byAlias[candidate] { return hit }
        }
        let words = normalise(place.replacingOccurrences(of: ",", with: " ")).split(separator: " ").map(String.init)
        for (i, word) in words.enumerated() where (word == "co" || word == "county") && i + 1 < words.count {
            if let hit = byAlias[words[i + 1]] { return hit }
            if i + 2 < words.count, let hit = byAlias[words[i + 1] + " " + words[i + 2]] { return hit }
        }
        return nil
    }
}

/// English historic counties → Chapman codes (GENUKI's page keys).
public enum EnglishCounty {
    static let codes: [String: String] = [
        "bedfordshire": "BDF", "berkshire": "BRK", "buckinghamshire": "BKM", "cambridgeshire": "CAM",
        "cheshire": "CHS", "cornwall": "CON", "cumberland": "CUL", "derbyshire": "DBY", "devon": "DEV",
        "devonshire": "DEV", "dorset": "DOR", "durham": "DUR", "essex": "ESS", "gloucestershire": "GLS",
        "hampshire": "HAM", "herefordshire": "HEF", "hertfordshire": "HRT", "huntingdonshire": "HUN",
        "kent": "KEN", "lancashire": "LAN", "leicestershire": "LEI", "lincolnshire": "LIN",
        "london": "LND", "middlesex": "MDX", "norfolk": "NFK", "northamptonshire": "NTH",
        "northumberland": "NBL", "nottinghamshire": "NTT", "oxfordshire": "OXF", "rutland": "RUT",
        "shropshire": "SAL", "somerset": "SOM", "staffordshire": "STS", "suffolk": "SFK",
        "surrey": "SRY", "sussex": "SSX", "warwickshire": "WAR", "westmorland": "WES",
        "wiltshire": "WIL", "worcestershire": "WOR", "yorkshire": "YKS",
    ]

    /// Chapman code of the first comma-part (from the end) that names an
    /// English county.
    public static func chapmanCode(_ place: String) -> String? {
        for part in place.split(separator: ",").reversed() {
            var key = IrishCounty.normalise(String(part))
            for prefix in ["county of ", "county "] where key.hasPrefix(prefix) {
                key = String(key.dropFirst(prefix.count))
            }
            if let code = codes[key] { return code }
        }
        return nil
    }
}
