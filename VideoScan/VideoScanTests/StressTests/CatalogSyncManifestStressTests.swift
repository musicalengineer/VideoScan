import Foundation
import Testing
@testable import VideoScan

@Suite(.serialized)
@MainActor
struct CatalogSyncManifestStressTests {
    private static let markerPath = "/tmp/vs-codex-stress/catalog-sync-manifest-stress-enabled"

    @Test("catalog sync manifest survives repeated writes, swaps, and staged corruption")
    func repeatedManifestWriteVerifyAndSwapKeepsViewerConsistent() async throws {
        guard Self.isEnabled else { return }

        let root = Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let masterPaths = Self.paths(under: root.appendingPathComponent("master-root", isDirectory: true))
        let viewerPaths = Self.paths(under: root.appendingPathComponent("viewer-root", isDirectory: true))
        let masterSync = Self.makeSync(paths: masterPaths,
                                       localHost: "RicksM4.local",
                                       masterHost: "RicksM4.local",
                                       runner: NoOpRsync())
        let runner = MirroringRsync(sourceTree: masterPaths.liveDir)
        let viewerSync = Self.makeSync(paths: viewerPaths,
                                       localHost: "RicksM5.local",
                                       masterHost: "RicksM4.local",
                                       runner: runner)

        try FileManager.default.createDirectory(at: masterPaths.liveDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: viewerPaths.liveDir, withIntermediateDirectories: true)

        let iterations = Self.intSetting("VIDEOSCAN_CATALOG_SYNC_STRESS_ITERATIONS", defaultValue: 32)
        let recordsPerIteration = Self.intSetting("VIDEOSCAN_CATALOG_SYNC_STRESS_RECORDS", defaultValue: 80)
        var lastGoodFilenames: [String] = []

        for iteration in 0..<iterations {
            let expectedFilenames = try Self.writeMasterSnapshot(
                iteration: iteration,
                recordCount: recordsPerIteration,
                paths: masterPaths
            )
            masterSync.writeManifestIfMaster()

            await viewerSync.syncFromMaster()
            try Self.assertSynced(viewerSync, iteration: iteration)
            try viewerSync.verifyManifest(in: viewerPaths.liveDir)
            try Self.assertViewerCatalog(at: viewerPaths.liveDir, filenames: expectedFilenames)
            lastGoodFilenames = expectedFilenames

            if iteration % 7 == 3 {
                let rejectedFilenames = try Self.writeMasterSnapshot(
                    iteration: iteration + 10_000,
                    recordCount: recordsPerIteration,
                    paths: masterPaths
                )
                masterSync.writeManifestIfMaster()
                runner.postCopyHook = { stagingDir in
                    let catalog = stagingDir.appendingPathComponent("catalog.json")
                    try? Data("tampered after manifest\n".utf8).write(to: catalog)
                }

                await viewerSync.syncFromMaster()
                try Self.assertFailed(viewerSync, iteration: iteration)
                try Self.assertViewerCatalog(at: viewerPaths.liveDir, filenames: lastGoodFilenames)

                runner.postCopyHook = nil
                await viewerSync.syncFromMaster()
                try Self.assertSynced(viewerSync, iteration: iteration)
                try viewerSync.verifyManifest(in: viewerPaths.liveDir)
                try Self.assertViewerCatalog(at: viewerPaths.liveDir, filenames: rejectedFilenames)
                lastGoodFilenames = rejectedFilenames
            }
        }
    }

    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["VIDEOSCAN_CATALOG_SYNC_STRESS"] == "1"
            || FileManager.default.fileExists(atPath: markerPath)
    }

    private static func intSetting(_ key: String, defaultValue: Int) -> Int {
        max(Int(ProcessInfo.processInfo.environment[key] ?? "") ?? defaultValue, 1)
    }

    private static func scratchRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("videoscan-catalog-sync-stress-\(UUID().uuidString)", isDirectory: true)
    }

    private static func paths(under root: URL) -> CatalogSyncPaths {
        CatalogSyncPaths(
            liveDir: root.appendingPathComponent("live", isDirectory: true),
            stagingDir: root.appendingPathComponent("staging", isDirectory: true),
            previousDir: root.appendingPathComponent("previous", isDirectory: true),
            lastSyncFile: root.appendingPathComponent("last_sync.txt")
        )
    }

    private static func makeSync(
        paths: CatalogSyncPaths,
        localHost: String,
        masterHost: String,
        runner: RsyncRunner
    ) -> CatalogSync {
        CatalogSync(
            paths: paths,
            hostnameSource: FixedStressHostname(value: localHost),
            rsyncRunner: runner,
            masterHostname: masterHost,
            remoteUser: "rickb",
            log: { line in
                print("[catalog-sync-stress] \(line)")
            }
        )
    }

    private static func writeMasterSnapshot(
        iteration: Int,
        recordCount: Int,
        paths: CatalogSyncPaths
    ) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.liveDir, withIntermediateDirectories: true)
        let poiDir = paths.liveDir.appendingPathComponent("POI", isDirectory: true)
        try? fm.removeItem(at: poiDir)
        try fm.createDirectory(at: poiDir, withIntermediateDirectories: true)

        let records = (0..<recordCount).map { index -> VideoRecord in
            let record = VideoRecord()
            record.filename = String(format: "stress-%05d-%04d.mov", iteration, index)
            record.fullPath = "/Volumes/Stress/Reel\(index % 9)/\(record.filename)"
            record.directory = (record.fullPath as NSString).deletingLastPathComponent
            record.streamTypeRaw = StreamType.videoAndAudio.rawValue
            record.sizeBytes = Int64(1_000_000 + iteration * 1_000 + index)
            record.durationSeconds = 10 + Double(index % 17)
            record.sceneCaptions = [
                SceneCaption(timestamp: Double(index % 5), text: "iteration \(iteration) record \(index)")
            ]
            record.audioTranscript = "synthetic transcript \(iteration)-\(index)"
            record.ocrDateCandidates = [
                SceneCaption(timestamp: 0, text: "JUN \(1 + index % 28) 199\(index % 10)")
            ]
            record.dossierProcessedAt = Date(timeIntervalSince1970: TimeInterval(1_800_000_000 + iteration))
            record.dossierProcessedBy = "catalog-sync-stress"
            return record
        }

        let snapshot = CatalogSnapshot(records: records, savedFromHost: "stress-master-\(iteration)")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(CatalogSnapshotDTO(snapshot))
        try data.write(to: paths.liveDir.appendingPathComponent("catalog.json"), options: .atomic)
        try Data("previous-\(iteration)".utf8)
            .write(to: paths.liveDir.appendingPathComponent("catalog.json.prev"), options: .atomic)

        for person in 0..<4 {
            let personDir = poiDir.appendingPathComponent("person-\(person)", isDirectory: true)
            try fm.createDirectory(at: personDir, withIntermediateDirectories: true)
            for photo in 0..<3 {
                let bytes = Data("poi \(iteration) \(person) \(photo)".utf8)
                try bytes.write(to: personDir.appendingPathComponent("ref-\(photo).jpg"))
            }
        }

        return records.map(\.filename)
    }

    private static func assertSynced(_ sync: CatalogSync, iteration: Int) throws {
        guard case .synced = sync.state.phase else {
            throw CatalogSyncStressFailure("iteration \(iteration) expected synced, got \(sync.state.phase)")
        }
    }

    private static func assertFailed(_ sync: CatalogSync, iteration: Int) throws {
        guard case .failed(let reason) = sync.state.phase else {
            throw CatalogSyncStressFailure("iteration \(iteration) expected manifest failure, got \(sync.state.phase)")
        }
        guard reason.contains("manifest verify failed") else {
            throw CatalogSyncStressFailure("iteration \(iteration) failed for wrong reason: \(reason)")
        }
    }

    private static func assertViewerCatalog(at liveDir: URL, filenames: [String]) throws {
        let catalog = liveDir.appendingPathComponent("catalog.json")
        let data = try Data(contentsOf: catalog)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(CatalogSnapshot.self, from: data)
        let actual = snapshot.records.map(\.filename)
        guard actual == filenames else {
            throw CatalogSyncStressFailure("viewer catalog mismatch: expected \(filenames.prefix(3))..., got \(actual.prefix(3))...")
        }
    }
}

private struct FixedStressHostname: HostnameSource {
    let value: String
    func currentHostname() -> String { value }
}

private struct NoOpRsync: RsyncRunner {
    func run(args: [String], destDir: URL) async -> RsyncOutcome {
        RsyncOutcome(succeeded: true, exitCode: 0, stderr: "")
    }
}

private final class MirroringRsync: RsyncRunner, @unchecked Sendable {
    let sourceTree: URL
    var postCopyHook: ((URL) -> Void)?

    init(sourceTree: URL) {
        self.sourceTree = sourceTree
    }

    func run(args: [String], destDir: URL) async -> RsyncOutcome {
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: destDir)
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            let entries = try fm.contentsOfDirectory(at: sourceTree, includingPropertiesForKeys: nil)
            for entry in entries {
                try fm.copyItem(at: entry, to: destDir.appendingPathComponent(entry.lastPathComponent))
            }
            postCopyHook?(destDir)
            return RsyncOutcome(succeeded: true, exitCode: 0, stderr: "")
        } catch {
            return RsyncOutcome(succeeded: false, exitCode: 1, stderr: error.localizedDescription)
        }
    }
}

private struct CatalogSyncStressFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
