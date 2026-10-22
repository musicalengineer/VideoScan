// CatalogRealityBandTests.swift
// The Catalog Status band's new meaning (Rick 2026-10-20 — does the catalog
// reflect reality?), app half. The colour itself is CatalogRealityPolicy's
// (VideoScanCore, CatalogRealityTests); here:
//   LOGIC     — every report finding lands in one bucket (break / unsettled
//               / review / information) by the table; the file check's
//               record and the report fold into ONE Validate outcome; the
//               presence counts (gone = reality; changed / never seen =
//               unsettled; not asked = not checked); Missing rows split by
//               whether another copy is present.
//   SCALE     — the Missing-copy count over 100k rows inside a time budget.
//   SENSOR    — the band's state takes its colour from the reality verdict,
//               and review items (1,312 likeness pairs, 29 reference movies,
//               missing files, silent audio) leave a green band green.
// ISOLATION / MEDIA MATRIX: N/A — pure values; nothing reads a file.
//
// Suites (filter by SUITE): CatalogRealityBucketTests ·
// CatalogRealityBuilderTests · MissingCopyCountTests · CatalogRealityStateTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let now = Date(timeIntervalSince1970: 2_000_000_000)

private func finding(_ tier: Int, _ rule: String, words: String = "w", decided: Bool = true) -> IntegrityFinding {
    IntegrityFinding(tier: tier, rule: rule, recordID: UUID(), filename: "f.mov", words: words, needsDecision: decided)
}

private func report(tiers: [IntegrityTier] = [], findings: [IntegrityFinding], total: Int? = nil,
                    outcome: IntegrityReport.Outcome = .completed) -> IntegrityReport {
    IntegrityReport(runID: UUID(), startedAt: now, verifiedAt: now, outcome: outcome, catalogFile: "/x/catalog.json",
                    rowsTotal: 100, rowsLive: 100, elapsedSeconds: 1, tiers: tiers, findings: findings,
                    findingsTotal: total ?? findings.count)
}

private func okTier(_ n: Int, couldNotCheck: Int = 0, result: IntegrityTierResult = .ok, summary: String = "ok") -> IntegrityTier {
    IntegrityTier(tier: n, name: VerifyCatalogTiers.name(n), verifiedAt: now, result: result, couldNotCheck: couldNotCheck, summary: summary)
}

// MARK: - The bucket table

@Suite("Catalog reality — every finding lands in one bucket")
struct CatalogRealityBucketTests {

    typealias R = CatalogConstraints.Rule

    @Test("tier 3: every headerSaysSoundPrintHeardNone finding, as the report states it, → review 'Audio Tracks, But No Sound' (never a colour)")
    func silentPrints() {
        for words in ["the header says Video+Audio, but the sound print heard nothing (silent)", "any other words"] {
            #expect(IntegrityRealityFacts.bucket(finding(3, VerifyCatalogTiers.silentPrintRule, words: words)) == .review(.audioTracksButNoSound))
        }
        #expect(VerifyCatalogTiers.silentPrintRule == "headerSaysSoundPrintHeardNone")
    }

    @Test("tier 3 'could not check' (e.g. ~500 prints that could not tell sound from silence) → review 'Sound prints to hear again', never unsettled: the band stays green")
    func soundPrintsThatCouldNotJudgeAreAReviewDoor() {
        let r = report(tiers: [okTier(3, couldNotCheck: 500, result: .couldNotCheck(500),
                                      summary: "500 sound prints could not tell sound from silence — Fingerprint Sound looks again")],
                       findings: [])
        let f = IntegrityRealityFacts.from(report: r)
        #expect(f.review == [CatalogReviewItem(kind: .soundPrintsToHearAgain, count: 500)])
        #expect(f.unsettled.isEmpty)
        let v = CatalogRealityPolicy.judge(CatalogRealityFacts(validation: .completed(at: now), breaks: f.breaks, unsettled: f.unsettled),
                                           review: f.review, now: now)
        #expect(v.colour == .green)
        #expect(v.review.first?.door == "Fingerprint Sound looks again")
    }

    @Test("informational rules: reference movies and same footage → review; lineage to removed rows → information; any other → unsettled")
    func informationalRules() {
        #expect(IntegrityRealityFacts.bucket(finding(5, R.referenceMovie.rawValue, decided: false)) == .review(.possibleReferenceMovies))
        #expect(IntegrityRealityFacts.bucket(finding(5, R.possibleSameFootage.rawValue, decided: false)) == .review(.possibleSameFootage))
        #expect(IntegrityRealityFacts.bucket(finding(5, R.lineageTargetsExist.rawValue, decided: false)) == .information)
        #expect(IntegrityRealityFacts.bucket(finding(5, "someFutureRule", decided: false)) == .unsettled)
    }

    @Test("every needs-a-decision constraint (tiers 4 and 5) and the catalog file's hash → a BREAK; tier 0 is never read here")
    func decidedFindingsAreBreaks() {
        for rule in R.allCases {
            #expect(IntegrityRealityFacts.bucket(finding(rule.tier, rule.rawValue)) == .breakRule, "\(rule)")
        }
        // The retired catalog.json hash's rule (no run writes it since
        // 2026-10-21; a report from before may still be beside the catalog).
        #expect(IntegrityRealityFacts.bucket(finding(5, "catalogFileChanged")) == .breakRule)
        #expect(IntegrityRealityFacts.bucket(finding(0, "anything")) == .skipped)
    }

    @Test("a report → breaks with the rule's words, review counts, information, tier 1 / tier 3 gaps as unsettled; tier 5's gap is its findings, not a second count")
    func fromAReport() {
        let r = report(tiers: [okTier(0), okTier(1, couldNotCheck: 660, result: .couldNotCheck(660), summary: "660 files still have only a sampled hash — Fill In Full Hashes"),
                               okTier(3), okTier(4), okTier(5, couldNotCheck: 1_469)],
                       findings: [finding(5, R.oneLiveRowPerPath.rawValue), finding(5, R.oneLiveRowPerPath.rawValue)]
                           + Array(repeating: finding(5, R.possibleSameFootage.rawValue, decided: false), count: 1_312)
                           + Array(repeating: finding(5, R.referenceMovie.rawValue, decided: false), count: 29)
                           + Array(repeating: finding(5, R.lineageTargetsExist.rawValue, decided: false), count: 128))
        let f = IntegrityRealityFacts.from(report: r)
        #expect(f.breaks == [CatalogRealityCount(count: 2, words: "2 paths have more than one live row")])
        #expect(Set(f.review) == [CatalogReviewItem(kind: .possibleSameFootage, count: 1_312), CatalogReviewItem(kind: .possibleReferenceMovies, count: 29)])
        #expect(f.information == ["128 lineage links point at rows removed from the catalog — kept as history"])
        #expect(f.unsettled == [CatalogRealityCount(count: 660, words: "tier 1 File identity: 660 files still have only a sampled hash — Fill In Full Hashes")])
        #expect(!f.findingsCapped)
        // QA P2-a: tier 5's "could not check" is its 1,469 informational findings here; ONE more (the store's
        // generation unreadable) is unsettled in tier 5's own words.
        var plusOne = r
        plusOne.tiers[4] = okTier(5, couldNotCheck: 1_470, summary: "catalog.sqlite's generation could not be read — run again")
        #expect(IntegrityRealityFacts.from(report: plusOne).unsettled.last
                == CatalogRealityCount(count: 1, words: "tier 5 \(VerifyCatalogTiers.name(5)): catalog.sqlite's generation could not be read — run again"))
        #expect(IntegrityRealityFacts.from(report: report(findings: [], total: 9_000)).findingsCapped)
    }
}

// MARK: - The builder

@Suite("Catalog reality — the file check and the report, folded")
struct CatalogRealityBuilderTests {

    private func audit(_ outcome: CatalogAuditRunRecord.Outcome, counts: [String: Int] = ["present": 100, "planned": 100],
                       partial: Bool = false, finished: Date? = now) -> CatalogAuditRunRecord {
        var r = CatalogAuditRunRecord(startedAt: now.addingTimeInterval(-60))
        r.outcome = outcome
        r.finishedAt = finished
        r.partial = partial
        r.counts = counts
        return r
    }

    private func integrity(_ outcome: FreshnessRow.Outcome, at: Date? = now) -> IntegrityReportFacts {
        IntegrityReportFacts(lastCompleted: outcome == .ok ? at : nil, outcome: outcome)
    }

    @Test("ONE Validate outcome: both completed → completed at the older; a killed or failed step → failed; none → never; a stopped step → partial; a report from before the switch → never")
    func validation() {
        let older = now.addingTimeInterval(-3_600)
        #expect(CatalogRealityFactsBuilder.validation(audit: audit(.completed, finished: older), integrity: integrity(.ok), switchedAt: nil)
                == .completed(at: older))
        #expect(CatalogRealityFactsBuilder.validation(audit: audit(.running, finished: nil), integrity: integrity(.ok), switchedAt: nil)
                == .failed("did not finish checking files on disk (quit or crash)"))
        #expect(CatalogRealityFactsBuilder.validation(audit: audit(.failed), integrity: integrity(.ok), switchedAt: nil)
                == .failed("failed while checking files on disk"))
        #expect(CatalogRealityFactsBuilder.validation(audit: audit(.completed), integrity: integrity(.failed), switchedAt: nil)
                == .failed("failed while checking the catalog"))
        #expect(CatalogRealityFactsBuilder.validation(audit: nil, integrity: integrity(.ok), switchedAt: nil) == .neverRan)
        #expect(CatalogRealityFactsBuilder.validation(audit: audit(.completed), integrity: IntegrityReportFacts(), switchedAt: nil) == .neverRan)
        #expect(CatalogRealityFactsBuilder.validation(audit: audit(.stopped), integrity: integrity(.ok), switchedAt: nil) == .partial(at: now))
        var stale = integrity(.ok); stale.predatesSwitch = true
        #expect(CatalogRealityFactsBuilder.validation(audit: audit(.completed), integrity: stale, switchedAt: nil) == .neverRan)
    }

    @Test("presence: gone and still-missing are reality (no reason); changed and never-seen are unsettled; not asked + could not check are 'not checked'")
    func presence() {
        let counts = ["present": 13_000, "gone": 4, "stillMissing": 8, "changed": 3, "neverSeenByAnAudit": 144,
                      "notAsked": 900, "couldNotCheck": 100, "planned": 14_159]
        let p = CatalogRealityFactsBuilder.PresenceTally(audit(.completed, counts: counts), switchedAt: nil)
        #expect(p.planned == 14_159 && p.notChecked == 1_000)
        #expect(p.unsettled.map(\.count) == [3, 144])
        #expect(p.unsettled.first?.words == "3 files changed size on disk — Fix Links decides")
        #expect(CatalogRealityFactsBuilder.PresenceTally(audit(.completed, counts: counts), switchedAt: now).planned == 0,
                "a run from before the switch says nothing")
    }

    @Test("the colour's inputs never carry a review item; review = the report's buckets + the two Missing counts; the sidecar and the report's own problems are unreadable (red)")
    func inputs() {
        var facts = CatalogFreshnessFacts(audit: audit(.completed), soundStoreProblem: "not a database", integrity: integrity(.ok))
        facts.integrity.reality.review = [CatalogReviewItem(kind: .possibleSameFootage, count: 1_312)]
        let i = CatalogRealityFactsBuilder.inputs(facts: facts, missing: MissingCopyCounts(noOtherCopy: 2, otherCopyPresent: 10))
        #expect(i.facts.unreadable == ["the sound print sidecar can't be opened: not a database"])
        #expect(i.review == [CatalogReviewItem(kind: .possibleSameFootage, count: 1_312),
                             CatalogReviewItem(kind: .missingNoOtherCopy, count: 2),
                             CatalogReviewItem(kind: .missingOtherCopyPresent, count: 10),
                             CatalogReviewItem(kind: .missingPossibleCopy, count: 0)])
        #expect(CatalogRealityPolicy.colour(i.facts, now: now) == .red)
    }
}

// MARK: - Missing, with or without another copy

@Suite("Catalog reality — Missing rows and their copies")
struct MissingCopyCountTests {

    // QA 2026-10-20 P2-b: a copy is PROVEN only by the same stored full SHA-256 on a live row; a group mate
    // whose bytes cannot be compared is "a possible copy, not proven"; one with a different digest is no copy.
    @Test("proven copy = a live row with the same full SHA-256; a live group mate without a digest on one side = possible, not proven; a different digest = no copy")
    func split() {
        let g = UUID(), h = UUID()
        let inputs = [
            MissingCopyInput(group: g, digest: nil, isMissing: true),          // live mate, no digest → possible, not proven
            MissingCopyInput(group: g, digest: nil, isMissing: false),
            MissingCopyInput(group: nil, digest: "abc", isMissing: true),      // same bytes live → proven copy
            MissingCopyInput(group: nil, digest: "abc", isMissing: false),
            MissingCopyInput(group: h, digest: "ddd", isMissing: true),        // the only live mate has other bytes → no copy
            MissingCopyInput(group: h, digest: "eee", isMissing: false),
            MissingCopyInput(group: UUID(), digest: "zzz", isMissing: true),   // alone → no other copy (CROSSROADS_1.m4v)
            MissingCopyInput(group: nil, digest: nil, isMissing: true),        // no group, no digest → no other copy
        ]
        #expect(MissingCopyCalculator.count(inputs) == MissingCopyCounts(noOtherCopy: 3, otherCopyPresent: 1, possibleCopyNotProven: 1))
        #expect(MissingCopyCalculator.count([MissingCopyInput(group: g, digest: nil, isMissing: true),
                                             MissingCopyInput(group: g, digest: nil, isMissing: true)])
                == MissingCopyCounts(noOtherCopy: 2), "two Missing copies of each other are not a present copy")
        #expect(CatalogReviewItem(kind: .missingPossibleCopy, count: 1).door == "Fill In Full Hashes, then Validate Catalog")
    }

    @Test("SCALE: 100k projected rows count inside a 0.5 s budget")
    func scale() {
        var inputs: [MissingCopyInput] = []
        inputs.reserveCapacity(100_000)
        let groups = (0..<5_000).map { _ in UUID() }
        for i in 0..<100_000 {
            inputs.append(MissingCopyInput(group: i % 3 == 0 ? groups[i % groups.count] : nil,
                                           digest: i % 2 == 0 ? "d\(i % 20_000)" : nil, isMissing: i % 50 == 0))
        }
        let start = ContinuousClock.now
        let counts = MissingCopyCalculator.count(inputs)
        let elapsed = ContinuousClock.now - start
        #expect(counts.noOtherCopy + counts.otherCopyPresent + counts.possibleCopyNotProven == 2_000)
        #expect(elapsed < PerformanceLane.debugCeiling(.milliseconds(500)), "took \(elapsed)")
    }
}

// MARK: - The state the surfaces read

@Suite("Catalog reality — the band's state")
struct CatalogRealityStateTests {

    private let wording = FreshnessWording(calendar: Calendar(identifier: .gregorian), groupingSeparator: ",")

    private var greenFacts: CatalogRealityFacts {
        CatalogRealityFacts(validation: .completed(at: now.addingTimeInterval(-3_600)), rowsToCheck: 14_000)
    }

    @Test("SENSOR: the band takes its colour and headline from the reality verdict, and Rick's real review load (1,312 likeness pairs, 29 reference movies, 2 + 10 missing, silent audio) leaves it GREEN with 'N to review'")
    func reviewItemsLeaveTheBandGreen() {
        let review = [CatalogReviewItem(kind: .possibleSameFootage, count: 1_312), CatalogReviewItem(kind: .possibleReferenceMovies, count: 29),
                      CatalogReviewItem(kind: .missingNoOtherCopy, count: 2), CatalogReviewItem(kind: .missingOtherCopyPresent, count: 10),
                      CatalogReviewItem(kind: .audioTracksButNoSound, count: 5)]
        // A yellow ROW (OCR not run) does not colour the band either: the band asks about reality.
        let rows = [FreshnessRow(kind: "ocr", title: "OCR", eligible: 100, covered: 3, lastOutcome: .ok)]
        let s = CatalogFreshnessState.judged(rows: rows, reality: CatalogRealityInputs(facts: greenFacts, review: review,
                                             information: ["128 lineage links … kept as history"]), now: now, wording: wording)
        #expect(s.summary.colour == .green)
        #expect(s.summary.headline == "The catalog is reconciled")
        #expect(s.reality.reviewLine == "1,358 to review")
        #expect(CatalogStatusWords.chipWords(s) == "Reconciled")
        #expect(s.summary.items.map(\.kind) == ["ocr"], "the stale rows are still listed for Update everything stale")
        let without = CatalogFreshnessState.judged(rows: rows, reality: CatalogRealityInputs(facts: greenFacts), now: now, wording: wording)
        #expect(without.summary.colour == s.summary.colour && without.summary.headline == s.summary.headline)
    }

    @Test("red and yellow chips and menu titles say the new words")
    func words() {
        var broke = greenFacts; broke.breaks = [CatalogRealityCount(count: 1, words: "1 paths have more than one live row")]
        let red = CatalogFreshnessState.judged(rows: [], reality: CatalogRealityInputs(facts: broke), now: now, wording: wording)
        #expect(CatalogStatusWords.chipWords(red) == "Needs attention…")
        #expect(CatalogStatusWords.menuTitle(.red) == "Catalog Status — Needs attention…")
        let yellow = CatalogFreshnessState.judged(rows: [], now: now, wording: wording)
        #expect(yellow.summary.colour == .yellow, "nothing known = never validated")
        #expect(CatalogStatusWords.chipWords(yellow) == "Needs validation")
        #expect(CatalogStatusWords.menuTitle(.yellow) == "Catalog Status…")
    }
}
