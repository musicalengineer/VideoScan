// ScanTargetRestoreIsolationTests.swift
// Test-host models must never inherit the machine's REAL persisted scan
// targets (the read-side twin of the Settings-pollution class: persist has
// been test-gated for months, but restore was not).
//
// Nightly incident 2026-07-05: M5/M1 real UserDefaults contained "/" as a
// saved scan target (Rick had test-scanned the root volume). Every one of
// the ~200 test-created VideoScanModel()s restored those targets in init;
// the init backfill then ran metadataCache.allRecordsWithPrefix("/") against
// the per-PROCESS test cache sandbox — which matches every fixture record
// probed by earlier tests in the same run — and appended them as foreign
// records. ScanMergeMoveIdentityTests counted 4/5/9 records where 1/2 were
// expected, on M1/M5 only (M4's saved targets are all /Volumes/… which never
// prefix-match /private/var/folders fixture paths — hence green there).
// Restoring 20+ stale targets also cost every model-creating test a fixed
// ~1.3–2.3 s reachability stall on those hosts (M5's suite: 4.8 h vs M4's
// 4.5 min).
//
// RED (pre-fix): on any machine whose real defaults hold scan targets —
// every machine in the fleet — VideoScanModel() restores them and
// scanTargets is non-empty. GREEN: restoreScanTargets() is gated by
// isRunningTests, mirroring persistScanTargets/persistScanDates; the
// restore LOGIC stays covered by PhaseConsistencyTests, which drives
// ScanTargetPersistence.restore directly with per-test unique keys.

import Testing
@testable import VideoScan

@Suite("Scan-target restore isolation (test host)")
struct ScanTargetRestoreIsolationTests {

    // A fresh model in a test host starts with ZERO scan targets — no
    // matter what the machine's real Rick-Breen.VideoScan defaults hold.
    @Test @MainActor
    func testHostModelNeverRestoresRealScanTargets() {
        let model = VideoScanModel()
        #expect(model.scanTargets.isEmpty,
                "A test-host VideoScanModel must not restore the machine's real scan targets (got \(model.scanTargets.count): \(model.scanTargets.map(\.searchPath).prefix(5)))")
    }

    // And therefore starts with zero records: with no restored targets the
    // init backfill has nothing to prefix-match against the shared
    // per-process metadata cache, so foreign fixture records from earlier
    // tests in the run can never leak in.
    @Test @MainActor
    func testHostModelStartsWithEmptyCatalog() {
        let model = VideoScanModel()
        #expect(model.records.isEmpty,
                "A test-host VideoScanModel must start with an empty catalog — init backfill leaked \(model.records.count) record(s) (first: \(model.records.first?.fullPath ?? "-"))")
    }
}
