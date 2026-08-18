import Testing
import Foundation
@testable import VideoScan

// MARK: - ReconcilePreviewLoggingTests
//
// GH #162 (2026-08-18). Three small things, all string-level, all pinned:
//
//   1. `ReconcileLogLines` — the ONE builder for relocate.log reconcile
//      lines. The sheet's "Reconcile preview" used to log nothing; now it
//      writes the same summary + per-file lines as the live run, every
//      line prefixed `[PREVIEW]`. The live run calls the same formatters
//      with no prefix, so a drift here would show up as a wording change
//      in the un-prefixed lines too (sensor).
//   2. `ReconcileLogLines.migrateButtonLabel` — the Migrate button used to
//      say "134 record(s) (1.33 TB)" (whole-scope bytes) when only 3 files
//      would be copied. With a plan it breaks the scope down by bucket;
//      without one it keeps the old wording + points at the preview.
//   3. `ScanVerb` — the committing per-target rescan is "Rescan", never
//      "Scan / Update Catalog" (the words collided with the previewing
//      Catalog → Update Catalog… door).
//
// Pure builders — VideoRecord construction only, no filesystem, no model.

@Suite("Reconcile preview logging + Migrate wording + Rescan verb (GH #162)")
@MainActor
struct ReconcilePreviewLoggingTests {

    // MARK: - Fixtures

    private func rec(_ path: String, size: Int64 = 1024) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.directory = (path as NSString).deletingLastPathComponent
        r.sizeBytes = size
        r.partialMD5 = "deadbeef"
        return r
    }

    /// One record in every bucket so every formatter is exercised.
    private func syntheticResult() -> ReconcileResult {
        ReconcileResult(
            ready: [rec("/Volumes/Src/a.mov", size: 5_000_000_000),
                    rec("/Volumes/Src/b.mov", size: 4_000_000_000)],
            manuallyDeleted: [rec("/Volumes/Src/gone.mov")],
            sourceSideMoves: [(rec: rec("/Volumes/Src/old/c.mov", size: 960_000_000),
                               newSourcePath: "/Volumes/Src/new/c.mov")],
            adopted: [(rec: rec("/Volumes/Src/d.mov"), destPath: "/Volumes/Dest/from_Src/d.mov")],
            safelyRedundant: [SafelyRedundantEntry(
                rec: rec("/Volumes/Src/e.mov"),
                witnesses: ["/Volumes/Other/e.mov", "/Volumes/Third/e.mov"],
                totalWitnessCount: 3,
                safeWitnesses: [],
                degradedWitnesses: [])],
            previouslyRelocated: [rec("/Volumes/Src/f.mov")]
        )
    }

    // MARK: - 1. Preview log lines

    @Test("summary line: live wording, [PREVIEW] prefix, source + dest appended")
    func previewSummaryLine() {
        let r = syntheticResult()
        let line = ReconcileLogLines.summaryLine(r,
                                                 prefix: ReconcileLogLines.previewPrefix,
                                                 source: "/Volumes/Src",
                                                 dest: "/Volumes/Dest")
        #expect(line == "[PREVIEW] Reconcile: ready=2 adopted=1 sourceMoves=1 safelyRedundant=1 manuallyDeleted=1 previouslyRelocated=1 source=/Volumes/Src dest=/Volumes/Dest")
        // The live run's line is the same text minus prefix + paths.
        #expect(ReconcileLogLines.summaryLine(r)
                == "Reconcile: ready=2 adopted=1 sourceMoves=1 safelyRedundant=1 manuallyDeleted=1 previouslyRelocated=1")
    }

    @Test("per-file lines: every bucket, live order, all [PREVIEW]-prefixed")
    func previewPerFileLines() {
        let lines = ReconcileLogLines.perFileLines(syntheticResult(),
                                                   prefix: ReconcileLogLines.previewPrefix)
        #expect(lines == [
            "[PREVIEW][RECONCILE] manually-deleted: /Volumes/Src/gone.mov",
            "[PREVIEW][RECONCILE] adopted: /Volumes/Src/d.mov → /Volumes/Dest/from_Src/d.mov",
            "[PREVIEW][RECONCILE] safely-redundant: /Volumes/Src/e.mov — 3 witness(es), first: /Volumes/Other/e.mov",
            "[PREVIEW][RECONCILE] source-move: /Volumes/Src/old/c.mov → /Volumes/Src/new/c.mov",
            "[PREVIEW][RECONCILE] previously-relocated, skipping: /Volumes/Src/f.mov",
        ])
        // Ready records are copies-to-come, not reconcile decisions — the
        // live run never logs them per-file at reconcile time and neither
        // does the preview.
        #expect(!lines.contains { $0.contains("a.mov") })
    }

    @Test("allLines = summary first, then per-file; nothing unprefixed")
    func previewAllLines() {
        let lines = ReconcileLogLines.allLines(syntheticResult(),
                                               prefix: ReconcileLogLines.previewPrefix,
                                               source: "/Volumes/Src",
                                               dest: "/Volumes/Dest")
        #expect(lines.count == 6)
        #expect(lines.first?.hasPrefix("[PREVIEW] Reconcile: ") == true)
        #expect(lines.allSatisfy { $0.hasPrefix("[PREVIEW]") })
        #expect(lines.dropFirst().allSatisfy { $0.hasPrefix("[PREVIEW][RECONCILE] ") })
    }

    // regression: sensor — the un-prefixed formatters ARE the live run's
    // relocate.log wording (VideoScanModel+Relocate.swift routes through
    // them). Post-mortem greps depend on these exact shapes.
    @Test("live per-file wording is unchanged by the refactor")
    func liveWordingPinned() {
        #expect(ReconcileLogLines.manuallyDeletedLine(path: "/p") == "[RECONCILE] manually-deleted: /p")
        #expect(ReconcileLogLines.adoptedLine(path: "/p", dest: "/d") == "[RECONCILE] adopted: /p → /d")
        #expect(ReconcileLogLines.safelyRedundantLine(path: "/p", totalWitnessCount: 2, firstWitness: "/w")
                == "[RECONCILE] safely-redundant: /p — 2 witness(es), first: /w")
        #expect(ReconcileLogLines.safelyRedundantLine(path: "/p", totalWitnessCount: 0, firstWitness: nil)
                == "[RECONCILE] safely-redundant: /p — 0 witness(es), first: ?")
        #expect(ReconcileLogLines.sourceMoveLine(path: "/p", newSourcePath: "/n") == "[RECONCILE] source-move: /p → /n")
        #expect(ReconcileLogLines.previouslyRelocatedLine(path: "/p") == "[RECONCILE] previously-relocated, skipping: /p")
    }

    @Test("empty result: summary of zeros, no per-file lines")
    func emptyResult() {
        let empty = ReconcileResult(ready: [], manuallyDeleted: [], sourceSideMoves: [],
                                    adopted: [], safelyRedundant: [], previouslyRelocated: [])
        let lines = ReconcileLogLines.allLines(empty, prefix: ReconcileLogLines.previewPrefix)
        #expect(lines == ["[PREVIEW] Reconcile: ready=0 adopted=0 sourceMoves=0 safelyRedundant=0 manuallyDeleted=0 previouslyRelocated=0"])
    }

    // MARK: - 2. Migrate button wording

    @Test("with a plan: per-bucket breakdown, copy bytes = ready + source-moves only")
    func migrateLabelWithPlan() {
        let r = syntheticResult()
        let label = ReconcileLogLines.migrateButtonLabel(scopeCount: 7,
                                                         scopeBytes: 1_330_000_000_000,
                                                         plan: r,
                                                         busy: false)
        // 5 GB + 4 GB (ready) + 0.96 GB (source-move) = 9.96 GB; the
        // whole-scope 1.33 TB must NOT appear.
        #expect(label.hasPrefix("Migrate 7 record(s): 3 to copy (9.96 GB)"))
        #expect(label.contains("1 already at destination (adopt, no copy)"))
        #expect(label.contains("1 redundant elsewhere (mark deleted)"))
        #expect(label.contains("1 missing (mark deleted)"))
        #expect(label.contains("1 previously migrated (skip)"))
        #expect(!label.contains("TB"))
    }

    @Test("with a plan and something already running: Add to Queue verb")
    func migrateLabelWithPlanBusy() {
        let label = ReconcileLogLines.migrateButtonLabel(scopeCount: 7,
                                                         scopeBytes: 1,
                                                         plan: syntheticResult(),
                                                         busy: true)
        #expect(label.hasPrefix("Add to Queue — 7 record(s): 3 to copy"))
    }

    @Test("with a plan: empty buckets are omitted from the breakdown")
    func migrateLabelOmitsEmptyBuckets() {
        let onlyReady = ReconcileResult(ready: [rec("/Volumes/Src/a.mov", size: 1_000_000)],
                                        manuallyDeleted: [], sourceSideMoves: [], adopted: [],
                                        safelyRedundant: [], previouslyRelocated: [])
        let label = ReconcileLogLines.migrateButtonLabel(scopeCount: 1, scopeBytes: 1_000_000,
                                                         plan: onlyReady, busy: false)
        #expect(label == "Migrate 1 record(s): 1 to copy (1 MB)")
    }

    @Test("without a plan: old wording + pointer to the preview")
    func migrateLabelFallback() {
        let label = ReconcileLogLines.migrateButtonLabel(scopeCount: 134,
                                                         scopeBytes: 1_330_000_000_000,
                                                         plan: nil,
                                                         busy: false)
        #expect(label == "Migrate 134 record(s) (1.33 TB) — run Reconcile preview for the copy breakdown")
        let queued = ReconcileLogLines.migrateButtonLabel(scopeCount: 134,
                                                          scopeBytes: 1_330_000_000_000,
                                                          plan: nil,
                                                          busy: true)
        #expect(queued.hasPrefix("Add to Queue — 134 record(s) (1.33 TB)"))
    }

    // MARK: - 3. Rescan verb sensor

    // regression: GH #162 — the committing rescan must never again share
    // the words "Update Catalog" with the previewing door.
    @Test("committing rescan verb is plain 'Rescan' in every surface")
    func rescanVerbSensor() {
        #expect(ScanVerb.rescan == "Rescan")
        #expect(ScanVerb.menuLabel(hasResumable: false, single: true) == "Rescan")
        #expect(ScanVerb.menuLabel(hasResumable: false, single: false) == "Scan Selected")
        #expect(ScanVerb.menuLabel(hasResumable: true, single: true) == "Resume Scan")
        #expect(!ScanVerb.rescan.contains("Update Catalog"))
        #expect(!ScanVerb.menuLabel(hasResumable: false, single: true).contains("Update Catalog"))
        // Help text may MENTION Update Catalog (to point at the previewing
        // door) but must say the rescan commits.
        #expect(ScanVerb.rescanHelp.contains("commits"))
    }
}
