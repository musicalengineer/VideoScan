// HallieTurnExecutor+DateOrdered.swift
// "and the newest?" / "the most recent one?" / "ok show me the second one"
// after a count or an age (eval cc007, cs015, tm009, 2026-09-01). A count
// answer and an age answer still carry the question they counted or
// measured (ConversationMemory.lastRefinable); this re-runs it over EVERY
// matching record, orders by date, and names the asked-for one. The
// ordered list (first 25) becomes the answer's citations so "show me the
// second one" afterwards is the second in THAT order.

import Foundation
import VideoScanCore

extension HallieTurnExecutor {

    static func executeDateOrdered(
        _ effective: ArchivistQueryAST.Presence,
        order request: DateOrderRequest,
        route: Route,
        intent: Intent,
        notes: [String],
        context: Context
    ) async throws -> Result {
        let records = context.presenceRecords
        var queries: [ArchivistPresenceQuery?] = []
        let scopeText: String
        switch request.scope {
        case .wholeCatalog:
            queries = [nil]
            scopeText = "everything in the catalog"
        case .list(_, let anyOfPeople):
            if anyOfPeople, let people = effective.people, people.count > 1 {
                queries = people.map { person in
                    var single = effective
                    single.people = [person]
                    return ArchivistPresenceQuery(single)
                }
            } else {
                queries = [ArchivistPresenceQuery(effective)]
            }
            scopeText = describe(effective, anyOfPeople: anyOfPeople)
        }

        // Union across the per-person queries (a video with ANY of "the
        // boys" counts once), in first-seen order.
        var byID: [UUID: ArchivistPresenceExecutor.DatedMatch] = [:]
        var seen: [UUID] = []
        for query in queries {
            let found = try await detached {
                ArchivistPresenceExecutor.datedMatches(query, records: records)
            }
            for match in found where byID[match.citation.recordID] == nil {
                byID[match.citation.recordID] = match
                seen.append(match.citation.recordID)
            }
        }
        let all = seen.compactMap { byID[$0] }
        let newestFirst = request.order == .newestFirst
        let dated = all.filter { $0.date != nil }.sorted { lhs, rhs in
            guard let a = lhs.date, let b = rhs.date else { return false }
            if a != b { return newestFirst ? a > b : a < b }
            return lhs.citation.filename.localizedStandardCompare(rhs.citation.filename) == .orderedAscending
        }
        let undated = all.count - dated.count
        let endWord = newestFirst ? "newest" : "oldest"
        let description = "\(scopeText) sorted \(endWord) first"

        var basisParts: [String] = []
        if let note = intent.refinementNote { basisParts.append(note) }
        basisParts.append(contentsOf: notes)
        func basis(_ tail: String) -> String {
            "Basis: " + (basisParts + [tail]).joined(separator: "; ") + "."
        }

        guard !all.isEmpty else {
            return Result(
                route: route, outcome: .declined,
                prose: "Nothing matched \(scopeText), so there's no \(endWord) one to pick.",
                basisLine: basis("no matching catalog evidence"),
                queryDescription: description, citations: [], catalogPersonName: nil,
                matchCount: 0)
        }
        guard !dated.isEmpty else {
            return Result(
                route: route, outcome: .declined,
                prose: "\(all.count) matched \(scopeText), but none of them has a date I can put in order.",
                basisLine: basis("\(all.count) matched; none dated"),
                queryDescription: description, citations: [], catalogPersonName: nil,
                matchCount: all.count)
        }
        let index = max(1, request.ordinal) - 1
        guard dated.indices.contains(index) else {
            return Result(
                route: route, outcome: .declined,
                prose: "Only \(dated.count) of those \(dated.count == 1 ? "has" : "have") a date, so there's no \(ordinalWord(request.ordinal)) \(endWord) one.",
                basisLine: basis("\(all.count) matched, \(dated.count) dated; position \(request.ordinal) is past the end"),
                queryDescription: description, citations: [], catalogPersonName: nil,
                matchCount: dated.count)
        }

        let pick = dated[index]
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let year = pick.date.map { utc.component(.year, from: $0) }
        let countText = all.count == 1 ? "the one match" : "the \(all.count) matches"
        var prose: String
        if dated.count > 1, dated.first?.date == dated.last?.date, let year {
            // Every match carries the same date (a year-only 1994 for
            // "videos from 1994"): there is no newest among them, and
            // saying so beats picking one by filename in silence.
            // Name the file at the ordinal the reader asked for, and say
            // which it is: "the second by name" — the nightly reviewer
            // (2026-09-02) caught this sentence calling dated[index] "first".
            let byName = index == 0
                ? "first by name is \(pick.citation.filename)"
                : "\(ordinalWord(index + 1)) by name is \(pick.citation.filename)"
            prose = "The \(dated.count) matches for \(scopeText) are all dated \(year) and nothing finer, "
                + "so there's no \(endWord) among them — \(byName)."
        } else {
            let which = request.ordinal <= 1 ? "The \(endWord)" : "The \(ordinalWord(request.ordinal)) \(endWord)"
            prose = "\(which) of \(countText) for \(scopeText) is \(pick.citation.filename)"
                + (year.map { " (\($0))" } ?? "") + "."
        }
        if undated > 0 {
            prose += " (\(undated) undated \(undated == 1 ? "file isn't" : "files aren't") in that order.)"
        }
        let citations = normalize(Array(dated.prefix(ArchivistPresenceExecutor.maxCitations)).map(\.citation))
        return Result(
            route: route,
            outcome: .answered,
            prose: prose,
            basisLine: basis(
                "\(all.count) matched; ordered by the Catalog's resolved date, else a year in the path "
                + "(never a file or transcode stamp); \(undated) undated set aside; "
                + "the first \(citations.count) are listed in that order"),
            queryDescription: description,
            citations: citations,
            catalogPersonName: nil,
            matchCount: dated.count,
            answerPlan: HallieAnswerPlan(route: route, shape: .fixed, fallbackText: prose))
    }

    /// "Donna · 1994", "Dan, Mark, Matt or Timmy", "“guitar” · 1990–1999".
    private static func describe(_ payload: ArchivistQueryAST.Presence, anyOfPeople: Bool) -> String {
        var parts: [String] = []
        let people = (payload.people ?? []).map(ArchivistFollowUpResolver.Chain.capitalized)
        if !people.isEmpty {
            if people.count == 1 {
                parts.append(people[0])
            } else {
                parts.append(people.dropLast().joined(separator: ", ")
                    + (anyOfPeople ? " or " : " and ") + people[people.count - 1])
            }
        }
        let keywords = payload.keywords ?? []
        if !keywords.isEmpty { parts.append(keywords.map { "“\($0)”" }.joined(separator: " ")) }
        if let lower = payload.yearStart ?? payload.yearEnd, let upper = payload.yearEnd ?? payload.yearStart {
            parts.append(lower == upper ? "\(lower)" : "\(lower)–\(upper)")
        }
        if parts.isEmpty, let kind = payload.mediaKind { parts.append(kind.rawValue) }
        return parts.isEmpty ? "that question" : parts.joined(separator: " · ")
    }

    private static func ordinalWord(_ ordinal: Int) -> String {
        let words = ["", "first", "second", "third", "fourth", "fifth", "sixth",
                     "seventh", "eighth", "ninth", "tenth"]
        if ordinal > 0, ordinal < words.count { return words[ordinal] }
        return "\(ordinal)th"
    }
}
