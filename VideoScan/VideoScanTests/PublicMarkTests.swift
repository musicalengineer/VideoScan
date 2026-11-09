// PublicMarkTests.swift — Make Public / Make Private (PublicMarkStore,
// PublicMarkMenu; schema v1.15 `public_marks`). Rick 2026-11-09: "if the bit
// is off, it is presumed private."
//
// Dimensions (CLAUDE.md rule 8, a catalog writer):
//   LOGIC      targets (not archived / no digest / all-or-nothing; byte
//              copies are one content), the menu's refusal and its offer
//              (public, private, both), "already", the words.
//   TRUTH      the globe reads the store, which reads catalog.sqlite: make
//              public → the byte copy (same digest, another row) is public →
//              relaunch (a NEW model on the same files) shows it again; make
//              private appends a row and clears it; a multi-selection is one
//              transaction.
//   WRITER     a mark inside the 2 s debounce window of a record edit (both
//              survive the relaunch); during a job's write hold (REFUSED,
//              nothing written, then it lands after release); across a role
//              flip master → viewer → master (refused as viewer, lands back
//              on the master); every case relaunched.
//   ISOLATION  FAIL CLOSED — an unattached or unloaded store, a poisoned row
//              (a flag this version cannot read), and a refused write all
//              read as PRIVATE; a content the store does not hold rolls the
//              whole change back in BOTH directions (Codex #273 F2); there is
//              no "make everything private" (Rick 11/09; sensor); a stale
//              projection never skips a change;
//              an older load snapshot never replaces newer committed state.
//   SCALE      100k selected records → targets and the offer inside a budget
//              (the menu's work at right-click); SQL scale is Core's
//              CatalogPublicMarksTests (100k contents).
//   SENSOR     the menu holds no SQL and no commit; no `extension
//              VideoScanModel` in Public/; the Archive row menu carries the
//              items and asks the PROVEN archived predicate; the side-table
//              door names the table; nothing outside Public/ and the wiring
//              writes the bit.
//   MEDIA      N/A — no media is opened (the bit is a catalog fact).
//
// Suites (filter by SUITE): PublicMarkLogicTests · PublicMarkTruthTests ·
// PublicMarkScaleTests · PublicMarkSensorTests
// Synthetic names only.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let markNow = Date(timeIntervalSince1970: 1_794_200_000)     // 2026-11-09

@MainActor
private func record(digest: String?, size: Int64 = 4_096) -> VideoRecord {
    let r = VideoRecord()
    r.filename = "test_synthetic_\(UUID().uuidString.prefix(6)).mov"
    r.sizeBytes = size
    if let digest {
        r.contentFixity = ContentFixity(digest: digest, byteCount: size,
                                        stamp: FileIdentityStamp(device: 1, inode: 1, size: size, mtimeNs: 1), computedAt: markNow)
    }
    return r
}

private func hex(_ n: Int) -> String { String(format: "%064x", n) }

private func reading(_ flag: Int64, id: Int64 = 1, digest: String = hex(1)) -> CatalogRow.PublicMarkReading {
    CatalogRow.PublicMarkReading(markID: id, digest: digest, storedFlag: flag, decidedAt: 1)
}

// MARK: - LOGIC

@Suite("Make Public — logic")
@MainActor
struct PublicMarkLogicTests {

    @Test("targets: byte copies are one content; a file that is not archived, or has no full SHA-256, refuses the whole selection with words")
    func targets() {
        let a = record(digest: hex(1)), copy = record(digest: hex(1)), b = record(digest: hex(2)), bare = record(digest: nil)
        let loose = record(digest: hex(3))
        let archived: (VideoRecord) -> Bool = { $0 !== loose }
        let hashed = PublicMarkTargets(records: [a, copy, b], isArchived: archived)
        #expect(hashed.digests == [hex(1), hex(2)])
        #expect(hashed.total == 3)
        #expect(hashed.refusal == nil)
        #expect(PublicMarkTargets(records: [bare], isArchived: archived).refusal == PublicMarkWords.noDigestHelp)
        #expect(PublicMarkTargets(records: [a, bare], isArchived: archived).refusal == PublicMarkWords.someWithoutDigestHelp(1, of: 2))
        #expect(PublicMarkTargets(records: [loose], isArchived: archived).refusal == PublicMarkWords.notArchivedHelp)
        let mixed = PublicMarkTargets(records: [a, loose], isArchived: archived)
        #expect(mixed.refusal == PublicMarkWords.someNotArchivedHelp(1, of: 2))
        #expect(mixed.digests == [hex(1)], "a file that is not archived never contributes a digest")
        #expect(PublicMarkTargets(records: [], isArchived: archived).refusal == nil)
    }

    @Test("the menu's refusal: the selection's own words first, then the session's; nil when it can write")
    func menuRefusal() {
        let ok = PublicMarkTargets(records: [record(digest: hex(1))]) { _ in true }
        #expect(PublicMarkMenuItems.refusal(targets: ok, writeRefusal: nil) == nil)
        #expect(PublicMarkMenuItems.refusal(targets: ok, writeRefusal: "the catalog is read-only")
                == "The mark cannot be changed now: the catalog is read-only.")
        let loose = PublicMarkTargets(records: [record(digest: hex(1))]) { _ in false }
        #expect(PublicMarkMenuItems.refusal(targets: loose, writeRefusal: nil) == PublicMarkWords.notArchivedHelp)
        #expect(PublicMarkMenuItems.refusal(targets: loose, writeRefusal: "held") == PublicMarkWords.notArchivedHelp)
    }

    @Test("the offer: all private → Make Public; all public → Make Private; some of each → both, each with its count")
    func offer() {
        #expect(PublicMarkMenuItems.Offer(total: 3, alreadyPublic: 0) == PublicMarkMenuItems.Offer(total: 3, alreadyPublic: 0))
        let allPrivate = PublicMarkMenuItems.Offer(total: 3, alreadyPublic: 0)
        #expect(allPrivate.makePublic == 3)
        #expect(allPrivate.makePrivate == 0)
        let allPublic = PublicMarkMenuItems.Offer(total: 3, alreadyPublic: 3)
        #expect(allPublic.makePublic == 0)
        #expect(allPublic.makePrivate == 3)
        let mixed = PublicMarkMenuItems.Offer(total: 5, alreadyPublic: 2)
        #expect(mixed.makePublic == 3)
        #expect(mixed.makePrivate == 2)
    }

    @Test("already: no row is private; a 1 is public; an unreadable row is never 'already'")
    func already() {
        #expect(PublicMarkStore.isAlready(false, nil))
        #expect(!PublicMarkStore.isAlready(true, nil))
        #expect(PublicMarkStore.isAlready(true, reading(1)))
        #expect(!PublicMarkStore.isAlready(false, reading(1)))
        #expect(PublicMarkStore.isAlready(false, reading(0)))
        #expect(!PublicMarkStore.isAlready(true, reading(0)))
        #expect(!PublicMarkStore.isAlready(false, reading(2)), "an unreadable row is replaced by a readable one")
        #expect(!PublicMarkStore.isAlready(true, reading(2)))
    }

    @Test("the words are plain and say that nothing is shared yet")
    func words() {
        #expect(PublicMarkWords.makePublicTitle(1) == "Make Public")
        #expect(PublicMarkWords.makePublicTitle(4) == "Make 4 Public")
        #expect(PublicMarkWords.makePrivateTitle(1) == "Make Private")
        #expect(PublicMarkWords.makePrivateTitle(2) == "Make 2 Private")
        #expect(PublicMarkWords.publicHelp.contains("Nothing is shared yet"))
        #expect(PublicMarkWords.privateHelp.contains("private unless you make it public"))
    }

    @Test("FAIL CLOSED: an unattached store (a viewer launch, a JSON session) shows everything private, refuses and says why")
    func unattachedIsPrivateAndRefuses() {
        let store = PublicMarkStore()
        var lines: [String] = []
        store.note = { lines.append($0) }
        #expect(!store.isPublic(hex(1)))
        #expect(!store.isPublic(nil), "no full SHA-256 is private")
        #expect(store.publicCount(in: [hex(1), hex(2)]) == 0)
        #expect(store.writeRefusal == "the catalog is not open for writing in this session")
        #expect(store.set(true, digests: [hex(1)]) == .refused("the catalog is not open for writing in this session"))
        #expect(!store.isPublic(hex(1)), "a refused write never shows as public")
        #expect(lines.contains { $0.hasPrefix("REFUSED make public: 1 content") })
        #expect(store.set(true, digests: []) == .refused("nothing selected has a full SHA-256"))
    }

    @Test("FAIL CLOSED: the projection takes only an exact 1 — a 0 and an unreadable flag are private, and the unreadable one is counted and said once")
    func theProjectionTakesOnlyAnExactOne() {
        let store = PublicMarkStore()
        var lines: [String] = []
        store.note = { lines.append($0) }
        let rows = [reading(1, id: 1, digest: hex(1)), reading(0, id: 2, digest: hex(2)), reading(2, id: 3, digest: hex(3))]
        #expect(store.apply(rows, takenAt: store.commitEpoch))
        #expect(store.isPublic(hex(1)))
        #expect(store.isPublic(hex(1).uppercased()), "a digest in any case is the same content")
        #expect(!store.isPublic(hex(2)))
        #expect(!store.isPublic(hex(3)))
        #expect(store.publicDigests == [hex(1)])
        #expect(store.unreadable == 1)
        #expect(store.apply(rows, takenAt: store.commitEpoch))
        #expect(lines.filter { $0.contains("holds a value this version cannot read") }.count == 1, "said once, not per load")
    }
}

// MARK: - TRUTH + WRITER + ISOLATION on catalog.sqlite

@MainActor
private func launch(_ scene: CutoverScene) async throws {
    try await scene.launchOnSQLite()
    try #require(scene.model.catalogCutover.isSQLiteAuthority, "the scene launched on catalog.sqlite")
    #expect(await scene.model.publicMarks.load() == nil)
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
    #expect(await fresh.publicMarks.load() == nil)
    return fresh
}

@MainActor
private func digest(_ scene: CutoverScene, _ shape: PoisonedCatalogFixture.Shape) throws -> String {
    try #require(CatalogCommit.digest(of: try scene.record(shape)))
}

@MainActor
private func history(_ model: VideoScanModel, _ digest: String) async throws -> [CatalogRow.PublicMarkReading] {
    let repository = try #require(model.catalogCutover.committer?.repository)
    return try await repository.read { try $0.publicMarkHistory(digest: digest) }
}

@Suite("Make Public — truth and the writer cases on catalog.sqlite", .serialized)
@MainActor
struct PublicMarkTruthTests {

    @Test("TRUTH: a fresh catalog is all private; Make Public → the byte copy is public too, read from catalog.sqlite → relaunch shows it again")
    func publicShowsOnCopiesAndSurvivesRelaunch() async throws {
        let scene = try CutoverScene.make("public_truth"); defer { scene.cleanup() }
        try await launch(scene)
        let shared = try digest(scene, .curatedConflictA)
        #expect(try digest(scene, .curatedConflictB) == shared, "the fixture's two rows are byte copies")
        let store = scene.model.publicMarks
        #expect(store.publicDigests.isEmpty, "everything is private until Rick says otherwise")
        #expect(store.set(true, digests: [shared], files: 1, now: markNow) == .set(changed: 1, unchanged: 0))
        // The OTHER row's globe: asked by its own record.
        let copy = try scene.record(.curatedConflictB)
        #expect(store.isPublic(CatalogCommit.digest(of: copy)))
        #expect(!store.isPublic(try digest(scene, .healthy)), "no other content became public")
        let rows = try await history(scene.model, shared)
        #expect(rows.map(\.isPublic) == [true])
        #expect(rows.first?.decidedAt == Int64(markNow.timeIntervalSince1970))
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("Public: START make public: 1 content (1 file)"), "\(log.suffix(600))")
        #expect(log.contains("Public: OUTCOME make public: 1 content (1 file) — 1 changed, 0 already public; 1 public now."))
        #expect(log.contains("via public marks"), "the committer's own OUTCOME line names the table")

        let fresh = try await relaunch(scene, from: scene.model)
        #expect(fresh.publicMarks.isPublic(shared))
        #expect(fresh.publicMarks.publicDigests == [shared])
        if let committer = fresh.catalogCutover.committer { await committer.repository.close() }
    }

    @Test("Make Private appends a row and clears the globe; the same choice twice writes nothing; a multi-selection is one transaction")
    func privateAgainAndMultiSelection() async throws {
        let scene = try CutoverScene.make("public_private"); defer { scene.cleanup() }
        try await launch(scene)
        let store = scene.model.publicMarks
        let a = try digest(scene, .healthy), b = try digest(scene, .curatedConflictA)
        #expect(store.set(false, digests: [a], now: markNow) == .set(changed: 0, unchanged: 1), "private is the default: no row is written to say so")
        #expect(try await history(scene.model, a).isEmpty)
        #expect(store.set(true, digests: [a], now: markNow) == .set(changed: 1, unchanged: 0))
        #expect(store.set(true, digests: [a], now: markNow) == .set(changed: 0, unchanged: 1), "no duplicate row")
        #expect(store.set(false, digests: [a], now: markNow) == .set(changed: 1, unchanged: 0))
        #expect(try await history(scene.model, a).map(\.isPublic) == [true, false], "history kept; private again is a row, never a delete")
        #expect(!store.isPublic(a))
        #expect(store.set(true, digests: [b], now: markNow) == .set(changed: 1, unchanged: 0))
        #expect(store.publicCount(in: [a, b]) == 1)
        let generation = try #require(scene.model.catalogCutover.committer?.knownGeneration)
        #expect(store.set(true, digests: [a, b], files: 3, now: markNow) == .set(changed: 1, unchanged: 1))
        #expect(scene.model.catalogCutover.committer?.knownGeneration == generation + 1, "one transaction for the selection")
        #expect(store.publicCount(in: [a, b]) == 2)
    }

    @Test("WRITER: a mark set inside the 2 s debounce window of a record edit — both land, both survive the relaunch")
    func insideTheDebounceWindow() async throws {
        let scene = try CutoverScene.make("public_debounce"); defer { scene.cleanup() }
        try await launch(scene)
        let healthy = try scene.record(.healthy)
        let d = try digest(scene, .healthy)
        healthy.userNotes = "typed just before the mark"
        scene.model.saveCatalogDebounced()
        let committer = try #require(scene.model.catalogCutover.committer)
        #expect(committer.isBusy, "the edit is waiting on the debounce timer")
        #expect(scene.model.publicMarks.set(true, digests: [d], now: markNow) == .set(changed: 1, unchanged: 0))
        #expect(committer.blockedReason == nil, "the side-table commit did not block the record commit")
        #expect(scene.model.saveCatalogNow(), "the edit inside the window still commits")
        let fresh = try await relaunch(scene, from: scene.model)
        #expect(fresh.publicMarks.isPublic(d))
        #expect(fresh.records.first { $0.id == healthy.id }?.userNotes == "typed just before the mark")
        if let c = fresh.catalogCutover.committer { await c.repository.close() }
    }

    @Test("WRITER: during a job's write hold the mark is REFUSED with the hold's words, nothing is written and nothing shows public; after release it lands and survives the relaunch")
    func duringAWriteHold() async throws {
        let scene = try CutoverScene.make("public_hold"); defer { scene.cleanup() }
        try await launch(scene)
        let d = try digest(scene, .healthy)
        let store = scene.model.publicMarks
        #expect(await scene.model.catalogStore.holdWrites(reason: "a test job", owner: CatalogWriteHoldOwner()) == .taken)
        let held = store.set(true, digests: [d], now: markNow)
        guard case .refused(let words) = held else { Issue.record("expected a refusal, got \(held)"); return }
        #expect(words.contains("held — a test job"))
        #expect(store.writeRefusal != nil, "the menu is disabled while held")
        #expect(!store.isPublic(d), "a refused write never shows as public")
        #expect(try await history(scene.model, d).isEmpty, "nothing written")
        #expect(scene.sandbox.catalogLogText().contains("Public: REFUSED make public: 1 content"))
        scene.model.catalogStore.releaseWriteHold()
        #expect(store.set(true, digests: [d], now: markNow) == .set(changed: 1, unchanged: 0))
        let fresh = try await relaunch(scene, from: scene.model)
        #expect(fresh.publicMarks.isPublic(d))
        if let c = fresh.catalogCutover.committer { await c.repository.close() }
    }

    @Test("WRITER: across a role flip — master makes public, viewer is refused (nothing written), master again makes private; the relaunch shows the master's last choice")
    func acrossAViewerMasterFlip() async throws {
        let scene = try CutoverScene.make("public_flip"); defer { scene.cleanup() }
        try await launch(scene)
        let d = try digest(scene, .healthy)
        let store = scene.model.publicMarks
        #expect(store.set(true, digests: [d], now: markNow) == .set(changed: 1, unchanged: 0))
        scene.model.updateReadOnlyFacts { $0.viewerRole = true }
        let refused = store.set(false, digests: [d], now: markNow)
        guard case .refused(let words) = refused else { Issue.record("expected a refusal, got \(refused)"); return }
        #expect(words.contains("viewer"))
        let targets = PublicMarkTargets(records: [try scene.record(.healthy)]) { _ in true }
        #expect(PublicMarkMenuItems.refusal(targets: targets, writeRefusal: store.writeRefusal) != nil)
        #expect(try await history(scene.model, d).map(\.isPublic) == [true], "the viewer wrote nothing")
        #expect(store.isPublic(d), "and the mark still shows what the table holds")
        scene.model.updateReadOnlyFacts { $0.viewerRole = false }
        #expect(store.set(false, digests: [d], now: markNow) == .set(changed: 1, unchanged: 0))
        let fresh = try await relaunch(scene, from: scene.model)
        #expect(!fresh.publicMarks.isPublic(d))
        if let c = fresh.catalogCutover.committer { await c.repository.close() }
    }

    @Test("ISOLATION, FAIL CLOSED: a poisoned row (flag 2) over a public one reads as PRIVATE with one log line, never a crash; a readable choice replaces it")
    func poisonedRow() async throws {
        let scene = try CutoverScene.make("public_poison"); defer { scene.cleanup() }
        try await launch(scene)
        let d = try digest(scene, .healthy)
        let store = scene.model.publicMarks
        #expect(store.set(true, digests: [d], now: markNow) == .set(changed: 1, unchanged: 0))
        try scene.execSQL("PRAGMA ignore_check_constraints = ON; INSERT INTO public_marks (digest, is_public, decided_at) VALUES ('\(d)', 2, 1);")
        #expect(await store.load() == nil)
        #expect(store.unreadable == 1)
        #expect(!store.isPublic(d), "the newest row cannot be read: private")
        #expect(await store.load() == nil)
        let said = scene.sandbox.catalogLogText().components(separatedBy: "holds a value this version cannot read").count - 1
        #expect(said == 1, "said once, not per load")
        #expect(store.set(true, digests: [d], now: markNow) == .set(changed: 1, unchanged: 0), "an unreadable row is never 'already public'")
        #expect(store.isPublic(d))
    }

    @Test("ISOLATION: a stale projection never skips a real change — the table decides changed / unchanged")
    func staleProjectionDoesNotSkipARealChange() async throws {
        let scene = try CutoverScene.make("public_stale"); defer { scene.cleanup() }
        try await launch(scene)
        let d = try digest(scene, .healthy)
        let store = scene.model.publicMarks
        _ = store.set(true, digests: [d], now: markNow)
        store.attach(try #require(store.backing))                 // projection cleared: shows private
        #expect(store.set(true, digests: [d], now: markNow) == .set(changed: 0, unchanged: 1))
        #expect(store.isPublic(d), "the read-back corrected the projection")
        #expect(try await history(scene.model, d).count == 1, "no duplicate row")
        store.apply([], takenAt: store.commitEpoch)               // the projection now lies: private
        #expect(store.set(false, digests: [d], now: markNow) == .set(changed: 1, unchanged: 0))
        #expect(try await history(scene.model, d).map(\.isPublic) == [true, false])
    }

    @Test("ISOLATION: a load snapshot taken before a commit never replaces the newer committed state")
    func anOlderLoadSnapshotNeverWins() async throws {
        let scene = try CutoverScene.make("public_load"); defer { scene.cleanup() }
        try await launch(scene)
        let d = try digest(scene, .healthy)
        let store = scene.model.publicMarks
        _ = store.set(true, digests: [d], now: markNow)
        let takenAt = store.commitEpoch                           // a load reads here (d is public)…
        let stalePublic = [reading(1, id: 1, digest: d)]
        _ = store.set(false, digests: [d], now: markNow)          // …Rick makes it private while it is suspended…
        #expect(store.apply(stalePublic, takenAt: takenAt) == false, "…and its older snapshot is not applied")
        #expect(!store.isPublic(d), "a stale load never re-publishes a video Rick made private")
    }

    @Test("ISOLATION: a content catalog.sqlite does not hold rolls the WHOLE change back — the other content is not marked either")
    func missingContentRollsBack() async throws {
        let scene = try CutoverScene.make("public_missing"); defer { scene.cleanup() }
        try await launch(scene)
        let d = try digest(scene, .healthy)
        let outcome = scene.model.publicMarks.set(true, digests: [d, hex(0xdead)], now: markNow)
        guard case .refused(let words) = outcome else { Issue.record("expected a refusal, got \(outcome)"); return }
        #expect(words.contains("is not in catalog.sqlite yet"))
        #expect(try await history(scene.model, d).isEmpty)
        #expect(!scene.model.publicMarks.isPublic(d))
        #expect(scene.model.catalogCutover.committer?.blockedReason == nil, "a refused mark never blocks the catalog")
    }

    // MARK: Codex cycle #273

    @Test("Codex #273 F2: Make Private on a selection holding a content catalog.sqlite does not have is refused WHOLE — the stored one stays public, nothing is written")
    func missingContentRollsBackMakePrivateToo() async throws {
        let scene = try CutoverScene.make("public_c273_f2"); defer { scene.cleanup() }
        try await launch(scene)
        let d = try digest(scene, .healthy)
        let store = scene.model.publicMarks
        #expect(store.set(true, digests: [d], now: markNow) == .set(changed: 1, unchanged: 0))
        let generation = try #require(scene.model.catalogCutover.committer?.knownGeneration)
        let outcome = store.set(false, digests: [d, hex(0xdead)], now: markNow)
        guard case .refused(let words) = outcome else { Issue.record("expected a refusal, got \(outcome)"); return }
        #expect(words.contains("is not in catalog.sqlite yet"))
        #expect(try await history(scene.model, d).map(\.isPublic) == [true], "the stored content was not half-written")
        #expect(scene.model.catalogCutover.committer?.knownGeneration == generation, "no commit")
        #expect(store.isPublic(d), "the mark still shows what the table holds")
        // The same rule for a no-op: "already private" never hides a content the catalog does not hold.
        let noop = store.set(false, digests: [hex(0xbeef)], now: markNow)
        guard case .refused = noop else { Issue.record("expected a refusal, got \(noop)"); return }
    }
}

// MARK: - SCALE

@Suite("Make Public — SCALE (100k)")
@MainActor
struct PublicMarkScaleTests {

    /// The menu's work at right-click for a 100k-row selection: targets (one
    /// digest rule per record) and the offer (one set probe per content),
    /// against a projection of 100k public contents. Budget 2 s (Debug, M4
    /// Max) — O(n²) would be hours.
    @Test(.timeLimit(.minutes(2)))
    func hundredThousandSelected() {
        let records = (1...100_000).map { record(digest: hex($0)) }
        let store = PublicMarkStore()
        store.apply((1...100_000).map { reading(1, id: Int64($0), digest: hex($0)) }, takenAt: store.commitEpoch)
        let clock = ContinuousClock()
        var targets = PublicMarkTargets(records: []) { _ in true }
        var alreadyPublic = 0
        let elapsed = clock.measure {
            targets = PublicMarkTargets(records: records) { _ in true }
            alreadyPublic = store.publicCount(in: targets.digests)
        }
        print("[make-public] 100k selected: targets + offer \(elapsed)")
        #expect(targets.digests.count == 100_000)
        #expect(alreadyPublic == 100_000)
        #expect(elapsed < .seconds(2))
    }
}

// MARK: - SENSOR

@Suite("Make Public — sensors")
@MainActor
struct PublicMarkSensorTests {

    @Test("the menu holds no SQL and no commit; Public/ adds no model extension; the store's one door names the table")
    func noSQLNoCommitInTheViews() throws {
        let menu = try SourceTree.appCode(named: "Public/PublicMarkMenu.swift")
        #expect(!menu.isEmpty)
        // "import " + "GRDB": spelled apart so this file never reads as a GRDB importer (CatalogStoreSensorTests).
        for token in ["commitSideTables", "writeBlocking", "INSERT", "appendPublicMark", "extension VideoScanModel", "import " + "GRDB"] {
            #expect(!menu.contains(token), "PublicMarkMenu.swift contains \(token)")
        }
        let store = try SourceTree.appCode(named: "Public/PublicMarkStore.swift")
        #expect(!store.contains("extension VideoScanModel"))
        #expect(store.contains("commitSideTables(what, via: .publicMarks, body)"), "the one door")
        #expect(!store.contains("INSERT"), "no SQL in the app; the Core door appends")
        #expect(store.components(separatedBy: "appendPublicMark(").count - 1 == 1, "one place appends a mark")
        #expect(store.contains("tx.publicMarkContentHeld(digests: keys)"), "the whole selection is checked before anything is written (Codex #273 F2)")
        // Rick 2026-11-09: private is the default; there is no bulk "make everything private" (Codex #273 F1 went with it).
        for code in [store, menu] {
            #expect(!code.lowercased().contains("everythingprivate"))
        }
    }

    @Test("the Archive row menu carries the items and asks the PROVEN archived predicate, never the sampled one")
    func archiveRowMenuCarriesTheItems() throws {
        let table = try SourceTree.appCode(named: "Archive/ArchiveView+Table.swift")
        let start = try #require(table.range(of: "func recordContextMenu("))
        let menu = table[start.lowerBound...]
        #expect(menu.contains("PublicMarkMenuItems(store: model.publicMarks"))
        #expect(menu.contains("PublicMarkTargets(records: recs) { model.isProvenArchived($0) }"))
        #expect(table.contains("PublicMarkBadge(store: model.publicMarks, record: rec"), "the Files table shows the globe")
        let timeline = try SourceTree.appCode(named: "Archive/ArchiveView+Timeline.swift")
        #expect(timeline.contains("PublicMarkBadge(store: model.publicMarks"), "the tab feeds the Timeline the globe")
        #expect(timeline.contains("publicBadge(item.id)"), "the Timeline card shows it")
    }

    @Test("the globe reads the store's projection of catalog.sqlite — never a record field, a tag or a path")
    func theGlobeReadsTheStore() throws {
        let menu = try SourceTree.appCode(named: "Public/PublicMarkMenu.swift")
        let start = try #require(menu.range(of: "struct PublicMarkBadge"))
        let end = try #require(menu.range(of: "enum PublicMarkDialogs"))
        let badge = menu[start.lowerBound..<end.lowerBound]
        #expect(badge.contains("store.isPublic(record.flatMap(CatalogCommit.digest(of:)))"))
        for token in [".tags", "fullPath", "filename", "userNotes"] {
            #expect(!badge.contains(token), "the globe reads \(token)")
        }
    }
}
