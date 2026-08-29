// ResearchSources.swift
// The source adapters behind Research Person: each turns a query plan into
// a few polite HTTP requests and a list of findings. Free, unauthenticated
// endpoints only:
//
//   Chronicling America (Library of Congress) — JSON search API, full-text
//     newspapers 1770–1963, constrained by name + year window (+ state).
//   Find a Grave — the public memorial search page (HTML); the parser is
//     deliberately tolerant of markup drift and yields nothing rather than
//     nonsense when the page changes.
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
// Memory worst case: ≤ 5 sources × ≤ 4 requests × 2 MB bodies, one at a
// time per source ≈ 10 MB transient.
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
    private let pacing = HostPacing()

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout * 2
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent,
                                               "Accept-Language": "en-US,en;q=0.8"]
        session = URLSession(configuration: configuration)
    }

    func fetch(_ url: URL) async throws -> ResearchFetchResult {
        try Task.checkCancellation()
        await pacing.waitTurn(host: url.host ?? "")
        do {
            let (data, response) = try await session.data(from: url)
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

    /// Serialises "last request time" per host so two adapters hitting the
    /// same host still space their requests.
    private actor HostPacing {
        private var lastRequest: [String: Date] = [:]
        func waitTurn(host: String) async {
            let pause = TimeInterval(URLSessionResearchFetcher.hostPause) / 1e9
            if let last = lastRequest[host] {
                let remaining = pause - Date().timeIntervalSince(last)
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1e9))
                }
            }
            lastRequest[host] = Date()
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

    func fetch(_ url: URL) async throws -> ResearchFetchResult {
        let key = url.absoluteString
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

// MARK: - Find a Grave

struct FindAGraveSource: ResearchSource {
    let fetcher: any ResearchFetcher
    let kind: ResearchSourceKind = .findAGrave

    static let base = "https://www.findagrave.com"
    static let maxVariants = 2

    func search(plan: ResearchQueryPlan) async throws -> [ResearchFinding] {
        var findings: [ResearchFinding] = []
        var seen: Set<String> = []
        for variant in plan.nameVariants.prefix(Self.maxVariants) {
            try Task.checkCancellation()
            guard let url = Self.searchURL(name: variant, plan: plan) else { continue }
            let result = try await fetcher.fetch(url)
            let html = String(decoding: result.body, as: UTF8.self)
            for finding in Self.parse(html, retrievedAt: result.retrievedAt)
            where seen.insert(finding.id).inserted {
                findings.append(finding)
            }
        }
        return findings
    }

    /// `/memorial/search?firstname=David&lastname=Latta&birthyear=1847&
    /// birthyearfilter=5&deathyear=1921&deathyearfilter=5&location=…`.
    /// The window's edges come from the plan's tolerance already, so the
    /// filters are the plan's own span.
    static func searchURL(name: String, plan: ResearchQueryPlan) -> URL? {
        let parts = name.split(separator: " ").map(String.init)
        guard let last = parts.last, parts.count >= 1 else { return nil }
        let first = parts.count > 1 ? parts[0] : ""
        var query = "firstname=\(ResearchText.percentEncoded(first))"
            + "&lastname=\(ResearchText.percentEncoded(last))"
        // Find a Grave takes a centre year and ± filter (1, 5, 10 …).
        let span = plan.yearTo - plan.yearFrom
        if span < 200 {
            let centre = plan.yearFrom + ResearchQueryPlan.defaultTolerance
            query += "&birthyear=\(centre)&birthyearfilter=10"
        }
        if let state = plan.stateHint {
            query += "&location=\(ResearchText.percentEncoded(state))"
        }
        query += "&orderby=r"
        return URL(string: base + "/memorial/search?" + query)
    }

    /// Anchors of the form `href="/memorial/<id>/<slug>"` are the only
    /// structure relied on. Around each, a bounded window of text yields
    /// the display name, a "YYYY–YYYY" dates run, and a cemetery line when
    /// present. Any of those may be missing; the memorial link never is.
    static func parse(_ html: String, retrievedAt: Date) -> [ResearchFinding] {
        guard let regex = try? NSRegularExpression(
            pattern: #"href="(/memorial/(\d+)/([^"?#]*))""#, options: [.caseInsensitive])
        else { return [] }
        let nsRange = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, options: [], range: nsRange)
        var findings: [ResearchFinding] = []
        var seen: Set<String> = []
        for match in matches {
            guard let pathRange = Range(match.range(at: 1), in: html),
                  let idRange = Range(match.range(at: 2), in: html),
                  let slugRange = Range(match.range(at: 3), in: html)
            else { continue }
            let memorialID = String(html[idRange])
            guard seen.insert(memorialID).inserted else { continue }
            let path = String(html[pathRange])
            let slug = String(html[slugRange])
            // Window: from the anchor forward ~1500 chars covers the name,
            // dates and cemetery of one result card.
            let windowEnd = html.index(pathRange.upperBound, offsetBy: 1500, limitedBy: html.endIndex) ?? html.endIndex
            let window = String(html[pathRange.upperBound..<windowEnd])
            let name = ResearchText.firstCapture(#"<h2[^>]*class="[^"]*name-grave[^"]*"[^>]*>(.*?)</h2>"#,
                                                 in: window, options: [.dotMatchesLineSeparators])
                .map(ResearchText.stripHTML)
                ?? Self.nameFromSlug(slug)
            let dates = ResearchText.firstCapture(#"((?:c\.\s*)?\d{4}\s*[–\-]\s*(?:c\.\s*)?\d{4}|\d{4}\s*[–\-]\s*unknown|unknown\s*[–\-]\s*\d{4})"#,
                                                  in: ResearchText.stripHTML(window))
            let cemetery = ResearchText.firstCapture(#"class="[^"]*addr-cemet[^"]*"[^>]*>(.*?)</"#,
                                                     in: window, options: [.dotMatchesLineSeparators])
                .map(ResearchText.stripHTML)
            var excerptParts: [String] = []
            if let dates { excerptParts.append(dates) }
            if let cemetery, !cemetery.isEmpty { excerptParts.append(cemetery) }
            let excerpt = excerptParts.isEmpty ? "Find a Grave memorial \(memorialID)" : excerptParts.joined(separator: " · ")
            findings.append(ResearchFinding(
                source: .findAGrave,
                title: name.isEmpty ? "Memorial \(memorialID)" : name,
                date: dates,
                excerpt: excerpt,
                url: base + path,
                retrievedAt: retrievedAt))
        }
        return findings
    }

    static func nameFromSlug(_ slug: String) -> String {
        slug.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

// MARK: - Wikipedia / Wikidata

struct WikipediaSource: ResearchSource {
    let fetcher: any ResearchFetcher
    let kind: ResearchSourceKind = .wikipedia

    static let wikipediaAPI = "https://en.wikipedia.org/w/api.php"
    static let wikidataAPI = "https://www.wikidata.org/w/api.php"
    static let limit = 5

    func search(plan: ResearchQueryPlan) async throws -> [ResearchFinding] {
        guard let primary = plan.nameVariants.first else { return [] }
        var findings: [ResearchFinding] = []
        var seen: Set<String> = []
        // Surname guard: a hit that does not even mention the surname is
        // noise ("David" alone matches half the encyclopedia).
        let surname = primary.split(separator: " ").last.map(String.init) ?? primary
        if let url = Self.wikipediaURL(query: primary) {
            try Task.checkCancellation()
            let result = try await fetcher.fetch(url)
            for finding in Self.parseWikipedia(result.body, retrievedAt: result.retrievedAt, surname: surname)
            where seen.insert(finding.id).inserted {
                findings.append(finding)
            }
        }
        if let url = Self.wikidataURL(query: primary) {
            try Task.checkCancellation()
            let result = try await fetcher.fetch(url)
            for finding in Self.parseWikidata(result.body, retrievedAt: result.retrievedAt, surname: surname)
            where seen.insert(finding.id).inserted {
                findings.append(finding)
            }
        }
        return findings
    }

    static func wikipediaURL(query: String) -> URL? {
        URL(string: wikipediaAPI + "?action=query&list=search&format=json&srlimit=\(limit)"
            + "&srsearch=\(ResearchText.percentEncoded(query))")
    }

    static func wikidataURL(query: String) -> URL? {
        URL(string: wikidataAPI + "?action=wbsearchentities&language=en&format=json&limit=\(limit)"
            + "&search=\(ResearchText.percentEncoded(query))")
    }

    static func parseWikipedia(_ data: Data, retrievedAt: Date, surname: String) -> [ResearchFinding] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = root["query"] as? [String: Any],
              let hits = query["search"] as? [[String: Any]]
        else { return [] }
        return hits.compactMap { hit in
            guard let title = hit["title"] as? String, !title.isEmpty else { return nil }
            let snippet = ResearchText.stripHTML((hit["snippet"] as? String) ?? "")
            let haystack = (title + " " + snippet).lowercased()
            guard haystack.contains(surname.lowercased()) else { return nil }
            let slug = title.replacingOccurrences(of: " ", with: "_")
            let url = "https://en.wikipedia.org/wiki/" + ResearchText.percentEncoded(slug)
            return ResearchFinding(source: .wikipedia, title: title, date: nil,
                                   excerpt: snippet, url: url, retrievedAt: retrievedAt)
        }
    }

    static func parseWikidata(_ data: Data, retrievedAt: Date, surname: String) -> [ResearchFinding] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = root["search"] as? [[String: Any]]
        else { return [] }
        return hits.compactMap { hit in
            guard let id = hit["id"] as? String, let label = hit["label"] as? String else { return nil }
            let description = (hit["description"] as? String) ?? ""
            guard (label + " " + description).lowercased().contains(surname.lowercased()) else { return nil }
            let url = (hit["concepturi"] as? String) ?? "https://www.wikidata.org/wiki/\(id)"
            return ResearchFinding(source: .wikidata, title: label, date: nil,
                                   excerpt: description.isEmpty ? "Wikidata item \(id)" : description,
                                   url: url, retrievedAt: retrievedAt)
        }
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
        let html = String(decoding: result.body, as: UTF8.self)
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
            return findings.isEmpty ? "no findings" : "\(findings.count) findings"
        }
    }

    /// Production source list for one subject.
    static func sources(fetcher: any ResearchFetcher) -> [any ResearchSource] {
        [ChroniclingAmericaSource(fetcher: fetcher),
         FindAGraveSource(fetcher: fetcher),
         WikipediaSource(fetcher: fetcher),
         WebSearchSource(fetcher: fetcher)]
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
