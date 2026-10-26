// EditorCacheSkipReviewTests.swift
// 383-review — fresh-eyes review of a7ababa90 (GH #383). RED on that commit.
//
// Finding: "one policy, two entry points" holds for CHILD directories only.
// FilesystemWalker.walkTree seeds `dirStack` with the scan root and runs the
// `SkipCategories.editorCacheDirs` check only on entries it lists
// (FilesystemWalker.swift:134 vs :189). A scan target AT or INSIDE a cache
// directory — Rick drags `…/Christmas1990/iMovie Movie Cache` in to "see
// what's there", or a per-folder scan is pointed below `Render Files` —
// therefore admits every file, the discovery audit counts 0 editor cache
// dirs, and the next Tidy Catalog sets those same rows aside as
// `.editorCache`. Scan says yes, Tidy says junk: the two entry points drift
// for exactly the shape the ruling calls "never admitted at scan".
//
// Pins: FilesystemWalker.swift:134 (root pushed unchecked) and :189 (the
// only place the set is consulted). Expected fix shape: the same
// `CatalogScopePolicy.isEditorCachePath(root + "/")` test on the root
// before the walk, counted through `audit.skippedEditorCacheDir(path:)` so
// nothing is silent — or an explicit ruling that a root INSIDE a cache is
// Rick's intent, in which case this test flips and Tidy must honour it.

import Foundation
import Testing
@testable import VideoScan

private func reviewTempRoot(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_383_review_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func reviewTouch(_ root: URL, _ relative: String) throws {
    let url = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data(repeating: 0, count: 16).write(to: url)
}

@Suite("383-review — a scan rooted at or inside an editor cache dir")
struct EditorCacheScanRootReviewTests {

    /// The invariant the commit claims: everything the walker admits is
    /// something Tidy would keep (not `.editorCache`), and every cache
    /// directory the walk touches is counted in the audit.
    @Test("scan root at / inside a cache dir: walker must admit nothing and the audit must say why",
          arguments: [
            "iMovie Movie Cache",                 // root IS the cache dir
            "Project/Render Files/Segment 3",     // root is BELOW a cache dir
          ])
    func rootInsideCacheIsNotAdmitted(relativeRoot: String) async throws {
        let base = try reviewTempRoot("root")
        defer { try? FileManager.default.removeItem(at: base) }
        try reviewTouch(base, "\(relativeRoot)/Cache-30.mov")
        try reviewTouch(base, "\(relativeRoot)/Deeper/Cache-31.mov")
        let scanRoot = base.appendingPathComponent(relativeRoot, isDirectory: true)

        let thorough = ScanOptions.thorough
        let audit = DiscoveryAuditCollector(scanRoot: scanRoot.path, volumeName: "T")
        let found = await FilesystemWalker.walkDirectory(
            root: scanRoot.path,
            videoExtensions: ["mov", "mp4"],
            skipDirs: thorough.skipDirs(),
            skipBundleExtensions: thorough.skipBundleExtensions(),
            skipSmallFiles: thorough.skipSmallFiles,
            probeExtensionless: true,
            audit: audit
        )

        // One policy, two entry points: nothing the walker emits may be a
        // path Tidy would set aside as an editor cache.
        let wouldBeTidied = found.filter { CatalogScopePolicy.isEditorCachePath($0.path) }
        #expect(wouldBeTidied.isEmpty,
                "walker admitted \(wouldBeTidied.count) file(s) Tidy would set aside as .editorCache: \(wouldBeTidied.map(\.lastPathComponent))")
        #expect(found.isEmpty, "a scan rooted in a cache dir must admit nothing (got \(found.map(\.lastPathComponent)))")

        // Nothing silent: the audit names the cache dir it refused.
        let snapshot = audit.finish(cataloged: 0)
        #expect(snapshot.skippedEditorCacheDirs >= 1,
                "the audit must count the cache dir the root sits in (got \(snapshot.skippedEditorCacheDirs))")
        #expect(snapshot.filesAdmitted == 0)
    }

    /// Codex round 2, finding 2 (P1) — RED on db2f3fec9: the root
    /// precondition read the root's LITERAL spelling, `contentsOfDirectory`
    /// followed the symlink, and the file branch never looked at the
    /// enclosing path. A scan target `Preview` → `Project/Render Files`
    /// admitted `clip.mov`. Fix: the root is checked as spelled AND as
    /// resolved (realpath), and every directory the walk enters is checked
    /// again before its files are classified.
    @Test("scan root that is a SYMLINK into a cache dir: nothing admitted, one audited cache rejection")
    func symlinkedRootIntoCacheIsNotAdmitted() async throws {
        let base = try reviewTempRoot("symlink")
        defer { try? FileManager.default.removeItem(at: base) }
        try reviewTouch(base, "Project/Render Files/clip.mov")
        try reviewTouch(base, "Project/Render Files/Deeper/clip2.mov")
        let link = base.appendingPathComponent("Preview", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: base.appendingPathComponent("Project/Render Files", isDirectory: true))

        let thorough = ScanOptions.thorough
        let audit = DiscoveryAuditCollector(scanRoot: link.path, volumeName: "T")
        let found = await FilesystemWalker.walkDirectory(
            root: link.path,
            videoExtensions: ["mov", "mp4"],
            skipDirs: thorough.skipDirs(),
            skipBundleExtensions: thorough.skipBundleExtensions(),
            skipSmallFiles: thorough.skipSmallFiles,
            probeExtensionless: true,
            audit: audit
        )
        #expect(found.isEmpty, "a symlinked root into a cache dir must admit nothing (got \(found.map(\.lastPathComponent)))")

        let snapshot = audit.finish(cataloged: 0)
        #expect(snapshot.skippedEditorCacheDirs == 1,
                "exactly one audited cache rejection — the resolved root (got \(snapshot.skippedEditorCacheDirs)); audit: \(snapshot)")
        #expect(snapshot.filesEnumerated == 0 && snapshot.filesAdmitted == 0)
        // Refused by RULE, not by accident: the walk must not have failed
        // to read the directory (that would be a different, incomplete scan).
        #expect(snapshot.directoryEnumerationErrors == 0, "\(snapshot.unreadableDirectories)")
        // The sampled path names the REAL directory, so "where did my file
        // go?" has an answer that exists on disk.
        let sample = snapshot.skippedEditorCacheDirPaths.first ?? ""
        #expect(sample.hasSuffix("/Project/Render Files"), "got \(sample)")
    }
}
