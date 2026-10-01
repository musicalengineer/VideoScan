// FamilyTreeResearchLinks.swift
// "When someone is born in Ireland we know we have to go out to these Irish
// search sites" (Rick, 2026-08-31).
//
// Derived, never stored: given a person, work out which archives are worth
// a look and build the deep links. Nothing here fetches anything — the
// Irish state sites return 403 to scripts while serving browsers happily,
// which is the site saying "a human may read this, a robot may not". A
// link the reader clicks respects that and is also more robust than a
// scraper: no parsing to break when they redesign.
//
// THIS ONLY WORKS BECAUSE OF YESTERDAY. Birthplace reached the app on
// 2026-08-30; before that the tree knew dates and names but not WHERE, so
// "born in Ireland → Irish archives" could not be asked.
//
// Region comes from the place STRING, because that is what a GEDCOM
// carries: "Cork, Ireland", "Derry, Ireland", "Yorkshire, England". County
// names are matched as well as countries — plenty of Irish records say only
// "Co. Mayo".
//
// 2026-10-01 (GH #230 Phase A): the per-archive links now come from the
// Record Finder registry (RecordFinder.swift) — one data entry per archive,
// pre-filled where the archive's query format has been confirmed. The two
// stale Irish links were replaced there: www.census.nationalarchives.ie
// (retired Feb 2025, connection refused) → nationalarchives.ie's census
// search; civilrecords.irishgenealogy.ie (old host, 403) → the combined
// irishgenealogy.ie search. This file keeps the region rule, the
// FamilySearch links (built from an ID, not a template) and the ordering.

import Foundation

public enum FamilyTreeResearchLinks {

    public struct Link: Sendable, Equatable, Identifiable {
        public let title: String
        public let url: URL
        /// Why this link is being offered, shown so the reader knows
        /// whether it is worth the click.
        public let reason: String
        /// True when the URL carries the person's details, false when it
        /// only lands on the archive's search form.
        public let isPrefilled: Bool
        /// Menu section the link belongs in ("Ireland", "FamilySearch", …).
        public let group: String
        /// The Record Finder site this came from; nil for links built in
        /// code (FamilySearch profile, Chronicling America).
        public let siteID: String?
        public var id: String { url.absoluteString }

        public init(title: String, url: URL, reason: String, isPrefilled: Bool,
                    group: String = "", siteID: String? = nil) {
            self.title = title
            self.url = url
            self.reason = reason
            self.isPrefilled = isPrefilled
            self.group = group
            self.siteID = siteID
        }
    }

    public enum Region: String, Sendable, CaseIterable {
        case ireland, england, wales, scotland, unitedStates

        var label: String {
            switch self {
            case .ireland: "Ireland"
            case .england: "England"
            case .wales: "Wales"
            case .scotland: "Scotland"
            case .unitedStates: "United States"
            }
        }
    }

    /// The 32 counties, so "Co. Mayo" or "Ballina, Mayo" resolves even when
    /// the record never says "Ireland". Both names are listed where the
    /// county has two.
    private static let irishCounties = [
        "antrim", "armagh", "carlow", "cavan", "clare", "cork", "derry",
        "londonderry", "donegal", "down", "dublin", "fermanagh", "galway",
        "kerry", "kildare", "kilkenny", "laois", "queen's county", "leitrim",
        "limerick", "longford", "louth", "mayo", "meath", "monaghan",
        "offaly", "king's county", "roscommon", "sligo", "tipperary",
        "tyrone", "waterford", "westmeath", "wexford", "wicklow",
    ]

    private static let englishMarkers = [
        "england", "yorkshire", "lancashire", "devon", "cornwall", "kent",
        "surrey", "sussex", "essex", "norfolk", "suffolk", "somerset",
        "dorset", "cheshire", "durham", "northumberland", "london",
    ]

    /// Scotland: the country and the counties/cities records name most.
    private static let scottishMarkers = [
        "scotland", "edinburgh", "glasgow", "aberdeen", "dundee", "lanarkshire",
        "ayrshire", "renfrewshire", "midlothian", "fife", "perthshire",
        "stirlingshire", "argyll", "inverness", "dumfriesshire", "berwickshire",
    ]

    /// Wales — "New South Wales" is Australia and is excluded below.
    private static let welshMarkers = [
        "wales", "glamorgan", "cardiff", "swansea", "carmarthen", "pembrokeshire",
        "caernarfon", "carnarvon", "denbigh", "flintshire", "monmouthshire",
        "anglesey", "merioneth", "cardiganshire", "brecon", "montgomeryshire",
    ]

    /// US words matched anywhere in a place (whole words): the country,
    /// the old colonial name, two cities the tree uses bare.
    private static let usMarkers = [
        "united states", "usa", "u s a", "new england", "boston", "albany",
    ]

    /// The 50 states and DC, matched as whole words.
    static let usStateNames: [String] = [
        "alabama", "alaska", "arizona", "arkansas", "california", "colorado", "connecticut",
        "delaware", "florida", "georgia", "hawaii", "idaho", "illinois", "indiana", "iowa",
        "kansas", "kentucky", "louisiana", "maine", "maryland", "massachusetts", "michigan",
        "minnesota", "mississippi", "missouri", "montana", "nebraska", "nevada", "new hampshire",
        "new jersey", "new mexico", "new york", "north carolina", "north dakota", "ohio",
        "oklahoma", "oregon", "pennsylvania", "rhode island", "south carolina", "south dakota",
        "tennessee", "texas", "utah", "vermont", "virginia", "washington", "west virginia",
        "wisconsin", "wyoming", "district of columbia",
    ]

    /// Postal abbreviations — matched only as a WHOLE comma-part ("Salem,
    /// Essex, MA"), never inside text, because "co", "me", "in" are words.
    static let usStateAbbreviations: Set<String> = [
        "al", "ak", "az", "ar", "ca", "co", "ct", "de", "fl", "ga", "hi", "id", "il", "in", "ia",
        "ks", "ky", "la", "me", "md", "ma", "mi", "mn", "ms", "mo", "mt", "ne", "nv", "nh", "nj",
        "nm", "ny", "nc", "nd", "oh", "ok", "or", "pa", "ri", "sc", "sd", "tn", "tx", "ut", "vt",
        "va", "wa", "wv", "wi", "wy", "dc", "us",
    ]

    /// Regions suggested by anywhere the record places this person.
    /// Deliberately returns a SET: someone born in Cork and dying in Boston
    /// is worth looking for on both sides of the water.
    ///
    /// QA 2026-10-01 (P2-4): each place is classified ON ITS OWN, by whole
    /// words. New England reused British and Irish names — Suffolk, Essex
    /// and Norfolk counties in Massachusetts, Wales MA, Derry and Antrim NH,
    /// Kent CT ("Kent" also hid inside "Kentucky") — and a substring rule
    /// sent those people to PRONI, PROB 11 and the Londonderry census. A
    /// place that carries a US marker is the United States; only an
    /// explicit country name in that SAME place ("…, Ireland") adds a
    /// British-Isles region to it.
    public static func regions(birthPlace: String?, deathPlace: String?) -> Set<Region> {
        var out: Set<Region> = []
        for place in [birthPlace, deathPlace].compactMap({ $0 }) {
            out.formUnion(regions(ofPlace: place))
        }
        return out
    }

    /// One place string → its regions (see `regions(birthPlace:deathPlace:)`).
    public static func regions(ofPlace place: String) -> Set<Region> {
        let words = " " + normalisedWords(place) + " "
        guard words.trimmingCharacters(in: .whitespaces).isEmpty == false else { return [] }
        func has(_ phrase: String) -> Bool { words.contains(" " + phrase + " ") }
        let parts = place.lowercased().split(separator: ",")
            .map { $0.replacingOccurrences(of: ".", with: "").trimmingCharacters(in: .whitespaces) }

        let isUS = usMarkers.contains(where: has) || usStateNames.contains(where: has)
            || parts.contains(where: { usStateAbbreviations.contains($0) })
        // "New England" names the US, and "New South Wales" Australia —
        // neither is the country of the same name.
        let withoutNewWorld = words.replacingOccurrences(of: " new england ", with: " ")
            .replacingOccurrences(of: " new south wales ", with: " ")
        func hasCountry(_ name: String) -> Bool { withoutNewWorld.contains(" " + name + " ") }

        var out: Set<Region> = []
        if isUS {
            out.insert(.unitedStates)
            // Only a whole comma-part in COUNTRY position counts — never the
            // first part, which is the town ("Wales, Hampden, Massachusetts").
            let countryParts = Set(parts.dropFirst())
            for (name, region) in [("ireland", Region.ireland), ("england", .england),
                                   ("scotland", .scotland), ("wales", .wales)]
            where countryParts.contains(name) {
                out.insert(region)
            }
            return out
        }
        if hasCountry("ireland") || irishCounties.contains(where: has) { out.insert(.ireland) }
        if englishMarkers.contains(where: { hasCountry($0) }) { out.insert(.england) }
        if scottishMarkers.contains(where: has) { out.insert(.scotland) }
        if welshMarkers.contains(where: { hasCountry($0) }) { out.insert(.wales) }
        return out
    }

    /// Lower-case words separated by single spaces; letters, digits and
    /// apostrophes only ("Queen's Co." → "queen's co").
    static func normalisedWords(_ text: String) -> String {
        var out = ""
        var pendingSpace = false
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "'" || ch == "’" {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(ch == "’" ? "'" : ch)
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    /// Everything worth clicking for this person.
    ///
    /// Order: FamilySearch (it has absorbed many collections), then the
    /// Record Finder registry — Ireland, UK military, Britain — then the
    /// United States. `isPrefilled: false` links land on the archive's own
    /// search form; the registry only pre-fills where the query format was
    /// confirmed (RecordFinder.Site.verification).
    public static func links(name: String,
                             surname: String?,
                             birthYear: Int?,
                             birthPlace: String?,
                             deathPlace: String?,
                             familySearchID: String?,
                             deathYear: Int? = nil,
                             servedInMilitary: Bool = false) -> [Link] {
        var out: [Link] = []

        // FamilySearch first, and not for sentimental reasons: it has
        // ABSORBED the collections. The 1901 and 1911 Irish censuses and
        // the civil registration indexes to 1958 are indexed there, so for
        // a person who already has an FSID the record may be attached to
        // the profile already — one login instead of three sites.
        if let fsid = familySearchID, !fsid.isEmpty {
            if let url = URL(string: "https://www.familysearch.org/tree/person/details/\(fsid)") {
                out.append(Link(title: "FamilySearch profile",
                                url: url,
                                reason: "Sources already attached to \(fsid) — check here before searching elsewhere.",
                                isPrefilled: true, group: "FamilySearch"))
            }
            if let url = URL(string: "https://www.familysearch.org/tree/person/sources/\(fsid)") {
                out.append(Link(title: "FamilySearch attached sources",
                                url: url,
                                reason: "Records someone has already linked to this person.",
                                isPrefilled: true, group: "FamilySearch"))
            }
        }

        let person = RecordFinder.Person(name: name, surname: surname, birthYear: birthYear,
                                         deathYear: deathYear, birthPlace: birthPlace,
                                         deathPlace: deathPlace, servedInMilitary: servedInMilitary)
        let context = RecordFinder.Context(person)

        out.append(contentsOf: RecordFinder.ireland.compactMap { RecordFinder.link(for: $0, in: context) })
        if context.regions.contains(.ireland),
           let url = familySearchRecordSearch(name: name, surname: surname,
                                              birthYear: birthYear, country: "Ireland") {
            out.append(Link(title: "FamilySearch — Irish records for this name",
                            url: url,
                            reason: "The Irish census and civil registration indexes, searched from inside FamilySearch.",
                            isPrefilled: true, group: "Ireland"))
        }
        out.append(contentsOf: RecordFinder.military.compactMap { RecordFinder.link(for: $0, in: context) })
        out.append(contentsOf: RecordFinder.britain.compactMap { RecordFinder.link(for: $0, in: context) })
        out.append(contentsOf: RecordFinder.burials.compactMap { RecordFinder.link(for: $0, in: context) })

        if context.regions.contains(.unitedStates),
           let url = URL(string: "https://chroniclingamerica.loc.gov/search/pages/results/") {
            out.append(Link(title: "Chronicling America",
                            url: url,
                            reason: "Recorded in the United States — Library of Congress newspaper archive.",
                            isPrefilled: false, group: "United States"))
        }

        return out
    }

    /// FamilySearch's record search takes its query in the URL. Best-effort
    /// and easy to check: if the result page is empty the parameters are
    /// wrong, and the link is one click away from telling you.
    public static func familySearchRecordSearch(name: String, surname: String?,
                                         birthYear: Int?, country: String) -> URL? {
        var items: [URLQueryItem] = []
        let given = name.split(separator: " ").first.map(String.init)
        if let given { items.append(URLQueryItem(name: "q.givenName", value: given)) }
        if let surname, !surname.isEmpty {
            items.append(URLQueryItem(name: "q.surname", value: surname))
        }
        if let birthYear {
            items.append(URLQueryItem(name: "q.birthLikeDate.from", value: String(birthYear - 5)))
            items.append(URLQueryItem(name: "q.birthLikeDate.to", value: String(birthYear + 5)))
        }
        items.append(URLQueryItem(name: "q.birthLikePlace", value: country))
        guard !items.isEmpty else { return nil }
        var components = URLComponents(string: "https://www.familysearch.org/search/record/results")
        components?.queryItems = items
        return components?.url
    }
}
