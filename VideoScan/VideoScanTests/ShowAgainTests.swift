// ShowAgainTests.swift
// "Show these files again" (Rick 2026-10-11) — the one-time repair of the
// false `.manuallyDeleted` label. Dimensions (CLAUDE.md feature checklist):
//   LOGIC     — the criteria truth table (receipt, catalog size, drive,
//               missing, not a file, unreadable, size changed, pass) and the
//               candidate rule (label + active); the receipt index (id, path,
//               damaged line).
//   END TO END — a sandbox catalog with real files: exactly the right record
//               changes, only its label changes, the snapshot and receipt are
//               written first, the save lands, catalog.log has one line per
//               file, and "Put the labels back" reverses exactly that. Since
//               2026-10-14: a row hidden by the GH #143 migration's legacy
//               marker is shown again through the engine's Restore, lands in
//               Cleanup's inputs, and the reverse puts the marker back too.
//   ISOLATION — a poisoned (unreadable) ledger refuses everything; a damaged
//               ledger line naming a file keeps it labelled; a model on the
//               SHARED store (the real App Support catalog) refuses — no
//               snapshot can be taken there from a test host, so nothing
//               changes.
//   SENSOR    — the media files are byte-, inode- and mtime-identical after a
//               run and its reverse; the repair's source has no file-moving,
//               -removing or -writing call on a media path
//               (ShowAgainSensorTests, below).
// Scale (100k) is ShowAgainScaleTests; Delete Duplicates after the repair is
// ShowAgainDeleteDuplicatesTests.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - Fixture

@MainActor
struct ShowAgainSandbox {
    let root: URL
    let model: VideoScanModel
    var files: URL { root.appendingPathComponent("files", isDirectory: true) }
    var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    var catalogDir: URL { root.appendingPathComponent("catalog", isDirectory: true) }

    static func make(_ label: String) throws -> ShowAgainSandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_showagain_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        let files = root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let model = VideoScanModel(logDirectory: root.appendingPathComponent("logs", isDirectory: true))
        model.catalogStore = CatalogStore(directory: root.appendingPathComponent("catalog", isDirectory: true))
        model.mediaLedger = MediaLedger(directory: root.appendingPathComponent("ledger", isDirectory: true))
        return ShowAgainSandbox(root: root, model: model)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    /// A record for a file written with `bytes` bytes (or not written when
    /// `onDisk` is false), labelled deleted unless told otherwise.
    @discardableResult
    func record(_ name: String, bytes: Int, onDisk: Bool = true,
                stage: ArchiveStage = .manuallyDeleted) throws -> VideoRecord {
        let url = files.appendingPathComponent(name)
        if onDisk { try Data((0..<bytes).map { UInt8(($0 &* 31 &+ name.count) % 251) }).write(to: url) }
        let r = VideoRecord()
        r.fullPath = url.path
        r.filename = name
        r.directory = files.path
        r.sizeBytes = Int64(bytes)
        r.archiveStage = stage
        r.userNotes = "Rick's note on \(name)"
        r.starRating = 2
        model.records.append(r)
        return r
    }

    static let onlineRealStat = ShowAgainDisk(volumeOnline: { _ in true }, stat: ShowAgainDisk.statPath)

    func catalogLogText() -> String {
        (try? String(contentsOf: logs.appendingPathComponent("catalog.log"), encoding: .utf8)) ?? ""
    }
}

/// What must not change on a file: its bytes, its inode, its mtime.
struct MediaFingerprint: Equatable {
    let bytes: Data
    let inode: UInt64
    let mtime: Date

    static func of(_ path: String) throws -> MediaFingerprint {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return MediaFingerprint(bytes: try Data(contentsOf: URL(fileURLWithPath: path)),
                                inode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                                mtime: attrs[.modificationDate] as? Date ?? .distantPast)
    }
}

// MARK: - Logic

@Suite("Show again — the criteria")
struct ShowAgainRulesTests {

    private let c = ShowAgainCandidate(id: UUID(), filename: "a.mov", fullPath: "/Volumes/LaCie/a.mov",
                                       volumeName: "LaCie", sizeBytes: 1_000)

    private func facts(receipt: Bool = false, online: Bool = true, disk: ShowAgainOnDisk = .file(size: 1_000)) -> ShowAgainFacts {
        ShowAgainFacts(hasRemovalReceipt: receipt, volumeOnline: online, onDisk: disk)
    }

    @Test("truth table: only an on-disk file at the catalog's size with no receipt is shown again")
    func truthTable() {
        #expect(ShowAgainRules.verdict(c, facts()) == .showAgain)
        #expect(ShowAgainRules.verdict(c, facts(disk: .missing)) == .stays(.fileMissing))
        #expect(ShowAgainRules.verdict(c, facts(disk: .file(size: 999))) == .stays(.sizeChanged))
        #expect(ShowAgainRules.verdict(c, facts(disk: .file(size: 1_001))) == .stays(.sizeChanged))
        #expect(ShowAgainRules.verdict(c, facts(receipt: true)) == .stays(.hasRemovalReceipt))
        #expect(ShowAgainRules.verdict(c, facts(online: false)) == .stays(.driveNotConnected))
        #expect(ShowAgainRules.verdict(c, facts(disk: .notAFile)) == .stays(.notAFile))
        #expect(ShowAgainRules.verdict(c, facts(disk: .unreadable(errno: EACCES))) == .stays(.couldNotCheck))
        let zero = ShowAgainCandidate(id: UUID(), filename: "z", fullPath: "/z", volumeName: "", sizeBytes: 0)
        #expect(ShowAgainRules.verdict(zero, facts(disk: .file(size: 0))) == .stays(.noCatalogSize),
                "0 == 0 is not proof of anything")
        // A receipt outranks everything — even a file that is back.
        #expect(ShowAgainRules.verdict(c, facts(receipt: true, disk: .file(size: 1_000))) == .stays(.hasRemovalReceipt))
    }

    @Test("candidates: labelled deleted AND active — purged, set aside, superseded or unlabelled are not")
    @MainActor
    func candidateRule() {
        func rec(_ stage: ArchiveStage) -> VideoRecord { let r = VideoRecord(); r.archiveStage = stage; return r }
        #expect(ShowAgainRules.isCandidate(rec(.manuallyDeleted)))
        for stage in ArchiveStage.allCases where stage != .manuallyDeleted {
            #expect(!ShowAgainRules.isCandidate(rec(stage)), "\(stage)")
        }
        let purged = rec(.manuallyDeleted); purged.purgedAt = Date()
        let aside = rec(.manuallyDeleted); aside.setAsideReason = "tidy"
        let superseded = rec(.manuallyDeleted); superseded.supersededByID = UUID()
        for r in [purged, aside, superseded] { #expect(!ShowAgainRules.isCandidate(r)) }
    }

    @Test("candidates, both encodings of the old label (GH #143 migration): the legacy marker is ours; any real removal marker is not")
    @MainActor
    func candidateRuleWithTheLegacyMarker() {
        let d = Date(timeIntervalSince1970: 1_760_000_000)
        func rec(_ stage: ArchiveStage, _ marker: RemovalMarker?) -> VideoRecord {
            let r = VideoRecord()
            r.archiveStage = stage
            if let marker { VideoScanModel.stampRemoval(r, marker) }
            return r
        }
        let legacy = RemovalMarker.removedFromCatalog(at: d, reason: .legacyDeletedLabel)
        #expect(ShowAgainRules.isCandidate(rec(.manuallyDeleted, legacy)),
                "label + the load migration's marker — Rick's 993 rows")
        #expect(ShowAgainRules.isCandidate(rec(.none, legacy)), "marker only")
        #expect(!ShowAgainRules.isCandidate(rec(.manuallyDeleted, .inTrash(movedAt: d, trashPath: nil, reason: .junk))),
                "in the Trash: a real removal")
        #expect(!ShowAgainRules.isCandidate(rec(.manuallyDeleted, .removedFromCatalog(at: d, reason: .userRemoved))),
                "Remove from Catalog: a real removal")
        #expect(!ShowAgainRules.isCandidate(rec(.manuallyDeleted, .missing(noticedAt: d, lastSeen: nil, reason: .missingOnDisk))),
                "missing: a real removal")
        #expect(!ShowAgainRules.isCandidate(rec(.none, .removedFromCatalog(at: d, reason: .legacyPurged))),
                "a legacy purgedAt: a real removal")
        let aside = rec(.manuallyDeleted, legacy); aside.setAsideReason = "tidy"
        let superseded = rec(.manuallyDeleted, legacy); superseded.supersededByID = UUID()
        #expect(!ShowAgainRules.isCandidate(aside) && !ShowAgainRules.isCandidate(superseded))
    }

    @Test("receipts: copyTrashed / copyDeleted by id or path count; other events do not; a damaged removal line naming the file counts")
    func receiptIndex() throws {
        let other = ShowAgainCandidate(id: UUID(), filename: "b.mov", fullPath: "/Volumes/LaCie/b.mov", volumeName: "LaCie", sizeBytes: 5)
        let byID = MediaLedgerEvent(event: .copyTrashed, recordID: c.id, contentKey: "", filename: "x", fullPath: "/elsewhere", by: .rick)
        let byPath = MediaLedgerEvent(event: .copyDeleted, recordID: UUID(), contentKey: "", filename: "b.mov", fullPath: other.fullPath, by: .rick)
        let notRemoval = MediaLedgerEvent(event: .setAside, recordID: UUID(), contentKey: "", filename: "q", fullPath: "/Volumes/LaCie/q.mov", by: .rick)
        let text = try #require(String(bytes: try MediaLedgerEvent.encodeLines([byID, byPath, notRemoval]), encoding: .utf8))
        let index = ShowAgainReceipts.index(ledgerText: text)
        #expect(index.covers(c), "receipt by record id")
        #expect(index.covers(other), "receipt by path")
        let q = ShowAgainCandidate(id: notRemoval.recordID, filename: "q", fullPath: "/Volumes/LaCie/q.mov", volumeName: "", sizeBytes: 1)
        #expect(!index.covers(q), "a set-aside line is not a Trash receipt")

        let fresh = ShowAgainCandidate(id: UUID(), filename: "c.mov", fullPath: "/Volumes/LaCie/c.mov", volumeName: "", sizeBytes: 1)
        let damaged = ShowAgainReceipts.index(ledgerText: "{\"event\":\"copyTrashed\",\"fullPath\":\"/Volumes/LaCie/c.mov\",\"reco")
        #expect(damaged.covers(fresh), "a cut-off removal line naming the path is treated as a receipt")
        #expect(!damaged.covers(c))
    }

    @Test("ledger: no file = no receipts; a file that can't be read refuses")
    func ledgerRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("showagain_ledger_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("media-ledger.jsonl")
        #expect((try? ShowAgainReceipts.read(ledgerURL: missing).get()) == ShowAgainReceipts())
        // Poisoned: a directory where the ledger file should be.
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        guard case .failure = ShowAgainReceipts.read(ledgerURL: missing) else {
            Issue.record("an unreadable ledger must refuse, never read as 'no receipts'")
            return
        }
    }
}

// MARK: - End to end

@Suite("Show again — the run", .serialized)
@MainActor
struct ShowAgainApplyTests {

    @Test("shows exactly the on-disk, right-size, unreceipted file; only its label changes; snapshot + receipt + save + log; reverse puts it back")
    func endToEnd() async throws {
        let sb = try ShowAgainSandbox.make("e2e"); defer { sb.cleanup() }
        let shown = try sb.record("Christmas_1997_clip1.dv", bytes: 4_096)
        let missing = try sb.record("gone.mov", bytes: 2_000, onDisk: false)
        let resized = try sb.record("resized.mov", bytes: 3_000)
        resized.sizeBytes = 2_999                                   // catalog says otherwise
        let trashed = try sb.record("trashed.mov", bytes: 1_500)
        let live = try sb.record("live.mov", bytes: 1_200, stage: .none)
        let wrote = await sb.model.mediaLedger.appendConfirmed([
            sb.model.ledgerEvent(.copyTrashed, for: trashed, by: .rick)])
        try #require(wrote, "fixture: the Trash receipt is in the sandbox ledger")
        let before = shown.snapshotClone()
        let fingerprints = try [shown, resized, trashed, live].map { try MediaFingerprint.of($0.fullPath) }

        let reviewed = await sb.model.showAgainReview(disk: ShowAgainSandbox.onlineRealStat)
        #expect(reviewed.showCount == 1 && reviewed.toShow.first?.id == shown.id, "\(reviewed.items)")
        #expect(reviewed.headline == "1 file, \(MediaBytes.display(4_096)) will be shown again")
        #expect(Set(reviewed.staying.map(\.id)) == [missing.id, resized.id, trashed.id])
        #expect(shown.archiveStage == .manuallyDeleted, "the review is a dry run")

        let result = await sb.model.applyShowAgain(reviewed: reviewed, disk: ShowAgainSandbox.onlineRealStat)

        #expect(result.outcome == .shown, "\(result.outcome)")
        #expect(result.shown.map(\.id) == [shown.id])
        #expect(shown.archiveStage == .none)
        #expect(missing.archiveStage == .manuallyDeleted, "file missing → stays labelled")
        #expect(resized.archiveStage == .manuallyDeleted, "size changed → stays labelled")
        #expect(trashed.archiveStage == .manuallyDeleted, "Trash receipt → stays labelled")
        #expect(live.archiveStage == .none)
        // Label only: every other field is what it was.
        let after = shown.snapshotClone()
        after.archiveStage = before.archiveStage
        #expect(after.userNotes == before.userNotes && after.notes == before.notes
                && after.starRating == before.starRating && after.lifecycleStage == before.lifecycleStage
                && after.fullPath == before.fullPath && after.sizeBytes == before.sizeBytes
                && after.tags == before.tags && after.userDate == before.userDate)
        // Media untouched (runtime sensor).
        #expect(try [shown, resized, trashed, live].map { try MediaFingerprint.of($0.fullPath) } == fingerprints)

        // The safety snapshot holds the OLD label; the receipt lists exactly the change.
        let snapPath = try #require(result.snapshotPath)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let snap = try dec.decode(CatalogSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: snapPath)))
        #expect(snap.records.first { $0.id == shown.id }?.archiveStage == .manuallyDeleted)
        let receiptURL = try #require(result.receiptURL)
        #expect(receiptURL.path.hasPrefix(sb.catalogDir.path), "receipts live beside the catalog, never in the repo")
        let receipt = try ShowAgainReceiptFile.decode(Data(contentsOf: receiptURL))
        #expect(receipt.changes == [.init(id: shown.id, path: shown.fullPath, from: "Manually Deleted", to: "None")])
        #expect(receipt.snapshotPath == snapPath)
        // Saved through the normal path: the catalog on disk agrees.
        let saved = try dec.decode(CatalogSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: sb.model.catalogStore.fileLocation)))
        #expect(saved.records.first { $0.id == shown.id }?.archiveStage == ArchiveStage.none)
        // One per-file line, START and OUTCOME in catalog.log.
        let log = sb.catalogLogText()
        #expect(log.contains("[show-again] shown again: \(shown.fullPath) id=\(shown.id.uuidString)"), "\(log)")
        #expect(log.contains("[show-again] left labelled: \(missing.fullPath)"))
        #expect(log.contains("Show again: START") && log.contains("Show again: OUTCOME — 1 shown again"))

        // Reverse: exactly that record goes back; a second reverse changes nothing.
        let rev = await sb.model.reverseShowAgain(receiptURL: receiptURL)
        #expect(rev.restored == 1 && rev.skipped.isEmpty && rev.refusal == nil, "\(rev)")
        #expect(shown.archiveStage == .manuallyDeleted)
        let again = await sb.model.reverseShowAgain(receiptURL: receiptURL)
        #expect(again.restored == 0 && again.skipped == [shown.fullPath])
        #expect(try [shown, resized, trashed, live].map { try MediaFingerprint.of($0.fullPath) } == fingerprints,
                "the reverse never touches media either")
    }

    @Test("THE goal (2026-10-14): a row hidden by the load migration's legacy marker is shown again — marker cleared, live, back in Cleanup's inputs; the log says the marker went")
    func legacyMarkerRowShownAgain() async throws {
        let sb = try ShowAgainSandbox.make("legacy"); defer { sb.cleanup() }
        let since = Date(timeIntervalSince1970: 1_760_300_000)
        let hidden = try sb.record("Thanksgiving_1994.dv", bytes: 4_096)
        VideoScanModel.stampRemoval(hidden, .removedFromCatalog(at: since, reason: .legacyDeletedLabel))
        let trashed = try sb.record("in_trash.mov", bytes: 2_048)
        VideoScanModel.stampRemoval(trashed, .inTrash(movedAt: since, trashPath: nil, reason: .junk))
        let live = try sb.record("live.mov", bytes: 1_200, stage: .none)
        let stageBefore = hidden.lifecycleStage
        #expect(hidden.isPurged, "fixture: the marker hides the row, as on Rick's catalog")
        #expect(!sb.model.cleanupInputs().rows.contains { $0.id == hidden.id }, "fixture: Cleanup cannot see it")

        let reviewed = await sb.model.showAgainReview(disk: ShowAgainSandbox.onlineRealStat)
        #expect(reviewed.toShow.map(\.id) == [hidden.id], "\(reviewed.items)")
        let result = await sb.model.applyShowAgain(reviewed: reviewed, disk: ShowAgainSandbox.onlineRealStat)
        #expect(result.outcome == .shown, "\(result.outcome)")
        #expect(hidden.removal == nil && !hidden.isPurged && hidden.archiveStage == .none)
        #expect(hidden.lifecycleStage == stageBefore, "not a trashed row: the lifecycle stage is left alone")
        #expect(trashed.removal?.state == .inTrash && trashed.archiveStage == .manuallyDeleted, "a real removal is never touched")
        #expect(live.archiveStage == .none && live.removal == nil)
        #expect(sb.model.cleanupInputs().rows.contains { $0.id == hidden.id }, "Cleanup can see it now")
        let log = sb.catalogLogText()
        #expect(log.contains("[show-again] shown again: \(hidden.fullPath)") && log.contains("removal marker"), "\(log)")
        // Saved through the normal path: the catalog on disk carries no marker for it.
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let saved = try dec.decode(CatalogSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: sb.model.catalogStore.fileLocation)))
        let row = try #require(saved.records.first { $0.id == hidden.id })
        #expect(row.removal == nil && row.purgedAt == nil && row.archiveStage == ArchiveStage.none)
    }

    @Test("put back restores BOTH the legacy marker (same since) and the label; the receipt names the marker; label-only rows get the label only")
    func reversePutsTheMarkerBack() async throws {
        let sb = try ShowAgainSandbox.make("legacyreverse"); defer { sb.cleanup() }
        let since = Date(timeIntervalSince1970: 1_760_300_000)
        let hidden = try sb.record("Easter_1992.dv", bytes: 3_072)
        VideoScanModel.stampRemoval(hidden, .removedFromCatalog(at: since, reason: .legacyDeletedLabel))
        let labelOnly = try sb.record("label_only.mov", bytes: 2_048)
        let reviewed = await sb.model.showAgainReview(disk: ShowAgainSandbox.onlineRealStat)
        let result = await sb.model.applyShowAgain(reviewed: reviewed, disk: ShowAgainSandbox.onlineRealStat)
        #expect(result.outcome == .shown && Set(result.shown.map(\.id)) == [hidden.id, labelOnly.id], "\(result)")
        let receiptURL = try #require(result.receiptURL)
        let receipt = try ShowAgainReceiptFile.decode(Data(contentsOf: receiptURL))
        #expect(receipt.changes.first { $0.id == hidden.id }?.removalSince == since)
        #expect(receipt.changes.first { $0.id == labelOnly.id }?.removalSince == nil)
        #expect((String(data: try Data(contentsOf: receiptURL), encoding: .utf8) ?? "").contains("\"removalSince\""))
        #expect(hidden.removal == nil && labelOnly.removal == nil)

        let rev = await sb.model.reverseShowAgain(receiptURL: receiptURL)
        #expect(rev.restored == 2 && rev.skipped.isEmpty && rev.refusal == nil, "\(rev)")
        #expect(hidden.archiveStage == .manuallyDeleted)
        #expect(hidden.removal == .removedFromCatalog(at: since, reason: .legacyDeletedLabel), "\(String(describing: hidden.removal))")
        #expect(hidden.isPurged, "hidden again, exactly as the migration left it")
        #expect(labelOnly.archiveStage == .manuallyDeleted && labelOnly.removal == nil)
        let log = sb.catalogLogText()
        #expect(log.contains("label put back: \(hidden.fullPath) id=\(hidden.id.uuidString) — None → Manually Deleted; removal marker (old deleted label) put back"), "\(log)")
        #expect(log.contains("label put back: \(labelOnly.fullPath) id=\(labelOnly.id.uuidString) — None → Manually Deleted\n"), "\(log)")
        // Both are candidates again: a second review offers them.
        let again = await sb.model.showAgainReview(disk: ShowAgainSandbox.onlineRealStat)
        #expect(Set(again.toShow.map(\.id)) == [hidden.id, labelOnly.id])
    }

    @Test("a receipt from the 2026-10-11 build (no removalSince key) still decodes and reverses the label only")
    func oldReceiptShapeReversesLabelOnly() async throws {
        let sb = try ShowAgainSandbox.make("oldreceipt"); defer { sb.cleanup() }
        let shown = try sb.record("old.mov", bytes: 1_024, stage: .none)
        let json = """
        {"changes":[{"from":"Manually Deleted","id":"\(shown.id.uuidString)","path":"\(shown.fullPath)","to":"None"}],"runID":"show-again-old","snapshotPath":"/nowhere","writtenAt":"2026-10-11T12:00:00Z"}
        """
        let file = try ShowAgainReceiptFile.decode(Data(json.utf8))
        #expect(file.changes == [.init(id: shown.id, path: shown.fullPath, from: "Manually Deleted", to: "None")])
        #expect(file.changes.first?.removalSince == nil)
        let dir = sb.model.showAgainReceiptsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("show-again-old.json")
        try Data(json.utf8).write(to: url)
        let rev = await sb.model.reverseShowAgain(receiptURL: url)
        #expect(rev.restored == 1 && rev.skipped.isEmpty, "\(rev)")
        #expect(shown.archiveStage == .manuallyDeleted && shown.removal == nil && !shown.isPurged)
    }

    @Test("put back never re-hides a file that has since become its group's surviving keeper, nor relabels a removed row")
    func reverseLeavesASurvivingKeeperVisible() async throws {
        let sb = try ShowAgainSandbox.make("reverse_keeper"); defer { sb.cleanup() }
        let keeper = try sb.record("keeper.mov", bytes: 900)
        let extra = try sb.record("extra.mov", bytes: 900)
        let removed = try sb.record("removed.mov", bytes: 901)
        let reviewed = await sb.model.showAgainReview(disk: ShowAgainSandbox.onlineRealStat)
        let run = await sb.model.applyShowAgain(reviewed: reviewed, disk: ShowAgainSandbox.onlineRealStat)
        let receipt = try #require(run.receiptURL)
        try #require(run.shown.count == 3)
        // After the run: keeper + extra became a duplicate group; the extra
        // was purged (trashed); another shown file was removed from the catalog.
        let group = UUID()
        keeper.duplicateGroupID = group; keeper.duplicateDisposition = .keep
        extra.duplicateGroupID = group; extra.duplicateDisposition = .extraCopy
        extra.purgedAt = Date()
        removed.purgedAt = Date()

        let rev = await sb.model.reverseShowAgain(receiptURL: receipt)

        #expect(keeper.archiveStage == .none, "the surviving keeper was hidden again")
        #expect(extra.archiveStage == .none, "a purged row was relabelled")
        #expect(removed.archiveStage == .none, "a purged row was relabelled")
        #expect(rev.restored == 0 && rev.skipped.count == 3, "\(rev)")
        let log = sb.catalogLogText()
        #expect(log.contains("label NOT put back: \(keeper.fullPath)") && log.contains("surviving copy"), "\(log)")
        #expect(log.contains("label NOT put back: \(extra.fullPath)") && log.contains("removed from the catalog"))
    }

    @Test("put back holds a file that is now the only active member of its duplicate group, whatever its disposition")
    func reverseHoldsTheSoleGroupMemberAnyDisposition() async throws {
        let sb = try ShowAgainSandbox.make("reverse_sole"); defer { sb.cleanup() }
        let a = try sb.record("a.mov", bytes: 700)
        let b = try sb.record("b.mov", bytes: 701)
        let reviewed = await sb.model.showAgainReview(disk: ShowAgainSandbox.onlineRealStat)
        let run = await sb.model.applyShowAgain(reviewed: reviewed, disk: ShowAgainSandbox.onlineRealStat)
        let receipt = try #require(run.receiptURL)
        // a is marked an extra copy, but its keeper left the catalog after the run.
        let group = UUID()
        a.duplicateGroupID = group; a.duplicateDisposition = .extraCopy
        let rev = await sb.model.reverseShowAgain(receiptURL: receipt)
        #expect(a.archiveStage == .none, "the group's last active copy was hidden again")
        #expect(b.archiveStage == .manuallyDeleted, "an ordinary file is put back")
        #expect(rev.restored == 1 && rev.skipped == [a.fullPath], "\(rev)")
    }

    @Test("a record changed between the review and the run stays as it is")
    func changedSinceReview() async throws {
        let sb = try ShowAgainSandbox.make("changed"); defer { sb.cleanup() }
        let a = try sb.record("a.mov", bytes: 900)
        let b = try sb.record("b.mov", bytes: 901)
        let reviewed = await sb.model.showAgainReview(disk: ShowAgainSandbox.onlineRealStat)
        #expect(reviewed.showCount == 2)
        b.archiveStage = .backedUp                      // Rick changed it meanwhile
        let result = await sb.model.applyShowAgain(reviewed: reviewed, disk: ShowAgainSandbox.onlineRealStat)
        #expect(result.shown.map(\.id) == [a.id])
        #expect(b.archiveStage == .backedUp, "never overwritten")
        #expect(result.stayed.contains { $0.candidate.id == b.id && $0.reason == .changedSinceReview })
    }

    @Test("a file deleted between the review and the run stays labelled (checked again at the run)")
    func fileGoneSinceReview() async throws {
        let sb = try ShowAgainSandbox.make("gone"); defer { sb.cleanup() }
        let a = try sb.record("a.mov", bytes: 700)
        let reviewed = await sb.model.showAgainReview(disk: ShowAgainSandbox.onlineRealStat)
        try FileManager.default.removeItem(atPath: a.fullPath)
        let result = await sb.model.applyShowAgain(reviewed: reviewed, disk: ShowAgainSandbox.onlineRealStat)
        #expect(result.outcome == .nothingToDo)
        #expect(a.archiveStage == .manuallyDeleted)
        #expect(result.receiptURL == nil, "nothing changed, so no change list")
    }

    // MARK: Isolation (poisoned state)

    @Test("POISONED ledger (unreadable): the run refuses and nothing changes")
    func poisonedLedgerRefuses() async throws {
        let sb = try ShowAgainSandbox.make("poison"); defer { sb.cleanup() }
        let a = try sb.record("a.mov", bytes: 800)
        let reviewed = await sb.model.showAgainReview(disk: ShowAgainSandbox.onlineRealStat)
        #expect(reviewed.showCount == 1)
        try FileManager.default.createDirectory(at: sb.model.mediaLedger.fileURL, withIntermediateDirectories: true)
        let result = await sb.model.applyShowAgain(reviewed: reviewed, disk: ShowAgainSandbox.onlineRealStat)
        guard case .refused = result.outcome else { Issue.record("\(result.outcome)"); return }
        #expect(a.archiveStage == .manuallyDeleted)
        let review = await sb.model.showAgainReview(disk: ShowAgainSandbox.onlineRealStat)
        #expect(review.refusal != nil && review.showCount == 0, "the review says so too")
    }

    @Test("DAMAGED ledger line naming the file: it stays labelled; the rest still go")
    func damagedLedgerLineHolds() async throws {
        let sb = try ShowAgainSandbox.make("damaged"); defer { sb.cleanup() }
        let a = try sb.record("a.mov", bytes: 800)
        let b = try sb.record("b.mov", bytes: 801)
        try FileManager.default.createDirectory(at: sb.model.mediaLedger.directory, withIntermediateDirectories: true)
        try "{\"event\":\"copyTrashed\",\"fullPath\":\"\(a.fullPath)\",\"recordI\n".write(to: sb.model.mediaLedger.fileURL,
                                                                                         atomically: true, encoding: .utf8)
        let reviewed = await sb.model.showAgainReview(disk: ShowAgainSandbox.onlineRealStat)
        let result = await sb.model.applyShowAgain(reviewed: reviewed, disk: ShowAgainSandbox.onlineRealStat)
        #expect(result.shown.map(\.id) == [b.id])
        #expect(a.archiveStage == .manuallyDeleted)
    }

    @Test("a model on the SHARED store (the real catalog) refuses: no safety copy from a test host, no change")
    func sharedStoreRefuses() async throws {
        let sb = try ShowAgainSandbox.make("shared"); defer { sb.cleanup() }
        let a = try sb.record("a.mov", bytes: 600)
        sb.model.catalogStore = CatalogStore.shared
        let reviewed = await sb.model.showAgainReview(disk: ShowAgainSandbox.onlineRealStat)
        let result = await sb.model.applyShowAgain(reviewed: reviewed, disk: ShowAgainSandbox.onlineRealStat)
        guard case .refused(let why) = result.outcome else { Issue.record("\(result.outcome)"); return }
        #expect(why.contains("safety copy"))
        #expect(a.archiveStage == .manuallyDeleted)
    }

    @Test("an empty review refuses; nothing offered → nothing changes")
    func emptyReviewRefuses() async throws {
        let sb = try ShowAgainSandbox.make("empty"); defer { sb.cleanup() }
        try sb.record("gone.mov", bytes: 10, onDisk: false)
        let reviewed = await sb.model.showAgainReview(disk: ShowAgainSandbox.onlineRealStat)
        #expect(reviewed.showCount == 0 && reviewed.stayCounts.first?.reason == .fileMissing)
        let result = await sb.model.applyShowAgain(reviewed: reviewed, disk: ShowAgainSandbox.onlineRealStat)
        guard case .refused = result.outcome else { Issue.record("\(result.outcome)"); return }
    }

    @Test("the MFO job runs the reviewed plan to a finished row with the one-line summary")
    func jobFinishes() async throws {
        let sb = try ShowAgainSandbox.make("job"); defer { sb.cleanup() }
        let a = try sb.record("a.mov", bytes: 500)
        try sb.record("gone.mov", bytes: 10, onDisk: false)
        let reviewed = await sb.model.showAgainReview(disk: ShowAgainSandbox.onlineRealStat)
        let job = ShowAgainJob(model: sb.model, reviewed: reviewed)
        job.disk = ShowAgainSandbox.onlineRealStat
        job.start()
        await job.task?.value
        #expect(job.state == .finished(summary: "1 shown again (\(MediaBytes.display(500))) · 1 left labelled"), "\(job.state)")
        #expect(a.archiveStage == .none)
        #expect(job.canReverse)
        #expect(MediaFileOperationKind.showAgain.hasDetailView)
    }
}

// MARK: - Sensor: the repair never touches media

@Suite("Show again — sensor: label only, never a file operation on media")
struct ShowAgainSensorTests {

    static let files = ["ShowAgain.swift", "ShowAgain+Apply.swift", "ShowAgainJob.swift", "ShowAgainReview.swift"]

    /// Calls that move, remove, rename, copy, truncate, lock or open a file
    /// for writing. None may appear in the repair's sources.
    static let forbidden = [
        "trashItem", "removeItem", "moveItem", "copyItem", "replaceItem", "linkItem",
        "unlink(", "rename(", "renamex", "renameat", "chflags", "truncate(", "ftruncate",
        "FileHandle(forWriting", "FileHandle(forUpdating", "O_WRONLY", "O_RDWR", "open(",
        "setAttributes", "deleteConfirmedJunk", "SignatureVerification",
    ]

    @Test("no file-moving, -removing or -writing call in the repair's sources")
    func noMediaFileOperations() throws {
        for name in Self.files {
            let src = try SourceTree.appSource(named: name)
            let code = src.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for call in Self.forbidden {
                #expect(!code.contains(call), "\(name) calls \(call)")
            }
        }
    }

    @Test("the only file the repair writes itself is its receipt, beside the catalog")
    func onlyTheReceiptIsWritten() throws {
        var writes = 0
        for name in Self.files {
            let src = try SourceTree.appSource(named: name)
            writes += src.components(separatedBy: ".write(to:").count - 1
        }
        let apply = try SourceTree.appSource(named: "ShowAgain+Apply.swift")
        #expect(writes == 1, "one write call: the receipt")
        #expect(apply.contains("try ShowAgainReceiptFile.encode(file).write(to: url, options: .atomic)"))
        #expect(apply.contains("let dir = showAgainReceiptsDirectory"))
    }

    @Test("the only assignment is the label; the marker goes through the engine (clearRemoval / stampRemoval), never a `.removal =` here")
    func onlyTheLabel() throws {
        #expect(ShowAgainRules.falseLabel == .manuallyDeleted)
        #expect(ShowAgainRules.liveLabel == .none)
        let apply = try SourceTree.appSource(named: "ShowAgain+Apply.swift")
        #expect(apply.contains("if let why = clearRemoval(rec)"), "the run clears the marker through the engine's Restore")
        #expect(apply.contains("Self.stampRemoval(rec, .removedFromCatalog(at: since, reason: .legacyDeletedLabel))"),
                "the reverse re-marks through the engine's one writer")
        for name in Self.files {
            let src = try SourceTree.appSource(named: name)
            #expect(!src.contains(".removal = ") && !src.contains(".purgedAt = "), "\(name) writes the marker itself")
        }
        // A property assignment on a record: `rec.<field> = …` (not `==`, not a binding).
        let assignment = try NSRegularExpression(pattern: #"\brec\.[A-Za-z_.]+ = "#)
        let assignments = apply.split(separator: "\n").filter {
            let line = String($0)
            return assignment.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
        #expect(!assignments.isEmpty, "the sensor must see the label assignments it pins")
        #expect(assignments.allSatisfy { $0.contains("rec.archiveStage = ShowAgainRules.") },
                "the run and its reverse assign nothing but the label: \(assignments)")
    }
}
