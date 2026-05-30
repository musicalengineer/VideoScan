import Testing
import Foundation
@testable import VideoScan

// MARK: - VolumesWindowRetireTests
//
// Covers the `VolumeRetireStatus` predicate that drives:
//   - the Mark Retired context-menu action's enabled / disabled state
//   - the sidebar row's safe-to-retire vs degraded-disposed badge pill
//
// This is the second half of the 2026-05-30 safe-witness work — the
// Volumes window is now the explicit retire surface (per
// feedback_friendly_language.md), so we must gate the action correctly.
//
// Hermetic — pure record + scanTarget fixtures, no filesystem.

@Suite(.serialized) @MainActor
struct VolumesWindowRetireTests {

    private func makeRecord(fullPath: String,
                             stage: ArchiveStage = .none,
                             size: Int64 = 100,
                             md5: String = "hh",
                             notes: String = "") -> VideoRecord {
        let r = VideoRecord()
        r.filename = (fullPath as NSString).lastPathComponent
        r.fullPath = fullPath
        r.directory = (fullPath as NSString).deletingLastPathComponent
        r.sizeBytes = size
        r.partialMD5 = md5
        r.archiveStage = stage
        r.notes = notes
        return r
    }

    /// Build the same `VolumeRetireStatus` the Volumes window
    /// constructs internally. Compact reimplementation that doesn't
    /// need the SwiftUI view layer instantiated — exercises the same
    /// model helpers + safety resolver the view does.
    private func makeStatus(for volumePath: String,
                             model: VideoScanModel) -> VolumeRetireStatus {
        let total = VideoScanModel.totalRecordsOn(
            volumeRootPath: volumePath, in: model.records
        )
        let disposed = VideoScanModel.manuallyDeletedOn(
            volumeRootPath: volumePath, in: model.records
        )
        let allDisposed = total > 0 && disposed == total
        let witnesses = VideoScanModel.aggregateRetiredWitnesses(
            volumeRootPath: volumePath, in: model.records
        )
        let resolver = model.makeVolumeSafetyResolver()
        let hasSafeWitness = witnesses.contains { path in
            let (role, trust) = resolver(path)
            return role != .retired && trust != .unreliable
        }
        return VolumeRetireStatus(
            totalRecords: total,
            disposedRecords: disposed,
            allDisposed: allDisposed,
            hasSafeWitness: hasSafeWitness
        )
    }

    // MARK: - 1. Mark Retired enabled only when 100% disposed + safe witness

    @Test
    func volumesWindow_markRetiredAction_enabledOnlyWhen100PercentSafelyDisposed() {
        let model = VideoScanModel()
        let vol = "/Volumes/PretendOld"
        let safeBackup = CatalogScanTarget(searchPath: "/Volumes/MyBook")
        safeBackup.role = .backup
        safeBackup.trust = .reliable
        let degradedBackup = CatalogScanTarget(searchPath: "/Volumes/OldFlaky")
        degradedBackup.role = .backup
        degradedBackup.trust = .unreliable
        model.scanTargets = [
            CatalogScanTarget(searchPath: vol),
            safeBackup,
            degradedBackup
        ]

        let bucketENote = VideoScanModel.formatSafelyRedundantNote(
            stamp: "2026-05-30T10:00:00Z",
            witnesses: ["/Volumes/MyBook/a.bin"],
            totalWitnessCount: 1
        )
        let bucketENoteDegraded = VideoScanModel.formatSafelyRedundantNote(
            stamp: "2026-05-30T10:00:00Z",
            witnesses: ["/Volumes/OldFlaky/b.bin"],
            totalWitnessCount: 1
        )

        // State 1: no records → action disabled, tooltip says so.
        var status = makeStatus(for: vol, model: model)
        #expect(status.canRetire == false)
        #expect(status.tooltipForRetireAction.contains("No catalogued files"))

        // State 2: one record not disposed → action disabled.
        let r1 = makeRecord(fullPath: vol + "/a.bin", stage: .none)
        model.records = [r1]
        status = makeStatus(for: vol, model: model)
        #expect(status.canRetire == false)
        #expect(status.allDisposed == false)
        #expect(status.tooltipForRetireAction.contains("run Relocate first"))

        // State 3: disposed but ALL witnesses on degraded host → action
        // still disabled, with the specific "no safe witness" tooltip.
        r1.archiveStage = .manuallyDeleted
        r1.notes = bucketENoteDegraded
        model.records = [r1]
        status = makeStatus(for: vol, model: model)
        #expect(status.allDisposed)
        #expect(status.hasSafeWitness == false)
        #expect(status.canRetire == false)
        #expect(status.tooltipForRetireAction.contains("no backup copies are confirmed"))

        // State 4: disposed + at least one safe witness → action ENABLED.
        r1.notes = bucketENote
        model.records = [r1]
        status = makeStatus(for: vol, model: model)
        #expect(status.allDisposed)
        #expect(status.hasSafeWitness)
        #expect(status.canRetire)
        #expect(status.isSafeToRetire)
        #expect(status.isDegradedDisposed == false)

        // State 5: two records, only one disposed → still disabled.
        let r2 = makeRecord(fullPath: vol + "/b.bin", stage: .none)
        model.records = [r1, r2]
        status = makeStatus(for: vol, model: model)
        #expect(status.allDisposed == false)
        #expect(status.canRetire == false)
    }
}
