// ScanMergePairCarryoverTests.swift
// QA P1-4 (2026-07-05, analysis-ledger arc): a rescan replaces every
// re-seen record with a FRESH instance — which silently destroyed its
// A/V pairing (pair fields are not in RescanPreservedFields), and under
// the incremental ledger the damage became sticky: the surviving partner
// still read as "paired" (settled), so the pair could never re-form
// until an app relaunch dropped the dangling reference.
//
// Contract now: pairs are carried across record replacement (both sides
// re-seen, or one side re-seen with a surviving cross-root partner), and
// a genuinely-pruned record's partner gets its back-reference cleared —
// honestly returning to "pending" for the next incremental correlate.
//
// RED (pre-fix): all three tests fail — fresh instances come back
// unpaired and pruned records leave dangling partners.

import Testing
import Foundation
@testable import VideoScan

@Suite(.serialized) @MainActor
struct ScanMergePairCarryoverTests {

    private func makeTempDir(_ label: String) throws -> URL {
        var dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs_paircarry_\(label)_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let canonical = try dir.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            dir = URL(fileURLWithPath: canonical, isDirectory: true)
        }
        return dir
    }

    private func makeRecord(path: String, video: Bool) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.directory = (path as NSString).deletingLastPathComponent
        r.streamTypeRaw = (video ? StreamType.videoOnly : StreamType.audioOnly).rawValue
        r.sizeBytes = 1000
        r.partialMD5 = video ? "vv" : "aa"
        return r
    }

    private func pairUp(_ v: VideoRecord, _ a: VideoRecord) -> UUID {
        let gid = UUID()
        v.pairedWith = a; v.pairGroupID = gid; v.pairConfidence = .high
        a.pairedWith = v; a.pairGroupID = gid; a.pairConfidence = .high
        return gid
    }

    // MARK: - 1. Complete rescan: both sides re-seen → pair survives

    @Test func completeRescanCarriesPairOntoFreshInstances() async throws {
        let dir = try makeTempDir("both")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vPath = dir.appendingPathComponent("clip.V01.mxf").path
        let aPath = dir.appendingPathComponent("clip.A01.mxf").path
        // Files exist on disk so nothing is pruned.
        try Data([1]).write(to: URL(fileURLWithPath: vPath))
        try Data([2]).write(to: URL(fileURLWithPath: aPath))

        let model = VideoScanModel()
        let v = makeRecord(path: vPath, video: true)
        let a = makeRecord(path: aPath, video: false)
        let gid = pairUp(v, a)
        model.records = [v, a]

        // The rescan re-sees both paths with FRESH instances.
        let vFresh = makeRecord(path: vPath, video: true)
        let aFresh = makeRecord(path: aPath, video: false)
        _ = await model.commitScanResults(root: dir.path, volName: "X",
                                          targetRecords: [vFresh, aFresh],
                                          scanWasComplete: true)

        #expect(vFresh.pairedWith === aFresh,
                "A rescan must carry the pair onto the fresh instances (RED pre-fix: silently destroyed)")
        #expect(aFresh.pairedWith === vFresh)
        #expect(vFresh.pairGroupID == gid && aFresh.pairGroupID == gid,
                "Pair identity (group id) survives the rescan")
        #expect(vFresh.pairConfidence == .high)
    }

    // MARK: - 2. One side re-seen, partner on another volume → pair survives

    @Test func rescanWithCrossRootPartnerRewiresTheSurvivingInstance() async throws {
        let dir = try makeTempDir("cross")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vPath = dir.appendingPathComponent("video.V02.mxf").path
        try Data([3]).write(to: URL(fileURLWithPath: vPath))

        let model = VideoScanModel()
        let v = makeRecord(path: vPath, video: true)
        let a = makeRecord(path: "/Volumes/Elsewhere/audio.A02.mxf", video: false)
        let gid = pairUp(v, a)
        model.records = [v, a]

        let vFresh = makeRecord(path: vPath, video: true)
        _ = await model.commitScanResults(root: dir.path, volName: "X",
                                          targetRecords: [vFresh],
                                          scanWasComplete: true)

        #expect(vFresh.pairedWith === a,
                "The fresh instance must rewire to the surviving cross-root partner")
        #expect(a.pairedWith === vFresh,
                "…and the partner's back-reference must follow to the fresh instance (RED pre-fix: dangled at the removed instance)")
        #expect(vFresh.pairGroupID == gid && a.pairGroupID == gid)
    }

    // MARK: - 3. Pruned record's partner returns honestly to pending

    @Test func pruneClearsTheSurvivingPartnersBackReference() async throws {
        let dir = try makeTempDir("prune")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Anchor keeps the discovery non-empty so pruning can happen.
        let anchorPath = dir.appendingPathComponent("anchor.mov").path
        try Data([4]).write(to: URL(fileURLWithPath: anchorPath))
        // v's file does NOT exist → genuinely gone on a complete scan.
        let vPath = dir.appendingPathComponent("vanished.V03.mxf").path

        let model = VideoScanModel()
        let v = makeRecord(path: vPath, video: true)
        let a = makeRecord(path: "/Volumes/Elsewhere/partner.A03.mxf", video: false)
        _ = pairUp(v, a)
        let anchor = makeRecord(path: anchorPath, video: true)
        anchor.pairedWith = nil
        model.records = [v, a, anchor]

        let anchorFresh = makeRecord(path: anchorPath, video: true)
        _ = await model.commitScanResults(root: dir.path, volName: "X",
                                          targetRecords: [anchorFresh],
                                          scanWasComplete: true)

        #expect(!model.records.contains { $0 === v }, "Fixture sanity: v was pruned")
        #expect(a.pairedWith == nil,
                "A pruned record's partner must return to 'pending' (RED pre-fix: dangled as settled forever)")
        #expect(a.pairGroupID == nil && a.pairConfidence == nil)
    }

    // MARK: - 4. Partial rescan preserves pairs too

    @Test func partialRescanCarriesPairsToo() async throws {
        let dir = try makeTempDir("partial")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vPath = dir.appendingPathComponent("p.V04.mxf").path
        let aPath = dir.appendingPathComponent("p.A04.mxf").path
        try Data([5]).write(to: URL(fileURLWithPath: vPath))
        try Data([6]).write(to: URL(fileURLWithPath: aPath))

        let model = VideoScanModel()
        let v = makeRecord(path: vPath, video: true)
        let a = makeRecord(path: aPath, video: false)
        let gid = pairUp(v, a)
        model.records = [v, a]

        let vFresh = makeRecord(path: vPath, video: true)
        let aFresh = makeRecord(path: aPath, video: false)
        _ = await model.commitScanResults(root: dir.path, volName: "X",
                                          targetRecords: [vFresh, aFresh],
                                          scanWasComplete: false)   // partial

        #expect(vFresh.pairedWith === aFresh && aFresh.pairedWith === vFresh,
                "Partial-scan upserts replace re-seen records and must carry pairs identically")
        #expect(vFresh.pairGroupID == gid)
    }
}
