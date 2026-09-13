// HallieTurnExecutor+DateOrdered.swift
// "and the newest?" / "the most recent one?" / "ok show me the second one"
// after a count or an age (eval cc007, cs015, tm009, 2026-09-01), and —
// since design §3.5 step 5 — "play the longest video in the archive" /
// "what's the biggest file in the collection" (eval cs030). A count
// answer and an age answer still carry the question they counted or
// measured (ConversationMemory.lastRefinable); this re-runs it over EVERY
// matching record, orders by the asked-for key (date, running time or
// size on disk), and names the asked-for one. The ordered list (first 25)
// becomes the answer's citations so "show me the second one" afterwards
// is the second in THAT order.
//
// Memory: one DatedMatch per proven match (a citation plus three optional
// scalars), so a 100,000-record catalog is ~100k small structs for the
// duration of the turn — tens of MB at the very worst, freed on return.

import Foundation
import VideoScanCore

extension HallieTurnExecutor {

    static func executeOrdered(
        _ effective: ArchivistQueryAST.Presence,
        order request: OrderRequest,
        route: Route,
        intent: Intent,
        notes: [String],
        context: Context
    ) async throws -> Result {
        let records = context.presenceRecords
        let aliases = presenceAliases(for: effective.people ?? [], context: context)
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
                    return ArchivistPresenceQuery(single, aliases: aliases)
                }
            } else {
                queries = [ArchivistPresenceQuery(effective, aliases: aliases)]
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
        let order = request.order
        let key = order.key
        let (keyed, unkeyed) = ordered(all, by: order)
        let endWord = order.word
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
        guard !keyed.isEmpty else {
            let noneWith: String
            switch key {
            case .date: noneWith = "none dated"
            case .duration: noneWith = "none with a running time"
            case .size: noneWith = "none with a size"
            }
            return Result(
                route: route, outcome: .declined,
                prose: "\(all.count) matched \(scopeText), but none of them has a \(keyNoun(key)) I can put in order.",
                basisLine: basis("\(all.count) matched; \(noneWith)"),
                queryDescription: description, citations: [], catalogPersonName: nil,
                matchCount: all.count)
        }
        let index = max(1, request.ordinal) - 1
        guard keyed.indices.contains(index) else {
            let counted = key == .date ? "\(keyed.count) dated" : "\(keyed.count) with a \(keyNoun(key))"
            return Result(
                route: route, outcome: .declined,
                prose: "Only \(keyed.count) of those \(keyed.count == 1 ? "has" : "have") a \(keyNoun(key)), so there's no \(ordinalWord(request.ordinal)) \(endWord) one.",
                basisLine: basis("\(all.count) matched, \(counted); position \(request.ordinal) is past the end"),
                queryDescription: description, citations: [], catalogPersonName: nil,
                matchCount: keyed.count)
        }

        let pick = keyed[index]
        let countText = all.count == 1 ? "the one match" : "the \(all.count) matches"
        let allTheSame = keyed.count > 1 && sortKey(of: keyed[0], for: key) == sortKey(of: keyed[keyed.count - 1], for: key)
        // Name the file at the ordinal the reader asked for, and say which
        // it is: "the second by name" — the nightly reviewer (2026-09-02)
        // caught this sentence calling keyed[index] "first".
        let byName = index == 0
            ? "first by name is \(pick.citation.filename)"
            : "\(ordinalWord(index + 1)) by name is \(pick.citation.filename)"
        var prose: String
        switch key {
        case .date:
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(secondsFromGMT: 0)!
            let year = pick.date.map { utc.component(.year, from: $0) }
            if allTheSame, let year {
                // Every match carries the same date (a year-only 1994 for
                // "videos from 1994"): there is no newest among them, and
                // saying so beats picking one by filename in silence.
                prose = "The \(keyed.count) matches for \(scopeText) are all dated \(year) and nothing finer, "
                    + "so there's no \(endWord) among them — \(byName)."
            } else {
                let which = request.ordinal <= 1 ? "The \(endWord)" : "The \(ordinalWord(request.ordinal)) \(endWord)"
                prose = "\(which) of \(countText) for \(scopeText) is \(pick.citation.filename)"
                    + (year.map { " (\($0))" } ?? "") + "."
            }
        case .duration, .size:
            let value = valueText(of: pick, for: key)
            if allTheSame {
                prose = "The \(keyed.count) matches for \(scopeText) are all the same \(keyNoun(key))"
                    + (value.map { " (\($0))" } ?? "")
                    + ", so there's no \(endWord) among them — \(byName)."
            } else {
                let which = request.ordinal <= 1 ? "The \(endWord)" : "The \(ordinalWord(request.ordinal)) \(endWord)"
                prose = "\(which) of \(countText) for \(scopeText) is \(pick.citation.filename)"
                    + (value.map { " (\($0))" } ?? "") + "."
            }
        }
        if unkeyed > 0 {
            switch key {
            case .date:
                prose += " (\(unkeyed) undated \(unkeyed == 1 ? "file isn't" : "files aren't") in that order.)"
            case .duration, .size:
                prose += " (\(unkeyed) \(unkeyed == 1 ? "file" : "files") with no \(keyNoun(key)) "
                    + "\(unkeyed == 1 ? "isn't" : "aren't") in that order.)"
            }
        }
        let citations = normalize(Array(keyed.prefix(ArchivistPresenceExecutor.maxCitations)).map(\.citation))
        let orderedBy: String
        switch key {
        case .date:
            orderedBy = "ordered by the Catalog's resolved date, else a year in the path "
                + "(never a file or transcode stamp); \(unkeyed) undated set aside"
        case .duration:
            orderedBy = "ordered by the Catalog's probed running time; \(unkeyed) without one set aside"
        case .size:
            orderedBy = "ordered by the file's size on disk; \(unkeyed) without one set aside"
        }
        return Result(
            route: route,
            outcome: .answered,
            prose: prose,
            basisLine: basis(
                "\(all.count) matched; \(orderedBy); "
                + "the first \(citations.count) are listed in that order"),
            queryDescription: description,
            citations: citations,
            catalogPersonName: nil,
            matchCount: keyed.count,
            answerPlan: HallieAnswerPlan(route: route, shape: .fixed, fallbackText: prose))
    }

    /// The matches that carry the requested key, sorted with the asked-for
    /// end first and ties broken by path (deterministic whatever order the
    /// catalog handed them over in), plus how many carry no key at all.
    /// Pure; the scale sensor calls it directly with 100k matches.
    static func ordered(
        _ all: [ArchivistPresenceExecutor.DatedMatch],
        by order: OrderRequest.Order
    ) -> (keyed: [ArchivistPresenceExecutor.DatedMatch], unkeyed: Int) {
        let key = order.key
        // Pair each match with its key once; the comparator must not
        // recompute it n·log n times.
        let pairs: [(match: ArchivistPresenceExecutor.DatedMatch, key: Double)] = all.compactMap { match in
            sortKey(of: match, for: key).map { (match, $0) }
        }
        let descending = order.descending
        let sorted = pairs.sorted { lhs, rhs in
            if lhs.key != rhs.key { return descending ? lhs.key > rhs.key : lhs.key < rhs.key }
            return lhs.match.citation.fullPath
                .localizedStandardCompare(rhs.match.citation.fullPath) == .orderedAscending
        }
        return (sorted.map(\.match), all.count - pairs.count)
    }

    private static func sortKey(
        of match: ArchivistPresenceExecutor.DatedMatch,
        for key: OrderRequest.Order.Key
    ) -> Double? {
        switch key {
        case .date: return match.date?.timeIntervalSinceReferenceDate
        case .duration: return match.durationSeconds
        case .size: return match.sizeBytes.map(Double.init)
        }
    }

    /// "date" / "running time" / "size" — the noun the prose uses.
    private static func keyNoun(_ key: OrderRequest.Order.Key) -> String {
        switch key {
        case .date: return "date"
        case .duration: return "running time"
        case .size: return "size"
        }
    }

    /// "1h 12m 05s" / "1.2 GB" for the picked file; nil for the date key
    /// (the year is rendered by the caller) or a missing value.
    private static func valueText(
        of match: ArchivistPresenceExecutor.DatedMatch,
        for key: OrderRequest.Order.Key
    ) -> String? {
        switch key {
        case .date:
            return nil
        case .duration:
            return match.durationSeconds.map(durationText)
        case .size:
            return match.sizeBytes.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            }
        }
    }

    /// "1h 12m 05s", "12m 05s", "45s".
    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, s) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }

    /// "Donna · 1994", "Dan, Mark, Matt or Timmy", "“guitar” · 1990–1999",
    /// "every video in the catalog".
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
        if parts.isEmpty, let kind = payload.mediaKind { parts.append("every \(kind.rawValue) in the catalog") }
        return parts.isEmpty ? "that question" : parts.joined(separator: " · ")
    }

    private static func ordinalWord(_ ordinal: Int) -> String {
        let words = ["", "first", "second", "third", "fourth", "fifth", "sixth",
                     "seventh", "eighth", "ninth", "tenth"]
        if ordinal > 0, ordinal < words.count { return words[ordinal] }
        return "\(ordinal)th"
    }
}
