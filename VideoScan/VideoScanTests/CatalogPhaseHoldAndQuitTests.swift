// CatalogPhaseHoldAndQuitTests.swift
// The tests that ImportToSQLiteTests.swift / ImportToSQLiteQuitTests.swift
// held for code that OUTLIVES Import to SQLite (retired 2026-10-20, "JSON
// gone"). Moved here unchanged in what they assert; only the suite names, the
// scene helper and the quit sensor (which pinned the retired import settle)
// changed. The removed tests covered only the retired job, marker, preflight,
// menu and quit settle.
//   • CatalogPhaseLogicTests — ImportPhaseVerdict and ImportToSQLiteTiming,
//     which Validate Catalog drives between its two phases.
//   • CatalogStoreHoldTests — the store's MOPS-16 owner-token hold (still in
//     CatalogStore and read by the committer; slice 2 decides its fate).
//   • CatalogQuitRecoveryTests — willTerminate's CHECKED save, the recovery
//     copy, the launch notice, the bounded hold.
//   • CatalogQuitRecoverySensorTests — the delegate's quit wiring after the
//     retirement: no import settle, the checked save, the launch notice.
// Suites (filter by SUITE): CatalogPhaseLogicTests · CatalogStoreHoldTests ·
// CatalogQuitRecoveryTests · CatalogQuitRecoverySensorTests

import AppKit
import CryptoKit
import Foundation
import Testing
@testable import VideoScan
@testable import VideoScanCore

// MARK: - Logic: the verdicts, the wait

@Suite("Catalog phase jobs — verdicts and the wait before Verify")
struct CatalogPhaseLogicTests {

    @Test("a phase job's terminal state: finished goes on, Stop stops, a failure stops the run with the phase's own words")
    func phaseVerdicts() {
        #expect(ImportPhaseVerdict.of(.finished(summary: "ok"), step: "the audit") == .proceed)
        #expect(ImportPhaseVerdict.of(.cancelled, step: "the audit") == .stopped)
        #expect(ImportPhaseVerdict.of(.cancelling, step: "the audit") == .stopped)
        #expect(ImportPhaseVerdict.of(.failed(message: "Refused — read-only"), step: "the audit")
                == .couldNotComplete("the audit could not complete: Refused — read-only"))
        #expect(ImportPhaseVerdict.of(.running, step: "Verify Catalog") == .couldNotComplete("Verify Catalog did not finish"))
    }

    @Test("Verify starts no earlier than the audit's finishing second + 1.5 s (the gate refuses finishedAt >= report start, whole seconds)")
    func theWaitBeforeVerify() {
        let finished = Date(timeIntervalSince1970: 1_000.2)
        #expect(abs(ImportToSQLiteTiming.verifyStartDelay(auditFinishedAt: finished, now: Date(timeIntervalSince1970: 1_000.3)) - 1.2) < 1e-6)
        #expect(ImportToSQLiteTiming.verifyStartDelay(auditFinishedAt: finished, now: Date(timeIntervalSince1970: 1_001.5)) == 0)
        #expect(ImportToSQLiteTiming.verifyStartDelay(auditFinishedAt: finished, now: Date(timeIntervalSince1970: 1_005)) == 0)
        let lateInSecond = Date(timeIntervalSince1970: 1_000.99)
        #expect(ImportToSQLiteTiming.verifyStartDelay(auditFinishedAt: lateInSecond, now: lateInSecond) < 0.52)
    }

    /// An injected wall clock: each read returns the next value (then the last, forever).
    @MainActor
    private final class SteppedClock {
        var readings: [TimeInterval]
        var sleeps: [TimeInterval] = []
        init(_ readings: [TimeInterval]) { self.readings = readings }
        func now() -> Date { Date(timeIntervalSince1970: readings.count > 1 ? readings.removeFirst() : readings[0]) }
    }

    @Test("P3 (codex 2026-10-17): the wall clock steps BACK 0.7 s during the wait — re-read after waking and waited again (0.7 s) until the audit's second + 1.5 s has truly passed")
    @MainActor
    func aBackwardClockStepWaitsAgain() async {
        let clock = SteppedClock([100.9, 100.8, 101.6])        // audit ended 100.9; slept 0.6; woke at 100.8
        let ready = await ImportToSQLiteTiming.waitForVerifyStart(auditFinishedAt: Date(timeIntervalSince1970: 100.9),
                                                                  now: clock.now, sleep: { clock.sleeps.append($0) })
        #expect(ready)
        #expect(clock.sleeps.count == 2)
        #expect(abs((clock.sleeps.first ?? 0) - 0.6) < 1e-6)
        #expect(abs((clock.sleeps.last ?? 0) - 0.7) < 1e-6)
    }

    @Test("P3: a clock that keeps stepping back is waited out a bounded number of times, then the wait says no")
    @MainActor
    func aClockThatKeepsSteppingBackGivesUp() async {
        let clock = SteppedClock([100.0])                      // never moves forward
        let ready = await ImportToSQLiteTiming.waitForVerifyStart(auditFinishedAt: Date(timeIntervalSince1970: 100.0),
                                                                  now: clock.now, sleep: { clock.sleeps.append($0) })
        #expect(!ready)
        #expect(clock.sleeps.count == ImportToSQLiteTiming.verifyWaitRounds)
    }
}

// MARK: - The store's hold with an owner token

@Suite("Catalog store — the hold (owner token)", .serialized)
@MainActor
struct CatalogStoreHoldTests {

    @Test("every write door refuses with .heldByJob and its words, nothing lands; releasing returns the count; the next save lands")
    func theStoreHoldRefusesEveryDoor() async throws {
        let sb = try ShowAgainSandbox.make("import_doors"); defer { sb.cleanup() }
        let store = sb.model.catalogStore
        let file = store.fileLocation
        #expect(await store.holdWrites(reason: "a test job", owner: CatalogWriteHoldOwner()) == .taken)
        #expect(store.saveNow(records: []) == false)
        #expect(await store.saveAcknowledged(records: []) == false)
        #expect(store.lastWriteError == .heldByJob("a test job"))
        #expect(store.lastWriteError?.userFacingDescription == "Catalog saving is paused while a test job. The change is kept in memory and saved when the job finishes.")
        #expect(!FileManager.default.fileExists(atPath: file), "nothing landed while held")
        #expect(store.writeHold == "a test job")
        #expect(store.releaseWriteHold() == 2)
        #expect(store.writeHold == nil)
        #expect(store.saveNow(records: []) == true)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test("the owner's acknowledged save passes the hold and moves the generation by one; the hold stays; it is not counted as held")
    func theOwnersSavePasses() async throws {
        let sb = try ShowAgainSandbox.make("import_owner"); defer { sb.cleanup() }
        let store = sb.model.catalogStore
        #expect(store.saveNow(records: []))
        let before = store.currentGeneration
        let owner = CatalogWriteHoldOwner()
        #expect(await store.holdWrites(reason: "a test job", owner: owner) == .taken)
        #expect(await store.saveAcknowledged(records: [], as: owner))
        #expect(store.currentGeneration == before + 1)
        #expect(CatalogSnapshot.headerProbe(at: URL(fileURLWithPath: store.fileLocation))?.generation == before + 1)
        #expect(store.writeHold == "a test job")
        #expect(store.releaseWriteHold() == 0)
    }

    @Test("a save presenting ANOTHER token, or none, is held while the owner's passes")
    func anotherTokenIsHeld() async throws {
        let sb = try ShowAgainSandbox.make("import_token"); defer { sb.cleanup() }
        let store = sb.model.catalogStore
        #expect(store.saveNow(records: []))
        let before = store.currentGeneration
        #expect(await store.holdWrites(reason: "a test job", owner: CatalogWriteHoldOwner()) == .taken)
        #expect(await store.saveAcknowledged(records: [], as: CatalogWriteHoldOwner()) == false)
        #expect(await store.saveAcknowledged(records: [], as: nil) == false)
        #expect(store.currentGeneration == before)
        #expect(store.releaseWriteHold() == 2)
    }

    @Test("P2 (codex 2026-10-17): taking the hold drains a save already admitted — it lands BEFORE holdWrites returns")
    func theHoldDrainsAnAdmittedSave() async throws {
        let sb = try ShowAgainSandbox.make("import_drain"); defer { sb.cleanup() }
        let store = sb.model.catalogStore
        #expect(store.saveNow(records: []))
        let before = store.currentGeneration
        store.testWriteDelay = 0.3
        store.saveAsync(records: [])                                     // admitted: on the write queue, in flight
        #expect(await store.holdWrites(reason: "a test job", owner: CatalogWriteHoldOwner()) == .taken)
        #expect(!store.hasUnsavedChanges)
        #expect(store.currentGeneration == before + 1)
        #expect(CatalogSnapshot.headerProbe(at: URL(fileURLWithPath: store.fileLocation))?.generation == before + 1)
        #expect(store.releaseWriteHold() == 0, "the admitted save was not refused — it landed")
    }

    @Test("P2: an acknowledged save in flight is an unsaved change (hasUnsavedChanges is truthful) until it lands")
    func anAcknowledgedSaveInFlightIsUnsaved() async throws {
        let sb = try ShowAgainSandbox.make("import_ackflight"); defer { sb.cleanup() }
        let store = sb.model.catalogStore
        store.testAfterWriteBeforeVerify = { _ in Thread.sleep(forTimeInterval: 0.3) }
        let saving = Task { @MainActor in await store.saveAcknowledged(records: []) }
        var sawInFlight = false
        for _ in 0..<20 where !sawInFlight {
            try await Task.sleep(for: .milliseconds(5))
            sawInFlight = store.hasUnsavedChanges
        }
        #expect(sawInFlight)
        #expect(await saving.value)
        #expect(!store.hasUnsavedChanges)
    }

    @Test("the audit's acknowledged save presents its owner token; the store lets ONLY that token past the hold, before the lock; saveNow and saveAsync present none")
    func theOwnerTokenPath() throws {
        let audit = try CatalogQuitRecoverySensorTests.code("MediaOps/CatalogAuditJob.swift")
        #expect(audit.contains("model.saveCatalogAcknowledged(asHoldOwner: writeHoldOwner)"))
        let store = try CatalogQuitRecoverySensorTests.code("Catalog/CatalogStore.swift")
        let hold = try #require(store.range(of: "if let hold = writeHold, owner != writeHoldOwner {"))
        let lock = try #require(store.range(of: "switch lock.acquire() {"))
        #expect(hold.lowerBound < lock.lowerBound)
        #expect(store.components(separatedBy: "writePrecondition(as: owner)").count == 2, "only saveAcknowledged presents a token")
        #expect(store.components(separatedBy: "if writePrecondition() != nil").count == 3, "saveNow and saveAsync present none")
    }
}

// MARK: - The quit's checked save and recovery copy

/// A sandboxed catalog folder with real small files and a SAVED catalog.json
/// (the store's generation = the file's), as in a live JSON-store session.
@MainActor
struct QuitScene {
    let sandbox: ShowAgainSandbox

    var catalogURL: URL { URL(fileURLWithPath: sandbox.model.catalogStore.fileLocation) }
    var folder: URL { catalogURL.deletingLastPathComponent() }

    static func make(_ label: String, rows: Int = 3) throws -> QuitScene {
        let sb = try ShowAgainSandbox.make("import_\(label)")
        try FileManager.default.createDirectory(at: sb.catalogDir, withIntermediateDirectories: true)
        for i in 0..<rows { try sb.live("clip\(i).mov", bytes: 2_000 + i) }
        guard sb.model.saveCatalogNow() else { throw CocoaError(.fileWriteUnknown) }
        return QuitScene(sandbox: sb)
    }

    func cleanup() { sandbox.cleanup() }
    func log() -> String { sandbox.catalogLogText() }
}

@Suite("Catalog quit — the checked save and the recovery copy", .serialized)
@MainActor
struct CatalogQuitRecoveryTests {

    private static let corrupt: @Sendable (URL) -> Void = { url in
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("tamper".utf8))
        try? handle.close()
    }

    @Test("P1: willTerminate's save is CHECKED — a refused save becomes a recovery copy and the branch is logged")
    func theTerminalSaveIsChecked() async throws {
        let scene = try QuitScene.make("terminal"); defer { scene.cleanup() }
        let model = scene.sandbox.model
        model.records.first?.userNotes = "saved at exit"
        model.catalogStore.testAfterWriteBeforeVerify = Self.corrupt
        let outcome = CatalogQuitRecovery.saveAtTermination(model: model, writerDeadline: 5)
        guard case .recoveryCopy(let url) = outcome else { Issue.record("expected a recovery copy, got \(outcome)"); return }
        #expect(url.lastPathComponent.hasPrefix(CatalogQuitRecovery.filePrefix))
        #expect(url.deletingLastPathComponent().path == scene.folder.path)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("saved at exit"))
        #expect(CatalogSnapshot.headerProbe(at: url) != nil)
        #expect(scene.log().contains("Catalog quit: app exit — the catalog could not be saved"))
        #expect(scene.log().contains("Catalog quit: START recovery copy"))
        #expect(scene.log().contains("Catalog quit: OUTCOME recovery copy written"))
        model.catalogStore.testAfterWriteBeforeVerify = nil
        #expect(CatalogQuitRecovery.saveAtTermination(model: model, writerDeadline: 5) == .saved)
    }

    @Test("P2: willTerminate behind a stalled writer SKIPS the synchronous save (it would block the main thread) and writes the recovery copy, within the bound, logged")
    func theTerminalSaveSkipsAStalledWriter() async throws {
        let scene = try QuitScene.make("terminal_stall"); defer { scene.cleanup() }
        let model = scene.sandbox.model
        let store = model.catalogStore
        store.testWriteDelay = 3
        store.saveAsync(records: model.records)                      // admitted, stalled on the write queue
        model.records.first?.userNotes = "edited behind a stalled save"
        let started = Date()
        let outcome = CatalogQuitRecovery.saveAtTermination(model: model, writerDeadline: 0.3)
        #expect(Date().timeIntervalSince(started) < 2, "bounded: the stalled writer is detected, not joined")
        guard case .recoveryCopy(let url) = outcome else { Issue.record("expected a recovery copy, got \(outcome)"); return }
        #expect(url.lastPathComponent.hasPrefix(CatalogQuitRecovery.filePrefix))
        #expect(try String(contentsOf: url, encoding: .utf8).contains("edited behind a stalled save"))
        #expect(scene.log().contains("the synchronous save is SKIPPED — writing a recovery copy instead"), Comment(rawValue: scene.log()))
        #expect(scene.log().contains("Catalog quit: OUTCOME recovery copy written"))
        for _ in 0..<1_000 where store.hasUnsavedChanges { try await Task.sleep(for: .milliseconds(10)) }
        store.testWriteDelay = 0
    }

    @Test("P1: willTerminate where the save AND the recovery copy fail (read-only folder) — .unsaved with the words and N, logged, nothing written")
    func theTerminalSaveBothFailing() async throws {
        let scene = try QuitScene.make("terminal_both")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scene.folder.path)
            scene.cleanup()
        }
        let model = scene.sandbox.model
        model.records.first?.userNotes = "nowhere to go"
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scene.folder.path)
        let outcome = CatalogQuitRecovery.saveAtTermination(model: model, writerDeadline: 5)
        guard case .unsaved(let words, let changes) = outcome else { Issue.record("expected unsaved, got \(outcome)"); return }
        #expect(words.contains("the catalog could not be saved"), Comment(rawValue: words))
        #expect(words.contains("the recovery copy also failed"), Comment(rawValue: words))
        #expect(changes == 1)
        #expect(scene.log().contains("Catalog quit: app exit — the catalog could not be saved"), Comment(rawValue: scene.log()))
        #expect(scene.log().contains("Catalog quit: OUTCOME recovery copy FAILED"))
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: scene.folder.path)) ?? [])
            .filter { $0.hasPrefix(CatalogQuitRecovery.filePrefix) }
        #expect(left.isEmpty, "nothing written: \(left)")
    }

    @Test("P1: the next launch says a recovery copy is beside the catalog — console + catalog.log — and merges nothing")
    func theNextLaunchSaysACopyIsThere() async throws {
        let scene = try QuitScene.make("launch"); defer { scene.cleanup() }
        let model = scene.sandbox.model
        #expect(CatalogQuitRecovery.launchNotice(catalogURL: scene.catalogURL) == nil)
        try Data("{}".utf8).write(to: scene.folder.appendingPathComponent("catalog.recovery-20261017-230000.json"))
        let before = model.records.map(\.userNotes)
        model.announceCatalogRecoveryCopies()
        #expect(scene.log().contains("Catalog quit: 1 catalog recovery copy from a quit that could not save is beside the catalog: catalog.recovery-20261017-230000.json. Nothing was merged."),
                Comment(rawValue: scene.log()))
        #expect(model.records.map(\.userNotes) == before)
    }

    // MARK: - A read-only session writes no copy (M5 viewer, 2026-10-21)
    //
    // The M5 viewer's every quit wrote an 80 MB catalog.recovery-*.json and
    // told the person to make it catalog.json: its read-only commit refused
    // (correctly), and the quit read the refusal as "could not be saved:
    // unknown". A viewer saves nothing by design — nothing is at risk.

    private static func recoveryCopies(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix(CatalogQuitRecovery.filePrefix) }
    }

    @Test("ISOLATION: a viewer's quit (its synced catalog on screen) writes NO recovery copy, and says why")
    func aViewerUnderSQLiteWritesNoCopy() async throws {
        let scene = try CutoverScene.make("quit_viewer_sqlite"); defer { scene.cleanup() }
        try await scene.importCatalog()
        try scene.writeLatch()
        _ = try await scene.sqliteLoad()               // a writer's first load fills the display tables (as the master's did)
        scene.model.applyReadOnlyMode(true)            // the role is known before the launch, as on the M5
        scene.model.records = scene.model.loadCatalogAtLaunch()
        #expect(scene.model.catalogCutover.committer == nil, "a viewer never opens its own catalog.sqlite (QA r1 F2)")
        scene.model.records = try await scene.sqliteLoad().records   // what the synced snapshot shows
        #expect(scene.model.saveCatalogNow() == false, "the viewer's save is refused — what the quit used to read as data at risk")
        try scene.record(.healthy).userNotes = "a viewer's launch-time change"
        let outcome = CatalogQuitRecovery.saveAtTermination(model: scene.model, writerDeadline: 5)
        guard case .readOnlySession(let words) = outcome else { Issue.record("expected no copy, got \(outcome)"); return }
        #expect(words.contains("viewer"), Comment(rawValue: words))
        #expect(Self.recoveryCopies(in: scene.folder).isEmpty)
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("Catalog quit: app exit — this Mac is a viewer"), Comment(rawValue: log))
        #expect(log.contains("no recovery copy is written"))
        #expect(!log.contains("START recovery copy"))
    }

    @Test("ISOLATION: a viewer on the JSON store writes NO recovery copy either")
    func aViewerOnJSONWritesNoCopy() async throws {
        let scene = try QuitScene.make("quit_viewer_json"); defer { scene.cleanup() }
        let model = scene.sandbox.model
        model.records.first?.userNotes = "a viewer edit"
        model.applyReadOnlyMode(true)
        #expect(CatalogQuitRecovery.saveAtTermination(model: model, writerDeadline: 5)
                == .readOnlySession(words: CatalogReadOnlyFacts(viewerRole: true).readOnlyWords ?? ""))
        #expect(Self.recoveryCopies(in: scene.folder).isEmpty)
        #expect(!scene.log().contains("START recovery copy"))
    }

    @Test("under catalog.sqlite a failed quit commit still writes the copy, with the committer's reason, and never says rename it to catalog.json")
    func theMasterUnderSQLiteNeverSaysRenameToCatalogJSON() async throws {
        let scene = try CutoverScene.make("quit_master_sqlite"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let committer = try #require(scene.model.catalogCutover.committer)
        try scene.record(.healthy).userNotes = "not committed at quit"
        committer.block("a test refusal")
        let outcome = CatalogQuitRecovery.saveAtTermination(model: scene.model, writerDeadline: 5)
        guard case .recoveryCopy(let url) = outcome else { Issue.record("expected a recovery copy, got \(outcome)"); return }
        #expect(try String(contentsOf: url, encoding: .utf8).contains("not committed at quit"))
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("could not be saved: the catalog can't save (a test refusal)"), Comment(rawValue: log))
        #expect(!log.contains("could not be saved: unknown"))
        #expect(log.contains("beside catalog.sqlite (the older JSON catalog format"))
        #expect(log.contains("do NOT rename it to catalog.json"))
        #expect(!log.contains("rename the copy to catalog.json"))
        let notice = try #require(CatalogQuitRecovery.launchNotice(catalogURL: scene.catalogURL))
        #expect(notice.contains("catalog.sqlite is the catalog"))
        #expect(!notice.contains("rename the copy to catalog.json"))
    }

    @Test("SENSOR: the quit's one copy writer sits behind the read-only gate")
    func theCopyWriterIsBehindTheGate() throws {
        let code = try CatalogQuitRecoverySensorTests.code("App/CatalogQuitRecovery.swift")
        #expect(code.contains("private static func writeCopyBlocking("))
        let gate = try #require(code.range(of: "if let readOnly = model.readOnlyFacts.readOnlyWords {"))
        let firstWrite = try #require(code.range(of: "return writeCopyBlocking("))
        #expect(gate.lowerBound < firstWrite.lowerBound, "the read-only gate comes before any copy")
    }

    @Test("P2: holdWrites is BOUNDED — an admitted save that does not drain gives the hold back within the bound (.writerStalled)")
    func theHoldGivesUpOnAStalledSave() async throws {
        let scene = try QuitScene.make("stallhold"); defer { scene.cleanup() }
        let store = scene.sandbox.model.catalogStore
        store.testWriteDelay = 2
        store.saveAsync(records: scene.sandbox.model.records)
        let started = Date()
        let result = await store.holdWrites(reason: "a test job", owner: CatalogWriteHoldOwner(), within: 0.3)
        #expect(Date().timeIntervalSince(started) < 1.5)
        #expect(result == .writerStalled(heldSaves: 0))
        #expect(store.writeHold == nil)
        for _ in 0..<1_000 where store.hasUnsavedChanges { try await Task.sleep(for: .milliseconds(10)) }
        store.testWriteDelay = 0
    }
}

@Suite("Catalog quit — delegate wiring sensors")
struct CatalogQuitRecoverySensorTests {

    static func code(_ name: String) throws -> String {
        try SourceTree.appSource(named: name).split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    @Test("both terminateLater paths reply through finishQuit; willTerminate makes the CHECKED save; launch announces recovery copies; no Import to SQLite settle is left")
    func theDelegateQuitWiring() throws {
        let app = try Self.code("App/VideoScanApp.swift")
        #expect(app.components(separatedBy: "NSApp.reply(toApplicationShouldTerminate: reply == .terminateNow)").count == 3)
        #expect(app.components(separatedBy: "await self?.finishQuit() ?? .terminateNow").count == 3, "both terminateLater paths")
        #expect(app.contains("if suspending || center.hasActivePruneApply {"))
        #expect(app.contains("CatalogQuitRecovery.saveAtTermination(model: model)"))
        #expect(!app.contains("catalogModel?.saveCatalogNow()"))
        #expect(app.contains("catalogModel?.announceCatalogRecoveryCopies()"))
        for retired in ["ImportToSQLiteQuit", "activeImportToSQLite", "ImportToSQLiteJob"] {
            #expect(!app.contains(retired), "VideoScanApp still names \(retired)")
        }
    }

    @Test("the retired Catalog menu items are gone; Reopen SQLite Catalog stays; Split Duplicate Groups by Full Hash stays (its finding's only door)")
    func theRetiredMenuItemsAreGone() throws {
        let app = try Self.code("App/VideoScanApp.swift")
        #expect(app.contains("CatalogReopenMenuItems(cutover: catalogModel.catalogCutover)"))
        #expect(!app.contains("ImportToSQLiteMenuItems"))
        #expect(!app.contains("CatalogSwitchMenuItems"))
        #expect(app.contains("Button(VideoScanModel.duplicateDigestSplitTitle)"))
        #expect(app.contains("fileOpsCenter.splitDuplicateGroupsKeepingSameFootage(model: catalogModel)"))
        #expect(!app.contains("attachImportDryRunMarker"))
        let reopen = try Self.code("Catalog/CatalogReopenMenuItems.swift")
        #expect(reopen.contains("Button(\"Reopen SQLite Catalog\")"))
        #expect(!reopen.contains("Switch Catalog to SQLite"))
        #expect(!MediaFileOperationKind.all.map(\.rawValue).contains("importToSQLite"))
        let split = try Self.code("MediaOps/VideoScanModel+DuplicateDigestSplit.swift")
        #expect(split.contains("func splitDuplicateGroupsKeepingSameFootage("))
    }

    @Test("QA 2026-10-20: the red duplicateGroupDigestsAgree finding names a door the Catalog menu offers, and no Catalog finding names a retired menu item")
    func digestFindingNamesALiveDoor() throws {
        let constraints = try Self.code("Integrity/CatalogConstraints.swift")
        let title = VideoScanModel.duplicateDigestSplitTitle
        #expect(constraints.contains(title + " settles it"), "the finding's words name \(title)")
        let app = try Self.code("App/VideoScanApp.swift")
        #expect(app.contains("Button(VideoScanModel.duplicateDigestSplitTitle)"), "…and the Catalog menu offers it")
        for name in ["Integrity/CatalogConstraints.swift", "Integrity/VerifyCatalogTiers.swift", "Integrity/VerifyCatalogJob.swift",
                     "MediaOps/ValidateCatalogJob.swift"] {
            let code = try Self.code(name)
            for retired in ["Import to SQLite", "Switch Catalog to SQLite", "Audit Catalog…", "Verify Catalog…"] {
                #expect(!code.contains(retired), "\(name) names the retired menu item \(retired)")
            }
        }
    }

    @Test("the per-drive right-click no longer offers Verify Catalog; Rescan and Update Catalog… stay")
    func theVolumeMenuKeepsRescanAndUpdate() throws {
        let table = try Self.code("Catalog/CatalogView+VolumeTable.swift")
        #expect(!table.contains("model.verifyCatalog(for:"))
        #expect(!table.contains("Label(\"Verify Catalog\""))
        #expect(table.contains("Rescan"))
        #expect(table.contains("Update Catalog…"))
    }
}

// MARK: - Fixture: the catalog.cutover latch's bytes

/// The latch Switch Catalog to SQLite… wrote (CatalogSwitch.latchData,
/// retired 2026-10-20) — byte-for-byte the same shape, for tests that need a
/// real latch with a `switchedAt` (Catalog Status reads it).
enum CatalogLatchFixture {
    static func data(_ run: CatalogRow.FinishedImport, at date: Date) -> Data {
        let iso = ISO8601DateFormatter().string(from: date)
        let text = #"{"switchedAt":"\#(iso)","importRun":"\#(run.runID)","sourceSHA256":"\#(run.sourceSHA256)","sourceGeneration":\#(run.sourceGeneration)}"#
        return Data((text + "\n").utf8)
    }
}
