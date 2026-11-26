// CatalogRenameArchiveIndexTests.swift
// Renaming a promoted SOURCE in the Catalog carries through to the archive's
// index files (ArchiveIndexRename.swift): the manifest's source column and
// the journals' source paths follow. A Master Archive file itself is NOT
// renamed here (rule 3, Codex #383 — superseding Rick 2026-09-25): only
// Update… changes an archived file's name, locked or not.
//
// Dimensions (CLAUDE.md feature-test checklist):
//   LOGIC     — an archive file (promoted copy, a stray under the root, the
//               wrong volume, a Promote running) is refused with nothing
//               touched; source-path rename (5 lines in 2 files,
//               byte-identical untouched lines, ledger); substring lookalikes
//               untouched; unparseable index refuses; destination exists
//               refuses; no-reference rename unchanged; publish failure rolls
//               back; engine token rules.
//   ISOLATION — tmp-dir archive only; the ledger is a per-test folder; an
//               offline designation and a symlinked 00_Index are refused
//               or ignored without touching anything outside the fixture.
//   SCALE     — 50k-line manifest + 50k-line ledger mirror within a budget.
//
// Everything lives under FileManager.temporaryDirectory; no real volume,
// no real Application Support. Log lines are captured per task tree (`withAppLog`).

import Foundation
import Testing
@testable import VideoScan

// serialized: the SCALE test (50k-line manifest + ledger mirror) holds a wall-clock budget; siblings running beside it would spend it
@Suite("Catalog rename — carries through to the archive index", .serialized)
@MainActor
struct CatalogRenameArchiveIndexTests {

    // MARK: Fixture

    static let rel = "30_Video/1990-1999/1994/1994-xx-xx_Chrsitmas_1994_misc.mkv"
    static let newBase = "1994-xx-xx_Christmas_1994_misc"
    static var newRel: String { "30_Video/1990-1999/1994/\(newBase).mkv" }
    static let oldName = "1994-xx-xx_Chrsitmas_1994_misc.mkv"
    static let newName = "1994-xx-xx_Christmas_1994_misc.mkv"
    nonisolated static let sourceName = "Chrsitmas 1994 misc.mkv"
    static let at = Date(timeIntervalSince1970: 1_758_000_000)
    static let newSourceBase = "Christmas 1994 misc"
    nonisolated static let newSourceName = "Christmas 1994 misc.mkv"

    struct Fixture {
        let tmp: URL
        let root: String
        let index: URL
        let media: String
        let source: String
        let model: VideoScanModel
        let archiveRecord: VideoRecord
        let sourceRecord: VideoRecord

        func indexFile(_ name: String) -> URL { index.appendingPathComponent(name) }
        var backups: URL { index.appendingPathComponent(ArchiveIndexRename.backupFolder) }
        let newMedia: String
        var newSource: String { (source as NSString).deletingLastPathComponent + "/" + CatalogRenameArchiveIndexTests.newSourceName }
        func cleanup() { try? FileManager.default.removeItem(at: tmp) }
    }

    static func record(_ path: String) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.ext = (path as NSString).pathExtension.uppercased()
        r.directory = (path as NSString).deletingLastPathComponent
        return r
    }

    static func makeFixture(_ label: String, sourceName: String = CatalogRenameArchiveIndexTests.sourceName,
                            volumeUUID: String? = nil) throws -> Fixture {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("VideoScanRenameIndex-\(label)-\(UUID().uuidString)")
        let vol = tmp.appendingPathComponent("Vol")
        let root = vol.appendingPathComponent(MasterArchiveLayout.rootFolderName)
        let index = root.appendingPathComponent(MasterArchiveLayout.indexFolder)
        try fm.createDirectory(at: index, withIntermediateDirectories: true)
        let media = root.appendingPathComponent(rel)
        try fm.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("archive copy".utf8).write(to: media)
        let srcDir = tmp.appendingPathComponent("Source")
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let source = srcDir.appendingPathComponent(sourceName)
        try Data("source".utf8).write(to: source)

        let model = VideoScanModel()
        model.masterArchive = MasterArchiveDesignation(targetPath: vol.path, rootPath: root.path, volumeUUID: volumeUUID)
        model.mediaLedger = MediaLedger(directory: tmp.appendingPathComponent("ledger", isDirectory: true))
        let archiveRecord = record(media.path)
        let sourceRecord = record(source.path)
        // The promote link (m4: only a promoted source is looked up in the index).
        archiveRecord.derivedFrom = sourceRecord.id
        archiveRecord.derivationKind = ArchivePromotion.derivationKind
        model.records = [archiveRecord, sourceRecord]
        return Fixture(tmp: tmp, root: root.path, index: index, media: media.path, source: source.path,
                       model: model, archiveRecord: archiveRecord, sourceRecord: sourceRecord,
                       newMedia: root.appendingPathComponent(newRel).path)
    }

    /// Write the five index files. `targets: false` writes only the
    /// lookalikes (no exact match anywhere).
    static func writeIndex(_ f: Fixture, targets: Bool = true) throws {
        let root = f.root
        let otherID = UUID()
        // Manifest — header + rows. Row values: the target, a `.bak`
        // lookalike, and a longer folder name that CONTAINS the target.
        var manifest = MasterArchiveLayout.manifestHeader + "\n"
        func row(_ relPath: String, _ original: String) -> String {
            ArchiveManifestCSV.line(for: .init(promotedAt: at, archiveRelPath: relPath, sha256: "ab12",
                                               sizeBytes: 12, originalPath: original, originalVolume: "Source",
                                               recordID: UUID(), sourceRecordID: UUID(), recordDate: "1994",
                                               dateConfidence: "estimated", people: ["Donna"], starRating: 3))
        }
        if targets { manifest += row(rel, f.source) }
        manifest += row(rel + ".bak", f.source + ".bak")
        manifest += row(rel + "_extras/clip.mkv", "/elsewhere/other.mkv")
        try Data(manifest.utf8).write(to: f.indexFile(MasterArchiveLayout.manifestFilename))

        // Promote journal — the production writer (default encoder: `\/`).
        if targets {
            for state in [ArchivePromoteJournal.Entry.State.intent, .renamed, .published, .done] {
                try ArchivePromoteJournal.append(.init(sourceRecordID: f.sourceRecord.id, sourcePath: f.source,
                                                       destRelPath: rel, state: state, sha256: state == .intent ? nil : "ab12",
                                                       copyRecordID: f.archiveRecord.id, at: at), rootPath: root)
            }
        }
        try ArchivePromoteJournal.append(.init(sourceRecordID: otherID, sourcePath: f.source + ".bak",
                                               destRelPath: rel + ".bak", state: .done, at: at), rootPath: root)

        // Attestation journal — the production writer (sorted, no `\/`).
        var attest: [ArchiveAttestationJournal.Entry] = []
        if targets {
            for kind in [BackupAttestation.Kind.cloud, .offsite] {
                attest.append(.init(at: at, record: (f.archiveRecord.id, oldName, f.media),
                                    attestation: BackupAttestation(kind: kind, answer: .yes, label: "iCloud", attestedAt: at)))
            }
        }
        attest.append(.init(at: at, record: (otherID, oldName, f.media + ".bak"),
                            attestation: BackupAttestation(kind: .cloud, answer: .no, attestedAt: at)))
        try ArchiveAttestationJournal.append(attest, rootPath: root)

        // Ledger mirror.
        try MediaLedgerEvent.encodeLines(ledgerEvents(f, targets: targets))
            .write(to: f.indexFile(MediaLedger.mirrorFilename))

        // Decisions — never matches; must never be rewritten.
        _ = ArchivePromoteDecisions.record([.init(at: at, recordID: otherID, filename: "other.mkv",
                                                  sourcePath: "/elsewhere/other.mkv", decision: "skipped",
                                                  reason: "duplicate", detail: rel + ".bak")], rootPath: root)
    }

    static func ledgerEvents(_ f: Fixture, targets: Bool) -> [MediaLedgerEvent] {
        var events: [MediaLedgerEvent] = []
        if targets {
            events.append(MediaLedgerEvent(at: at, event: .archived, recordID: f.sourceRecord.id, contentKey: "h:x",
                                           filename: sourceName, fullPath: f.source, by: .promote,
                                           detail: [MediaLedgerEvent.Detail.relPath: rel,
                                                    MediaLedgerEvent.Detail.archive: "Breen Family Archive"]))
            events.append(MediaLedgerEvent(at: at, event: .attestation, recordID: f.archiveRecord.id, contentKey: "h:x",
                                           filename: oldName, fullPath: f.media, by: .rick,
                                           detail: [MediaLedgerEvent.Detail.kind: "cloud"]))
        }
        events.append(MediaLedgerEvent(at: at, event: .cataloged, recordID: UUID(), contentKey: "",
                                       filename: oldName, fullPath: f.media + ".bak", by: .app))
        return events
    }

    /// Every file under 00_Index a rename could touch — including the
    /// ledger mirror, which the rename no longer rewrites directly.
    static let allIndexFiles = [MasterArchiveLayout.manifestFilename, ArchivePromoteJournal.filename,
                                ArchiveAttestationJournal.filename, MediaLedger.mirrorFilename,
                                ArchivePromoteDecisions.filename]

    /// Bytes + mtime of every index file (nil when absent).
    static func snapshot(_ f: Fixture) -> [String: (Data, Date)] {
        var out: [String: (Data, Date)] = [:]
        for name in allIndexFiles {
            let url = f.indexFile(name)
            guard let d = try? Data(contentsOf: url),
                  let m = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            else { continue }
            out[name] = (d, m)
        }
        return out
    }

    static func expectUntouched(_ before: [String: (Data, Date)], _ f: Fixture,
                                sourceLocation: SourceLocation = #_sourceLocation) {
        let after = snapshot(f)
        #expect(Set(after.keys) == Set(before.keys), sourceLocation: sourceLocation)
        for (name, (data, mtime)) in before {
            #expect(after[name]?.0 == data, "\(name) bytes changed", sourceLocation: sourceLocation)
            #expect(after[name]?.1 == mtime, "\(name) was rewritten", sourceLocation: sourceLocation)
        }
    }

    static func lines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
    }

    /// The expected file: the old one with `edit` applied to the lines at
    /// `changed` (0-based) and every other line kept verbatim.
    static func expectFile(_ url: URL, before: Data, changed: Set<Int>, edit: (String) -> String,
                           sourceLocation: SourceLocation = #_sourceLocation) throws {
        let old = lines(before)
        let expected = old.enumerated().map { changed.contains($0.offset) ? edit($0.element) : $0.element }
        let actual = lines(try Data(contentsOf: url))
        #expect(actual.count == old.count, sourceLocation: sourceLocation)
        for (i, line) in actual.enumerated() where i < expected.count {
            #expect(line == expected[i], "\(url.lastPathComponent) line \(i + 1)", sourceLocation: sourceLocation)
            if changed.contains(i) {
                #expect(line != old[i], "\(url.lastPathComponent) line \(i + 1) should have changed",
                        sourceLocation: sourceLocation)
            }
        }
    }

    static func esc(_ s: String) -> String { s.replacingOccurrences(of: "/", with: "\\/") }

    // MARK: Archive file — refused (rule 3, Codex #383)

    /// The archive file is refused before anything is read or written.
    static func expectArchiveRefusal(_ f: Fixture, _ rec: VideoRecord, sourceLocation: SourceLocation = #_sourceLocation) {
        let oldPath = rec.fullPath, oldName = rec.filename
        do {
            try f.model.renameRecord(rec, toBaseName: newBase)
            Issue.record("an archive file must be refused", sourceLocation: sourceLocation)
        } catch VideoScanModel.RenameError.archivedFile {
        } catch {
            Issue.record("wrong refusal \(error)", sourceLocation: sourceLocation)
        }
        #expect(FileManager.default.fileExists(atPath: oldPath), sourceLocation: sourceLocation)
        #expect(rec.fullPath == oldPath && rec.filename == oldName, sourceLocation: sourceLocation)
    }

    @Test("archive file (unlocked promoted copy): refused — media, record, every index file and the ledger untouched, no backups, one log line")
    func archiveFileIsRefused() async throws {
        let f = try Self.makeFixture("happy")
        defer { f.cleanup() }
        try Self.writeIndex(f)
        try FileManager.default.createDirectory(at: f.model.mediaLedger.directory, withIntermediateDirectories: true)
        try MediaLedgerEvent.encodeLines(Self.ledgerEvents(f, targets: true)).write(to: f.model.mediaLedger.fileURL)
        let ledgerBefore = try Data(contentsOf: f.model.mediaLedger.fileURL)
        let before = Self.snapshot(f)

        let sink = InMemoryLogSink()
        withAppLog(sink) { Self.expectArchiveRefusal(f, f.archiveRecord) }

        #expect(!FileManager.default.fileExists(atPath: f.newMedia))
        Self.expectUntouched(before, f)
        #expect(!FileManager.default.fileExists(atPath: f.backups.path))
        #expect(sink.lines == ["Catalog: rename of \(Self.oldName) refused — it is a Master Archive file; use Update…"])
        await f.model.mediaLedger.waitForPendingWrites()
        #expect(try Data(contentsOf: f.model.mediaLedger.fileURL) == ledgerBefore)
    }

    // MARK: Lookalikes

    @Test("substring lookalikes (.bak, a longer folder name) are never changed; no match ⇒ nothing rewritten, no backups")
    func lookalikesUntouched() throws {
        let f = try Self.makeFixture("lookalike")
        defer { f.cleanup() }
        try Self.writeIndex(f, targets: false)
        let before = Self.snapshot(f)
        #expect(before.count == 5)

        let sink = InMemoryLogSink()
        try withAppLog(sink) { _ = try f.model.renameRecord(f.sourceRecord, toBaseName: Self.newSourceBase) }

        #expect(FileManager.default.fileExists(atPath: f.newSource))
        Self.expectUntouched(before, f)
        #expect(!FileManager.default.fileExists(atPath: f.backups.path))
        #expect(sink.lines.contains("Catalog: renamed \(Self.sourceName) → \(Self.newSourceName)"))
    }

    // MARK: Refusals — nothing touched

    @Test("an unparseable index line refuses the rename: media, record and every index file untouched")
    func unparseableIndexRefuses() throws {
        let f = try Self.makeFixture("damaged")
        defer { f.cleanup() }
        try Self.writeIndex(f)
        let journal = f.indexFile(ArchiveAttestationJournal.filename)
        var bytes = try Data(contentsOf: journal)
        bytes.append(Data("{\"at\":\"torn\n".utf8))
        try bytes.write(to: journal)
        let before = Self.snapshot(f)

        do {
            try f.model.renameRecord(f.sourceRecord, toBaseName: Self.newSourceBase)
            Issue.record("rename should have been refused")
        } catch VideoScanModel.RenameError.archiveIndex(let failure) {
            guard case .unparseable(let file, let line, _) = failure else {
                Issue.record("wrong failure \(failure)"); return
            }
            #expect(file == ArchiveAttestationJournal.filename)
            #expect(line == 4)
        }
        #expect(FileManager.default.fileExists(atPath: f.source))
        #expect(!FileManager.default.fileExists(atPath: f.newSource))
        #expect(f.sourceRecord.fullPath == f.source)
        #expect(f.sourceRecord.filename == Self.sourceName)
        Self.expectUntouched(before, f)
        #expect(!FileManager.default.fileExists(atPath: f.backups.path))
    }

    @Test("destination already exists: refused, nothing touched")
    func destinationExistsRefuses() throws {
        let f = try Self.makeFixture("dest")
        defer { f.cleanup() }
        try Self.writeIndex(f)
        try Data("squatter".utf8).write(to: URL(fileURLWithPath: f.newSource))
        let before = Self.snapshot(f)

        do {
            try f.model.renameRecord(f.sourceRecord, toBaseName: Self.newSourceBase)
            Issue.record("rename should have been refused")
        } catch VideoScanModel.RenameError.destinationExists(let p) {
            #expect(p == f.newSource)
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: f.newSource)) == Data("squatter".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: f.source)) == Data("source".utf8))
        #expect(f.sourceRecord.fullPath == f.source)
        Self.expectUntouched(before, f)
        #expect(!FileManager.default.fileExists(atPath: f.backups.path))
    }

    // MARK: Source (non-archive) rename

    @Test("non-archive source rename updates the manifest's source column and the journals' source paths; relPaths untouched")
    func sourceRenameUpdatesSourcePointers() async throws {
        let f = try Self.makeFixture("source")
        defer { f.cleanup() }
        try Self.writeIndex(f)
        try FileManager.default.createDirectory(at: f.model.mediaLedger.directory, withIntermediateDirectories: true)
        try MediaLedgerEvent.encodeLines(Self.ledgerEvents(f, targets: true)).write(to: f.model.mediaLedger.fileURL)
        let ledgerBefore = try Data(contentsOf: f.model.mediaLedger.fileURL)
        let before = Self.snapshot(f)
        let newSource = (f.source as NSString).deletingLastPathComponent + "/Christmas 1994 misc.mkv"

        let sink = InMemoryLogSink()
        try withAppLog(sink) { _ = try f.model.renameRecord(f.sourceRecord, toBaseName: "Christmas 1994 misc") }

        #expect(f.sourceRecord.fullPath == newSource)
        let q = { (s: String) in "\"\(s)\"" }
        try Self.expectFile(f.indexFile(MasterArchiveLayout.manifestFilename),
                            before: before[MasterArchiveLayout.manifestFilename]!.0, changed: [1]) {
            $0.replacingOccurrences(of: q(f.source), with: q(newSource))
        }
        try Self.expectFile(f.indexFile(ArchivePromoteJournal.filename),
                            before: before[ArchivePromoteJournal.filename]!.0, changed: [0, 1, 2, 3]) {
            $0.replacingOccurrences(of: q(Self.esc(f.source)), with: q(Self.esc(newSource)))
        }
        await f.model.mediaLedger.waitForPendingWrites()
        try Self.expectFile(f.model.mediaLedger.fileURL, before: ledgerBefore, changed: [0]) {
            $0.replacingOccurrences(of: q(f.source), with: q(newSource))
              .replacingOccurrences(of: q(Self.sourceName), with: q("Christmas 1994 misc.mkv"))
        }
        #expect(try Data(contentsOf: f.indexFile(MediaLedger.mirrorFilename))
                == (try Data(contentsOf: f.model.mediaLedger.fileURL)))
        // The archive's own relPath and the attestation journal (no source lines) are untouched.
        let manifestText = String(decoding: try Data(contentsOf: f.indexFile(MasterArchiveLayout.manifestFilename)), as: UTF8.self)
        #expect(manifestText.contains(q(Self.rel)))
        for name in [ArchiveAttestationJournal.filename, ArchivePromoteDecisions.filename] {
            #expect(try Data(contentsOf: f.indexFile(name)) == before[name]!.0)
        }
        #expect(sink.lines.contains("Catalog: renamed \(Self.sourceName) → Christmas 1994 misc.mkv (archive index: 5 lines in 2 files updated)"))
    }

    @Test("a non-archive file the index never mentions: renamed exactly as before, no index file (or ledger) touched")
    func unrelatedFileUnchangedBehaviour() async throws {
        let f = try Self.makeFixture("plain")
        defer { f.cleanup() }
        try Self.writeIndex(f)
        let plainURL = f.tmp.appendingPathComponent("Other/plain.mov")
        try FileManager.default.createDirectory(at: plainURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("plain".utf8).write(to: plainURL)
        let plain = Self.record(plainURL.path)
        f.model.records.append(plain)
        try FileManager.default.createDirectory(at: f.model.mediaLedger.directory, withIntermediateDirectories: true)
        try MediaLedgerEvent.encodeLines(Self.ledgerEvents(f, targets: true)).write(to: f.model.mediaLedger.fileURL)
        let ledgerBefore = try Data(contentsOf: f.model.mediaLedger.fileURL)
        let before = Self.snapshot(f)

        let sink = InMemoryLogSink()
        let newPath = try withAppLog(sink) { try f.model.renameRecord(plain, toBaseName: "renamed") }

        #expect(newPath == plainURL.deletingLastPathComponent().appendingPathComponent("renamed.mov").path)
        #expect(plain.filename == "renamed.mov")
        Self.expectUntouched(before, f)
        #expect(!FileManager.default.fileExists(atPath: f.backups.path))
        #expect(sink.lines.contains("Catalog: renamed plain.mov → renamed.mov"))
        await f.model.mediaLedger.waitForPendingWrites()
        #expect(try Data(contentsOf: f.model.mediaLedger.fileURL) == ledgerBefore)
    }

    // MARK: Failure after the move — rollback

    @Test("an index publish failing after the move rolls back: media moved back, published files restored, record unchanged")
    func publishFailureRollsBack() throws {
        let f = try Self.makeFixture("rollback")
        defer { f.cleanup() }
        try Self.writeIndex(f)
        let before = Self.snapshot(f)
        var calls = 0

        do {
            try f.model.renameRecord(f.sourceRecord, toBaseName: Self.newSourceBase, indexPublisher: { data, url in
                calls += 1
                if calls == 2 { throw CocoaError(.fileWriteNoPermission) }
                try ArchiveIndexRename.livePublish(data, to: url)
            })
            Issue.record("rename should have failed")
        } catch VideoScanModel.RenameError.archiveIndex(let failure) {
            guard case .publishFailedRolledBack(let file, _) = failure else {
                Issue.record("wrong failure \(failure)"); return
            }
            #expect(file == ArchivePromoteJournal.filename)
        }
        #expect(calls == 3, "2 forward publishes + 1 restore of the manifest")
        #expect(FileManager.default.fileExists(atPath: f.source))
        #expect(!FileManager.default.fileExists(atPath: f.newSource))
        #expect(f.sourceRecord.fullPath == f.source)
        let after = Self.snapshot(f)
        for (name, (data, _)) in before { #expect(after[name]?.0 == data, "\(name) not restored") }
        // Rolled back = refused: its own backup folder is removed.
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: f.backups.path)) ?? []).isEmpty)
    }

    // MARK: Isolation

    @Test("isolation: the test host's ledger is never the real App Support file; an offline designation renames as before")
    func isolationOfflineArchive() throws {
        #expect(!MediaLedger.defaultDirectory.path.contains("Library/Application Support"))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("VideoScanRenameIndex-offline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("clip.mov")
        try Data("x".utf8).write(to: file)
        let model = VideoScanModel()
        model.mediaLedger = MediaLedger(directory: tmp.appendingPathComponent("ledger"))
        let offlineRoot = "/Volumes/VideoScanNoSuchArchive-\(UUID().uuidString)/\(MasterArchiveLayout.rootFolderName)"
        model.masterArchive = MasterArchiveDesignation(targetPath: (offlineRoot as NSString).deletingLastPathComponent,
                                                       rootPath: offlineRoot)
        let rec = Self.record(file.path)
        model.records = [rec]
        _ = try model.renameRecord(rec, toBaseName: "clip2")
        #expect(rec.filename == "clip2.mov")
        #expect(!FileManager.default.fileExists(atPath: offlineRoot))
    }

    @Test("poisoned 00_Index (a symlink to a folder elsewhere): refused, the link's target is untouched")
    func symlinkedIndexRefuses() throws {
        let f = try Self.makeFixture("symlink")
        defer { f.cleanup() }
        try Self.writeIndex(f)
        // Move the real index aside and put a symlink in its place.
        let elsewhere = f.tmp.appendingPathComponent("elsewhere-index")
        try FileManager.default.moveItem(at: f.index, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: f.index, withDestinationURL: elsewhere)
        let manifest = elsewhere.appendingPathComponent(MasterArchiveLayout.manifestFilename)
        let beforeBytes = try Data(contentsOf: manifest)

        do {
            try f.model.renameRecord(f.sourceRecord, toBaseName: Self.newSourceBase)
            Issue.record("rename should have been refused")
        } catch VideoScanModel.RenameError.archiveIndex(let failure) {
            guard case .unreadable = failure else { Issue.record("wrong failure \(failure)"); return }
        }
        #expect(FileManager.default.fileExists(atPath: f.source))
        #expect(try Data(contentsOf: manifest) == beforeBytes)
        #expect(!FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent(ArchiveIndexRename.backupFolder).path))
    }

    // MARK: QA round 1 (2026-09-25) — RED first

    @Test("M1: an append landing between the move and a publish is never lost — the rename is refused and rolled back")
    func concurrentAppendDuringPublishIsNotLost() throws {
        let f = try Self.makeFixture("race")
        defer { f.cleanup() }
        try Self.writeIndex(f)
        let straggler = UUID()
        var calls = 0
        var refused = false
        var appendRefused = false
        do {
            try f.model.renameRecord(f.sourceRecord, toBaseName: Self.newSourceBase, indexPublisher: { data, url in
                calls += 1
                if calls == 1 {
                    // Promote appends to the journal while the rename is
                    // publishing the manifest. Since the archive-index lock
                    // (codex review of Refile #1, 2026-09-27) the append is
                    // REFUSED while the rename holds the index — the
                    // appender is told (Busy) and its journal converges on
                    // the next run; what must never happen is a silent drop.
                    do {
                        try ArchivePromoteJournal.append(.init(sourceRecordID: straggler, sourcePath: "/Volumes/Src/late.mkv",
                                                               destRelPath: "30_Video/late.mkv", state: .intent, at: Self.at),
                                                         rootPath: f.root)
                    } catch is ArchiveIndexLock.Busy {
                        appendRefused = true
                    }
                }
                try ArchiveIndexRename.livePublish(data, to: url)
            })
        } catch {
            refused = true
        }
        #expect(appendRefused || ArchivePromoteJournal.latestBySource(rootPath: f.root)[straggler] != nil,
                "the concurrent journal append was dropped by a whole-file publish")
        if refused {
            #expect(FileManager.default.fileExists(atPath: f.source))
            #expect(!FileManager.default.fileExists(atPath: f.newSource))
            #expect(f.sourceRecord.fullPath == f.source)
            #expect(ArchiveManifestCSV.fieldRowsBySource(rootPath: f.root).values.contains { $0[4] == f.source },
                    "the already-published manifest was restored")
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: f.backups.path)) ?? []).isEmpty)
        }
    }

    @Test("M2: a path with a double quote is rewritten in the CSV (\"\" escaped) AND the journal — the index never splits")
    func csvCellWithQuoteIsRewritten() throws {
        let f = try Self.makeFixture("quote", sourceName: "Say \"hi\" 1994.mkv")
        defer { f.cleanup() }
        try Self.writeIndex(f)
        let newSource = (f.source as NSString).deletingLastPathComponent + "/Say hi 1994.mkv"

        _ = try f.model.renameRecord(f.sourceRecord, toBaseName: "Say hi 1994")

        let originals = ArchiveManifestCSV.fieldRowsBySource(rootPath: f.root).values.map { $0[4] }
        #expect(originals.contains(newSource), "manifest source column not rewritten")
        #expect(!originals.contains(f.source))
        #expect(originals.contains(f.source + ".bak"), "lookalike untouched")
        #expect(ArchivePromoteJournal.latestBySource(rootPath: f.root)[f.sourceRecord.id]?.sourcePath == newSource)
    }

    @Test("m3: archive volume identity mismatch — an archive file is refused (as everywhere), a source rename skips the index with a log line")
    func identityMismatchRefusesOrSkips() throws {
        let f = try Self.makeFixture("identity", volumeUUID: "00000000-0000-0000-0000-00000000BAD0")
        defer { f.cleanup() }
        try Self.writeIndex(f)
        #expect(f.model.masterArchiveIdentityRefusal() != nil)
        let before = Self.snapshot(f)

        Self.expectArchiveRefusal(f, f.archiveRecord)

        let sink = InMemoryLogSink()
        try withAppLog(sink) { _ = try f.model.renameRecord(f.sourceRecord, toBaseName: "Christmas 1994 misc") }
        #expect(f.sourceRecord.filename == "Christmas 1994 misc.mkv")
        #expect(sink.lines.contains { $0.contains("archive index NOT updated") })
        Self.expectUntouched(before, f)
        #expect(!FileManager.default.fileExists(atPath: f.backups.path))
    }

    @Test("m4: a file with no promote link never reads the index — a damaged index cannot block an ordinary rename")
    func unlinkedFileNeverReadsIndex() throws {
        let f = try Self.makeFixture("unlinked")
        defer { f.cleanup() }
        try Self.writeIndex(f)
        let journal = f.indexFile(ArchivePromoteJournal.filename)
        var bytes = try Data(contentsOf: journal)
        bytes.append(Data("{torn\n".utf8))
        try bytes.write(to: journal)
        let plainURL = f.tmp.appendingPathComponent("Other/plain.mov")
        try FileManager.default.createDirectory(at: plainURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("plain".utf8).write(to: plainURL)
        let plain = Self.record(plainURL.path)
        f.model.records.append(plain)
        let before = Self.snapshot(f)

        _ = try f.model.renameRecord(plain, toBaseName: "renamed")

        #expect(plain.filename == "renamed.mov")
        Self.expectUntouched(before, f)
    }

    @Test("a stray file at the archive ROOT (never promoted) is an archive file too: refused, decisions untouched")
    func archiveRootFileBareNameNotAKey() throws {
        let f = try Self.makeFixture("rootfile")
        defer { f.cleanup() }
        try Self.writeIndex(f)
        let strayURL = URL(fileURLWithPath: f.root).appendingPathComponent("clip.mov")
        try Data("stray".utf8).write(to: strayURL)
        let stray = Self.record(strayURL.path)
        f.model.records.append(stray)
        _ = ArchivePromoteDecisions.record([.init(at: Self.at, recordID: UUID(), filename: "clip.mov",
                                                  sourcePath: "/elsewhere/clip.mov", decision: "skipped",
                                                  reason: "source volume offline", detail: nil)],
                                           rootPath: f.root)
        let decisionsBefore = try Data(contentsOf: f.indexFile(ArchivePromoteDecisions.filename))

        Self.expectArchiveRefusal(f, stray)

        #expect(stray.filename == "clip.mov")
        #expect(try Data(contentsOf: f.indexFile(ArchivePromoteDecisions.filename)) == decisionsBefore)
    }

    @Test("M1: while a Promote appends to the index, a source rename that would rewrite it is refused in the MODEL; the archive file is refused as always")
    func busyArchiveRefusesInModel() throws {
        let f = try Self.makeFixture("busy")
        defer { f.cleanup() }
        try Self.writeIndex(f)
        f.model.archiveIndexWriterActive = { true }
        let before = Self.snapshot(f)
        Self.expectArchiveRefusal(f, f.archiveRecord)
        let oldPath = f.sourceRecord.fullPath
        do {
            try f.model.renameRecord(f.sourceRecord, toBaseName: "renamed while busy")
            Issue.record("the source should be refused while a Promote runs")
        } catch VideoScanModel.RenameError.archiveBusy {
        }
        #expect(f.sourceRecord.fullPath == oldPath)
        #expect(FileManager.default.fileExists(atPath: oldPath))
        Self.expectUntouched(before, f)
        #expect(!FileManager.default.fileExists(atPath: f.backups.path))

        // An unrelated file is not held up by a Promote.
        let plainURL = f.tmp.appendingPathComponent("Other/plain.mov")
        try FileManager.default.createDirectory(at: plainURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("plain".utf8).write(to: plainURL)
        let plain = Self.record(plainURL.path)
        f.model.records.append(plain)
        _ = try f.model.renameRecord(plain, toBaseName: "renamed")
        #expect(plain.filename == "renamed.mov")
    }

    /// Was "keeps the newest 20 folders" by NAME, which pruned the two
    /// oldest-named markerless folders. Codex review of GH #204
    /// (2026-09-27): names carry no provenance, so markerless (legacy)
    /// folders are never pruned; retention of MARKED backups is pinned in
    /// LedgerRenameBackupProvenanceTests / LedgerRenameBackupOrderingTests.
    @Test("nit: .rename_backups never prunes legacy (markerless) folders; this rename's backup is marked complete")
    func backupRetentionKeepsTwenty() throws {
        let f = try Self.makeFixture("retention")
        defer { f.cleanup() }
        try Self.writeIndex(f)
        for i in 0..<22 {
            try FileManager.default.createDirectory(
                at: f.backups.appendingPathComponent(String(format: "2000-01-01T000000.%03d", i)),
                withIntermediateDirectories: true)
        }

        _ = try f.model.renameRecord(f.sourceRecord, toBaseName: Self.newSourceBase)

        let kept = try FileManager.default.contentsOfDirectory(atPath: f.backups.path).sorted()
        #expect(kept.count == 23, "22 legacy folders left in place + this rename's own")
        #expect(kept.contains("2000-01-01T000000.000"))
        #expect(kept.contains("2000-01-01T000000.021"))
        let own = try #require(kept.last)
        #expect(!own.hasPrefix("2000"), "this rename's own folder is kept")
        let marker = try #require(ArchiveIndexRename.readMarker(in: f.backups.appendingPathComponent(own)))
        #expect(marker.complete && marker.sequence == 1)
        #expect(!marker.files.isEmpty)
    }

    // MARK: Engine rules

    @Test("engine: JSON keys are never replaced; values at any depth are; CSV cells with quotes/commas round-trip")
    func engineTokenRules() throws {
        let old = "/a/b.mov", new = "/a/c.mov"
        let r = ArchiveIndexRename.Replacements(values: [old: new], oldFilename: "b.mov", newFilename: "c.mov")
        let line = #"{"/a/b.mov":"keep","x":["/a/b.mov",{"fullPath":"/a/b.mov","filename":"b.mov"},{"detail":"/a/b.mov","filename":"b.mov"}],"z":"/a/b.mov.bak","filename":"b.mov"}"#
        let out = try ArchiveIndexRename.rewriteJSONL(Array((line + "\n").utf8), replacements: r, file: "t", lenient: false)
        #expect(out.changedLines == 1)
        #expect(String(decoding: out.bytes, as: UTF8.self) ==
                #"{"/a/b.mov":"keep","x":["/a/c.mov",{"fullPath":"/a/c.mov","filename":"c.mov"},{"detail":"/a/c.mov","filename":"b.mov"}],"z":"/a/b.mov.bak","filename":"b.mov"}"# + "\n",
                "filename follows only a matched fullPath/sourcePath in its own object — not `detail`, not a parent")

        let header = MasterArchiveLayout.manifestHeader
        let csv = header + "\n" + #""x","/a/b.mov","say ""hi"", ok","/a/b.mov,old""# + "\r\n"
        let csvOut = try ArchiveIndexRename.rewriteCSV(Array(csv.utf8), replacements: r, file: "m")
        #expect(csvOut.changedLines == 1)
        #expect(String(decoding: csvOut.bytes, as: UTF8.self) ==
                header + "\n" + #""x","/a/c.mov","say ""hi"", ok","/a/b.mov,old""# + "\r\n")

        // Unchanged input is returned verbatim (same bytes, zero lines).
        let none = try ArchiveIndexRename.rewriteJSONL(Array(#"{"a":"/q"}"#.utf8), replacements: r, file: "t", lenient: false)
        #expect(none.changedLines == 0)
        #expect(none.bytes == Array(#"{"a":"/q"}"#.utf8))

        // The one-parse fast path must not hide a line holding TWO values,
        // or one value split over two lines: both refuse, naming the line.
        for (text, badLine) in [(#"{"a":"/q"}"# + "\n" + #"{"a":1},{"b":2}"# + "\n", 2),
                                ("[1\n2]\n", 1)] {
            #expect(!ArchiveIndexRename.allLinesParse(Array(text.utf8)))
            do {
                _ = try ArchiveIndexRename.rewriteJSONL(Array(text.utf8), replacements: r, file: "t", lenient: false)
                Issue.record("\(text) should refuse")
            } catch let failure as ArchiveIndexRename.Failure {
                #expect(failure == .unparseable(file: "t", line: badLine, reason: "not valid JSON"))
            }
        }
        #expect(ArchiveIndexRename.allLinesParse(Array((#"{"a":1}"# + "\n\n" + #"{"b":"x"}"# + "\n").utf8)))
    }

    // MARK: Scale sensor

    @Test("scale: a source rename through a 50k-line manifest + 50k-line promote journal within budget; the 50k-line App Support ledger follows and is re-mirrored")
    func scaleFiftyThousandLines() async throws {
        let f = try Self.makeFixture("scale")
        defer { f.cleanup() }
        let n = 50_000
        func original(_ i: Int) -> String { i == n / 2 ? f.source : "/Volumes/Src/clip_\(i).mkv" }
        var manifest = MasterArchiveLayout.manifestHeader + "\n"
        manifest.reserveCapacity(n * 260)
        var ledger: [MediaLedgerEvent] = []
        ledger.reserveCapacity(n)
        for i in 0..<n {
            let relPath = i == n / 2 ? Self.rel : "30_Video/1990-1999/1994/clip_\(i).mkv"
            manifest += ArchiveManifestCSV.line(for: .init(promotedAt: Self.at, archiveRelPath: relPath, sha256: "ab\(i)",
                                                           sizeBytes: Int64(i), originalPath: original(i),
                                                           originalVolume: "Src", recordID: UUID(), sourceRecordID: UUID(),
                                                           recordDate: "1994", dateConfidence: "estimated",
                                                           people: [], starRating: 0))
            ledger.append(MediaLedgerEvent(at: Self.at, event: .archived, recordID: UUID(), contentKey: "h:\(i)",
                                           filename: (original(i) as NSString).lastPathComponent, fullPath: original(i), by: .promote,
                                           detail: [MediaLedgerEvent.Detail.relPath: relPath]))
        }
        try Data(manifest.utf8).write(to: f.indexFile(MasterArchiveLayout.manifestFilename))
        try FileManager.default.createDirectory(at: f.model.mediaLedger.directory, withIntermediateDirectories: true)
        try MediaLedgerEvent.encodeLines(ledger).write(to: f.model.mediaLedger.fileURL)
        // Promote journal: the default encoder escapes every `/` as `\/`,
        // so no line passes the cheap literal pre-filter — the worst case.
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        var journal = Data()
        for i in 0..<n {
            let relPath = i == n / 2 ? Self.rel : "30_Video/1990-1999/1994/clip_\(i).mkv"
            journal.append(try enc.encode(ArchivePromoteJournal.Entry(
                sourceRecordID: i == n / 2 ? f.sourceRecord.id : UUID(), sourcePath: original(i), destRelPath: relPath,
                state: .done, sha256: "ab\(i)", copyRecordID: UUID(), at: Self.at)))
            journal.append(0x0A)
        }
        try journal.write(to: f.indexFile(ArchivePromoteJournal.filename))

        let clock = ContinuousClock()
        var result = ""
        let elapsed = try clock.measure {
            result = try f.model.renameRecord(f.sourceRecord, toBaseName: Self.newSourceBase)
        }
        #expect(result == f.newSource)
        let originals = ArchiveManifestCSV.fieldRowsBySource(rootPath: f.root).values.map { $0[4] }
        #expect(originals.filter { $0 == f.newSource }.count == 1)
        #expect(!originals.contains(f.source))
        #expect(ArchivePromoteJournal.latestBySource(rootPath: f.root)[f.sourceRecord.id]?.sourcePath == f.newSource)
        await f.model.mediaLedger.waitForPendingWrites()
        let mirror = try Data(contentsOf: f.indexFile(MediaLedger.mirrorFilename))
        #expect(mirror == (try Data(contentsOf: f.model.mediaLedger.fileURL)))
        let mirrorText = String(decoding: mirror, as: UTF8.self)
        #expect(mirrorText.components(separatedBy: "\"\(f.newSource)\"").count == 2, "one ledger line follows")
        #expect(!mirrorText.contains("\"\(f.source)\""))
        let budget = PerformanceLane.debugCeiling(.seconds(2))
        print("[CatalogRenameArchiveIndexTests] 2x50k index rename: \(elapsed) (\(PerformanceLane.configurationName))")
        #expect(elapsed < budget, "2×50k index rename took \(elapsed) (budget \(budget))")
    }
}
