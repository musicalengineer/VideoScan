import Testing
import Foundation
@testable import VideoScan

@Suite("CatalogHealthReport")
struct CatalogHealthReportTests {

    @Test func healthyReportShowsNoIssues() {
        var report = CatalogHealthReport(
            volumePath: "/Volumes/X",
            volumeName: "X",
            totalRecords: 100
        )
        report.healthy = 100
        #expect(report.isHealthy)
        #expect(report.issues == 0)
        #expect(report.recommendation.contains("healthy"))
    }

    @Test func missingFilesRecommendsRescan() {
        var report = CatalogHealthReport(
            volumePath: "/Volumes/X",
            volumeName: "X",
            totalRecords: 100
        )
        report.filesDeleted = 60
        report.healthy = 40
        #expect(!report.isHealthy)
        #expect(report.recommendation.contains("rescan"))
    }

    @Test func sizeChangedRecommendsRescan() {
        var report = CatalogHealthReport(
            volumePath: "/Volumes/X",
            volumeName: "X",
            totalRecords: 10
        )
        report.sizeChanged = 2
        report.healthy = 8
        #expect(report.recommendation.contains("rescan"))
    }

    @Test func allDeletedRecommendsRescan() {
        var report = CatalogHealthReport(
            volumePath: "/Volumes/X",
            volumeName: "X",
            totalRecords: 50
        )
        report.filesDeleted = 50
        #expect(report.recommendation.contains("rescan"))
    }

    @Test func backfilledShowsUpToDate() {
        var report = CatalogHealthReport(
            volumePath: "/Volumes/X",
            volumeName: "X",
            totalRecords: 100
        )
        report.healthy = 100
        report.provenanceBackfilled = 100
        #expect(report.isHealthy)
        #expect(report.recommendation.contains("up to date"))
    }

    @Test func offlineRecommendsConnect() {
        var report = CatalogHealthReport(
            volumePath: "/Volumes/X",
            volumeName: "X",
            totalRecords: 100
        )
        report.volumeOffline = true
        #expect(report.recommendation.contains("offline"))
    }

    @Test func summaryContainsVolumeName() {
        let report = CatalogHealthReport(
            volumePath: "/Volumes/TestVol",
            volumeName: "TestVol",
            totalRecords: 42
        )
        #expect(report.summary.contains("TestVol"))
        #expect(report.summary.contains("42"))
    }
}

@Suite("Catalog Verify Integration")
@MainActor
struct CatalogVerifyIntegrationTests {

    @Test func verifyBackfillsProvenance() {
        let model = VideoScanModel()
        model.scanTargets.removeAll()
        model.records.removeAll()

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs_verify_\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let tmpFile = tmpDir.appendingPathComponent("test.mov")
        FileManager.default.createFile(atPath: tmpFile.path, contents: Data(count: 1024))
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let target = CatalogScanTarget(searchPath: tmpDir.path)
        model.scanTargets.append(target)

        let rec = VideoRecord()
        rec.fullPath = tmpFile.path
        rec.filename = "test.mov"
        rec.sizeBytes = 1024
        model.records.append(rec)

        #expect(rec.scanContext.volumeName.isEmpty)

        model.verifyCatalog(for: target)

        #expect(!rec.scanContext.volumeName.isEmpty)
        #expect(!rec.scanContext.scanHost.isEmpty)
    }

    @Test func verifyDetectsDeletedFiles() {
        let model = VideoScanModel()
        model.scanTargets.removeAll()
        model.records.removeAll()

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs_verify_del_\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let target = CatalogScanTarget(searchPath: tmpDir.path)
        model.scanTargets.append(target)

        let rec = VideoRecord()
        rec.fullPath = tmpDir.appendingPathComponent("gone.mov").path
        rec.filename = "gone.mov"
        rec.sizeBytes = 5000
        model.records.append(rec)

        model.verifyCatalog(for: target)

        #expect(target.status == .complete)
    }

    @Test func backfillAllUpdatesRecords() {
        let model = VideoScanModel()
        model.records.removeAll()

        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs_backfill_\(UUID().uuidString.prefix(8)).mov")
        FileManager.default.createFile(atPath: tmpFile.path, contents: Data(count: 512))
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let rec = VideoRecord()
        rec.fullPath = tmpFile.path
        rec.filename = tmpFile.lastPathComponent
        model.records.append(rec)

        #expect(rec.scanContext.volumeName.isEmpty)

        model.backfillAllProvenance()

        #expect(!rec.scanContext.volumeName.isEmpty)
    }

    @Test func backfillSkipsAlreadyPopulated() {
        let model = VideoScanModel()
        model.records.removeAll()

        let rec = VideoRecord()
        rec.fullPath = "/Volumes/SomeVol/clip.mov"
        rec.filename = "clip.mov"
        rec.scanContext.volumeName = "SomeVol"
        rec.scanContext.scanHost = "TestMac"
        model.records.append(rec)

        model.backfillAllProvenance()
        #expect(rec.scanContext.volumeName == "SomeVol")
    }
}
