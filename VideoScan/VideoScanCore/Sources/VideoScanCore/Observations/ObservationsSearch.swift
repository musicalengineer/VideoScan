// ObservationsSearch.swift (VideoScanCore/Observations) — ONE search across
// everything the machine observed in a scope (docs/design/file_dossier_view.md
// §II.3): scene captions, transcripts, on-screen text and dates, burned-in
// dates, machine eras (by their decade words and years), people the machine
// found, event names, and the technical readings (the probe's values and
// what they suggest). Never a file name, path, note or any other catalog
// field (§II.0; ObservationsSensorTests and the truth test pin it).
//
// Each hit carries the observation's text, its time in the clip, who said
// it, and the file it came from — no hit without its source. Ordered by
// tier, kind, file name, time; capped (`limit`, `perKind`) and the result
// says when a cap was hit.
//
// Memory: at most `limit` hits (≈ 400 B each; a transcript hit is a
// 220-character window cut in SQL).

import Foundation

public struct ObservationsSearch: Sendable, Equatable {

    public enum Kind: String, Sendable, CaseIterable, Comparable {
        case technical, era, scene, speech, onScreenText, onScreenDate, burnedInDate, person, event

        public var tier: FileDossier.Layer { self == .technical ? .technical : .patterns }

        public var title: String {
            switch self {
            case .technical: return "Technical reading"
            case .era: return "Machine era"
            case .scene: return "Scene caption"
            case .speech: return "Speech"
            case .onScreenText: return "On-screen text"
            case .onScreenDate: return "On-screen date"
            case .burnedInDate: return "Burned-in date"
            case .person: return "Person found"
            case .event: return "Event"
            }
        }

        public static func < (a: Kind, b: Kind) -> Bool {
            (Kind.allCases.firstIndex(of: a) ?? 0) < (Kind.allCases.firstIndex(of: b) ?? 0)
        }

        static func from(_ store: String) -> Kind? {
            switch store {
            case "scene": return .scene
            case "ocrText": return .onScreenText
            case "ocrDate": return .onScreenDate
            case "speech": return .speech
            case "burnedIn": return .burnedInDate
            case "person": return .person
            case "event": return .event
            case "era": return .era
            case "technical": return .technical
            default: return nil
            }
        }
    }

    public struct Hit: Sendable, Equatable, Identifiable {
        public var id: String
        public var kind: Kind
        public var tier: FileDossier.Layer { kind.tier }
        /// The observation (a window around the match for long texts).
        public var text: String
        /// Seconds into the clip; nil when untimed.
        public var at: Double?
        /// Who said it, in words.
        public var source: String
        public var digest: String
        public var recordID: UUID?
        public var filename: String
        public var path: String
        public var removed: Bool

        public init(id: String, kind: Kind, text: String, at: Double?, source: String, digest: String, recordID: UUID?,
                    filename: String, path: String, removed: Bool) {
            self.id = id
            self.kind = kind
            self.text = text
            self.at = at
            self.source = source
            self.digest = digest
            self.recordID = recordID
            self.filename = filename
            self.path = path
            self.removed = removed
        }
    }

    public var query: String
    public var hits: [Hit]
    /// A cap was hit (`limit` in all or `perKind` for one kind).
    public var truncated: Bool
    public var counts: [Kind: Int]

    public init(query: String, hits: [Hit], truncated: Bool, counts: [Kind: Int]) {
        self.query = query
        self.hits = hits
        self.truncated = truncated
        self.counts = counts
    }

    public static let limit = 2_000
    public static let perKind = 500
    /// Distinct probe tuples a technical query may expand into (each is one bounded SQL read).
    public static let tupleCap = 20
    public static let minimumQuery = 2

    // MARK: Search

    /// The query trimmed and lowercased; nil when too short to search.
    public static func normalized(_ raw: String) -> String? {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return q.count >= minimumQuery ? q : nil
    }

    /// `LIKE` needs `%`, `_` and the escape itself escaped.
    static func escapedForLike(_ q: String) -> String {
        q.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    public static func search(reader: any CatalogObservationsReading, scope: ObservationsScope, query raw: String, now: Date,
                              limit: Int = limit, perKind: Int = perKind) throws -> ObservationsSearch {
        guard let q = normalized(raw) else { return ObservationsSearch(query: raw, hits: [], truncated: false, counts: [:]) }
        let parts = [try textHits(reader: reader, scope: scope, query: q, perKind: perKind),
                     try eraHits(reader: reader, scope: scope, query: q, perKind: perKind),
                     try technicalHits(reader: reader, scope: scope, query: q, now: now, perKind: perKind)]
        var hits = parts.flatMap(\.hits)
        var truncated = parts.contains { $0.truncated }
        hits.sort { ($0.kind, $0.filename.lowercased(), $0.at ?? -1, $0.id) < ($1.kind, $1.filename.lowercased(), $1.at ?? -1, $1.id) }
        if hits.count > limit {
            hits = Array(hits.prefix(limit))
            truncated = true
        }
        var counts: [Kind: Int] = [:]
        for h in hits { counts[h.kind, default: 0] += 1 }
        return ObservationsSearch(query: raw, hits: hits, truncated: truncated, counts: counts)
    }

    typealias Part = (hits: [Hit], truncated: Bool)

    /// Texts: captions, transcripts, burned-in dates, people, events (SQL LIKE, bounded per kind).
    static func textHits(reader: any CatalogObservationsReading, scope: ObservationsScope, query q: String, perKind: Int) throws -> Part {
        let rows = try reader.observationTextHits(scope, query: escapedForLike(q), limitPerKind: perKind)
        var perKindCount: [String: Int] = [:]
        for r in rows { perKindCount[r.kind, default: 0] += 1 }
        let hits: [Hit] = rows.compactMap { r in
            guard let kind = Kind.from(r.kind) else { return nil }
            let source: String
            switch kind {
            case .person: source = "face recognition (\(r.by)), unconfirmed"
            case .event: source = "related-score ladder · \(r.by) by you"
            case .burnedInDate: source = "\(MachineEraResolver.modelShortName(by: r.by)) date reader, unconfirmed"
            default: source = r.by
            }
            return hit(r, kind: kind, text: snippet(r.text, around: q), source: source)
        }
        return (hits, perKindCount.values.contains { $0 >= perKind })
    }

    /// Machine eras: the query against each distinct shown value's words and years, then the files of the matching values.
    static func eraHits(reader: any CatalogObservationsReading, scope: ObservationsScope, query q: String, perKind: Int) throws -> Part {
        var matching: [String] = []
        for v in try reader.observationEraVerdicts(scope) where v.found {
            guard let value = v.value, !matching.contains(value), eraMatches(value, query: q) else { continue }
            matching.append(value)
        }
        guard !matching.isEmpty else { return ([], false) }
        let rows = try reader.observationEraHits(scope, values: matching, limit: perKind)
        let hits = rows.map { r in
            hit(r, kind: .era, text: AnalysisResultsReport.eraWords(r.text), source: "\(MachineEraResolver.modelShortName(by: r.by)) era, unconfirmed")
        }
        return (hits, rows.count >= perKind)
    }

    /// Technical readings: the query against each distinct probe tuple's values and interpretation words, then the files of the matching tuples.
    static func technicalHits(reader: any CatalogObservationsReading, scope: ObservationsScope, query q: String, now: Date, perKind: Int) throws -> Part {
        var hits: [Hit] = []
        var matched = 0
        for t in try reader.observationTechnicalTuples(scope) where !t.streamType.isEmpty && t.streamType != "ffprobe failed" {
            guard let line = technicalMatch(t, query: q, now: now) else { continue }
            matched += 1
            if matched > tupleCap { return (hits, true) }
            let rows = try reader.observationTechnicalHits(scope, tuple: t, limit: max(0, perKind - hits.count))
            hits += rows.map { r in hit(r, kind: .technical, text: line, source: ObservationsReport.probe + " · TechnicalReading") }
            if hits.count >= perKind { return (hits, true) }
        }
        return (hits, false)
    }

    static func hit(_ r: CatalogRow.ObservationHitRow, kind: Kind, text: String, source: String) -> Hit {
        Hit(id: "\(kind.rawValue)·\(r.digest)·\(r.seq)·\(r.at ?? -1)·\(r.by)", kind: kind, text: text, at: r.at, source: source, digest: r.digest,
            recordID: r.fileID.flatMap(UUID.init(uuidString:)), filename: r.filename ?? "(no file in the catalog)", path: r.path ?? "", removed: r.removed)
    }

    /// "1991-1995" matches "1990s", "early 90s", "early 1990s", any year in range, or the value itself.
    public static func eraMatches(_ value: String, query q: String) -> Bool {
        guard let r = MachineEraResolver.range(value) else { return value.lowercased().contains(q) }
        if value.contains(q) { return true }
        let era = MachineEra(lo: r.lo, hi: r.hi, by: "", at: 0, seq: 0)
        if MachineEraResolver.searchWords(era: era).contains(where: { $0 == q || $0.hasSuffix(" " + q) || $0 == q + "s" }) { return true }
        if AnalysisResultsReport.eraWords(value).lowercased().contains(q) { return true }
        if let year = Int(q), q.count == 4 { return MachineEraResolver.searchYears(era: era).contains(year) }
        return false
    }

    /// The reading line a tuple matches on ("DV camcorder/deck capture … · Scan: interlaced → analog tape or DV-era video"), or nil.
    public static func technicalMatch(_ t: CatalogRow.ObservationTechnicalTuple, query q: String, now: Date) -> String? {
        let facts = t.facts
        let oneLiner = TechnicalReading.oneLiner(facts)
        if oneLiner.lowercased().contains(q) { return oneLiner }
        for line in TechnicalReading.interpret(facts, now: now) where line.label != "File modified" && line.label != "Creation time" && line.label != "Duration / rate" {
            if line.value.lowercased().contains(q) || line.suggests.lowercased().contains(q) {
                return "\(oneLiner) · \(line.label): \(line.value) → \(line.suggests)"
            }
        }
        return nil
    }

    /// A window of about 160 characters around the first match (the whole text when short).
    public static func snippet(_ text: String, around q: String, width: Int = 160) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard flat.count > width else { return flat }
        guard let range = flat.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { return String(flat.prefix(width)) + "…" }
        let half = width / 2
        let start = flat.index(range.lowerBound, offsetBy: -half, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: half, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }
}
