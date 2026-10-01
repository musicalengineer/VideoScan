import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// GH #230 Phase B — the two record adapters (Census of Ireland 1901/1911,
// TNA Discovery) inside Research Person's runner, plus the Find a Grave
// demotion (Rick, 2026-10-01).
//
// Dimensions (CLAUDE.md feature-test checklist):
//   Logic     — parsers over recorded-SHAPE fixture JSON (synthetic rows,
//               no real people): age filter, `next` paging, empty result,
//               a 1,244-hit surname capped by the request budget; query
//               plans; partial failure; hints from a GEDCOM record
//   Scale     — a 10k-row census response parsed under a budget
//   Media     — n/a
//   Isolation — FixtureResearchFetcher only (never URLSession); every
//               request's host is on an allow-list; a POISONED cache file
//               and a cached garbage body are survived; a missing People
//               root reads as "nothing saved"; Discovery responses never
//               reach the disk cache
//   Sensor    — no automated source requests findagrave.com; filed records
//               survive a re-run's merge; pre-2026-10-01 dossiers decode
//
// No live network anywhere in this file.

/// 2026-10-01 14:00 / 15:00 UTC.
private let fetched = Date(timeIntervalSince1970: 1_790_863_200)
private let now = Date(timeIntervalSince1970: 1_790_866_800)

private func hints(surnames: [String] = ["Fenlane", "Fenlayne", "Fenlaine"],
                   born: Int? = 1878, died: Int? = 1935, irish: Bool = true,
                   soldier: Bool = false, ewDeathBefore1858: Bool = false) -> ResearchRecordHints {
    ResearchRecordHints(givenName: "Honora", surnames: surnames, birthYear: born, deathYear: died,
                        isIrish: irish, irishCensusCounty: irish ? "Cork" : nil,
                        servedInMilitary: soldier, diedInEnglandOrWalesBefore1858: ewDeathBefore1858)
}

private let plan = ResearchQueryPlan(nameVariants: ["Honora Fenlane"], yearFrom: 1873, yearTo: 1940,
                                     placeTokens: [], stateHint: nil)

/// The api-census `/census/query` shape (27 fields per row as probed
/// 2026-10-01), with invented people. Row 2 is far outside the age window;
/// row 3 has no id.
private let censusSmallJSON = """
{"results":[
 {"id": 900001, "census_year": 1911, "county": "Cork", "surname": "Fenlane", "firstname": "Honora",
  "townland": "Synthetic Street", "ded": "Test DED (part of)", "age": 33, "sex": "F", "house_number": "4",
  "relation_to_head": "Wife", "religion": "Roman Catholic", "education": "Read and write",
  "occupation": "Seamstress", "marriage_status": "Married", "marriage_years": 9, "children_born": 3,
  "children_living": 3, "birthplace": "Co Cork", "language": null, "deafdumb": null, "image_group": "1",
  "religion_updated": "Roman Catholic", "occupation_updated": "Seamstress", "relation_to_head_updated": "Wife",
  "language_updated": null,
  "images": [{"form": "Form A", "side": "1", "id": "naiTEST0001", "url": "/census/image/naiTEST0001.pdf"}]},
 {"id": 900002, "census_year": 1911, "county": "Cork", "surname": "Fenlane", "firstname": "Honora",
  "townland": "Other Lane", "ded": "Test DED", "age": 70, "images": []},
 {"census_year": 1911, "surname": "Fenlane", "firstname": "NoId", "age": 33}
],"meta":{"count":3,"next":null,"prev":null}}
"""

private let censusEmptyJSON = #"{"results":[],"meta":{"count":0,"next":null,"prev":null}}"#

/// A common surname: 1,244 hits, 10 per page, a `next` link.
private func censusCommonJSON() -> String {
    let rows = (0..<10).map { i in
        #"{"id": \#(910000 + i), "census_year": 1911, "county": "Cork", "surname": "Fenlane", "firstname": "Honora", "townland": "Row \#(i)", "ded": "D", "age": \#(20 + i * 5)}"#
    }.joined(separator: ",")
    return #"{"results":[\#(rows)],"meta":{"count":1244,"next":"?census_year=1911&county=Cork&surname=Fenlane&firstname=Honora&offset=10","prev":null}}"#
}

/// The Discovery `/API/search/records` shape (fields as probed 2026-10-01),
/// invented entries. The `context` marker must never reach a finding.
private let discoveryJSON = """
{"count": 2, "nextBatchMark": "x", "records": [
 {"id": "C900001", "reference": "WO 97/9999", "title": "Fenlane Cornelius - Fenlane John",
  "description": "Fenlane Cornelius - Fenlane John", "coveringDates": "1900-1913",
  "context": "CONTEXT-MARKER-NOT-TO-BE-KEPT", "heldBy": ["The National Archives, Kew"]},
 {"id": "C900002", "reference": "WO 363/F999", "title": "Fenlane Cornelius", "coveringDates": "1914 - 1920"},
 {"id": "", "reference": "WO 97/1"},
 {"id": "../etc", "reference": "WO 97/2"}
]}
"""

private func fixture(_ pairs: [(String, String)], status: Int = 200,
                     recorder: FixtureResearchFetcher.RequestRecorder? = nil) -> FixtureResearchFetcher {
    FixtureResearchFetcher(fixtures: pairs.map { .init(urlContains: $0.0, body: Data($0.1.utf8), statusCode: status) },
                           retrievedAt: fetched, recorder: recorder)
}

private func tempPeopleRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecordFinderAdapter-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("People", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private let soldierGedcom = """
0 HEAD
1 SOUR VideoScanTests
0 @I1@ INDI
1 NAME Cornelius /Fenlane/
1 SEX M
1 BIRT
2 DATE 1880
2 PLAC Bandon, Co. Cork, Ireland
1 DEAT
2 DATE 1950
1 _MILT Private, Royal Munster Fusiliers
1 _FSFTID TEST-001
0 @I2@ INDI
1 NAME Abner /Testerly/
1 SEX M
1 BIRT
2 DATE 1890
2 PLAC Albany, New York
1 DEAT
2 DATE 1960
1 _MILT World War I Draft Registration
0 @I3@ INDI
1 NAME Bridget
1 SEX F
1 BIRT
2 DATE 1870
2 PLAC Bandon, Co. Cork, Ireland
1 DEAT
2 DATE 1940
0 TRLR
"""

private func subject(_ id: String) throws -> ResearchSubject {
    let graph = GedcomFamilyGraph(gedcomText: soldierGedcom)
    guard case .eligible(let s) = ResearchEligibility.evaluate(graph.people[id], now: now) else {
        throw ResearchStore.StoreError.ioFailure("fixture subject \(id) not eligible")
    }
    return s
}

// MARK: - Census of Ireland

@Suite("Record Finder — Census of Ireland adapter (fixtures only)")
struct IrishCensusAdapterTests {

    @Test func parserKeepsRowsInTheAgeWindowAndSkipsBrokenOnes() throws {
        let page = IrishCensusSource.parse(Data(censusSmallJSON.utf8), retrievedAt: fetched, expectedAge: 33)
        #expect(page.total == 3)
        #expect(page.nextOffset == nil)
        try #require(page.findings.count == 1)
        let f = page.findings[0]
        #expect(f.source == .irishCensus)
        #expect(f.title == "Census 1911 — Honora Fenlane, age 33")
        #expect(f.date == "1911")
        #expect(f.excerpt.contains("Wife · age 33 · born Co Cork · Seamstress"))
        #expect(f.excerpt.contains("4 Synthetic Street, Test DED (part of), Co. Cork"))
        #expect(f.excerpt.contains("household form: https://api-census.nationalarchives.ie/census/image/naiTEST0001.pdf"))
        #expect(f.url.hasPrefix(IrishCensusSource.resultsPage + "?census_year=1911&surname=Fenlane&firstname=Honora&county=Cork"))
        #expect(f.url.hasSuffix("#nai-900001"))
        #expect(f.retrievedAt == fetched)
        // Without a birth year every row with an id is kept.
        #expect(IrishCensusSource.parse(Data(censusSmallJSON.utf8), retrievedAt: fetched, expectedAge: nil)
            .findings.count == 2)
    }

    @Test func emptyAndGarbageBodiesYieldEmptyPages() {
        let empty = IrishCensusSource.parse(Data(censusEmptyJSON.utf8), retrievedAt: fetched, expectedAge: nil)
        #expect(empty == IrishCensusSource.Page(findings: [], total: 0, nextOffset: nil))
        let garbage = IrishCensusSource.parse(Data("<html>Just a moment…</html>".utf8), retrievedAt: fetched, expectedAge: 30)
        #expect(garbage.findings.isEmpty && garbage.total == 0)
        #expect(IrishCensusSource.offset(fromNext: "?census_year=1911&county=Cork&surname=X&offset=10") == 10)
        #expect(IrishCensusSource.offset(fromNext: "?census_year=1911") == nil)
    }

    @Test func asksEachCensusYearForEachSpellingWithCounty() async throws {
        let recorder = FixtureResearchFetcher.RequestRecorder()
        let source = IrishCensusSource(fetcher: fixture([("api-census.nationalarchives.ie", censusSmallJSON)],
                                                        recorder: recorder), hints: hints())
        let findings = try await source.search(plan: plan)
        #expect(recorder.count == 6, "2 years × 3 spellings, small results need no second page")
        #expect(recorder.urls.allSatisfy { URL(string: $0)?.host == IrishCensusSource.host })
        #expect(recorder.urls.allSatisfy { $0.contains("county=Cork") && $0.contains("firstname=Honora") })
        for spelling in ["Fenlane", "Fenlayne", "Fenlaine"] {
            #expect(recorder.urls.contains { $0.contains("surname=\(spelling)&") })
        }
        #expect(recorder.urls.filter { $0.contains("census_year=1901") }.count == 3)
        // The same household from three spellings' fixtures dedupes to one.
        #expect(findings.count == 1)
    }

    @Test func aCommonSurnameIsNarrowedByAgeAndCappedByTheBudget() async throws {
        let recorder = FixtureResearchFetcher.RequestRecorder()
        let source = IrishCensusSource(
            fetcher: fixture([("age=", censusSmallJSON), ("api-census", censusCommonJSON())], recorder: recorder),
            hints: hints())
        let findings = try await source.search(plan: plan)
        #expect(recorder.count == IrishCensusSource.maxRequests, "never more than \(IrishCensusSource.maxRequests)")
        #expect(recorder.urls.contains { $0.contains("age=33") }, "1911 − 1878")
        #expect(recorder.urls.contains { $0.contains("age=23") }, "1901 − 1878")
        #expect(!recorder.urls.contains { $0.contains("offset=") },
                "1,244 hits are narrowed by age, not paged through")
        #expect(findings.count <= IrishCensusSource.maxFindings)
        // Age window ±3 around 23/33 on the common page: ages 20, 25, 30, 35.
        #expect(findings.allSatisfy { $0.title.hasPrefix("Census 1911") })
    }

    @Test func smallResultsWithANextPageAreFollowedWithLeftoverBudget() async throws {
        let recorder = FixtureResearchFetcher.RequestRecorder()
        // No birth year → no age narrowing → the next page is read.
        let source = IrishCensusSource(
            fetcher: fixture([("offset=10", censusEmptyJSON), ("api-census", censusCommonJSON())], recorder: recorder),
            hints: hints(surnames: ["Fenlane"], born: nil, died: nil))
        _ = try await source.search(plan: plan)
        #expect(recorder.urls.filter { $0.contains("offset=10") }.count == 2, "one follow-up per census year")
        #expect(recorder.count == 4)
    }

    @Test func notIrishOrNotAliveForACensusMakesNoRequest() async throws {
        let recorder = FixtureResearchFetcher.RequestRecorder()
        let f = fixture([("api-census", censusSmallJSON)], recorder: recorder)
        #expect(try await IrishCensusSource(fetcher: f, hints: hints(irish: false)).search(plan: plan).isEmpty)
        #expect(try await IrishCensusSource(fetcher: f, hints: hints(born: 1820, died: 1890)).search(plan: plan).isEmpty)
        #expect(try await IrishCensusSource(fetcher: f, hints: hints(surnames: [])).search(plan: plan).isEmpty)
        #expect(recorder.urls.isEmpty)
        #expect(IrishCensusSource.plausibleYears(birth: 1905, death: nil) == [1911])
        #expect(IrishCensusSource.plausibleYears(birth: nil, death: 1905) == [1901])
    }

    @Test func oneFailedRequestDoesNotLoseTheOthersButAllFailedThrows() async throws {
        let partial = IrishCensusSource(fetcher: fixture([("surname=Fenlane&", censusSmallJSON)]), hints: hints())
        let kept = try await partial.search(plan: plan)
        #expect(kept.count == 1, "the Fenlane queries answered; the variant 404s are tolerated")

        let dead = IrishCensusSource(fetcher: fixture([]), hints: hints())
        await #expect(throws: ResearchFetchError.self) { _ = try await dead.search(plan: plan) }
    }

    @Test func tenThousandRowResponseParsesUnderBudget() {
        let rows = (0..<10_000).map { i in
            #"{"id": \#(i + 1), "census_year": 1901, "county": "Cork", "surname": "Fenlane", "firstname": "N\#(i)", "townland": "T\#(i % 50)", "ded": "D", "age": \#(i % 90), "images": [{"url": "/census/image/x\#(i).pdf"}]}"#
        }.joined(separator: ",")
        let body = Data(#"{"results":[\#(rows)],"meta":{"count":10000,"next":null,"prev":null}}"#.utf8)
        let start = Date()
        let page = IrishCensusSource.parse(body, retrievedAt: fetched, expectedAge: 40)
        let elapsed = Date().timeIntervalSince(start)
        // Ages 37…43 of each 90: 111 full cycles × 7.
        #expect(page.findings.count == 777)
        #expect(elapsed < 10, "10k rows took \(elapsed) s")
    }

    @Test func hintsComeFromTheTreeRecord() throws {
        let soldier = ResearchRecordHints(subject: try subject("@I1@"))
        #expect(soldier.givenName == "Cornelius")
        #expect(soldier.surnames.first == "Fenlane")
        #expect(soldier.surnames.contains("Fenlayne"), "clerk spellings are generated: \(soldier.surnames)")
        #expect(soldier.isIrish)
        #expect(soldier.irishCensusCounty == "Cork")
        #expect(soldier.servedInMilitary)
        let drafted = ResearchRecordHints(subject: try subject("@I2@"))
        #expect(!drafted.servedInMilitary, "a US draft registration is not service")
        #expect(!drafted.isIrish)
    }

    /// QA P3-11: a record with only a given name has no surname to search —
    /// "Bridget" must never be sent to the census as a family name.
    @Test func aGivenNameIsNeverUsedAsTheSurname() async throws {
        let given = ResearchRecordHints(subject: try subject("@I3@"))
        #expect(given.surnames.isEmpty, "\(given.surnames)")
        let recorder = FixtureResearchFetcher.RequestRecorder()
        let f = fixture([("api-census", censusSmallJSON)], recorder: recorder)
        _ = try await IrishCensusSource(fetcher: f, hints: given).search(plan: plan)
        #expect(recorder.urls.isEmpty)
    }
}

// MARK: - TNA Discovery

@Suite("Record Finder — TNA Discovery adapter (fixtures only)")
struct TNADiscoveryAdapterTests {

    @Test func onlySoldiersAndPre1858EnglishDeathsAreAsked() {
        #expect(TNADiscoverySource.plannedQueries(hints()).isEmpty)
        let soldier = TNADiscoverySource.plannedQueries(hints(soldier: true))
        #expect(soldier.count == 3, "primary + two other spellings, capped at 3")
        #expect(soldier.allSatisfy { $0.series == TNADiscoverySource.militarySeries })
        #expect(soldier.first?.dateFrom == 1892 && soldier.first?.dateTo == 1935)
        let will = TNADiscoverySource.plannedQueries(hints(died: 1840, soldier: false, ewDeathBefore1858: true))
        #expect(will == [.init(surname: "Fenlane", series: ["PROB 11"], dateFrom: 1840, dateTo: 1843)])
        let both = TNADiscoverySource.plannedQueries(hints(died: 1850, soldier: true, ewDeathBefore1858: true))
        #expect(both.count == TNADiscoverySource.maxRequests)
        #expect(both[1].series == ["PROB 11"], "wills outrank a third spelling")
    }

    @Test func searchSendsAllServiceSeriesInOneRequestAndKeepsOnlyReferences() async throws {
        let recorder = FixtureResearchFetcher.RequestRecorder()
        let source = TNADiscoverySource(fetcher: fixture([("discovery.nationalarchives.gov.uk", discoveryJSON)],
                                                         recorder: recorder),
                                        hints: hints(surnames: ["Fenlane"], soldier: true))
        let findings = try await source.search(plan: plan)
        #expect(recorder.count == 1)
        let url = try #require(recorder.urls.first)
        #expect(url.hasPrefix(TNADiscoverySource.apiBase + "?sps.searchQuery=Fenlane%20Honora"))
        for series in ["WO%2097", "WO%20363", "WO%20364", "AIR%2079", "ADM%20188", "ADM%20139", "ADM%20196"] {
            #expect(url.contains("sps.recordSeries=\(series)"), "\(series)")
        }
        #expect(url.contains("sps.dateFrom=1892-01-01") && url.contains("sps.dateTo=1935-12-31"))
        try #require(findings.count == 2, "empty and unsafe ids are skipped")
        #expect(findings[0].title == "WO 97/9999 — Fenlane Cornelius - Fenlane John")
        #expect(findings[0].url == "https://discovery.nationalarchives.gov.uk/details/r/C900001")
        #expect(findings[0].date == "1900-1913")
        #expect(findings.allSatisfy { !$0.title.contains("CONTEXT-MARKER") && !$0.excerpt.contains("CONTEXT-MARKER") },
                "only reference, title, dates and id are kept")
    }

    @Test func discoveryResponsesNeverReachTheDiskCacheButCensusPagesDo() async throws {
        let root = try tempPeopleRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = ResearchStore(peopleRoot: root)
        let inner = fixture([("discovery.nationalarchives.gov.uk", discoveryJSON), ("api-census", censusSmallJSON)])
        let caching = CachingResearchFetcher(inner: inner, store: store, subjectKey: "TEST-001", bypassCache: false)
        _ = try await TNADiscoverySource(fetcher: caching, hints: hints(soldier: true)).search(plan: plan)
        let cacheDir = try store.cacheDirectory(key: "TEST-001")
        let afterDiscovery = (try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path)) ?? []
        #expect(afterDiscovery.isEmpty, "TNA: \"do not cache\"")
        _ = try await IrishCensusSource(fetcher: caching, hints: hints(surnames: ["Fenlane"])).search(plan: plan)
        let afterCensus = (try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path)) ?? []
        #expect(afterCensus.count == 2, "two census years cached per person")
    }
}

// MARK: - Isolation and sensors

@Suite("Record Finder — isolation and sensors")
struct RecordFinderIsolationTests {

    @Test func poisonedCacheFilesAreSurvived() async throws {
        let root = try tempPeopleRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = ResearchStore(peopleRoot: root)
        let query = IrishCensusSource.Query(year: 1911, surname: "Fenlane", age: nil, offset: 0)
        let url = try #require(IrishCensusSource.queryURL(query, givenName: "Honora", county: "Cork"))
        // 1. A cache file that is not even JSON → ignored, the page is re-fetched.
        let path = try store.cacheURL(key: "TEST-001", pageURL: url.absoluteString)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: path)
        let recorder = FixtureResearchFetcher.RequestRecorder()
        let caching = CachingResearchFetcher(inner: fixture([("api-census", censusSmallJSON)], recorder: recorder),
                                             store: store, subjectKey: "TEST-001", bypassCache: false)
        let first = try await caching.fetch(url)
        #expect(!first.fromCache && recorder.count == 1)
        // 2. A well-formed cache entry whose BODY is garbage → parsed as an
        //    empty page, never a crash or a throw.
        try store.cache(.init(url: url.absoluteString, retrievedAt: fetched, statusCode: 200,
                              body: Data([0xFF, 0x00, 0x7B])), key: "TEST-001")
        let poisoned = try await caching.fetch(url)
        #expect(poisoned.fromCache)
        #expect(IrishCensusSource.parse(poisoned.body, retrievedAt: fetched, expectedAge: 33).findings.isEmpty)
    }

    @Test func aMissingPeopleRootReadsAsNothingSaved() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordFinderMissing-\(UUID().uuidString)/People", isDirectory: true)
        let store = ResearchStore(peopleRoot: missing)
        #expect(try store.loadDossier(key: "TEST-001") == nil)
        #expect(store.cachedPage(key: "TEST-001", pageURL: "https://example.invalid/") == nil)
        #expect(store.keysWithDossiers().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: missing.path), "reading never creates the folder")
    }

    /// Rick, 2026-10-01: Find a Grave is a link now. Its robots.txt has
    /// disallowed /memorial/search since 2024-11-25.
    @Test func noAutomatedSourceRequestsFindAGrave() async throws {
        let recorder = FixtureResearchFetcher.RequestRecorder()
        // A catch-all fixture: every source gets a 200 for every URL.
        let anything = FixtureResearchFetcher(fixtures: [.init(urlContains: "", body: Data("{}".utf8), statusCode: 200)],
                                              retrievedAt: fetched, recorder: recorder)
        let soldier = try subject("@I1@")
        let sources = ResearchRunner.sources(fetcher: anything, subject: soldier)
        _ = await ResearchRunner.run(plan: ResearchQueryPlan.build(subject: soldier, now: now), sources: sources)
        #expect(!recorder.urls.isEmpty)
        #expect(!recorder.urls.contains { $0.lowercased().contains("findagrave") })
        #expect(!sources.contains { $0.kind == .findAGrave })
        // Every request goes to a host this feature is allowed to ask.
        let allowed: Set<String> = ["chroniclingamerica.loc.gov", "en.wikipedia.org", "www.wikidata.org",
                                    "html.duckduckgo.com", IrishCensusSource.host, TNADiscoverySource.host]
        let hosts = Set(recorder.urls.compactMap { URL(string: $0)?.host })
        #expect(hosts.isSubset(of: allowed), "unexpected hosts: \(hosts.subtracting(allowed))")
        #expect(hosts.contains(IrishCensusSource.host) && hosts.contains(TNADiscoverySource.host))
        // And no adapter source file carries a Find a Grave URL literal.
        for file in ["ResearchSources.swift", "ResearchRecordSources.swift"] {
            let text = try SourceTree.appSource(named: file)
            #expect(!text.contains("\"https://www.findagrave.com"), "\(file)")
        }
        // The browser link is there instead.
        #expect(RecordFinder.burials.contains { $0.id == "world.findagrave" && $0.searchURL != nil })
    }

    @Test func filedRecordsSurviveARerunsMerge() throws {
        var dossier = ResearchDossier(subject: try subject("@I1@"))
        let filed = ResearchFinding(source: .recordFinder, title: "Civil birth 1880 — irishgenealogy.ie", date: "1880",
                                    excerpt: "Not yet transcribed.", url: "https://example.invalid/record/1",
                                    retrievedAt: fetched, documentPath: "People/X/Documents/BC-1.pdf",
                                    idSeed: "sha256:abc")
        let added = dossier.addFiled(filed)
        let addedAgain = dossier.addFiled(filed)
        #expect(added)
        #expect(!addedAgain, "the same record is never added twice")
        // A run returns nothing: an unreviewed SEARCH finding would be
        // dropped, a filed record is not.
        dossier.merge(fresh: [], at: now)
        #expect(dossier.findings.map(\.id) == [filed.id])
        #expect(dossier.findings.first?.documentPath == "People/X/Documents/BC-1.pdf")
    }

    @Test func dossiersSavedBeforeTodayStillDecode() throws {
        let old = """
        {"schemaVersion":1,"subject":{"key":"TEST-001","isFamilySearchKey":true,"gedcomPersonID":"@I1@",
         "name":"Cornelius Fenlane","alternateNames":[],"surname":"Fenlane","alternateSurnames":[],"sex":"M",
         "birthDate":"1880","deathDate":"1950","birthPlace":"Bandon, Co. Cork, Ireland","deathPlace":null},
         "sourceStatus":{},"findings":[{"id":"chroniclingAmerica.0123456789abcdef","source":"chroniclingAmerica",
         "title":"T","date":null,"excerpt":"E","url":"https://example.invalid/p","retrievedAt":"2026-08-29T14:00:00Z",
         "verdict":"confirmed","lore":"","toldItemID":null},
         {"id":"findAGrave.0123456789abcdef","source":"findAGrave","title":"Memorial","date":"1880–1950",
          "excerpt":"E","url":"https://example.invalid/memorial/1","retrievedAt":"2026-08-29T14:00:00Z",
          "verdict":"plausible","lore":"","toldItemID":null}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dossier = try decoder.decode(ResearchDossier.self, from: Data(old.utf8))
        #expect(dossier.subject.servedInMilitary == nil)
        #expect(dossier.findings.first?.documentPath == nil)
        // A Find a Grave finding saved before the demotion still loads.
        #expect(dossier.findings.map(\.source) == [.chroniclingAmerica, .findAGrave])
    }

    /// QA P3-8: three requests to one host at once must still be spaced by
    /// the pause — the actor used to let concurrent callers sleep the same
    /// remainder and fire together.
    @Test func concurrentCallersToOneHostAreSpacedApart() async {
        let pacing = ResearchHostPacing(pause: 0.2)
        let times = await withTaskGroup(of: Date.self) { group -> [Date] in
            for _ in 0..<3 {
                group.addTask {
                    await pacing.waitTurn(host: "example.invalid")
                    return Date()
                }
            }
            var out: [Date] = []
            for await t in group { out.append(t) }
            return out.sorted()
        }
        #expect(times.count == 3)
        for i in 1..<times.count {
            let gap = times[i].timeIntervalSince(times[i - 1])
            #expect(gap >= 0.18, "requests \(i - 1) and \(i) were \(gap) s apart")
        }
    }

    /// QA P3-9: the JSON APIs are asked for JSON; other hosts are untouched.
    @Test func jsonAPIRequestsCarryAnAcceptHeader() throws {
        let discovery = try #require(TNADiscoverySource.queryURL(
            .init(surname: "Fenlane", series: ["WO 97"], dateFrom: nil, dateTo: nil), givenName: "Honora"))
        #expect(URLSessionResearchFetcher.request(for: discovery).value(forHTTPHeaderField: "Accept") == "application/json")
        let census = try #require(IrishCensusSource.queryURL(.init(year: 1911, surname: "Fenlane", age: nil, offset: 0),
                                                             givenName: nil, county: nil))
        #expect(URLSessionResearchFetcher.request(for: census).value(forHTTPHeaderField: "Accept") == "application/json")
        let other = try #require(URL(string: "https://chroniclingamerica.loc.gov/search/pages/results/?format=json"))
        #expect(URLSessionResearchFetcher.request(for: other).value(forHTTPHeaderField: "Accept") == nil)
    }

    @Test func attestationLocatorFollowsTheKind() throws {
        let s = try subject("@I1@")
        var filed = ResearchFinding(source: .recordFinder, title: "t", date: nil, excerpt: "What it says.",
                                    url: "https://example.invalid/r", retrievedAt: fetched,
                                    verdict: .confirmed, documentPath: "People/F/Documents/BC-1.pdf",
                                    fullText: "What it says.")
        #expect(ResearchAttestation.locator(for: filed, subject: s) == "People/F/Documents/BC-1.pdf")
        filed.verdict = .confirmed
        let testimony = try ResearchAttestation.testimony(for: filed, subject: s, speakerName: "Tester", date: now)
        #expect(testimony.citation?.sourceKind == .officialRecord)
        let census = ResearchFinding(source: .irishCensus, title: "c", date: "1911", excerpt: "e",
                                     url: "https://example.invalid/c", retrievedAt: fetched, verdict: .confirmed)
        #expect(ResearchAttestation.locator(for: census, subject: s) == nil)
        let discovery = ResearchFinding(source: .tnaDiscovery, title: "d", date: nil, excerpt: "e",
                                        url: "https://example.invalid/d", retrievedAt: fetched, verdict: .confirmed)
        #expect(ResearchAttestation.locator(for: discovery, subject: s) == nil)
        #expect(ResearchAttestation.kind(for: census) == .event)
    }
}
