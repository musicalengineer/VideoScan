// IntegrityRealityFacts.swift
// What the last Verify report says about "does the catalog reflect
// reality?" (Rick 2026-10-20, the Catalog Status band's new meaning —
// CatalogRealityPolicy in VideoScanCore owns the colour). One sentence:
// every finding of the report lands in ONE bucket — an integrity BREAK
// (red), UNSETTLED (yellow), a REVIEW item (never a colour) or INFORMATION
// (said, never counted) — by a table, and the tiers' own "could not check"
// gaps land where they belong.
//
//   break        every needs-a-decision finding of tiers 4 and 5 (two rows
//                at one path, duplicate groups whose digests differ, a sound
//                print made from other content, catalog.json changed with no
//                new generation …).
//   review       tier 3's `headerSaysSoundPrintHeardNone` findings, as the
//                report states them → "Audio Tracks, But No Sound"; tier 3's
//                "could not check" (no current print, a print that could
//                not tell sound from silence) → "Sound prints to hear
//                again" (Fingerprint Sound looks again — the catalog's
//                presence and integrity truth is unaffected, Manager
//                2026-10-20); possible same footage; possible reference
//                movies.
//   unsettled    any informational finding without a table entry; tier 1
//                "could not check" (sampled-only hashes); a built tier not
//                run; the catalog changed during the run.
//   information  lineage links to rows removed from the catalog — kept as
//                history.
// Tier 0 is NOT read here: the file check's own record
// (catalog-audit.json) is, by CatalogRealityFactsBuilder. Tier 3's rules
// and words belong to VerifyCatalogTiers (and the sound-print branch); this
// file only reads the rule id.
//
// Counts come from the report's kept findings (at most
// IntegrityReport.findingsCap = 5,000 across all tiers); a report that hit
// the cap undercounts, and `findingsCapped` says so.
//
// Pure: a report in, values out. Memory: one small dictionary per rule.
//
// (For Rick: `Bucket` is an enum with associated values — a tagged union;
// the table maps a rule name to one, like a C++ static std::map.)

import Foundation
import VideoScanCore

struct IntegrityRealityFacts: Sendable, Equatable {
    var breaks: [CatalogRealityCount] = []
    var unsettled: [CatalogRealityCount] = []
    var review: [CatalogReviewItem] = []
    var information: [String] = []
    /// The report kept fewer findings than it found (the counts are low).
    var findingsCapped = false

    /// Where one finding goes.
    enum Bucket: Equatable {
        case breakRule
        case unsettled
        case review(CatalogReviewItem.Kind)
        case information
        /// Not this classifier's (tier 0 — the file check's record decides).
        case skipped
    }

    /// Informational (needsDecision == false) rules → their bucket. A rule
    /// not listed is unsettled: the catalog cannot vouch for that row yet.
    static let undecidedBuckets: [String: Bucket] = [
        CatalogConstraints.Rule.referenceMovie.rawValue: .review(.possibleReferenceMovies),
        CatalogConstraints.Rule.possibleSameFootage.rawValue: .review(.possibleSameFootage),
        CatalogConstraints.Rule.lineageTargetsExist.rawValue: .information,
    ]

    static func bucket(_ f: IntegrityFinding) -> Bucket {
        if f.tier == 0 { return .skipped }
        if f.rule == VerifyCatalogTiers.silentPrintRule { return .review(.audioTracksButNoSound) }
        if !f.needsDecision { return undecidedBuckets[f.rule] ?? .unsettled }
        return .breakRule
    }

    static func from(report r: IntegrityReport) -> IntegrityRealityFacts {
        var tally = Tally()
        for f in r.findings { tally.add(f) }
        if let sound = r.tier(3), sound.couldNotCheck > 0 { tally.review[.soundPrintsToHearAgain, default: 0] += sound.couldNotCheck }
        var out = IntegrityRealityFacts()
        out.breaks = tally.words(tally.breaks, decided: true)
        out.unsettled = tally.words(tally.unsettled, decided: false) + gaps(r)
        out.review = tally.review.map { CatalogReviewItem(kind: $0.key, count: $0.value) }
        out.information = tally.information.sorted { $0.key < $1.key }
            .map { VerifyCatalogTiers.ruleWords($0.key, count: $0.value, decided: false) }
        out.findingsCapped = r.findingsTotal > r.findings.count
        return out
    }

    /// Per-bucket counts by rule (≈ a fold's accumulator).
    struct Tally {
        var breaks: [String: Int] = [:]
        var unsettled: [String: Int] = [:]
        var review: [CatalogReviewItem.Kind: Int] = [:]
        var information: [String: Int] = [:]

        mutating func add(_ f: IntegrityFinding) {
            switch IntegrityRealityFacts.bucket(f) {
            case .breakRule: breaks[f.rule, default: 0] += 1
            case .unsettled: unsettled[f.rule, default: 0] += 1
            case .review(let kind): review[kind, default: 0] += 1
            case .information: information[f.rule, default: 0] += 1
            case .skipped: break
            }
        }

        /// Largest first, then by rule name — stable words for the band.
        func words(_ counts: [String: Int], decided: Bool) -> [CatalogRealityCount] {
            counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { CatalogRealityCount(count: $0.value, words: VerifyCatalogTiers.ruleWords($0.key, count: $0.value, decided: decided)) }
        }
    }

    /// What the report leaves unsettled beyond its findings: tier 1's
    /// "could not check" (sampled-only hashes), any built tier past 0 that
    /// did not run, and a catalog that changed during the run. Tier 3's gap
    /// is a review item (above); tier 5's is its informational findings,
    /// already bucketed.
    static func gaps(_ r: IntegrityReport) -> [CatalogRealityCount] {
        var out: [CatalogRealityCount] = []
        for t in r.builtTiers where t.tier != 0 {
            if case .notRun(let why) = t.result {
                out.append(CatalogRealityCount(count: max(1, r.rowsLive), words: "\(t.label): not run — \(why)"))
            } else if t.tier == 1, t.couldNotCheck > 0 {
                out.append(CatalogRealityCount(count: t.couldNotCheck, words: "\(t.label): \(couldNotCheckWords(t))"))
            }
        }
        if let mismatch = r.generationMismatchWords {
            out.append(CatalogRealityCount(count: max(1, r.rowsLive), words: "the catalog changed during the last check: \(mismatch)"))
        }
        return out
    }

    /// A tier's own summary when the gap is its whole result; the count otherwise.
    static func couldNotCheckWords(_ t: IntegrityTier) -> String {
        if case .couldNotCheck = t.result { return t.summary }
        return "\(t.couldNotCheck.formatted()) could not be checked"
    }
}
