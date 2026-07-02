// T3VExtensionlessSurvivalTests.swift
// End-to-end regression for the "t3-v scenario" (Rick, 2026-07-02).
//
// Backstory: "t3-v" is a 9 GB extensionless QuickTime DV file rescued into
// the catalog by the "Scan Files With No Extension" feature (17aa7d2,
// walker-level tests in ExtensionlessScanTests). The 2026-07-01 LaCie
// incident then destroyed 5,586 records — including rescued extensionless
// files — because the scan lifecycle wiped records at scan START and blindly
// saved whatever incomplete discovery returned at completion (fixed in
// 0a6fd3c, unit/pipeline tests in ScanMergeScopeTests).
//
// This suite pins the FULL story at integration level, through the real
// pipeline (startTarget/resumeTarget → walker → ffprobe → finalize →
// commitScanResults) and the real search path the UI uses
// (VideoScanModel.searchIndex.filter — CatalogHelpers.swift). One rescued
// extensionless record must:
//   (a) survive a later scan of a DIFFERENT subtree on the same volume,
//   (b) survive a later scan of the SAME root that discovers nothing
//       (extensionless option back OFF — the exact way discovery "loses"
//       t3-v), survive a same-root rescan with NON-EMPTY discovery that
//       still cannot see it (b1b — retained-invisible existence check),
//       and survive an ABORTED (partial) rescan of the same root,
//   (c) remain findable by search afterward.
//
// Red/green: phase (b1) FAILS at fa24921 (pre-fix: startTarget's
// records.removeAll wiped the root at scan start; an empty walk never
// brought the record back), and the search phase (c) fails with it. Phases
// 1 and (a) pass pre-fix and stay as permanent sensors (discovery of
// extensionless media; root-scoped replace).
//
// Isolation notes (settings-pollution class):
//   * scanOptions are set IN-MEMORY on the model only; ScanOptions.save()
//     is never called, so the user's real UserDefaults are untouched.
//     (Relying on the model's default `.restored()` would silently read the
//     developer's live prefs — see the makePipelineModel comment in
//     ScanMergeScopeTests.)
//   * CatalogStore(directory:) is injected — nothing touches
//     ~/Library/Application Support/VideoScan.
//   * MetadataCache is already test-host-isolated (temp SQLite).
//   * The one ScanCheckpoint written goes through the production storage
//     (same convention as RobustScanTests), keyed by a UUID temp path, and
//     is deleted in a defer.

import Testing
import Foundation
@testable import VideoScan

@Suite("t3-v scenario — extensionless record survives later scans, stays searchable",
       .enabled(if: TestMediaGenerator.isAvailable))
struct T3VExtensionlessSurvivalTests {

    // MARK: - Helpers

    /// Canonicalized temp dir (walker yields /private/var/… realpaths; seeded
    /// paths must share that prefix — same trick as ScanMergeScopeTests).
    private func makeTempDir(_ label: String) throws -> URL {
        var dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs_t3v_\(label)_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let canonical = try dir.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            dir = URL(fileURLWithPath: canonical, isDirectory: true)
        }
        return dir
    }

    /// Deterministic scan policy, set in-memory only (never `.save()`d):
    /// no small-file floor (fixtures are tiny), no checksums (speed),
    /// extensionless admission per-phase.
    private func scanOptions(probeExtensionless: Bool) -> ScanOptions {
        var opts = ScanOptions()          // struct copy — like a C++ value type
        opts.skipSmallFiles = false
        opts.skipChecksums = true
        opts.probeExtensionless = probeExtensionless
        return opts
    }

    /// Run one full per-target scan through the production pipeline and wait
    /// for it to finalize (walker → probe → preservation → commitScanResults).
    @MainActor
    private func runScan(_ model: VideoScanModel, root: String,
                         probeExtensionless: Bool) async {
        model.scanOptions = scanOptions(probeExtensionless: probeExtensionless)
        let target = CatalogScanTarget(searchPath: root)
        model.scanTargets.append(target)
        model.startTarget(target)
        _ = await target.scanTask?.value
    }

    // MARK: - The end-to-end t3-v story

    @Test @MainActor
    func t3vSurvivesLaterScansAndStaysSearchable() async throws {
        let fm = FileManager.default
        let vol = try makeTempDir("vol")            // stands in for the volume root
        let storeDir = try makeTempDir("store")
        defer {
            try? fm.removeItem(at: vol)
            try? fm.removeItem(at: storeDir)
        }

        // Fixture volume:
        //   vol/TripAcrossCountry_1995_video-only/t3-v   ← REAL video-only
        //       QuickTime bytes, no extension (ffprobe must identify it —
        //       that is what admits it past the catalog gate)
        //   vol/OtherFootage/clip.mov                    ← created in phase (a)
        let rescuedDir = vol.appendingPathComponent("TripAcrossCountry_1995_video-only",
                                                    isDirectory: true)
        try fm.createDirectory(at: rescuedDir, withIntermediateDirectories: true)
        let generated = try TestMediaGenerator.generate(
            container: "mov", streams: .videoOnly, duration: 1.0, prefix: "t3v_src")
        let t3vPath = rescuedDir.appendingPathComponent("t3-v").path
        try fm.moveItem(atPath: generated, toPath: t3vPath)

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: storeDir)
        model.scanTargets.removeAll()

        // ── Phase 1: the rescue scan ("Scan Files With No Extension" ON) ──
        await runScan(model, root: rescuedDir.path, probeExtensionless: true)
        let rescued = try #require(
            model.records.first { $0.fullPath == t3vPath },
            "Rescue scan must catalog the extensionless media file (t3-v)")
        #expect(rescued.streamTypeRaw == StreamType.videoOnly.rawValue,
                "ffprobe must identify the real bytes as video-only media")
        // The user then curates it — this must also survive every later phase.
        rescued.mediaDisposition = .important

        // ── Phase (a): later scan of a DIFFERENT subtree, default options ──
        let otherDir = vol.appendingPathComponent("OtherFootage", isDirectory: true)
        try fm.createDirectory(at: otherDir, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 64).write(to: otherDir.appendingPathComponent("clip.mov"))

        await runScan(model, root: otherDir.path, probeExtensionless: false)
        #expect(model.records.contains { $0.fullPath == t3vPath },
                "t3-v must survive a scan of a sibling subtree on the same volume")
        #expect(model.records.contains { $0.fullPath == otherDir.appendingPathComponent("clip.mov").path },
                "The sibling scan itself must still catalog its own files")

        // ── Phase (b1): rescan of the SAME root with extensionless OFF ──
        // The walker cannot see t3-v, so discovery returns 0 files — the
        // incident shape. Pre-fix (fa24921) this DESTROYED the record
        // (wipe-at-start + empty walk). Post-fix: empty discovery never prunes.
        await runScan(model, root: rescuedDir.path, probeExtensionless: false)
        #expect(model.records.contains { $0.fullPath == t3vPath },
                "t3-v must survive a same-root rescan whose discovery comes back empty (RED pre-0a6fd3c)")

        // ── Phase (b1b): same-root rescan, extensionless OFF, NON-EMPTY discovery ──
        // The adjacent hazard to (b1): a decoy .mov sits next to t3-v, so
        // discovery returns 1 file and the merge takes the COMPLETE-scan
        // prune path instead of the empty-discovery guard. "Not re-seen"
        // must not mean "deleted": t3-v's bytes are on disk, it is merely
        // INVISIBLE to this scan's options — and one vanished record is far
        // under the >50 tripwire floor. RED before the retained-invisible
        // existence check in commitScanResults.
        let decoyPath = rescuedDir.appendingPathComponent("decoy.mov").path
        try Data(repeating: 0, count: 64).write(to: URL(fileURLWithPath: decoyPath))
        await runScan(model, root: rescuedDir.path, probeExtensionless: false)
        #expect(model.records.contains { $0.fullPath == t3vPath },
                "t3-v must survive a complete same-root rescan that cannot SEE it while its file is still on disk (RED pre-retained-invisible fix)")
        #expect(model.records.contains { $0.fullPath == decoyPath },
                "The decoy scan itself must still catalog its own files")

        // ── Phase (b2): ABORTED (partial) rescan of the same root ──
        // Resume from a checkpoint of 60 vanished extensionless paths: every
        // probe is "File not found", the consecutive-inaccessible abort fires
        // at 50 (< 60 discovered), so the merge is PARTIAL and must not prune.
        let bogusPaths = (0..<60).map {
            rescuedDir.appendingPathComponent("vanished_blob_\($0)").path
        }
        ScanCheckpointStorage.save(ScanCheckpoint(
            volumePath: rescuedDir.path,
            startedAt: Date(),
            discoveredPaths: bogusPaths,
            totalDiscovered: bogusPaths.count,
            skipChecksums: true))
        defer { ScanCheckpointStorage.delete(for: rescuedDir.path) }

        model.scanOptions = scanOptions(probeExtensionless: true)
        let resumed = CatalogScanTarget(searchPath: rescuedDir.path)
        model.scanTargets.append(resumed)
        model.resumeTarget(resumed)
        _ = await resumed.scanTask?.value

        let underRoot = model.records.filter {
            PathScope.contains($0.fullPath, within: rescuedDir.path)
        }
        #expect(Set(underRoot.map(\.fullPath)) == [t3vPath, decoyPath],
                "Aborted rescan must keep t3-v (and the b1b decoy) and admit none of the vanished blobs (got \(underRoot.map(\.fullPath)))")

        // ── Phase (c): the record is still findable via the REAL search path ──
        // Same call the catalog bar makes (CatalogHelpers.swift →
        // model.searchIndex.filter) plus the canonical matcher it must equal.
        model.searchIndex.rebuild(records: model.records)
        let hits = model.searchIndex.filter(records: model.records, query: "t3-v")
        #expect(hits.contains { $0.fullPath == t3vPath },
                "Search for 't3-v' must still find the rescued record after all rescans")
        let survivor = try #require(model.records.first { $0.fullPath == t3vPath })
        #expect(pfRecordFilenameOrPersonMatch(survivor, query: "t3-v"),
                "Canonical catalog matcher must match the surviving record")
        #expect(survivor.mediaDisposition == .important,
                "User curation applied after the rescue must survive every later scan")
    }
}
