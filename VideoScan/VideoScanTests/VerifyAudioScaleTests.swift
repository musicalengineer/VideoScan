// VerifyAudioScaleTests.swift
// SCALE + SENSOR dimensions (feature-test checklist items 2 + 5) for
// the GH #128 `notes:` token change: pfNotesFieldMatches now unions
// audioVerifyNote, and that predicate runs per-record per-keystroke —
// so it gets pinned at 100k Rick-shaped records with an explicit time
// budget (the WorkflowTagsScaleSensorTests shape: one big test so the
// corpus + index build happen once; Release-only budget assertions,
// Debug prints only).

import Testing
import Foundation
@testable import VideoScan

@MainActor
@Suite("VerifyAudio scale + sensor", .serialized)
struct VerifyAudioScaleSensorTests {

    /// Decorates the 100k bench corpus with Verify Audio verdicts, then
    /// pins:
    ///   * budgets for the `notes:` batch-find queries (field tokens →
    ///     linear regime; 165 ms interim ceiling per the GH #123 sensor)
    ///     and for a plain word query (no regression to the fast path);
    ///   * index ≡ canonical agreement for the new audioVerifyNote leg;
    ///   * SENSOR: verdict notes NEVER surface in plain search — via
    ///     the index AND the canonical matcher — at 100k records.
    @Test func verifyNotesBudgetsAgreementAndPlainSearchSensorAt100k() {
        let clock = ContinuousClock()
        let corpus = CatalogSearchProfileBench.makeRickShapedCorpus(100_000)
        // Decorate: every 200th record carries a damaged verdict whose
        // note contains "vfxglorb" — a nonsense marker guaranteed absent
        // from the generator's vocabulary, so any plain-search hit can
        // only have come from the verdict note (500 records total).
        // Every 400th additionally gets an "ok" verdict with a
        // non-damage note, exercising the status-independent union.
        var damaged = 0
        for (i, rec) in corpus.enumerated() {
            if i % 200 == 0 {
                rec.audioVerifyStatus = "damaged"
                rec.audioVerifyNote = "reference movie — media missing; vfxglorb"
                rec.audioVerifyDate = Date(timeIntervalSince1970: 1_753_300_000)
                damaged += 1
            } else if i % 400 == 1 {
                rec.audioVerifyStatus = "ok"
                rec.audioVerifyNote = "silent audio"
            }
        }
        #expect(damaged == 500)
        let index = CatalogSearchIndex()
        index.rebuild(records: corpus)

        // ---- budgets (Release-only assertions; Debug prints only) ----
        // "donna" pins "the audioVerifyNote union didn't regress the
        // plain-word fast path"; the notes: queries are the new
        // batch-find surface and take the linear field-token regime.
        let budgets: [(String, Double)] = [
            ("donna", 50),
            ("notes:vfxglorb", 165),
            ("notes:damaged", 165),
            ("notes:reference", 165),
        ]
        for (query, budget) in budgets {
            _ = index.filter(records: corpus, query: query)  // warm-up
            var times: [Double] = []
            for _ in 0..<5 {
                let t = clock.measure { _ = index.filter(records: corpus, query: query) }
                times.append(Double(t.components.seconds) * 1_000
                             + Double(t.components.attoseconds) / 1e15)
            }
            let settled = times.sorted()[2]
            print(String(format: "[verify-scale] q='%@' settled_ms=%.1f budget_ms=%.0f",
                         query, settled, budget))
            #if !DEBUG
            #expect(settled <= budget,
                    "settled keystroke for '\(query)' took \(settled) ms — budget \(budget) ms at 100k records with verify verdicts")
            #endif
        }

        // ---- agreement: index ≡ canonical for the new union leg ----
        for q in ["notes:vfxglorb", "notes:reference", "notes:silent", "notes:missing"] {
            let viaIndex = index.filter(records: corpus, query: q).map(\.fullPath)
            let canonical = corpus.filter { pfRecordFilenameOrPersonMatch($0, query: q) }
                .map(\.fullPath)
            #expect(viaIndex == canonical,
                    "index vs canonical disagree for '\(q)': \(viaIndex.count) vs \(canonical.count) rows")
        }
        // Sanity: the decoration actually landed (agreement on empty
        // sets would be vacuous) and the batch-find math is right.
        #expect(index.filter(records: corpus, query: "notes:vfxglorb").count == 500)
        #expect(corpus.filter { pfRecordMatchesQuery($0, query: "notes:vfxglorb") }.count == 500,
                "universal matcher must honor the audioVerifyNote leg too")

        // ---- SENSOR: verdict notes never in plain search ----
        // 500 records carry "vfxglorb" in audioVerifyNote; a plain query
        // must find ZERO of them — via the index and the canonical
        // matcher. The notes: field token (explicit opt-in, asserted
        // non-empty above) proves the data is intact, just not
        // plain-searchable — machine state stays machine.
        #expect(index.filter(records: corpus, query: "vfxglorb").isEmpty,
                "SENSOR: audioVerifyNote leaked into indexed plain search")
        #expect(corpus.filter { pfRecordFilenameOrPersonMatch($0, query: "vfxglorb") }.isEmpty,
                "SENSOR: audioVerifyNote leaked into canonical plain search")
    }
}
