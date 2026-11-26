// HeldBackTests.swift — GH #339 (DECISIONS 2026-11-25 evening, item 3):
// "Held back at import" — the read-only list, Find Moved Copies, the carry.
//   LOGIC     each row lands in the group its evidence says; fields judged
//             carry / already / conflict / archived; the job plan leaves out
//             rows with nothing to carry, a finding, or an unreadable record;
//   TRUTH     a row on a drive that is not connected is never "gone"; a
//             name + size lead is never shown as "moved"; group words name
//             what was checked; a poisoned old record says so;
//   PROOF     whole-file SHA-256 read now proves; a same-name, same-size file
//             whose content differs is NOT offered; the sampled hash proves
//             only as "sampled"; a row with no stored hash is never offered;
//   SCALE     100k live records + 2,110 rows classified and planned in budget;
//   ISOLATION poisoned raw_row text in the real table is listed as "could
//             not be read" and never planned;
//   WRITER    (HeldBackCarryTests) no write without confirmation; never over
//             a live value Rick set; an edit inside the debounce window is
//             seen; refused during a write hold and after a role flip;
//             archived files keep their date; a changed file is skipped; the
//             carry survives a relaunch with its provenance;
//   MEDIA     N/A — bytes are hashed, never decoded (any container proves the same).
// Invented fixtures only; every file lives in a sandbox folder.

import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - Fixtures

enum HeldBackFixture {
    static func row(_ qid: Int64, path: String, size: Int64? = 100, digest: String? = nil, sampled: String? = nil,
                    findings: Int = 0, raw: String? = #"{"mediaDisposition":"Important"}"#,
                    resolvedNote: String? = nil) -> CatalogRow.HeldBackRow {
        CatalogRow.HeldBackRow(qid: qid, reasonCode: "removedNoDigest", words: "invented", fullPath: path, sizeBytes: size,
                               digest: digest, sampledHash: sampled, findingsCount: findings, rawRowText: raw,
                               quarantinedAt: 1_700_000_000, resolvedFileID: resolvedNote == nil ? nil : "X",
                               resolvedAt: resolvedNote == nil ? nil : 1, resolution: resolvedNote == nil ? nil : "personDecided",
                               resolutionNote: resolvedNote)
    }

    static func live(_ name: String, path: String, size: Int64 = 100, digest: String? = String(repeating: "a", count: 64),
                     disposition: MediaDisposition = .unreviewed, date: String? = nil, place: String? = nil,
                     archived: Bool = false, fixity: ContentFixity? = nil) -> HeldBackLive {
        HeldBackLive(id: UUID(), filename: name, sizeBytes: size, fullPath: path, digest: digest, disposition: disposition,
                     userDate: date, userPlace: place, dateReadOnly: archived, fixity: fixity)
    }

    /// An invented stored fixity for `digest` (the stamp is never stat'ed:
    /// the pure tests inject `describesNow`).
    static func fixity(_ digest: String, size: Int64 = 100) -> ContentFixity {
        ContentFixity(digest: digest, byteCount: size,
                      stamp: FileIdentityStamp(device: 1, inode: 2, size: size, mtimeNs: 3, ctimeNs: 4, volumeUUID: "V"))
    }

    /// Drive "Online" is mounted; "Offline" is not; `files` exist (regular files), the rest are absent.
    /// `unchanged`: the paths whose stored stamp still describes the file (default: every present file).
    static func disk(_ files: Set<String>, unchanged: Set<String>? = nil) -> HeldBackDisk {
        let same = unchanged ?? files
        return HeldBackDisk(driveOnline: { !$0.hasPrefix("/Volumes/Offline/") }, probe: { files.contains($0) ? .regularFile : .absent },
                            describesNow: { _, path in same.contains(path) })
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// A sandbox folder removed when the test case ends (TestScratch; the suite carries `.scratchCleanup`).
    static func scratch(_ tag: String) throws -> URL {
        try TestScratch.unique("heldback-\(tag)-")
    }

    static func curated(_ json: String) -> HeldBackCurated {
        guard case .read(let c) = HeldBackCurated.parse(json) else { fatalError("fixture JSON") }
        return c
    }
}

// MARK: - The plan (pure)

@Suite("Held back at import (#339) — where each file is now, what may be carried")
struct HeldBackPlanTests {

    typealias F = HeldBackFixture

    @Test("LOGIC: each row lands in the group its evidence says")
    func groups() {
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        let back = F.live("back.mov", path: "/Volumes/Online/a/back.mov", digest: a, fixity: F.fixity(a))
        let touched = F.live("touched.mov", path: "/Volumes/Online/a/touched.mov", digest: a, fixity: F.fixity(a))
        let other = F.live("taken.mov", path: "/Volumes/Online/a/taken.mov", digest: b)
        let moved = F.live("moved.mov", path: "/Volumes/Online/new/moved.mov")
        let index = HeldBackLiveIndex([back, other, moved, touched])
        let rows = [
            F.row(1, path: "/Volumes/Online/a/back.mov", digest: a),
            F.row(2, path: "/Volumes/Online/a/loose.mov"),
            F.row(3, path: "/Volumes/Online/old/moved.mov"),
            F.row(4, path: "/Volumes/Online/old/moved.mov", size: 101),
            F.row(5, path: "/Volumes/Offline/x/moved.mov"),
            F.row(6, path: "/Volumes/Online/a/done.mov", resolvedNote: "carried"),
            F.row(7, path: "/Volumes/Online/a/taken.mov", digest: a),
            F.row(8, path: "/Volumes/Online/a/denied.mov"),
            F.row(9, path: "/Volumes/Online/a/touched.mov", digest: a),
        ]
        let present: Set<String> = ["/Volumes/Online/a/back.mov", "/Volumes/Online/a/loose.mov", "/Volumes/Online/a/taken.mov",
                                    "/Volumes/Online/a/touched.mov"]
        let disk = HeldBackDisk(driveOnline: { !$0.hasPrefix("/Volumes/Offline/") }, probe: { path in
            if path.hasSuffix("denied.mov") { return .couldNotCheck("Permission denied (errno 13)") }
            return present.contains(path) ? .regularFile : .absent
        }, describesNow: { _, path in path.hasSuffix("back.mov") })
        let entries = HeldBackClassifier.classify(rows, live: index, disk: disk)
        #expect(entries[0].whereNow == .alreadyBack(recordID: back.id), "same path, same whole-file SHA-256, AND its stamp still describes the file")
        #expect(entries[1].whereNow == .onDiskNotCatalogued)
        #expect(entries[2].whereNow == .goneLikelyMoved(candidates: [moved.id]))
        #expect(entries[3].whereNow == .goneNoMatch, "same name, different size is no lead")
        #expect(entries[4].whereNow == .driveNotConnected(drive: "Offline"))
        #expect(entries[5].whereNow == .resolved(note: "carried"))
        #expect(entries[6].whereNow == .pathTaken(recordID: other.id, candidates: [other.id]), "a path is not an identity; the occupant is only a name + size lead")
        #expect(entries[7].whereNow == .couldNotCheck(reason: "Permission denied (errno 13)"))
        #expect(entries[8].whereNow == .pathMayHaveChanged(recordID: touched.id, candidates: [touched.id]),
                "same stored digest, but the stamp no longer describes the file: it may have changed (Codex #389 P0)")
        #expect(HeldBackClassifier.grouped(entries).map(\.group) == HeldBackGroup.allCases)
    }

    @Test("TRUTH: a row whose drive is not connected is never called gone, and its file is never asked about")
    func offlineIsNeverGone() {
        let asked = HeldBackAskedPaths()
        let disk = HeldBackDisk(driveOnline: { _ in false }, probe: { asked.add($0); return .absent })
        let entries = HeldBackClassifier.classify([F.row(1, path: "/Volumes/Offline/a.mov")],
                                                  live: HeldBackLiveIndex([F.live("a.mov", path: "/Volumes/Online/a.mov")]), disk: disk)
        #expect(entries[0].whereNow.group == .driveNotConnected)
        #expect(asked.paths.isEmpty)
        #expect(HeldBackGroup.driveNotConnected.evidence.contains("nothing is said about the file"))
    }

    @Test("TRUTH: the group words say what was checked; a name + size lead is never called moved")
    func groupWordsAreEvidence() {
        #expect(HeldBackGroup.goneLikelyMoved.title.contains("same name and size"))
        #expect(!HeldBackGroup.goneLikelyMoved.title.lowercased().contains("moved"))
        #expect(HeldBackGroup.goneLikelyMoved.evidence.contains("not proof"))
        for g in HeldBackGroup.allCases { #expect(!g.evidence.isEmpty) }
        #expect(HeldBackWords.curated(.unreadable("the old record is not valid JSON")).hasPrefix("the old record could not be read"))
        #expect(HeldBackWords.statusLine(2_110) == "Held back at import: 2,110 — why")
    }

    @Test("LOGIC: fields — carry into an empty field, already when equal, conflict when Rick set another value, archived keeps its date")
    func fields() {
        let old = F.curated(#"{"mediaDisposition":"Important","userDate":"1992","userPlace":"Cape Cod"}"#)
        let empty = HeldBackFields.evaluate(old: old, live: F.live("a", path: "/a"))
        #expect(empty.tag == .carry("Important"))
        #expect(empty.date == .carry("1992"))
        #expect(empty.place == .carry("Cape Cod"))
        let same = HeldBackFields.evaluate(old: old, live: F.live("a", path: "/a", disposition: .important, date: "1992", place: "Cape Cod"))
        #expect(same.allAlready)
        #expect(!same.carriesAny)
        let mine = HeldBackFields.evaluate(old: old, live: F.live("a", path: "/a", disposition: .recoverable, date: "1980", place: "Boston"))
        #expect(mine.tag == .conflict(old: "Important", live: "Recoverable"))
        #expect(mine.date == .conflict(old: "1992", live: "1980"))
        #expect(mine.place == .conflict(old: "Cape Cod", live: "Boston"))
        let archived = HeldBackFields.evaluate(old: old, live: F.live("a", path: "/a", archived: true))
        #expect(archived.date == .archived("1992"))
        #expect(archived.tag == .carry("Important"))
        let unreviewed = HeldBackFields.evaluate(old: F.curated(#"{"mediaDisposition":"Unreviewed"}"#), live: F.live("a", path: "/a"))
        #expect(unreviewed.all.isEmpty)
    }

    @Test("LOGIC: an offer onto a file with no full SHA-256, or with only conflicts, cannot be selected")
    func offerBlocking() throws {
        let entry = HeldBackClassifier.classify([F.row(1, path: "/Volumes/Online/old/a.mov")], live: HeldBackLiveIndex([]), disk: F.disk([]))[0]
        let old = F.curated(#"{"mediaDisposition":"Important"}"#)
        let stamp = FileIdentityStamp(device: 1, inode: 2, size: 100, mtimeNs: 3, ctimeNs: 4)
        let pending = HeldBackOffer.make(entry: entry, old: old, live: F.live("a.mov", path: "/b/a.mov", digest: nil), evidence: .sampledHash, stamp: stamp)
        #expect(!pending.isSelectable)
        #expect(pending.blocked == HeldBackWords.needsFullHash)
        let conflict = HeldBackOffer.make(entry: entry, old: old, live: F.live("a.mov", path: "/b/a.mov", disposition: .recoverable), evidence: .sampledHash, stamp: stamp)
        #expect(!conflict.isSelectable)
        let good = HeldBackOffer.make(entry: entry, old: old, live: F.live("a.mov", path: "/b/a.mov"), evidence: .wholeFileSHA256, stamp: stamp)
        #expect(good.isSelectable)
    }

    @Test("LOGIC: Find Moved Copies plans only gone rows with a lead, a readable record, no finding, and something to carry")
    func jobPlan() {
        let lead = F.live("a.mov", path: "/Volumes/Online/new/a.mov")
        let index = HeldBackLiveIndex([lead])
        let rows = [
            F.row(1, path: "/Volumes/Online/old/a.mov"),
            F.row(2, path: "/Volumes/Online/old/a.mov", raw: #"{"mediaDisposition":"Unreviewed"}"#),
            F.row(3, path: "/Volumes/Online/old/a.mov", findings: 1),
            F.row(4, path: "/Volumes/Online/old/a.mov", raw: "{poisoned"),
            F.row(5, path: "/Volumes/Online/old/none.mov"),
        ]
        let entries = HeldBackClassifier.classify(rows, live: index, disk: F.disk([]))
        let plan = HeldBackJobPlan.make(entries: entries, live: index)
        #expect(plan.tasks.map(\.entry.qid) == [1])
        #expect(plan.skippedNothingToCarry == 1)
        #expect(plan.skippedFinding == 1)
        #expect(plan.skippedUnreadable == 1)
        #expect(plan.candidateCount == 1)
    }

    @Test("SCALE: 100k live records + 2,110 held-back rows classified and planned within 3 s (Debug)")
    func scale() {
        var live: [HeldBackLive] = []
        live.reserveCapacity(100_000)
        for i in 0..<100_000 { live.append(F.live("clip\(i).mov", path: "/Volumes/Online/live/clip\(i).mov", size: Int64(1_000 + i))) }
        let rows = (0..<2_110).map { i in
            F.row(Int64(i + 1), path: "/Volumes/Online/old/clip\(i * 40).mov", size: Int64(1_000 + i * 40),
                  raw: #"{"mediaDisposition":"Important","userDate":"1992"}"#)
        }
        let clock = ContinuousClock()
        let start = clock.now
        let index = HeldBackLiveIndex(live)
        let entries = HeldBackClassifier.classify(rows, live: index, disk: F.disk([]))
        let plan = HeldBackJobPlan.make(entries: entries, live: index)
        let elapsed = clock.now - start
        #expect(entries.count == 2_110)
        #expect(plan.tasks.count == 2_110, "every row has its name + size lead")
        #expect(elapsed < .seconds(3), "took \(elapsed)")
    }
}

final class HeldBackAskedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var paths: [String] { lock.withLock { stored } }
    func add(_ p: String) { lock.withLock { stored.append(p) } }
}

// MARK: - The proof (real files in a sandbox)

@Suite("Held back at import (#339) — proven by content, never by name", .scratchCleanup)
struct HeldBackProofTests {

    typealias F = HeldBackFixture

    @Test("PROOF: the whole-file SHA-256 read now proves; a same-size file with other bytes differs")
    func wholeFile() throws {
        let dir = try F.scratch("whole")
        let a = dir.appendingPathComponent("a.mov"), b = dir.appendingPathComponent("b.mov")
        let bytes = Data(repeating: 7, count: 4_096)
        try bytes.write(to: a)
        try Data(repeating: 8, count: 4_096).write(to: b)
        let prover = HeldBackProver.live(shouldCancel: { false })
        let digestA = F.sha256(bytes), digestB = F.sha256(Data(repeating: 8, count: 4_096))
        guard case .proven(.wholeFileSHA256, let stamp) = prover.prove(rowDigest: digestA, rowSampled: nil, candidatePath: a.path,
                                                                       destinationDigest: digestA)
        else { Issue.record("not proven"); return }
        #expect(stamp == FileIdentityStamp.capture(path: a.path))
        #expect(prover.prove(rowDigest: digestA, rowSampled: nil, candidatePath: b.path, destinationDigest: digestB) == .differs(.wholeFileSHA256))
        #expect(prover.prove(rowDigest: digestA, rowSampled: nil, candidatePath: a.path, destinationDigest: nil) == .noDestinationDigest,
                "no stored identity on the live file's row: nothing to bind the proof to")
    }

    @Test("PROOF: the sampled hash proves only as sampled; no stored hash is no proof; a missing file is not checked")
    func sampledAndNone() throws {
        let dir = try F.scratch("sampled")
        let a = dir.appendingPathComponent("a.mov")
        try Data(repeating: 3, count: 10_000).write(to: a)
        let stored = FileHasher.segmentedHash(path: a.path)
        let mine = F.sha256(try Data(contentsOf: a))
        let prover = HeldBackProver.live(shouldCancel: { false })
        guard case .proven(.sampledHash, _) = prover.prove(rowDigest: nil, rowSampled: stored, candidatePath: a.path, destinationDigest: mine)
        else { Issue.record("not proven"); return }
        #expect(prover.prove(rowDigest: nil, rowSampled: "v1:" + String(repeating: "0", count: 64), candidatePath: a.path,
                             destinationDigest: mine) == .differs(.sampledHash))
        #expect(prover.prove(rowDigest: nil, rowSampled: stored, candidatePath: a.path, destinationDigest: String(repeating: "e", count: 64))
                == .notTheRecordedContent, "a sampled match onto a row whose stored identity is not the file's is never offered")
        #expect(prover.prove(rowDigest: nil, rowSampled: nil, candidatePath: a.path, destinationDigest: mine) == .noEvidence)
        guard case .couldNotRead = prover.prove(rowDigest: String(repeating: "a", count: 64), rowSampled: nil,
                                                 candidatePath: dir.appendingPathComponent("gone.mov").path,
                                                 destinationDigest: String(repeating: "a", count: 64))
        else { Issue.record("a missing file must be 'not checked'"); return }
        #expect(HeldBackEvidence.sampledHash.words.contains("likely the same file"))
    }

    @Test("PROOF: the job offers the proven pair, never the same-name, same-size file whose content differs — and writes nothing")
    @MainActor
    func jobOffersOnlyProven() async throws {
        let dir = try F.scratch("job")
        let goodDir = dir.appendingPathComponent("good"), badDir = dir.appendingPathComponent("bad")
        try FileManager.default.createDirectory(at: goodDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        let bytes = Data(repeating: 9, count: 2_048)
        try bytes.write(to: goodDir.appendingPathComponent("clip.mov"))
        try Data(repeating: 1, count: 2_048).write(to: badDir.appendingPathComponent("clip.mov"))
        let good = F.live("clip.mov", path: goodDir.appendingPathComponent("clip.mov").path, size: 2_048, digest: F.sha256(bytes))
        let bad = F.live("clip.mov", path: badDir.appendingPathComponent("clip.mov").path, size: 2_048,
                         digest: F.sha256(Data(repeating: 1, count: 2_048)))
        let index = HeldBackLiveIndex([good, bad])
        let rows = [F.row(1, path: "/Volumes/Online/old/clip.mov", size: 2_048, digest: F.sha256(bytes))]
        let plan = HeldBackJobPlan.make(entries: HeldBackClassifier.classify(rows, live: index, disk: F.disk([])), live: index)
        let lines = HeldBackLineSink()
        var delivered: [HeldBackOffer]?
        let job = FindMovedCopiesJob(plan: plan, note: { lines.add($0) }, deliver: { delivered = $0 })
        job.start()
        await job.task?.value
        #expect(job.tally.proven == 1)
        #expect(job.tally.differs == 1)
        #expect(delivered?.map(\.recordID) == [good.id])
        #expect(lines.lines.contains { $0.contains("DIFFERS") && $0.contains("not offered") })
        #expect(lines.lines.last?.contains("nothing was written") == true)
        if case .finished = job.state {} else { Issue.record("job state \(job.state)") }
    }
}

final class HeldBackLineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.withLock { stored } }
    func add(_ l: String) { lock.withLock { stored.append(l) } }
}

// MARK: - The writer (a real catalog.sqlite under a launched model)

@MainActor
struct HeldBackScene {
    let scene: CutoverScene
    var model: VideoScanModel { scene.model }
    var store: HeldBackStore { scene.model.heldBack }

    static func make(_ label: String) async throws -> HeldBackScene {
        let scene = try CutoverScene.make("heldback_\(label)")
        try await scene.launchOnSQLite()
        #expect(scene.model.saveCatalogNow(), "the launch commit lands first")
        let s = HeldBackScene(scene: scene)
        s.store.disk = HeldBackDisk(driveOnline: { _ in true }, probe: { _ in .absent })
        await s.store.loadList()
        return s
    }

    func cleanup() { scene.cleanup() }

    /// The healthy record moved onto a real sandbox file (so the stamp re-check has a file), committed.
    func liveRecord() throws -> VideoRecord {
        let record = try scene.record(.healthy)
        let file = scene.folder.appendingPathComponent("moved-\(record.filename)")
        if !FileManager.default.fileExists(atPath: file.path) { try Data(repeating: 5, count: 512).write(to: file) }
        if record.fullPath != file.path {
            record.fullPath = file.path
            #expect(model.saveCatalogNow())
        }
        return record
    }

    /// An open held-back row the DDL lets a person close (no finding).
    func openRow() throws -> HeldBackEntry {
        try #require(store.entries.first { !$0.isResolved && $0.findingsCount == 0 })
    }

    /// One proven offer of `old` onto `record`, built the way the job builds it.
    func offer(_ old: String, onto record: VideoRecord) throws -> HeldBackOffer {
        let entry = try openRow()
        let stamp = try #require(FileIdentityStamp.capture(path: record.fullPath))
        let live = HeldBackLive(record, dateReadOnly: model.isDateReadOnly(record))
        let offer = HeldBackOffer.make(entry: entry, old: HeldBackFixture.curated(old), live: live, evidence: .wholeFileSHA256, stamp: stamp)
        store.setOffers([offer])
        return offer
    }

    /// Carry exactly what the confirmation would show now (preview → carry).
    @discardableResult
    func carryNow(_ ids: Set<String>) async -> HeldBackStore.CarryOutcome {
        await store.carry(await store.previewCarryNow(ids))
    }

    func generation() async throws -> Int {
        try await #require(scene.model.catalogCutover.committer).repository.read { $0.generation }
    }

    func openCountInDatabase() async throws -> Int {
        try await #require(scene.model.catalogCutover.committer).repository.read { try $0.heldBackOpenCount() }
    }

    /// One value from a private read-only connection (after the app's commits).
    func query(_ sql: String) throws -> String? {
        var db: OpaquePointer?
        defer { sqlite3_close_v2(db) }
        guard sqlite3_open_v2(scene.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW,
              let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }
}

@Suite("Held back at import (#339) — the carry: confirmed, never over Rick's values, through the one door", .serialized)
@MainActor
struct HeldBackCarryTests {

    static let old = #"{"mediaDisposition":"Important","userDate":"1992-06","userDateConfidence":"known","userPlace":"Cape Cod"}"#

    @Test("WRITER: the list, the job's offers and an unconfirmed offer write nothing")
    func noWriteWithoutConfirmation() async throws {
        let s = try await HeldBackScene.make("noconfirm"); defer { s.cleanup() }
        let record = try s.liveRecord()
        let generation = try await s.generation()
        let open = try await s.openCountInDatabase()
        _ = try s.offer(Self.old, onto: record)
        await s.store.loadList()
        #expect(try await s.generation() == generation, "no commit without Carry")
        #expect(try await s.openCountInDatabase() == open)
        #expect(record.mediaDisposition == .unreviewed)
        #expect(record.userDate == nil)
        #expect(await s.carryNow([]) == .refused("nothing was selected"))
        #expect(try await s.generation() == generation)
    }

    @Test("WRITER: a confirmed carry sets tag, date and place, closes the row, and survives a relaunch with its provenance")
    func carryAndRelaunch() async throws {
        let s = try await HeldBackScene.make("carry"); defer { s.cleanup() }
        let record = try s.liveRecord()
        let offer = try s.offer(Self.old, onto: record)
        let open = try await s.openCountInDatabase()
        let outcome = await s.carryNow([offer.id])
        #expect(outcome == .carried(carried: 1, closed: 1, skipped: 0))
        #expect(record.mediaDisposition == .important)
        #expect(record.userDate == "1992-06")
        #expect(record.userDateConfidence == "known")
        #expect(record.userPlace == "Cape Cod")
        #expect(try await s.openCountInDatabase() == open - 1)
        #expect(s.store.openCount == open - 1)
        // Relaunch: a fresh open of catalog.sqlite reads both back.
        let reloaded = try await s.scene.reloaded(.healthy)
        #expect(reloaded.mediaDisposition == .important)
        #expect(reloaded.userDate == "1992-06")
        #expect(reloaded.userPlace == "Cape Cod")
        #expect(try s.query("SELECT resolution FROM quarantine WHERE qid = \(offer.qid)") == "personDecided")
        #expect(try s.query("SELECT resolved_file_id FROM quarantine WHERE qid = \(offer.qid)") == record.id.uuidString)
        #expect(try s.query("SELECT resolution_note FROM quarantine WHERE qid = \(offer.qid)")?.contains("October import row") == true)
        #expect(try s.query("SELECT count(*) FROM row_knowledge WHERE source = 'app:import carry' AND field = 'userDate'") == "1")
        #expect(try s.query("SELECT count(*) FROM generation_history WHERE writer = 'import carry'") == "2", "the records, then the closure")
        #expect(s.scene.sandbox.catalogLogText().contains("via import carry"))
    }

    @Test("WRITER: never over a value Rick already set — the conflict is shown, his value stays, the rest is carried")
    func neverOverwrite() async throws {
        let s = try await HeldBackScene.make("conflict"); defer { s.cleanup() }
        let record = try s.liveRecord()
        record.userDate = "1980"
        record.userDateConfidence = UserDateConfidence.estimated.rawValue
        #expect(s.model.saveCatalogNow())
        let offer = try s.offer(Self.old, onto: record)
        #expect(offer.fields.date == .conflict(old: "1992-06", live: "1980"))
        #expect(await s.carryNow([offer.id]) == .carried(carried: 1, closed: 1, skipped: 0))
        #expect(record.userDate == "1980")
        #expect(record.mediaDisposition == .important)
        #expect(try await s.scene.reloaded(.healthy).userDate == "1980")
    }

    @Test("WRITER: an edit inside the debounce window is seen at the carry and never overwritten")
    func editInsideDebounce() async throws {
        let s = try await HeldBackScene.make("debounce"); defer { s.cleanup() }
        let record = try s.liveRecord()
        let offer = try s.offer(Self.old, onto: record)
        #expect(offer.fields.place == .carry("Cape Cod"), "when the job proved it, the place was empty")
        record.userPlace = "Boston"                           // Rick types a place; the 2 s timer is pending
        record.userPlaceConfidence = UserPlaceConfidence.known.rawValue
        s.model.saveCatalogDebounced()
        #expect(await s.carryNow([offer.id]) == .carried(carried: 1, closed: 1, skipped: 0))
        #expect(record.userPlace == "Boston")
        #expect(try await s.scene.reloaded(.healthy).userPlace == "Boston", "his edit was committed with the carry, not replaced")
    }

    @Test("WRITER: refused during a write hold — nothing changes, the row stays open")
    func duringHold() async throws {
        let s = try await HeldBackScene.make("hold"); defer { s.cleanup() }
        let record = try s.liveRecord()
        let offer = try s.offer(Self.old, onto: record)
        let open = try await s.openCountInDatabase()
        #expect(await s.model.catalogStore.holdWrites(reason: "a test job", owner: CatalogWriteHoldOwner()) == .taken)
        let outcome = await s.carryNow([offer.id])
        _ = s.model.catalogStore.releaseWriteHold()
        guard case .refused(let why) = outcome else { Issue.record("expected refused, got \(outcome)"); return }
        #expect(why.contains("held"), Comment(rawValue: why))
        #expect(record.mediaDisposition == .unreviewed)
        #expect(record.userDate == nil)
        #expect(try await s.openCountInDatabase() == open)
    }

    @Test("WRITER: refused after a role flip to viewer — nothing changes")
    func acrossRoleFlip() async throws {
        let s = try await HeldBackScene.make("role"); defer { s.cleanup() }
        let record = try s.liveRecord()
        let offer = try s.offer(Self.old, onto: record)
        let generation = try await s.generation()
        s.model.applyReadOnlyMode(true)
        guard case .refused(let why) = await s.carryNow([offer.id]) else { Issue.record("expected refused"); return }
        #expect(why.contains("read-only"), Comment(rawValue: why))
        #expect(record.mediaDisposition == .unreviewed)
        #expect(try await s.generation() == generation)
    }

    @Test("WRITER: an archived live file keeps its date (Update… only); the tag still carries")
    func archivedKeepsDate() async throws {
        let s = try await HeldBackScene.make("archived"); defer { s.cleanup() }
        let record = try s.liveRecord()
        record.lifecycleStage = .archived
        #expect(s.model.saveCatalogNow())
        let offer = try s.offer(Self.old, onto: record)
        #expect(offer.fields.date == .archived("1992-06"))
        #expect(await s.carryNow([offer.id]) == .carried(carried: 1, closed: 1, skipped: 0))
        #expect(record.userDate == nil)
        #expect(record.mediaDisposition == .important)
    }

    @Test("WRITER: a live file that changed since it was proven is skipped — nothing written, the row stays open")
    func changedFileSkipped() async throws {
        let s = try await HeldBackScene.make("changed"); defer { s.cleanup() }
        let record = try s.liveRecord()
        let offer = try s.offer(Self.old, onto: record)
        let open = try await s.openCountInDatabase()
        try Data(repeating: 6, count: 2_000).write(to: URL(fileURLWithPath: record.fullPath))
        #expect(await s.carryNow([offer.id]) == .carried(carried: 0, closed: 0, skipped: 1))
        #expect(s.store.lastCarryLines.first?.contains("changed") == true)
        #expect(record.mediaDisposition == .unreviewed)
        #expect(try await s.openCountInDatabase() == open)
    }

    @Test("ISOLATION: poisoned raw_row text in the real table is listed as unreadable and never planned")
    func poisonedRowInTheTable() async throws {
        let s = try await HeldBackScene.make("poison"); defer { s.cleanup() }
        let committer = try #require(s.model.catalogCutover.committer)
        let run = CatalogRow.ImportRun(runID: "R-poison", startedAt: 1_700_000_000, sourceSHA256: String(repeating: "d", count: 64),
                                       sourceGeneration: 5, integrityRunID: "IR-1", auditRunStartedAt: 1_699_990_000,
                                       auditRunFinishedAt: 1_699_990_500, auditGeneration: 5, integrityStartedAt: 1_699_995_000,
                                       integrityGeneration: 5)
        let record = try s.liveRecord()
        let outcome = committer.repository.writeBlocking(as: .importRun) { tx in
            try tx.insertImportRun(run)
            _ = try tx.insertQuarantine(CatalogRow.Quarantine(
                importRun: "R-poison", sourceOrdinal: 0, jsonRowID: "00000000-0000-4000-8000-00000000D00D",
                fullPath: "/Volumes/Invented/old/\(record.filename)", sizeBytes: record.sizeBytes, digest: nil, evidenceDigests: [],
                sampledHash: nil, reasonCode: .removedNoDigest, words: "invented",
                findings: [], rawRow: ["id": .string("00000000-0000-4000-8000-00000000D00D"), "mediaDisposition": .array([.int(1)]),
                                       "userDate": .object(["y": .int(1992)])], quarantinedAt: 1_700_000_000))
        }
        guard case .committed = outcome else { Issue.record("seed: \(outcome)"); return }
        await s.store.loadList()
        let entry = try #require(s.store.entries.first { $0.fullPath.hasPrefix("/Volumes/Invented/old/") })
        #expect(entry.curatedRead?.problems.count == 2)
        #expect(HeldBackWords.curated(entry.curated).contains("unreadable"))
        #expect(entry.whereNow.group == .goneLikelyMoved)
        #expect(!s.store.jobPlan().tasks.contains { $0.entry.qid == entry.qid }, "nothing usable to carry — never planned")
    }
}
