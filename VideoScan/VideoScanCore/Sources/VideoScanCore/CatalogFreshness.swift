// CatalogFreshness.swift (VideoScanCore)
// THE rule for "is what the catalog knows current?" (Rick 2026-10-16,
// docs/design/catalog_status_freshness_2026_10_16.md §3).
//
// Every knowledge kind the Analyze panel lists (Full Hashes, Sound Prints,
// File Presence, the metadata cyclers) reports ONE FreshnessRow: how many
// rows it should cover, how many it has, when it last finished, how that
// went, and whether something is waiting on a person. This file turns a
// row into a colour and a sentence, and a set of rows into the summary
// band at the top of the panel. The colour answers one question — do I
// need to look, or just click?
//
//   green   current — every eligible row stamped, last pass within cadence
//   yellow  a run fixes it — the Run button is the answer
//   red     a person has to look — Update alone cannot fix it
//   grey    not asked — everything eligible is on drives that aren't mounted
//
// Precedence: red beats yellow beats green; grey only when nothing else
// applies. "Way out of date" stays yellow: the button fixes it. Red is
// reserved for known bad (a failed pass, a sidecar that won't open) or a
// decision (rows pointing at nothing, waiting for Fix Links).
//
// Pure: plain values in, values out. `now` is injected; nothing here reads
// the clock, the catalog, or the disk. The calendar and the digit-grouping
// separator are injected too (FreshnessWording) so the words are
// deterministic under test. Worst-case memory: one small struct per row,
// O(rows); the registry has on the order of ten rows.
//
// (For Rick: FreshnessReason is a `std::variant` of every outcome; the
// colour and the sentence are both `std::visit`s over it, so adding a
// reason without a colour or words is a compile error, not a blank cell.)

import Foundation

// MARK: - Colour

/// The four freshness colours, ordered by severity for "worst of":
/// red > yellow > green > grey.
public enum FreshnessColour: String, Sendable, Codable, CaseIterable, Comparable {
    case green, yellow, red, grey

    /// Severity rank. Grey is the floor — "not asked" never outranks an
    /// answer — so a mixed green/grey catalog reads green.
    private var rank: Int {
        switch self {
        case .grey: return 0
        case .green: return 1
        case .yellow: return 2
        case .red: return 3
        }
    }

    // Comparable by rank, so `colours.max()` is "the worst of".
    // (For Rick: operator< on an enum class, ordered by a lookup, not by
    // declaration order.)
    public static func < (lhs: FreshnessColour, rhs: FreshnessColour) -> Bool {
        lhs.rank < rhs.rank
    }
}

// MARK: - Row

/// What one knowledge kind reports about itself. Counts are rows (files)
/// unless `phrases.unit` says otherwise; `offline` is the count on
/// unmounted drives, in the same unit, so the three counts add up.
public struct FreshnessRow: Sendable, Equatable {

    /// How the last pass ended.
    public enum Outcome: String, Sendable, Codable, Equatable {
        case ok, partial, failed, neverRan
    }

    /// The kind's own words for its counts, so the model can say
    /// "660 files without a full hash" without knowing what a hash is.
    /// Each phrase follows a count + plural noun, so write it as a
    /// participle or prepositional phrase ("pointing at nothing — look at
    /// Fix Links"), never a verb that needs agreement ("point").
    public struct Phrases: Sendable, Equatable {
        /// Singular noun for a counted thing; the plural appends "s".
        public var unit: String
        /// Follows "N files": what the uncovered ones lack.
        public var uncovered: String
        /// Follows "N files": what the decision rows are waiting for.
        public var decision: String

        public init(unit: String = "file", uncovered: String = "not yet checked",
                    decision: String = "needing a decision") {
            self.unit = unit
            self.uncovered = uncovered
            self.decision = decision
        }

        /// The default words: files, not yet checked, needing a decision.
        public static let standard = Phrases()
    }

    /// Stable id of the knowledge kind (the registry key).
    public var kind: String
    /// What a person sees: "Full Hashes", "Sound Prints", "File Presence".
    public var title: String
    /// Rows this kind should cover and could reach (mounted drives).
    public var eligible: Int
    /// Of `eligible`, the rows that carry a current stamp.
    public var covered: Int
    /// Rows this kind would cover but cannot reach — drives not mounted.
    public var offline: Int
    /// When the last pass finished; nil = never.
    public var lastCompleted: Date?
    public var lastOutcome: Outcome
    /// Rows a person must decide about (e.g. pointing at nothing — Fix
    /// Links). Any count > 0 is red, running or not.
    public var needsDecision: Int
    /// A sidecar store that cannot be opened — the words to show. Red.
    public var storeUnavailable: String?
    /// How often a pass should complete. nil = no clock; this kind is
    /// stale only by coverage (a scan adding rows is what ages it).
    public var cadence: Duration?
    /// A pass is in progress right now.
    public var isRunning: Bool
    public var phrases: Phrases
    /// What the kind wants said after its words whatever the colour
    /// ("tiers 2 and 6 not built") — never a reason, never a colour.
    public var note: String?

    public init(kind: String, title: String, eligible: Int = 0, covered: Int = 0, offline: Int = 0,
                lastCompleted: Date? = nil, lastOutcome: Outcome = .neverRan, needsDecision: Int = 0,
                storeUnavailable: String? = nil, cadence: Duration? = nil, isRunning: Bool = false,
                phrases: Phrases = .standard, note: String? = nil) {
        self.kind = kind
        self.title = title
        self.eligible = eligible
        self.covered = covered
        self.offline = offline
        self.lastCompleted = lastCompleted
        self.lastOutcome = lastOutcome
        self.needsDecision = needsDecision
        self.storeUnavailable = storeUnavailable
        self.cadence = cadence
        self.isRunning = isRunning
        self.phrases = phrases
        self.note = note
    }

    /// Eligible rows without a stamp, never negative.
    public var uncovered: Int { max(0, eligible - covered) }
}

// MARK: - Reason, verdict, summary

/// Why a row has the colour it has — every outcome, in precedence order.
/// The first reason that applies decides; the colour is a property of the
/// reason, so the two can never disagree.
public enum FreshnessReason: Sendable, Equatable {
    // red — a person has to look
    case storeUnavailable(String)
    case lastRunFailed
    case needsDecision(Int)
    // yellow — a run fixes it
    case uncovered(Int)
    case neverRan(waiting: Int)
    case lastRunPartial
    case overdue(lastCompleted: Date?)
    // grey — not asked
    case notMounted(Int)
    case nothingToCheck
    // green
    case current(checked: Date?)

    public var colour: FreshnessColour {
        switch self {
        case .storeUnavailable, .lastRunFailed, .needsDecision: return .red
        case .uncovered, .neverRan, .lastRunPartial, .overdue: return .yellow
        case .notMounted, .nothingToCheck: return .grey
        case .current: return .green
        }
    }
}

/// One row's answer: the colour, the sentence under it, and the reason.
public struct FreshnessVerdict: Sendable, Equatable {
    public var colour: FreshnessColour
    public var words: String
    public var reason: FreshnessReason

    public init(colour: FreshnessColour, words: String, reason: FreshnessReason) {
        self.colour = colour
        self.words = words
        self.reason = reason
    }
}

/// The band at the top of the panel: one colour, one sentence, and the
/// rows behind it (red first, then yellow, then grey; green rows are not
/// listed — there is nothing to say about them).
public struct FreshnessSummary: Sendable, Equatable {

    public struct Item: Sendable, Equatable {
        public var kind: String
        public var title: String
        public var colour: FreshnessColour
        public var words: String

        public init(kind: String, title: String, colour: FreshnessColour, words: String) {
            self.kind = kind
            self.title = title
            self.colour = colour
            self.words = words
        }
    }

    public var colour: FreshnessColour
    public var headline: String
    public var items: [Item]
    /// Kinds "Update everything stale" should queue: the yellow rows that
    /// are not already running.
    public var staleKinds: [String]

    public init(colour: FreshnessColour, headline: String, items: [Item], staleKinds: [String]) {
        self.colour = colour
        self.headline = headline
        self.items = items
        self.staleKinds = staleKinds
    }

    /// Red: the dot on the toolbar, the console line at launch.
    public var needsAttention: Bool { colour == .red }
}

// MARK: - Wording context

/// Where the words get their calendar (for "today at 10:42") and their
/// digit grouping (for "1,200 files"). Injected so tests are deterministic
/// in any locale or time zone; `.current` follows the machine.
public struct FreshnessWording: Sendable {
    public var calendar: Calendar
    public var groupingSeparator: String

    public init(calendar: Calendar, groupingSeparator: String) {
        self.calendar = calendar
        self.groupingSeparator = groupingSeparator
    }

    /// The machine's calendar, time zone and grouping separator.
    public static var current: FreshnessWording {
        FreshnessWording(calendar: .current,
                         groupingSeparator: Locale.current.groupingSeparator ?? ",")
    }

    /// "1,200" — pure digit grouping, no NumberFormatter (one is ~50 µs to
    /// make; the summary judges every row).
    public func grouped(_ count: Int) -> String {
        let digits = Array(String(max(0, count)))
        var out = ""
        out.reserveCapacity(digits.count + digits.count / 3)
        for (index, digit) in digits.enumerated() {
            let remaining = digits.count - index
            if index > 0, remaining % 3 == 0 { out += groupingSeparator }
            out.append(digit)
        }
        return out
    }

    /// "1 file" / "660 files" / "1,200 rows". Plural appends "s".
    public func count(_ count: Int, _ unit: String) -> String {
        "\(grouped(count)) \(unit)\(count == 1 ? "" : "s")"
    }
}

/// Relative-time words for a stamp against an injected `now`: "just now",
/// "12 minutes ago", "today at 10:42", "yesterday at 23:05", "3 days ago".
/// Hours are said as a clock time, which is what a person wants when the
/// pass ran earlier today. Built once per summary; the day boundaries are
/// computed in `init` so each row costs at most one calendar call.
public struct RelativeTimeWords: Sendable {
    private let calendar: Calendar
    private let now: Date
    private let startOfToday: Date
    private let startOfYesterday: Date

    public init(calendar: Calendar, now: Date) {
        self.calendar = calendar
        self.now = now
        let today = calendar.startOfDay(for: now)
        startOfToday = today
        startOfYesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)
    }

    public func words(for date: Date) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        if elapsed < 3_600 {
            let minutes = Int(elapsed / 60)
            return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        }
        if date >= startOfToday { return "today at \(clock(date))" }
        if date >= startOfYesterday { return "yesterday at \(clock(date))" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: startOfToday).day ?? 2
        return "\(max(2, days)) days ago"
    }

    private func clock(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

// MARK: - The rules

public enum FreshnessPolicy {

    /// THE rule for one row.
    public static func judge(_ row: FreshnessRow, now: Date,
                             wording: FreshnessWording = .current) -> FreshnessVerdict {
        judge(row, reason: reason(for: row, now: now),
              wording: wording, relative: RelativeTimeWords(calendar: wording.calendar, now: now))
    }

    /// Precedence: a red reason, else a yellow one, else grey or green.
    /// (For Rick: `??` chains like `a ? a : b ? b : c`, evaluated lazily.)
    public static func reason(for row: FreshnessRow, now: Date) -> FreshnessReason {
        attention(row) ?? staleness(row, now: now) ?? idle(row)
    }

    /// Red — a person has to look. A running row keeps its red: the count
    /// of rows awaiting a decision does not shrink because a pass is on.
    static func attention(_ row: FreshnessRow) -> FreshnessReason? {
        if let why = row.storeUnavailable { return .storeUnavailable(why) }
        if row.lastOutcome == .failed { return .lastRunFailed }
        if row.needsDecision > 0 { return .needsDecision(row.needsDecision) }
        return nil
    }

    /// Yellow — a run fixes it. Coverage first (the count is the useful
    /// number), then the outcome, then the clock.
    static func staleness(_ row: FreshnessRow, now: Date) -> FreshnessReason? {
        if row.uncovered > 0 { return .uncovered(row.uncovered) }
        if row.lastOutcome == .neverRan, row.eligible > 0 { return .neverRan(waiting: row.eligible) }
        if row.lastOutcome == .partial { return .lastRunPartial }
        if let cadence = row.cadence, isOverdue(row.lastCompleted, cadence: cadence, now: now) {
            return .overdue(lastCompleted: row.lastCompleted)
        }
        return nil
    }

    /// Grey or green: nothing reachable (grey) or everything stamped (green).
    static func idle(_ row: FreshnessRow) -> FreshnessReason {
        if row.eligible == 0 {
            return row.offline > 0 ? .notMounted(row.offline) : .nothingToCheck
        }
        return .current(checked: row.lastCompleted)
    }

    static func isOverdue(_ lastCompleted: Date?, cadence: Duration, now: Date) -> Bool {
        guard let lastCompleted else { return true }
        return now.timeIntervalSince(lastCompleted) > cadence.timeInterval
    }

    /// The colour's words, then the running overlay: a running row that is
    /// not red just says "running" — the pass is on, the button is not
    /// needed; a red row keeps its words and adds "· running" because the
    /// person still has to look. The row's `note`, when it has one, ends
    /// the words in every colour.
    static func judge(_ row: FreshnessRow, reason: FreshnessReason,
                      wording: FreshnessWording, relative: RelativeTimeWords) -> FreshnessVerdict {
        let plain = words(for: reason, phrases: row.phrases, wording: wording, relative: relative)
        var words: String
        switch (row.isRunning, reason.colour) {
        case (false, _): words = plain
        case (true, .red): words = "\(plain) · running"
        case (true, _): words = "running"
        }
        if let note = row.note { words += " · \(note)" }
        return FreshnessVerdict(colour: reason.colour, words: words, reason: reason)
    }

    /// Plain family-app English for each reason.
    static func words(for reason: FreshnessReason, phrases: FreshnessRow.Phrases,
                      wording: FreshnessWording, relative: RelativeTimeWords) -> String {
        switch reason {
        case .storeUnavailable(let why):
            return "sidecar can't be opened: \(why)"
        case .lastRunFailed:
            return "the last run failed or was stopped — look at the log, then run again"
        case .needsDecision(let n):
            return "\(wording.count(n, phrases.unit)) \(phrases.decision)"
        case .uncovered(let n):
            return "\(wording.count(n, phrases.unit)) \(phrases.uncovered)"
        case .neverRan(let waiting):
            return "never run — \(wording.count(waiting, phrases.unit)) waiting"
        case .lastRunPartial:
            return "the last run stopped part way — run it again"
        case .overdue(nil):
            return "not checked yet"
        case .overdue(let last?):
            return "last checked \(relative.words(for: last))"
        case .notMounted(let n):
            return "not asked — \(wording.count(n, phrases.unit)) on drives that aren't mounted"
        case .nothingToCheck:
            return "nothing to check"
        case .current(nil):
            return "current"
        case .current(let checked?):
            return "current · checked \(relative.words(for: checked))"
        }
    }

    // MARK: Summary

    /// The band: worst colour, one headline, the non-green rows red first.
    public static func summarize(_ rows: [FreshnessRow], now: Date,
                                 wording: FreshnessWording = .current) -> FreshnessSummary {
        let relative = RelativeTimeWords(calendar: wording.calendar, now: now)
        let judged = rows.map { row in
            (row: row, verdict: judge(row, reason: reason(for: row, now: now), wording: wording, relative: relative))
        }
        let colour = judged.map(\.verdict.colour).max() ?? .grey
        // `sorted` is stable (Swift 5+), so rows keep registry order within a colour.
        let items = judged
            .filter { $0.verdict.colour != .green }
            .sorted { $0.verdict.colour > $1.verdict.colour }
            .map { FreshnessSummary.Item(kind: $0.row.kind, title: $0.row.title,
                                         colour: $0.verdict.colour, words: $0.verdict.words) }
        let reds = judged.filter { $0.verdict.colour == .red }
        let tally = Tally(red: reds.count,
                          yellow: judged.filter { $0.verdict.colour == .yellow }.count,
                          anyOffline: rows.contains { $0.offline > 0 },
                          onlyRedWords: reds.count == 1 ? reds[0].verdict.words : nil)
        let stale = judged.filter { $0.verdict.colour == .yellow && !$0.row.isRunning }.map(\.row.kind)
        return FreshnessSummary(colour: colour, headline: headline(colour, tally), items: items, staleKinds: stale)
    }

    struct Tally {
        var red: Int
        var yellow: Int
        var anyOffline: Bool
        /// The one red row's words, when there is exactly one — the chip
        /// says "Needs a decision: 3 rows pointing at nothing" (design §4;
        /// Rick 2026-10-16: yellow says "need attention", so red says "decision").
        var onlyRedWords: String?
    }

    static func headline(_ colour: FreshnessColour, _ tally: Tally) -> String {
        switch colour {
        case .red:
            return "Needs a decision: \(tally.onlyRedWords ?? things(tally.red))"
        case .yellow:
            return "\(things(tally.yellow)) \(tally.yellow == 1 ? "needs" : "need") attention"
        case .green:
            return "Catalog is current"
        case .grey:
            return tally.anyOffline ? "Nothing to check — drives not mounted" : "Nothing to check"
        }
    }

    static func things(_ n: Int) -> String {
        "\(n) thing\(n == 1 ? "" : "s")"
    }
}

private extension Duration {
    /// Seconds as a TimeInterval, for comparing against a Date gap.
    var timeInterval: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
