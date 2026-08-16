// VolumeStatusCacheTests.swift
// Pins the per-volume retire-status cache (2026-07-05 beachball fix).
//
// The Volumes window used to compute retire readiness inside its body —
// four full-catalog sweeps per row per body evaluation (~8M PathScope
// comparisons per keystroke at 103k records; 91% of a 20 s main-thread
// sample). The cache moves that to ONE off-main pass published to a
// dictionary. These tests pin three things:
//   1. PARITY — the single-pass aggregator produces exactly what the
//      legacy per-volume sweeps produced (same helpers the old
//      VolumesWindow.retireStatus composed), including the Bucket A/D
//      safe-migrated-destination rule.
//   2. SAFETY — a cold cache can never enable Mark Retired.
//   3. PERFORMANCE — the O(1) read discipline and the aggregate pass
//      itself stay within budget at production scale (regression sensor).

import Testing
import Foundation
@testable import VideoScan

@Suite(.serialized) @MainActor
struct VolumeStatusCacheTests {

    private func makeRecord(fullPath: String,
                            stage: ArchiveStage = .none,
                            originVolume: String? = nil,
                            originalFullPath: String? = nil,
                            notes: String = "") -> VideoRecord {
        let r = VideoRecord()
        r.filename = (fullPath as NSString).lastPathComponent
        r.fullPath = fullPath
        r.directory = (fullPath as NSString).deletingLastPathComponent
        r.sizeBytes = 100
        r.partialMD5 = "hh"
        r.archiveStage = stage
        r.originVolume = originVolume
        r.originalFullPath = originalFullPath
        r.notes = notes
        return r
    }

    /// The legacy composition, verbatim from the pre-fix
    /// VolumesWindow.retireStatus (including hasSafeMigratedDestination).
    /// The cache must match this for every volume and every fixture.
    private func legacyStatus(for volumePath: String,
                              model: VideoScanModel) -> VolumeRetireStatus {
        let total = VideoScanModel.totalRecordsOn(
            volumeRootPath: volumePath, in: model.records)
        let disposed = VideoScanModel.manuallyDeletedOn(
            volumeRootPath: volumePath, in: model.records)
        let originated = VideoScanModel.originatedOnCount(
            volumeRootPath: volumePath, in: model.records)
        let usedAtSomePoint = total > 0 || originated > 0
        let allDisposed = usedAtSomePoint && (disposed == total)
        let witnesses = VideoScanModel.aggregateRetiredWitnesses(
            volumeRootPath: volumePath, in: model.records)
        let resolver = model.makeVolumeSafetyResolver()
        let name = (volumePath as NSString).lastPathComponent
        let pathPrefix = volumePath.hasSuffix("/") ? volumePath : volumePath + "/"
        let safeMigrated = model.records.contains { r in
            let originatedHere = (r.originVolume == name)
                || (r.originalFullPath?.hasPrefix(pathPrefix) ?? false)
            guard originatedHere, !r.fullPath.hasPrefix(pathPrefix) else { return false }
            return resolver(r.fullPath).isSafe
        }
        let hasSafeWitness = witnesses.contains { path in
            resolver(path).isSafe
        } || safeMigrated
        return VolumeRetireStatus(totalRecords: total,
                                  disposedRecords: disposed,
                                  allDisposed: allDisposed,
                                  hasSafeWitness: hasSafeWitness)
    }

    /// Rebuild the cache deterministically and assert parity with the
    /// legacy composition for every target in the model.
    private func expectParity(_ model: VideoScanModel,
                              sourceLocation: SourceLocation = #_sourceLocation) async {
        await model.rebuildVolumeStatusesNow()
        for t in model.scanTargets where !t.searchPath.isEmpty {
            let cached = model.volumeStatus(for: t.searchPath)
            let legacy = legacyStatus(for: t.searchPath, model: model)
            #expect(cached == legacy,
                    "Cache/legacy divergence for \(t.searchPath): cached=\(cached) legacy=\(legacy)",
                    sourceLocation: sourceLocation)
        }
    }

    // MARK: - 1. Cold cache is fail-safe

    @Test
    func coldCacheNeverEnablesRetire() {
        let model = VideoScanModel()
        model.scanTargets = [CatalogScanTarget(searchPath: "/Volumes/Anything")]
        model.records = [makeRecord(fullPath: "/Volumes/Anything/a.bin",
                                    stage: .manuallyDeleted)]
        // No rebuild awaited: the cache is cold (or at best stale-empty).
        let status = model.volumeStatus(for: "/Volumes/Anything")
        #expect(status.canRetire == false,
                "A cold cache must never enable a destructive action")
    }

    // MARK: - 2. Parity across the five legacy states

    @Test
    func parityAcrossRetireLifecycleStates() async {
        let model = VideoScanModel()
        let vol = "/Volumes/PretendOld"
        let safeBackup = CatalogScanTarget(searchPath: "/Volumes/MyBook")
        safeBackup.role = .backup
        safeBackup.trust = .reliable
        let degradedBackup = CatalogScanTarget(searchPath: "/Volumes/OldFlaky")
        degradedBackup.role = .backup
        degradedBackup.trust = .unreliable
        model.scanTargets = [CatalogScanTarget(searchPath: vol), safeBackup, degradedBackup]

        let bucketENote = VideoScanModel.formatSafelyRedundantNote(
            stamp: "2026-05-30T10:00:00Z",
            witnesses: ["/Volumes/MyBook/a.bin"], totalWitnessCount: 1)
        let bucketENoteDegraded = VideoScanModel.formatSafelyRedundantNote(
            stamp: "2026-05-30T10:00:00Z",
            witnesses: ["/Volumes/OldFlaky/b.bin"], totalWitnessCount: 1)

        // State 1: no records.
        await expectParity(model)
        #expect(model.volumeStatus(for: vol).canRetire == false)

        // State 2: one record, not disposed.
        let r1 = makeRecord(fullPath: vol + "/a.bin")
        model.records = [r1]
        await expectParity(model)
        #expect(model.volumeStatus(for: vol).allDisposed == false)

        // State 3: disposed, witnesses only on a degraded host.
        r1.archiveStage = .manuallyDeleted
        r1.notes = bucketENoteDegraded
        model.records = [r1]
        await expectParity(model)
        let s3 = model.volumeStatus(for: vol)
        #expect(s3.allDisposed && !s3.hasSafeWitness && !s3.canRetire)

        // State 4: disposed + safe witness → retire enabled.
        r1.notes = bucketENote
        model.records = [r1]
        await expectParity(model)
        let s4 = model.volumeStatus(for: vol)
        #expect(s4.canRetire && s4.isSafeToRetire && !s4.isDegradedDisposed)

        // State 5: two records, one undisposed.
        model.records = [r1, makeRecord(fullPath: vol + "/b.bin")]
        await expectParity(model)
        #expect(model.volumeStatus(for: vol).canRetire == false)
    }

    // MARK: - 3. Bucket A/D — records moved away, destination safe

    @Test
    func migratedDestinationSafetyMatchesLegacy() async {
        let model = VideoScanModel()
        let old = CatalogScanTarget(searchPath: "/Volumes/OldDrive")
        let dest = CatalogScanTarget(searchPath: "/Volumes/NewHome")
        dest.role = .backup
        dest.trust = .reliable
        model.scanTargets = [old, dest]

        // Originated on OldDrive, fullPath rewritten to NewHome (Bucket D):
        // total on OldDrive is 0, originated > 0, destination safe →
        // retire-eligible via the safe-migrated rule.
        model.records = [makeRecord(fullPath: "/Volumes/NewHome/tape.mkv",
                                    originVolume: "OldDrive",
                                    originalFullPath: "/Volumes/OldDrive/tape.mkv")]
        await expectParity(model)
        let status = model.volumeStatus(for: "/Volumes/OldDrive")
        #expect(status.totalRecords == 0)
        #expect(status.allDisposed, "0-of-0 with originated>0 is trivially disposed")
        #expect(status.hasSafeWitness, "Safe destination volume is the witness")
        #expect(status.canRetire)

        // Same shape but the destination is unreliable → not eligible.
        dest.trust = .unreliable
        await expectParity(model)
        #expect(model.volumeStatus(for: "/Volumes/OldDrive").canRetire == false)
    }

    // MARK: - 4. Reads never recompute; invalidation recomputes once

    @Test
    func readsAreO1AndInvalidationCoalesces() async throws {
        let model = VideoScanModel()
        model.scanTargets = [CatalogScanTarget(searchPath: "/Volumes/V1")]
        model.records = [makeRecord(fullPath: "/Volumes/V1/a.bin")]
        await model.rebuildVolumeStatusesNow()
        let after = model.volumeStatusRecomputeCount
        for _ in 0..<200 {
            _ = model.volumeStatus(for: "/Volumes/V1")
        }
        #expect(model.volumeStatusRecomputeCount == after,
                "volumeStatus(for:) reads must never trigger recomputation")

        // The debounced path: a burst of invalidations coalesces into one
        // rebuild that lands within ~1 s and reflects the new state.
        model.records = [makeRecord(fullPath: "/Volumes/V1/a.bin"),
                         makeRecord(fullPath: "/Volumes/V1/b.bin"),
                         makeRecord(fullPath: "/Volumes/V1/c.bin")]
        // records didSet has already called noteVolumeStatusesStale().
        var updated = false
        for _ in 0..<40 {   // up to ~2 s
            try await Task.sleep(nanoseconds: 50_000_000)
            if model.volumeStatus(for: "/Volumes/V1").totalRecords == 3 {
                updated = true
                break
            }
        }
        #expect(updated, "Debounced invalidation must land a fresh cache within ~2 s")
    }

    // MARK: - 5. Trailing-slash key normalization

    @Test
    func trailingSlashLookupHitsTheSameEntry() async {
        let model = VideoScanModel()
        model.scanTargets = [CatalogScanTarget(searchPath: "/Volumes/Slashy/")]
        model.records = [makeRecord(fullPath: "/Volumes/Slashy/a.bin")]
        await model.rebuildVolumeStatusesNow()
        #expect(model.volumeStatus(for: "/Volumes/Slashy").totalRecords == 1)
        #expect(model.volumeStatus(for: "/Volumes/Slashy/").totalRecords == 1)
    }

    // MARK: - 6. Perf regression sensor (production scale)

    // The whole point of the fix: at ~100k records × 10 volumes the
    // aggregate pass must complete comfortably fast OFF the main thread,
    // and row reads must be O(1). Budgets are generous (Debug build,
    // loaded test hosts) — the legacy path was ~1000× over them.
    @Test
    func aggregatePassStaysWithinBudgetAtScale() async {
        let volumes = (0..<10).map { "/Volumes/Perf\($0)" }
        let records: [VolumeStatusRecordSnap] = (0..<100_000).map { i in
            VolumeStatusRecordSnap(
                fullPath: "\(volumes[i % volumes.count])/dir\(i % 37)/clip\(i).mov",
                isManuallyDeleted: i % 5 == 0,
                originVolume: nil,
                originalFullPath: nil,
                notes: nil)
        }
        let targets = volumes.map {
            VolumeStatusTargetSnap(searchPath: $0, role: .original, trust: .reliable)
        }
        let start = Date()
        let out = await VideoScanModel.computeVolumeStatuses(records: records,
                                                             targets: targets)
        let elapsed = Date().timeIntervalSince(start)
        #expect(out.count == 10)
        #expect(out["/Volumes/Perf0"]?.totalRecords == 10_000)
        #expect(elapsed < 2.0,
                "Single-pass aggregate at 100k×10 must stay well under 2 s (got \(elapsed)s)")
    }
}
