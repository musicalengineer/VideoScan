// ProvenanceSetRoleTests.swift — Provenance ▸ Set Role (ProvenanceRoleStore,
// ProvenanceMenu, InspectorProvenanceRoleLine; schema v1.12
// `provenance_roles`). Policy docs/guides/provenance_roles.md.
//
// Dimensions (CLAUDE.md rule 8, a catalog writer):
//   LOGIC      targets (no digest / some / all; byte copies are one content),
//              the menu's refusal, the common-role checkmark, "already",
//              the Inspector's words and dates.
//   TRUTH      the Inspector's line is read from catalog.sqlite: set → the
//              byte copy (same digest, another row) shows the same role →
//              relaunch (a NEW model on the same files) shows it again;
//              Unknown appends a row and resets; a multi-selection sets every
//              content in one transaction.
//   WRITER     a set inside the 2 s debounce window of a record edit (both
//              survive the relaunch); during a job's write hold (REFUSED,
//              nothing written, then it lands after release); across a role
//              flip master → viewer → master (refused as viewer, lands back
//              on the master); every case relaunched.
//   ISOLATION  a poisoned role row (a key this version cannot read) is
//              shown as Unknown with ONE log line, never a crash, and a
//              readable role replaces it; a content the store does not hold
//              rolls the whole change back; an unattached store refuses.
//   SCALE      100k selected records → targets and the common role inside a
//              budget (the menu's work at right-click); SQL scale is Core's
//              CatalogProvenanceRolesTests (100k contents).
//   SENSOR     the menu and the Inspector line hold no SQL and no commit;
//              no `extension VideoScanModel` in Provenance/; the row menu
//              carries ProvenanceMenu; the side-table door names the table.
//   MEDIA      N/A — no media is opened (a role is a catalog fact).
//
// Suites (filter by SUITE): ProvenanceSetRoleLogicTests ·
// ProvenanceSetRoleTruthTests · ProvenanceSetRoleScaleTests ·
// ProvenanceSetRoleSensorTests
// Synthetic names only.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let roleNow = Date(timeIntervalSince1970: 1_793_000_000)     // 2026-10-26

@MainActor
private func record(digest: String?, size: Int64 = 4_096) -> VideoRecord {
    let r = VideoRecord()
    r.filename = "test_synthetic_\(UUID().uuidString.prefix(6)).mov"
    r.sizeBytes = size
    if let digest {
        r.contentFixity = ContentFixity(digest: digest, byteCount: size,
                                        stamp: FileIdentityStamp(device: 1, inode: 1, size: size, mtimeNs: 1), computedAt: roleNow)
    }
    return r
}

private func hex(_ n: Int) -> String { String(format: "%064x", n) }

// MARK: - LOGIC

@Suite("Provenance ▸ Set Role — logic")
@MainActor
struct ProvenanceSetRoleLogicTests {

    @Test("targets: byte copies are one content; a file without a full SHA-256 disables the whole selection, with words")
    func targets() {
        let a = record(digest: hex(1)), copy = record(digest: hex(1)), b = record(digest: hex(2)), bare = record(digest: nil)
        let hashed = ProvenanceRoleTargets(records: [a, copy, b])
        #expect(hashed.digests == [hex(1), hex(2)])
        #expect(hashed.total == 3)
        #expect(hashed.refusal == nil)
        let one = ProvenanceRoleTargets(records: [bare])
        #expect(one.refusal == ProvenanceRoleWords.noDigestHelp)
        let mixed = ProvenanceRoleTargets(records: [a, bare])
        #expect(mixed.refusal == ProvenanceRoleWords.someWithoutDigestHelp(1, of: 2))
        #expect(mixed.refusal?.contains("1 of the 2 selected files have no full SHA-256") == true)
    }

    @Test("the menu's refusal: no digest, then the session's words; nil when it can write")
    func menuRefusal() {
        let ok = ProvenanceRoleTargets(records: [record(digest: hex(1))])
        #expect(SetRoleMenu.refusal(targets: ok, writeRefusal: nil) == nil)
        #expect(SetRoleMenu.refusal(targets: ok, writeRefusal: "the catalog is read-only") == "No role can be set now: the catalog is read-only.")
        let bare = ProvenanceRoleTargets(records: [record(digest: nil)])
        #expect(SetRoleMenu.refusal(targets: bare, writeRefusal: nil) == ProvenanceRoleWords.noDigestHelp)
        #expect(SetRoleMenu.refusal(targets: ProvenanceRoleTargets(records: []), writeRefusal: nil) == ProvenanceRoleWords.noDigestHelp)
    }

    @Test("already: no row is Unknown; a Master differs from a Master with its source missing; an unreadable row is never 'already'")
    func already() {
        let master = CatalogRow.ProvenanceRoleReading(roleID: 1, digest: hex(1), storedRole: "master", decidedAt: 1, storedSourceMissing: false, note: nil)
        let lost = CatalogRow.ProvenanceRoleReading(roleID: 2, digest: hex(1), storedRole: "master", decidedAt: 1, storedSourceMissing: true, note: nil)
        let bad = CatalogRow.ProvenanceRoleReading(roleID: 3, digest: hex(1), storedRole: "zzz", decidedAt: 1, storedSourceMissing: false, note: nil)
        #expect(ProvenanceRoleStore.isAlready(.unknown, false, nil))
        #expect(!ProvenanceRoleStore.isAlready(.master, false, nil))
        #expect(ProvenanceRoleStore.isAlready(.master, false, master))
        #expect(!ProvenanceRoleStore.isAlready(.master, true, master))
        #expect(ProvenanceRoleStore.isAlready(.master, true, lost))
        #expect(!ProvenanceRoleStore.isAlready(.unknown, false, bad))
    }

    @Test("the Inspector's words: Unknown, a role with who and when, the source-missing line, an unreadable key, no digest, reading")
    func inspectorWords() {
        let day = Int64(roleNow.timeIntervalSince1970)
        let master = CatalogRow.ProvenanceRoleReading(roleID: 1, digest: hex(1), storedRole: "master", decidedAt: day, storedSourceMissing: true, note: nil)
        let bad = CatalogRow.ProvenanceRoleReading(roleID: 2, digest: hex(1), storedRole: "zzz", decidedAt: day, storedSourceMissing: false, note: nil)
        let date = ProvenanceRoleWords.shortDate(day, now: roleNow)
        #expect(InspectorProvenanceRoleLine.lines(digest: hex(1), reading: .noRow(digest: hex(1)), now: roleNow) == ["Role: Unknown"])
        #expect(InspectorProvenanceRoleLine.lines(digest: hex(1), reading: .row(master), now: roleNow)
                == ["Role: Master — set by Rick, \(date)", "Source not in the catalog — the only surviving version"])
        #expect(InspectorProvenanceRoleLine.lines(digest: hex(1), reading: .row(bad), now: roleNow)
                == ["Role: Unknown — the catalog holds a role this version cannot read"])
        #expect(InspectorProvenanceRoleLine.lines(digest: nil, reading: nil) == [ProvenanceRoleWords.noDigestLine])
        #expect(InspectorProvenanceRoleLine.lines(digest: hex(1), reading: nil) == ["Role: …"], "never a guess while reading")
    }

    @Test("F2: a reading for content A is never rendered for content B — 'Role: …' until B's own read lands (Codex #156)")
    func aReadingForAnotherContentIsNeverShown() {
        let masterA = CatalogRow.ProvenanceRoleReading(roleID: 1, digest: hex(1), storedRole: "master", decidedAt: 1, storedSourceMissing: false, note: nil)
        #expect(InspectorProvenanceRoleLine.lines(digest: hex(2), reading: .row(masterA)) == ["Role: …"])
        #expect(InspectorProvenanceRoleLine.lines(digest: hex(2), reading: .noRow(digest: hex(1))) == ["Role: …"])
        // Same content, but the revision moved since that read finished: not shown either.
        let now = InspectorProvenanceRoleLine.ReadKey(digest: hex(1), revision: 8)
        let old = InspectorProvenanceRoleLine.ReadKey(digest: hex(1), revision: 7)
        #expect(InspectorProvenanceRoleLine.shownReading(for: now, completedKey: old, reading: .row(masterA)) == nil)
        #expect(InspectorProvenanceRoleLine.shownReading(for: now, completedKey: now, reading: .row(masterA)) == .row(masterA))
    }

    @Test("dates: this year without the year, another year with it")
    func dates() {
        let thisYear = ProvenanceRoleWords.shortDate(Int64(roleNow.timeIntervalSince1970), now: roleNow)
        #expect(!thisYear.contains("2026"))
        let lastYear = ProvenanceRoleWords.shortDate(Int64(roleNow.timeIntervalSince1970) - 400 * 86_400, now: roleNow)
        #expect(lastYear.contains("2025"))
    }

    @Test("the Master confirm's words are Rick's")
    func masterWords() {
        #expect(ProvenanceRoleWords.sourceMissingCheckbox == "Source not in the catalog (this is the only surviving version)")
        #expect(ProvenanceRoleWords.masterQuestion(contents: 1) == "Mark this file as the Master?")
        #expect(ProvenanceRoleWords.masterQuestion(contents: 3) == "Mark these 3 files as Masters?")
    }

    @Test("an unattached store (a viewer launch, a JSON session) refuses and says why")
    func unattachedRefuses() {
        let store = ProvenanceRoleStore()
        var lines: [String] = []
        store.note = { lines.append($0) }
        #expect(store.writeRefusal == "the catalog is not open for writing in this session")
        #expect(store.set(.master, digests: [hex(1)]) == .refused("the catalog is not open for writing in this session"))
        #expect(lines.contains { $0.hasPrefix("REFUSED set role Master on 1 content") })
        #expect(store.commonRole(of: [hex(1)]) == .unknown, "no row is Unknown")
        #expect(store.commonRole(of: []) == nil)
    }
}

// MARK: - TRUTH + WRITER + ISOLATION on catalog.sqlite

@MainActor
private func launch(_ scene: CutoverScene) async throws {
    try await scene.launchOnSQLite()
    try #require(scene.model.catalogCutover.isSQLiteAuthority, "the scene launched on catalog.sqlite")
    #expect(await scene.model.provenanceRoles.load() == nil)
}

/// Quit and launch again: the store closed, a NEW model on the same folder
/// runs the launch — nothing in memory survives from the first session.
@MainActor
private func relaunch(_ scene: CutoverScene, from model: VideoScanModel) async throws -> VideoScanModel {
    if let committer = model.catalogCutover.committer { await committer.repository.close() }
    let sandbox = scene.sandbox
    let fresh = VideoScanModel(logDirectory: sandbox.logs)
    fresh.catalogStore = CatalogStore(directory: sandbox.catalogDir)
    fresh.mediaLedger = MediaLedger(directory: sandbox.root.appendingPathComponent("ledger", isDirectory: true))
    fresh.records = fresh.loadCatalogAtLaunch()
    try #require(fresh.catalogCutover.isSQLiteAuthority, "the relaunch opened catalog.sqlite")
    #expect(await fresh.provenanceRoles.load() == nil)
    return fresh
}

@MainActor
private func digest(_ scene: CutoverScene, _ shape: PoisonedCatalogFixture.Shape) throws -> String {
    try #require(CatalogCommit.digest(of: try scene.record(shape)))
}

@MainActor
private func history(_ model: VideoScanModel, _ digest: String) async throws -> [CatalogRow.ProvenanceRoleReading] {
    let repository = try #require(model.catalogCutover.committer?.repository)
    return try await repository.read { try $0.provenanceRoleHistory(digest: digest) }
}

@Suite("Provenance ▸ Set Role — truth and the writer cases on catalog.sqlite", .serialized)
@MainActor
struct ProvenanceSetRoleTruthTests {

    @Test("TRUTH: Master with its source missing → the byte copy shows it, read from catalog.sqlite → relaunch shows it again")
    func setShowsOnCopiesAndSurvivesRelaunch() async throws {
        let scene = try CutoverScene.make("role_truth"); defer { scene.cleanup() }
        try await launch(scene)
        let shared = try digest(scene, .curatedConflictA)
        #expect(try digest(scene, .curatedConflictB) == shared, "the fixture's two rows are byte copies")
        let store = scene.model.provenanceRoles
        let outcome = store.set(.master, digests: [shared], sourceMissing: true, files: 1, now: roleNow)
        #expect(outcome == .set(changed: 1, unchanged: 0))
        // The OTHER row's Inspector: read from the store by its own digest.
        let copyDigest = try #require(CatalogCommit.digest(of: try scene.record(.curatedConflictB)))
        let read = await store.readCurrent(digest: copyDigest)
        guard case .row(let row) = read else { Issue.record("expected a row, got \(read)"); return }
        #expect(row.role == .master)
        #expect(InspectorProvenanceRoleLine.lines(digest: copyDigest, reading: read, now: roleNow).last
                == ProvenanceRoleWords.sourceMissingLine)
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("Provenance: START set role Master (source not in the catalog) on 1 content (1 file)"), "\(log.suffix(600))")
        #expect(log.contains("Provenance: OUTCOME set role Master (source not in the catalog) on 1 content (1 file) — 1 changed, 0 already"))
        #expect(log.contains("via provenance roles"), "the committer's own OUTCOME line names the table")

        let fresh = try await relaunch(scene, from: scene.model)
        #expect(fresh.provenanceRoles.role(of: shared) == .master)
        guard case .row(let again) = await fresh.provenanceRoles.readCurrent(digest: shared) else {
            Issue.record("the role did not survive the relaunch"); return
        }
        #expect(again.sourceNotInCatalog)
        #expect(again.decidedAt == Int64(roleNow.timeIntervalSince1970))
        if let committer = fresh.catalogCutover.committer { await committer.repository.close() }
    }

    @Test("Unknown appends a row and resets; the same role twice writes nothing; a multi-selection is one transaction with a shared checkmark")
    func unknownResetsAndMultiSelection() async throws {
        let scene = try CutoverScene.make("role_unknown"); defer { scene.cleanup() }
        try await launch(scene)
        let store = scene.model.provenanceRoles
        let a = try digest(scene, .healthy), b = try digest(scene, .curatedConflictA)
        #expect(store.set(.excerpt, digests: [a], now: roleNow) == .set(changed: 1, unchanged: 0))
        #expect(store.set(.excerpt, digests: [a], now: roleNow) == .set(changed: 0, unchanged: 1), "no duplicate row")
        #expect(store.set(.unknown, digests: [a], now: roleNow) == .set(changed: 1, unchanged: 0))
        #expect(try await history(scene.model, a).map(\.role) == [.excerpt, .unknown], "history kept, Unknown is a row")
        #expect(store.role(of: a) == .unknown)
        #expect(store.set(.viewCopy, digests: [b], now: roleNow) == .set(changed: 1, unchanged: 0))
        #expect(store.commonRole(of: [a, b]) == nil, "mixed roles: no checkmark")
        let generation = try #require(scene.model.catalogCutover.committer?.knownGeneration)
        #expect(store.set(.viewCopy, digests: [a, b], files: 3, now: roleNow) == .set(changed: 1, unchanged: 1))
        #expect(scene.model.catalogCutover.committer?.knownGeneration == generation + 1, "one transaction for the selection")
        #expect(store.commonRole(of: [a, b]) == .viewCopy)
    }

    @Test("WRITER: a role set inside the 2 s debounce window of a record edit — both land, both survive the relaunch")
    func insideTheDebounceWindow() async throws {
        let scene = try CutoverScene.make("role_debounce"); defer { scene.cleanup() }
        try await launch(scene)
        let healthy = try scene.record(.healthy)
        let d = try digest(scene, .healthy)
        healthy.userNotes = "typed just before the role"
        scene.model.saveCatalogDebounced()
        let committer = try #require(scene.model.catalogCutover.committer)
        #expect(committer.isBusy, "the edit is waiting on the debounce timer")
        #expect(scene.model.provenanceRoles.set(.cameraOriginal, digests: [d], now: roleNow) == .set(changed: 1, unchanged: 0))
        #expect(committer.blockedReason == nil, "the side-table commit did not block the record commit")
        #expect(scene.model.saveCatalogNow(), "the edit inside the window still commits")
        let fresh = try await relaunch(scene, from: scene.model)
        #expect(fresh.provenanceRoles.role(of: d) == .cameraOriginal)
        #expect(fresh.records.first { $0.id == healthy.id }?.userNotes == "typed just before the role")
        if let c = fresh.catalogCutover.committer { await c.repository.close() }
    }

    @Test("WRITER: during a job's write hold the set is REFUSED with the hold's words and nothing is written; after release it lands and survives the relaunch")
    func duringAWriteHold() async throws {
        let scene = try CutoverScene.make("role_hold"); defer { scene.cleanup() }
        try await launch(scene)
        let d = try digest(scene, .healthy)
        let store = scene.model.provenanceRoles
        #expect(await scene.model.catalogStore.holdWrites(reason: "a test job", owner: CatalogWriteHoldOwner()) == .taken)
        let held = store.set(.editCopy, digests: [d], now: roleNow)
        guard case .refused(let words) = held else { Issue.record("expected a refusal, got \(held)"); return }
        #expect(words.contains("held — a test job"))
        #expect(store.writeRefusal != nil, "the menu is disabled while held")
        #expect(try await history(scene.model, d).isEmpty, "nothing written")
        #expect(scene.sandbox.catalogLogText().contains("Provenance: REFUSED set role Edit Copy on 1 content"))
        scene.model.catalogStore.releaseWriteHold()
        #expect(store.set(.editCopy, digests: [d], now: roleNow) == .set(changed: 1, unchanged: 0))
        let fresh = try await relaunch(scene, from: scene.model)
        #expect(fresh.provenanceRoles.role(of: d) == .editCopy)
        if let c = fresh.catalogCutover.committer { await c.repository.close() }
    }

    @Test("WRITER: across a role flip — master sets, viewer is refused (nothing written), master again sets; the relaunch shows the master's last choice")
    func acrossAViewerMasterFlip() async throws {
        let scene = try CutoverScene.make("role_flip"); defer { scene.cleanup() }
        try await launch(scene)
        let d = try digest(scene, .healthy)
        let store = scene.model.provenanceRoles
        #expect(store.set(.viewCopy, digests: [d], now: roleNow) == .set(changed: 1, unchanged: 0))
        scene.model.updateReadOnlyFacts { $0.viewerRole = true }
        let refused = store.set(.master, digests: [d], now: roleNow)
        guard case .refused(let words) = refused else { Issue.record("expected a refusal, got \(refused)"); return }
        #expect(words.contains("viewer"))
        #expect(SetRoleMenu.refusal(targets: ProvenanceRoleTargets(records: [try scene.record(.healthy)]), writeRefusal: store.writeRefusal) != nil)
        #expect(try await history(scene.model, d).map(\.role) == [.viewCopy], "the viewer wrote nothing")
        scene.model.updateReadOnlyFacts { $0.viewerRole = false }
        #expect(store.set(.master, digests: [d], now: roleNow) == .set(changed: 1, unchanged: 0))
        let fresh = try await relaunch(scene, from: scene.model)
        #expect(fresh.provenanceRoles.role(of: d) == .master)
        if let c = fresh.catalogCutover.committer { await c.repository.close() }
    }

    @Test("ISOLATION: a poisoned role row is shown as Unknown with one log line, never a crash; a readable role replaces it")
    func poisonedRow() async throws {
        let scene = try CutoverScene.make("role_poison"); defer { scene.cleanup() }
        try await launch(scene)
        let d = try digest(scene, .healthy)
        try scene.execSQL("PRAGMA ignore_check_constraints = ON; INSERT INTO provenance_roles (digest, role, decided_at) VALUES ('\(d)', 'grandMaster', 1);")
        let store = scene.model.provenanceRoles
        #expect(await store.load() == nil)
        #expect(store.unreadable == 1)
        #expect(store.role(of: d) == .unknown)
        let read = await store.readCurrent(digest: d)
        #expect(InspectorProvenanceRoleLine.lines(digest: d, reading: read) == ["Role: Unknown — the catalog holds a role this version cannot read"])
        let said = scene.sandbox.catalogLogText().components(separatedBy: "holds a key this version cannot read").count - 1
        #expect(said == 1, "said once, not per read")
        #expect(store.set(.testCopy, digests: [d], now: roleNow) == .set(changed: 1, unchanged: 0))
        #expect(store.role(of: d) == .testCopy)
    }

    // MARK: Codex #156 F1 — the map is display only; SQLite decides changed / unchanged

    @Test("F1: a cleared map (attach before load) never reports 'unchanged' while SQLite holds another role (Codex #156)")
    func clearedMapDoesNotSkipARealChange() async throws {
        let scene = try CutoverScene.make("role_f1_cleared"); defer { scene.cleanup() }
        try await launch(scene)
        let d = try digest(scene, .healthy)
        let store = scene.model.provenanceRoles
        _ = store.set(.master, digests: [d])
        store.attach(try #require(store.backing))
        #expect(store.set(.unknown, digests: [d]) == .set(changed: 1, unchanged: 0))
        #expect(try await history(scene.model, d).map(\.role) == [.master, .unknown])
    }

    @Test("F1: a stale map that already shows the chosen role still writes it when SQLite holds another")
    func staleMapDoesNotSkipARealChange() async throws {
        let scene = try CutoverScene.make("role_f1_stale"); defer { scene.cleanup() }
        try await launch(scene)
        let d = try digest(scene, .healthy)
        let store = scene.model.provenanceRoles
        _ = store.set(.master, digests: [d], now: roleNow)
        let stale = CatalogRow.ProvenanceRoleReading(roleID: 0, digest: d, storedRole: "viewCopy", decidedAt: 1, storedSourceMissing: false, note: nil)
        store.apply([stale], takenAt: store.commitEpoch)          // the map now lies: View Copy
        #expect(store.set(.viewCopy, digests: [d], now: roleNow) == .set(changed: 1, unchanged: 0))
        #expect(try await history(scene.model, d).map(\.role) == [.master, .viewCopy])
    }

    @Test("F1: every selected digest's map entry is refreshed from the in-transaction read-back, the unchanged ones too")
    func unchangedDigestsAreRefreshedFromTheReadBack() async throws {
        let scene = try CutoverScene.make("role_f1_refresh"); defer { scene.cleanup() }
        try await launch(scene)
        let d = try digest(scene, .healthy)
        let store = scene.model.provenanceRoles
        _ = store.set(.master, digests: [d], now: roleNow)
        store.attach(try #require(store.backing))                 // map cleared: shows Unknown
        #expect(store.set(.master, digests: [d], now: roleNow) == .set(changed: 0, unchanged: 1))
        #expect(store.role(of: d) == .master, "the read-back corrected the map")
        #expect(try await history(scene.model, d).count == 1, "no duplicate row")
    }

    @Test("F1: a load snapshot taken before a commit never replaces the newer committed state")
    func anOlderLoadSnapshotNeverWins() async throws {
        let scene = try CutoverScene.make("role_f1_load"); defer { scene.cleanup() }
        try await launch(scene)
        let d = try digest(scene, .healthy)
        let store = scene.model.provenanceRoles
        let takenAt = store.commitEpoch                           // a load reads here (no rows yet)…
        _ = store.set(.excerpt, digests: [d], now: roleNow)       // …a commit lands while it is suspended…
        #expect(store.apply([], takenAt: takenAt) == false, "…and its older snapshot is not applied")
        #expect(store.role(of: d) == .excerpt)
    }

    @Test("ISOLATION: a content catalog.sqlite does not hold rolls the WHOLE change back — the other content is not written either")
    func missingContentRollsBack() async throws {
        let scene = try CutoverScene.make("role_missing"); defer { scene.cleanup() }
        try await launch(scene)
        let d = try digest(scene, .healthy)
        let outcome = scene.model.provenanceRoles.set(.master, digests: [d, hex(0xdead)], now: roleNow)
        guard case .refused(let words) = outcome else { Issue.record("expected a refusal, got \(outcome)"); return }
        #expect(words.contains("is not in catalog.sqlite yet"))
        #expect(try await history(scene.model, d).isEmpty)
        #expect(scene.model.catalogCutover.committer?.blockedReason == nil, "a refused role never blocks the catalog")
    }
}

// MARK: - SCALE

@Suite("Provenance ▸ Set Role — SCALE (100k)")
@MainActor
struct ProvenanceSetRoleScaleTests {

    /// The menu's work at right-click for a 100k-row selection: targets
    /// (one digest rule per record) and the common role (one map probe per
    /// content). Budget 2 s (Debug, M4 Max) — O(n²) would be hours.
    @Test(.timeLimit(.minutes(2)))
    func hundredThousandSelected() {
        let records = (1...100_000).map { record(digest: hex($0)) }
        let store = ProvenanceRoleStore()
        let clock = ContinuousClock()
        var targets = ProvenanceRoleTargets(records: [])
        var common: ProvenanceRole?
        let elapsed = clock.measure {
            targets = ProvenanceRoleTargets(records: records)
            common = store.commonRole(of: targets.digests)
        }
        print("[provenance-set-role] 100k selected: targets + common role \(elapsed)")
        #expect(targets.digests.count == 100_000)
        #expect(common == .unknown)
        #expect(elapsed < .seconds(2))
    }
}

// MARK: - SENSOR

@Suite("Provenance ▸ Set Role — sensors")
@MainActor
struct ProvenanceSetRoleSensorTests {

    @Test("the menu and the Inspector line hold no SQL and no commit; Provenance/ adds no model extension")
    func noSQLNoCommitInTheViews() throws {
        for name in ["ProvenanceMenu.swift", "InspectorProvenanceRoleLine.swift"] {
            let code = try SourceTree.appCode(named: "Provenance/" + name)
            #expect(!code.isEmpty)
            // "import " + "GRDB": spelled apart so this file never reads as a GRDB importer (CatalogStoreSensorTests).
            for token in ["commitSideTables", "writeBlocking", "INSERT", "appendProvenanceRole", "extension VideoScanModel", "import " + "GRDB"] {
                #expect(!code.contains(token), "\(name) contains \(token)")
            }
        }
        let store = try SourceTree.appCode(named: "Provenance/ProvenanceRoleStore.swift")
        #expect(!store.contains("extension VideoScanModel"))
        #expect(store.contains("commitSideTables(what, via: .provenanceRoles, body)"), "the one door")
        #expect(!store.contains("INSERT"), "no SQL in the app; the Core door appends")
    }

    @Test("the catalog row menu carries Provenance ▸ Find ▸ Master (sound) and Set Role ▸")
    func rowMenuCarriesTheProvenanceMenu() throws {
        let table = try SourceTree.appCode(named: "Catalog/CatalogContent+FolderTable.swift")
        let start = try #require(table.range(of: "func tableContextMenu("))
        #expect(table[start.lowerBound...].prefix(900).contains("ProvenanceMenu("))
        let menu = try SourceTree.appCode(named: "Provenance/ProvenanceMenu.swift")
        #expect(menu.contains("Menu(ProvenanceRoleWords.findTitle)"))
        #expect(menu.contains("FindMasterMenuItem(model: model, recordIDs: recordIDs)"))
        #expect(menu.contains("SetRoleMenu("))
        #expect(menu.contains("ForEach(ProvenanceRole.allCases"))
        #expect(ProvenanceRoleWords.menuTitle == "Provenance")
        #expect(ProvenanceRoleWords.findTitle == "Find")
        #expect(ProvenanceRoleWords.setRoleTitle == "Set Role")
    }

    @Test("the Inspector line reads catalog.sqlite (readCurrent), never the menu's map or a record field")
    func inspectorReadsTheStore() throws {
        let line = try SourceTree.appCode(named: "Provenance/InspectorProvenanceRoleLine.swift")
        #expect(line.contains("await store.readCurrent(digest: digest)"))
        #expect(!line.contains("store.role(of:"))
        #expect(!line.contains("byDigest"))
    }
}
