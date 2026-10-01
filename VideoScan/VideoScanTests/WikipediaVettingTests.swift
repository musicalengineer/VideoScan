import Foundation
import Testing
@testable import VideoScan

// Wikipedia / Wikidata vetting (bug 2026-10-01): Research Person on a
// 19th-century ancestor returned the article on a 1965 film because a
// character in it shares the ancestor's surname. The Wikipedia source must
// only return articles ABOUT a human who could plausibly be the subject:
//   - name on the title/label: surname + given name or initial
//   - Wikidata P31 = Q5 (human)
//   - P569/P570 compatible with the subject's lifespan
//   - checks that cannot run (network failure, no Wikidata item) DROP the hit
//
// Fixture shapes probed live 2026-10-01 (list=search, prop=pageprops with
// wikibase_item + wikibase-shortdesc, wbsearchentities, wbgetentities
// props=claims incl. the "missing" entity). Every surname here is synthetic;
// this is a public repo. No live network anywhere in this file.

private let fetchedAt = ISO8601DateFormatter().date(from: "2026-10-01T14:00:00Z")!

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
    #""Q9999":{"id":"Q9999","missing":""}"#,
].joined(separator: ",") + #"},"success":1}"#

private let wikidataSearch = wbSearchJSON([
    ("Q9104", "Amos B. Quillfeather", "American glassworker (1874–1943)"),
    ("Q9103", "Amos Quillfeather", "Colonial surveyor (1725–1790)"),
    ("Q9199", "Quillfeather", "family name"),
])

/// Fixture order matters: the fetcher serves the FIRST fixture whose
/// substring is in the URL.
private func vettingFetcher(search: [String],
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

@Suite("Research Person — Wikipedia vetting (fixtures only)")
struct ResearchWikipediaVettingTests {

    // MARK: The four cases from the bug report

    @Test func filmArticleNamingACharacterIsDropped() async throws {
        let source = WikipediaSource(fetcher: vettingFetcher(search: [filmHit, namedFilmHit],
                                                             wbSearch: wbSearchJSON([])))
        let findings = try await source.search(plan: plan)
        #expect(findings.isEmpty, "a film is not a person: \(findings.map(\.title))")
    }

    @Test func samesurnamePersonBornACenturyAndAHalfEarlierIsDropped() async throws {
        let source = WikipediaSource(fetcher: vettingFetcher(
            search: [colonistHit], wbSearch: wbSearchJSON([("Q9103", "Amos Quillfeather", "Colonial surveyor (1725–1790)")])))
        let findings = try await source.search(plan: plan)
        #expect(findings.isEmpty, "born 1725 cannot be a man born 1875: \(findings.map(\.title))")
    }

    @Test func matchingPersonIsKeptFromBothWikipediaAndWikidata() async throws {
        let source = WikipediaSource(fetcher: vettingFetcher(
            search: [filmHit, actorHit, colonistHit, matchHit, placeHit, namedFilmHit, shipHit]))
        let findings = try await source.search(plan: plan)
        #expect(findings.map(\.source) == [.wikipedia, .wikidata])
        #expect(findings.map(\.title) == ["Amos B. Quillfeather", "Amos B. Quillfeather"])
        #expect(findings.first?.url == "https://en.wikipedia.org/wiki/Amos_B._Quillfeather")
        #expect(findings.last?.url == "http://www.wikidata.org/entity/Q9104")
    }

    @Test func wikidataFailureDropsEverythingAndDoesNotFailTheSource() async throws {
        let source = WikipediaSource(fetcher: vettingFetcher(search: [matchHit], entitiesStatus: 503))
        let findings = try await source.search(plan: plan)
        #expect(findings.isEmpty, "unverified hits are refused, not shown: \(findings.map(\.title))")
    }

    // MARK: Further edges of the same gate

    @Test func pagePropsFailureDropsTheWikipediaHit() async throws {
        let source = WikipediaSource(fetcher: vettingFetcher(search: [matchHit], pagePropsStatus: 500,
                                                             wbSearch: wbSearchJSON([])))
        #expect(try await source.search(plan: plan).isEmpty)
    }

    @Test func articleWithNoWikidataItemIsDropped() async throws {
        let props = pagePropsJSON([(104, "Amos B. Quillfeather", nil, "American glassworker (1874–1943)")])
        let source = WikipediaSource(fetcher: vettingFetcher(search: [matchHit], pageProps: props,
                                                             wbSearch: wbSearchJSON([])))
        #expect(try await source.search(plan: plan).isEmpty)
    }

    @Test func nonHumanWithTheRightNameIsDroppedByP31() async throws {
        let source = WikipediaSource(fetcher: vettingFetcher(search: [shipHit], wbSearch: wbSearchJSON([])))
        #expect(try await source.search(plan: plan).isEmpty)
    }

    @Test func humanWhoseSnippetNamesTheRoleIsDroppedByName() async throws {
        let source = WikipediaSource(fetcher: vettingFetcher(search: [actorHit], wbSearch: wbSearchJSON([])))
        #expect(try await source.search(plan: plan).isEmpty)
    }

    @Test func missingWikidataEntityIsDropped() async throws {
        let props = pagePropsJSON([(104, "Amos B. Quillfeather", "Q9999", nil)])
        let source = WikipediaSource(fetcher: vettingFetcher(search: [matchHit], pageProps: props,
                                                             wbSearch: wbSearchJSON([])))
        #expect(try await source.search(plan: plan).isEmpty)
    }

    // MARK: Politeness

    @Test func lookupsAreBatchedAndCappedPerHost() async throws {
        let recorder = FixtureResearchFetcher.RequestRecorder()
        let source = WikipediaSource(fetcher: vettingFetcher(
            search: [filmHit, actorHit, colonistHit, matchHit, placeHit], recorder: recorder))
        _ = try await source.search(plan: plan)
        let byHost = hosts(recorder)
        #expect(byHost["en.wikipedia.org"] == 2, "one search + one batched pageprops: \(recorder.urls)")
        #expect(byHost["www.wikidata.org"] == 2, "one search + one batched wbgetentities: \(recorder.urls)")
        let entityCall = try #require(recorder.urls.first { $0.contains("wbgetentities") })
        #expect(entityCall.contains("props=claims"))
        #expect(entityCall.contains("Q9103") && entityCall.contains("Q9104"))
        #expect(!entityCall.contains("Q9101"), "the film never reaches Wikidata: it fails the name check")
    }

    @Test func nothingNamedMeansNoVerificationRequests() async throws {
        let recorder = FixtureResearchFetcher.RequestRecorder()
        let source = WikipediaSource(fetcher: vettingFetcher(search: [filmHit, placeHit],
                                                             wbSearch: wbSearchJSON([]), recorder: recorder))
        #expect(try await source.search(plan: plan).isEmpty)
        #expect(!recorder.urls.contains { $0.contains("prop=pageprops") || $0.contains("wbgetentities") },
                "\(recorder.urls)")
    }
}
