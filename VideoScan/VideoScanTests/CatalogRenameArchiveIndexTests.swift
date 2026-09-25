// CatalogRenameArchiveIndexTests.swift
// Renaming a file in the Catalog is THE way to fix a typo in a name, also
// for files in the Master Archive (Rick 2026-09-25) — the rename carries
// through to the archive's index files (ArchiveIndexRename.swift).
//
// Dimensions (CLAUDE.md feature-test checklist):
//   LOGIC     — happy path (9 lines in 4 files, byte-identical untouched
//               lines, backups, record, log line); substring lookalikes
//               untouched; unparseable index refuses; destination exists
//               refuses; source-path rename; no-reference rename unchanged;
//               publish failure rolls back; engine token rules.
//   ISOLATION — tmp-dir archive only; the ledger is a per-test folder; an
//               offline designation and a symlinked 00_Index are refused
//               or ignored without touching anything outside the fixture.
//   SCALE     — 50k-line manifest + 50k-line ledger mirror within a budget.
//
// Everything lives under FileManager.temporaryDirectory; no real volume,
// no real Application Support. Serialized: two tests swap the global appLog.

import Foundation
import Testing
@testable import VideoScan

@Suite("Catalog rename — carries through to the archive index", .serialized)
@MainActor
struct CatalogRenameArchiveIndexTests {

    // MARK: Fixture

    static let rel = "30_Video/1990-1999/1994/1994-xx-xx_Chrsitmas_1994_misc.mkv"
    static let newBase = "1994-xx-xx_Christmas_1994_misc"
    static var newRel: String { "30_Video/1990-1999/1994/\(newBase).mkv" }
    static let oldName = "1994-xx-xx_Chrsitmas_1994_misc.mkv"
    static let newName = "1994-xx-xx_Christmas_1994_misc.mkv"
    static let sourceName = "Chrsitmas 1994 misc.mkv"
    static let at = Date(timeIntervalSince1970: 1_758_000_000)

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
        var newMedia: String { (root as NSString).appendingPathComponent(CatalogRenameArchiveIndexTests.newRel) }
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

    static func makeFixture(_ label: String) throws -> Fixture {
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
        model.masterArchive = MasterArchiveDesignation(targetPath: vol.path, rootPath: root.path)
        model.mediaLedger = MediaLedger(directory: tmp.appendingPathComponent("ledger", isDirectory: true))
        let archiveRecord = record(media.path)
        let sourceRecord = record(source.path)
        model.records = [archiveRecord, sourceRecord]
        return Fixture(tmp: tmp, root: root.path, index: index, media: media.path, source: source.path,
                       model: model, archiveRecord: archiveRecord, sourceRecord: sourceRecord)
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

    static let allIndexFiles = ArchiveIndexRename.indexFilenames

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

    // MARK: Happy path — archive file

    @Test("archive file: manifest + journals + ledger rewritten (9 lines in 4 files), untouched lines byte-identical, backups, record, log")
    func archiveRenameHappyPath() async throws {
        let f = try Self.makeFixture("happy")
        defer { f.cleanup() }
        try Self.writeIndex(f)
        // The App Support ledger (here: the per-test folder) holds the same events.
        try FileManager.default.createDirectory(at: f.model.mediaLedger.directory, withIntermediateDirectories: true)
        try MediaLedgerEvent.encodeLines(Self.ledgerEvents(f, targets: true)).write(to: f.model.mediaLedger.fileURL)
        let ledgerBefore = try Data(contentsOf: f.model.mediaLedger.fileURL)
        let before = Self.snapshot(f)

        let sink = InMemoryLogSink()
        let newPath = try withAppLog(sink) { try f.model.renameRecord(f.archiveRecord, toBaseName: Self.newBase) }

        // Media + record.
        #expect(newPath == f.newMedia)
        #expect(FileManager.default.fileExists(atPath: f.newMedia))
        #expect(!FileManager.default.fileExists(atPath: f.media))
        #expect(f.archiveRecord.fullPath == f.newMedia)
        #expect(f.archiveRecord.filename == Self.newName)

        // Manifest: data row 1 (line index 1) only; the relPath cell only.
        let q = { (s: String) in "\"\(s)\"" }
        try Self.expectFile(f.indexFile(MasterArchiveLayout.manifestFilename),
                            before: before[MasterArchiveLayout.manifestFilename]!.0, changed: [1]) {
            $0.replacingOccurrences(of: q(Self.rel), with: q(Self.newRel))
        }
        // Promote journal: 4 target lines; `\/` style kept, key order kept.
        try Self.expectFile(f.indexFile(ArchivePromoteJournal.filename),
                            before: before[ArchivePromoteJournal.filename]!.0, changed: [0, 1, 2, 3]) {
            $0.replacingOccurrences(of: q(Self.esc(Self.rel)), with: q(Self.esc(Self.newRel)))
        }
        // Attestation journal: 2 lines — fullPath AND the same-object filename.
        try Self.expectFile(f.indexFile(ArchiveAttestationJournal.filename),
                            before: before[ArchiveAttestationJournal.filename]!.0, changed: [0, 1]) {
            $0.replacingOccurrences(of: q(f.media), with: q(f.newMedia))
              .replacingOccurrences(of: q(Self.oldName), with: q(Self.newName))
        }
        // Ledger mirror: archived (detail.relPath) + attestation (fullPath + filename).
        let ledgerEdit: (String) -> String = {
            $0.replacingOccurrences(of: q(Self.rel), with: q(Self.newRel))
              .replacingOccurrences(of: q(f.media), with: q(f.newMedia))
              .replacingOccurrences(of: "\"filename\":\(q(Self.oldName)),\"fullPath\":\(q(f.newMedia))",
                                    with: "\"filename\":\(q(Self.newName)),\"fullPath\":\(q(f.newMedia))")
        }
        try Self.expectFile(f.indexFile(MediaLedger.mirrorFilename),
                            before: before[MediaLedger.mirrorFilename]!.0, changed: [0, 1], edit: ledgerEdit)
        // The .bak cataloged event kept its filename (its path did not match).
        let mirrorText = String(decoding: try Data(contentsOf: f.indexFile(MediaLedger.mirrorFilename)), as: UTF8.self)
        #expect(mirrorText.contains(q(f.media + ".bak")))

        // Decisions: never matched — byte-identical AND not rewritten.
        let decisions = ArchivePromoteDecisions.filename
        #expect(try Data(contentsOf: f.indexFile(decisions)) == before[decisions]!.0)
        #expect((try FileManager.default.attributesOfItem(atPath: f.indexFile(decisions).path))[.modificationDate] as? Date
                == before[decisions]!.1)

        // Backups: one folder, the 4 affected files, original bytes.
        let stamps = try FileManager.default.contentsOfDirectory(atPath: f.backups.path)
        #expect(stamps.count == 1)
        let backupDir = f.backups.appendingPathComponent(stamps[0])
        let backedUp = Set(try FileManager.default.contentsOfDirectory(atPath: backupDir.path))
        #expect(backedUp == [MasterArchiveLayout.manifestFilename, ArchivePromoteJournal.filename,
                             ArchiveAttestationJournal.filename, MediaLedger.mirrorFilename])
        for name in backedUp {
            #expect(try Data(contentsOf: backupDir.appendingPathComponent(name)) == before[name]!.0)
        }

        // Readers agree.
        #expect(ArchiveManifestCSV.rowsBySource(rootPath: f.root).values.contains { $0.relPath == Self.newRel })
        #expect(ArchivePromoteJournal.latestBySource(rootPath: f.root)[f.sourceRecord.id]?.destRelPath == Self.newRel)
        #expect(ArchiveAttestationJournal.entries(rootPath: f.root).filter { $0.fullPath == f.newMedia }.count == 2)

        // One log line, Rick's format.
        #expect(sink.lines.contains("Catalog: renamed \(Self.oldName) → \(Self.newName) (archive index: 9 lines in 4 files updated)"))

        // The App Support ledger (the mirror's source) follows, off-main.
        await f.model.mediaLedger.waitForPendingWrites()
        try Self.expectFile(f.model.mediaLedger.fileURL, before: ledgerBefore, changed: [0, 1], edit: ledgerEdit)
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
        try withAppLog(sink) { _ = try f.model.renameRecord(f.archiveRecord, toBaseName: Self.newBase) }

        #expect(FileManager.default.fileExists(atPath: f.newMedia))
        Self.expectUntouched(before, f)
        #expect(!FileManager.default.fileExists(atPath: f.backups.path))
        #expect(sink.lines.contains("Catalog: renamed \(Self.oldName) → \(Self.newName)"))
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
            try f.model.renameRecord(f.archiveRecord, toBaseName: Self.newBase)
            Issue.record("rename should have been refused")
        } catch VideoScanModel.RenameError.archiveIndex(let failure) {
            guard case .unparseable(let file, let line, _) = failure else {
                Issue.record("wrong failure \(failure)"); return
            }
            #expect(file == ArchiveAttestationJournal.filename)
            #expect(line == 4)
        }
        #expect(FileManager.default.fileExists(atPath: f.media))
        #expect(!FileManager.default.fileExists(atPath: f.newMedia))
        #expect(f.archiveRecord.fullPath == f.media)
        #expect(f.archiveRecord.filename == Self.oldName)
        Self.expectUntouched(before, f)
        #expect(!FileManager.default.fileExists(atPath: f.backups.path))
    }

    @Test("destination already exists: refused, nothing touched")
    func destinationExistsRefuses() throws {
        let f = try Self.makeFixture("dest")
        defer { f.cleanup() }
        try Self.writeIndex(f)
        try Data("squatter".utf8).write(to: URL(fileURLWithPath: f.newMedia))
        let before = Self.snapshot(f)

        do {
            try f.model.renameRecord(f.archiveRecord, toBaseName: Self.newBase)
            Issue.record("rename should have been refused")
        } catch VideoScanModel.RenameError.destinationExists(let p) {
            #expect(p == f.newMedia)
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: f.newMedia)) == Data("squatter".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: f.media)) == Data("archive copy".utf8))
        #expect(f.archiveRecord.fullPath == f.media)
        Self.expectUntouched(before, f)
        #expect(!FileManager.default.fileExists(atPath: f.backups.path))
    }

    // MARK: Source (non-archive) rename

    @Test("non-archive source rename updates the manifest's source column and the journals' source paths; relPaths untouched")
    func sourceRenameUpdatesSourcePointers() throws {
        let f = try Self.makeFixture("source")
        defer { f.cleanup() }
        try Self.writeIndex(f)
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
        try Self.expectFile(f.indexFile(MediaLedger.mirrorFilename),
                            before: before[MediaLedger.mirrorFilename]!.0, changed: [0]) {
            $0.replacingOccurrences(of: q(f.source), with: q(newSource))
              .replacingOccurrences(of: q(Self.sourceName), with: q("Christmas 1994 misc.mkv"))
        }
        // The archive's own relPath and the attestation journal (no source lines) are untouched.
        let manifestText = String(decoding: try Data(contentsOf: f.indexFile(MasterArchiveLayout.manifestFilename)), as: UTF8.self)
        #expect(manifestText.contains(q(Self.rel)))
        for name in [ArchiveAttestationJournal.filename, ArchivePromoteDecisions.filename] {
            #expect(try Data(contentsOf: f.indexFile(name)) == before[name]!.0)
        }
        #expect(sink.lines.contains("Catalog: renamed \(Self.sourceName) → Christmas 1994 misc.mkv (archive index: 6 lines in 3 files updated)"))
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
            try f.model.renameRecord(f.archiveRecord, toBaseName: Self.newBase, indexPublisher: { data, url in
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
        #expect(FileManager.default.fileExists(atPath: f.media))
        #expect(!FileManager.default.fileExists(atPath: f.newMedia))
        #expect(f.archiveRecord.fullPath == f.media)
        let after = Self.snapshot(f)
        for (name, (data, _)) in before { #expect(after[name]?.0 == data, "\(name) not restored") }
        // The backups stay (they are what the log points at).
        #expect(FileManager.default.fileExists(atPath: f.backups.path))
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
            try f.model.renameRecord(f.archiveRecord, toBaseName: Self.newBase)
            Issue.record("rename should have been refused")
        } catch VideoScanModel.RenameError.archiveIndex(let failure) {
            guard case .unreadable = failure else { Issue.record("wrong failure \(failure)"); return }
        }
        #expect(FileManager.default.fileExists(atPath: f.media))
        #expect(try Data(contentsOf: manifest) == beforeBytes)
        #expect(!FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent(ArchiveIndexRename.backupFolder).path))
    }

    // MARK: Engine rules

    @Test("engine: JSON keys are never replaced; values at any depth are; CSV cells with quotes/commas round-trip")
    func engineTokenRules() throws {
        let old = "/a/b.mov", new = "/a/c.mov"
        let r = ArchiveIndexRename.Replacements(values: [old: new], oldFilename: "b.mov", newFilename: "c.mov")
        let line = #"{"/a/b.mov":"keep","x":["/a/b.mov",{"y":"/a/b.mov","filename":"b.mov"}],"z":"/a/b.mov.bak","filename":"b.mov"}"#
        let out = try ArchiveIndexRename.rewriteJSONL(Array((line + "\n").utf8), replacements: r, file: "t", lenient: false)
        #expect(out.changedLines == 1)
        #expect(String(decoding: out.bytes, as: UTF8.self) ==
                #"{"/a/b.mov":"keep","x":["/a/c.mov",{"y":"/a/c.mov","filename":"c.mov"}],"z":"/a/b.mov.bak","filename":"b.mov"}"# + "\n",
                "nested filename follows its matched sibling; the top-level one had no matched path beside it")

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
    }

    // MARK: Scale sensor

    @Test("scale: 50k-line manifest + 50k-line ledger mirror rewrite within budget")
    func scaleFiftyThousandLines() throws {
        let f = try Self.makeFixture("scale")
        defer { f.cleanup() }
        let n = 50_000
        var manifest = MasterArchiveLayout.manifestHeader + "\n"
        manifest.reserveCapacity(n * 260)
        var ledger: [MediaLedgerEvent] = []
        ledger.reserveCapacity(n)
        for i in 0..<n {
            let relPath = i == n / 2 ? Self.rel : "30_Video/1990-1999/1994/clip_\(i).mkv"
            manifest += ArchiveManifestCSV.line(for: .init(promotedAt: Self.at, archiveRelPath: relPath, sha256: "ab\(i)",
                                                           sizeBytes: Int64(i), originalPath: "/Volumes/Src/clip_\(i).mkv",
                                                           originalVolume: "Src", recordID: UUID(), sourceRecordID: UUID(),
                                                           recordDate: "1994", dateConfidence: "estimated",
                                                           people: [], starRating: 0))
            ledger.append(MediaLedgerEvent(at: Self.at, event: .archived, recordID: UUID(), contentKey: "h:\(i)",
                                           filename: "clip_\(i).mkv", fullPath: "/Volumes/Src/clip_\(i).mkv", by: .promote,
                                           detail: [MediaLedgerEvent.Detail.relPath: relPath]))
        }
        try Data(manifest.utf8).write(to: f.indexFile(MasterArchiveLayout.manifestFilename))
        try MediaLedgerEvent.encodeLines(ledger).write(to: f.indexFile(MediaLedger.mirrorFilename))

        let clock = ContinuousClock()
        var result = ""
        let elapsed = try clock.measure {
            result = try f.model.renameRecord(f.archiveRecord, toBaseName: Self.newBase)
        }
        #expect(result == f.newMedia)
        let rows = ArchiveManifestCSV.rowsBySource(rootPath: f.root)
        #expect(rows.values.filter { $0.relPath == Self.newRel }.count == 1)
        #expect(rows.values.filter { $0.relPath == Self.rel }.isEmpty)
        let budget = PerformanceLane.debugCeiling(.seconds(4))
        #expect(elapsed < budget, "50k+50k index rename took \(elapsed) (budget \(budget))")
    }
}
