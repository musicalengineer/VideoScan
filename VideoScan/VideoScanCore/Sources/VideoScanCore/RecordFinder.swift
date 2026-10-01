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
// sources in docs/uk_scotland_records_survey_2026-10-01.md §5 went in that
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
        let p = context.person
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
        return String(decoding: out, as: UTF8.self)
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

    // MARK: - The registry

    /// Every site, in the order the menu shows them.
    public static var all: [Site] { ireland + military + britain + burials }

    /// Burials and memorials, worldwide.
    ///
    /// Find a Grave WAS an automated Research Person source; its robots.txt
    /// has disallowed /memorial/search since 2024-11-25, so on 2026-10-01
    /// (Rick approved; survey §6.1) it became this link. A person clicking a
    /// link in their own browser is not a crawler; the app fetching it was.
    public static let burials: [Site] = [
        Site(id: "world.findagrave",
             title: "Find a Grave — memorial search",
             group: "Burials and memorials",
             reason: "Recorded in {place}: volunteer memorials, often with a headstone photo and family links.",
             searchURL: "https://www.findagrave.com/memorial/search",
             parameters: [
                Parameter("firstname", .givenName),
                Parameter("lastname", .surname, required: true),
                Parameter("birthyear", .birthYear),
                Parameter("birthyearfilter", .constant("5")),
                Parameter("deathyear", .deathYearOffset(0)),
                Parameter("deathyearfilter", .constant("5")),
             ],
             formURL: "https://www.findagrave.com/",
             conditions: [.any([.recordedIn(.unitedStates), .recordedIn(.ireland), .recordedIn(.england),
                                .recordedIn(.wales), .recordedIn(.scotland)])],
             verification: .verified("survey 2026-10-01: search 200 with 21 memorial links; parameter names as the old adapter used them")),
    ]

    // Region shorthands for the tables below.
    private typealias R = FamilyTreeResearchLinks.Region
    private static let inGB: Condition = .any([.recordedIn(.england), .recordedIn(.wales), .recordedIn(.scotland)])
    private static let inEW: Condition = .any([.recordedIn(.england), .recordedIn(.wales)])
    private static let bornEW: Condition = .any([.bornIn(.england), .bornIn(.wales)])
    private static let diedEW: Condition = .any([.diedIn(.england), .diedIn(.wales)])
    private static let diedGB: Condition = .any([.diedIn(.england), .diedIn(.wales), .diedIn(.scotland)])

    /// Ireland — docs/irish_records_design_2026-09-30.md §2/§4, URL shapes
    /// re-checked 2026-10-01.
    public static let ireland: [Site] = [
        Site(id: "ie.nai.census-1901-1911",
             title: "Census of Ireland 1901 / 1911",
             group: "Ireland",
             reason: "Recorded in {place}. The only two surviving full censuses — household returns, occupations and townland, free, with scans of the original forms.",
             searchURL: "https://nationalarchives.ie/collections/search-the-census/search-results/",
             parameters: [
                Parameter("census_year", .singleYearAlive([1901, 1911])),
                Parameter("surname", .surname, required: true),
                Parameter("firstname", .givenName),
                Parameter("county", .irishCensusCounty),
             ],
             formURL: "https://nationalarchives.ie/collections/search-the-census/",
             conditions: [.recordedIn(.ireland), .any([.aliveIn(1901), .aliveIn(1911)])],
             verification: .verified("2026-10-01: results page 200; the same parameters on api-census.nationalarchives.ie return the rows (county spelled as the index spells it, e.g. \"King's Co.\")")),
        Site(id: "ie.nai.census-1926",
             title: "Census of Ireland 1926",
             group: "Ireland",
             reason: "Released April 2026 — every household in the Irish Free State on 18 April 1926. Opens the search form.",
             searchURL: nil,
             formURL: "https://nationalarchives.ie/collections/search-the-1926-census/",
             conditions: [.recordedIn(.ireland), .aliveIn(1926), .not(.northernIrishCounty)],
             verification: .formOnly("2026-10-01: form page 200; its query parameters are not yet pinned")),
        Site(id: "ie.nai.census-1821-1851",
             title: "Census fragments 1821–1851",
             group: "Ireland",
             reason: "What survived the 1922 fire of the earlier censuses — patchy, but whole parishes in a few counties. Opens the search form.",
             searchURL: nil,
             formURL: "https://nationalarchives.ie/collections/search-the-census-c19/",
             conditions: [.recordedIn(.ireland), .bornBefore(1851)],
             verification: .formOnly("2026-10-01: form page 200")),
        Site(id: "ie.irishgenealogy.civil-church",
             title: "Irish civil records and church registers (irishgenealogy.ie)",
             group: "Ireland",
             reason: "State registration with register images — births 1864–1924, marriages 1845–1949, deaths 1871–1974 — plus Catholic registers for Cork and Ross, Dublin, Kerry and Carlow. Download the PDF and use I found a record… to file it.",
             searchURL: "https://www.irishgenealogy.ie/search/",
             parameters: [
                Parameter("church-or-civil", .constant("all")),
                Parameter("firstname", .givenName),
                Parameter("lastname", .surname, required: true),
                Parameter("location", .irishCounty),
                Parameter("yearStart", .lifeStart(-1)),
                Parameter("yearEnd", .lifeEnd(1)),
                Parameter("event-birth", .constant("1")),
                Parameter("event-marriage", .constant("1")),
                Parameter("event-death", .constant("1")),
                Parameter("event-baptism", .constant("1")),
                Parameter("event-burial", .constant("1")),
             ],
             formURL: "https://www.irishgenealogy.ie/search/",
             conditions: [.recordedIn(.ireland)],
             verification: .browserOnly("2026-10-01: field names read from real result pages captured by the Wayback Machine on 2026-04-06 and 2026-09-05 (20 record links rendered); the live site answers scripts with a Cloudflare challenge")),
        Site(id: "ie.griffiths",
             title: "Griffith's Valuation 1847–1864 (askaboutireland.ie)",
             group: "Ireland",
             reason: "Who held land and houses in {place} in the 1850s — the bridge that places a surname in a townland before civil registration.",
             searchURL: "https://www.askaboutireland.ie/griffith-valuation/index.xml",
             parameters: [
                Parameter("action", .constant("doNameSearch")),
                Parameter("familyname", .surname, required: true),
                Parameter("firstname", .givenNameIfBornBefore(1845)),
                Parameter("countyname", .irishCounty),
             ],
             formURL: "https://www.askaboutireland.ie/griffith-valuation/",
             conditions: [.recordedIn(.ireland), .bornBefore(1920)],
             verification: .browserOnly("Wayback captures 2023–2024 of real name searches; live site challenges scripts")),
        Site(id: "ie.nli.registers",
             title: "Catholic parish registers — page images (NLI)",
             group: "Ireland",
             reason: "Page images of the Catholic registers, mostly to 1880, searchable by parish — no name index. Find the entry in the FindMyPast index below, then open the page here.",
             searchURL: "https://registers.nli.ie/",
             parameters: [Parameter("q", .firstOf([.irishTown, .irishCounty]), required: true)],
             formURL: "https://registers.nli.ie/",
             conditions: [.recordedIn(.ireland), .bornBefore(1900)],
             verification: .browserOnly("q= seen on real captured URLs; live site challenges scripts")),
        Site(id: "ie.findmypast.catholic-baptisms",
             title: "Irish Catholic baptisms index (FindMyPast, free account)",
             group: "Ireland",
             reason: "The free name index to the NLI registers — child, parents, parish and date — so you know which register page to open.",
             searchURL: "https://www.findmypast.ie/search/results",
             parameters: [
                Parameter("datasetname", .constant("ireland roman catholic parish baptisms")),
                Parameter("firstname", .givenName),
                Parameter("lastname", .surname, required: true),
                Parameter("yearofbirth", .birthYear),
                Parameter("yearofbirth_offset", .constant("2")),
             ],
             formURL: "https://www.findmypast.ie/search/ireland",
             conditions: [.recordedIn(.ireland), .bornBefore(1915)],
             verification: .browserOnly("datasetname/lastname/firstname from captured real URLs (2023–2025); scripts get 403")),
        Site(id: "ie.proni.wills",
             title: "PRONI will calendars (Northern Ireland)",
             group: "Ireland",
             reason: "{place} is in Northern Ireland: will calendars 1858–1965 with images. Opens the search form (it cannot be pre-filled).",
             searchURL: nil,
             formURL: "https://apps.proni.gov.uk/WillsCalendar_IE/WillsSearch.aspx",
             conditions: [.northernIrishCounty, .diedFrom(1858)],
             verification: .formOnly("2026-10-01: 200; ASP.NET postback form")),
        Site(id: "ie.nai.genealogy",
             title: "National Archives genealogy (tithe, wills)",
             group: "Ireland",
             reason: "Tithe Applotment Books 1823–37, Calendars of Wills 1858–1920, soldiers' wills. Opens the search form.",
             searchURL: nil,
             formURL: "https://genealogy.nationalarchives.ie/",
             conditions: [.recordedIn(.ireland)],
             verification: .formOnly("Cloudflare to scripts; form landing page")),
    ]

    /// UK military service (Irish soldiers served in the British Army). The
    /// automated Discovery adapter (app side) fetches the references; these
    /// are the same searches for the browser.
    public static let military: [Site] = [
        Site(id: "uk.tna.wo97",
             title: "British Army service records to 1913 (TNA Discovery, WO 97)",
             group: "Military records (UK)",
             reason: "The tree records military service. Soldiers' documents for men discharged to pension — birthplace, regiment, next of kin. The catalogue entry is free; the image is on FindMyPast/Ancestry.",
             searchURL: "https://discovery.nationalarchives.gov.uk/results/r",
             parameters: [Parameter("_q", .surnameThenGiven, required: true),
                          Parameter("_ser", .constant("WO 97"))],
             formURL: "https://discovery.nationalarchives.gov.uk/",
             conditions: [.servedInMilitary, .bornBefore(1898)],
             verification: .verified("2026-10-01: API equivalent returns WO 97 rows; _q/_ser on captured result pages")),
        Site(id: "uk.tna.wo363",
             title: "British Army WWI service records (TNA Discovery, WO 363)",
             group: "Military records (UK)",
             reason: "The tree records military service. The surviving First World War service records (about 40% survived the 1940 bombing).",
             searchURL: "https://discovery.nationalarchives.gov.uk/results/r",
             parameters: [Parameter("_q", .surnameThenGiven, required: true),
                          Parameter("_ser", .constant("WO 363"))],
             formURL: "https://discovery.nationalarchives.gov.uk/",
             conditions: [.servedInMilitary, .aliveIn(1914), .bornBefore(1902)],
             verification: .verified("2026-10-01: API equivalent returns WO 363 rows")),
    ]

    /// England, Wales and Scotland — docs/uk_scotland_records_survey_2026-10-01.md §5.
    public static let britain: [Site] = {
        func fs(_ id: String, _ title: String, _ collection: String, _ reason: String,
                countries: [R], conditions: [Condition], group: String) -> Site {
            Site(id: id, title: title, group: group, reason: reason,
                 searchURL: "https://www.familysearch.org/search/record/results",
                 parameters: [
                    Parameter("q.givenName", .givenName),
                    Parameter("q.surname", .surname, required: true),
                    Parameter("q.birthLikeDate.from", .birthYearOffset(-5)),
                    Parameter("q.birthLikeDate.to", .birthYearOffset(5)),
                    Parameter("q.birthLikePlace", .birthCountry(countries)),
                    Parameter("f.collectionId", .constant(collection)),
                 ],
                 formURL: "https://www.familysearch.org/search/record/results",
                 conditions: conditions,
                 verification: .browserOnly("collection id confirmed via its collection page (survey 2026-10-01); FamilySearch 403s scripts"))
        }
        let ew = "England and Wales"
        let sct = "Scotland"
        return [
            fs("gb.fs.ew-birth-index", "FamilySearch — England and Wales birth index 1837–2008", "2285338",
               "Born in {place}: the GRO quarterly birth index, with mother's maiden name from 1911.",
               countries: [.england, .wales], conditions: [bornEW, .bornFrom(1837)], group: ew),
            fs("gb.fs.england-births", "FamilySearch — England births and christenings 1538–1975", "1473014",
               "Born in {place}: parish baptisms, often with both parents' names.",
               countries: [.england], conditions: [.bornIn(.england), .bornBefore(1900)], group: ew),
            fs("gb.fs.ew-marriage-index", "FamilySearch — England and Wales marriage index 1837–2005", "2285732",
               "Recorded in {place}: the GRO quarterly marriage index.",
               countries: [.england, .wales], conditions: [inEW, .bornFrom(1815)], group: ew),
            fs("gb.fs.ew-death-index", "FamilySearch — England and Wales death index 1837–2007", "2285341",
               "Died in {place}: the GRO quarterly death index, with age at death.",
               countries: [.england, .wales], conditions: [diedEW, .diedFrom(1837)], group: ew),
            fs("gb.fs.england-burials", "FamilySearch — England deaths and burials 1538–1991", "1473016",
               "Died in {place}: parish burials.",
               countries: [.england], conditions: [.diedIn(.england), .diedBefore(1900)], group: ew),
            fs("gb.fs.ew-census-1881", "FamilySearch — England and Wales census 1881", "2562194",
               "Recorded in {place} and alive in 1881: the fully indexed census.",
               countries: [.england, .wales], conditions: [inEW, .aliveIn(1881)], group: ew),
            fs("gb.fs.ew-census-1911", "FamilySearch — England and Wales census 1911", "1921547",
               "Recorded in {place} and alive in 1911.",
               countries: [.england, .wales], conditions: [inEW, .aliveIn(1911)], group: ew),
            fs("gb.fs.scotland-births", "FamilySearch — Scotland births and baptisms 1564–1950", "1771030",
               "Recorded in {place}: Old Parish Register baptisms and later births.",
               countries: [.scotland], conditions: [.recordedIn(.scotland), .bornBefore(1950)], group: sct),
            fs("gb.fs.scotland-marriages", "FamilySearch — Scotland marriages 1561–1910", "1771074",
               "Recorded in {place}: Old Parish Register banns and marriages.",
               countries: [.scotland], conditions: [.recordedIn(.scotland), .bornBefore(1895)], group: sct),
            Site(id: "gb.findmypast",
                 title: "FindMyPast (UK) — census, parish registers, 1921 census",
                 group: ew,
                 reason: "Recorded in {place}. Index search is free; the 1921 census is only here.",
                 searchURL: "https://www.findmypast.co.uk/search/results",
                 parameters: [
                    Parameter("firstname", .givenName),
                    Parameter("lastname", .surname, required: true),
                    Parameter("yearofbirth", .birthYear),
                    Parameter("yearofbirth_offset", .constant("5")),
                 ],
                 formURL: "https://www.findmypast.co.uk/search",
                 conditions: [inGB],
                 verification: .verified("survey 2026-10-01: firstname/lastname 200; yearofbirth from the Irish site's captured URLs")),
            Site(id: "gb.tna.discovery",
                 title: "The National Archives (UK) Discovery",
                 group: ew,
                 reason: "Recorded in {place}: the national catalogue — wills before 1858 (PROB 11), service records, court and estate papers.",
                 searchURL: "https://discovery.nationalarchives.gov.uk/results/r",
                 parameters: [Parameter("_q", .surnameThenGiven, required: true)],
                 formURL: "https://discovery.nationalarchives.gov.uk/",
                 conditions: [inEW],
                 verification: .verified("survey 2026-10-01")),
            Site(id: "gb.genuki.england",
                 title: "GENUKI — where the county's records are kept",
                 group: ew,
                 reason: "Recorded in {place}: the county page lists every parish's registers, census and memorial sets and where they are held.",
                 searchURL: "https://www.genuki.org.uk/big/eng/",
                 pathField: .englishChapman,
                 formURL: "https://www.genuki.org.uk/big/eng",
                 conditions: [.recordedIn(.england)],
                 verification: .verified("survey 2026-10-01: /big/eng/CON 200")),
            Site(id: "gb.genuki.wales",
                 title: "GENUKI — Wales",
                 group: ew,
                 reason: "Recorded in {place}: where the Welsh parish registers and census returns are held.",
                 searchURL: nil,
                 formURL: "https://www.genuki.org.uk/big/wal",
                 conditions: [.recordedIn(.wales)],
                 verification: .formOnly("country page")),
            Site(id: "gb.genuki.scotland",
                 title: "GENUKI — Scotland",
                 group: sct,
                 reason: "Recorded in {place}: where each Scottish parish's records are held.",
                 searchURL: nil,
                 formURL: "https://www.genuki.org.uk/big/sct",
                 conditions: [.recordedIn(.scotland)],
                 verification: .formOnly("country page")),
            Site(id: "gb.deceasedonline",
                 title: "Deceased Online — council burial registers",
                 group: ew,
                 reason: "Died in {place}: burial and cremation registers of participating councils (pay per view).",
                 searchURL: "https://www.deceasedonline.com/dec_search.php",
                 parameters: [
                    Parameter("s", .surname, required: true),
                    Parameter("f", .givenName),
                    Parameter("b", .deathYearOffset(-1)),
                    Parameter("e", .deathYearOffset(2)),
                 ],
                 formURL: "https://www.deceasedonline.com/",
                 conditions: [diedGB],
                 verification: .browserOnly("GET form field names read from the home page (survey); pre-fill not yet clicked through")),
            Site(id: "gb.billiongraves",
                 title: "BillionGraves — headstone photos (UK)",
                 group: ew,
                 reason: "Died in {place}: GPS-tagged headstone photos and transcriptions.",
                 searchURL: "https://billiongraves.com/search/results",
                 parameters: [
                    Parameter("given_names", .givenName),
                    Parameter("family_names", .surname, required: true),
                    Parameter("country", .constant("United Kingdom")),
                 ],
                 formURL: "https://billiongraves.com/",
                 conditions: [diedGB],
                 verification: .browserOnly("200 to scripts but a JS app; results only render in a browser")),
            // Tier 4 — blank forms. Their terms allow only a person typing
            // into the search ("The use of front end programs or sites to
            // enter search parameters is strictly forbidden" — FreeBMD), or
            // a login comes first. The link opens the form; nothing more.
            Site(id: "gb.freebmd",
                 title: "FreeBMD — England and Wales BMD index (type the search yourself)",
                 group: ew,
                 reason: "Recorded in {place}. Free volunteer index to GRO births, marriages and deaths from 1837; their terms allow only searches typed by hand.",
                 searchURL: nil,
                 formURL: "https://www.freebmd.org.uk/cgi/search.pl",
                 conditions: [inEW, .diedFrom(1837)],
                 verification: .formOnly("POST + terms forbid software filling in the search")),
            Site(id: "gb.freecen",
                 title: "FreeCEN — census transcriptions 1841–1901 (type the search yourself)",
                 group: ew,
                 reason: "Recorded in {place}. Free census transcriptions, strongest for Scotland 1841/1851; searches by hand only.",
                 searchURL: nil,
                 formURL: "https://www.freecen.org.uk/search_queries/new",
                 conditions: [inGB, .diedFrom(1841), .bornBefore(1911)],
                 verification: .formOnly("POST + CSRF; terms forbid software filling in the search")),
            Site(id: "gb.freereg",
                 title: "FreeREG — parish register transcriptions (type the search yourself)",
                 group: ew,
                 reason: "Recorded in {place}. Free baptism, marriage and burial transcriptions from 1538; searches by hand only.",
                 searchURL: nil,
                 formURL: "https://www.freereg.org.uk/search_queries/new",
                 conditions: [inGB, .bornBefore(1900)],
                 verification: .formOnly("POST + CSRF")),
            Site(id: "gb.gro",
                 title: "GRO England and Wales index (login)",
                 group: ew,
                 reason: "Recorded in {place}. The official index — births with mother's maiden name, deaths with age; certificate PDFs to order. Log in, then search.",
                 searchURL: nil,
                 formURL: "https://www.gro.gov.uk/gro/content/certificates/indexes_search.asp",
                 conditions: [inEW, .diedFrom(1837)],
                 verification: .formOnly("302 to Login.asp")),
            Site(id: "gb.probate",
                 title: "Probate calendar — England and Wales wills from 1858",
                 group: ew,
                 reason: "Died in {place}: the national calendar of wills and administrations; copies to order.",
                 searchURL: nil,
                 formURL: "https://www.gov.uk/search-will-probate",
                 conditions: [diedEW, .diedFrom(1858)],
                 verification: .formOnly("gov.uk landing page")),
            Site(id: "gb.scotlandspeople.births",
                 title: "ScotlandsPeople — statutory births (login)",
                 group: sct,
                 reason: "Recorded in {place}. Scottish birth entries from 1855 name the parents' marriage date and place. Log in, then search.",
                 searchURL: nil,
                 formURL: "https://www.scotlandspeople.gov.uk/search-records/statutory-records/stat_births",
                 conditions: [.recordedIn(.scotland), .bornFrom(1855)],
                 verification: .formOnly("login; terms forbid automated access")),
            Site(id: "gb.scotlandspeople.baptisms",
                 title: "ScotlandsPeople — church baptisms (login)",
                 group: sct,
                 reason: "Recorded in {place}. Old Parish Register baptisms before 1855. Log in, then search.",
                 searchURL: nil,
                 formURL: "https://www.scotlandspeople.gov.uk/search-records/church-registers/church-births-baptisms",
                 conditions: [.recordedIn(.scotland), .bornBefore(1855)],
                 verification: .formOnly("login; terms forbid automated access")),
        ]
    }()
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
