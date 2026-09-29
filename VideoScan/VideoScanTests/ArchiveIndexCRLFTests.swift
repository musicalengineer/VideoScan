// ArchiveIndexCRLFTests.swift
// CRLF-terminated archive index text (the 00_Index manifest CSV and the
// JSONL journals) must read row-for-row like LF text, in EVERY reader.
//
// Why this can go wrong: in Swift "\r\n" is ONE Character (a grapheme
// cluster), so `text.split(separator: "\n")` never splits a CRLF record —
// a CRLF manifest reads as one giant line. (C++ analogy: splitting on a
// char that never appears, because the iterator yields multi-byte
// clusters, not bytes.) ArchiveLockJob was fixed first (codex r2 #3,
// e9277d5d); these pins cover the other readers, all now routed through
// ArchiveIndexText.lines.
//
// Filesystem: the on-disk readers get a throwaway `<tmp>/test_crlf_*/`
// archive root holding only `00_Index/`. Nothing else is touched.

import Foundation
import Testing
@testable import VideoScan

@Suite("Archive index CRLF — every reader splits \\n and \\r\\n")
struct ArchiveIndexCRLFTests {

    // MARK: Fixtures

    struct Row {
        let rel: String
        let recordID = UUID()
        let sourceID = UUID()
        var csv: String {
            "2026-09-27T00:00:00Z,\(rel),abc123,1,/x/\(rel),Vol,\(recordID.uuidString),\(sourceID.uuidString),1992-xx-xx,known,,3"
        }
    }

    static let rels = ["30_Video/1990-1999/1992/a.mov", "30_Video/1990-1999/1992/b.mov", "30_Video/1990-1999/1992/c.mov"]

    /// Three shapes: all CRLF; LF header then CRLF rows (the shape that
    /// passes openIndexFile's header check); and mixed per row.
    static func manifests(_ rows: [Row]) -> [(label: String, text: String)] {
        let header = MasterArchiveLayout.manifestHeaderLegacy
        let lines = [header] + rows.map(\.csv)
        return [
            ("all CRLF", lines.joined(separator: "\r\n") + "\r\n"),
            ("LF header, CRLF rows", header + "\n" + rows.map(\.csv).joined(separator: "\r\n") + "\r\n"),
            ("mixed LF/CRLF", header + "\n" + rows[0].csv + "\r\n" + rows[1].csv + "\n" + rows[2].csv + "\r\n"),
        ]
    }

    /// A bare archive root (`<tmp>/test_crlf_<label>_<8>/00_Index/`).
    static func makeRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_crlf_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(MasterArchiveLayout.indexFolder, isDirectory: true),
            withIntermediateDirectories: true)
        return root
    }

    static func write(_ text: String, name: String, root: URL) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(MasterArchiveLayout.indexFolder, isDirectory: true)
                                          .appendingPathComponent(name))
    }

    /// JSONL shapes for the journals: all CRLF, and mixed (LF, CRLF, LF).
    static func jsonl(_ lines: [String]) -> [(label: String, text: String)] {
        [("all CRLF", lines.joined(separator: "\r\n") + "\r\n"),
         ("mixed LF/CRLF", lines[0] + "\n" + lines[1] + "\r\n" + lines[2] + "\n")]
    }

    // MARK: Pure manifest parsers

    @Test("VerifyArchiveManifestIndex.parse: every CRLF / mixed row is indexed")
    func verifyIndexParse() {
        let rows = Self.rels.map { Row(rel: $0) }
        for (label, text) in Self.manifests(rows) {
            let index = VerifyArchiveManifestIndex.parse(text: text)
            #expect(Set(index.byRelPath.keys) == Set(Self.rels), "\(label): indexed \(index.byRelPath.keys.sorted())")
            #expect(Set(index.bySourceID.keys) == Set(rows.map(\.sourceID)), "\(label)")
            #expect(index.byRelPath[Self.rels[2]]?.sha256 == "abc123", "\(label): last row's digest")
        }
    }

    @Test("ArchivedAtBackfill.manifestDates: every CRLF / mixed row yields its date")
    func archivedAtManifestDates() {
        let rows = Self.rels.map { Row(rel: $0) }
        for (label, text) in Self.manifests(rows) {
            let dates = ArchivedAtBackfill.manifestDates(text: text)
            #expect(Set(dates.keys) == Set(rows.map(\.recordID)), "\(label): \(dates.count) date(s)")
        }
    }

    @Test("ArchiveRefile.parseRows: every CRLF / mixed row is a row, relpath exact (no trailing \\r)")
    func refileParseRows() {
        let rows = Self.rels.map { Row(rel: $0) }
        for (label, text) in Self.manifests(rows) {
            let parsed = ArchiveRefile.parseRows(text)
            #expect(parsed.map(\.relPath) == Self.rels, "\(label): \(parsed.map(\.relPath))")
            #expect(parsed.map(\.dateConfidence) == ["known", "known", "known"], "\(label)")
        }
    }

    @Test("ArchiveLockJob.plan: mixed LF/CRLF rows are all planned (already fixed by e9277d5d; now via the shared helper)")
    func lockPlanMixed() {
        let rows = Self.rels.map { Row(rel: $0) }
        for (label, text) in Self.manifests(rows) {
            guard case .success(let plan) = ArchiveLockJob.plan(manifestText: text, root: "/tmp/test_crlf_lock_root") else {
                Issue.record("\(label): plan refused"); continue
            }
            #expect(plan.relPaths == Self.rels, "\(label): planned \(plan.relPaths)")
            #expect(plan.skipped.isEmpty, "\(label): skipped \(plan.skipped.map(\.row))")
        }
    }

    // MARK: On-disk readers (through openIndexFile)

    @Test("ArchiveManifestCSV.fieldRowsBySource: CRLF rows after the LF header are all read; an all-CRLF header still refuses")
    func manifestFieldRowsBySource() throws {
        let rows = Self.rels.map { Row(rel: $0) }
        for (label, text) in Self.manifests(rows) {
            let root = try Self.makeRoot("fields")
            defer { try? FileManager.default.removeItem(at: root) }
            try Self.write(text, name: MasterArchiveLayout.manifestFilename, root: root)
            let bySource = ArchiveManifestCSV.fieldRowsBySource(rootPath: root.path)
            if label == "all CRLF" {
                // The header line reads "header\r" — not a recognized
                // header, so openIndexFile refuses (refuse-over-guess,
                // unchanged by this fix).
                #expect(bySource.isEmpty, "a CRLF header must still be refused")
                continue
            }
            #expect(Set(bySource.keys) == Set(rows.map(\.sourceID)), "\(label): \(bySource.count) row(s)")
            #expect(bySource[rows[2].sourceID]?[ArchiveManifestCSV.relPathColumn] == Self.rels[2], "\(label)")
            #expect(bySource.values.allSatisfy { !($0.last ?? "").hasSuffix("\r") }, "\(label): no field keeps a CR")
        }
    }

    @Test("ArchivePromoteJournal.latestBySource: every CRLF / mixed journal line is read")
    func promoteJournalLatestBySource() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601   // same encoder shape as ArchivePromoteJournal.append
        let ids = [UUID(), UUID(), UUID()]
        let lines = try zip(ids, Self.rels).map { id, rel in
            let e = ArchivePromoteJournal.Entry(sourceRecordID: id, sourcePath: "/x/\(rel)", destRelPath: rel,
                                                state: .done, sha256: "abc123", copyRecordID: UUID(),
                                                at: Date(timeIntervalSince1970: 1_790_000_000))
            return String(decoding: try encoder.encode(e), as: UTF8.self)
        }
        for (label, text) in Self.jsonl(lines) {
            let root = try Self.makeRoot("pjournal")
            defer { try? FileManager.default.removeItem(at: root) }
            try Self.write(text, name: ArchivePromoteJournal.filename, root: root)
            let latest = ArchivePromoteJournal.latestBySource(rootPath: root.path)
            #expect(Set(latest.keys) == Set(ids), "\(label): \(latest.count) entr(ies)")
            #expect(latest[ids[1]]?.destRelPath == Self.rels[1], "\(label)")
        }
    }

    @Test("ArchiveAttestationJournal.entries: every CRLF / mixed journal line is read, in order")
    func attestationJournalEntries() throws {
        let names = ["a.mov", "b.mov", "c.mov"]
        let lines = names.map { name in
            #"{"answer":"yes","at":"2025-09-12T18:00:00.250Z","by":"rick","filename":"\#(name)","fullPath":"/x/\#(name)","kind":"cloud","label":"iCloud","line":"attestation cloud=yes","recordID":"\#(UUID().uuidString)"}"#
        }
        for (label, text) in Self.jsonl(lines) {
            let root = try Self.makeRoot("ajournal")
            defer { try? FileManager.default.removeItem(at: root) }
            try Self.write(text, name: ArchiveAttestationJournal.filename, root: root)
            let entries = ArchiveAttestationJournal.entries(rootPath: root.path)
            #expect(entries.map(\.filename) == names, "\(label): \(entries.map(\.filename))")
        }
    }
}
