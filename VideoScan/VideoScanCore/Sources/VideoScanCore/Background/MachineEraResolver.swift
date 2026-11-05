// MachineEraResolver.swift (VideoScanCore/Background) — background service
// step 1, item 8: what the app SHOWS of the era job's observations.
//
// One sentence: from one content's `provenance_assertions` rows, the newest
// `era.fused` row per `by` becomes a `MachineEra` (the range, who said it,
// the model's short name, when, and the evidence a tooltip names — windows
// and frame times); three pure rules sit beside it, each tested on its
// boundaries:
//   * `closeEnough(era:rickYear:)` — the review page's rule, in its words:
//     the range's midpoint within 5 years of Rick's year AND the range at
//     most 10 years wide;
//   * `searchWords(era:)` — the decade words a person types ("1990s",
//     "90s", "early 90s"), never the technical form (DECISIONS 2026-11-01
//     "Observations serve two uses, and both are in human words");
//   * `convergence(...)` — the Catalog Status count "N of M close enough".
//
// By ruling (DECISIONS 2026-11-01 "Observations are never shown as a
// date") a machine era is its own line, "unconfirmed", and never a date:
// nothing here feeds `inferred_dates`, the triangulator or a filter. The
// `confidence` column is never read (events_design rule 9).
//
// Which rows count: `state = 'inferred'`, `by` a machine signer
// ("machine:<approach id>@r<rev>"), the value "<lo>-<hi>" with lo ≤ hi.
// A later `rejected` row on the same value (Rick's veto, the v14 trigger's
// partner) hides that `by`'s era — the line never shows what Rick refused.
//
// Memory: a MachineEra is ~300 B (frame times capped at `frameTimeCap`);
// the bulk read streams one subject at a time, so the cache is the only
// O(contents) structure — 100k eras ≈ 30 MB worst case, the corpus
// (~15k video contents) ≈ 5 MB.
//
// (For Rick: a pure reducer — rows in, a value struct out — plus three free
// functions; a C++ codebase would put them in one header with no state.)

import Foundation

/// One machine's file-level era for one content.
public struct MachineEra: Sendable, Equatable {
    public let lo: Int
    public let hi: Int
    /// The signer, verbatim: "machine:<approach id>@r<rev>".
    public let by: String
    /// "8B" — the model segment's parameter size (`modelShortName(by:)`).
    public let modelShortName: String
    /// Unix seconds the job observed it (the row's `at`).
    public let at: Int64
    /// The fused row's seq (newest wins per `by`).
    public let seq: Int64
    /// The windows that answered (seconds into the file), from the fused row.
    public let windows: [ClosedRange<Double>]
    /// The windows the fused range came from (the evidence's count).
    public let windowCount: Int
    /// The frames the model saw (seconds), from the run's window rows; at most `frameTimeCap`.
    public let frameTimesS: [Double]
    /// How many frame times the run's window rows named in all.
    public let frameCount: Int
    /// On-screen years the stamp reader cited (bench.py burned_in_years).
    public let burnedInYears: [Int]

    public init(lo: Int, hi: Int, by: String, at: Int64, seq: Int64, windows: [ClosedRange<Double>] = [], windowCount: Int = 0,
                frameTimesS: [Double] = [], frameCount: Int? = nil, burnedInYears: [Int] = []) {
        self.lo = lo
        self.hi = hi
        self.by = by
        self.modelShortName = MachineEraResolver.modelShortName(by: by)
        self.at = at
        self.seq = seq
        self.windows = windows
        self.windowCount = windowCount
        self.frameTimesS = Array(frameTimesS.prefix(MachineEraResolver.frameTimeCap))
        self.frameCount = frameCount ?? frameTimesS.count
        self.burnedInYears = burnedInYears
    }

    public var midpoint: Double { Double(lo + hi) / 2 }
    public var width: Int { hi - lo }
    /// "1991–1995", or "1993" for a one-year range.
    public var rangeText: String { lo == hi ? "\(lo)" : "\(lo)–\(hi)" }
}

/// "Machine era agrees with your confirmed date within 5 y: N of M (p %)".
public struct MachineEraConvergence: Sendable, Equatable {
    /// Contents with both Rick's confirmed date and a fused machine era.
    public var total: Int
    /// Of those, the ones `closeEnough`.
    public var agree: Int

    public init(total: Int, agree: Int) {
        self.total = total
        self.agree = agree
    }

    public var percent: Int { total == 0 ? 0 : Int((Double(agree) * 100 / Double(total)).rounded()) }
}

public enum MachineEraResolver {

    public static let fusedField = "era.fused"
    public static let windowField = "era.yearRange"
    /// The two fields the bulk read asks for.
    public static let fields = [fusedField, windowField]
    public static let frameTimeCap = 24
    /// "close enough" (the review page, STATUS 11/01): midpoint within this many years …
    public static let closeEnoughYears = 5.0
    /// … AND a range at most this wide.
    public static let closeEnoughMaxWidth = 10
    /// A range wider than this names its decade only, never "early/mid/late".
    public static let thirdMaxWidth = 5

    // MARK: Rows → eras

    /// The newest fused era per `by` among one content's rows, newest
    /// (highest seq) first; [] when no machine fused row survives.
    public static func eras(fromRowsOfOneSubject rows: [CatalogRow.ProvenanceAssertionReading]) -> [MachineEra] {
        var newest: [String: CatalogRow.ProvenanceAssertionReading] = [:]
        for row in rows where row.field == fusedField && row.state == "inferred" && isMachine(row.by) && range(row.value) != nil {
            if let kept = newest[row.by], kept.seq > row.seq { continue }
            newest[row.by] = row
        }
        return newest.values
            .filter { fused in !isRejected(fused, among: rows) }
            .sorted { $0.seq > $1.seq }
            .compactMap { era(fused: $0, windows: rows) }
    }

    /// Every content's eras, from ONE streamed query (the cache's fill).
    /// Keys are `content.digest`'s spelling (64 lowercase hex).
    public static func eras(in reader: any CatalogProvenanceAssertionReading) throws -> [String: [MachineEra]] {
        var out: [String: [MachineEra]] = [:]
        try reader.forEachProvenanceAssertionSubject(subjectKind: ProvenanceAssertionSubject.content, fields: fields) { subject, rows in
            let found = eras(fromRowsOfOneSubject: rows)
            if !found.isEmpty { out[subject] = found }
        }
        return out
    }

    /// The years an era may name. `range` and `eraValueSQL` both read it:
    /// one rule for "is this an era" in Swift and in SQL (rule 4).
    public static let yearBounds = 1800...2200

    /// "1991-1995" → (1991, 1995); nil unless two 4-digit years in
    /// `yearBounds`, lo ≤ hi — exactly what `eraValueSQL` accepts.
    public static func range(_ value: String) -> (lo: Int, hi: Int)? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.utf8.count == 4 && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let lo = Int(parts[0]), let hi = Int(parts[1]), lo <= hi,
              yearBounds.contains(lo), yearBounds.contains(hi) else { return nil }
        return (lo, hi)
    }

    /// The SQL twin of `range(_:) != nil` for a value column ("value",
    /// "a.value"): two 4-digit years in `yearBounds`, lo ≤ hi. The Results
    /// sheet's "Era found" uses it, so it can never count an era the
    /// inspector, search or Catalog Status refuse.
    public static func eraValueSQL(_ column: String) -> String {
        let lo = "CAST(substr(\(column), 1, 4) AS INTEGER)", hi = "CAST(substr(\(column), 6, 4) AS INTEGER)"
        return "(\(column) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]' AND \(lo) <= \(hi)"
            + " AND \(lo) BETWEEN \(yearBounds.lowerBound) AND \(yearBounds.upperBound)"
            + " AND \(hi) BETWEEN \(yearBounds.lowerBound) AND \(yearBounds.upperBound))"
    }

    // MARK: Rick's veto — ONE rule, a Swift form and its SQL twin

    /// Rick rejected `row` afterwards: a `rejected` row on the same field and
    /// value with a higher seq, among one subject's `rows`. The resolver, the
    /// dossier and (through `rejectedLaterSQL`) the Results sheet all ask this.
    public static func isRejected(_ row: CatalogRow.ProvenanceAssertionReading,
                                  among rows: [CatalogRow.ProvenanceAssertionReading]) -> Bool {
        rows.contains { $0.field == row.field && $0.state == "rejected" && $0.value == row.value && $0.seq > row.seq }
    }

    /// The SQL twin of `isRejected` for an assertion row aliased `alias`
    /// (subject_kind, subject_id, field, value, seq columns). Codex 11/05: the
    /// Results sheet classified without it and listed a vetoed era as found.
    public static func rejectedLaterSQL(_ alias: String) -> String {
        "EXISTS (SELECT 1 FROM provenance_assertions rj WHERE rj.subject_kind = \(alias).subject_kind"
            + " AND rj.subject_id = \(alias).subject_id AND rj.field = \(alias).field AND rj.state = 'rejected'"
            + " AND rj.value = \(alias).value AND rj.seq > \(alias).seq)"
    }

    static func isMachine(_ by: String) -> Bool { by.hasPrefix("machine:") && by.count > "machine:".count }

    private static func era(fused: CatalogRow.ProvenanceAssertionReading, windows rows: [CatalogRow.ProvenanceAssertionReading]) -> MachineEra? {
        guard let r = range(fused.value) else { return nil }
        let evidence = object(fused.evidenceJSON)
        let windows = (evidence["windows"] as? [[Double]] ?? []).compactMap { w in w.count == 2 && w[0] <= w[1] ? w[0]...w[1] : nil }
        let count = evidence["validEraWindows"] as? Int ?? windows.count
        // The same run's window rows (same by, same at) name the frames.
        var frames: [Double] = []
        for row in rows where row.field == windowField && row.by == fused.by && row.at == fused.at {
            frames += object(row.evidenceJSON)["frameTimesS"] as? [Double] ?? []
        }
        let unique = Array(Set(frames)).sorted()
        return MachineEra(lo: r.lo, hi: r.hi, by: fused.by, at: fused.at, seq: fused.seq, windows: windows, windowCount: count,
                          frameTimesS: unique, frameCount: unique.count, burnedInYears: evidence["burnedInYears"] as? [Int] ?? [])
    }

    /// An assertion's evidence JSON as an object; [:] for anything else
    /// (shared with FileDossier's lines, one parser for one column).
    static func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    /// "machine:qwen3-vl-8b-4bit/era-v1/window-60s@r3" → "8B": the model
    /// segment (before the first "/") minus "machine:" and "@r…", and in it
    /// the token that is a parameter count ("8b", "32b", "1.5b"). No such
    /// token → the model segment itself (never empty).
    public static func modelShortName(by: String) -> String {
        var text = by.hasPrefix("machine:") ? String(by.dropFirst("machine:".count)) : by
        if let at = text.range(of: "@r", options: .backwards) { text = String(text[..<at.lowerBound]) }
        let model = String(text.split(separator: "/", maxSplits: 1).first ?? Substring(text))
        for token in model.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }) where token.count >= 2 && token.hasSuffix("b") {
            let number = token.dropLast()
            if Double(number) != nil, number.first?.isNumber == true { return String(number) + "B" }
        }
        return model.isEmpty ? by : model
    }

    // MARK: The three rules

    /// The review page's "close enough": the era's midpoint within 5 years
    /// of Rick's year (inclusive) AND the era at most 10 years wide.
    public static func closeEnough(era: MachineEra, rickYear: Int) -> Bool {
        abs(era.midpoint - Double(rickYear)) <= closeEnoughYears && era.width <= closeEnoughMaxWidth
    }

    /// Rick's year from his saved date ("1992", "1992-06", "1992-06-14"); nil otherwise.
    public static func rickYear(_ userDate: String?) -> Int? {
        guard let userDate, let canonical = UserDateEntry.canonicalize(userDate) else { return nil }
        return Int(canonical.prefix(4))
    }

    /// The decade words a person types for this era — one set per decade the
    /// range touches: "1990s", "90s" (the short form for 1910–1990), and,
    /// when the range sits inside one decade and is at most 5 years wide
    /// (`thirdMaxWidth`), the third its MIDPOINT falls in — ≤ x3.5 early,
    /// < x6.5 mid, else late — as "early 90s" / "early 1990s". So 1991–1995
    /// (midpoint 1993) is "early 90s", 1994–1996 "mid 90s", 1965 "mid 60s",
    /// 1990–1999 no third at all. Never the range, the field, the signer or
    /// the digest.
    public static func searchWords(era: MachineEra) -> [String] {
        var out: [String] = []
        let first = decade(era.lo), last = decade(era.hi)
        for d in stride(from: first, through: last, by: 10) {
            let short = (1910...1990).contains(d) ? "\(d % 100)s" : nil
            out.append("\(d)s")
            if let short { out.append(short) }
            if first == last, era.width <= thirdMaxWidth, let third = third(midpointInDecade: era.midpoint - Double(d)) {
                if let short { out.append("\(third) \(short)") }
                out.append("\(third) \(d)s")
            }
        }
        return out
    }

    /// The years a year token ("1990s", "year:1993") matches: the range itself.
    public static func searchYears(era: MachineEra) -> ClosedRange<Int> { era.lo...era.hi }

    private static func decade(_ year: Int) -> Int { year - ((year % 10) + 10) % 10 }

    /// "early" / "mid" / "late" for a midpoint 0 ≤ m < 10 years into its decade.
    private static func third(midpointInDecade m: Double) -> String? {
        if m <= 3.5 { return "early" }
        if m < 6.5 { return "mid" }
        return "late"
    }

    /// N of M over contents with BOTH Rick's confirmed year and an era (the
    /// newest era of each); nil when M = 0 (the line is absent, never "0 of 0").
    public static func convergence(eras: [String: [MachineEra]], rickYears: [String: Int]) -> MachineEraConvergence? {
        var c = MachineEraConvergence(total: 0, agree: 0)
        for (digest, year) in rickYears {
            guard let era = eras[digest]?.first else { continue }
            c.total += 1
            if closeEnough(era: era, rickYear: year) { c.agree += 1 }
        }
        return c.total == 0 ? nil : c
    }

    // MARK: The words (pure; the inspector and Catalog Status read them)

    /// "Machine era: 1991–1995 · 8B, unconfirmed", and when Rick's year is
    /// known and the era is not close enough, "— disagrees with your date".
    public static func inspectorLine(era: MachineEra, rickYear: Int?) -> String {
        var line = "Machine era: \(era.rangeText) · \(era.modelShortName), unconfirmed"
        if let rickYear, !closeEnough(era: era, rickYear: rickYear) { line += " — disagrees with your date" }
        return line
    }

    /// The tooltip: what the model saw and who said it.
    public static func inspectorHelp(era: MachineEra, others: [MachineEra] = []) -> String {
        var parts: [String] = []
        parts.append("What the \(era.modelShortName) model guessed from the pictures alone (no file dates, no folder names). It is not a date and files nothing; your date always wins.")
        let windows = era.windows.map { "\(seconds($0.lowerBound))–\(seconds($0.upperBound))" }
        parts.append("Windows: \(era.windowCount)" + (windows.isEmpty ? "" : " (" + windows.joined(separator: ", ") + ")") + ".")
        if era.frameCount > 0 {
            let shown = era.frameTimesS.map(seconds).joined(separator: ", ")
            let more = era.frameCount > era.frameTimesS.count ? ", … \(era.frameCount - era.frameTimesS.count) more" : ""
            parts.append("Frames: \(era.frameCount) at \(shown)\(more).")
        }
        if !era.burnedInYears.isEmpty { parts.append("On-screen years read: \(era.burnedInYears.map(String.init).joined(separator: ", ")).") }
        parts.append("By \(era.by), \(Self.day(era.at)).")
        for other in others { parts.append("Also: \(other.rangeText) by \(other.by), \(Self.day(other.at)).") }
        return parts.joined(separator: " ")
    }

    /// "Machine era agrees with your confirmed date within 5 y: 3 of 4 (75 %)".
    public static func statusLine(_ c: MachineEraConvergence) -> String {
        "Machine era agrees with your confirmed date within 5 y: \(c.agree.formatted()) of \(c.total.formatted()) (\(c.percent) %)"
    }

    private static func seconds(_ s: Double) -> String {
        let whole = Int(s.rounded())
        return whole >= 60 ? String(format: "%d:%02d", whole / 60, whole % 60) : "\(whole) s"
    }

    private static func day(_ at: Int64) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(at)))
    }
}
