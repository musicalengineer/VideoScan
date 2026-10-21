// CatalogQuitCornerTests.swift
// Corner-case matrix (Rick, 2026-10-21), the QUIT path under catalog.sqlite:
// what `CatalogQuitRecovery.saveAtTermination` (applicationWillTerminate's
// checked save) does when the session is a master whose final commit fails,
// and when it is a viewer that has nothing to save.
//
//   Case 3  master, pending edits, the final commit refused (another writer's
//           mark — the store flags the session for reopen). TODAY (pinned): a
//           recovery copy of the WHOLE in-memory catalog is written beside
//           catalog.json; catalog.sqlite is untouched; the committer stays
//           blocked (no silent retry); the quit's words carry the store's
//           refusal, never "unknown" (slice 2, 2026-10-21). PENDING (known
//           issues): the rescue holds only the delta (GH #356); the person gets a Keep Open / Quit-and-keep-
//           rescue choice, which needs the commit tried in
//           applicationShouldTerminate (willTerminate is too late to ask).
//   Case 4  viewer quit: nothing is saved (catalog.sqlite is byte-identical),
//           no recovery copy, no "could not be saved" lines — a viewer has
//           nothing to save (slice 2, 2026-10-21).
//
// Five dimensions: LOGIC (above) · SCALE N/A (the quit's cost is pinned by
// CatalogQuitRecoveryTests' bound) · MEDIA N/A · ISOLATION (CutoverScene
// sandbox; the viewer role is the test-host fact, never the real hostname)
// · SENSOR (the source check on applicationShouldTerminate).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Catalog quit corners — a failed final commit on a master, a viewer's quit", .serialized)
@MainActor
struct CatalogQuitCornerTests {

    @Test("case 3: master quit with pending edits whose final commit fails — today a whole-catalog recovery copy; catalog.sqlite untouched; no silent retry")
    func masterQuitWithFailedFinalCommit() async throws {
        let scene = try CutoverScene.make("corner_quit_master"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let committer = try #require(scene.model.catalogCutover.committer)
        #expect(scene.model.saveCatalogNow(), "the launch commit lands first")
        let databaseBefore = try await scene.sqliteLoad().generation
        // Another writer's mark: the session's next commit is refused (fail-fast).
        try Data("99\n".utf8).write(to: CatalogHighWater.url(besideDatabaseAt: scene.databaseURL))
        try scene.record(.healthy).userNotes = "typed just before quit"
        let total = scene.model.records.count

        let outcome = CatalogQuitRecovery.saveAtTermination(model: scene.model, writerDeadline: 5)
        let log = scene.sandbox.catalogLogText()
        guard case .recoveryCopy(let copy) = outcome else {
            Issue.record("expected today's recovery copy, got \(outcome)"); return
        }
        #expect(copy.deletingLastPathComponent().path == scene.folder.path)
        #expect(try String(contentsOf: copy, encoding: .utf8).contains("typed just before quit"))
        #expect(try await scene.sqliteLoad().generation == databaseBefore, "the refused commit wrote nothing")
        #expect(committer.blockedReason != nil, "the committer is blocked after the refusal")
        let attempts = committer.commitCount
        #expect(scene.model.saveCatalogNow() == false)
        #expect(committer.commitCount == attempts, "fail-fast: no second write is tried until a person reopens")

        let quitLine = log.components(separatedBy: "\n").first { $0.contains("app exit — the catalog could not be saved") } ?? ""
        #expect(!quitLine.isEmpty, Comment(rawValue: log))
        // Slice 2: the words are the committer's refusal, not the frozen JSON store's "unknown".
        #expect(quitLine.contains("another writer published generation 99"), Comment(rawValue: quitLine))
        #expect(!quitLine.contains("could not be saved: unknown"), Comment(rawValue: quitLine))
        let rescued = try Self.recordCount(copy)
        print("[corner-quit] recovery copy holds \(rescued) of \(total) records; 1 changed")
        withKnownIssue("GH #356: the rescue holds only the delta (the changed records), not the whole catalog") {
            #expect(rescued == 1, "the rescue holds \(rescued) records; 1 was changed")
        }
    }

    @Test("case 3 (SENSOR): a Keep Open choice needs the final commit tried in applicationShouldTerminate — pending")
    func keepOpenChoiceNeedsTheCommitBeforeTerminate() throws {
        let app = try SourceTree.strippingComments(SourceTree.appSource(named: "VideoScanApp.swift"))
        let start = try #require(app.range(of: "func applicationShouldTerminate("))
        let end = try #require(app.range(of: "func applicationWillTerminate(", range: start.upperBound..<app.endIndex))
        let shouldTerminate = String(app[start.upperBound..<end.lowerBound])
        withKnownIssue("pending: no Keep Open / Quit-and-keep-rescue choice — the commit runs only in willTerminate, after the quit is decided") {
            #expect(shouldTerminate.contains("saveCatalogNow") || shouldTerminate.contains("commitNow"),
                    "applicationShouldTerminate never tries the catalog's final commit")
        }
    }

    @Test("case 4: viewer quit — nothing saved, no recovery copy, no 'could not be saved' line")
    func viewerQuitSavesNothingAndSaysNothing() async throws {
        let scene = try CutoverScene.make("corner_quit_viewer"); defer { scene.cleanup() }
        try await scene.importCatalog()
        try scene.writeLatch()
        _ = try await scene.sqliteLoad()                        // the master's display pass
        scene.model.applyReadOnlyMode(true)
        scene.model.records = scene.model.loadCatalogAtLaunch()
        #expect(scene.model.catalogCutover.committer == nil, "a viewer never opens its own catalog.sqlite (QA r1 F2)")
        scene.model.records = try await scene.sqliteLoad().records   // what the synced snapshot shows
        let before = CornerFiles.catalogFingerprint(scene.databaseURL)
        let jsonBefore = try CornerFiles.sha256(scene.catalogURL)

        let outcome = CatalogQuitRecovery.saveAtTermination(model: scene.model, writerDeadline: 5)
        let log = scene.sandbox.catalogLogText()
        print("[corner-quit] viewer quit → \(outcome)")
        #expect(CornerFiles.catalogFingerprint(scene.databaseURL) == before, "a viewer's quit wrote to catalog.sqlite or a witness")
        #expect(try CornerFiles.sha256(scene.catalogURL) == jsonBefore, "a viewer's quit wrote catalog.json")
        let copies = CornerFiles.names(in: scene.folder, prefix: CatalogQuitRecovery.filePrefix)
        #expect(copies.isEmpty, "recovery copies on a viewer: \(copies)")
        #expect(!log.contains("could not be saved"), "a viewer's quit raised the not-saved alert")
        guard case .readOnlySession = outcome else { Issue.record("a viewer's quit produced \(outcome)"); return }
    }

    /// `records` in a recovery copy (the catalog's own JSON format).
    static func recordCount(_ url: URL) throws -> Int {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return (object?["records"] as? [Any])?.count ?? -1
    }
}
