import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// Wikipedia / Wikidata screening (bug 2026-10-01): Research Person on a
// 19th-century ancestor returned the article on a 1965 film because a
// character in it shares the ancestor's surname, shown like any finding.
//
// Rick's ruling the same day: keep near-misses (serendipity), but rank and
// label them. A likely match needs ALL of:
//   - name on the title/label: surname + given name or initial
//   - Wikidata P31 = Q5 (human)
//   - P569/P570 compatible with the subject's lifespan
// Everything else is kept BELOW the likely matches as a near-miss with a
// plain reason ("a film", "different era — born 1725", "surname only",
// "couldn't be checked", …). A near-miss reaches Hallie only if Rick
// confirms it himself.
//
// Fixture shapes probed live 2026-10-01 (list=search, prop=pageprops with
// wikibase_item + wikibase-shortdesc, wbsearchentities, wbgetentities
// props=claims incl. the "missing" entity). Every surname here is synthetic;
// this is a public repo. No live network anywhere in this file.

private let fetchedAt = Date(timeIntervalSince1970: 1_791_208_800) // 2026-10-01T14:00:00Z

/// The subject: Amos Quillfeather, b. 1875 North Carolina, d. 1943 West
/// Virginia. Plan window with the default ±5 tolerance is 1870–1948.
private let plan = ResearchQueryPlan(nameVariants: ["Amos Quillfeather"], yearFrom: 1870, yearTo: 1948,
                                     placeTokens: ["North Carolina", "West Virginia"],
                                     stateHint: "North Carolina")

// MARK: Wikipedia list=search

private func searchHit(_ title: String, _ pageid: Int, _ snippet: String) -> String {
    #"{"ns":0,"title":"\#(title)","pageid":\#(pageid),"size":1000,"wordcount":100,"snippet":"\#(snippet)","timestamp":"2026-09-14T15:00:38Z"}"#
}

private func searchJSON(_ hits: [String]) -> String {
    #"{"batchcomplete":"","continue":{"sroffset":5,"continue":"-||"},"query":{"searchinfo":{"totalhits":\#(hits.count)},"search":["#
        + hits.joined(separator: ",") + "]}}"
}

/// The film: its title does not name him, its snippet does (the live bug).
private let filmHit = searchHit("The Ninth Lantern", 101,
    #"except for Deputy Sheriff <span class=\"searchmatch\">Amos</span> <span class=\"searchmatch\">Quillfeather</span>, who despite his hostility"#)
/// A film whose TITLE carries the name; only the description / P31 can stop it.
private let namedFilmHit = searchHit("Amos Quillfeather (film)", 106,
    #"<span class=\"searchmatch\">Amos</span> <span class=\"searchmatch\">Quillfeather</span> is a 1931 western"#)
/// A real human whose snippet names the character he played.
private let actorHit = searchHit("Elias Varnholt", 102,
    #"as Deputy Sheriff <span class=\"searchmatch\">Amos</span> <span class=\"searchmatch\">Quillfeather</span> in The Ninth Lantern"#)
/// Same name, a real human, born 150 years too early.
private let colonistHit = searchHit("Amos Quillfeather (colonist)", 103,
    #"<span class=\"searchmatch\">Amos</span> <span class=\"searchmatch\">Quillfeather</span> (1725–1790) was a colonial surveyor"#)
/// The plausible match.
private let matchHit = searchHit("Amos B. Quillfeather", 104,
    #"<span class=\"searchmatch\">Amos</span> B. <span class=\"searchmatch\">Quillfeather</span> (1874–1943) was a West Virginia glassworker"#)
/// A place: surname only.
private let placeHit = searchHit("Quillfeather, West Virginia", 105,
    #"<span class=\"searchmatch\">Quillfeather</span> is an unincorporated community"#)
/// A ship named for him: the name passes, P31 does not.
private let shipHit = searchHit("Amos Quillfeather (ship)", 107,
    #"The <span class=\"searchmatch\">Amos</span> <span class=\"searchmatch\">Quillfeather</span> was a sternwheeler"#)

private let allHits = [filmHit, actorHit, colonistHit, matchHit, placeHit, namedFilmHit, shipHit]

// MARK: Wikipedia prop=pageprops

private func pagePropsJSON(_ pages: [(pageid: Int, title: String, qid: String?, shortdesc: String?)]) -> String {
    let body = pages.map { page -> String in
        var props: [String] = []
        if let shortdesc = page.shortdesc { props.append(#""wikibase-shortdesc":"\#(shortdesc)""#) }
        if let qid = page.qid { props.append(#""wikibase_item":"\#(qid)""#) }
        let pageprops = props.isEmpty ? "" : #","pageprops":{"# + props.joined(separator: ",") + "}"
        return #""\#(page.pageid)":{"pageid":\#(page.pageid),"ns":0,"title":"\#(page.title)"\#(pageprops)}"#
    }.joined(separator: ",")
    return #"{"batchcomplete":"","query":{"pages":{"# + body + "}}}"
}

private let allPageProps = pagePropsJSON([
    (101, "The Ninth Lantern", "Q9101", "1965 film by Harlan Mott"),
    (106, "Amos Quillfeather (film)", "Q9106", "1931 American western film"),
    (102, "Elias Varnholt", "Q9102", "American actor (1926–2006)"),
    (103, "Amos Quillfeather (colonist)", "Q9103", "Colonial surveyor (1725–1790)"),
    (104, "Amos B. Quillfeather", "Q9104", "American glassworker (1874–1943)"),
    (105, "Quillfeather, West Virginia", "Q9105", "Unincorporated community in West Virginia"),
    (107, "Amos Quillfeather (ship)", "Q9107", nil),
])

// MARK: Wikidata wbsearchentities / wbgetentities

private func wbSearchJSON(_ hits: [(id: String, label: String, description: String)]) -> String {
    let body = hits.map {
        #"{"id":"\#($0.id)","title":"\#($0.id)","pageid":1,"concepturi":"http://www.wikidata.org/entity/\#($0.id)","repository":"wikidata","url":"//www.wikidata.org/wiki/\#($0.id)","display":{},"label":"\#($0.label)","description":"\#($0.description)","match":{"type":"label","language":"en","text":"\#($0.label)"}}"#
    }.joined(separator: ",")
    return #"{"searchinfo":{"search":"Amos Quillfeather"},"search":["# + body + #"],"success":1}"#
}

private func timeClaim(_ property: String, _ time: String, precision: Int = 11) -> String {
    #"{"mainsnak":{"snaktype":"value","property":"\#(property)","hash":"h","datavalue":{"value":{"time":"\#(time)","timezone":0,"before":0,"after":0,"precision":\#(precision),"calendarmodel":"http://www.wikidata.org/entity/Q1985727"},"type":"time"},"datatype":"time"},"type":"statement","id":"s","rank":"normal"}"#
}

private func entityJSON(_ id: String, p31: String, born: String? = nil, died: String? = nil) -> String {
    var claims = [#""P31":[{"mainsnak":{"snaktype":"value","property":"P31","hash":"h","datavalue":{"value":{"entity-type":"item","numeric-id":\#(p31.dropFirst()),"id":"\#(p31)"},"type":"wikibase-entityid"},"datatype":"wikibase-item"},"type":"statement","id":"s","rank":"normal"}]"#]
    if let born { claims.append(#""P569":["# + timeClaim("P569", born) + "]") }
    if let died { claims.append(#""P570":["# + timeClaim("P570", died) + "]") }
    return #""\#(id)":{"type":"item","id":"\#(id)","claims":{"# + claims.joined(separator: ",") + "}}"
}

private let allEntities = #"{"entities":{"# + [
    entityJSON("Q9101", p31: "Q11424"),                                    // film
    entityJSON("Q9106", p31: "Q11424"),                                    // film
    entityJSON("Q9102", p31: "Q5", born: "+1926-02-17T00:00:00Z", died: "+2006-11-19T00:00:00Z"),
    entityJSON("Q9103", p31: "Q5", born: "+1725-04-02T00:00:00Z", died: "+1790-01-01T00:00:00Z"),
    entityJSON("Q9104", p31: "Q5", born: "+1874-06-01T00:00:00Z", died: "+1943-08-30T00:00:00Z"),
    entityJSON("Q9105", p31: "Q486972"),                                   // human settlement
    entityJSON("Q9107", p31: "Q11446"),                                    // ship
    entityJSON("Q9199", p31: "Q101352"),                                   // family name
    #""Q9999":{"id":"Q9999","missing":""}"#,
].joined(separator: ",") + #"},"success":1}"#

private let wikidataSearch = wbSearchJSON([
    ("Q9104", "Amos B. Quillfeather", "American glassworker (1874–1943)"),
    ("Q9103", "Amos Quillfeather", "Colonial surveyor (1725–1790)"),
    ("Q9199", "Quillfeather", "family name"),
])

private let noWikidataHits = wbSearchJSON([])

/// Fixture order matters: the fetcher serves the FIRST fixture whose
/// substring is in the URL.
private func screeningFetcher(search: [String],
                              pageProps: String = allPageProps,
                              pagePropsStatus: Int = 200,
                              wbSearch: String = wikidataSearch,
                              entities: String = allEntities,
                              entitiesStatus: Int = 200,
                              recorder: FixtureResearchFetcher.RequestRecorder? = nil) -> FixtureResearchFetcher {
    FixtureResearchFetcher(fixtures: [
        .init(urlContains: "list=search", body: Data(searchJSON(search).utf8), statusCode: 200),
        .init(urlContains: "prop=pageprops", body: Data(pageProps.utf8), statusCode: pagePropsStatus),
        .init(urlContains: "wbsearchentities", body: Data(wbSearch.utf8), statusCode: 200),
        .init(urlContains: "wbgetentities", body: Data(entities.utf8), statusCode: entitiesStatus),
    ], retrievedAt: fetchedAt, recorder: recorder)
}

private func hosts(_ recorder: FixtureResearchFetcher.RequestRecorder) -> [String: Int] {
    var out: [String: Int] = [:]
    for url in recorder.urls { out[URL(string: url)?.host ?? "", default: 0] += 1 }
    return out
}

/// (title, reason) for each near-miss, in order.
private func nearMissLabels(_ findings: [ResearchFinding]) -> [String] {
    findings.filter(\.isNearMiss).map { "\($0.title) — \($0.screening?.reason ?? "?")" }
}

@Suite("Research Person — Wikipedia screening (fixtures only)")
struct ResearchWikipediaVettingTests {

    // MARK: The four cases from the bug report, per Rick's ruling

    @Test func filmArticleNamingACharacterIsKeptAsANearMissLabelledAFilm() async throws {
        let source = WikipediaSource(fetcher: screeningFetcher(search: [filmHit, namedFilmHit], wbSearch: noWikidataHits))
        let findings = try await source.search(plan: plan)
        #expect(findings.map(\.title) == ["The Ninth Lantern", "Amos Quillfeather (film)"], "kept, not dropped")
        #expect(findings.allSatisfy { $0.screening == .nearMiss("a film") }, "\(nearMissLabels(findings))")
        #expect(findings.allSatisfy { $0.verdict == .unreviewed })
    }

    @Test func samesurnamePersonBornACenturyAndAHalfEarlierIsKeptAsDifferentEra() async throws {
        let source = WikipediaSource(fetcher: screeningFetcher(
            search: [colonistHit], wbSearch: wbSearchJSON([("Q9103", "Amos Quillfeather", "Colonial surveyor (1725–1790)")])))
        let findings = try await source.search(plan: plan)
        #expect(findings.map(\.source) == [.wikipedia, .wikidata])
        #expect(findings.allSatisfy { $0.screening == .nearMiss("different era — born 1725") },
                "\(nearMissLabels(findings))")
    }

    @Test func matchingPersonRanksFirstAsALikelyMatch() async throws {
        let source = WikipediaSource(fetcher: screeningFetcher(search: allHits))
        let findings = try await source.search(plan: plan)
        // Likely matches first (Wikipedia, then Wikidata), then every
        // near-miss in search order — nothing dropped.
        #expect(findings.count == allHits.count + 3)
        #expect(findings.prefix(2).map(\.screening) == [.likely, .likely])
        #expect(findings.prefix(2).map(\.title) == ["Amos B. Quillfeather", "Amos B. Quillfeather"])
        #expect(findings.first?.url == "https://en.wikipedia.org/wiki/Amos_B._Quillfeather")
        #expect(findings[1].url == "http://www.wikidata.org/entity/Q9104")
        #expect(nearMissLabels(findings) == [
            "The Ninth Lantern — a film",
            "Elias Varnholt — a different person",
            "Amos Quillfeather (colonist) — different era — born 1725",
            "Quillfeather, West Virginia — a place",
            "Amos Quillfeather (film) — a film",
            "Amos Quillfeather (ship) — a ship",
            "Amos Quillfeather — different era — born 1725",
            "Quillfeather — a name page",
        ])
    }

    @Test func wikidataFailureKeepsTheHitAsCouldNotBeChecked() async throws {
        let source = WikipediaSource(fetcher: screeningFetcher(search: [matchHit], wbSearch: noWikidataHits,
                                                               entitiesStatus: 503))
        let findings = try await source.search(plan: plan)
        #expect(findings.map(\.title) == ["Amos B. Quillfeather"], "kept, not hidden")
        #expect(findings.first?.screening == .nearMiss("couldn't be checked"),
                "an unchecked hit is never a likely match")
    }

    // MARK: Further edges of the same screen

    @Test func whatAPageIsWinsEvenWhenWikidataIsDown() async throws {
        // The short description already says "film"; no need to call it
        // "couldn't be checked".
        let source = WikipediaSource(fetcher: screeningFetcher(search: [filmHit, placeHit], wbSearch: noWikidataHits,
                                                               entitiesStatus: 503))
        let findings = try await source.search(plan: plan)
        #expect(nearMissLabels(findings) == ["The Ninth Lantern — a film",
                                             "Quillfeather, West Virginia — surname only"])
    }

    @Test func pagePropsFailureLeavesTheHitUnchecked() async throws {
        let source = WikipediaSource(fetcher: screeningFetcher(search: [matchHit], pagePropsStatus: 500,
                                                               wbSearch: noWikidataHits))
        let findings = try await source.search(plan: plan)
        #expect(findings.map(\.screening) == [.nearMiss("couldn't be checked")])
    }

    @Test func articleWithNoWikidataItemIsUnchecked() async throws {
        let props = pagePropsJSON([(104, "Amos B. Quillfeather", nil, "American glassworker (1874–1943)")])
        let source = WikipediaSource(fetcher: screeningFetcher(search: [matchHit], pageProps: props,
                                                               wbSearch: noWikidataHits))
        #expect(try await source.search(plan: plan).map(\.screening) == [.nearMiss("couldn't be checked")])
    }

    @Test func missingWikidataEntityIsUnchecked() async throws {
        let props = pagePropsJSON([(104, "Amos B. Quillfeather", "Q9999", nil)])
        let source = WikipediaSource(fetcher: screeningFetcher(search: [matchHit], pageProps: props,
                                                               wbSearch: noWikidataHits))
        #expect(try await source.search(plan: plan).map(\.screening) == [.nearMiss("couldn't be checked")])
    }

    @Test func nonHumanWithTheRightNameIsANearMissByP31() async throws {
        let source = WikipediaSource(fetcher: screeningFetcher(search: [shipHit], wbSearch: noWikidataHits))
        #expect(try await source.search(plan: plan).map(\.screening) == [.nearMiss("a ship")])
    }

    @Test func humanWhoseSnippetNamesTheRoleIsADifferentPerson() async throws {
        let source = WikipediaSource(fetcher: screeningFetcher(search: [actorHit], wbSearch: noWikidataHits))
        #expect(try await source.search(plan: plan).map(\.screening) == [.nearMiss("a different person")])
    }

    // MARK: Politeness

    @Test func lookupsAreBatchedAndCappedPerHost() async throws {
        let recorder = FixtureResearchFetcher.RequestRecorder()
        let source = WikipediaSource(fetcher: screeningFetcher(search: allHits, recorder: recorder))
        _ = try await source.search(plan: plan)
        let byHost = hosts(recorder)
        #expect(byHost["en.wikipedia.org"] == WikipediaSource.maxWikipediaRequests,
                "one search + one batched pageprops: \(recorder.urls)")
        #expect(byHost["www.wikidata.org"] == WikipediaSource.maxWikidataRequests,
                "one search + one batched wbgetentities: \(recorder.urls)")
        #expect(WikipediaSource.maxWikipediaRequests == 2 && WikipediaSource.maxWikidataRequests == 2)
        let entityCall = try #require(recorder.urls.first { $0.contains("wbgetentities") })
        #expect(entityCall.contains("props=claims"))
        for qid in ["Q9101", "Q9102", "Q9103", "Q9104", "Q9105", "Q9106", "Q9107", "Q9199"] {
            #expect(entityCall.contains(qid), "every candidate screened in the one batch: \(qid)")
        }
    }

    @Test func noHitsMeansNoScreeningRequests() async throws {
        let recorder = FixtureResearchFetcher.RequestRecorder()
        let source = WikipediaSource(fetcher: screeningFetcher(search: [], wbSearch: noWikidataHits, recorder: recorder))
        #expect(try await source.search(plan: plan).isEmpty)
        #expect(recorder.count == 2, "the two searches only: \(recorder.urls)")
    }

    // MARK: Subject years, logging, production wiring

    @Test func subjectBirthYearTightensTheCheckToPlusMinusTolerance() async throws {
        // A plan window alone (1870–1948) accepts a man born 1882; the
        // subject's own birth year 1875 ± 5 does not.
        let born1882 = #"{"entities":{"# + entityJSON("Q9104", p31: "Q5", born: "+1882-01-01T00:00:00Z",
                                                        died: "+1943-01-01T00:00:00Z") + "}}"
        let near = #"{"entities":{"# + entityJSON("Q9104", p31: "Q5", born: "+1879-01-01T00:00:00Z",
                                                     died: "+1943-01-01T00:00:00Z") + "}}"
        let windowOnly = WikipediaSource(fetcher: screeningFetcher(search: [matchHit], wbSearch: noWikidataHits,
                                                                   entities: born1882))
        #expect(try await windowOnly.search(plan: plan).map(\.screening) == [.likely], "1882 is inside 1870–1948")
        let tight = WikipediaSource(fetcher: screeningFetcher(search: [matchHit], wbSearch: noWikidataHits,
                                                              entities: born1882),
                                    birthYear: 1875, deathYear: 1943)
        #expect(try await tight.search(plan: plan).map(\.screening) == [.nearMiss("different era — born 1882")])
        let close = WikipediaSource(fetcher: screeningFetcher(search: [matchHit], wbSearch: noWikidataHits,
                                                              entities: near),
                                    birthYear: 1875, deathYear: 1943)
        #expect(try await close.search(plan: plan).map(\.screening) == [.likely], "1879 is within 5 of 1875")
    }

    @Test func logLineIsCountsOnly() async throws {
        final class Lines: @unchecked Sendable { var lines: [String] = []; let lock = NSLock() }
        let lines = Lines()
        let source = WikipediaSource(
            fetcher: screeningFetcher(search: allHits), birthYear: 1875, deathYear: 1943,
            log: { line in lines.lock.lock(); lines.lines.append(line); lines.lock.unlock() })
        _ = try await source.search(plan: plan)
        #expect(lines.lines == ["Research: wikipedia screened 10 hits: 2 likely, 8 also turned up "
                                + "(not a person 5, name 1, dates 2, couldn't be checked 0)"])
        let joined = lines.lines.joined()
        #expect(!joined.contains("Quillfeather") && !joined.contains("Amos") && !joined.contains("Lantern"))
    }

    @Test func productionSourceListCarriesTheSubjectYears() throws {
        let sources = ResearchRunner.sources(fetcher: screeningFetcher(search: []), subject: try amos())
        let wikipedia = try #require(sources.compactMap { $0 as? WikipediaSource }.first)
        #expect(wikipedia.birthYear == 1875 && wikipedia.deathYear == 1943)
    }

    @Test func sourceStatusCountsNearMissesSeparately() {
        let likely = ResearchFinding(source: .wikipedia, title: "a", date: nil, excerpt: "e",
                                     url: "https://x.example/a", retrievedAt: fetchedAt, screening: .likely)
        let miss = ResearchFinding(source: .wikipedia, title: "b", date: nil, excerpt: "e",
                                   url: "https://x.example/b", retrievedAt: fetchedAt, screening: .nearMiss("a film"))
        #expect(ResearchRunner.SourceOutcome(kind: .wikipedia, findings: [likely, miss], failure: nil).status
                == "1 findings · 1 also turned up")
        #expect(ResearchRunner.SourceOutcome(kind: .wikipedia, findings: [miss], failure: nil).status
                == "no findings · 1 also turned up")
    }

    // MARK: Pure rules

    @Test func nameRuleNeedsSurnameAndGivenOrInitialOnTheTitle() {
        let keys = WikipediaVetting.nameKeys(for: ResearchQueryPlan(
            nameVariants: ["Amos Bartholomew Quillfeather Sr", "Amos Quillfeather", "Amos Ostrander"],
            yearFrom: 1870, yearTo: 1948, placeTokens: [], stateHint: nil))
        let fit: (String) -> WikipediaVetting.NameFit = { WikipediaVetting.nameFit(title: $0, keys: keys) }
        #expect(fit("Amos Quillfeather") == .match)
        #expect(fit("Amos B. Quillfeather") == .match)
        #expect(fit("A. Quillfeather") == .match)
        #expect(fit("Bartholomew Quillfeather") == .match, "went by the middle name")
        #expect(fit("Amos Quillfeather Jr.") == .match)
        #expect(fit("Amos Quillfeather (glassworker)") == .match)
        #expect(fit("ÁMOS QUILLFEATHER") == .match)
        #expect(fit("Amos Ostrander") == .match, "alternate surname variant")
        #expect(fit("Quillfeather") == .surnameOnly)
        #expect(fit("Quillfeather, West Virginia") == .surnameOnly)
        #expect(fit("Quillfeather (surname)") == .surnameOnly)
        #expect(fit("Zebulon Quillfeather") == .surnameOnly, "wrong given name")
        #expect(fit("Quillfeather Amos") == .surnameOnly, "surname must be last")
        #expect(fit("Amos Varnholt") == .none, "wrong surname")
        #expect(fit("The Ninth Lantern") == .none)
    }

    @Test func descriptionLabelsWorksButNotPeopleInThoseTrades() {
        let labelled: [(String, String)] = [
            ("1965 film by Harlan Mott", "a film"), ("1931 American western film", "a film"),
            ("song by The Varnholts", "a song"), ("American television series (2022–present)", "a TV series"),
            ("2003 studio album by Quill", "an album"), ("1899 novel", "a book"),
            ("family name", "a name page"), ("Wikimedia disambiguation page", "a list page"),
            ("fictional character", "a fictional character"),
        ]
        for (description, label) in labelled {
            #expect(WikipediaVetting.nonPersonLabel(description: description) == label, "\(description)")
        }
        let people = ["American actor (1926–2006)", "American film actor", "American film and television actor",
                      "American songwriter", "single-sculls rower", "American novelist", "television presenter",
                      "American glassworker (1874–1943)", "", "American playwright"]
        for description in people {
            #expect(WikipediaVetting.nonPersonLabel(description: description) == nil, "\(description)")
        }
        #expect(WikipediaVetting.nonPersonLabel(description: nil) == nil)
    }

    @Test func entityParserHonoursRankSnaktypeAndPrecision() throws {
        let deprecatedHuman = #"""
        {"entities":{"Q1":{"type":"item","id":"Q1","claims":{
          "P31":[{"mainsnak":{"snaktype":"value","property":"P31","datavalue":{"value":{"id":"Q5"},"type":"wikibase-entityid"}},"rank":"deprecated"}],
          "P569":[{"mainsnak":{"snaktype":"somevalue","property":"P569"},"rank":"normal"},
                  \#(timeClaim("P569", "+1870-00-00T00:00:00Z", precision: 8)),
                  \#(timeClaim("P569", "+1800-00-00T00:00:00Z", precision: 7))]}},
          "Q2":{"id":"Q2","missing":""}},"success":1}
        """#
        let facts = try #require(WikipediaVetting.parseEntities(Data(deprecatedHuman.utf8)))
        let q1 = try #require(facts["Q1"])
        #expect(!q1.isHuman, "a deprecated P31 does not count")
        #expect(q1.births == [WikipediaVetting.WikidataYear(year: 1870, slack: 10)],
                "somevalue and century precision are unknown, decade widens the slack")
        #expect(facts["Q2"] == nil)
        #expect(WikipediaVetting.parseEntities(Data(#"{"error":{"code":"maxlag"}}"#.utf8)) == nil)
        #expect(WikipediaVetting.parseEntities(Data("<html>".utf8)) == nil)
    }

    @Test func dateRuleUsesWindowAndSubjectYears() {
        let life = WikipediaVetting.Lifespan(birth: 1875, death: 1943, plan: plan)
        func human(_ born: Int?, _ died: Int?) -> WikipediaVetting.EntityFacts {
            .init(instanceOf: ["Q5"],
                  births: born.map { [.init(year: $0, slack: 0)] } ?? [],
                  deaths: died.map { [.init(year: $0, slack: 0)] } ?? [])
        }
        #expect(WikipediaVetting.datesCompatible(human(1874, 1943), lifespan: life))
        #expect(WikipediaVetting.datesCompatible(human(1880, 1948), lifespan: life), "both edges of ±5")
        #expect(!WikipediaVetting.datesCompatible(human(1725, 1790), lifespan: life))
        #expect(!WikipediaVetting.datesCompatible(human(1875, 1960), lifespan: life))
        #expect(WikipediaVetting.datesCompatible(human(nil, nil), lifespan: life), "no dates on the item: not held against it")
        #expect(WikipediaVetting.datesCompatible(human(nil, 1941), lifespan: life))
        let birthOnly = WikipediaVetting.Lifespan(birth: 1875, death: nil, plan: plan)
        #expect(!WikipediaVetting.datesCompatible(human(nil, 1960), lifespan: birthOnly), "death outside the window")
    }
}

// MARK: - The pane: grouping, and nothing reaches Hallie by default

private func amos() throws -> ResearchSubject {
    let gedcom = """
    0 HEAD
    0 @I9@ INDI
    1 NAME Amos /Quillfeather/
    1 SEX M
    1 BIRT
    2 DATE 1875
    2 PLAC North Carolina, United States
    1 DEAT
    2 DATE 1943
    2 PLAC West Virginia, United States
    0 TRLR
    """
    let person = try #require(GedcomFamilyGraph(gedcomText: gedcom).people["@I9@"])
    return ResearchSubject(person: person)
}

private func tempPeopleRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WikipediaScreening-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("People", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("Research Person — near-miss group in the pane")
struct ResearchNearMissPaneTests {

    private func finding(_ title: String, _ screening: ResearchScreening?, source: ResearchSourceKind = .wikipedia)
        -> ResearchFinding {
        ResearchFinding(source: source, title: title, date: nil, excerpt: "e",
                        url: "https://x.example/\(title)", retrievedAt: fetchedAt, screening: screening)
    }

    @Test func groupsPutLikelyFirstAndNearMissesApart() throws {
        var dossier = ResearchDossier(subject: try amos())
        dossier.merge(fresh: [finding("paper", nil, source: .chroniclingAmerica),
                              finding("film", .nearMiss("a film")),
                              finding("him", .likely),
                              finding("era", .nearMiss("different era — born 1725"))], at: fetchedAt)
        #expect(dossier.mainFindings.map(\.title) == ["him", "paper"])
        #expect(dossier.nearMissFindings.map(\.title) == ["film", "era"])
        #expect(dossier.untoldConfirmed.isEmpty)
    }

    @Test func aNearMissReachesHallieOnlyWhenRickConfirmsIt() throws {
        var dossier = ResearchDossier(subject: try amos())
        let film = finding("film", .nearMiss("a film"))
        dossier.merge(fresh: [film], at: fetchedAt)
        dossier.setVerdict(.wrong, for: film.id)
        #expect(dossier.nearMissFindings.map(\.title) == ["film"], "marked wrong: stays folded away")
        #expect(dossier.untoldConfirmed.isEmpty)
        dossier.setVerdict(.confirmed, for: film.id)
        #expect(dossier.untoldConfirmed.map(\.title) == ["film"], "an explicit Confirm, as for any finding")
        #expect(dossier.mainFindings.map(\.title) == ["film"], "promoted out of the near-miss group")
        // A re-run keeps Rick's verdict and refreshes the screening.
        dossier.merge(fresh: [film], at: fetchedAt)
        #expect(dossier.findings.first?.verdict == .confirmed)
        #expect(dossier.findings.first?.screening == .nearMiss("a film"))
    }

    @Test func screeningRoundTripsAndOldDossiersStillDecode() throws {
        var dossier = ResearchDossier(subject: try amos())
        dossier.merge(fresh: [finding("film", .nearMiss("a film")), finding("him", .likely),
                              finding("paper", nil, source: .chroniclingAmerica)], at: fetchedAt)
        let data = try JSONEncoder().encode(dossier)
        #expect(try JSONDecoder().decode(ResearchDossier.self, from: data) == dossier)
        // A dossier written before 2026-10-01 has no "screening" key at all.
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var findings = try #require(object["findings"] as? [[String: Any]])
        for index in findings.indices { findings[index].removeValue(forKey: "screening") }
        object["findings"] = findings
        let old = try JSONDecoder().decode(ResearchDossier.self,
                                           from: try JSONSerialization.data(withJSONObject: object))
        #expect(old.findings.allSatisfy { $0.screening == nil })
        #expect(old.nearMissFindings.isEmpty, "old findings all show in the main list")
    }

    /// The whole path: a Run through the pane model with the real
    /// Wikipedia adapter and the fixtures, then Tell Hallie with nothing
    /// confirmed. Nothing is written; the near-misses are kept and grouped.
    @MainActor
    @Test func aRunNeverTellsHallieAnythingByItself() async throws {
        final class Box: @unchecked Sendable { var told = 0 }
        let box = Box()
        let model = ResearchPersonModel(
            subject: try amos(), store: ResearchStore(peopleRoot: try tempPeopleRoot()),
            fetcher: screeningFetcher(search: allHits), speakerName: "Tester",
            record: { _ in box.told += 1; throw CancellationError() },
            sources: { [WikipediaSource(fetcher: $0, birthYear: 1875, deathYear: 1943)] },
            log: { _ in }, now: { fetchedAt })
        model.run()
        let deadline = Date().addingTimeInterval(10)
        while model.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(!model.isRunning)
        #expect(model.mainFindings.map(\.screening) == [.likely, .likely])
        #expect(model.nearMissFindings.count == 8)
        #expect(model.findings.allSatisfy { $0.verdict == .unreviewed })
        #expect(model.confirmedUntoldCount == 0)
        #expect(model.tellHallie() == 0)
        #expect(box.told == 0, "the CyberBrain writer was never called")
    }
}
