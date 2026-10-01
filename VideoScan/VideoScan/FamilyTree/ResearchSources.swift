// ResearchSources.swift
// The source adapters behind Research Person: each turns a query plan into
// a few polite HTTP requests and a list of findings. Free, unauthenticated
// endpoints only:
//
//   Chronicling America (Library of Congress) — JSON search API, full-text
//     newspapers 1770–1963, constrained by name + year window (+ state).
//   (Find a Grave was an adapter here until 2026-10-01; its robots.txt
//     disallows the search path, so it is now a pre-filled link — see the
//     note where the adapter used to be.)
//   Wikipedia / Wikidata — JSON search APIs.
//   Web (DuckDuckGo HTML) — best effort; TODO(fragile): the HTML endpoint
//     rate-limits and reshapes without notice. When the parser finds no
//     result anchors the adapter reports "no parse" and returns nothing.
//
// Every request goes through a `ResearchFetcher`: production is a
// URLSession with a 20 s timeout, a 2 MB body cap and a small pause
// between requests to the same host; tests use a fixture fetcher and NEVER
// touch the network. Fetched pages are cached on disk with their retrieved
// date (ResearchStore) and re-used until Rick presses Run again with
// "refresh". Logging is counts only — never a name or an excerpt.
//
// Memory worst case: ≤ 5 sources running at once, each holding ONE body of
// ≤ 2 MB at a time ≈ 10 MB transient. (The Irish census adapter makes up to
// 8 requests, the Discovery adapter up to 3 — sequentially, one body each.)
//
// 2026-10-01 (GH #230 Phase B): two record adapters live in
// ResearchRecordSources.swift — Census of Ireland 1901/1911 and TNA
// Discovery. Discovery responses bypass the page cache (their terms).
//
// C++ readers: `protocol` ≈ abstract interface; `actor` ≈ a class with an
// implicit mutex around all members; `async throws` ≈ a coroutine that
// may throw. `TaskGroup` ≈ fork/join of child coroutines.

import Foundation

// MARK: - Fetching

/// What every adapter uses to get bytes. Swappable for fixtures.
protocol ResearchFetcher: Sendable {
    func fetch(_ url: URL) async throws -> ResearchFetchResult
}

struct ResearchFetchResult: Sendable, Equatable {
    let url: String
    let statusCode: Int
    let body: Data
    let retrievedAt: Date
    /// True when served from the on-disk cache (no request was made).
    let fromCache: Bool
}

enum ResearchFetchError: Error, LocalizedError, Equatable {
    case badStatus(Int)
    case tooLarge(Int)
    case network(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "HTTP \(code)"
        case .tooLarge(let bytes): return "response too large (\(bytes) bytes)"
        case .network(let detail): return detail
        case .cancelled: return "cancelled"
        }
    }
}

/// Production fetcher. One shared session; a per-host pause so we never
/// hammer a public service.
final class URLSessionResearchFetcher: ResearchFetcher, @unchecked Sendable {
    static let userAgent = "VideoScan-Research/0.1 (personal family-archive tool; polite; cached)"
    static let timeout: TimeInterval = 20
    static let maxBodyBytes = ResearchStore.maxCachedBodyBytes
    static let hostPause: UInt64 = 1_000_000_000 // 1 s in nanoseconds

    private let session: URLSession
    private let pacing = ResearchHostPacing(pause: TimeInterval(URLSessionResearchFetcher.hostPause) / 1e9)

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout * 2
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent,
                                               "Accept-Language": "en-US,en;q=0.8"]
        session = URLSession(configuration: configuration)
    }

    /// The JSON APIs are asked for JSON explicitly. Probed 2026-10-01: TNA
    /// Discovery answers JSON with or without the header, but its terms
    /// describe JSON *or XML* by Accept, so the app never relies on a default.
    static let jsonAPIHosts: Set<String> = [TNADiscoverySource.host, IrishCensusSource.host]

    /// The request for one URL (pure, so the headers can be pinned by a test).
    static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let host = url.host?.lowercased(), jsonAPIHosts.contains(host) {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        return request
    }

    func fetch(_ url: URL) async throws -> ResearchFetchResult {
        try Task.checkCancellation()
        await pacing.waitTurn(host: url.host ?? "")
        do {
            let (data, response) = try await session.data(for: Self.request(for: url))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { throw ResearchFetchError.badStatus(code) }
            guard data.count <= Self.maxBodyBytes else { throw ResearchFetchError.tooLarge(data.count) }
            return ResearchFetchResult(url: url.absoluteString, statusCode: code, body: data,
                                       retrievedAt: Date(), fromCache: false)
        } catch let error as ResearchFetchError {
            throw error
        } catch is CancellationError {
            throw ResearchFetchError.cancelled
        } catch {
            throw ResearchFetchError.network(error.localizedDescription)
        }
    }
}

/// Serialises "last request time" per host so two adapters hitting the
/// same host still space their requests.
actor ResearchHostPacing {
    private let pause: TimeInterval
    private var lastRequest: [String: Date] = [:]

    init(pause: TimeInterval) { self.pause = pause }

    /// RESERVES the caller's slot before sleeping (QA 2026-10-01 P3-8). An
    /// actor is re-entrant across `await`: with "sleep, then record", two
    /// callers arriving together both read the same last time, sleep the
    /// same remainder and fire together. Here each caller claims
    /// max(now, previous slot + pause) synchronously, then sleeps until it.
    func waitTurn(host: String) async {
        let now = Date()
        let slot = lastRequest[host].map { max(now, $0.addingTimeInterval(pause)) } ?? now
        lastRequest[host] = slot
        let wait = slot.timeIntervalSince(now)
        if wait > 0 {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
        }
    }
}

/// Wraps any fetcher with the on-disk page cache for one subject.
struct CachingResearchFetcher: ResearchFetcher {
    let inner: any ResearchFetcher
    let store: ResearchStore
    let subjectKey: String
    /// When true, cached pages are ignored (Run with refresh).
    let bypassCache: Bool

    /// Hosts whose responses are NEVER written to (or read from) the page
    /// cache. TNA's API terms say "do not cache" (GH #230): what we keep
    /// from Discovery is our own finding — a catalogue reference, id and
    /// title — in the dossier, never their response body.
    static let uncachedHosts: Set<String> = [TNADiscoverySource.host]

    func fetch(_ url: URL) async throws -> ResearchFetchResult {
        let key = url.absoluteString
        if let host = url.host?.lowercased(), Self.uncachedHosts.contains(host) {
            return try await inner.fetch(url)
        }
        if !bypassCache, let cached = store.cachedPage(key: subjectKey, pageURL: key) {
            return ResearchFetchResult(url: cached.url, statusCode: cached.statusCode,
                                       body: cached.body, retrievedAt: cached.retrievedAt,
                                       fromCache: true)
        }
        let fresh = try await inner.fetch(url)
        // A cache failure must not fail the search — the finding is still
        // shown, only the next run re-fetches.
        try? store.cache(ResearchStore.CachedPage(url: fresh.url, retrievedAt: fresh.retrievedAt,
                                                  statusCode: fresh.statusCode, body: fresh.body),
                         key: subjectKey)
        return fresh
    }
}

/// Test double: canned bodies by URL substring; anything else is a 404.
struct FixtureResearchFetcher: ResearchFetcher {
    struct Fixture: Sendable {
        let urlContains: String
        let body: Data
        let statusCode: Int
    }
    let fixtures: [Fixture]
    let retrievedAt: Date
    let recorder: RequestRecorder?

    final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var urls: [String] = []
        init() {}
        func record(_ url: String) { lock.lock(); urls.append(url); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return urls.count }
    }

    init(fixtures: [Fixture], retrievedAt: Date, recorder: RequestRecorder? = nil) {
        self.fixtures = fixtures
        self.retrievedAt = retrievedAt
        self.recorder = recorder
    }

    func fetch(_ url: URL) async throws -> ResearchFetchResult {
        recorder?.record(url.absoluteString)
        let text = url.absoluteString
        guard let hit = fixtures.first(where: { text.contains($0.urlContains) }) else {
            throw ResearchFetchError.badStatus(404)
        }
        guard (200..<300).contains(hit.statusCode) else { throw ResearchFetchError.badStatus(hit.statusCode) }
        return ResearchFetchResult(url: text, statusCode: hit.statusCode, body: hit.body,
                                   retrievedAt: retrievedAt, fromCache: false)
    }
}

// MARK: - Source protocol

protocol ResearchSource: Sendable {
    var kind: ResearchSourceKind { get }
    func search(plan: ResearchQueryPlan) async throws -> [ResearchFinding]
}

/// Shared text helpers for the parsers.
enum ResearchText {
    /// Strip tags, decode the handful of entities search pages use, and
    /// collapse whitespace. Good enough for excerpts; never for structure.
    static func stripHTML(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
            ("&#x27;", "'"), ("&nbsp;", " "), ("&ndash;", "–"), ("&mdash;", "—"), ("&#8211;", "–"),
        ]
        for (entity, plain) in entities { text = text.replacingOccurrences(of: entity, with: plain) }
        return collapseWhitespace(text)
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    /// A window of `radius` characters around the first (case-insensitive)
    /// hit of any needle; the head of the text when nothing matches.
    static func snippet(_ text: String, around needles: [String], radius: Int = 220) -> String {
        let clean = collapseWhitespace(text)
        guard !clean.isEmpty else { return "" }
        let lowered = clean.lowercased()
        var hit: Range<String.Index>?
        for needle in needles where !needle.isEmpty {
            if let range = lowered.range(of: needle.lowercased()) { hit = range; break }
        }
        guard let hit else { return String(clean.prefix(radius * 2)) }
        let start = clean.index(hit.lowerBound, offsetBy: -radius, limitedBy: clean.startIndex) ?? clean.startIndex
        let end = clean.index(hit.upperBound, offsetBy: radius, limitedBy: clean.endIndex) ?? clean.endIndex
        var out = String(clean[start..<end])
        if start > clean.startIndex { out = "…" + out }
        if end < clean.endIndex { out += "…" }
        return out
    }

    /// "18750512" → "1875-05-12"; anything else returned as-is.
    static func isoDate(fromCompact raw: String) -> String {
        guard raw.count == 8, raw.allSatisfy(\.isNumber) else { return raw }
        let y = raw.prefix(4), m = raw.dropFirst(4).prefix(2), d = raw.suffix(2)
        return "\(y)-\(m)-\(d)"
    }

    static func percentEncoded(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?/#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Every capture-1 match of `pattern` in `text`.
    static func captures(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }

    static func firstCapture(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> String? {
        captures(pattern, in: text, options: options).first
    }
}

// MARK: - Chronicling America

struct ChroniclingAmericaSource: ResearchSource {
    let fetcher: any ResearchFetcher
    let kind: ResearchSourceKind = .chroniclingAmerica

    static let base = "https://chroniclingamerica.loc.gov"
    /// The collection's coverage; the plan's window is clipped to it.
    static let coverage = 1770...1963
    static let rowsPerQuery = 20
    /// One request per name variant, at most this many.
    static let maxVariants = 3

    func search(plan: ResearchQueryPlan) async throws -> [ResearchFinding] {
        let from = max(plan.yearFrom, Self.coverage.lowerBound)
        let to = min(plan.yearTo, Self.coverage.upperBound)
        guard from <= to else { return [] }
        var findings: [ResearchFinding] = []
        var seen: Set<String> = []
        for variant in plan.nameVariants.prefix(Self.maxVariants) {
            try Task.checkCancellation()
            guard let url = Self.queryURL(name: variant, from: from, to: to, state: plan.stateHint) else { continue }
            let result = try await fetcher.fetch(url)
            for finding in Self.parse(result.body, retrievedAt: result.retrievedAt,
                                      needles: plan.nameVariants)
            where seen.insert(finding.id).inserted {
                findings.append(finding)
            }
        }
        return findings
    }

    static func queryURL(name: String, from: Int, to: Int, state: String?) -> URL? {
        var query = "andtext=\(ResearchText.percentEncoded(name))"
            + "&date1=\(from)&date2=\(to)&dateFilterType=yearRange"
            + "&rows=\(rowsPerQuery)&searchType=advanced&format=json"
        if let state, !state.isEmpty {
            query += "&state=\(ResearchText.percentEncoded(state))"
        }
        return URL(string: base + "/search/pages/results/?" + query)
    }

    /// Tolerant: any item lacking an `id` is skipped; missing fields become
    /// empty strings. Never throws on shape drift.
    static func parse(_ data: Data, retrievedAt: Date, needles: [String]) -> [ResearchFinding] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]]
        else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let pageURL = id.hasPrefix("http") ? id : base + id
            let paper = (item["title"] as? String) ?? "Newspaper page"
            let place = (item["place_of_publication"] as? String) ?? ""
            let date = (item["date"] as? String).map(ResearchText.isoDate(fromCompact:))
            let ocr = (item["ocr_eng"] as? String) ?? ""
            let excerpt = ResearchText.snippet(ocr, around: needles)
            let title = place.isEmpty ? paper : "\(paper) (\(place))"
            return ResearchFinding(source: .chroniclingAmerica, title: title, date: date,
                                   excerpt: excerpt.isEmpty ? "(no OCR text returned)" : excerpt,
                                   url: pageURL, retrievedAt: retrievedAt)
        }
    }
}

// MARK: - Find a Grave (demoted to a link, 2026-10-01)
//
// There is deliberately NO Find a Grave adapter. Find a Grave's robots.txt
// has disallowed /memorial/search since 2024-11-25; the app fetched it
// anyway until Rick approved the demotion (2026-10-01, GH #230, survey
// docs/uk_scotland_records_survey_2026-10-01.md §6.1). The search is now a
// pre-filled Record Finder link ("us.findagrave" in VideoScanCore's
// RecordFinder registry) that opens in the reader's browser, and what they
// find comes back through "I found a record…". Findings already saved with
// source `.findAGrave` still load, show and can be told to Hallie.
// RecordFinderAdapterTests pins that no automated source requests
// findagrave.com.

// MARK: - Wikipedia / Wikidata
//
// Bug 2026-10-01: a full-text search for a 19th-century ancestor returned
// the article on a 1965 film because a character in it shares the surname,
// shown like any other finding. Every hit is now SCREENED (WikipediaVetting:
// name on the title, Wikidata P31 = Q5, compatible P569/P570) and KEPT —
// Rick's ruling: serendipity matters. Likely matches come first; the rest
// follow as near-misses with a plain reason ("a film", "surname only",
// "different era — born 1725", "couldn't be checked"). A check that cannot
// run never yields a likely match. Requests per run, all batched:
//   en.wikipedia.org  — 1 search + 1 prop=pageprops (QIDs, short descriptions)
//   www.wikidata.org  — 1 wbsearchentities + 1 wbgetentities&props=claims
// The fetcher's per-host pacing spaces each host independently.

struct WikipediaSource: ResearchSource {
    let fetcher: any ResearchFetcher
    let kind: ResearchSourceKind = .wikipedia
    /// The subject's own years, for the ± tolerance date check. Nil = only
    /// the plan's year window applies.
    let birthYear: Int?
    let deathYear: Int?
    /// Counts-only log sink (one line per run).
    let log: @Sendable (String) -> Void

    static let wikipediaHost = "en.wikipedia.org"
    static let wikidataHost = "www.wikidata.org"
    static let wikipediaAPI = "https://\(wikipediaHost)/w/api.php"
    static let wikidataAPI = "https://\(wikidataHost)/w/api.php"
    static let limit = 5
    /// Hard caps per run, per host (one search + one batched lookup each).
    static let maxWikipediaRequests = 2
    static let maxWikidataRequests = 2

    init(fetcher: any ResearchFetcher, birthYear: Int? = nil, deathYear: Int? = nil,
         log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.fetcher = fetcher
        self.birthYear = birthYear
        self.deathYear = deathYear
        self.log = log
    }

    /// A search hit waiting for its checks.
    struct Candidate: Equatable {
        let source: ResearchSourceKind
        let title: String
        let excerpt: String
        let url: String
        var qid: String?
        var description: String?
        var pageID: Int?
    }

    func search(plan: ResearchQueryPlan) async throws -> [ResearchFinding] {
        guard let primary = plan.nameVariants.first else { return [] }
        let keys = WikipediaVetting.nameKeys(for: plan)
        let lifespan = WikipediaVetting.Lifespan(birth: birthYear, death: deathYear, plan: plan)
        var tally = WikipediaVetting.Tally()
        var budget = [Self.wikipediaHost: Self.maxWikipediaRequests,
                      Self.wikidataHost: Self.maxWikidataRequests]

        /// Spends one request from the host's budget; nil when the URL is
        /// nil or the budget is gone (the flow below never exceeds it).
        func fetch(_ url: URL?) async throws -> ResearchFetchResult? {
            guard let url, let host = url.host?.lowercased(), let left = budget[host], left > 0 else { return nil }
            budget[host] = left - 1
            try Task.checkCancellation()
            return try await fetcher.fetch(url)
        }

        /// A screening lookup. Failure means "could not check": the hits
        /// that needed it are kept as "couldn't be checked", the source
        /// itself does not fail. Cancellation still propagates.
        func lookup(_ url: URL?) async throws -> ResearchFetchResult? {
            do {
                return try await fetch(url)
            } catch ResearchFetchError.cancelled {
                throw ResearchFetchError.cancelled
            } catch is CancellationError {
                throw ResearchFetchError.cancelled
            } catch {
                return nil
            }
        }

        // 1. Searches. A failed SEARCH still fails the source ("failed: …"),
        //    exactly as before; only the screening lookups degrade.
        var retrievedAt = Date()
        var wikipediaHits: [Candidate] = []
        if let result = try await fetch(Self.wikipediaURL(query: primary)) {
            retrievedAt = result.retrievedAt
            wikipediaHits = Self.parseWikipediaSearch(result.body)
        }
        var wikidataHits: [Candidate] = []
        if let result = try await fetch(Self.wikidataURL(query: primary)) {
            wikidataHits = Self.parseWikidataSearch(result.body)
        }

        // 2. Every Wikipedia page → its Wikidata item + short description,
        //    in one batched request.
        // (pagePropsURL is nil for no pages, so `lookup` makes no request.)
        let props = try await lookup(Self.pagePropsURL(pageIDs: wikipediaHits.compactMap(\.pageID)))
            .flatMap { Self.parsePageProps($0.body) }
        for index in wikipediaHits.indices {
            guard let id = wikipediaHits[index].pageID, let page = props?[id] else { continue }
            wikipediaHits[index].qid = page.qid
            wikipediaHits[index].description = page.shortDescription
        }
        let candidates = wikipediaHits + wikidataHits

        // 3. One batched Wikidata lookup for P31 / P569 / P570.
        var qids: [String] = []
        for qid in candidates.compactMap(\.qid) where !qids.contains(qid) { qids.append(qid) }
        // (entitiesURL is nil for no QIDs, so `lookup` makes no request.)
        let facts = try await lookup(Self.entitiesURL(ids: qids))
            .flatMap { WikipediaVetting.parseEntities($0.body) }

        // 4. Screen, then rank: likely matches first, near-misses after,
        //    each group in search order.
        var likely: [ResearchFinding] = []
        var nearMisses: [ResearchFinding] = []
        var seen: Set<String> = []
        for hit in candidates {
            let evidence = WikipediaVetting.Evidence(title: hit.title, description: hit.description,
                                                     facts: hit.qid.flatMap { facts?[$0] })
            let screening = WikipediaVetting.screen(evidence, keys: keys, lifespan: lifespan)
            let finding = ResearchFinding(source: hit.source, title: hit.title, date: nil,
                                          excerpt: hit.excerpt, url: hit.url, retrievedAt: retrievedAt,
                                          screening: screening)
            guard seen.insert(finding.id).inserted else { continue }
            tally.count(screening)
            if screening.isNearMiss { nearMisses.append(finding) } else { likely.append(finding) }
        }
        log(tally.logLine)
        return likely + nearMisses
    }

    // MARK: URLs

    static func wikipediaURL(query: String) -> URL? {
        URL(string: wikipediaAPI + "?action=query&list=search&format=json&srlimit=\(limit)"
            + "&srsearch=\(ResearchText.percentEncoded(query))")
    }

    static func wikidataURL(query: String) -> URL? {
        URL(string: wikidataAPI + "?action=wbsearchentities&language=en&format=json&limit=\(limit)"
            + "&search=\(ResearchText.percentEncoded(query))")
    }

    /// `prop=pageprops` for up to `limit` pages: `wikibase_item` (the QID)
    /// and `wikibase-shortdesc` (the one-line description).
    static func pagePropsURL(pageIDs: [Int]) -> URL? {
        guard !pageIDs.isEmpty else { return nil }
        let ids = pageIDs.prefix(limit).map(String.init).joined(separator: "%7C")
        return URL(string: wikipediaAPI + "?action=query&prop=pageprops"
            + "&ppprop=wikibase_item%7Cwikibase-shortdesc&format=json&pageids=\(ids)")
    }

    /// `wbgetentities&props=claims` for every candidate QID in ONE request
    /// (at most 2 × `limit`; the API allows 50).
    static func entitiesURL(ids: [String]) -> URL? {
        let safe = ids.filter { $0.range(of: #"^Q\d+$"#, options: .regularExpression) != nil }
        guard !safe.isEmpty else { return nil }
        return URL(string: wikidataAPI + "?action=wbgetentities&props=claims&format=json&ids="
            + safe.prefix(limit * 2).joined(separator: "%7C"))
    }

    // MARK: Parsers (tolerant: shape drift yields nothing, never a throw)

    static func parseWikipediaSearch(_ data: Data) -> [Candidate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = root["query"] as? [String: Any],
              let hits = query["search"] as? [[String: Any]]
        else { return [] }
        return hits.compactMap { hit in
            guard let title = hit["title"] as? String, !title.isEmpty else { return nil }
            let snippet = ResearchText.stripHTML((hit["snippet"] as? String) ?? "")
            let slug = title.replacingOccurrences(of: " ", with: "_")
            return Candidate(source: .wikipedia, title: title, excerpt: snippet,
                             url: "https://en.wikipedia.org/wiki/" + ResearchText.percentEncoded(slug),
                             qid: nil, description: nil, pageID: hit["pageid"] as? Int)
        }
    }

    static func parseWikidataSearch(_ data: Data) -> [Candidate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = root["search"] as? [[String: Any]]
        else { return [] }
        return hits.compactMap { hit in
            guard let id = hit["id"] as? String, let label = hit["label"] as? String else { return nil }
            let description = (hit["description"] as? String) ?? ""
            return Candidate(source: .wikidata, title: label,
                             excerpt: description.isEmpty ? "Wikidata item \(id)" : description,
                             url: (hit["concepturi"] as? String) ?? "https://www.wikidata.org/wiki/\(id)",
                             qid: id, description: description, pageID: nil)
        }
    }

    struct PageProps: Equatable {
        let qid: String?
        let shortDescription: String?
    }

    /// pageid → (QID, short description). Nil when the body is not a
    /// `query.pages` response at all, so every pending hit counts as
    /// unverified.
    static func parsePageProps(_ data: Data) -> [Int: PageProps]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = root["query"] as? [String: Any],
              let pages = query["pages"] as? [String: Any]
        else { return nil }
        var out: [Int: PageProps] = [:]
        for raw in pages.values {
            guard let page = raw as? [String: Any], let id = page["pageid"] as? Int else { continue }
            let props = page["pageprops"] as? [String: Any]
            out[id] = PageProps(qid: props?["wikibase_item"] as? String,
                                shortDescription: props?["wikibase-shortdesc"] as? String)
        }
        return out
    }
}

// MARK: - Web (DuckDuckGo HTML)

/// TODO(fragile): DuckDuckGo's HTML endpoint is unofficial. It may answer a
/// challenge page or change its markup; the parser then yields nothing and
/// the runner reports "no parse" for this source. Replace with a proper
/// search API when one without keys is available.
struct WebSearchSource: ResearchSource {
    let fetcher: any ResearchFetcher
    let kind: ResearchSourceKind = .web

    static let endpoint = "https://html.duckduckgo.com/html/"
    static let maxResults = 8

    func search(plan: ResearchQueryPlan) async throws -> [ResearchFinding] {
        guard let primary = plan.nameVariants.first, let url = Self.queryURL(plan: plan, name: primary) else { return [] }
        try Task.checkCancellation()
        let result = try await fetcher.fetch(url)
        let html = String(data: result.body, encoding: .utf8) ?? ""
        return Array(Self.parse(html, retrievedAt: result.retrievedAt).prefix(Self.maxResults))
    }

    /// `"David McGill Latta" 1847..1921 Massachusetts` — quoted name plus a
    /// year and place hint.
    static func queryURL(plan: ResearchQueryPlan, name: String) -> URL? {
        var terms = "\"\(name)\""
        if let place = plan.placeTokens.first { terms += " \(place)" }
        terms += " \(plan.yearFrom)..\(plan.yearTo)"
        return URL(string: endpoint + "?q=" + ResearchText.percentEncoded(terms))
    }

    static func parse(_ html: String, retrievedAt: Date) -> [ResearchFinding] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return [] }
        let nsRange = NSRange(html.startIndex..., in: html)
        var findings: [ResearchFinding] = []
        var seen: Set<String> = []
        for match in regex.matches(in: html, options: [], range: nsRange) {
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html)
            else { continue }
            let href = Self.unwrapRedirect(String(html[hrefRange]))
            guard href.hasPrefix("http"), seen.insert(href).inserted else { continue }
            let title = ResearchText.stripHTML(String(html[titleRange]))
            let windowEnd = html.index(titleRange.upperBound, offsetBy: 1200, limitedBy: html.endIndex) ?? html.endIndex
            let window = String(html[titleRange.upperBound..<windowEnd])
            let snippet = ResearchText.firstCapture(#"class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</a>"#,
                                                    in: window, options: [.dotMatchesLineSeparators])
                .map(ResearchText.stripHTML) ?? ""
            findings.append(ResearchFinding(source: .web, title: title.isEmpty ? href : title, date: nil,
                                            excerpt: snippet.isEmpty ? href : snippet,
                                            url: href, retrievedAt: retrievedAt))
        }
        return findings
    }

    /// `//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.org%2Fx&rut=…` → the
    /// real URL.
    static func unwrapRedirect(_ href: String) -> String {
        let decoded = ResearchText.stripHTML(href)
        if let range = decoded.range(of: "uddg=") {
            let tail = decoded[range.upperBound...]
            let encoded = tail.split(separator: "&").first.map(String.init) ?? String(tail)
            return encoded.removingPercentEncoding ?? encoded
        }
        if decoded.hasPrefix("//") { return "https:" + decoded }
        return decoded
    }
}

// MARK: - Runner

/// Runs every source concurrently and reports per-source outcome. Logging
/// is counts only. Cancellation propagates to every child.
enum ResearchRunner {
    struct SourceOutcome: Sendable, Equatable {
        let kind: ResearchSourceKind
        let findings: [ResearchFinding]
        /// Nil on success; a short reason otherwise.
        let failure: String?

        var status: String {
            if let failure { return "failed: \(failure)" }
            let nearMisses = findings.filter(\.isNearMiss).count
            let kept = findings.count - nearMisses
            let head = kept == 0 ? "no findings" : "\(kept) findings"
            return nearMisses == 0 ? head : head + " · \(nearMisses) also turned up"
        }
    }

    /// The general-web sources. Find a Grave is not one of them any more
    /// (robots.txt; it is a Record Finder link). The subject's years, when
    /// given, tighten Wikipedia's date check to ± tolerance of each.
    static func sources(fetcher: any ResearchFetcher,
                        birthYear: Int? = nil, deathYear: Int? = nil,
                        log: @escaping @Sendable (String) -> Void = { _ in }) -> [any ResearchSource] {
        [ChroniclingAmericaSource(fetcher: fetcher),
         WikipediaSource(fetcher: fetcher, birthYear: birthYear, deathYear: deathYear, log: log),
         WebSearchSource(fetcher: fetcher)]
    }

    /// The kinds a Run can produce, in display order (the pane's "Sources"
    /// line). Wikidata rides with Wikipedia.
    static let runKinds: [ResearchSourceKind] = [.chroniclingAmerica, .wikipedia, .web,
                                                 .irishCensus, .tnaDiscovery]

    /// Production source list for one subject: the general sources plus the
    /// record adapters (GH #230 Phase B), which read the subject's places,
    /// years and military flag and make NO request when they do not apply.
    static func sources(fetcher: any ResearchFetcher, subject: ResearchSubject,
                        log: @escaping @Sendable (String) -> Void = { _ in }) -> [any ResearchSource] {
        let hints = ResearchRecordHints(subject: subject)
        return sources(fetcher: fetcher, birthYear: subject.birthYear, deathYear: subject.deathYear, log: log)
            + [IrishCensusSource(fetcher: fetcher, hints: hints),
               TNADiscoverySource(fetcher: fetcher, hints: hints)]
    }

    static func run(plan: ResearchQueryPlan,
                    sources: [any ResearchSource],
                    log: @escaping @Sendable (String) -> Void = { _ in }) async -> [SourceOutcome] {
        await withTaskGroup(of: SourceOutcome.self) { group in
            for source in sources {
                group.addTask {
                    do {
                        let findings = try await source.search(plan: plan)
                        log("Research: \(source.kind.rawValue) returned \(findings.count) findings")
                        return SourceOutcome(kind: source.kind, findings: findings, failure: nil)
                    } catch {
                        let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                        log("Research: \(source.kind.rawValue) failed (\(reason))")
                        return SourceOutcome(kind: source.kind, findings: [], failure: reason)
                    }
                }
            }
            var outcomes: [SourceOutcome] = []
            for await outcome in group { outcomes.append(outcome) }
            // Stable order for the UI regardless of which finished first.
            let order = ResearchSourceKind.allCases
            return outcomes.sorted {
                (order.firstIndex(of: $0.kind) ?? 0) < (order.firstIndex(of: $1.kind) ?? 0)
            }
        }
    }
}
