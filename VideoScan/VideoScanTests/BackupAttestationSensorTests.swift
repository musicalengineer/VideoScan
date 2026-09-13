// BackupAttestationSensorTests.swift
// Rick's promote-and-prune ruling (2026-09-12), stage 1 — the app-side
// half of the backup attestations:
//
//   SENSORS   legacyTwelveColumnManifestStillLoads
//             manifestRoundTripsPlaceAndAttestations
//             promotedCopyInheritsAttestations
//             (rescanNeverDropsAttestations lives in RescanPreservationTests
//              beside its place twin; the same-footage twins live in
//              PlaceInheritanceSensorTests.)
//   LOGIC     recordAttestation (replace-by-kind, journal line, record-
//             scoped notifications, label trimming, unknown ids); the CSV
//             export column; CSV escaping of the JSON manifest cell.
//             (The journal's batching / off-main / failure contract lives
//             in BackupAttestationJournalTests — codex #1416.)
//   ISOLATION manifest + journal only ever under a temp sandbox; a
//             poisoned "real-looking" archive tree is byte-identical after
//             the whole flow, and the flow's root is the INJECTED one.
//   SCALE     protectionSummary over 100k records × 5k content groups,
//             computed once per batch, under a budget.

import Foundation
import Testing
@testable import VideoScan

// MARK: - Manifest sensors

@Suite("Backup attestations — manifest sensors", .serialized)
@MainActor
struct BackupAttestationManifestSensorTests {

    private let attestedAt = Date(timeIntervalSince1970: 1_757_700_000)
    private var familyWord: [BackupAttestation] {
        [BackupAttestation(kind: .cloud, answer: .yes, label: "O'Neil, \"family\" cloud", attestedAt: attestedAt),
         BackupAttestation(kind: .offsite, answer: .notApplicable, attestedAt: attestedAt)]
    }

    private func row(_ rel: String, source: UUID = UUID(), place: String = "", confidence: String = "",
                     attestations: String = "") -> ArchiveManifestCSV.Row {
        ArchiveManifestCSV.Row(promotedAt: attestedAt, archiveRelPath: rel, sha256: "s", sizeBytes: 1,
                               originalPath: "/Volumes/T/\((rel as NSString).lastPathComponent)", originalVolume: "T",
                               recordID: UUID(), sourceRecordID: source,
                               recordDate: "1992-07-15", dateConfidence: "user-known", people: ["Donna"], starRating: 3,
                               readiness: "playable;audio=verified;format=safe;date=known",
                               userPlace: place, userPlaceConfidence: confidence, backupAttestations: attestations)
    }

    /// A v2 (13-column) line: the v3 line with its last three cells dropped.
    private func v2Line(for r: ArchiveManifestCSV.Row) -> String {
        let fields = ArchiveManifestCSV.fields(ofLine: ArchiveManifestCSV.line(for: r))
        return fields.prefix(ArchiveManifestCSV.columnCountV2).map(ArchiveManifestCSV.escape).joined(separator: ",") + "\n"
    }

    @Test("SENSOR: a 12-column (v1) and a 13-column (v2) manifest validate, parse, rebuild (no place, no attestations) and accept v3 rows — header never rewritten")
    func legacyTwelveColumnManifestStillLoads() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("legacy12")
        defer { sb.cleanup() }
        _ = try VideoScanModel.scaffoldMasterArchive(rootURL: sb.archiveRoot)
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)

        // v1: 12 columns.
        let legacySource = UUID()
        let legacyRow = row("30_Video/Undated/xxxx-xx-xx_old.mov", source: legacySource)
        try (MasterArchiveLayout.manifestHeaderLegacy + "\n" + ArchiveManifestCSV.line(for: legacyRow, legacy: true))
            .write(to: sb.manifestURL, atomically: true, encoding: .utf8)
        #expect(throws: Never.self) { try ArchiveManifestCSV.validate(rootPath: sb.archiveRoot.path) }
        var fields = try #require(ArchiveManifestCSV.fieldRowsBySource(rootPath: sb.archiveRoot.path)[legacySource])
        #expect(fields.count == ArchiveManifestCSV.columnCountLegacy)
        var extra = ArchiveManifestCSV.placeAndAttestations(fromFields: fields)
        #expect(extra.place == nil && extra.confidence == nil && extra.attestations.isEmpty)
        let rebuilt = model.registerOrphanPromotedCopy(
            sourceID: legacySource, sourcePath: legacyRow.originalPath,
            destinationURL: sb.archiveRoot.appendingPathComponent(legacyRow.archiveRelPath),
            relativePath: legacyRow.archiveRelPath, sha256: "s", probed: VideoRecord(), manifestRow: fields)
        #expect(rebuilt.userDate == "1992-07-15" && rebuilt.detectedPeople == ["Donna"], "the v1 columns still rebuild")
        #expect(rebuilt.userPlace == nil && rebuilt.userPlaceConfidence == nil && rebuilt.backupAttestations.isEmpty)

        // Append a v3 row to the v1 file: header untouched, new row has 16 cells, both rows read.
        let newSource = UUID()
        try ArchiveManifestCSV.append(row("30_Video/Undated/xxxx-xx-xx_new.mov", source: newSource,
                                          place: "Franklin, MA", confidence: "known",
                                          attestations: BackupAttestation.jsonString(familyWord)),
                                      rootPath: sb.archiveRoot.path)
        let text = try String(contentsOf: sb.manifestURL, encoding: .utf8)
        #expect(text.hasPrefix(MasterArchiveLayout.manifestHeaderLegacy + "\n"), "header NOT rewritten")
        let rows = MasterArchiveTestSupport.manifestRows(sb)
        #expect(rows.map(\.count) == [ArchiveManifestCSV.columnCountLegacy, ArchiveManifestCSV.columnCount])
        #expect(ArchiveManifestCSV.rowsBySource(rootPath: sb.archiveRoot.path).count == 2, "parsers read both shapes")
        #expect(VerifyArchiveManifestIndex.parse(text: text).rowCount == 2, "Verify reads both shapes")

        // v2: 13 columns (readiness), same story.
        let v2Source = UUID()
        let v2Row = row("30_Video/Undated/xxxx-xx-xx_v2.mov", source: v2Source)
        try (MasterArchiveLayout.manifestHeaderV2 + "\n" + v2Line(for: v2Row))
            .write(to: sb.manifestURL, atomically: true, encoding: .utf8)
        #expect(throws: Never.self) { try ArchiveManifestCSV.validate(rootPath: sb.archiveRoot.path) }
        fields = try #require(ArchiveManifestCSV.fieldRowsBySource(rootPath: sb.archiveRoot.path)[v2Source])
        #expect(fields.count == ArchiveManifestCSV.columnCountV2)
        #expect(fields[ArchiveManifestCSV.readinessColumn] == v2Row.readiness)
        extra = ArchiveManifestCSV.placeAndAttestations(fromFields: fields)
        #expect(extra.place == nil && extra.attestations.isEmpty)
        #expect(MasterArchiveLayout.acceptedManifestHeaders.count == 3)
        #expect(MasterArchiveLayout.manifestFormatVersion == 3)
        #expect(MasterArchiveLayout.manifestHeader.hasSuffix(",readiness,user_place,user_place_confidence,backup_attestations"))
    }

    @Test("SENSOR: the v3 trailing columns round-trip through the CSV quoting (JSON with commas and quotes) and rebuild the copy's place, confidence and attestations")
    func manifestRoundTripsPlaceAndAttestations() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("v3rt")
        defer { sb.cleanup() }
        _ = try VideoScanModel.scaffoldMasterArchive(rootURL: sb.archiveRoot)
        #expect(try String(contentsOf: sb.manifestURL, encoding: .utf8) == MasterArchiveLayout.manifestHeader + "\n",
                "a fresh archive carries the v3 header")
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)

        let source = UUID()
        let json = BackupAttestation.jsonString(familyWord)
        #expect(json.contains(",") && json.contains("\""), "the JSON exercises both CSV specials")
        let r = row("30_Video/1990-1999/1992/1992-07-15_Reel.mov", source: source,
                    place: "Franklin, MA", confidence: "known", attestations: json)
        try ArchiveManifestCSV.append(r, rootPath: sb.archiveRoot.path)
        try ArchiveManifestCSV.append(row("30_Video/Undated/xxxx-xx-xx_bare.mov"), rootPath: sb.archiveRoot.path)

        let text = try String(contentsOf: sb.manifestURL, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 3, "header + one physical line per row")
        let fields = try #require(ArchiveManifestCSV.fieldRowsBySource(rootPath: sb.archiveRoot.path)[source])
        #expect(fields.count == ArchiveManifestCSV.columnCount)
        #expect(fields[ArchiveManifestCSV.userPlaceColumn] == "Franklin, MA")
        #expect(fields[ArchiveManifestCSV.userPlaceConfidenceColumn] == "known")
        #expect(fields[ArchiveManifestCSV.backupAttestationsColumn] == json, "the JSON comes back byte-identical")
        let extra = ArchiveManifestCSV.placeAndAttestations(fromFields: fields)
        #expect(extra.place == "Franklin, MA" && extra.confidence == "known")
        #expect(extra.attestations == familyWord)

        // A bare v3 row: empty cells, not "[]".
        let rows = MasterArchiveTestSupport.manifestRows(sb)
        #expect(rows[1][ArchiveManifestCSV.userPlaceColumn] == "" && rows[1][ArchiveManifestCSV.backupAttestationsColumn] == "")
        #expect(ArchiveManifestCSV.placeAndAttestations(fromFields: rows[1]).attestations.isEmpty)

        // Rebuild from the row (the source-gone path) restores all three.
        let rebuilt = model.registerOrphanPromotedCopy(
            sourceID: source, sourcePath: r.originalPath,
            destinationURL: sb.archiveRoot.appendingPathComponent(r.archiveRelPath),
            relativePath: r.archiveRelPath, sha256: "s", probed: VideoRecord(), manifestRow: fields)
        #expect(rebuilt.userPlace == "Franklin, MA")
        #expect(rebuilt.userPlaceConfidence == "known")
        #expect(rebuilt.backupAttestations == familyWord)
        // A place with an EMPTY confidence cell rebuilds as estimated (the conservative default).
        var noConf = fields; noConf[ArchiveManifestCSV.userPlaceConfidenceColumn] = ""
        #expect(ArchiveManifestCSV.placeAndAttestations(fromFields: noConf).confidence == UserPlaceConfidence.estimated.rawValue)
        // Verify's index and the archivedAt backfill still parse the file.
        #expect(VerifyArchiveManifestIndex.parse(text: text).rowCount == 2)
        #expect(ArchivedAtBackfill.manifestDates(text: text).count == 2)
    }

    @Test("SENSOR: a real Promote carries the source's attestations onto the copy AND into the manifest row (no ffmpeg needed)")
    func promotedCopyInheritsAttestations() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("attpromote")
        defer { sb.cleanup() }
        let src = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_att.mov"), bytes: 8192, seed: 11)
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path, userDate: "1992-07-15")
        rec.userPlace = "Cape Cod"; rec.userPlaceConfidence = "estimated"
        rec.backupAttestations = familyWord
        model.records = [rec]

        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        guard case .finished = job.state else { Issue.record("\(job.state)"); return }
        let copy = try #require(model.masterArchiveCopy(of: rec))
        #expect(copy.backupAttestations == familyWord)
        #expect(copy.userPlace == "Cape Cod" && copy.userPlaceConfidence == "estimated")
        let row = try #require(MasterArchiveTestSupport.manifestRows(sb).first)
        #expect(row.count == ArchiveManifestCSV.columnCount)
        #expect(row[ArchiveManifestCSV.userPlaceColumn] == "Cape Cod")
        #expect(row[ArchiveManifestCSV.userPlaceConfidenceColumn] == "estimated")
        #expect(BackupAttestation.fromJSONString(row[ArchiveManifestCSV.backupAttestationsColumn]) == familyWord)
        // An unplaced, unattested source writes empty trailing cells.
        let bare = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_bare.mov"), bytes: 4096, seed: 12)
        let bareRec = MasterArchiveTestSupport.makeRecord(path: bare.path)
        model.records.append(bareRec)
        let job2 = try #require(await MasterArchiveTestSupport.promote(model, ids: [bareRec.id]))
        guard case .finished = job2.state else { Issue.record("\(job2.state)"); return }
        let rows = MasterArchiveTestSupport.manifestRows(sb)
        #expect(rows.count == 2)
        let bareRow = try #require(rows.first { $0[ArchiveManifestCSV.sourceRecordIDColumn] == bareRec.id.uuidString })
        #expect(bareRow[ArchiveManifestCSV.userPlaceColumn] == "" && bareRow[ArchiveManifestCSV.userPlaceConfidenceColumn] == ""
                && bareRow[ArchiveManifestCSV.backupAttestationsColumn] == "")
    }
}

// MARK: - recordAttestation (model) + isolation

@Suite("Backup attestations — recordAttestation", .serialized)
@MainActor
struct BackupAttestationModelTests {

    private func rec(_ name: String) -> VideoRecord {
        let r = VideoRecord(); r.filename = name; r.fullPath = "/Volumes/T/\(name)"; r.directory = "/Volumes/T"
        return r
    }

    /// Record-scoped `.videoScanCatalogMutated` posts, captured for the
    /// duration of `body`.
    private func capturingMutations(_ body: () -> Void) -> [VideoRecord] {
        var seen: [VideoRecord] = []
        let token = NotificationCenter.default.addObserver(forName: .videoScanCatalogMutated, object: nil, queue: nil) { note in
            if let r = note.object as? VideoRecord { seen.append(r) }
        }
        body()
        NotificationCenter.default.removeObserver(token)
        return seen
    }

    @Test("replaces the same kind, keeps the others, trims the label, skips unknown ids, posts one record-scoped mutation per record, journals one line per record")
    func recordAttestationWritesJournalsAndAnnounces() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("attmodel")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let a = rec("a.mov"), b = rec("b.mov")
        let earlier = Date(timeIntervalSince1970: 1_757_600_000)
        a.backupAttestations = [BackupAttestation(kind: .cloud, answer: .no, attestedAt: earlier),
                                BackupAttestation(kind: .drive, answer: .yes, label: "MyBook", attestedAt: earlier)]
        model.records = [a, b]
        let at = Date(timeIntervalSince1970: 1_757_700_000)

        var write: BackupAttestationWrite?
        let posted = capturingMutations {
            write = model.recordAttestation(kind: .cloud, answer: .yes, label: "  iCloud ", at: at, for: [a.id, UUID(), b.id])
        }
        let written = write?.records ?? []
        #expect(written.map(\.filename) == ["a.mov", "b.mov"], "unknown id skipped")
        #expect(posted.map(\.filename) == ["a.mov", "b.mov"], "one RECORD-SCOPED post per written record")
        #expect(a.backupAttestations.map(\.token) == ["cloud=yes 'iCloud'", "drive=yes 'MyBook'"], "cloud replaced, drive kept, kind order")
        #expect(b.backupAttestations.map(\.token) == ["cloud=yes 'iCloud'"])
        #expect(a.backupAttestation(for: .cloud)?.attestedAt == at)
        #expect(a.backupAttestation(for: .cloud)?.by == "rick")

        // The archive journal (written off-main; awaited here): one line
        // per record, the human line inside.
        await write?.flush?.value
        let entries = ArchiveAttestationJournal.entries(rootPath: sb.archiveRoot.path)
        #expect(entries.count == 2)
        #expect(entries.map(\.line) == ["attestation cloud=yes 'iCloud' by rick", "attestation cloud=yes 'iCloud' by rick"])
        #expect(entries.map(\.recordID) == [a.id, b.id])
        #expect(entries.first?.filename == "a.mov" && entries.first?.fullPath == "/Volumes/T/a.mov")
        #expect(entries.first?.kind == "cloud" && entries.first?.answer == "yes" && entries.first?.label == "iCloud")
        let raw = try String(contentsOf: ArchiveAttestationJournal.url(rootPath: sb.archiveRoot.path), encoding: .utf8)
        #expect(raw.split(separator: "\n").count == 2, "JSONL: one physical line per entry")
        #expect(raw.contains("\"line\":\"attestation cloud=yes 'iCloud' by rick\""))

        // A "no" and an "n/a" are answers: recorded, journaled, and they replace a "yes".
        let w2 = model.recordAttestation(kind: .cloud, answer: .notApplicable, at: at.addingTimeInterval(60), for: [b.id])
        let w3 = model.recordAttestation(kind: .offsite, answer: .no, label: "", at: at.addingTimeInterval(60), for: [b.id])
        #expect(b.backupAttestations.map(\.token) == ["cloud=n/a", "offsite=no"], "empty label → none")
        await w2.flush?.value
        await w3.flush?.value
        #expect(ArchiveAttestationJournal.entries(rootPath: sb.archiveRoot.path).map(\.line).suffix(2)
                == ["attestation cloud=n/a by rick", "attestation offsite=no by rick"])
        // The promote journal is untouched by attestation lines.
        #expect(ArchivePromoteJournal.latestBySource(rootPath: sb.archiveRoot.path).isEmpty)
    }

    @Test("no designated archive: the record is still written and announced; nothing is journaled anywhere")
    func recordAttestationWithoutArchive() async {
        let model = VideoScanModel()
        let a = rec("a.mov")
        model.records = [a]
        #expect(model.masterArchiveRootPath == nil)
        var write: BackupAttestationWrite?
        let posted = capturingMutations {
            write = model.recordAttestation(kind: .offsite, answer: .yes, label: "Tim's", for: [a.id])
        }
        #expect(posted.count == 1)
        #expect(a.backupAttestations.map(\.token) == ["offsite=yes 'Tim's'"])
        #expect(write?.flush != nil, "the console batch still flushes off-main even with no archive")
        await write?.flush?.value
    }

    @Test("ISOLATION (poisoned-state): a real-looking archive tree is byte-identical after the whole flow — every write lands under the INJECTED root")
    func poisonedRealLookingArchiveIsNeverTouched() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("attpoison")
        defer { sb.cleanup() }
        // The decoy: shaped like Rick's archive (Volumes/FamilyArchive/Breen_Family_Archive/00_Index),
        // with a v2 manifest, a promote journal and an attestation journal already inside.
        let decoyVolume = sb.root.appendingPathComponent("Volumes/FamilyArchive", isDirectory: true)
        try FileManager.default.createDirectory(at: decoyVolume, withIntermediateDirectories: true)
        let decoyRoot = MasterArchiveLayout.rootURL(forTargetPath: decoyVolume.path)
        _ = try VideoScanModel.scaffoldMasterArchive(rootURL: decoyRoot)
        try (MasterArchiveLayout.manifestHeaderV2 + "\n").write(to: MasterArchiveLayout.manifestURL(rootPath: decoyRoot.path),
                                                                atomically: true, encoding: .utf8)
        try "{\"poison\":true}\n".write(to: ArchiveAttestationJournal.url(rootPath: decoyRoot.path), atomically: true, encoding: .utf8)
        try "{\"poison\":true}\n".write(to: ArchivePromoteJournal.url(rootPath: decoyRoot.path), atomically: true, encoding: .utf8)
        func fingerprint(_ dir: URL) -> [String: Int] {
            var out: [String: Int] = [:]
            let e = FileManager.default.enumerator(atPath: dir.path)
            while let rel = e?.nextObject() as? String {
                let full = dir.appendingPathComponent(rel).path
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
                out[rel] = (try? Data(contentsOf: URL(fileURLWithPath: full)))?.hashValue ?? -1
            }
            return out
        }
        let before = fingerprint(decoyVolume)
        #expect(before.count >= 4, "decoy has manifest, README, both journals")

        // The flow, against the INJECTED sandbox root only.
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        #expect(model.masterArchiveRootPath == sb.archiveRoot.path, "the injected root is the only root")
        let src = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_p.mov"), bytes: 4096, seed: 3)
        let r = MasterArchiveTestSupport.makeRecord(path: src.path, userDate: "1991")
        model.records = [r]
        let write = model.recordAttestation(kind: .cloud, answer: .yes, label: "iCloud", for: [r.id])
        await write.flush?.value
        #expect(ArchiveAttestationJournal.entries(rootPath: sb.archiveRoot.path).count == 1, "the line landed under the injected root")

        #expect(fingerprint(decoyVolume) == before, "the real-looking tree is byte-for-byte unchanged")
        #expect(ArchiveAttestationJournal.entries(rootPath: decoyRoot.path).isEmpty, "the decoy journal has only its poison line (unparseable)")
        #expect(try String(contentsOf: MasterArchiveLayout.manifestURL(rootPath: decoyRoot.path), encoding: .utf8)
                == MasterArchiveLayout.manifestHeaderV2 + "\n", "the decoy's v2 header was never bumped")
    }
}

// MARK: - CSV export

@Suite("Backup attestations — CSV export")
@MainActor
struct BackupAttestationCSVTests {

    @Test("the catalog CSV carries a Backup Attestations column before Place; Notes stays last; the cell is the summary token")
    func csvColumn() {
        let h = CatalogCSVWriter.headers
        #expect(h.suffix(4) == ["Backup Attestations", "Place", "Place Confidence", "Notes"])
        let r = VideoRecord(); r.filename = "clip.mov"; r.fullPath = "/Volumes/T/clip.mov"; r.notes = "n"
        r.userPlace = "Cape Cod"; r.userPlaceConfidence = "known"
        r.backupAttestations = [BackupAttestation(kind: .offsite, answer: .no), BackupAttestation(kind: .cloud, answer: .yes, label: "iCloud")]
        let row = CatalogCSVWriter.row(for: r)
        #expect(row.hasSuffix("cloud=yes 'iCloud'; offsite=no,Cape Cod,known,n"), "\(row)")
        // A label with a comma is quoted, and the Notes column is still last.
        r.backupAttestations = [BackupAttestation(kind: .cloud, answer: .yes, label: "Dropbox, shared")]
        #expect(CatalogCSVWriter.row(for: r).hasSuffix("\"cloud=yes 'Dropbox, shared'\",Cape Cod,known,n"))
        let bare = CatalogCSVWriter.row(for: VideoRecord())
        #expect(bare.hasSuffix(",,,"), "never-asked, unplaced → three empty cells before an empty Notes")
        #expect(CatalogCSVWriter.csvText(records: [r]).split(separator: "\n").count == 2)
    }
}

// MARK: - Protection summary over the model (scale)

@Suite("Backup attestations — protection summary scale", .serialized)
@MainActor
struct BackupAttestationProtectionScaleTests {

    @Test("SCALE: protectionSummary over 100k records × 5k content groups, computed once per batch, under budget")
    func protectionSummaryAtScale() {
        // 5k groups × 20 records: 1 verified archive copy (derivedFrom the
        // group's first source, no contentHash — the promote link joins it)
        // + 19 working copies sharing a contentHash over 6 volumes, every
        // 7th offline, every 3rd group attested on its first copy.
        // ~100k VideoRecords (~100 MB) — the same shape UserPlaceTests uses.
        let volumes = ["LaCie", "Projects", "MyBook", "X9", "X10", "Movies"]
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        var batch: [UUID] = []
        batch.reserveCapacity(5_000)
        let at = Date(timeIntervalSince1970: 1_757_700_000)
        for g in 0..<5_000 {
            var firstID: UUID?
            for c in 0..<19 {
                let r = VideoRecord()
                let vol = volumes[(g + c) % volumes.count]
                r.filename = "g\(g)_c\(c).mov"; r.fullPath = "/Volumes/\(vol)/g\(g)_c\(c).mov"; r.scanContext.volumeName = vol
                r.contentHash = "v1:\(g)"
                if c == 0 {
                    firstID = r.id
                    batch.append(r.id)
                    if g % 3 == 0 {
                        r.backupAttestations = [BackupAttestation(kind: .cloud, answer: .yes, label: "iCloud", attestedAt: at),
                                                BackupAttestation(kind: .offsite, answer: .no, attestedAt: at)]
                    }
                }
                records.append(r)
            }
            let copy = VideoRecord()
            copy.filename = "g\(g)_archive.mov"; copy.fullPath = "/Volumes/FamilyArchive/Breen_Family_Archive/30_Video/g\(g).mov"
            copy.scanContext.volumeName = "FamilyArchive"
            copy.derivedFrom = firstID; copy.derivationKind = ArchivePromotion.derivationKind
            copy.archiveFixity = ArchiveFixity(digest: "d", verifiedAt: at, sizeBytes: 1)
            records.append(copy)
        }
        let model = VideoScanModel()
        model.records = records
        #expect(model.records.count == 100_000)

        let clock = ContinuousClock()
        var summary = ProtectionSummary.empty
        let elapsed = clock.measure {
            summary = model.protectionSummary(for: batch) { r in (r.fullPath.hashValue % 7) != 0 }
        }
        #expect(summary.familyCount == 5_000)
        #expect(summary.workingCopyCount == 95_000)
        #expect(summary.archive == .verified, "the promote link joins every archive copy to its group")
        #expect(summary.cloud == .mixed && summary.offsite == .mixed)
        #expect(Set(summary.workingVolumesOnline + summary.workingVolumesOffline) == Set(volumes))
        #expect(summary.displayLine.hasPrefix("Archive ✓verified · 95000 working copies ("))
        #expect(elapsed < .seconds(3), "protectionSummary took \(elapsed) for 100k records × 5k groups")

        // A single-family batch reads like the design line.
        let one = model.protectionSummary(for: [batch[1]]) { _ in true }
        #expect(one.familyCount == 1 && one.workingCopyCount == 19 && one.archive == .verified)
        #expect(one.displayLine.hasSuffix("· cloud: none · off-site: none"))
        let attested = model.protectionSummary(for: [batch[0]]) { _ in true }
        #expect(attested.displayLine.hasSuffix("· cloud: iCloud · off-site: no"))
    }
}
