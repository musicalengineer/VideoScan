// EditorCacheCodexRound2Tests.swift
// GH #383, Codex review round 2 (docs/reviews/codex/codex-review-383-
// editor-caches-2026-10-25.md). Each suite is one finding, seen RED on
// dd1a6735a before its fix.
//
// Finding 1 (P1) — an editor-cache ignore entry propagated through the
// ignore list's FILENAME fallback: Tidy `Project/iMovie Cache/Cache.mov`
// (never hashed), then an unrelated, unhashed `Family/Christmas1990/
// Cache.mov` of equal size was labelled "Junk that came back —
// editor-cache" by the next Tidy plan and refused by the scan gate at a
// new path. Ruling (DECISIONS 2026-10-25): editor-cache ignores are
// content-keyed only. A byte-identical cache file at a non-cache path still
// hides under the label (2026-09-11 ruling) — pinned by
// EditorCacheTidyTests.planApplyAndCameBack.
//
// Finding 3 (P2) — a resumed checkpoint dropped its editor-cache paths but
// the discovery audit (and its sidecar) reported zero skipped cache dirs.
// The pure seam `CatalogScopePolicy.partitionEditorCachePaths` is what the
// resume door and the test both call; the end-to-end test drives
// `resumeTarget` and reads `lastDiscoveryAudit` + the sidecar.
//
// Finding 2 (symlinked root) lives in EditorCacheSkipReviewTests — it
// extends that fixture.
//
// Dimensions: logic (key policy, plan, gate, partition) · isolation (own
// store directory, own temp tree, sidecar override) · truth (the audit and
// the sidecar carry the count and the sampled path) · sensor (a name+size
// collision never sets a family video aside). Scale: the 100k path test in
// EditorCacheScaleTests covers the predicate the partition reuses. Media
// matrix: N/A — path and metadata rules only.

import Foundation
import Testing
@testable import VideoScan

// MARK: - Fixtures

private func tempRoot(_ label: String) throws -> URL {
    // Canonical path (realpath): the walker and the probe pipeline report
    // /private/var/… for a /var/… temp root, and checkpoint paths must share
    // that prefix or nothing matches (ScanMergeScopeTests convention).
    var url = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_383_r2_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    if let canonical = try url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
        url = URL(fileURLWithPath: canonical, isDirectory: true)
    }
    return url
}

/// Write `bytes` at `root/relative`, creating directories.
private func touch(_ root: URL, _ relative: String, bytes: Int = 64) throws -> String {
    let url = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data(repeating: 0, count: bytes).write(to: url)
    return url.path
}

@MainActor
private func rec(
    _ filename: String,
    dir: String,
    md5: String = "",
    size: Int64 = 4_000_000,
    setAside: String? = nil
) -> VideoRecord {
    let r = VideoRecord()
    r.filename = filename
    r.ext = (filename as NSString).pathExtension.uppercased()
    r.streamTypeRaw = StreamType.videoAndAudio.rawValue
    r.directory = dir
    r.fullPath = dir + "/" + filename
    r.sizeBytes = size
    r.partialMD5 = md5
    r.setAsideReason = setAside
    return r
}

/// A model whose ignore-list store lives in a throwaway directory.
@MainActor
private func makeModel(_ label: String) throws -> VideoScanModel {
    let model = VideoScanModel()
    model.ignoredContentStore = IgnoredContentStore(directory: try tempRoot("store_\(label)"))
    return model
}

private let editorCache = CatalogScopePolicy.SetAsideReason.editorCache.rawValue

// MARK: - Finding 1: the filename fallback never carries the cache label

@MainActor
@Suite("383 r2 — F1: an unrelated family video never inherits the editor-cache label by filename + size")
struct EditorCacheIgnoreListNameFallbackTests {

    @Test("key policy: editor-cache entries form a content key only; every other reason keeps the name fallback")
    func keyPolicy() {
        // Hashed cache row → content key only.
        #expect(IgnoredContentKey.indexKeys(partialMD5: "c1", sizeBytes: 11, filename: "Cache.mov", reason: editorCache)
                == [.content(partialMD5: "c1", sizeBytes: 11)])
        // Unhashed cache row → nothing to remember it by (never a name key).
        #expect(IgnoredContentKey.indexKeys(partialMD5: "", sizeBytes: 11, filename: "Cache.mov", reason: editorCache).isEmpty)
        // Other reasons: unchanged — both keys when hashed, the name key alone when not.
        for reason in CatalogScopePolicy.SetAsideReason.allCases where reason != .editorCache {
            #expect(IgnoredContentKey.indexKeys(partialMD5: "m", sizeBytes: 11, filename: "A.mov", reason: reason.rawValue)
                    == [.content(partialMD5: "m", sizeBytes: 11), .name(filenameLower: "a.mov", sizeBytes: 11)],
                    Comment(rawValue: reason.rawValue))
            #expect(IgnoredContentKey.indexKeys(partialMD5: "", sizeBytes: 11, filename: "A.mov", reason: reason.rawValue)
                    == [.name(filenameLower: "a.mov", sizeBytes: 11)], Comment(rawValue: reason.rawValue))
        }
    }

    @Test("Tidy an unhashed cache row; a different, unhashed family Cache.mov of equal size stays admitted and is absent from the next plan")
    func familyVideoWithSameNameAndSizeIsNotJunk() async throws {
        let model = try makeModel("f1")
        let cache = rec("Cache.mov", dir: "/Volumes/SanDisk/Project/iMovie Cache")   // partialMD5 "" — hashing skipped
        model.records = [cache]

        let plan = await model.computeTidyCatalogPlan()
        #expect(plan.editorCacheCount == 1 && plan.rows.count == 1)
        #expect(model.applyTidyCatalog(plan) == 1)
        #expect(cache.setAsideReason == editorCache)

        // The scan door: a fresh probe at a NEW path, same name and size,
        // never hashed — different bytes for all anyone can prove.
        let fresh = rec("Cache.mov", dir: "/Volumes/LaCie/Family/Christmas1990")
        let gate = model.applyIgnoredContentGate(targetRecords: [fresh], volName: "LaCie")
        #expect(gate.ignored == 0, "the gate must not refuse a family video on filename + size alone")
        #expect(gate.admitted.count == 1)

        // The Tidy door: the same record, now in the catalog.
        model.records.append(fresh)
        let second = await model.computeTidyCatalogPlan()
        #expect(second.rows.isEmpty, "got \(second.rows.map { "\($0.filename) cameBack=\($0.cameBack) \($0.reason)" })")
        #expect(second.junkCameBackCount == 0 && second.editorCacheCount == 0)
        #expect(fresh.setAsideReason == nil)

        // The store did not remember an unhashed cache row by name either
        // (there is nothing content-shaped to remember it by).
        #expect(model.ignoredContentStore.reason(partialMD5: "", sizeBytes: 4_000_000, filename: "cache.mov") == nil)
    }

    @Test("retroactive index: a catalog row already set aside as editor-cache (no store entry) does not match a family video by name")
    func retroactiveIndexIsContentKeyedForCaches() async throws {
        let model = try makeModel("f1r")
        let setAside = rec("Cache-30.mov", dir: "/Volumes/SanDisk/Event/iMovie Movie Cache", setAside: editorCache)
        let family = rec("Cache-30.mov", dir: "/Volumes/LaCie/Family/Christmas1990")
        // A set-aside row of another reason DOES still match by name — the
        // fallback is reason-scoped, not removed.
        let oldMusic = rec("song.mp3", dir: "/Volumes/SanDisk/Old", size: 777, setAside: CatalogScopePolicy.SetAsideReason.musicFormat.rawValue)
        let musicAgain = rec("SONG.mp3", dir: "/Volumes/LaCie/Loose", size: 777)
        model.records = [setAside, family, oldMusic, musicAgain]

        let plan = await model.computeTidyCatalogPlan()
        #expect(plan.rows.map(\.filename) == ["SONG.mp3"], "got \(plan.rows.map(\.filename))")
        #expect(plan.junkCameBackCount == 1)
        #expect(plan.rows.first?.reason == .musicFormat && plan.rows.first?.cameBack == true)
    }

    @Test("content evidence still carries the label: a hashed cache row's byte-identical copy at a non-cache path comes back as junk (2026-09-11 ruling kept)")
    func byteIdenticalCopyStillHides() async throws {
        let model = try makeModel("f1c")
        let cache = rec("Cache.mov", dir: "/Volumes/SanDisk/Project/iMovie Cache", md5: "deadbeef")
        model.records = [cache]
        let plan = await model.computeTidyCatalogPlan()
        #expect(model.applyTidyCatalog(plan) == 1)
        #expect(model.ignoredContentStore.count == 1)

        let copy = rec("Christmas Cache copy.mov", dir: "/Volumes/LaCie/Loose", md5: "deadbeef")
        let gate = model.applyIgnoredContentGate(targetRecords: [copy], volName: "LaCie")
        #expect(gate.ignored == 1 && gate.admitted.isEmpty)
        // And by name only (unhashed rescan of the same size) — NOT matched:
        // no content evidence, no label.
        let unhashed = rec("Cache.mov", dir: "/Volumes/LaCie/Loose")
        #expect(model.applyIgnoredContentGate(targetRecords: [unhashed], volName: "LaCie").ignored == 0)

        // Undo forgets the content entry (the override).
        #expect(model.undoLastTidyCatalog())
        #expect(model.ignoredContentStore.isEmpty)
    }
}
