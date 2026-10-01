// ResearchRecordSources.swift
// GH #230 Phase B — the two record archives whose terms allow an app to ask
// on the reader's behalf, as adapters inside Research Person's runner:
//
//   Census of Ireland 1901/1911 — api-census.nationalarchives.ie, keyless
//     JSON (`GET /census/query?census_year=&surname=&firstname=&county=
//     &age=&offset=` → `{results:[…], meta:{count,next,prev}}`, 10 rows a
//     page), robots `Crawl-delay: 1`. Shape probed live 2026-10-01. Surname
//     matching is EXACT (no wildcard), so the adapter also asks for the
//     clerk spellings SurnameSpellingVariants generates.
//
//   TNA Discovery — discovery.nationalarchives.gov.uk/API/search/records,
//     keyless JSON today (`sps.searchQuery`, repeated `sps.recordSeries`,
//     `sps.dateFrom/To`, `sps.resultsPageSize`), ≤ 1 request/second, ≤ 3
//     per person. Only for people the tree says served (military series)
//     or who died in England/Wales before 1858 (PCC wills, PROB 11).
//     TNA's terms say "do not cache": CachingResearchFetcher never stores
//     these responses, and a finding keeps only what a citation needs —
//     reference, item title, covering dates and the Discovery id (OGL v3
//     catalogue data). The response body itself is never persisted.
//
// Both: the per-host pause in URLSessionResearchFetcher (1 s) is the pacing;
// the census pages are cached per person by CachingResearchFetcher (a
// personal-research cache under People/<key>/research/cache, purged with
// the dossier); logging is the runner's counts-only line — no name, place
// or excerpt ever reaches a log. Tests use FixtureResearchFetcher only.
//
// A request that fails does not throw away what the others found; the
// source fails only when EVERY request it made failed.
//
// Memory: one response body (≤ 2 MB cap; a census page is ~15 KB) at a
// time per adapter, ≤ 50 census findings and ≤ 60 Discovery findings.
//
// C++ readers: `struct … : ResearchSource` ≈ a class implementing an
// abstract interface; `async throws` ≈ a coroutine that may throw.

import Foundation
import VideoScanCore

// MARK: - Hints from the tree record

/// What the record adapters need to know about the subject, derived once.
struct ResearchRecordHints: Sendable, Equatable {
    let givenName: String?
    /// Primary surname first, then the tree's alternate surnames (maiden /
    /// married), then generated clerk spellings of the primary. Deduplicated.
    let surnames: [String]
    let birthYear: Int?
    let deathYear: Int?
    /// Birth or death place resolves to Ireland.
    let isIrish: Bool
    /// The county as the census index spells it ("Cork", "King's Co."), or nil.
    let irishCensusCounty: String?
    let servedInMilitary: Bool
    /// Died in England or Wales before 1858 — the PCC will era (PROB 11).
    let diedInEnglandOrWalesBefore1858: Bool

    init(givenName: String?, surnames: [String], birthYear: Int?, deathYear: Int?,
         isIrish: Bool, irishCensusCounty: String?, servedInMilitary: Bool,
         diedInEnglandOrWalesBefore1858: Bool) {
        self.givenName = givenName
        self.surnames = surnames
        self.birthYear = birthYear
        self.deathYear = deathYear
        self.isIrish = isIrish
        self.irishCensusCounty = irishCensusCounty
        self.servedInMilitary = servedInMilitary
        self.diedInEnglandOrWalesBefore1858 = diedInEnglandOrWalesBefore1858
    }

    init(subject: ResearchSubject) {
        // The surname: the GEDCOM one, else the last name token once a
        // Jr/Sr suffix is dropped.
        let suffixes: Set<String> = ["jr", "jr.", "sr", "sr.", "ii", "iii", "iv"]
        var tokens = subject.name.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        while let last = tokens.last, suffixes.contains(last.lowercased()) { tokens.removeLast() }
        // A record that is only a given name ("Bridget") has NO surname to
        // search: never send the given name as the family name (QA P3-11).
        let primary = (subject.surname?.isEmpty == false ? subject.surname : nil)
            ?? (tokens.count >= 2 ? tokens.last : nil)
        let person = RecordFinder.Person(name: subject.name, surname: primary,
                                         birthYear: subject.birthYear, deathYear: subject.deathYear,
                                         birthPlace: subject.birthPlace, deathPlace: subject.deathPlace,
                                         servedInMilitary: subject.servedInMilitary ?? false)
        let context = RecordFinder.Context(person)
        var names: [String] = []
        func add(_ name: String) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !names.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
            names.append(trimmed)
        }
        if let primary { add(primary) }
        subject.alternateSurnames.forEach(add)
        if let primary { SurnameSpellingVariants.variants(of: primary).forEach(add) }
        let diedEW = context.deathRegions.contains(.england) || context.deathRegions.contains(.wales)
        self.init(givenName: person.givenName,
                  surnames: names,
                  birthYear: subject.birthYear,
                  deathYear: subject.deathYear,
                  isIrish: context.regions.contains(.ireland),
                  irishCensusCounty: context.irishCounty?.censusName,
                  servedInMilitary: subject.servedInMilitary ?? false,
                  diedInEnglandOrWalesBefore1858: diedEW && (subject.deathYear.map { $0 < 1858 } ?? false))
    }
}

/// Run requests one after another; keep what succeeded; fail only when all
/// failed. Cancellation always propagates.
private func collect(_ urls: [URL], fetcher: any ResearchFetcher,
                     _ handle: (ResearchFetchResult) -> Void) async throws {
    var firstError: Error?
    var anySucceeded = false
    for url in urls {
        try Task.checkCancellation()
        do {
            handle(try await fetcher.fetch(url))
            anySucceeded = true
        } catch ResearchFetchError.cancelled {
            throw ResearchFetchError.cancelled
        } catch is CancellationError {
            throw ResearchFetchError.cancelled
        } catch {
            if firstError == nil { firstError = error }
        }
    }
    if !anySucceeded, let firstError { throw firstError }
}

// MARK: - Census of Ireland 1901 / 1911

struct IrishCensusSource: ResearchSource {
    let fetcher: any ResearchFetcher
    let hints: ResearchRecordHints
    let kind: ResearchSourceKind = .irishCensus

    static let host = "api-census.nationalarchives.ie"
    static let apiBase = "https://api-census.nationalarchives.ie/census/query"
    static let imageBase = "https://api-census.nationalarchives.ie"
    /// The public results page a finding links to (the reader's browser).
    static let resultsPage = "https://nationalarchives.ie/collections/search-the-census/search-results/"
    static let censusYears = [1901, 1911]
    static let pageSize = 10
    /// Hard cap on requests per run (≈ 8 s at the 1 s host pause).
    static let maxRequests = 8
    /// Primary + two others (alternate surname or clerk spelling).
    static let maxSurnames = 3
    static let maxFindings = 50
    /// Census ages drift; ± this many years of the age the tree implies.
    static let ageTolerance = 3

    /// One parsed page: the rows that passed the age filter, the index's
    /// total for the query, and the next page's offset when there is one.
    struct Page: Equatable {
        let findings: [ResearchFinding]
        let total: Int
        let nextOffset: Int?
    }

    /// One request the adapter intends to make, before any I/O.
    struct Query: Equatable {
        let year: Int
        let surname: String
        let age: Int?
        let offset: Int
    }

    /// Census years the person could appear in: born by then, not yet dead.
    static func plausibleYears(birth: Int?, death: Int?) -> [Int] {
        censusYears.filter { year in
            if let birth, birth > year { return false }
            if let death, death < year { return false }
            return true
        }
    }

    /// The age the tree implies at census night (late March / early April):
    /// year − birth year. Nil without a birth year.
    static func expectedAge(year: Int, birth: Int?) -> Int? {
        birth.map { year - $0 }
    }

    func search(plan: ResearchQueryPlan) async throws -> [ResearchFinding] {
        guard hints.isIrish, !hints.surnames.isEmpty else { return [] }
        let years = Self.plausibleYears(birth: hints.birthYear, death: hints.deathYear)
        guard !years.isEmpty else { return [] }

        var budget = Self.maxRequests
        var findings: [ResearchFinding] = []
        var seen: Set<String> = []
        var firstError: Error?
        var anySucceeded = false
        var followUps: [Query] = []

        func run(_ query: Query) async throws -> Page? {
            guard budget > 0, let url = Self.queryURL(query, givenName: hints.givenName,
                                                       county: hints.irishCensusCounty) else { return nil }
            budget -= 1
            try Task.checkCancellation()
            do {
                let result = try await fetcher.fetch(url)
                anySucceeded = true
                let page = Self.parse(result.body, retrievedAt: result.retrievedAt,
                                      expectedAge: Self.expectedAge(year: query.year, birth: hints.birthYear))
                for finding in page.findings where findings.count < Self.maxFindings
                    && seen.insert(finding.id).inserted {
                    findings.append(finding)
                }
                return page
            } catch ResearchFetchError.cancelled {
                throw ResearchFetchError.cancelled
            } catch is CancellationError {
                throw ResearchFetchError.cancelled
            } catch {
                if firstError == nil { firstError = error }
                return nil
            }
        }

        outer: for year in years {
            for surname in hints.surnames.prefix(Self.maxSurnames) {
                guard budget > 0, findings.count < Self.maxFindings else { break outer }
                guard let page = try await run(Query(year: year, surname: surname, age: nil, offset: 0)) else { continue }
                // A common name: narrow by the age the tree implies rather
                // than page through hundreds of strangers.
                if page.total > Self.pageSize,
                   let age = Self.expectedAge(year: year, birth: hints.birthYear) {
                    _ = try await run(Query(year: year, surname: surname, age: age, offset: 0))
                } else if let next = page.nextOffset {
                    followUps.append(Query(year: year, surname: surname, age: nil, offset: next))
                }
            }
        }
        // Leftover budget reads the second page of small result sets.
        for query in followUps where budget > 0 && findings.count < Self.maxFindings {
            _ = try await run(query)
        }
        if !anySucceeded, let firstError { throw firstError }
        return findings
    }

    static func queryURL(_ query: Query, givenName: String?, county: String?) -> URL? {
        var pairs = ["census_year=\(query.year)", "surname=" + RecordFinder.encode(query.surname)]
        if let givenName, !givenName.isEmpty { pairs.append("firstname=" + RecordFinder.encode(givenName)) }
        if let county, !county.isEmpty { pairs.append("county=" + RecordFinder.encode(county)) }
        if let age = query.age { pairs.append("age=\(age)") }
        if query.offset > 0 { pairs.append("offset=\(query.offset)") }
        return URL(string: apiBase + "?" + pairs.joined(separator: "&"))
    }

    /// `"?census_year=1911&…&offset=10"` → 10.
    static func offset(fromNext next: String) -> Int? {
        ResearchText.firstCapture(#"[?&]offset=(\d+)"#, in: next).flatMap(Int.init)
    }

    /// Tolerant: rows lacking an id, year or surname are skipped; a body
    /// that is not the expected JSON yields an empty page, never a throw.
    static func parse(_ data: Data, retrievedAt: Date, expectedAge: Int?) -> Page {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Page(findings: [], total: 0, nextOffset: nil)
        }
        let meta = root["meta"] as? [String: Any]
        let total = (meta?["count"] as? Int) ?? 0
        let next = (meta?["next"] as? String).flatMap(offset(fromNext:))
        let rows = (root["results"] as? [[String: Any]]) ?? []
        let findings = rows.compactMap { finding(from: $0, retrievedAt: retrievedAt, expectedAge: expectedAge) }
        return Page(findings: findings, total: total, nextOffset: next)
    }

    static func finding(from row: [String: Any], retrievedAt: Date, expectedAge: Int?) -> ResearchFinding? {
        let id: String
        if let n = row["id"] as? Int { id = String(n) } else if let s = row["id"] as? String, !s.isEmpty { id = s } else { return nil }
        guard let year = row["census_year"] as? Int,
              let surname = (row["surname"] as? String)?.trimmingCharacters(in: .whitespaces), !surname.isEmpty
        else { return nil }
        let age = row["age"] as? Int
        if let expectedAge, let age, abs(age - expectedAge) > ageTolerance { return nil }
        func text(_ key: String) -> String? {
            let value = (row[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        let first = text("firstname")
        let county = text("county")
        let townland = text("townland")
        let ded = text("ded")

        var title = "Census \(year) — " + [first, surname].compactMap { $0 }.joined(separator: " ")
        if let age { title += ", age \(age)" }

        // The finding opens the public results page narrowed to this
        // household; the fragment keeps two people of one name in one
        // townland (father and son) as two findings.
        var link = [("census_year", String(year)), ("surname", surname)]
        if let first { link.append(("firstname", first)) }
        if let county { link.append(("county", county)) }
        if let townland { link.append(("townland", townland)) }
        if let ded { link.append(("ded", ded)) }
        let url = resultsPage + "?" + link.map { "\($0.0)=\(RecordFinder.encode($0.1))" }.joined(separator: "&")
            + "#nai-\(RecordFinder.encode(id))"

        return ResearchFinding(source: .irishCensus, title: title, date: String(year),
                               excerpt: excerpt(row: row, age: age), url: url,
                               retrievedAt: retrievedAt)
    }

    /// "Wife · age 33 · born Co Cork · Seamstress · … · 4 Main St, DED, Co.
    /// Cork · household form: <pdf>" — whatever fields the row has.
    static func excerpt(row: [String: Any], age: Int?) -> String {
        func text(_ key: String) -> String? {
            let value = (row[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        var parts: [String] = [text("relation_to_head"), age.map { "age \($0)" },
                               text("birthplace").map { "born \($0)" }, text("occupation"),
                               text("religion"), text("marriage_status")].compactMap { $0 }
        let address = [[text("house_number"), text("townland")].compactMap { $0 }.joined(separator: " "),
                       text("ded") ?? "", text("county").map { "Co. \($0)" } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ", ")
        if !address.isEmpty { parts.append(address) }
        if let images = row["images"] as? [[String: Any]],
           let firstImage = images.first, let path = firstImage["url"] as? String, path.hasPrefix("/") {
            parts.append("household form: \(imageBase)\(path)")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - TNA Discovery

struct TNADiscoverySource: ResearchSource {
    let fetcher: any ResearchFetcher
    let hints: ResearchRecordHints
    let kind: ResearchSourceKind = .tnaDiscovery

    static let host = "discovery.nationalarchives.gov.uk"
    static let apiBase = "https://discovery.nationalarchives.gov.uk/API/search/records"
    static let detailsBase = "https://discovery.nationalarchives.gov.uk/details/r/"
    /// Army (WO 97 to 1913, WO 363/364 WWI), RAF (AIR 79), Navy ratings
    /// and officers (ADM 188, ADM 139, ADM 196) — one request covers all.
    static let militarySeries = ["WO 97", "WO 363", "WO 364", "AIR 79", "ADM 188", "ADM 139", "ADM 196"]
    /// Prerogative Court of Canterbury wills, 1384–1858.
    static let probateSeries = ["PROB 11"]
    /// TNA's terms: ≤ 1 request/second (the host pause) — and ours: ≤ 3 a person.
    static let maxRequests = 3
    static let pageSize = 20

    struct Query: Equatable {
        let surname: String
        let series: [String]
        let dateFrom: Int?
        let dateTo: Int?
    }

    /// What will be asked, in priority order, before any I/O: military for
    /// the primary surname, wills when the death fits, then military for
    /// up to two other surnames — never more than `maxRequests`.
    static func plannedQueries(_ hints: ResearchRecordHints) -> [Query] {
        guard let primary = hints.surnames.first else { return [] }
        func military(_ surname: String) -> Query {
            let from = hints.birthYear.map { $0 + 14 }
            let to = hints.deathYear ?? hints.birthYear.map { $0 + 70 }
            return Query(surname: surname, series: militarySeries, dateFrom: from, dateTo: to)
        }
        var out: [Query] = []
        if hints.servedInMilitary { out.append(military(primary)) }
        if hints.diedInEnglandOrWalesBefore1858, let death = hints.deathYear {
            out.append(Query(surname: primary, series: probateSeries, dateFrom: death, dateTo: death + 3))
        }
        if hints.servedInMilitary {
            out.append(contentsOf: hints.surnames.dropFirst().prefix(2).map(military))
        }
        return Array(out.prefix(maxRequests))
    }

    func search(plan: ResearchQueryPlan) async throws -> [ResearchFinding] {
        let urls = Self.plannedQueries(hints).compactMap { Self.queryURL($0, givenName: hints.givenName) }
        guard !urls.isEmpty else { return [] }
        var findings: [ResearchFinding] = []
        var seen: Set<String> = []
        try await collect(urls, fetcher: fetcher) { result in
            for finding in Self.parse(result.body, retrievedAt: result.retrievedAt)
            where seen.insert(finding.id).inserted {
                findings.append(finding)
            }
        }
        return findings
    }

    /// `sps.searchQuery=<surname> <given>` (Discovery's own order), one
    /// `sps.recordSeries` per series, optional date window.
    static func queryURL(_ query: Query, givenName: String?) -> URL? {
        let terms = [query.surname, givenName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        guard !terms.isEmpty else { return nil }
        var pairs = ["sps.searchQuery=" + RecordFinder.encode(terms)]
        pairs += query.series.map { "sps.recordSeries=" + RecordFinder.encode($0) }
        if let from = query.dateFrom { pairs.append("sps.dateFrom=\(from)-01-01") }
        if let to = query.dateTo { pairs.append("sps.dateTo=\(to)-12-31") }
        pairs.append("sps.resultsPageSize=\(pageSize)")
        return URL(string: apiBase + "?" + pairs.joined(separator: "&"))
    }

    /// Keeps reference + item title + covering dates + id; nothing else of
    /// the response survives this function.
    static func parse(_ data: Data, retrievedAt: Date) -> [ResearchFinding] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = root["records"] as? [[String: Any]] else { return [] }
        return records.compactMap { record in
            guard let id = record["id"] as? String, !id.isEmpty,
                  id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }),
                  let reference = (record["reference"] as? String)?
                    .trimmingCharacters(in: .whitespaces), !reference.isEmpty
            else { return nil }
            let itemTitle = ((record["title"] as? String) ?? (record["description"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let dates = (record["coveringDates"] as? String)?.trimmingCharacters(in: .whitespaces)
            let title = itemTitle.isEmpty ? reference : "\(reference) — \(ResearchText.stripHTML(itemTitle))"
            var excerpt = "TNA \(reference)"
            if let dates, !dates.isEmpty { excerpt += " · \(dates)" }
            excerpt += " · Discovery \(id). Catalogue entry only; the image is usually on FindMyPast or Ancestry."
            return ResearchFinding(source: .tnaDiscovery, title: title, date: dates,
                                   excerpt: excerpt, url: detailsBase + id, retrievedAt: retrievedAt)
        }
    }
}
