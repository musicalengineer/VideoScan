// CatalogRealityFactsBuilder.swift
// The app half of the Catalog Status band's new meaning (Rick 2026-10-20:
// does the catalog reflect reality?). One sentence: fold what the app
// already reads off the main actor — the file check's record
// (catalog-audit.json), the last report's facts (IntegrityReportFacts and
// its IntegrityRealityFacts buckets), the sound sidecar's openability and
// the coverage pass's Missing-copy counts — into the Core policy's inputs
// (CatalogRealityFacts) and, SEPARATELY, the review items and information
// lines that never touch the colour.
//
// Presence (tier 0) is read from the file check's record, not the report:
//   gone / still missing     → reality (a Missing file that IS missing is fine);
//                              listed as review items by copy (MissingCopyCounts)
//   changed, never seen by   → unsettled (yellow) — Fix Links decides
//   an audit
//   not asked, could not     → "not checked"; a large share is yellow
//   check
//
// Pure: values in, values out; nothing here reads a file or the clock.
//
// (For Rick: an `enum` with only static functions ≈ a C++ namespace of
// free functions.)

import Foundation
import VideoScanCore

/// Everything the band needs from the app, the colour's inputs apart from the rest.
struct CatalogRealityInputs: Sendable, Equatable {
    var facts = CatalogRealityFacts()
    var review: [CatalogReviewItem] = []
    var information: [String] = []
}

enum CatalogRealityFactsBuilder {

    static func inputs(facts: CatalogFreshnessFacts, missing: MissingCopyCounts) -> CatalogRealityInputs {
        CatalogRealityInputs(facts: realityFacts(facts), review: review(facts.integrity, missing: missing),
                             information: information(facts.integrity))
    }

    /// The colour's inputs — no review item can reach them.
    static func realityFacts(_ f: CatalogFreshnessFacts) -> CatalogRealityFacts {
        var out = CatalogRealityFacts(validation: validation(audit: f.audit, integrity: f.integrity, switchedAt: f.switchedAt))
        if let why = f.soundStoreProblem { out.unreadable.append("the sound print sidecar can't be opened: \(why)") }
        if let why = f.integrity.problem { out.unreadable.append(why) }
        if let why = f.auditProblem { out.unreadable.append(why) }
        out.breaks = f.integrity.reality.breaks
        out.unsettled = f.integrity.reality.unsettled
        let presence = PresenceTally(f.audit, switchedAt: f.switchedAt)
        out.rowsToCheck = presence.planned
        out.rowsNotChecked = presence.notChecked
        out.unsettled = presence.unsettled + out.unsettled
        return out
    }

    /// The file check and the catalog check, as ONE Validate outcome.
    static func validation(audit: CatalogAuditRunRecord?, integrity: IntegrityReportFacts, switchedAt: Date?) -> CatalogValidation {
        let presence = CatalogAuditPresenceFacts.from(audit, switchedAt: switchedAt)
        if presence.outcome == .failed {
            return .failed(audit?.outcome == .running ? "did not finish checking files on disk (quit or crash)"
                                                      : "failed while checking files on disk")
        }
        if integrity.outcome == .failed { return .failed("failed while checking the catalog") }
        if presence.outcome == .neverRan || integrity.outcome == .neverRan || integrity.predatesSwitch { return .neverRan }
        if presence.outcome == .partial || integrity.outcome == .partial {
            return .partial(at: [presence.lastCompleted, integrity.lastCompleted].compactMap { $0 }.min())
        }
        guard let files = presence.lastCompleted, let catalog = integrity.lastCompleted else { return .neverRan }
        return .completed(at: min(files, catalog))
    }

    /// Review items: the report's buckets, then the two Missing counts.
    static func review(_ integrity: IntegrityReportFacts, missing: MissingCopyCounts) -> [CatalogReviewItem] {
        integrity.reality.review + [
            CatalogReviewItem(kind: .missingNoOtherCopy, count: missing.noOtherCopy),
            CatalogReviewItem(kind: .missingOtherCopyPresent, count: missing.otherCopyPresent),
            CatalogReviewItem(kind: .missingPossibleCopy, count: missing.possibleCopyNotProven),
        ]
    }

    static func information(_ integrity: IntegrityReportFacts) -> [String] {
        var out = integrity.reality.information
        if integrity.reality.findingsCapped {
            out.append("the last check kept its first \(IntegrityReport.findingsCap.formatted()) findings — the counts may be low")
        }
        return out
    }

    /// What the file check's record says about presence (a run from
    /// before the switch to SQLite says nothing).
    struct PresenceTally: Equatable {
        var planned = 0
        var notChecked = 0
        var unsettled: [CatalogRealityCount] = []

        init(_ record: CatalogAuditRunRecord?, switchedAt: Date?) {
            guard let r = record, !CatalogFreshnessFactsReader.predatesSwitch(r.startedAt, switchedAt: switchedAt) else { return }
            func n(_ result: CatalogAuditResult) -> Int { r.counts[result.rawValue] ?? 0 }
            planned = r.counts["planned"] ?? 0
            notChecked = n(.notAsked) + n(.couldNotCheck) + n(.recordChanged)
            let changed = n(.changed)
            let unseen = n(.neverSeenByAnAudit)
            if changed > 0 {
                unsettled.append(CatalogRealityCount(count: changed, words: "\(changed.formatted()) files changed size on disk — Fix Links decides"))
            }
            if unseen > 0 {
                unsettled.append(CatalogRealityCount(count: unseen,
                    words: "\(unseen.formatted()) files are not at their path and no file check has seen them before — Fix Links decides"))
            }
        }
    }
}
