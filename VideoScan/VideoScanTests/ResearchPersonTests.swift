import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// Research Person, Phase 1 (docs/research_person_design.md, 2026-08-29).
// Dimensions per the feature-test checklist:
//   Logic     — query-plan builder (name variants incl. alternate/maiden
//               names, ± tolerance year window, place tokens, state hint);
//               each source adapter against a recorded-shape fixture;
//               attestation shape; privacy guard
//   Round-trip — dossier + page cache through a temp People root; verdicts
//               and lore survive a re-run merge and a reload
//   Isolation — two stores on two roots never see each other; the fixture
//               fetcher records that NO network URL is hit outside fixtures
//   Scale     — a 100k-key store lookup is a path build, not a scan; a
//               500-finding merge completes within budget
// No live network anywhere in this file.

// MARK: - Fixtures

private let treeGedcom = """
0 HEAD
1 SOUR VideoScanTests
0 @I1@ INDI
1 NAME David McGill /Latta/ Sr
2 TYPE birth
1 NAME David M. /Latta/
1 SEX M
1 BIRT
2 DATE 12 MAR 1847
2 PLAC Pittsfield, Berkshire, Massachusetts, United States
1 DEAT
2 DATE 3 JAN 1921
2 PLAC Dalton, Berkshire, Massachusetts, United States
1 _FSFTID KWCJ-7B2
1 FAMS @F1@
0 @I2@ INDI
1 NAME Eileen /Latta/
1 NAME Eileen /Breen/
1 SEX F
1 BIRT
2 DATE 1930
1 FAMS @F1@
0 @I3@ INDI
1 NAME Richard Hardin /Breen/ Jr
1 SEX M
1 BIRT
2 DATE 1959
1 FAMC @F1@
0 @I4@ INDI
1 NAME Nathaniel /Lamson/
1 SEX M
0 @I5@ INDI
1 NAME Martha /Lamson/
1 SEX F
1 BIRT
2 DATE 1802
0 @F1@ FAM
1 HUSB @I1@
1 WIFE @I2@
1 CHIL @I3@
0 TRLR
"""

private func graph() -> GedcomFamilyGraph { GedcomFamilyGraph(gedcomText: treeGedcom) }
private let now = ISO8601DateFormatter().date(from: "2026-08-29T15:00:00Z")!
private let fetched = ISO8601DateFormatter().date(from: "2026-08-29T14:00:00Z")!

private func david() -> ResearchSubject {
    guard case .eligible(let subject) = ResearchEligibility.evaluate(graph().people["@I1@"], now: now) else {
        Issue.record("David should be eligible"); fatalError()
    }
    return subject
}

private func tempPeopleRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ResearchPerson-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("People", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Shape of https://chroniclingamerica.loc.gov/search/pages/results/?…&format=json
/// (documented API; field names as the service returns them).
private let chroniclingAmericaJSON = """
{"totalItems": 2, "endIndex": 2, "startIndex": 1, "itemsPerPage": 20,
 "items": [
  {"sequence": 3, "county": ["Berkshire"], "edition": null, "frequency": "Weekly",
   "id": "/lccn/sn84020551/1875-05-12/ed-1/seq-3/", "subject": [], "city": ["Pittsfield"],
   "date": "18750512", "title": "Berkshire County Eagle.", "end_year": 1892,
   "state": ["Massachusetts"], "type": "page", "place_of_publication": "Pittsfield, Mass.",
   "start_year": 1858, "lccn": "sn84020551", "country": "Massachusetts",
   "ocr_eng": "LOCAL NEWS. The mill on the north branch was sold Tuesday to David M. Latta of this town, who intends to run it as a paper mill. Mr. Latta has been in the business twenty years.",
   "url": "https://chroniclingamerica.loc.gov/lccn/sn84020551/1875-05-12/ed-1/seq-3.json"},
  {"sequence": 1, "id": "/lccn/sn84020551/1921-01-06/ed-1/seq-1/", "date": "19210106",
   "title": "Berkshire County Eagle.", "place_of_publication": "Pittsfield, Mass.",
   "ocr_eng": "DALTON. David McGill Latta, Sr., one of the oldest residents, died Monday at his home aged 73 years."},
  {"sequence": 9, "date": "19000101", "title": "No id item is skipped"}
 ]}
"""

/// Documented shape of a Find a Grave memorial-search result card.
private let findAGraveHTML = """
<html><body>
<div class="memorial-list">
 <div class="memorial-item">
  <a href="/memorial/123456789/david-mcgill-latta" class="memorial-item--title">
   <h2 class="name-grave pt-2"> <i>David McGill</i> Latta Sr</h2>
  </a>
  <b class="birthDeathDates">12 Mar 1847 – 3 Jan 1921</b>
  <p class="addr-cemet">Pine Grove Cemetery</p>
  <p class="addr-cemet-loc">Dalton, Berkshire County, Massachusetts, USA</p>
 </div>
 <div class="memorial-item">
  <a href="/memorial/987654321/david-latta?something=1">
   <h2 class="name-grave"> David Latta</h2>
  </a>
  <span>1901–1960</span>
 </div>
 <a href="/memorial/123456789/david-mcgill-latta#photos">photos (duplicate link)</a>
</div>
</body></html>
"""

private let wikipediaJSON = """
{"batchcomplete":"","query":{"searchinfo":{"totalhits":2},"search":[
 {"ns":0,"title":"Latta, Pennsylvania","pageid":1,"snippet":"<span class=\\"searchmatch\\">Latta</span> is a borough named for David Latta"},
 {"ns":0,"title":"David (name)","pageid":2,"snippet":"David is a common given name"}
]}}
"""

private let wikidataJSON = """
{"searchinfo":{"search":"David Latta"},"search":[
 {"id":"Q1234","title":"Q1234","concepturi":"http://www.wikidata.org/entity/Q1234","label":"David Latta","description":"American paper manufacturer (1847–1921)"},
 {"id":"Q999","label":"David","description":"given name"}
],"success":1}
"""

private let duckDuckGoHTML = """
<div class="results">
 <div class="result results_links">
  <h2 class="result__title"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fberkshirehistory.org%2Flatta&amp;rut=abc">Latta family of Dalton</a></h2>
  <a class="result__snippet" href="...">The <b>Latta</b> paper mill on the north branch, 1875</a>
 </div>
 <div class="result">
  <h2><a class="result__a" href="https://example.org/latta">Example</a></h2>
 </div>
</div>
"""

private func fetcher(recorder: FixtureResearchFetcher.RequestRecorder? = nil) -> FixtureResearchFetcher {
    FixtureResearchFetcher(fixtures: [
        .init(urlContains: "chroniclingamerica.loc.gov", body: Data(chroniclingAmericaJSON.utf8), statusCode: 200),
        .init(urlContains: "findagrave.com", body: Data(findAGraveHTML.utf8), statusCode: 200),
        .init(urlContains: "en.wikipedia.org", body: Data(wikipediaJSON.utf8), statusCode: 200),
        .init(urlContains: "wikidata.org", body: Data(wikidataJSON.utf8), statusCode: 200),
        .init(urlContains: "duckduckgo.com", body: Data(duckDuckGoHTML.utf8), statusCode: 200),
    ], retrievedAt: fetched, recorder: recorder)
}

// MARK: - Privacy guard

@Suite("Research Person — privacy guard")
struct ResearchPrivacyGuardTests {

    @Test func deceasedTreePersonIsEligibleAndKeyedByFamilySearchID() {
        let outcome = ResearchEligibility.evaluate(graph().people["@I1@"], now: now)
        guard case .eligible(let subject) = outcome else { Issue.record("refused"); return }
        #expect(subject.key == "KWCJ-7B2")
        #expect(subject.isFamilySearchKey)
        #expect(subject.gedcomPersonID == "@I1@")
        #expect(subject.vitals == "1847–1921")
    }

    @Test func livingTreePersonIsRefused() {
        // Born 1959, no death date → presumed living.
        guard case .refused(let reason) = ResearchEligibility.evaluate(graph().people["@I3@"], now: now) else {
            Issue.record("should refuse"); return
        }
        #expect(reason.contains("presumed living"))
    }

    @Test func noDatesIsRefusedWithAnActionableReason() {
        guard case .refused(let reason) = ResearchEligibility.evaluate(graph().people["@I4@"], now: now) else {
            Issue.record("should refuse"); return
        }
        #expect(reason.contains("Add a date"))
    }

    @Test func oldBirthWithoutDeathIsEligibleWithFallbackKey() {
        guard case .eligible(let subject) = ResearchEligibility.evaluate(graph().people["@I5@"], now: now) else {
            Issue.record("should be eligible"); return
        }
        #expect(!subject.isFamilySearchKey)
        #expect(subject.key.hasPrefix("U-"))
        #expect(ResearchSubject.isSafeKey(subject.key))
        // Deterministic across re-pulls: same name + dates → same key.
        #expect(subject.key == ResearchSubject.fallbackKey(name: "Martha Lamson", birthDate: "1802", deathDate: nil))
    }

    @Test func peopleTabContemporaryIsAlwaysRefused() {
        #expect(ResearchEligibility.evaluate(nil, now: now)
                == .refused(reason: "Only people with a family-tree record can be researched."))
        guard case .refused(let reason) = ResearchEligibility.refusedForProfile(named: "Timmy") else {
            Issue.record("should refuse"); return
        }
        #expect(reason.contains("never researched online"))
    }

    @Test func unsafeKeysNeverReachTheFilesystem() throws {
        let store = ResearchStore(peopleRoot: try tempPeopleRoot())
        #expect(throws: ResearchStore.StoreError.unsafeKey("../etc")) { try store.dossierURL(key: "../etc") }
        #expect(throws: ResearchStore.StoreError.unsafeKey("")) { try store.dossierURL(key: "") }
        #expect(throws: ResearchStore.StoreError.unsafeKey("a/b")) { try store.dossierURL(key: "a/b") }
    }
}

// MARK: - Query plan

@Suite("Research Person — query plan")
struct ResearchQueryPlanTests {

    @Test func nameVariantsIncludeSuffixlessAlternateAndGivenSurname() {
        let plan = ResearchQueryPlan.build(subject: david(), now: now)
        #expect(plan.nameVariants.first == "David McGill Latta Sr")
        #expect(plan.nameVariants.contains("David McGill Latta"))
        #expect(plan.nameVariants.contains("David Latta"))
        #expect(plan.nameVariants.contains("David M. Latta"))
        // Deduplicated, case-insensitively.
        #expect(Set(plan.nameVariants.map { $0.lowercased() }).count == plan.nameVariants.count)
    }

    @Test func maidenAndMarriedSurnamesBothBecomeVariants() {
        // Eileen is living (born 1930) — build the subject directly to test
        // the name logic; the guard is covered above.
        let subject = ResearchSubject(person: graph().people["@I2@"]!)
        let variants = ResearchQueryPlan.nameVariants(for: subject)
        #expect(variants.contains("Eileen Latta"))
        #expect(variants.contains("Eileen Breen"))
    }

    @Test func yearWindowIsBirthToDeathPlusTolerance() {
        let plan = ResearchQueryPlan.build(subject: david(), tolerance: 5, now: now)
        #expect(plan.yearFrom == 1842)
        #expect(plan.yearTo == 1926)
        let tight = ResearchQueryPlan.build(subject: david(), tolerance: 0, now: now)
        #expect((tight.yearFrom, tight.yearTo) == (1847, 1921))
    }

    @Test func birthOnlyWindowAssumesALifespanAndNeverPassesToday() {
        let martha = ResearchSubject(person: graph().people["@I5@"]!)
        let plan = ResearchQueryPlan.build(subject: martha, now: now)
        #expect(plan.yearFrom == 1797)
        #expect(plan.yearTo == 1897)
        let unknown = ResearchSubject(person: graph().people["@I4@"]!)
        let open = ResearchQueryPlan.build(subject: unknown, now: now)
        #expect(open.yearFrom == 1700 && open.yearTo == 2026)
    }

    @Test func placeTokensAndStateHint() {
        let plan = ResearchQueryPlan.build(subject: david(), now: now)
        #expect(plan.placeTokens == ["Pittsfield", "Berkshire", "Massachusetts", "United States", "Dalton"])
        #expect(plan.stateHint == "Massachusetts")
        #expect(plan.countsSummary == "\(plan.nameVariants.count) names · 1842–1926 · 5 places")
    }
}

// MARK: - Adapters

@Suite("Research Person — source adapters (fixtures only)")
struct ResearchSourceAdapterTests {

    @Test func chroniclingAmericaParsesItemsAndConstrainsTheQuery() async throws {
        let recorder = FixtureResearchFetcher.RequestRecorder()
        let source = ChroniclingAmericaSource(fetcher: fetcher(recorder: recorder))
        let plan = ResearchQueryPlan.build(subject: david(), now: now)
        let findings = try await source.search(plan: plan)
        // Three name variants → three requests; the two real items dedupe
        // across them; the id-less item is skipped.
        #expect(recorder.count == ChroniclingAmericaSource.maxVariants)
        #expect(findings.count == 2)
        let first = try #require(findings.first)
        #expect(first.source == .chroniclingAmerica)
        #expect(first.title == "Berkshire County Eagle. (Pittsfield, Mass.)")
        #expect(first.date == "1875-05-12")
        #expect(first.url == "https://chroniclingamerica.loc.gov/lccn/sn84020551/1875-05-12/ed-1/seq-3/")
        #expect(first.excerpt.contains("David M. Latta"))
        #expect(first.retrievedAt == fetched)
        #expect(first.verdict == .unreviewed)
        // Query shape: name, year window clipped to coverage, state.
        let url = try #require(recorder.urls.first)
        #expect(url.contains("andtext=David%20McGill%20Latta%20Sr"))
        #expect(url.contains("date1=1842&date2=1926"))
        #expect(url.contains("state=Massachusetts"))
        #expect(url.contains("format=json"))
    }

    @Test func chroniclingAmericaClipsToCoverageAndSkipsOutOfRange() async throws {
        let recorder = FixtureResearchFetcher.RequestRecorder()
        let source = ChroniclingAmericaSource(fetcher: fetcher(recorder: recorder))
        let modern = ResearchQueryPlan(nameVariants: ["Someone Recent"], yearFrom: 1970, yearTo: 2000,
                                       placeTokens: [], stateHint: nil)
        #expect(try await source.search(plan: modern).isEmpty)
        #expect(recorder.count == 0)
        let straddling = ResearchQueryPlan(nameVariants: ["X Y"], yearFrom: 1700, yearTo: 2000,
                                           placeTokens: [], stateHint: nil)
        _ = try await source.search(plan: straddling)
        #expect(recorder.urls.last?.contains("date1=1770&date2=1963") == true)
    }

    @Test func findAGraveTolerantParserYieldsMemorialsOnce() async throws {
        let recorder = FixtureResearchFetcher.RequestRecorder()
        let source = FindAGraveSource(fetcher: fetcher(recorder: recorder))
        let findings = try await source.search(plan: ResearchQueryPlan.build(subject: david(), now: now))
        #expect(findings.count == 2)
        let memorial = try #require(findings.first)
        #expect(memorial.title == "David McGill Latta Sr")
        #expect(memorial.url == "https://www.findagrave.com/memorial/123456789/david-mcgill-latta")
        #expect(memorial.date == "1847 – 1921")
        #expect(memorial.excerpt.contains("Pine Grove Cemetery"))
        let second = findings[1]
        #expect(second.url == "https://www.findagrave.com/memorial/987654321/david-latta")
        #expect(second.date == "1901–1960")
        let url = try #require(recorder.urls.first)
        #expect(url.contains("firstname=David&lastname=Latta"))
        #expect(url.contains("birthyear=1847"))
        #expect(url.contains("location=Massachusetts"))
    }

    @Test func findAGraveParserSurvivesGarbage() {
        #expect(FindAGraveSource.parse("<html><body>Checking your browser…</body></html>", retrievedAt: fetched).isEmpty)
        #expect(FindAGraveSource.parse("", retrievedAt: fetched).isEmpty)
        // A bare anchor with no card still yields a finding named from the slug.
        let bare = FindAGraveSource.parse(#"<a href="/memorial/42/jane-doe">x</a>"#, retrievedAt: fetched)
        #expect(bare.map(\.title) == ["Jane Doe"])
    }

    @Test func wikipediaAndWikidataKeepOnlySurnameHits() async throws {
        let source = WikipediaSource(fetcher: fetcher())
        let findings = try await source.search(plan: ResearchQueryPlan.build(subject: david(), now: now))
        #expect(findings.map(\.source) == [.wikipedia, .wikidata])
        #expect(findings[0].title == "Latta, Pennsylvania")
        #expect(findings[0].url == "https://en.wikipedia.org/wiki/Latta,_Pennsylvania")
        #expect(findings[0].excerpt == "Latta is a borough named for David Latta")
        #expect(findings[1].title == "David Latta")
        #expect(findings[1].url == "http://www.wikidata.org/entity/Q1234")
    }

    @Test func webSearchUnwrapsRedirectsAndSurvivesNoParse() async throws {
        let source = WebSearchSource(fetcher: fetcher())
        let findings = try await source.search(plan: ResearchQueryPlan.build(subject: david(), now: now))
        #expect(findings.count == 2)
        #expect(findings[0].url == "https://berkshirehistory.org/latta")
        #expect(findings[0].title == "Latta family of Dalton")
        #expect(findings[0].excerpt == "The Latta paper mill on the north branch, 1875")
        #expect(findings[1].url == "https://example.org/latta")
        #expect(WebSearchSource.parse("<html>challenge</html>", retrievedAt: fetched).isEmpty)
    }

    @Test func runnerReportsPerSourceCountsAndFailures() async throws {
        let failing = FixtureResearchFetcher(fixtures: [], retrievedAt: fetched)
        let sources: [any ResearchSource] = [
            ChroniclingAmericaSource(fetcher: fetcher()),
            FindAGraveSource(fetcher: failing),
        ]
        final class Lines: @unchecked Sendable { var lines: [String] = []; let lock = NSLock() }
        let lines = Lines()
        let outcomes = await ResearchRunner.run(
            plan: ResearchQueryPlan.build(subject: david(), now: now), sources: sources,
            log: { line in lines.lock.lock(); lines.lines.append(line); lines.lock.unlock() })
        #expect(outcomes.map(\.kind) == [.chroniclingAmerica, .findAGrave])
        #expect(outcomes[0].status == "2 findings")
        #expect(outcomes[1].status == "failed: HTTP 404")
        // Counts only in the log: no name, no excerpt.
        #expect(lines.lines.count == 2)
        #expect(!lines.lines.joined().contains("Latta"))
    }
}

// MARK: - Store: round-trip, cache, isolation, verdicts

@Suite("Research Person — store round-trip and isolation")
struct ResearchStoreTests {

    @Test func dossierRoundTripsAndVerdictsSurviveARerun() throws {
        let root = try tempPeopleRoot()
        let store = ResearchStore(peopleRoot: root)
        var dossier = ResearchDossier(subject: david())
        let plan = ResearchQueryPlan.build(subject: david(), now: now)
        dossier.plan = plan
        let first = ChroniclingAmericaSource.parse(Data(chroniclingAmericaJSON.utf8), retrievedAt: fetched,
                                                   needles: plan.nameVariants)
        dossier.merge(fresh: first, at: now)
        dossier.setVerdict(.confirmed, for: first[0].id)
        dossier.setLore("This is the paper-mill Latta.", for: first[0].id)
        try store.saveDossier(dossier)

        // Path is People/<FSID>/research/dossier.json.
        let expected = root.appendingPathComponent("KWCJ-7B2/research/dossier.json").standardizedFileURL
        #expect(try store.dossierURL(key: "KWCJ-7B2").standardizedFileURL == expected)
        #expect(FileManager.default.fileExists(atPath: expected.path))

        let reloaded = try #require(try store.loadDossier(key: "KWCJ-7B2"))
        #expect(reloaded == dossier)
        #expect(reloaded.findings[0].verdict == .confirmed)
        #expect(reloaded.findings[0].lore == "This is the paper-mill Latta.")

        // Re-run: same id keeps verdict + lore; a vanished unreviewed finding
        // is dropped; a vanished reviewed one is kept.
        var again = reloaded
        again.setVerdict(.wrong, for: first[1].id)
        let rerun = [ResearchFinding(source: .chroniclingAmerica, title: "New", date: nil, excerpt: "e",
                                     url: first[0].url, retrievedAt: now),
                     ResearchFinding(source: .web, title: "Fresh", date: nil, excerpt: "f",
                                     url: "https://x.example/1", retrievedAt: now)]
        again.merge(fresh: rerun, at: now)
        #expect(again.findings.map(\.verdict) == [.confirmed, .unreviewed, .wrong])
        #expect(again.findings[0].lore == "This is the paper-mill Latta.")
        #expect(again.findings[0].title == "New")
        #expect(again.lastRunAt == now)
        #expect(store.keysWithDossiers() == ["KWCJ-7B2"])
    }

    @Test func pageCacheServesRepeatFetchesWithRetrievedDate() async throws {
        let store = ResearchStore(peopleRoot: try tempPeopleRoot())
        let recorder = FixtureResearchFetcher.RequestRecorder()
        let caching = CachingResearchFetcher(inner: fetcher(recorder: recorder), store: store,
                                             subjectKey: "KWCJ-7B2", bypassCache: false)
        let url = try #require(WikipediaSource.wikipediaURL(query: "David Latta"))
        let live = try await caching.fetch(url)
        #expect(!live.fromCache)
        let cached = try await caching.fetch(url)
        #expect(cached.fromCache)
        #expect(cached.retrievedAt == fetched)
        #expect(cached.body == live.body)
        #expect(recorder.count == 1)
        let bypass = CachingResearchFetcher(inner: fetcher(recorder: recorder), store: store,
                                            subjectKey: "KWCJ-7B2", bypassCache: true)
        _ = try await bypass.fetch(url)
        #expect(recorder.count == 2)
        // Cache lives under People/<key>/research/cache/.
        let cacheURL = try store.cacheURL(key: "KWCJ-7B2", pageURL: url.absoluteString)
        #expect(cacheURL.path.contains("/KWCJ-7B2/research/cache/"))
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test func cacheCapsOversizedBodies() throws {
        let store = ResearchStore(peopleRoot: try tempPeopleRoot())
        let big = Data(repeating: 0x41, count: ResearchStore.maxCachedBodyBytes + 10)
        try store.cache(.init(url: "https://x.example/big", retrievedAt: fetched, statusCode: 200, body: big), key: "K1")
        #expect(store.cachedPage(key: "K1", pageURL: "https://x.example/big")?.body.count == ResearchStore.maxCachedBodyBytes)
    }

    @Test func twoRootsAreIsolated() throws {
        let a = ResearchStore(peopleRoot: try tempPeopleRoot())
        let b = ResearchStore(peopleRoot: try tempPeopleRoot())
        try a.saveDossier(ResearchDossier(subject: david()))
        #expect(try a.loadDossier(key: "KWCJ-7B2") != nil)
        #expect(try b.loadDossier(key: "KWCJ-7B2") == nil)
        #expect(b.keysWithDossiers().isEmpty)
        #expect(b.cachedPage(key: "KWCJ-7B2", pageURL: "https://x.example") == nil)
    }

    @Test func mergeOfFiveHundredFindingsIsFast() {
        var dossier = ResearchDossier(subject: david())
        let fresh = (0..<ResearchDossier.maxFindings + 200).map {
            ResearchFinding(source: .web, title: "t\($0)", date: nil, excerpt: "e", url: "https://x.example/\($0)", retrievedAt: now)
        }
        let start = Date()
        dossier.merge(fresh: fresh, at: now)
        dossier.merge(fresh: fresh.reversed(), at: now)
        #expect(Date().timeIntervalSince(start) < 1.0)
        #expect(dossier.findings.count == ResearchDossier.maxFindings)
    }
}

// MARK: - Attestation shape

@Suite("Research Person — Tell Hallie attestation shape")
struct ResearchAttestationTests {

    private func confirmedFinding() -> ResearchFinding {
        var finding = ResearchFinding(
            source: .chroniclingAmerica, title: "Berkshire County Eagle. (Pittsfield, Mass.)",
            date: "1875-05-12", excerpt: "The mill was sold to David M. Latta.",
            url: "https://chroniclingamerica.loc.gov/lccn/sn84020551/1875-05-12/ed-1/seq-3/",
            retrievedAt: fetched)
        finding.verdict = .confirmed
        finding.lore = "That's the paper mill on the north branch — family lore says he bought it with his brother."
        return finding
    }

    @Test func confirmedFindingBecomesAConfirmedCitedItemLinkedToTheTreeRecord() throws {
        let testimony = try ResearchAttestation.testimony(
            for: confirmedFinding(), subject: david(), speakerName: "Rick", date: now)
        #expect(testimony.origin == .researchFinding)
        #expect(testimony.gedcomPersonID == "@I1@")
        #expect(testimony.subjectAliases == ["David M. Latta"])
        #expect(testimony.kind == .event)
        #expect(testimony.text.hasPrefix("That's the paper mill"))
        let citation = try #require(testimony.citation)
        #expect(citation.title == "Berkshire County Eagle. (Pittsfield, Mass.), 1875-05-12")
        #expect(citation.sourceKind == .officialRecord)

        let receipt = try CyberBrainWriter.appending(testimony, to: nil)
        let person = try #require(receipt.archive.people.first)
        #expect(person.gedcomPersonID == "@I1@")
        let item = try #require(person.lifeEvents.first)
        #expect(item.confidence == .confirmed)
        #expect(item.id.hasPrefix("research."))
        #expect(item.sourceIDs.count == 1)
        let source = try #require(receipt.archive.sources.first)
        #expect(source.id.hasPrefix(CyberBrainWriter.researchSourceIDPrefix))
        #expect(source.type == .officialRecord)
        #expect(source.attribution == "confirmed by Rick")
        #expect(source.locator == "https://chroniclingamerica.loc.gov/lccn/sn84020551/1875-05-12/ed-1/seq-3/")
        #expect(source.sourceDate?.value == "1875-05-12")
        #expect(source.notes?.contains("retrieved 2026-08-29") == true)
        try CyberBrainValidator.validate(receipt.archive)
    }

    @Test func excerptIsTheTextWhenThereIsNoLore() throws {
        var finding = confirmedFinding()
        finding.lore = "   "
        let testimony = try ResearchAttestation.testimony(for: finding, subject: david(), speakerName: "Rick", date: now)
        #expect(testimony.text == "The mill was sold to David M. Latta.")
    }

    @Test func unconfirmedAndAlreadyToldAreRefused() throws {
        var plausible = confirmedFinding()
        plausible.verdict = .plausible
        #expect(throws: ResearchAttestation.AttestationError.self) {
            try ResearchAttestation.testimony(for: plausible, subject: david(), speakerName: "Rick", date: now)
        }
        var told = confirmedFinding()
        told.toldItemID = "research.x"
        #expect(throws: ResearchAttestation.AttestationError.self) {
            try ResearchAttestation.testimony(for: told, subject: david(), speakerName: "Rick", date: now)
        }
        // The writer itself refuses a research origin without a citation.
        let bare = CyberBrainWriter.Testimony(subjectName: "X Y", speakerName: "Rick", text: "t",
                                              date: now, origin: .researchFinding)
        #expect(throws: CyberBrainWriter.WriteError.self) { try CyberBrainWriter.appending(bare, to: nil) }
    }

    @Test func samePageConfirmedTwiceSharesOneSource() throws {
        let first = try ResearchAttestation.testimony(for: confirmedFinding(), subject: david(), speakerName: "Rick", date: now)
        var second = confirmedFinding()
        second.lore = "Second excerpt from the same page."
        let receipt1 = try CyberBrainWriter.appending(first, to: nil)
        let receipt2 = try CyberBrainWriter.appending(
            try ResearchAttestation.testimony(for: second, subject: david(), speakerName: "Rick", date: now),
            to: receipt1.archive)
        #expect(receipt2.archive.sources.count == 1)
        #expect(receipt2.archive.people.count == 1)
        #expect(receipt2.archive.people[0].lifeEvents.count == 2)
    }

    @Test func durableRecordThroughTheWriterIsReadableByTheIndex() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResearchBrain-\(UUID().uuidString)", isDirectory: true)
        let testimony = try ResearchAttestation.testimony(for: confirmedFinding(), subject: david(), speakerName: "Rick", date: now)
        let receipt = try CyberBrainWriter.record(testimony, rootURL: root)
        let index = try CyberBrainIndex(archive: CyberBrainLoader(rootURL: root).load())
        #expect(index.people(gedcomPersonID: "@I1@").map(\.id) == [receipt.personID])
        #expect(index.source(id: receipt.sourceID)?.locator?.hasPrefix("https://chroniclingamerica") == true)
    }
}
