// ScanCheckpointIsolationTests.swift
// REGRESSION (2026-11-20, full Release run on the M5 Ultra): app-hosted
// tests that save/delete scan checkpoints (ScanMergeScopeTests,
// RobustScanTests, T3VExtensionlessSurvivalTests, DiscoveryCompleteness,
// ScanLifecycleGuard, ScratchVolumeScreening, EditorCacheCodexRound2, and
// every model scan that reaches ProbeEngine's checkpoint save) wrote JSON
// into Rick's REAL ~/Library/Application Support/VideoScan/scan_checkpoints.
// The real folder's mtime moved at 13:13:53 (t3-v scenario), and it still
// holds five July files named after test temp paths
// (`private_var_folders_…_T_vs_scanmerge_*`) from runs whose `defer` never
// ran. Any concurrent "real App Support unchanged" snapshot sees the folder
// change. Fix: `ScanCheckpoint.directory` routes to the per-PID test sandbox
// under the test host — the one place every checkpoint path is resolved.
//
// These tests only stat/list the real folder; they never write to it (the
// save test refuses before saving if the directory is not sandboxed).

import Foundation
import Testing
@testable import VideoScan

@Suite("Scan checkpoints — test-host isolation")
struct ScanCheckpointIsolationTests {

    /// The user's REAL checkpoint folder, spelled independently of the code under test.
    private static var realCheckpointDir: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent("scan_checkpoints", isDirectory: true)
    }

    private static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// name → "size@mtime" of the real folder, plus the folder's own mtime.
    /// Read-only: stat and list, nothing else.
    private static func realFolderFingerprint() -> [String: String] {
        guard let dir = realCheckpointDir else { return [:] }
        let fm = FileManager.default
        var out: [String: String] = [:]
        let dirAttrs = (try? fm.attributesOfItem(atPath: dir.path)) ?? [:]
        out["."] = "\((dirAttrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1)"
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let a = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path)) ?? [:]
            out[name] = "\((a[.size] as? NSNumber)?.int64Value ?? -1)@\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1)"
        }
        return out
    }

    @Test("under the test host the checkpoint folder is the per-PID temp sandbox, never Application Support")
    func checkpointDirectoryUnderTestIsSandboxed() throws {
        #expect(TestEnvironment.isTestHost, "test-host detection broke — every default path would be Rick's")
        let dir = Self.canonical(ScanCheckpoint.directory)
        let temp = Self.canonical(URL(fileURLWithPath: NSTemporaryDirectory()))
        let appSupport = try #require(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        #expect(!dir.hasPrefix(Self.canonical(appSupport)),
                "checkpoint folder leaked into Application Support: \(dir)")
        #expect(!dir.contains("/Library/Application Support/"), "\(dir)")
        #expect(dir.hasPrefix(temp), "checkpoint folder is not under the test temp dir: \(dir)")
        #expect(dir.contains("VideoScanTests-\(ProcessInfo.processInfo.processIdentifier)"),
                "checkpoint folder missing the per-PID sandbox marker: \(dir)")
        #expect(dir.hasSuffix("/VideoScan/scan_checkpoints"), "same layout as production, inside the sandbox: \(dir)")
    }

    @Test("save → exists → listAll → load → delete all land in the sandbox; the real folder is not touched")
    func saveListDeleteStayInSandbox() throws {
        // Refuse BEFORE any write if the store would hit the real folder —
        // this test must never be the leak it guards against.
        let real = try #require(Self.realCheckpointDir)
        let dir = ScanCheckpoint.directory
        try #require(!Self.canonical(dir).hasPrefix(Self.canonical(real)),
                     "ScanCheckpoint.directory is the REAL folder — refusing to save: \(dir.path)")

        let realBefore = Self.realFolderFingerprint()
        let volume = "/Volumes/IsolationCanary_\(UUID().uuidString)"
        let cp = ScanCheckpoint(volumePath: volume, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                discoveredPaths: ["\(volume)/a.mov", "\(volume)/b.mp4"], totalDiscovered: 2)
        ScanCheckpointStorage.save(cp)
        defer { ScanCheckpointStorage.delete(for: volume) }

        #expect(ScanCheckpointStorage.exists(for: volume))
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(onDisk.contains { $0.contains("IsolationCanary_") }, "the checkpoint was not written into the sandbox: \(onDisk)")
        #expect(ScanCheckpointStorage.listAll().contains { $0.volumePath == volume })
        #expect(ScanCheckpointStorage.load(for: volume)?.discoveredPaths.count == 2)
        ScanCheckpointStorage.delete(for: volume)
        #expect(!ScanCheckpointStorage.exists(for: volume))

        #expect(Self.realFolderFingerprint() == realBefore, "the REAL scan_checkpoints folder changed under test")
    }

    @Test("production resolution is unchanged: App Support/VideoScan/scan_checkpoints when not a test host")
    func productionResolutionIsAppSupport() throws {
        let real = try #require(Self.realCheckpointDir)
        // Pure path arithmetic — resolveDirectory creates nothing.
        #expect(ScanCheckpoint.resolveDirectory(testHost: false).path == real.path)
        #expect(ScanCheckpoint.resolveDirectory(testHost: true).path == ScanCheckpoint.directory.path)
    }
}
