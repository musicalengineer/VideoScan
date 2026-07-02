// ProbeGroupAbortAccountingTests.swift
// Regression for the harden-findings Jul-01 bug: the junk-catalog gate added
// in b954982 (shouldCatalogProbeResult) made gated-out outcomes `continue`
// PAST processTargetProbeResult — the function that owns the
// consecutiveNotAccessible counter and the target.filesScanned tick.
//
// Real-world consequence: if a volume unmounts mid-scan in an
// extensionless-heavy tree (Avid media directories), EVERY outcome becomes
// extensionless + ffprobeFailed ("File not found"), every outcome is gated
// out, the abort counter never increments, and the 50-consecutive-failures
// abort never fires — the scan grinds through the entire dead volume.
//
// The gate must control only CATALOG ADMISSION, never scan-health accounting.
//
// Red/green:
//   - gatedOutNotAccessibleOutcomesStillTripAbort FAILS before the fix
//     (completed == 60, filesScanned == 0) and PASSES after (abort fires at
//     50, filesScanned ticks).
//
// Determinism: the target's pauseGate holds every probe task before it
// touches the filesystem. We wait for the walk to complete (filesFound is
// set immediately after the walk loop), delete the whole tree — the
// "mid-scan unmount" — then release the gate.

import Testing
import Foundation
@testable import VideoScan

@MainActor
@Suite("Probe-group abort accounting — gate must not bypass scan-health counters")
struct ProbeGroupAbortAccountingTests {

    /// More files than the local abort threshold (50) so the abort has room
    /// to fire strictly before the group drains naturally.
    private static let fileCount = 60
    private static let localAbortAfter = 50

    @Test("Gated-out (extensionless + not-accessible) outcomes still increment the abort counter and filesScanned")
    func gatedOutNotAccessibleOutcomesStillTripAbort() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs_abortacct_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 60 extensionless files — the Avid-media-directory shape. When these
        // vanish mid-scan, every probe yields ext == "" + ffprobeFailed
        // ("File not found"), i.e. exactly the shape the catalog gate rejects.
        for i in 0..<Self.fileCount {
            let name = String(format: "avid-blob-%02d", i)
            try Data(repeating: 0xAB, count: 4096).write(to: dir.appendingPathComponent(name))
        }

        let model = VideoScanModel()
        model.scanOptions.probeExtensionless = true
        model.scanOptions.skipChecksums = true
        model.scanOptions.skipSmallFiles = false
        let target = CatalogScanTarget(searchPath: dir.path)

        // Hold every probe task at the gate so nothing touches the files
        // until we've "unmounted the volume".
        await target.pauseGate.pause()

        let scanTask = Task {
            await model.runTargetProbeGroup(
                target: target,
                root: dir.path,
                volName: "TestVol",
                rootIsNetwork: false,
                ramMountPoint: nil
            )
        }

        // Wait for the walk to complete — runTargetProbeGroup sets
        // target.filesFound right after the walk loop finishes.
        for _ in 0..<600 where target.filesFound != Self.fileCount {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try #require(target.filesFound == Self.fileCount,
                     "walk must discover all \(Self.fileCount) files before we pull the volume")

        // Simulate the mid-scan unmount: every discovered file vanishes.
        try FileManager.default.removeItem(at: dir)
        await target.pauseGate.resume()

        let result = await scanTask.value

        // The abort must fire at exactly abortAfter (50) consecutive
        // not-accessible files — NOT grind through all 60. Before the fix,
        // gated-out outcomes skipped the counter and completed == 60.
        #expect(result.completed == Self.localAbortAfter,
                "abort should fire after \(Self.localAbortAfter) consecutive not-accessible files; completed=\(result.completed) means the counter never tripped")

        // filesScanned must tick for gated-out files too (milestone/every-20
        // updates inside processTargetProbeResult). Before the fix it stayed 0.
        #expect(target.filesScanned > 0,
                "filesScanned must tick even when outcomes are gated out of the catalog")

        // The gate still does its actual job: none of these junk outcomes
        // may enter the catalog.
        #expect(result.records.isEmpty,
                "not-accessible extensionless outcomes must still be kept OUT of the catalog")
    }
}
