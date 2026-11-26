// CatalogQuitCornerTests.swift
// Corner-case matrix (Rick, 2026-10-21), the QUIT path under catalog.sqlite:
// what `CatalogQuitRecovery.saveAtTermination` (applicationWillTerminate's
// checked save) does when the session is a master whose final commit fails,
// and when it is a viewer that has nothing to save.
//
//   Case 3  master, pending edits, the final commit refused (another writer's
//           mark — the store flags the session for reopen): the recovery copy
//           holds ONLY the unsaved records and the generation they were based
//           on (GH #356); catalog.sqlite is untouched; the committer stays
//           blocked (no silent retry); the quit's words carry the store's
//           refusal, never "unknown" (slice 2, 2026-10-21).
//   Keep Open (GH #356, Rick 2026-10-21) — the final commit is tried in
//           applicationShouldTerminate, while the quit can be cancelled:
//           an edit inside the debounce window lands with no question; a
//           job's hold is waited out (bounded) and the edit lands when it
//           lets go; a hold that stays, or a refused commit, asks "couldn't
//           save N changes: <words>" — Keep Open keeps the session (nothing
//           written, the edit in memory, it lands once the cause clears);
//           a session that turned read-only (role flip) with accepted edits
//           asks too, and Quit writes the delta-only copy. Each ends with a
//           relaunch read of catalog.sqlite.
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

    @Test("case 3: master quit with pending edits whose final commit fails — the recovery copy holds only the unsaved record and its base generation; catalog.sqlite untouched; no silent retry")
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
            Issue.record("expected a recovery copy, got \(outcome)"); return
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
        #expect(rescued == 1, "the rescue holds \(rescued) records; 1 was changed (GH #356)")
        #expect(try Self.generation(copy) == databaseBefore, "the copy names the generation its changes were based on")
        #expect(log.contains("writing the 1 unsaved record(s) of \(total), based on generation \(databaseBefore)"), Comment(rawValue: log))
    }

    @Test("case 3 (SENSOR): the final commit is tried in applicationShouldTerminate (fast path) and in finishQuit (every terminateLater path), which can cancel the quit — Keep Open")
    func keepOpenChoiceNeedsTheCommitBeforeTerminate() throws {
        let app = try SourceTree.strippingComments(SourceTree.appSource(named: "VideoScanApp.swift"))
        let start = try #require(app.range(of: "func applicationShouldTerminate("))
        let end = try #require(app.range(of: "func applicationWillTerminate(", range: start.upperBound..<app.endIndex))
        let shouldTerminate = String(app[start.upperBound..<end.lowerBound])
        #expect(shouldTerminate.contains("CatalogQuitRecovery.quitNeedsNoQuestion(model: catalogModel)"),
                "applicationShouldTerminate never tries the catalog's final commit")
        #expect(shouldTerminate.contains("CatalogQuitRecovery.finalCommitBeforeQuit(model: catalogModel, ask: CatalogQuitRecovery.askWithAlert)"))
        #expect(shouldTerminate.contains("return proceed ? .terminateNow : .terminateCancel"), "Keep Open must be able to cancel the quit")
        let recovery = try SourceTree.strippingComments(SourceTree.appSource(named: "CatalogQuitRecovery.swift"))
        #expect(recovery.contains("return model.saveCatalogNow()"), "the fast path is the committer's synchronous commit")
        #expect(recovery.contains("alert.addButton(withTitle: \"Keep Open\")\n        alert.addButton(withTitle: \"Quit and Keep a Rescue Copy\")"),
                "Keep Open is the first (default) button")
    }

    // MARK: - Keep Open (GH #356): the catalog-writer corners, each ending in a relaunch read

    @Test("Keep Open: an edit inside the debounce window lands at quit with no question; relaunch shows it")
    func editInsideTheDebounceWindowLandsAtQuit() async throws {
        let scene = try CutoverScene.make("corner_quit_debounce"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let committer = try #require(scene.model.catalogCutover.committer)
        #expect(scene.model.saveCatalogNow())
        scene.model.setUserNotes("typed 0.1 s before Quit", for: try scene.record(.healthy))
        #expect(committer.isBusy, "the edit is inside the debounce window")
        let asked = AskLog()
        let proceed = await CatalogQuitRecovery.finalCommitBeforeQuit(model: scene.model, holdWait: 1, ask: asked.answer(.keepOpen))
        #expect(proceed && asked.questions.isEmpty, "\(asked.questions)")
        #expect(try await scene.reloaded(.healthy).userNotes == "typed 0.1 s before Quit")
    }

    @Test("Keep Open: during a job's write hold the quit waits (bounded); the hold lets go and the edit lands with no question; relaunch shows it")
    func holdThatClearsIsWaitedOut() async throws {
        let scene = try CutoverScene.make("corner_quit_hold_clears"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        #expect(scene.model.saveCatalogNow())
        let store = scene.model.catalogStore
        #expect(await store.holdWrites(reason: "a test job", owner: CatalogWriteHoldOwner()) == .taken)
        scene.model.setUserNotes("typed while a job held writes", for: try scene.record(.healthy))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            _ = store.releaseWriteHold()
        }
        let asked = AskLog()
        let proceed = await CatalogQuitRecovery.finalCommitBeforeQuit(model: scene.model, holdWait: 5, ask: asked.answer(.keepOpen))
        #expect(proceed && asked.questions.isEmpty, "\(asked.questions)")
        #expect(scene.sandbox.catalogLogText().contains("a job holds catalog writes; waiting up to 5 s"))
        #expect(try await scene.reloaded(.healthy).userNotes == "typed while a job held writes")
    }

    @Test("Keep Open: a hold that does not let go asks 'couldn't save 1 change: … held …'; Keep Open writes nothing and keeps the edit; once the hold lets go it saves; relaunch shows it")
    func holdThatStaysAsksAndKeepOpenKeepsTheEdit() async throws {
        let scene = try CutoverScene.make("corner_quit_hold_stays"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let committer = try #require(scene.model.catalogCutover.committer)
        #expect(scene.model.saveCatalogNow())
        let before = try await scene.sqliteLoad().generation
        let store = scene.model.catalogStore
        #expect(await store.holdWrites(reason: "a test job", owner: CatalogWriteHoldOwner()) == .taken)
        scene.model.setUserNotes("typed while the hold stayed", for: try scene.record(.healthy))
        let asked = AskLog()
        let proceed = await CatalogQuitRecovery.finalCommitBeforeQuit(model: scene.model, holdWait: 0.3, ask: asked.answer(.keepOpen))
        #expect(!proceed, "Keep Open must cancel the quit")
        let question = try #require(asked.questions.first)
        #expect(question.changes == 1 && question.message == "VideoScan couldn't save 1 change", "\(question)")
        #expect(question.words.contains("held — a test job"), Comment(rawValue: question.words))
        #expect(try await scene.sqliteLoad().generation == before, "Keep Open wrote something")
        #expect(committer.blockedReason == nil, "a hold is not a refusal: the session must stay able to save")
        #expect(scene.sandbox.catalogLogText().contains("quit cancelled — Keep Open"))
        _ = store.releaseWriteHold()
        #expect(scene.model.saveCatalogNow(), "the kept edit saves once the hold lets go")
        #expect(try await scene.reloaded(.healthy).userNotes == "typed while the hold stayed")
    }

    @Test("Keep Open: a refused final commit (another writer's mark) asks with the committer's words; Keep Open writes nothing and tries no second write; relaunch reads the old value")
    func refusedCommitAsksWithTheCommittersWords() async throws {
        let scene = try CutoverScene.make("corner_quit_refused"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let committer = try #require(scene.model.catalogCutover.committer)
        #expect(scene.model.saveCatalogNow())
        let before = try await scene.reloaded(.healthy).userNotes
        try Data("99\n".utf8).write(to: CatalogHighWater.url(besideDatabaseAt: scene.databaseURL))
        scene.model.setUserNotes("typed before a refused quit", for: try scene.record(.healthy))
        let asked = AskLog()
        let proceed = await CatalogQuitRecovery.finalCommitBeforeQuit(model: scene.model, holdWait: 1, ask: asked.answer(.keepOpen))
        #expect(!proceed)
        let question = try #require(asked.questions.first)
        #expect(question.words.contains("another writer published generation 99"), Comment(rawValue: question.words))
        #expect(question.changes == 1, "\(question)")
        let attempts = committer.commitCount
        #expect(await CatalogQuitRecovery.finalCommitBeforeQuit(model: scene.model, holdWait: 1, ask: asked.answer(.quitKeepingRescueCopy)))
        #expect(committer.commitCount == attempts, "fail-fast: a second quit asks again but writes nothing")
        #expect(try await scene.reloaded(.healthy).userNotes == before)
    }

    @Test("Keep Open: across a role flip — a session that turned read-only with an accepted edit asks; Quit writes the delta-only copy (1 record); relaunch reads the old value")
    func roleFlipWithAcceptedEditAsksThenRescuesTheDelta() async throws {
        let scene = try CutoverScene.make("corner_quit_role_flip"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        #expect(scene.model.saveCatalogNow())
        let before = try await scene.reloaded(.healthy).userNotes
        try Data("99\n".utf8).write(to: CatalogHighWater.url(besideDatabaseAt: scene.databaseURL))
        scene.model.setUserNotes("typed just before the role flip", for: try scene.record(.healthy))
        scene.model.applyReadOnlyMode(true)                        // the commit before the flip is refused
        try #require(scene.model.unsavedFromWritableSession != nil)
        let asked = AskLog()
        let proceed = await CatalogQuitRecovery.finalCommitBeforeQuit(model: scene.model, holdWait: 1, ask: asked.answer(.quitKeepingRescueCopy))
        #expect(proceed && asked.questions.count == 1, "\(asked.questions)")
        let outcome = CatalogQuitRecovery.saveAtTermination(model: scene.model, writerDeadline: 5)
        guard case .recoveryCopy(let copy) = outcome else { Issue.record("\(outcome)"); return }
        #expect(try Self.recordCount(copy) == 1)
        #expect(try String(contentsOf: copy, encoding: .utf8).contains("typed just before the role flip"))
        #expect(try await scene.reloaded(.healthy).userNotes == before)
    }

    @Test("Keep Open: a viewer (read-only, nothing accepted) and a session with nothing changed quit with no question")
    func nothingAtRiskQuitsWithoutAQuestion() async throws {
        let scene = try CutoverScene.make("corner_quit_nothing"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        #expect(scene.model.saveCatalogNow())
        let asked = AskLog()
        #expect(await CatalogQuitRecovery.finalCommitBeforeQuit(model: scene.model, holdWait: 1, ask: asked.answer(.keepOpen)))
        scene.model.applyReadOnlyMode(true)
        #expect(await CatalogQuitRecovery.finalCommitBeforeQuit(model: scene.model, holdWait: 1, ask: asked.answer(.keepOpen)))
        #expect(await CatalogQuitRecovery.finalCommitBeforeQuit(model: nil, holdWait: 1, ask: asked.answer(.keepOpen)))
        #expect(asked.questions.isEmpty, "\(asked.questions)")
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

    /// The generation a recovery copy says its changes were based on.
    static func generation(_ url: URL) throws -> Int {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return (object?["generation"] as? Int) ?? -1
    }

    /// The questions the quit asked, and a fixed answer (the alert's stand-in).
    @MainActor final class AskLog {
        private(set) var questions: [CatalogQuitRecovery.QuitQuestion] = []
        func answer(_ choice: CatalogQuitRecovery.QuitChoice) -> (CatalogQuitRecovery.QuitQuestion) -> CatalogQuitRecovery.QuitChoice {
            { [self] question in questions.append(question); return choice }
        }
    }
}
