import Foundation
import Testing
@testable import VideoScan

// MARK: - Catalog scope gate × move/rename identity (QA BLOCKER 2, 2026-07-15)
//
// The scope gate runs BEFORE commitScanResults, but move/rename adoption
// inside commitScanResults fingerprints THIS SCAN'S added files against
// gone records. A paired (or plain cataloged) ambiguous-audio file moved
// from P1 to P2 therefore hit a trap: the fresh P2 instance fails the
// video-linked evidence test (moved directory), the gate strips it
// pre-commit, P1 is genuinely gone — adoption has nothing to match, and
// the OLD record is PRUNED with its pair fields, notes and dossier.
//
// Fix under test: the gate EXEMPTS any fresh record whose content
// fingerprint (partialMD5 + sizeBytes — the same key adoption trusts)
// matches an existing non-purged catalog record. The record upserts, the
// merge's adoption relocates the ORIGINAL instance, and Tidy can set it
// aside later if it truly has no video.
//
// RED phase: both tests below FAIL against the unfixed gate — the moved
// record is pruned (identity, pair wiring and notes destroyed).
//
// Harness: gate + commit are driven directly, in the exact order
// finalizeTarget runs them, over a REAL temp dir so the merge's
// existence sweep stats real paths (old path absent = genuinely gone,
// new path present = added file).

@MainActor
private func moveRec(
    path: String,
    stream: StreamType,
    md5: String,
    sizeBytes: Int64 = 64,
    duration: Double = 0
) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path
    r.filename = (path as NSString).lastPathComponent
    r.directory = (path as NSString).deletingLastPathComponent
    r.ext = (path as NSString).pathExtension.uppercased()
    r.streamTypeRaw = stream.rawValue
    r.partialMD5 = md5
    r.sizeBytes = sizeBytes
    r.durationSeconds = duration
    return r
}

private func makeMoveTempDir(_ label: String) throws -> URL {
    // Canonicalize /var/folders → /private/var/folders so PathScope
    // prefix checks agree with what the filesystem reports.
    var dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vs_scopemove_\(label)_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let canonical = try dir.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
        dir = URL(fileURLWithPath: canonical, isDirectory: true)
    }
    return dir
}

@MainActor
@Suite("Catalog scope gate — moved files keep their record identity")
struct CatalogScopeMoveIdentityTests {

    @Test("moved PAIRED ambiguous audio survives a scoped rescan — identity + pair fields intact")
    func movedPairedAudioSurvivesScopedRescan() async throws {
        let root = try makeMoveTempDir("paired")
        defer { try? FileManager.default.removeItem(at: root) }
        let oldPath = root.appendingPathComponent("old/tape_audio.wav").path
        let newDir = root.appendingPathComponent("new", isDirectory: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        let newURL = newDir.appendingPathComponent("tape_audio.wav")
        try Data(repeating: 0x42, count: 64).write(to: newURL)  // moved file, on disk at P2 only

        let model = VideoScanModel()
        model.catalogScopeSettings.videoAndLinkedAudioOnly = true

        // The recovered pair: audio under the scan root, video partner on
        // another volume (deliberately NO structural correlation signals
        // with the moved file's new directory — the evidence test must
        // fail so only the fingerprint exemption can save it).
        let oldAudio = moveRec(path: oldPath, stream: .audioOnly,
                               md5: "feedbeef", duration: 45)
        oldAudio.notes = "Donna singing — keep forever"
        let partner = moveRec(path: "/Volumes/Elsewhere/ceremony_video.mxf",
                              stream: .videoOnly, md5: "0ther", duration: 45)
        let gid = UUID()
        oldAudio.pairedWith = partner
        oldAudio.pairGroupID = gid
        partner.pairedWith = oldAudio
        partner.pairGroupID = gid
        model.records = [oldAudio, partner]
        let originalID = oldAudio.id

        // The rescan of `root` found ONE file: the audio at its new home.
        let fresh = moveRec(path: newURL.path, stream: .audioOnly,
                            md5: "feedbeef", duration: 45)

        // finalizeTarget order: gate first, then commit.
        let outcome = await model.applyCatalogScopeGate(
            targetRecords: [fresh], volName: "T")
        _ = await model.commitScanResults(
            root: root.path, volName: "T",
            targetRecords: outcome.admitted, scanWasComplete: true)

        let survivor = model.records.first { $0.id == originalID }
        #expect(survivor != nil,
                "moved paired audio was PRUNED — gate stripped the fresh instance before adoption (RED pre-fix)")
        #expect(survivor === oldAudio,
                "the surviving record must be the ORIGINAL instance (pair references resolve by identity)")
        #expect(survivor?.fullPath == newURL.path,
                "the record must follow its file to the new location")
        #expect(survivor?.pairedWith === partner, "pair wiring must survive the move")
        #expect(partner.pairedWith === oldAudio, "partner's back-reference must survive")
        #expect(survivor?.pairGroupID == gid)
        // Update Catalog (2026-08-17): a relink appends ONE journey line
        // after the user's note; the note itself is intact.
        #expect(survivor?.notes.hasPrefix("Donna singing — keep forever") == true)
        #expect(survivor?.notes.contains("(relinked by Update Catalog)") == true)
        #expect(model.records.count == 2, "relocation, not prune + stranger")
    }

    @Test("moved UNPAIRED ambiguous audio keeps its record — relocation, not deletion")
    func movedUnpairedAudioKeepsRecord() async throws {
        let root = try makeMoveTempDir("unpaired")
        defer { try? FileManager.default.removeItem(at: root) }
        let oldPath = root.appendingPathComponent("loose/session_take.wav").path
        let newDir = root.appendingPathComponent("sorted", isDirectory: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        let newURL = newDir.appendingPathComponent("session_take.wav")
        try Data(repeating: 0x7, count: 64).write(to: newURL)

        let model = VideoScanModel()
        model.catalogScopeSettings.videoAndLinkedAudioOnly = true

        // Legacy cataloged wav (pre-scope era), no pair, no video evidence
        // anywhere — but it IS a catalog record with user enrichment.
        let old = moveRec(path: oldPath, stream: .audioOnly,
                          md5: "cafe0001", duration: 12)
        old.notes = "might be grampa's voice"
        model.records = [old]
        let originalID = old.id

        let fresh = moveRec(path: newURL.path, stream: .audioOnly,
                            md5: "cafe0001", duration: 12)
        let outcome = await model.applyCatalogScopeGate(
            targetRecords: [fresh], volName: "T")
        _ = await model.commitScanResults(
            root: root.path, volName: "T",
            targetRecords: outcome.admitted, scanWasComplete: true)

        let survivor = model.records.first { $0.id == originalID }
        #expect(survivor != nil,
                "moved unpaired audio record was deleted — a move must be a relocation (RED pre-fix)")
        #expect(survivor?.fullPath == newURL.path)
        #expect(survivor?.notes.hasPrefix("might be grampa's voice") == true)
        #expect(model.records.count == 1)
    }
}
