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
        public var id: String { url.absoluteString }
    }

    public enum Region: String, Sendable, CaseIterable {
        case ireland, england, unitedStates

        var label: String {
            switch self {
            case .ireland: "Ireland"
            case .england: "England"
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

    private static let usMarkers = [
        "united states", "usa", "u.s.a", "massachusetts", "new york",
        "connecticut", "rhode island", "new hampshire", "vermont", "maine",
        "new jersey", "pennsylvania", "boston", "albany",
    ]

    /// Regions suggested by anywhere the record places this person.
    /// Deliberately returns a SET: someone born in Cork and dying in Boston
    /// is worth looking for on both sides of the water.
    public static func regions(birthPlace: String?, deathPlace: String?) -> Set<Region> {
        let haystack = [birthPlace, deathPlace]
            .compactMap { $0?.lowercased() }
            .joined(separator: " | ")
        guard !haystack.isEmpty else { return [] }
        var out: Set<Region> = []
        if haystack.contains("ireland") || irishCounties.contains(where: { haystack.contains($0) }) {
            out.insert(.ireland)
        }
        if englishMarkers.contains(where: { haystack.contains($0) }) { out.insert(.england) }
        if usMarkers.contains(where: { haystack.contains($0) }) { out.insert(.unitedStates) }
        return out
    }

    /// Everything worth clicking for this person.
    ///
    /// `isPrefilled: false` links land on the archive's own search form.
    /// The Irish state sites publish no API and their query parameters have
    /// not been verified from a real search, so guessing them would produce
    /// links that land on an error page — worse than landing on the form.
    /// Verified formats can be added later without changing any caller.
    public static func links(name: String,
                             surname: String?,
                             birthYear: Int?,
                             birthPlace: String?,
                             deathPlace: String?,
                             familySearchID: String?) -> [Link] {
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
                                isPrefilled: true))
            }
            if let url = URL(string: "https://www.familysearch.org/tree/person/sources/\(fsid)") {
                out.append(Link(title: "FamilySearch attached sources",
                                url: url,
                                reason: "Records someone has already linked to this person.",
                                isPrefilled: true))
            }
        }

        let found = regions(birthPlace: birthPlace, deathPlace: deathPlace)

        if found.contains(.ireland) {
            let where_ = [birthPlace, deathPlace].compactMap { $0 }.first ?? "Ireland"
            out.append(contentsOf: [
                link("Census of Ireland 1901 / 1911",
                     "https://www.census.nationalarchives.ie/",
                     "Recorded in \(where_). The only two surviving full censuses — household returns, occupations and townland, free, with scans of the original page."),
                link("Irish civil records (birth, marriage, death)",
                     "https://civilrecords.irishgenealogy.ie/",
                     "State registration with register images: births to 100 years ago, marriages 75, deaths 50."),
                link("National Archives genealogy",
                     "https://genealogy.nationalarchives.ie/",
                     "Tithe Applotment Books 1823–37, wills and administrations 1858–1922."),
            ])
            if let url = familySearchRecordSearch(name: name, surname: surname,
                                                  birthYear: birthYear, country: "Ireland") {
                out.append(Link(title: "FamilySearch — Irish records for this name",
                                url: url,
                                reason: "The Irish census and civil registration indexes, searched from inside FamilySearch.",
                                isPrefilled: true))
            }
        }

        if found.contains(.england) {
            out.append(link("The National Archives (UK) Discovery",
                            "https://discovery.nationalarchives.gov.uk/",
                            "Recorded in England."))
        }

        if found.contains(.unitedStates) {
            out.append(link("Chronicling America",
                            "https://chroniclingamerica.loc.gov/search/pages/results/",
                            "Recorded in the United States — Library of Congress newspaper archive."))
        }

        return out
    }

    private static func link(_ title: String, _ urlString: String, _ reason: String) -> Link {
        Link(title: title, url: URL(string: urlString)!,   // swiftlint:disable:this force_unwrapping
             reason: reason, isPrefilled: false)
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
