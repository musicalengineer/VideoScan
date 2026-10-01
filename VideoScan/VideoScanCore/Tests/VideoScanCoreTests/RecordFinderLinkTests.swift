import Foundation
import Testing
@testable import VideoScanCore

// GH #230 Phase A — the Record Finder link registry.
//
// Dimensions (CLAUDE.md feature-test checklist):
//   Logic     — per-site URL building, conditions, county parsing, surname
//               variants, strict encoding, form fallback
//   Scale     — 100k synthetic people through the registry under a budget
//   Media     — n/a (no media files)
//   Isolation — pure functions; no network, no disk, no global state
//   Sensor    — a pinned table of EXACT URLs per site (incl. every
//               "browser-only" shape the survey marked blocked to scripts):
//               a redesign shows up as a red row here, not a 404 for Rick
//
// Synthetic people only — invented surnames, no family data (public repo).

private func person(given: String? = "Honora", surname: String? = "Fenlane",
                    born: Int? = 1878, died: Int? = 1935,
                    birthPlace: String? = "Skibbereen, County Cork, Ireland",
                    deathPlace: String? = "Boston, Massachusetts",
                    soldier: Bool = false) -> RecordFinder.Person {
    RecordFinder.Person(givenName: given, surname: surname, birthYear: born, deathYear: died,
                        birthPlace: birthPlace, deathPlace: deathPlace, servedInMilitary: soldier)
}

private func links(_ p: RecordFinder.Person) -> [String: FamilyTreeResearchLinks.Link] {
    var out: [String: FamilyTreeResearchLinks.Link] = [:]
    for link in RecordFinder.links(for: p) { if let id = link.siteID { out[id] = link } }
    return out
}

@Suite("Record Finder — pinned URLs (sensor)")
struct RecordFinderPinnedURLTests {

    @Test func irishEmigrantGetsTheIrishArchivesPrefilled() throws {
        let byID = links(person())
        let pinned: [String: String] = [
            "ie.nai.census-1901-1911":
                "https://nationalarchives.ie/collections/search-the-census/search-results/?surname=Fenlane&firstname=Honora&county=Cork",
            "ie.irishgenealogy.civil-church":
                "https://www.irishgenealogy.ie/search/?church-or-civil=all&firstname=Honora&lastname=Fenlane&location=Cork&yearStart=1877&yearEnd=1936&event-birth=1&event-marriage=1&event-death=1&event-baptism=1&event-burial=1",
            "ie.griffiths":
                "https://www.askaboutireland.ie/griffith-valuation/index.xml?action=doNameSearch&familyname=Fenlane&countyname=Cork",
            "ie.nli.registers":
                "https://registers.nli.ie/?q=Skibbereen",
            "ie.findmypast.catholic-baptisms":
                "https://www.findmypast.ie/search/results?datasetname=ireland%20roman%20catholic%20parish%20baptisms&firstname=Honora&lastname=Fenlane&yearofbirth=1878&yearofbirth_offset=2",
            "world.findagrave":
                "https://www.findagrave.com/memorial/search?firstname=Honora&lastname=Fenlane&birthyear=1878&birthyearfilter=5&deathyear=1935&deathyearfilter=5",
        ]
        for (id, url) in pinned {
            let link = try #require(byID[id], "missing \(id)")
            #expect(link.url.absoluteString == url, "\(id)")
            #expect(link.isPrefilled, "\(id)")
        }
        // Form-only Irish sites land on their forms and say so.
        let census1926 = try #require(byID["ie.nai.census-1926"])
        #expect(census1926.url.absoluteString == "https://nationalarchives.ie/collections/search-the-1926-census/")
        #expect(!census1926.isPrefilled)
        #expect(byID["ie.nai.genealogy"]?.isPrefilled == false)
        // Not offered: pre-1851 fragments (born 1878), PRONI (Cork), military.
        #expect(byID["ie.nai.census-1821-1851"] == nil)
        #expect(byID["ie.proni.wills"] == nil)
        #expect(byID["uk.tna.wo97"] == nil)
    }

    @Test func theTwoStaleIrishHostsAreGone() {
        let all = RecordFinder.links(for: person()).map(\.url.absoluteString)
        #expect(!all.contains { $0.contains("census.nationalarchives.ie") && !$0.contains("api-census") },
                "www.census.nationalarchives.ie was retired in Feb 2025")
        #expect(!all.contains { $0.contains("civilrecords.irishgenealogy.ie") },
                "the old civil-records host 403s; the combined search replaced it")
        let flat = FamilyTreeResearchLinks.links(name: "Honora Fenlane", surname: "Fenlane", birthYear: 1878,
                                                 birthPlace: "Cork, Ireland", deathPlace: nil, familySearchID: nil)
        #expect(!flat.contains { $0.url.host == "www.census.nationalarchives.ie" })
        #expect(!flat.contains { $0.url.host == "civilrecords.irishgenealogy.ie" })
    }

    @Test func aSoldierGetsTheBritishArmySearches() throws {
        let byID = links(person(given: "Cornelius", born: 1880, died: 1950,
                                birthPlace: "Bandon, Co. Cork, Ireland", deathPlace: nil, soldier: true))
        #expect(byID["uk.tna.wo97"]?.url.absoluteString
                == "https://discovery.nationalarchives.gov.uk/results/r?_q=Fenlane%20Cornelius&_ser=WO%2097")
        #expect(byID["uk.tna.wo363"]?.url.absoluteString
                == "https://discovery.nationalarchives.gov.uk/results/r?_q=Fenlane%20Cornelius&_ser=WO%20363")
        #expect(byID["ie.nli.registers"]?.url.absoluteString == "https://registers.nli.ie/?q=Bandon")
        // The same man without recorded service is not sent to the army records.
        let civilian = links(person(given: "Cornelius", born: 1880, died: 1950,
                                    birthPlace: "Bandon, Co. Cork, Ireland", deathPlace: nil))
        #expect(civilian["uk.tna.wo97"] == nil)
        #expect(civilian["uk.tna.wo363"] == nil)
    }

    @Test func englishLineGetsFamilySearchCollectionsAndBlankForms() throws {
        let byID = links(person(given: "Thomasina", surname: "Polwenna", born: 1850, died: 1920,
                                birthPlace: "St Austell, Cornwall, England",
                                deathPlace: "Bolton, Lancashire, England"))
        let pinned: [String: String] = [
            "gb.fs.ew-birth-index":
                "https://www.familysearch.org/search/record/results?q.givenName=Thomasina&q.surname=Polwenna&q.birthLikeDate.from=1845&q.birthLikeDate.to=1855&q.birthLikePlace=England&f.collectionId=2285338",
            "gb.fs.england-births":
                "https://www.familysearch.org/search/record/results?q.givenName=Thomasina&q.surname=Polwenna&q.birthLikeDate.from=1845&q.birthLikeDate.to=1855&q.birthLikePlace=England&f.collectionId=1473014",
            "gb.fs.ew-census-1881":
                "https://www.familysearch.org/search/record/results?q.givenName=Thomasina&q.surname=Polwenna&q.birthLikeDate.from=1845&q.birthLikeDate.to=1855&q.birthLikePlace=England&f.collectionId=2562194",
            "gb.findmypast":
                "https://www.findmypast.co.uk/search/results?firstname=Thomasina&lastname=Polwenna&yearofbirth=1850&yearofbirth_offset=5",
            "gb.tna.discovery":
                "https://discovery.nationalarchives.gov.uk/results/r?_q=Polwenna%20Thomasina",
            "gb.genuki.england":
                "https://www.genuki.org.uk/big/eng/CON",
            // Survey "B" shapes — blocked to scripts; pinned by shape only.
            "gb.deceasedonline":
                "https://www.deceasedonline.com/dec_search.php?s=Polwenna&f=Thomasina&b=1919&e=1922",
            "gb.billiongraves":
                "https://billiongraves.com/search/results?given_names=Thomasina&family_names=Polwenna&country=United%20Kingdom",
        ]
        for (id, url) in pinned {
            let link = try #require(byID[id], "missing \(id)")
            #expect(link.url.absoluteString == url, "\(id)")
            #expect(link.isPrefilled, "\(id)")
        }
        // Tier 4: blank forms only — never pre-filled (terms / login / POST).
        let forms: [String: String] = [
            "gb.freebmd": "https://www.freebmd.org.uk/cgi/search.pl",
            "gb.freecen": "https://www.freecen.org.uk/search_queries/new",
            "gb.freereg": "https://www.freereg.org.uk/search_queries/new",
            "gb.gro": "https://www.gro.gov.uk/gro/content/certificates/indexes_search.asp",
            "gb.probate": "https://www.gov.uk/search-will-probate",
        ]
        for (id, url) in forms {
            let link = try #require(byID[id], "missing \(id)")
            #expect(link.url.absoluteString == url, "\(id)")
            #expect(!link.isPrefilled, "\(id) must not claim to be pre-filled")
        }
        #expect(byID["gb.fs.england-burials"] == nil, "died 1920 — the pre-1900 burial collection is noise")
        #expect(byID["gb.scotlandspeople.births"] == nil)
        #expect(byID["ie.nai.census-1901-1911"] == nil)
    }

    @Test func scottishLineGetsScottishCollections() throws {
        let byID = links(person(given: "Euphemia", surname: "Glendarroch", born: 1860, died: nil,
                                birthPlace: "Paisley, Renfrewshire, Scotland", deathPlace: nil))
        #expect(byID["gb.fs.scotland-births"]?.url.absoluteString
                == "https://www.familysearch.org/search/record/results?q.givenName=Euphemia&q.surname=Glendarroch&q.birthLikeDate.from=1855&q.birthLikeDate.to=1865&q.birthLikePlace=Scotland&f.collectionId=1771030")
        #expect(byID["gb.scotlandspeople.births"]?.url.absoluteString
                == "https://www.scotlandspeople.gov.uk/search-records/statutory-records/stat_births")
        #expect(byID["gb.scotlandspeople.births"]?.isPrefilled == false)
        #expect(byID["gb.scotlandspeople.baptisms"] == nil, "born 1860 — after statutory registration began")
        #expect(byID["gb.genuki.scotland"] != nil)
        #expect(byID["gb.fs.ew-birth-index"] == nil)
    }
}

@Suite("Record Finder — rules")
struct RecordFinderRuleTests {

    @Test func censusYearIsPinnedOnlyWhenOneYearFits() {
        let born1905 = links(person(born: 1905, died: nil, deathPlace: nil))["ie.nai.census-1901-1911"]
        #expect(born1905?.url.absoluteString.contains("census_year=1911") == true)
        let both = links(person(born: 1890, died: nil, deathPlace: nil))["ie.nai.census-1901-1911"]
        #expect(both?.url.absoluteString.contains("census_year") == false)
        #expect(links(person(born: 1820, died: 1890))["ie.nai.census-1901-1911"] == nil,
                "died before 1901 — not in either census")
    }

    @Test func kingsCountyIsSpelledTheWayTheCensusIndexSpellsIt() {
        let url = links(person(birthPlace: "Tullamore, King's County, Ireland", deathPlace: nil))["ie.nai.census-1901-1911"]?
            .url.absoluteString ?? ""
        #expect(url.contains("county=King%27s%20Co."), "\(url)")
        #expect(IrishCounty.parse("Queen's Co., Ireland")?.censusName == "Queen's Co.")
        #expect(IrishCounty.parse("Mountmellick, Laois")?.name == "Laois")
    }

    @Test func derryIsNorthernIrelandAndGetsPRONINot1926() {
        let byID = links(person(born: 1880, died: 1940, birthPlace: "Derry, Ireland", deathPlace: nil))
        #expect(byID["ie.proni.wills"] != nil)
        #expect(byID["ie.nai.census-1926"] == nil, "the 1926 census covers the Free State only")
        #expect(byID["ie.nai.census-1901-1911"]?.url.absoluteString.contains("county=Londonderry") == true)
    }

    @Test func countyParsingUsesWholePartsNotSubstrings() {
        #expect(IrishCounty.parse("Skibbereen, County Cork, Ireland")?.name == "Cork")
        #expect(IrishCounty.parse("Cork City, Ireland")?.name == "Cork")
        #expect(IrishCounty.parse("Bandon Co Cork")?.name == "Cork")
        #expect(IrishCounty.parse("Ballina, Mayo")?.name == "Mayo")
        #expect(IrishCounty.parse("Downpatrick, Ireland") == nil, "Downpatrick is a town, not County Down")
        #expect(IrishCounty.parse("Ireland") == nil)
        #expect(EnglishCounty.chapmanCode("Bolton, Lancashire, England") == "LAN")
        #expect(EnglishCounty.chapmanCode("Paris, France") == nil)
    }

    @Test func newSouthWalesIsNotWales() {
        #expect(!FamilyTreeResearchLinks.regions(birthPlace: "Sydney, New South Wales, Australia", deathPlace: nil)
            .contains(.wales))
        #expect(FamilyTreeResearchLinks.regions(birthPlace: "Swansea, Glamorgan, Wales", deathPlace: nil) == [.wales])
        #expect(FamilyTreeResearchLinks.regions(birthPlace: "Paisley, Renfrewshire, Scotland", deathPlace: nil) == [.scotland])
    }

    @Test func aMissingSurnameDemotesToTheFormNotAGuess() throws {
        let byID = links(person(surname: nil))
        let census = try #require(byID["ie.nai.census-1901-1911"])
        #expect(!census.isPrefilled)
        #expect(census.url.absoluteString == "https://nationalarchives.ie/collections/search-the-census/")
        let ig = try #require(byID["ie.irishgenealogy.civil-church"])
        #expect(!ig.isPrefilled)
    }

    @Test func noPlaceAndNoServiceMeansNoLinks() {
        #expect(RecordFinder.links(for: person(birthPlace: nil, deathPlace: nil)).isEmpty)
    }

    @Test func encodingNeverLetsAValueSplitAParameter() {
        #expect(RecordFinder.encode("King's Co.") == "King%27s%20Co.")
        #expect(RecordFinder.encode("A&B=C?#/+") == "A%26B%3DC%3F%23%2F%2B")
        #expect(RecordFinder.encode("Ó Súilleabháin") == "%C3%93%20S%C3%BAilleabh%C3%A1in")
    }

    @Test func registryIsWellFormed() {
        let ids = RecordFinder.all.map(\.id)
        #expect(Set(ids).count == ids.count, "site ids must be unique")
        for site in RecordFinder.all {
            #expect(site.formURL.hasPrefix("https://"), "\(site.id)")
            #expect(site.searchURL.map { $0.hasPrefix("https://") } ?? true, "\(site.id)")
            #expect(!site.reason.isEmpty && !site.title.isEmpty, "\(site.id)")
            #expect(!site.conditions.isEmpty, "\(site.id) must say when it applies")
            if site.isFormOnly {
                #expect(site.parameters.isEmpty, "\(site.id): a form-only site carries no parameters")
                if case .formOnly = site.verification {} else {
                    Issue.record("\(site.id): form-only site must be verified as .formOnly")
                }
            }
        }
        // The terms-forbidden indexes can never be turned into pre-fills by
        // a careless edit.
        for id in ["gb.freebmd", "gb.freecen", "gb.freereg", "gb.gro",
                   "gb.scotlandspeople.births", "gb.scotlandspeople.baptisms"] {
            #expect(RecordFinder.all.first { $0.id == id }?.isFormOnly == true, "\(id)")
        }
    }

    @Test func everyLinkSaysWhyAndNamesThePlace() {
        let all = RecordFinder.links(for: person())
        #expect(all.allSatisfy { !$0.reason.isEmpty && !$0.reason.contains("{place}") })
        let census = all.first { $0.siteID == "ie.nai.census-1901-1911" }
        #expect(census?.reason.contains("Skibbereen") == true)
        #expect(census?.reason.contains("Boston") == false)
    }

    @Test func familySearchStillLeadsAndGroupsAreSet() throws {
        let flat = FamilyTreeResearchLinks.links(
            name: "Honora Fenlane", surname: "Fenlane", birthYear: 1878,
            birthPlace: "Skibbereen, County Cork, Ireland", deathPlace: "Boston, Massachusetts",
            familySearchID: "ABCD-123", deathYear: 1935)
        #expect(flat.first?.group == "FamilySearch")
        #expect(flat.allSatisfy { !$0.group.isEmpty })
        #expect(flat.contains { $0.title == "Chronicling America" })
        #expect(flat.contains { $0.siteID == "world.findagrave" })
    }
}

@Suite("Record Finder — surname spelling variants")
struct SurnameSpellingVariantTests {

    @Test func anEndingsAndTheOyVowelAreGenerated() {
        let v = SurnameSpellingVariants.variants(of: "Doran", limit: 10)
        #expect(v.first == "Doran")
        for expected in ["Dorane", "Dorayne", "Doraine", "Doyran"] {
            #expect(v.contains(expected), "\(expected) missing from \(v)")
        }
        #expect(v.contains("Doyrane"), "two rules combine: \(v)")
    }

    @Test func reverseDirectionsWork() {
        #expect(SurnameSpellingVariants.variants(of: "Dorayne", limit: 10).contains("Doran"))
        #expect(SurnameSpellingVariants.variants(of: "Doyran", limit: 10).contains("Doran"))
    }

    @Test func prefixesAreHandledConservatively() {
        #expect(SurnameSpellingVariants.variants(of: "McAvoy", limit: 10).contains("MacAvoy"))
        #expect(SurnameSpellingVariants.variants(of: "MacAvoy", limit: 10).contains("McAvoy"))
        #expect(!SurnameSpellingVariants.variants(of: "Mackey", limit: 10).contains { $0.hasPrefix("Mcc") },
                "Mackey is not Mac + Key")
        #expect(SurnameSpellingVariants.variants(of: "O'Dolan", limit: 10).contains("Dolan"))
        #expect(SurnameSpellingVariants.variants(of: "Daly", limit: 10).contains("Daley"))
        #expect(SurnameSpellingVariants.variants(of: "Daley", limit: 10).contains("Daly"))
    }

    @Test func limitsAndEmptyInput() {
        #expect(SurnameSpellingVariants.variants(of: "Doran", limit: 3).count == 3)
        #expect(SurnameSpellingVariants.variants(of: "   ").isEmpty)
        #expect(SurnameSpellingVariants.variants(of: "Doran", limit: 0).isEmpty)
        let v = SurnameSpellingVariants.variants(of: "Doran", limit: 20)
        #expect(Set(v.map { $0.lowercased() }).count == v.count, "no duplicates")
    }
}

@Suite("Record Finder — scale")
struct RecordFinderScaleTests {

    /// 100k synthetic people through the whole registry. The menu builds
    /// links for ONE person when it opens; this pins that the per-person
    /// cost is small enough that even a whole-tree pass would not stall.
    @Test func hundredThousandPeopleUnderBudget() {
        let places = ["Skibbereen, County Cork, Ireland", "Bolton, Lancashire, England",
                      "Paisley, Renfrewshire, Scotland", "Boston, Massachusetts", "Derry, Ireland", ""]
        let start = Date()
        var total = 0
        for i in 0..<100_000 {
            let p = RecordFinder.Person(givenName: "Given\(i % 97)", surname: "Surname\(i % 1013)",
                                        birthYear: 1800 + i % 150, deathYear: i % 3 == 0 ? nil : 1870 + i % 120,
                                        birthPlace: places[i % places.count],
                                        deathPlace: places[(i / 7) % places.count],
                                        servedInMilitary: i % 11 == 0)
            total += RecordFinder.links(for: p).count
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(total > 100_000)
        // Debug `swift test` on the M4 measured 20.8 s (2026-10-01; 51 s
        // before the byte-loop encoder). 60 s catches an accidental O(n²)
        // without flaking on a busy machine; Release is far faster.
        #expect(elapsed < 60, "100k people took \(elapsed) s")
    }
}
