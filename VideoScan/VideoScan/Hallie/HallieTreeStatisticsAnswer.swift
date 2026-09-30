// HallieTreeStatisticsAnswer.swift
// The prose for a spreadsheet question about the tree. Every number states
// its denominator and everything that fell out of the measurement, because
// the engine hands those over and this layer is not allowed to drop them.
//
//   "how many people in the tree were born in England?"
//   → "11,280 of the 16,383 people in the tree have a recorded birthplace in
//      England. 1,172 have no birthplace recorded, so they could not be
//      counted either way."
//
// Rick asked that twice on 2026-09-07 and got "49 people named England".

import Foundation
import VideoScanCore

extension HallieLineageAnswer {

    static func treeStatistics(_ ask: HallieTreeStatisticsQuestion,
                               context: HallieTurnExecutor.Context) -> Result {
        guard let graph = context.graph else { return noTree(context) }
        var query = ask.query
        var notes: [String] = []

        // "my ancestors" needs the owner's record. Resolved through the same
        // owner chain every other route uses; an owner the tree cannot pin
        // gets that route's own decline rather than a silent whole-tree count.
        if case .ancestors(_, let depth) = query.scope {
            switch resolve(nil, context: context, graph: graph) {
            case .failure(let r):
                // `resolve` hands back the decline it composed, or nil when it
                // simply has no owner to work from — say which, never count
                // the whole tree as "your ancestors".
                return r ?? Result(
                    route: .graph, outcome: .declined,
                    prose: "I can’t tell whose ancestors to count — set the owner in Settings ▸ Archivist and ask again.",
                    basisLine: ArchivistBiographyPolicy.gedcomBasis + " No owner record could be pinned; nothing was counted.",
                    queryDescription: "tree statistics: owner unresolved",
                    citations: [], catalogPersonName: nil)
            case .success(let owner, let note):
                query.scope = .ancestors(of: owner.id, maxGenerations: depth)
                if let note { notes.append(note) }
                notes.append("Counted over \(owner.name)'s recorded ancestors, not the whole tree.")
            }
        }

        // The population phrase, built once so every sentence reads the same:
        // "the 16,383 people in the tree" or "your 13,406 recorded ancestors".
        // (The first build said "1 of the 6 the people in the tree".)
        func population(_ n: Int) -> String {
            if case .ancestors = query.scope { return "your \(Self.spoken(n)) recorded ancestors" }
            return "the \(Self.spoken(n)) people in the tree"
        }
        let placeWords = Self.placeWords(query.place)
        let timeWords = Self.timeWords(query.time)
        let filterWords = [placeWords, timeWords].compactMap { $0 }.joined(separator: " ")

        let sentence: String
        switch ask {
        case .count:
            let c = TreeStatistics.count(query, in: graph)
            if c.considered == 0 {
                sentence = "There is nobody to count — \(population(0)) is empty."
            } else if c.matched == 0 {
                sentence = "None of \(population(c.considered)) were born \(filterWords)."
                    + Self.gapSentence(c)
            } else {
                sentence = "\(Self.spoken(c.matched)) of \(population(c.considered)) "
                    + " were born \(filterWords)."
                    + Self.gapSentence(c)
            }
        case .lifespan:
            guard let s = TreeStatistics.lifespan(query, in: graph) else {
                sentence = "I can't work out a lifespan — none of \(population(TreeStatistics.count(query, in: graph).considered)) \(filterWords) have both a birth and a death year recorded."
                break
            }
            sentence = "Across the \(Self.spoken(s.count)) of \(population(s.considered)) \(filterWords) with both a birth and a death year, "
                + "the average lifespan is \(Self.spoken(s.mean)) years and the median \(Self.spoken(s.median)); "
                + "the shortest recorded life is \(s.minimum) and the longest \(s.maximum)."
                + (s.unrecorded > 0
                   ? " \(Self.spoken(s.unrecorded)) more lack one of the two years and are not in the figure."
                   : "")
        case .birthCountries:
            let r = TreeStatistics.birthCountries(query, in: graph)
            if r.rows.isEmpty {
                sentence = "No recorded birthplaces among \(population(TreeStatistics.count(query, in: graph).considered)) \(filterWords) could be read as a country."
            } else {
                let top = r.rows.prefix(8).map { "\($0.country) (\(Self.spoken($0.count)))" }
                sentence = "Birth countries among \(population(TreeStatistics.count(query, in: graph).considered)) \(filterWords), commonest first: "
                    + top.joined(separator: ", ")
                    + (r.rows.count > 8 ? ", and \(r.rows.count - 8) more." : ".")
                    + (r.unrecorded > 0 ? " \(Self.spoken(r.unrecorded)) have no birthplace recorded." : "")
                    + (r.ambiguous > 0 ? " \(Self.spoken(r.ambiguous)) were born under a historical name that spans today's borders and are listed nowhere." : "")
            }
        }

        let basis = ArchivistBiographyPolicy.gedcomBasis
            + " Counted over recorded fields only; every figure names the population it was drawn from and how many records lacked the field."
            + (notes.isEmpty ? "" : " " + notes.joined(separator: " "))
        return Result(
            route: .graph, outcome: .answered,
            prose: sentence.replacingOccurrences(of: "  ", with: " "),
            basisLine: basis,
            queryDescription: "tree statistics: \(ask)",
            citations: [], catalogPersonName: nil)
    }

    // MARK: - Words

    private static func gapSentence(_ c: TreeStatistics.Count) -> String {
        var parts: [String] = []
        if c.unrecorded > 0 {
            parts.append("\(spoken(c.unrecorded)) have no \(c.unrecorded == 1 ? "record" : "records") of the field asked about, so they could not be counted either way")
        }
        if c.unclassifiable > 0 {
            parts.append("\(spoken(c.unclassifiable)) have a birthplace that could not be placed in a country — an unknown name, or one that spanned today's borders")
        }
        return parts.isEmpty ? "" : " " + parts.joined(separator: "; ") + "."
    }

    private static func placeWords(_ place: TreeStatistics.PlaceFilter) -> String? {
        switch place {
        case .anywhere: return nil
        case .country(let c): return "in \(c)"
        case .continent(let c): return "in \(c.rawValue)"
        case .outsideCountry(let c):
            return "outside \(c == BirthplaceClassifier.unitedStates ? "the United States" : c)"
        case .recordedText(let t): return "in a place recorded as \(t.capitalized)"
        }
    }

    private static func timeWords(_ time: TreeStatistics.TimeFilter) -> String? {
        switch (time.bornFrom, time.bornTo) {
        case (nil, nil): return nil
        case let (from?, to?) where from == to: return "in \(from)"
        case let (from?, to?): return "between \(from) and \(to)"
        case let (from?, nil): return "after \(from - 1)"
        case let (nil, to?): return "before \(to + 1)"
        }
    }

    private static let grouping: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    static func spoken(_ n: Int) -> String {
        grouping.string(from: NSNumber(value: n)) ?? String(n)
    }

    static func spoken(_ x: Double) -> String {
        let rounded = (x * 10).rounded() / 10
        return rounded == rounded.rounded() ? spoken(Int(rounded)) : String(format: "%.1f", rounded)
    }
}
