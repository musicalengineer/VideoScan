import Testing
import Foundation
import VideoScanCore
@testable import VideoScan

// MARK: - Scale: the launch-time dossier backfill (launch-time fix 2026-11-02)
//
// Shape of Rick's catalog on 11-02: ~12,000 live rows sit in partial-MD5
// groups, each with a transcript (median ~1.4 KB) and OCR entries, almost
// every group already harmonised. The backfill runs on the main thread on
// every launch; before the fix it cost ~3 s there. Fixture memory: 12,000
// records × (1.4 KB transcript + 3 short OCR entries) ≈ 20 MB, freed with
// the model at the end of the test.

@MainActor
@Suite("Dossier backfill — scale (launch path)", .tags(.scale))
struct DossierBackfillScaleTests {

    @Test("12,000 rows in 4,000 groups of 3, 1.4 KB transcripts: the backfill fits the launch budget")
    func backfillAt12kRowsFitsBudget() {
        let model = VideoScanModel()
        var records: [VideoRecord] = []
        records.reserveCapacity(12_000)
        var behind = 0
        for g in 0..<4_000 {
            let o = DossierBackfillVerdictBudgetTests.ocr(g)
            for c in 0..<3 {
                // One group in 20 has a copy that never got its transcript —
                // the backfill's real job; the rest already agree.
                let isBehind = g % 20 == 0 && c == 2
                if isBehind { behind += 1 }
                records.append(DossierBackfillVerdictBudgetTests.record(
                    md5: "G\(g)", path: "/V\(c)/g\(g).mov",
                    transcript: isBehind ? nil : DossierBackfillVerdictBudgetTests.transcript(seed: g),
                    ocrText: o.text, ocrDates: o.dates))
            }
        }
        model.records = records

        let load = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        var judge = DossierTextJudge()
        var updated = 0
        let elapsed = clock.measure { updated = model.backfillDossierAcrossDuplicates(judge: &judge) }
        print("[launch-cost] backfill over 12,000 rows: \(elapsed), \(judge.verdictCalls) verdict(s), \(updated) row(s) written")

        #expect(updated == behind)
        #expect(judge.verdictCalls <= behind, "≤ 1 verdict per group that needs one; spent \(judge.verdictCalls)")
        // Budget: see the commit message for the measured green run.
        expectWithinTimingBudget("dossier backfill over 12,000 duplicate rows", measured: elapsed,
                                 budget: PerformanceLane.debugCeiling(.milliseconds(250)), loadBefore: load)
    }
}
