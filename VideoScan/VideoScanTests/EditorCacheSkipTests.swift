// EditorCacheSkipTests.swift
// GH #383 — editor render caches (iMovie Movie Cache, iMovie Thumbnails,
// Render Files, Analysis Files) are never admitted at scan, even under Scan
// Everything, and the rows that already reached the catalog are set aside by
// Tidy Catalog (hide + ignore list, never delete).
//
// Measured 2026-10-25: 545 live rows under those directories, admitted by
// the 10/24 rescan because Rick's options are Scan Everything and no skip
// set named them. Rick's ruling: unconditional skip, counted in the audit.
//
// Dimensions:
//   Logic     — walker over a temp tree with a .thorough-equivalent policy;
//               isEditorCachePath truth table; setAsideReason precedence
//               (pair protection still wins); Tidy plan / apply / came-back.
//   Scale     — 100k paths through isEditorCachePath under an asserted budget.
//   Isolation — own temp directory per test; the ignore-list store is
//               pointed at a throwaway directory; no UserDefaults writes.
//   Truth     — the discovery-audit summary line and the one-line app log
//               name the count; the sidecar JSON round-trips the new fields.
//   Sensor    — Tidy apply never adds/removes a record (the pinned P0 class)
//               and the ignore list carries the new reason.
// Media matrix: N/A — pure path and catalog-metadata rules; no decode.
//
// Red/green: with the walker branch, the policy path rule and the Tidy
// branch stripped (declarations kept so the file compiles) every behaviour
// test below FAILS; with them in place every test PASSES.

import Foundation
import Testing
@testable import VideoScan

// MARK: - Fixtures

private func tempRoot(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_editor_cache_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Write a 16-byte stand-in at `root/relative`, creating directories.
private func touch(_ root: URL, _ relative: String) throws {
    let url = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data(repeating: 0, count: 16).write(to: url)
}

@MainActor
private func rec(
    _ filename: String,
    dir: String,
    md5: String = "",
    size: Int64 = 1_000_000,
    stream: StreamType = .videoAndAudio
) -> VideoRecord {
    let r = VideoRecord()
    r.filename = filename
    r.ext = (filename as NSString).pathExtension.uppercased()
    r.streamTypeRaw = stream.rawValue
    r.directory = dir
    r.fullPath = dir + "/" + filename
    r.sizeBytes = size
    r.partialMD5 = md5
    return r
}

/// A model whose ignore-list store lives in a throwaway directory.
@MainActor
private func makeModel(_ label: String) throws -> VideoScanModel {
    let model = VideoScanModel()
    model.ignoredContentStore = IgnoredContentStore(directory: try tempRoot("store_\(label)"))
    return model
}

private let cacheRoot = "/Volumes/LaCieWorkspace/CheesegraterArchive/InternalRaid/iMovie Events.localized/Christmas1990"

// MARK: - Walker

@Suite("Editor caches — walker skips the directories unconditionally")
struct EditorCacheWalkerTests {

    @Test("Scan Everything still skips iMovie/FCP cache dirs; files and look-alike dirs are admitted; the audit counts and names them")
    func thoroughScanSkipsCacheDirs() async throws {
        let root = try tempRoot("walk")
        defer { try? FileManager.default.removeItem(at: root) }
        try touch(root, "Christmas1990/iMovie Movie Cache/Cache-30.mov")
        try touch(root, "Christmas1990/clip.mov")
        try touch(root, "Project/Render Files/x.mov")
        try touch(root, "RENDER FILES/y.mov")                       // case-insensitive
        try touch(root, "My Render Files Backup/keep.mov")          // substring: NOT a cache
        try touch(root, "Render Files.mov")                         // a FILE named like the token
        // An extensionless FILE named exactly the token (in a subfolder: the
        // volume is case-insensitive, so it cannot sit beside RENDER FILES/).
        try touch(root, "Christmas1990/Render Files")

        // .thorough-equivalent: Scan Everything — no small-file floor, only
        // the Finder-meta skip set, extensionless probing on so the bare
        // "Render Files" FILE is eligible and proves the file branch never
        // consults the editor-cache set.
        let thorough = ScanOptions.thorough
        let audit = DiscoveryAuditCollector(scanRoot: root.path, volumeName: "T")
        let found = await FilesystemWalker.walkDirectory(
            root: root.path,
            videoExtensions: ["mov", "mp4"],
            skipDirs: thorough.skipDirs(),
            skipBundleExtensions: thorough.skipBundleExtensions(),
            skipSmallFiles: thorough.skipSmallFiles,
            probeExtensionless: true,
            audit: audit
        )
        let names = Set(found.map(\.lastPathComponent))
        #expect(names == ["clip.mov", "keep.mov", "Render Files.mov", "Render Files"],
                "exactly the non-cache files must be emitted (got \(names.sorted()))")

        let snapshot = audit.finish(cataloged: 0)
        #expect(snapshot.skippedEditorCacheDirs == 3,
                "three cache directories at mixed depth and case (got \(snapshot.skippedEditorCacheDirs))")
        // The enumerator reports resolved paths (/private/var/… for a /var/…
        // temp root), so compare on the resolved root.
        let resolvedRoot = root.resolvingSymlinksInPath().path
        let sample = Set(snapshot.skippedEditorCacheDirPaths.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
                .replacingOccurrences(of: resolvedRoot + "/", with: "")
        })
        #expect(sample == ["Christmas1990/iMovie Movie Cache", "Project/Render Files", "RENDER FILES"],
                "the path sample names the skipped directories (got \(sample.sorted()))")
        // Not double-counted as a system-tree skip.
        #expect(snapshot.skippedSystemTreeDirs == 0)
        #expect(snapshot.filesEnumerated == 4, "files INSIDE a skipped cache dir are never enumerated")
        #expect(snapshot.filesAdmitted == 4)
    }

    @Test("the skip set is exactly the regenerable caches — proxies, Transcoded Media and Avid MediaFiles are deliberately absent")
    func skipSetIsPinned() {
        #expect(SkipCategories.editorCacheDirs
                == ["imovie movie cache", "imovie thumbnails", "render files", "analysis files"])
        // Not folded into any option-derived set: Scan Everything's skipDirs
        // does not carry it (the walker consults it unconditionally).
        #expect(ScanOptions.thorough.skipDirs().isDisjoint(with: SkipCategories.editorCacheDirs))
        #expect(ScanOptions().skipDirs().isDisjoint(with: SkipCategories.editorCacheDirs))
        for notACache in ["transcoded media", "proxy media", "avid mediafiles", "original media"] {
            #expect(!SkipCategories.editorCacheDirs.contains(notACache), "\(notACache) can be a last surviving copy")
        }
    }
}

// MARK: - Policy

@Suite("Editor caches — CatalogScopePolicy.isEditorCachePath")
struct EditorCachePathPolicyTests {

    @Test("truth table", arguments: [
        ("\(cacheRoot)/iMovie Movie Cache/Cache-30.mov", true),                       // .localized parent
        ("/Volumes/Vidéos/Noël 1990/iMovie Thumbnails/thumb.jpg", true),             // unicode parent
        ("/Volumes/X/Project/Render Files/", true),                                   // trailing slash = directory
        ("/Volumes/X/Project/RENDER FILES/x.mov", true),                              // case-insensitive
        ("/Volumes/X/Event.fcpbundle/Cape/Analysis Files/a.mov", true),               // FCP analysis
        ("/Volumes/X/Christmas1990/Render Files.mov", false),                         // token as filename (with ext)
        ("/Volumes/X/Christmas1990/Render Files", false),                             // token as the last component = filename
        ("/Volumes/X/My Render Files Backup/keep.mov", false),                        // substring
        ("/Volumes/X/iMovie Movie Cache Notes/readme.mov", false),                    // prefix
        ("/Volumes/X/Project/Transcoded Media/x.mov", false),                         // not a cache
        ("/Volumes/X/Project/Proxy Media/x.mov", false),                              // not a cache
        ("/Volumes/X/Avid MediaFiles/MXF/1/x.mxf", false),                            // not a cache
        ("Render Files", false),                                                      // bare filename
        ("", false),
    ])
    func truthTable(path: String, expected: Bool) {
        #expect(CatalogScopePolicy.isEditorCachePath(path) == expected, Comment(rawValue: path))
    }

    @Test("one definition: the policy predicate reads the walker's skip set")
    func sharedDefinition() {
        for token in SkipCategories.editorCacheDirs {
            #expect(CatalogScopePolicy.isEditorCachePath("/Volumes/X/\(token.uppercased())/clip.mov"))
        }
    }

    @Test("friendly label and raw key for the new reason; every reason has a label")
    func reasonLabel() {
        #expect(CatalogScopePolicy.SetAsideReason.editorCache.rawValue == "editor-cache")
        #expect(CatalogScopePolicy.SetAsideReason.editorCache.friendlyLabel
                == "Editor render caches (iMovie, Final Cut)")
        #expect(CatalogScopePolicy.SetAsideReason(rawValue: "editor-cache") == .editorCache)
        #expect(CatalogScopePolicy.SetAsideReason.allCases.allSatisfy { !$0.friendlyLabel.isEmpty })
    }

    @MainActor
    @Test("setAsideReason: a VIDEO under a cache dir is .editorCache; the same video elsewhere stays; pair protection still wins")
    func setAsideReasonPrecedence() {
        let cached = rec("Cache-30.mov", dir: "\(cacheRoot)/iMovie Movie Cache", stream: .videoAndAudio)
        #expect(CatalogScopePolicy.setAsideReason(for: cached, isVideoLinked: { _ in true }) == .editorCache)

        let keeper = rec("clip.mov", dir: cacheRoot, stream: .videoAndAudio)
        #expect(CatalogScopePolicy.setAsideReason(for: keeper, isVideoLinked: { _ in true }) == nil)

        // Path beats format: a still and an unlinked wav under a cache dir
        // both read .editorCache, not .stillImage / .unlinkedAudio.
        let thumb = rec("thumb.jpg", dir: "\(cacheRoot)/iMovie Thumbnails", stream: .videoOnly)
        #expect(CatalogScopePolicy.setAsideReason(for: thumb, isVideoLinked: { _ in false }) == .editorCache)
        let wav = rec("scratch.wav", dir: "/Volumes/X/Project/Render Files", stream: .audioOnly)
        #expect(CatalogScopePolicy.setAsideReason(for: wav, isVideoLinked: { _ in false }) == .editorCache)

        // HARD INVARIANT: a pair member under a cache dir is never set aside.
        let pairedA = rec("half.mxf", dir: "/Volumes/X/Project/Render Files", stream: .audioOnly)
        let pairedV = rec("halfV.mxf", dir: "/Volumes/X/Project/Render Files", stream: .videoOnly)
        pairedA.pairedWith = pairedV
        pairedV.pairedWith = pairedA
        pairedA.pairGroupID = UUID()
        #expect(CatalogScopePolicy.classifyRecord(pairedA) == nil)
        #expect(CatalogScopePolicy.setAsideReason(for: pairedA, isVideoLinked: { _ in false }) == nil)
        #expect(CatalogScopePolicy.setAsideReason(for: pairedV, isVideoLinked: { _ in false }) == nil)
    }
}

// MARK: - Tidy Catalog

@MainActor
@Suite("Editor caches — Tidy Catalog sets the existing rows aside")
struct EditorCacheTidyTests {

    @Test("plan: rows under cache dirs carry .editorCache with a correct tally; siblings and pair members are kept; apply hides + remembers; a same-content copy then comes back as junk")
    func planApplyAndCameBack() async throws {
        let model = try makeModel("tidy")
        let cache1 = rec("Cache-30.mov", dir: "\(cacheRoot)/iMovie Movie Cache", md5: "c1", size: 11)
        let cache2 = rec("thumb.jpg", dir: "\(cacheRoot)/iMovie Thumbnails", md5: "c2", size: 22, stream: .videoOnly)
        let cache3 = rec("scratch.wav", dir: "/Volumes/SanDisk/Project/Render Files", md5: "c3", size: 33, stream: .audioOnly)
        let keeper = rec("clip.mov", dir: cacheRoot, md5: "k1", size: 44)
        let lookAlike = rec("keep.mov", dir: "/Volumes/SanDisk/My Render Files Backup", md5: "k2", size: 55)
        let pairedA = rec("half.mxf", dir: "/Volumes/SanDisk/Project/Render Files", md5: "p1", size: 66, stream: .audioOnly)
        let pairedV = rec("halfV.mxf", dir: "/Volumes/SanDisk/Project/Render Files", md5: "p2", size: 77, stream: .videoOnly)
        pairedA.pairedWith = pairedV
        pairedV.pairedWith = pairedA
        pairedA.pairGroupID = UUID()
        model.records = [cache1, cache2, cache3, keeper, lookAlike, pairedA, pairedV]
        let countBefore = model.records.count

        let plan = await model.computeTidyCatalogPlan()
        #expect(plan.editorCacheCount == 3)
        #expect(plan.rows.count == 3)
        #expect(plan.rows.allSatisfy { $0.reason == .editorCache && !$0.cameBack })
        #expect(Set(plan.rows.map(\.filename)) == ["Cache-30.mov", "thumb.jpg", "scratch.wav"])
        // Path beats format: nothing double-counted as a still / unlinked audio.
        #expect(plan.stillCount == 0 && plan.unlinkedAudioCount == 0 && plan.musicCount == 0)
        #expect(plan.keptPairProtected == 2)
        #expect(plan.examined == 7)
        #expect(model.records.allSatisfy { $0.setAsideReason == nil }, "dry run mutates nothing")

        // CSV names the category (quoted: the label carries a comma).
        let csv = VideoScanModel.tidyPlanCSV(plan)
        #expect(csv.contains("\"Editor render caches (iMovie, Final Cut)\",Cache-30.mov,\(cacheRoot)/iMovie Movie Cache/Cache-30.mov,11"))

        // Apply: hide + remember, never remove.
        #expect(model.applyTidyCatalog(plan) == 3)
        #expect(model.records.count == countBefore, "Tidy never adds/removes records (pinned P0 class)")
        #expect(cache1.setAsideReason == "editor-cache")
        #expect(cache2.setAsideReason == "editor-cache")
        #expect(cache3.setAsideReason == "editor-cache")
        #expect(cache1.isSetAside)
        #expect(keeper.setAsideReason == nil && lookAlike.setAsideReason == nil)
        #expect(pairedA.setAsideReason == nil && pairedV.setAsideReason == nil)
        #expect(model.ignoredContentStore.count == 3)
        #expect(model.ignoredContentStore.reason(partialMD5: "c1", sizeBytes: 11, filename: "x") == "editor-cache")
        let applied = VideoScanModel.tidyAppliedCounts(plan, changed: Set(plan.rows.map(\.id)))
        #expect(applied.editorCache == 3 && applied.cameBack == 0)

        // A rescan catalogs the same bytes under a NON-cache path on another
        // drive: "Junk that came back" with the ORIGINAL reason — the ignore
        // list covers future copies for free.
        let copy = rec("Cache-30 copy.mov", dir: "/Volumes/SanDisk/Loose", md5: "c1", size: 11)
        model.records.append(copy)
        let second = await model.computeTidyCatalogPlan()
        #expect(second.rows.count == 1)
        #expect(second.junkCameBackCount == 1)
        #expect(second.editorCacheCount == 0, "a came-back row is not re-tallied as a fresh editor-cache row")
        #expect(second.rows.first?.cameBack == true)
        #expect(second.rows.first?.reason == .editorCache)
        #expect(second.rows.first?.filename == "Cache-30 copy.mov")
        #expect(VideoScanModel.tidyPlanCSV(second).contains("\"Junk that came back — Editor render caches (iMovie, Final Cut)\",Cache-30 copy.mov"))

        // Undo is the override: rows back, ignore list forgets them.
        #expect(model.undoLastTidyCatalog())
        #expect(cache1.setAsideReason == nil && cache2.setAsideReason == nil && cache3.setAsideReason == nil)
        #expect(model.ignoredContentStore.isEmpty)
        #expect(model.records.count == countBefore + 1)
    }

    @Test("idempotent: a second dry run after apply plans nothing")
    func secondDryRunEmpty() async throws {
        let model = try makeModel("idem")
        model.records = [rec("Cache-30.mov", dir: "\(cacheRoot)/iMovie Movie Cache", md5: "c1", size: 11)]
        let first = await model.computeTidyCatalogPlan()
        #expect(first.editorCacheCount == 1)
        #expect(model.applyTidyCatalog(first) == 1)
        let second = await model.computeTidyCatalogPlan()
        #expect(second.rows.isEmpty)
        #expect(second.editorCacheCount == 0)
    }
}

// MARK: - Truth (audit lines + sidecar)

@Suite("Editor caches — the audit says so")
struct EditorCacheAuditTruthTests {

    @Test("console block and one-line log name the editor-cache count")
    func summaryLinesCarryTheCount() {
        var audit = DiscoveryAudit()
        audit.skippedEditorCacheDirs = 7
        let lines = VideoScanModel.discoveryAuditLines(audit, volName: "LaCie", sidecarPath: nil)
        #expect(lines.contains { $0.contains("7 editor cache dir(s)") },
                "the Skipped line must carry the count (got \(lines))")
    }

    @Test("sidecar JSON round-trips the new count and path sample")
    func sidecarRoundTrips() throws {
        let dir = try tempRoot("sidecar")
        defer { try? FileManager.default.removeItem(at: dir) }
        let collector = DiscoveryAuditCollector(scanRoot: "/Volumes/T", volumeName: "T")
        collector.skippedEditorCacheDir(path: "/Volumes/T/A/iMovie Movie Cache")
        collector.skippedEditorCacheDir(path: "/Volumes/T/B/Render Files")
        let audit = collector.finish(cataloged: 0)
        #expect(audit.skippedEditorCacheDirs == 2)

        let path = try #require(DiscoveryAuditSidecar.write(audit, to: dir))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode(DiscoveryAudit.self, from: data)
        #expect(decoded.skippedEditorCacheDirs == 2)
        #expect(decoded.skippedEditorCacheDirPaths == ["/Volumes/T/A/iMovie Movie Cache", "/Volumes/T/B/Render Files"])
        // (Whole-struct equality is not asserted: ISO8601 drops sub-second
        // precision on startedAt/finishedAt, same as the existing sidecar test.)
        #expect(decoded.scanRoot == audit.scanRoot && decoded.pathListsTruncated == audit.pathListsTruncated)
        // Machine-readable key present by name (the sidecar is what a
        // person greps when asking "where did my file go?").
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"skippedEditorCacheDirPaths\""))
    }

    @Test("the path sample is capped; the count keeps counting")
    func pathSampleIsCapped() {
        let collector = DiscoveryAuditCollector(scanRoot: "/Volumes/T", volumeName: "T")
        let n = DiscoveryAuditCollector.maxRecordedPaths + 25
        for i in 0..<n { collector.skippedEditorCacheDir(path: "/Volumes/T/\(i)/Render Files") }
        let audit = collector.finish(cataloged: 0)
        #expect(audit.skippedEditorCacheDirs == n)
        #expect(audit.skippedEditorCacheDirPaths.count == DiscoveryAuditCollector.maxRecordedPaths)
        #expect(audit.pathListsTruncated)
    }
}

// MARK: - Scale

@Suite("Editor caches — scale")
struct EditorCacheScaleTests {

    @Test("100k paths through isEditorCachePath under budget")
    func hundredKPathsUnderBudget() {
        // Realistic shapes: deep .localized event trees, FCP bundles, Avid
        // MediaFiles; every 10th path sits under a cache directory.
        var paths: [String] = []
        paths.reserveCapacity(100_000)
        for i in 0..<100_000 {
            switch i % 10 {
            case 0:
                paths.append("/Volumes/LaCie/iMovie Events.localized/Event \(i / 10)/iMovie Movie Cache/Cache-\(i).mov")
            case 1:
                paths.append("/Volumes/LaCie/Avid MediaFiles/MXF/\(i % 40)/Tape\(i % 300)V01.\(String(format: "%08X", i)).mxf")
            case 2:
                paths.append("/Volumes/SanDisk/Projects/Trip.fcpbundle/Cape/Original Media/clip-\(i).mov")
            case 3:
                paths.append("/Volumes/SanDisk/Projects/My Render Files Backup/clip-\(i).mov")
            default:
                paths.append("/Volumes/LaCie/Family/\(1980 + i % 40)/Tape \(i % 500)/clip-\(i).mov")
            }
        }
        let start = ContinuousClock.now
        var hits = 0
        for p in paths where CatalogScopePolicy.isEditorCachePath(p) { hits += 1 }
        let elapsed = start.duration(to: .now)
        #expect(hits == 10_000)
        // Budget: ~8 components × 100k lowercased compares is well under a
        // second on Apple Silicon; 3 s is the generous fleet bound (M1 under
        // load). Asserted, not advisory.
        #expect(elapsed < .seconds(3), "100k isEditorCachePath took \(elapsed) — budget 3s")
    }
}
