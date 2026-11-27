// CatalogRescueApplyTests.swift
// GH #520 (rest of #356; DECISIONS 2026-11-27 (3)): the quit rescue copy's
// launch notice — Apply… / Discard… / Later (CatalogRescueApply.swift) and the
// basis the quit now writes into the copy (CatalogRescueBasis.swift).
//
// Every scene is a real quit through the real door: launch on catalog.sqlite,
// a job holds catalog writes, edits are typed, the quit asks and writes the
// rescue copy (CatalogQuitRecovery.finalCommitBeforeQuit), then a NEW model
// launches on the same folder (CutoverScene sandbox — never Application
// Support; the Trash is MediaTrash's per-process test trash).
//
// Dimensions (CLAUDE.md rule 8):
//   LOGIC      no conflict ⇒ every rescued record applied, the backup made
//              first (Back Up Catalog's own bundle), the copy kept as
//              catalog.applied-recovery-…; a record the catalog changed since
//              ⇒ listed with why and left as the catalog has it; a backup that
//              fails ⇒ nothing applied; an old copy with no basis ⇒ nothing
//              applied, each record says why; a new record (never stored) is
//              applied; Discard ⇒ the Trash; a non-rescue file is refused.
//              The pure check (`plan`) per reason.
//   WRITER     an edit inside the debounce window before Apply lands first
//              (through the backup's commit) and wins; a job's write hold
//              refuses Apply in words; a role flip to read-only refuses Apply
//              in words; each ends in a relaunch read.
//   RELAUNCH   the notice's list keeps the copy across launches until it is
//              applied or discarded.
//   TRUTH      the copy's header carries the basis — the base generation and
//              one stored-row digest per rescued record — from both quit
//              writers; the outcome's counts are the commit's, re-read from
//              catalog.sqlite; the audit trail names the `rescue apply` door.
//   SCALE      the check over 100,000 live records and 5,000 rescued ones,
//              within a budget.
//   SENSOR     source: Apply goes through the commit door, the Back Up
//              Catalog engine and THE one Trash call; never removes, replaces
//              or writes catalog.sqlite itself; the launch wiring is there.
//   MEDIA      N/A — no media is opened.
//
// Suites (filter by SUITE): CatalogRescueApplyTests · CatalogRescueApplyLogicTests · CatalogRescueApplySensorTests

import Foundation
import SQLite3
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - The scene

@MainActor
extension CutoverScene {

    /// Launch, save, a job takes the write hold, `edits` are typed, and the
    /// quit writes a rescue copy through the real door. Returns the copy.
    func quitWithRescue(_ edits: [(PoisonedCatalogFixture.Shape, String)]) async throws -> URL {
        try await launchOnSQLite()
        #expect(model.saveCatalogNow(), "the launch commit lands first")
        #expect(await model.catalogStore.holdWrites(reason: "a test job", owner: CatalogWriteHoldOwner()) == .taken)
        for (shape, notes) in edits { model.setUserNotes(notes, for: try record(shape)) }
        let asked = CatalogQuitCornerTests.AskLog()
        let decided = await CatalogQuitRecovery.finalCommitBeforeQuit(model: model, holdWait: 0.2,
                                                                      ask: asked.answer(.quitKeepingRescueCopy), tell: asked.tell)
        guard case .quitWithRescue(let copy) = decided else { throw CutoverFailure(words: "no rescue copy: \(decided)") }
        return copy.url
    }

    /// A NEW model on the same folder, launched from `previous` (its store closed, as at quit).
    func relaunch(from previous: VideoScanModel) async throws -> VideoScanModel {
        if let committer = previous.catalogCutover.committer { await committer.repository.close() }
        let fresh = VideoScanModel(logDirectory: sandbox.logs)
        fresh.catalogStore = CatalogStore(directory: sandbox.catalogDir)
        fresh.mediaLedger = MediaLedger(directory: sandbox.root.appendingPathComponent("ledger", isDirectory: true))
        fresh.records = fresh.loadCatalogAtLaunch()
        try #require(fresh.catalogCutover.isSQLiteAuthority, "the relaunch opened catalog.sqlite")
        return fresh
    }

    /// Production's Apply context, the alerts answered by the test and the
    /// backup aimed at the sandbox (Back Up Catalog's real engine).
    func rescueContext(_ on: VideoScanModel, confirm: Bool = true, backup: URL? = nil) throws -> CatalogRescueApply.Context {
        var context = try #require(CatalogRescueApply.Context.live(model: on))
        context.confirm = { _ in confirm }
        let target = backup ?? backupURL
        context.chooseBackup = { target }
        let side = sandboxSideFiles
        context.backUp = { [weak on] url in await on?.backUpCatalog(to: url, sideFiles: side) ?? .refused("gone") }
        return context
    }

    func pending() -> [URL] { CatalogRescueApply.pendingCopies(besideCatalog: catalogURL) }

    func stored(_ shape: PoisonedCatalogFixture.Shape) async throws -> String { try await reloaded(shape).userNotes }

    /// One integer from the sandbox database, through a read-only connection.
    func sqliteInt(_ sql: String) throws -> Int {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw CutoverFailure(words: "open") }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else {
            throw CutoverFailure(words: "\(sql): \(String(cString: sqlite3_errmsg(db)))")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// The Back Up Catalog bundle's manifest.
    func rescueBackupManifest() throws -> BundleManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BundleManifest.self, from: Data(contentsOf: backupURL.appendingPathComponent("manifest.json")))
    }

    /// The copy's header `rescueBasis`, as written.
    static func basis(_ copy: URL) throws -> [String: Any]? {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: copy)) as? [String: Any]
        return object?["rescueBasis"] as? [String: Any]
    }
}

// MARK: - Apply / Discard / Later, end to end

@Suite("Quit rescue copy — Apply… / Discard… / Later at launch (GH #520)", .serialized)
@MainActor
struct CatalogRescueApplyTests {

    typealias Why = CatalogRescueApply.Why

    @Test("no conflict: the backup is made first, every rescued record is applied, the copy is kept as applied; relaunch shows the values and no notice")
    func noConflictAppliesAllAfterTheBackup() async throws {
        let scene = try CutoverScene.make("rescue_apply_all"); defer { scene.cleanup() }
        let copy = try await scene.quitWithRescue([(.healthy, "rescued note A"), (.stalePrint, "rescued note B")])
        let before = try await scene.sqliteLoad().generation
        let fresh = try await scene.relaunch(from: scene.model)
        #expect(scene.pending() == [copy], "the notice offers the copy")

        let outcome = await CatalogRescueApply.apply(rescue: copy, context: try scene.rescueContext(fresh))
        guard case .applied(let report) = outcome else { Issue.record("\(outcome)"); return }
        #expect(Set(report.applied.map(\.name)) == [try scene.record(.healthy).filename, try scene.record(.stalePrint).filename])
        #expect(report.notApplied.isEmpty, "\(report.notApplied)")
        #expect(report.backup.resolvingSymlinksInPath().path == scene.backupURL.resolvingSymlinksInPath().path, "\(report.backup.path)")
        let manifest = scene.backupURL.appendingPathComponent("manifest.json")
        #expect(FileManager.default.fileExists(atPath: manifest.path), "the backup is Back Up Catalog's bundle")
        let backupGeneration = try #require(try scene.rescueBackupManifest().catalogDatabase?.generation)
        #expect(backupGeneration == before, "the backup holds the catalog as it was BEFORE the apply (Restore undoes it)")
        #expect(try await scene.stored(.healthy) == "rescued note A")
        #expect(try await scene.stored(.stalePrint) == "rescued note B")
        #expect(try scene.sqliteInt("SELECT count(*) FROM generation_history WHERE writer = 'rescue apply'") == 1,
                "one commit, under its own door")
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(report.keptAs.lastPathComponent.hasPrefix(CatalogRescueApply.appliedPrefix))
        #expect(FileManager.default.fileExists(atPath: report.keptAs.path), "the rescue copy is kept until Discard")
        #expect(scene.pending().isEmpty, "an applied copy is not offered again")
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("rescue copy — START Apply \(copy.lastPathComponent)"), Comment(rawValue: log))
        #expect(log.contains("OUTCOME Apply \(copy.lastPathComponent) — applied 2, not applied 0 of 2"), Comment(rawValue: log))

        let again = try await scene.relaunch(from: fresh)
        #expect(again.records.first { $0.id.uuidString == PoisonedCatalogFixture.id(.healthy) }?.userNotes == "rescued note A")
        #expect(scene.pending().isEmpty)
    }

    @Test("conflict: a record the catalog changed after the copy was made is listed with why and left as the catalog has it; the other is applied")
    func conflictIsListedAndLeft() async throws {
        let scene = try CutoverScene.make("rescue_apply_conflict"); defer { scene.cleanup() }
        let copy = try await scene.quitWithRescue([(.healthy, "rescued A"), (.stalePrint, "rescued B")])
        let fresh = try await scene.relaunch(from: scene.model)
        let stale = try #require(fresh.records.first { $0.id.uuidString == PoisonedCatalogFixture.id(.stalePrint) })
        fresh.setUserNotes("typed after the relaunch", for: stale)
        #expect(fresh.saveCatalogNow())

        let outcome = await CatalogRescueApply.apply(rescue: copy, context: try scene.rescueContext(fresh))
        guard case .applied(let report) = outcome else { Issue.record("\(outcome)"); return }
        #expect(report.applied.map(\.id) == [try scene.record(.healthy).id])
        #expect(report.notApplied.map(\.id) == [stale.id])
        #expect(report.notApplied.first?.why == Why.changed)
        #expect(try await scene.stored(.stalePrint) == "typed after the relaunch", "a conflict is left as the catalog has it")
        #expect(try await scene.stored(.healthy) == "rescued A")
        #expect(CatalogRescueApply.reportTitle(report) == "Rescue Copy Partly Applied")
        let text = CatalogRescueApply.reportText(report)
        #expect(text.contains("Not applied — left as they are in the catalog (1):\n• \(stale.filename): \(Why.changed)"), Comment(rawValue: text))
        #expect(scene.sandbox.catalogLogText().contains("NOT APPLIED \(stale.filename) (\(stale.id.uuidString)) — \(Why.changed)"))
    }

    @Test("WRITER: an edit typed inside the debounce window before Apply lands first (the backup's commit) and wins; relaunch shows it")
    func editInsideTheDebounceWindowWins() async throws {
        let scene = try CutoverScene.make("rescue_apply_debounce"); defer { scene.cleanup() }
        let copy = try await scene.quitWithRescue([(.healthy, "rescued A")])
        let fresh = try await scene.relaunch(from: scene.model)
        let healthy = try #require(fresh.records.first { $0.id.uuidString == PoisonedCatalogFixture.id(.healthy) })
        fresh.setUserNotes("typed 0.1 s before Apply", for: healthy)
        #expect(try #require(fresh.catalogCutover.committer).isBusy, "the edit is inside the debounce window")

        let outcome = await CatalogRescueApply.apply(rescue: copy, context: try scene.rescueContext(fresh))
        guard case .applied(let report) = outcome else { Issue.record("\(outcome)"); return }
        #expect(report.applied.isEmpty && report.notApplied.first?.why == Why.changed, "\(report)")
        let again = try await scene.relaunch(from: fresh)
        #expect(again.records.first { $0.id == healthy.id }?.userNotes == "typed 0.1 s before Apply")
    }

    @Test("backup failure: nothing is applied, the words say why, the copy stays offered")
    func backupFailureAppliesNothing() async throws {
        let scene = try CutoverScene.make("rescue_apply_no_backup"); defer { scene.cleanup() }
        let copy = try await scene.quitWithRescue([(.healthy, "rescued A")])
        let fresh = try await scene.relaunch(from: scene.model)
        let before = try await scene.stored(.healthy)
        let generation = try await scene.sqliteLoad().generation
        let notABundle = scene.backupURL.deletingPathExtension().appendingPathExtension("txt")

        let outcome = await CatalogRescueApply.apply(rescue: copy, context: try scene.rescueContext(fresh, backup: notABundle))
        guard case .refused(let words) = outcome else { Issue.record("\(outcome)"); return }
        #expect(words.hasPrefix("the catalog backup could not be made ("), Comment(rawValue: words))
        #expect(words.hasSuffix("so nothing was applied"), Comment(rawValue: words))
        #expect(try await scene.stored(.healthy) == before)
        #expect(try await scene.sqliteLoad().generation == generation, "nothing was committed")
        #expect(scene.pending() == [copy], "the copy is kept and offered again")
        #expect(scene.sandbox.catalogLogText().contains("REFUSED Apply \(copy.lastPathComponent) — the catalog backup could not be made"))
    }

    @Test("WRITER: during a job's write hold Apply is refused in words before any backup; the copy stays offered after a relaunch")
    func writeHoldRefusesApply() async throws {
        let scene = try CutoverScene.make("rescue_apply_hold"); defer { scene.cleanup() }
        let copy = try await scene.quitWithRescue([(.healthy, "rescued A")])
        let fresh = try await scene.relaunch(from: scene.model)
        let before = try await scene.stored(.healthy)
        #expect(await fresh.catalogStore.holdWrites(reason: "another test job", owner: CatalogWriteHoldOwner()) == .taken)

        let outcome = await CatalogRescueApply.apply(rescue: copy, context: try scene.rescueContext(fresh))
        guard case .refused(let words) = outcome else { Issue.record("\(outcome)"); return }
        #expect(words.contains("held — another test job"), Comment(rawValue: words))
        #expect(!FileManager.default.fileExists(atPath: scene.backupURL.path), "no backup before a refusal")
        #expect(try await scene.stored(.healthy) == before)
        _ = fresh.catalogStore.releaseWriteHold()
        _ = try await scene.relaunch(from: fresh)
        #expect(scene.pending() == [copy])
    }

    @Test("WRITER: a session flipped to read-only refuses Apply in words; nothing is backed up or applied; relaunch still offers the copy")
    func readOnlySessionRefusesApply() async throws {
        let scene = try CutoverScene.make("rescue_apply_read_only"); defer { scene.cleanup() }
        let copy = try await scene.quitWithRescue([(.healthy, "rescued A")])
        let fresh = try await scene.relaunch(from: scene.model)
        let before = try await scene.stored(.healthy)
        fresh.applyReadOnlyMode(true)

        let outcome = await CatalogRescueApply.apply(rescue: copy, context: try scene.rescueContext(fresh))
        guard case .refused(let words) = outcome else { Issue.record("\(outcome)"); return }
        #expect(words.hasPrefix("this session is read-only ("), Comment(rawValue: words))
        #expect(words.hasSuffix("so nothing can be applied here"), Comment(rawValue: words))
        #expect(!FileManager.default.fileExists(atPath: scene.backupURL.path))
        #expect(try await scene.stored(.healthy) == before)
        fresh.applyReadOnlyMode(false)
        _ = try await scene.relaunch(from: fresh)
        #expect(scene.pending() == [copy])
    }

    @Test("Discard moves the copy to the Trash (where it can be put back); relaunch offers nothing; Cancel keeps it")
    func discardMovesToTheTrash() async throws {
        let scene = try CutoverScene.make("rescue_discard"); defer { scene.cleanup() }
        let copy = try await scene.quitWithRescue([(.healthy, "rescued A")])
        let fresh = try await scene.relaunch(from: scene.model)
        let before = try await scene.stored(.healthy)
        var lines: [String] = []
        let bytes = try Data(contentsOf: copy)

        #expect(CatalogRescueApply.discard(rescue: copy, besideCatalog: scene.catalogURL, note: { lines.append($0) }, confirm: { _ in false }) == .cancelled)
        #expect(scene.pending() == [copy], "Cancel keeps the copy")
        let outcome = CatalogRescueApply.discard(rescue: copy, besideCatalog: scene.catalogURL, note: { lines.append($0) }, confirm: { _ in true })
        guard case .discarded(let trashed) = outcome else { Issue.record("\(outcome)"); return }
        #expect(trashed.path.hasPrefix(MediaTrash.testHostTrash.path), "the one Trash call (the test host's trash)")
        #expect(try Data(contentsOf: trashed) == bytes, "the copy is in the Trash whole")
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(scene.pending().isEmpty)
        #expect(try await scene.stored(.healthy) == before, "nothing was applied")
        #expect(lines.last?.hasPrefix("OUTCOME Discard \(copy.lastPathComponent) — moved to the Trash at ") == true, "\(lines)")
        _ = try await scene.relaunch(from: fresh)
        #expect(scene.pending().isEmpty)
    }

    @Test("ISOLATION: Discard refuses anything that is not a rescue copy beside the catalog — catalog.sqlite stays byte-identical")
    func discardRefusesTheCatalog() async throws {
        let scene = try CutoverScene.make("rescue_discard_refuses"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let before = try CornerFiles.sha256(scene.databaseURL)
        var confirmed = false
        let outcome = CatalogRescueApply.discard(rescue: scene.databaseURL, besideCatalog: scene.catalogURL, note: { _ in },
                                                 confirm: { _ in confirmed = true; return true }, trash: { _ in throw CutoverFailure(words: "must not be called") })
        guard case .refused = outcome else { Issue.record("\(outcome)"); return }
        #expect(!confirmed, "refused before the question")
        let elsewhere = scene.sandbox.root.appendingPathComponent("\(CatalogQuitRecovery.filePrefix)20260101-000000.json")
        try Data("{}".utf8).write(to: elsewhere)
        guard case .refused = CatalogRescueApply.discard(rescue: elsewhere, besideCatalog: scene.catalogURL, note: { _ in }, confirm: { _ in true }) else {
            Issue.record("a copy outside the catalog folder was discarded"); return
        }
        #expect(try CornerFiles.sha256(scene.databaseURL) == before)
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))
    }

    @Test("RELAUNCH: the copy is offered at every launch until it is applied or discarded (Later changes nothing)")
    func offeredUntilAppliedOrDiscarded() async throws {
        let scene = try CutoverScene.make("rescue_relaunch"); defer { scene.cleanup() }
        let copy = try await scene.quitWithRescue([(.healthy, "rescued A")])
        var model = try await scene.relaunch(from: scene.model)
        #expect(scene.pending() == [copy])
        model = try await scene.relaunch(from: model)                 // Later: nothing changes
        #expect(scene.pending() == [copy])
        model.announceCatalogRecoveryCopies()
        #expect(scene.sandbox.catalogLogText().contains("1 catalog recovery copy from a quit that could not save"))
        guard case .applied = await CatalogRescueApply.apply(rescue: copy, context: try scene.rescueContext(model)) else {
            Issue.record("not applied"); return
        }
        _ = try await scene.relaunch(from: model)
        #expect(scene.pending().isEmpty)
        #expect(CatalogQuitRecovery.launchNotice(catalogURL: scene.catalogURL) == nil, "the log-only notice agrees")
    }

    @Test("an old copy with no basis (written before GH #520): nothing is applied and each record says why; the backup was made")
    func oldCopyWithoutBasisAppliesNothing() async throws {
        let scene = try CutoverScene.make("rescue_old_copy"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        #expect(scene.model.saveCatalogNow())
        let healthy = try scene.record(.healthy)
        let before = healthy.userNotes
        healthy.userNotes = "in an old copy"
        let copy = CatalogQuitRecovery.url(besideCatalog: scene.catalogURL)
        let write = scene.model.catalogStore.recoveryCopyWriter(records: [healthy], generation: scene.model.catalogGenerationForStamp)
        #expect(write(copy) == nil)
        #expect(try CutoverScene.basis(copy) == nil, "no basis in the header")
        healthy.userNotes = before
        let fresh = try await scene.relaunch(from: scene.model)

        let outcome = await CatalogRescueApply.apply(rescue: copy, context: try scene.rescueContext(fresh))
        guard case .applied(let report) = outcome else { Issue.record("\(outcome)"); return }
        #expect(report.applied.isEmpty)
        #expect(report.notApplied.map(\.why) == [Why.noBasisOldCopy])
        #expect(try await scene.stored(.healthy) == before)
        #expect(CatalogRescueApply.reportTitle(report) == "Nothing Applied from the Rescue Copy")
    }

    @Test("a NEW record the catalog never took is applied (held until Fill In Full Hashes, as any new row); relaunch has it")
    func newRecordIsApplied() async throws {
        let scene = try CutoverScene.make("rescue_new_record"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        #expect(scene.model.saveCatalogNow())
        #expect(await scene.model.catalogStore.holdWrites(reason: "a test job", owner: CatalogWriteHoldOwner()) == .taken)
        let fresh = try scene.freshCopy(of: .healthy, path: "/Volumes/Fixture/New/rescued-new.mov")
        scene.model.records.append(fresh)
        let asked = CatalogQuitCornerTests.AskLog()
        let decided = await CatalogQuitRecovery.finalCommitBeforeQuit(model: scene.model, holdWait: 0.2,
                                                                      ask: asked.answer(.quitKeepingRescueCopy), tell: asked.tell)
        guard case .quitWithRescue(let copy) = decided else { Issue.record("\(decided)"); return }
        let rows = try #require(try CutoverScene.basis(copy.url)?["rows"] as? [String: String])
        #expect(rows[fresh.id.uuidString] == CatalogRescueBasis.absent, "the basis says the catalog had no row for it")
        let next = try await scene.relaunch(from: scene.model)
        #expect(next.records.contains { $0.id == fresh.id } == false)

        let outcome = await CatalogRescueApply.apply(rescue: copy.url, context: try scene.rescueContext(next))
        guard case .applied(let report) = outcome else { Issue.record("\(outcome)"); return }
        #expect(report.applied.map(\.id) == [fresh.id], "\(report)")
        let again = try await scene.relaunch(from: next)
        #expect(again.records.contains { $0.id == fresh.id && $0.fullPath == "/Volumes/Fixture/New/rescued-new.mov" })
    }

    @Test("TRUTH: both quit writers put the basis in the copy — the base generation and one stored-row digest per rescued record")
    func bothQuitWritersRecordTheBasis() async throws {
        let scene = try CutoverScene.make("rescue_basis_truth"); defer { scene.cleanup() }
        let copy = try await scene.quitWithRescue([(.healthy, "rescued A"), (.stalePrint, "rescued B")])
        let generation = scene.model.catalogGenerationForStamp
        let basis = try #require(try CutoverScene.basis(copy))
        #expect(basis["generation"] as? Int == generation)
        #expect(basis["unknown"] == nil)
        let rows = try #require(basis["rows"] as? [String: String])
        #expect(Set(rows.keys) == [PoisonedCatalogFixture.id(.healthy), PoisonedCatalogFixture.id(.stalePrint)])
        #expect(rows.values.allSatisfy { $0.hasPrefix("sha256:") && $0.count == 71 }, "\(rows)")
        #expect(scene.sandbox.catalogLogText().contains("recovery copy — what catalog.sqlite held for each at generation \(generation) is recorded"))

        // applicationWillTerminate's writer (a fresh copy for an edit after the first).
        scene.model.setUserNotes("after the first copy", for: try scene.record(.healthy))
        let outcome = CatalogQuitRecovery.saveAtTermination(model: scene.model, writerDeadline: 5)
        guard case .recoveryCopy(let second) = outcome else { Issue.record("\(outcome)"); return }
        let secondRows = try #require(try CutoverScene.basis(second)?["rows"] as? [String: String])
        #expect(secondRows[PoisonedCatalogFixture.id(.healthy)] == rows[PoisonedCatalogFixture.id(.healthy)],
                "the same stored row, the same digest, from the other writer")
    }
}

// MARK: - The check, pure

@Suite("Quit rescue copy — the record-by-record check and its words (GH #520)")
@MainActor
struct CatalogRescueApplyLogicTests {

    typealias Why = CatalogRescueApply.Why

    private static func record(_ path: String) -> VideoRecord {
        let r = VideoRecord(id: UUID())
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        return r
    }

    private static func file(_ records: [VideoRecord], basis: CatalogRescueBasis?) -> CatalogRescueApply.RescueFile {
        CatalogRescueApply.RescueFile(url: URL(fileURLWithPath: "/tmp/catalog.recovery-20261127-120000.json"), generation: 7,
                                      savedAt: nil, records: records, basis: basis)
    }

    @Test("each reason: unchanged applies; changed, gone, appeared, unreadable, unsaved here, path taken, no basis are left with their words")
    func everyReason() {
        let unchanged = Self.record("/V/a.mov"), changed = Self.record("/V/b.mov"), gone = Self.record("/V/c.mov")
        let appeared = Self.record("/V/d.mov"), unreadable = Self.record("/V/e.mov"), unsaved = Self.record("/V/f.mov")
        let newOK = Self.record("/V/g.mov"), newTaken = Self.record("/V/h.mov"), unlisted = Self.record("/V/i.mov")
        let holder = Self.record("/V/h.mov")
        let all = [unchanged, changed, gone, appeared, unreadable, unsaved, newOK, newTaken, unlisted]
        var rows: [String: String] = [:]
        for r in [unchanged, changed, gone, unreadable, unsaved] { rows[r.id.uuidString] = "sha256:base-\(r.filename)" }
        for r in [appeared, newOK, newTaken] { rows[r.id.uuidString] = CatalogRescueBasis.absent }
        var stored: [String: String?] = [:]
        stored[unchanged.id.uuidString] = .some("sha256:base-a.mov")
        stored[changed.id.uuidString] = .some("sha256:other")
        stored[gone.id.uuidString] = .some(CatalogRescueBasis.absent)
        stored[appeared.id.uuidString] = .some("sha256:new")
        stored[unreadable.id.uuidString] = .some(nil)
        stored[unsaved.id.uuidString] = .some("sha256:base-f.mov")
        stored[newOK.id.uuidString] = .some(CatalogRescueBasis.absent)
        stored[newTaken.id.uuidString] = .some(CatalogRescueBasis.absent)
        stored[unlisted.id.uuidString] = .some("sha256:x")
        let memory = Dictionary(uniqueKeysWithValues: [unchanged, changed, unsaved].map { ($0.id, $0) })
        let now = CatalogRescueApply.Now(stored: stored, memory: { memory[$0] }, unsaved: [unsaved.id],
                                         pathHolder: { $0 == holder.fullPath ? holder : nil })
        let plan = CatalogRescueApply.plan(Self.file(all, basis: CatalogRescueBasis(generation: 7, rows: rows)), now: now)
        #expect(plan.apply.map(\.id) == [unchanged.id, newOK.id])
        let why = Dictionary(uniqueKeysWithValues: plan.leave.map { ($0.id, $0.why ?? "") })
        #expect(why[changed.id] == Why.changed)
        #expect(why[gone.id] == Why.gone)
        #expect(why[appeared.id] == Why.appeared)
        #expect(why[unreadable.id] == Why.unreadable)
        #expect(why[unsaved.id] == Why.unsavedHere)
        #expect(why[newTaken.id] == Why.pathTaken("h.mov"))
        #expect(why[unlisted.id] == Why.noBasis("it was not in the list"))
        #expect(plan.leave.count == 7)

        let unknown = CatalogRescueApply.plan(Self.file(all, basis: .missing("catalog.sqlite could not be read: x")), now: now)
        #expect(unknown.apply.isEmpty && unknown.leave.allSatisfy { $0.why == Why.noBasis("catalog.sqlite could not be read: x") })
        let old = CatalogRescueApply.plan(Self.file(all, basis: nil), now: now)
        #expect(old.apply.isEmpty && old.leave.allSatisfy { $0.why == Why.noBasisOldCopy })
    }

    @Test("SCALE: the check over 100,000 live records and 5,000 rescued ones stays within 2 s (Debug)")
    func scale() {
        let live = (0..<100_000).map { Self.record("/V/live-\($0).mov") }
        let rescued = Array(live.prefix(5_000))
        var rows: [String: String] = [:]
        var stored: [String: String?] = [:]
        for (i, r) in rescued.enumerated() {
            rows[r.id.uuidString] = "sha256:\(i)"
            stored[r.id.uuidString] = .some(i.isMultiple(of: 10) ? "sha256:moved" : "sha256:\(i)")
        }
        let clock = ContinuousClock()
        let start = clock.now
        let byID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        let now = CatalogRescueApply.Now(stored: stored, memory: { byID[$0] }, unsaved: [], pathHolder: { _ in nil })
        let plan = CatalogRescueApply.plan(Self.file(rescued, basis: CatalogRescueBasis(generation: 1, rows: rows)), now: now)
        let elapsed = clock.now - start
        print("[rescue-apply scale] 100k live, 5k rescued: \(elapsed)")
        #expect(plan.apply.count == 4_500 && plan.leave.count == 500)
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }

    @Test("the words: the notice names the copy and the three choices; the confirmation says the backup comes first and how to undo; the outcome says where the backup is")
    func words() {
        let r = Self.record("/V/a.mov")
        let file = Self.file([r], basis: nil)
        #expect(CatalogRescueApply.launchTitle(3) == "VideoScan kept a rescue copy of 3 changes it couldn't save")
        #expect(CatalogRescueApply.launchTitle(1) == "VideoScan kept a rescue copy of 1 change it couldn't save")
        let notice = CatalogRescueApply.launchText(name: file.name, savedAt: nil, count: 1, readProblem: nil, olderCopies: 1)
        #expect(notice.contains("so it kept them in catalog.recovery-20261127-120000.json beside the catalog. Nothing from it is in the catalog yet."))
        #expect(notice.contains("Apply… backs up the catalog first"))
        #expect(notice.contains("Discard… moves the rescue copy to the Trash without applying it."))
        #expect(notice.contains("Later keeps it and asks again the next time you open VideoScan."))
        #expect(notice.contains("1 older rescue copy is waiting"))
        let confirm = CatalogRescueApply.confirmText(file)
        #expect(confirm.hasPrefix("First VideoScan backs up the catalog — you choose where."))
        #expect(confirm.contains("choose File ▸ Restore from Backup… and pick that backup to put the catalog back as it was."))
        #expect(confirm.contains("The rescue copy stays beside the catalog until you discard it."))
        let report = CatalogRescueApply.Report(applied: [CatalogRescueApply.Item(r)], notApplied: [],
                                               backup: URL(fileURLWithPath: "/B/x.videoscanbundle"),
                                               keptAs: URL(fileURLWithPath: "/C/catalog.applied-recovery-1.json"), keepWords: nil)
        #expect(CatalogRescueApply.reportTitle(report) == "Rescue Copy Applied")
        let text = CatalogRescueApply.reportText(report)
        #expect(text.hasPrefix("Applied: 1 change."))
        #expect(text.contains("The catalog was backed up first to /B/x.videoscanbundle. To undo this, choose File ▸ Restore from Backup… and pick that backup."))
        #expect(text.contains("The rescue copy is kept as catalog.applied-recovery-1.json beside the catalog until you discard it."))
        #expect(CatalogRescueApply.discardText(URL(fileURLWithPath: "/C/catalog.recovery-1.json"))
            == "The changes in catalog.recovery-1.json will not be applied. You can put the file back from the Trash if you change your mind.")
    }
}

// MARK: - Sensors (source)

@Suite("Quit rescue copy — wiring sensors (GH #520)")
struct CatalogRescueApplySensorTests {

    @Test("Apply goes through the commit door, the Back Up Catalog engine and the stored-row read; Discard through THE one Trash call; nothing removes, replaces or writes catalog.sqlite itself")
    func applyUsesTheOneDoors() throws {
        let code = try SourceTree.strippingComments(SourceTree.appSource(named: "CatalogRescueApply.swift"))
        #expect(code.contains("committer.commitRescued(ids: ids)"))
        #expect(code.contains("await model?.backUpCatalog(to: url)"))
        #expect(code.contains("CatalogRescueBasis.digests(ids, in: reader)"))
        #expect(code.contains("try MediaTrash.move($0)"))
        for banned in ["removeItem(", "trashItem(", "replaceItemAt", "writeBlocking(", "write(as:", "unlink(", "moveItem("] {
            #expect(!code.contains(banned), "CatalogRescueApply must not call \(banned)")
        }
        // The backup comes before the check and the commit.
        let backUp = try #require(code.range(of: "await context.backUp(backupURL)"))
        let check = try #require(code.range(of: "CatalogRescueBasis.digests(ids, in: reader)"))
        #expect(backUp.lowerBound < check.lowerBound)
        let committer = try SourceTree.strippingComments(SourceTree.appSource(named: "CatalogCommitter.swift"))
        #expect(committer.contains("_ = commit(.rescueApply, owner: nil, scope: .only(ids))"))
    }

    @Test("both quit writers read the basis and pass it to the copy writer; launch announces the copy and then offers the choices")
    func quitAndLaunchWiring() throws {
        let quit = try SourceTree.strippingComments(SourceTree.appSource(named: "CatalogQuitRecovery.swift"))
        #expect(quit.contains("CatalogRescueBasis.readBlocking("))
        #expect(quit.contains("await CatalogRescueBasis.read("))
        #expect(quit.components(separatedBy: "basis: settled(basis, model))").count == 3, "both writers pass the basis")
        let app = try SourceTree.strippingComments(SourceTree.appSource(named: "VideoScanApp.swift"))
        let announce = try #require(app.range(of: "catalogModel?.announceCatalogRecoveryCopies()"))
        let offer = try #require(app.range(of: "CatalogRescueApply.presentLaunchNotice(model: catalogModel)"))
        #expect(announce.lowerBound < offer.lowerBound)
    }
}
