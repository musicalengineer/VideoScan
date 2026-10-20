// CatalogReality.swift (VideoScanCore)
// THE colour of the Catalog Status band (Rick 2026-10-20 — supersedes the
// 10/16 rule "yellow = a run fixes it / red = a person must look"). One
// question: does the catalog reflect reality?
//
//   GREEN   the catalog reflects reality — integrity holds (full hashes,
//           duplicate groups agree, relations / constraints hold, derived
//           stamps are about the right content) AND the last Validate
//           Catalog (files on disk, then the catalog) completed and is
//           fresh (≤ 7 days) AND every row's presence state matches the
//           disk. A file marked Missing that IS missing is reality — fine.
//   YELLOW  the catalog can't fully vouch for reality — Validate overdue or
//           never run, a large share of rows could not be checked (drives
//           offline …), or rows whose state is unsettled.
//   RED     the catalog is lying or the check broke — any integrity break,
//           a failed or killed Validate, an unreadable sidecar or report.
//
// REVIEW ITEMS never change the colour. A green band may carry "N to
// review" — things a person may want to look at (audio tracks with no
// sound, possible same footage, possible reference movies, missing files)
// — each with its count and its door. The colour function does not even
// take them: `CatalogRealityPolicy.colour(_:now:)` reads
// `CatalogRealityFacts`, which has no review field, so no review count can
// move the band (and CatalogRealityTests pins it at production scale).
//
// Per-row verdicts (FreshnessPolicy.judge — each cycler's own colour and
// words, the "Update everything stale" list) are unchanged; only the
// band's colour and headline come from here.
//
// Pure: values in, values out; `now` injected. Memory: a handful of small
// structs (one per reason, one per review kind).
//
// (For Rick: CatalogRealityReason is a `std::variant` of every reason the
// band can have; its `colour` is a `std::visit`, so a reason without a
// colour is a compile error, not a blank band.)

import Foundation

// MARK: - Facts (what the colour reads)

/// How the last Validate Catalog ended — the file check and the catalog
/// check together (the app folds the audit's record and the report into
/// one of these).
public enum CatalogValidation: Sendable, Equatable {
    /// No record of a Validate (or only one from before the switch to SQLite).
    case neverRan
    /// Both steps completed; `at` = the OLDER of the two finish times.
    case completed(at: Date)
    /// A step stopped part way (`at` = when it last finished anything, if known).
    case partial(at: Date?)
    /// A step failed or was killed (quit / crash) — the words say which.
    case failed(String)
}

/// A count with its words ("3 duplicate groups hold files with different digests").
public struct CatalogRealityCount: Sendable, Equatable {
    public var count: Int
    public var words: String

    public init(count: Int, words: String) {
        self.count = count
        self.words = words
    }
}

/// Everything the band's COLOUR depends on — and nothing else (no review items).
public struct CatalogRealityFacts: Sendable, Equatable {
    public var validation: CatalogValidation
    /// Integrity breaks: each a rule the catalog fails ("2 rows share a path").
    public var breaks: [CatalogRealityCount]
    /// A sidecar or the report that cannot be read — its words.
    public var unreadable: [String]
    /// Live rows the file check should have asked.
    public var rowsToCheck: Int
    /// Of those, rows it could not check (drive not connected, an errno).
    public var rowsNotChecked: Int
    /// Rows whose state is unsettled ("4 files changed size on disk",
    /// "660 files have only a sampled hash").
    public var unsettled: [CatalogRealityCount]

    public init(validation: CatalogValidation = .neverRan, breaks: [CatalogRealityCount] = [], unreadable: [String] = [],
                rowsToCheck: Int = 0, rowsNotChecked: Int = 0, unsettled: [CatalogRealityCount] = []) {
        self.validation = validation
        self.breaks = breaks
        self.unreadable = unreadable
        self.rowsToCheck = rowsToCheck
        self.rowsNotChecked = rowsNotChecked
        self.unsettled = unsettled
    }
}

// MARK: - Reasons

/// Why the band is not green — every reason, in precedence order.
public enum CatalogRealityReason: Sendable, Equatable {
    // red — the catalog is lying or the check broke
    case unreadable(String)
    case validateFailed(String)
    case integrityBreak(CatalogRealityCount)
    // yellow — the catalog can't fully vouch for reality
    case neverValidated
    case validatePartial
    case validateOverdue(lastCompleted: Date)
    case largeShareNotChecked(notChecked: Int, of: Int)
    case unsettled(CatalogRealityCount)

    public var colour: FreshnessColour {
        switch self {
        case .unreadable, .validateFailed, .integrityBreak: return .red
        case .neverValidated, .validatePartial, .validateOverdue, .largeShareNotChecked, .unsettled: return .yellow
        }
    }
}

// MARK: - Review items (never a colour)

/// What a person may want to look at, whatever the colour.
public struct CatalogReviewItem: Sendable, Hashable {

    /// Each kind's words and door are DATA (one table, below), not a switch per use.
    public enum Kind: String, Sendable, CaseIterable {
        /// Video+Audio headers whose sound print heard silence (tier 3's
        /// `headerSaysSoundPrintHeardNone`, as the report states it).
        case audioTracksButNoSound
        /// Sound prints tier 3 could not judge (no current print, or one that
        /// could not tell sound from silence) — Fingerprint Sound looks again.
        /// The catalog's presence and integrity truth is unaffected, so this
        /// is a door, never a colour (Manager 2026-10-20).
        case soundPrintsToHearAgain
        case possibleSameFootage
        case possibleReferenceMovies
        /// Marked Missing, and no other copy is in the catalog.
        case missingNoOtherCopy
        /// Marked Missing; another copy is present.
        case missingOtherCopyPresent
    }

    public var kind: Kind
    public var count: Int

    public init(kind: Kind, count: Int) {
        self.kind = kind
        self.count = count
    }

    private struct Words { let title: String; let door: String; let caution: Bool }

    private static let table: [Kind: Words] = [
        .audioTracksButNoSound: Words(
            title: "Audio Tracks, But No Sound",
            door: "could be junk, could be a slideshow missing its music — look, then tag it \"Silent — checked\" or fix it",
            caution: true),
        .soundPrintsToHearAgain: Words(
            title: "Sound prints to hear again",
            door: "Fingerprint Sound looks again", caution: false),
        .possibleSameFootage: Words(
            title: "Possible same footage",
            door: "confirm or reject each pair in the inspector", caution: false),
        .possibleReferenceMovies: Words(
            title: "Possible reference movies",
            door: "Verify Media decides", caution: false),
        .missingNoOtherCopy: Words(
            title: "Missing, with no other copy",
            door: "reconnect its drive or look for it — this may be the only copy", caution: false),
        .missingOtherCopyPresent: Words(
            title: "Missing, another copy is present",
            door: "the other copy stands; Remove from Catalog when you're sure", caution: false),
    ]

    public var title: String { Self.table[kind]?.title ?? kind.rawValue }
    /// Where a person goes from here.
    public var door: String { Self.table[kind]?.door ?? "" }
    /// Shown in yellow TEXT (Rick: "needs a look") — still never a band colour.
    public var isCaution: Bool { Self.table[kind]?.caution ?? false }
}

// MARK: - Verdict

public struct CatalogRealityVerdict: Sendable, Equatable {
    public var colour: FreshnessColour
    public var headline: String
    /// Every reason that applies, red first, then yellow (empty when green).
    public var reasons: [CatalogRealityReason]
    /// Review items with a count > 0, in table order.
    public var review: [CatalogReviewItem]
    /// Said under the band, never counted ("128 lineage links … kept as history").
    public var information: [String]

    public init(colour: FreshnessColour, headline: String, reasons: [CatalogRealityReason],
                review: [CatalogReviewItem], information: [String]) {
        self.colour = colour
        self.headline = headline
        self.reasons = reasons
        self.review = review
        self.information = information
    }

    /// The sum of the review counts.
    public var reviewCount: Int { review.reduce(0) { $0 + $1.count } }

    /// "N to review" under the band; nil when there is nothing to review.
    public var reviewLine: String? {
        let n = reviewCount
        return n > 0 ? "\(n.formatted()) to review" : nil
    }
}

// MARK: - The rule

public enum CatalogRealityPolicy {

    /// A Validate older than this is overdue (Rick: ≤ 7 days is fresh).
    public static let freshFor: TimeInterval = 7 * 24 * 3_600
    /// A share of rows the file check could not reach at or above this is
    /// "a large share" — yellow. Below it the rows are simply not asked.
    public static let largeShareNotChecked = 0.10

    /// THE colour. Reads only `facts` — never the review items.
    public static func colour(_ facts: CatalogRealityFacts, now: Date) -> FreshnessColour {
        reasons(facts, now: now).map(\.colour).max() ?? .green
    }

    /// Every reason that applies, red ones first (stable within a colour).
    public static func reasons(_ facts: CatalogRealityFacts, now: Date) -> [CatalogRealityReason] {
        let all = broken(facts) + vouching(facts, now: now)
        return all.filter { $0.colour == .red } + all.filter { $0.colour != .red }
    }

    /// Red: unreadable stores, a failed Validate, every integrity break.
    static func broken(_ facts: CatalogRealityFacts) -> [CatalogRealityReason] {
        var out = facts.unreadable.map(CatalogRealityReason.unreadable)
        if case .failed(let why) = facts.validation { out.append(.validateFailed(why)) }
        out += facts.breaks.filter { $0.count >= 1 }.map(CatalogRealityReason.integrityBreak)
        return out
    }

    /// Yellow: the Validate's age and outcome, the share not checked, the unsettled rows.
    static func vouching(_ facts: CatalogRealityFacts, now: Date) -> [CatalogRealityReason] {
        var out: [CatalogRealityReason] = []
        switch facts.validation {
        case .neverRan: out.append(.neverValidated)
        case .partial: out.append(.validatePartial)
        case .completed(let at) where now.timeIntervalSince(at) > freshFor: out.append(.validateOverdue(lastCompleted: at))
        case .completed, .failed: break
        }
        if isLargeShare(facts.rowsNotChecked, of: facts.rowsToCheck) {
            out.append(.largeShareNotChecked(notChecked: facts.rowsNotChecked, of: facts.rowsToCheck))
        }
        out += facts.unsettled.filter { $0.count >= 1 }.map(CatalogRealityReason.unsettled)
        return out
    }

    static func isLargeShare(_ notChecked: Int, of total: Int) -> Bool {
        guard total > 0, notChecked > 0 else { return false }
        return Double(notChecked) / Double(total) >= largeShareNotChecked
    }

    /// The band: the colour and its headline from `facts`; the review items
    /// and the information lines ride along and change neither.
    public static func judge(_ facts: CatalogRealityFacts, review: [CatalogReviewItem] = [], information: [String] = [],
                             now: Date) -> CatalogRealityVerdict {
        let reasons = reasons(facts, now: now)
        let colour = reasons.map(\.colour).max() ?? .green
        let order = CatalogReviewItem.Kind.allCases
        let shown = review.filter { $0.count >= 1 }
            .sorted { (order.firstIndex(of: $0.kind) ?? 0) < (order.firstIndex(of: $1.kind) ?? 0) }
        return CatalogRealityVerdict(colour: colour, headline: headline(colour, reasons, now: now), reasons: reasons,
                                     review: shown, information: information)
    }

    // MARK: Words

    static func headline(_ colour: FreshnessColour, _ reasons: [CatalogRealityReason], now: Date) -> String {
        guard let first = reasons.first else { return "The catalog reflects reality" }
        let more = reasons.count > 1 ? " · \(reasons.count - 1) more" : ""
        let lead = colour == .red ? "Something is wrong" : "The catalog can't fully vouch for itself"
        return "\(lead): \(words(first, now: now))\(more)"
    }

    /// Plain family-app English for each reason.
    public static func words(_ reason: CatalogRealityReason, now: Date) -> String {
        switch reason {
        case .unreadable(let why): return why
        case .validateFailed(let why): return "the last Validate Catalog \(why) — run it again"
        case .integrityBreak(let c): return c.words
        case .neverValidated: return "Validate Catalog has not run — Catalog ▸ Validate Catalog…"
        case .validatePartial: return "the last Validate Catalog stopped part way — run it again"
        case .validateOverdue(let at):
            let days = max(8, Int(now.timeIntervalSince(at) / 86_400))
            return "the last Validate Catalog was \(days) days ago — run it again"
        case .largeShareNotChecked(let n, let total):
            return "\(n.formatted()) of \(total.formatted()) files could not be checked (drives not connected?)"
        case .unsettled(let c): return c.words
        }
    }
}
