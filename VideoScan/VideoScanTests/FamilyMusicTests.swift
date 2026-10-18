// FamilyMusicTests.swift
// The Family Music FEATURE (Archive-tab shelf, mark sheet, mark/unmark
// writers) was removed 2026-10-18 — Rick: "we'll never use it". The
// PERSISTED data it wrote is kept until Rick rules on the schema:
// `VideoRecord.familyMusic` (catalog.json + the SQLite `family_music`
// table / `row_knowledge`) and the `familyMusic` Media Ledger kind. These
// tests pin that existing marks still decode, round-trip, narrate and
// survive Update Catalog — removing the UI must not lose a byte of them.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Fixtures

@MainActor
private enum FM {
    static func model(_ label: String) throws -> (VideoScanModel, MasterArchiveTestSupport.Sandbox) {
        let sb = try MasterArchiveTestSupport.makeSandbox("music_\(label)")
        let m = MasterArchiveTestSupport.makeModel(sb)
        m.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        return (m, sb)
    }

    static func rec(_ name: String, dir: String = "/Volumes/Src/music",
                    stream: StreamType = .audioOnly, dur: Double = 187) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = dir + "/" + name
        r.directory = dir
        r.streamTypeRaw = stream.rawValue
        r.durationSeconds = dur
        r.sizeBytes = 1_000
        return r
    }
}

// MARK: - Persisted field

@Suite("Family Music — persisted field")
@MainActor
struct FamilyMusicFieldTests {

    @Test("legacy record decodes nil and re-encodes WITHOUT the key; a mark round-trips and rides the clone")
    func additiveField() throws {
        let legacy = #"{"id":"11111111-2222-3333-4444-555555555555","filename":"a.m4a","fullPath":"/V/a.m4a"}"#
        let r = try JSONDecoder().decode(VideoRecord.self, from: Data(legacy.utf8))
        #expect(r.familyMusic == nil)
        let out = String(bytes: try JSONEncoder().encode(VideoRecordDTO(r)), encoding: .utf8) ?? ""
        #expect(!out.isEmpty && !out.contains("familyMusic"), "\(out)")

        r.familyMusic = FamilyMusicInfo(performer: "Tim", title: "Blackbird",
                                        markedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(VideoRecord.self, from: enc.encode(VideoRecordDTO(r)))
        #expect(back.familyMusic == r.familyMusic)
        #expect(r.snapshotClone().familyMusic == r.familyMusic)
    }

    @Test("FamilyMusicInfo trims and turns blanks into nil")
    func infoCleaning() {
        let i = FamilyMusicInfo(performer: "  Tim ", title: " \n ")
        #expect(i.performer == "Tim")
        #expect(i.title == nil)
    }

    @Test("ledger vocabulary appended familyMusic after every older kind; narrator reads both actions")
    func ledgerVocabulary() {
        // Append-only vocabulary: familyMusic came after footageDecided, and
        // only kinds added later (Update…'s two, 2026-09-27) follow it.
        let kinds = MediaLedgerEvent.Kind.allCases
        let i = kinds.firstIndex(of: .familyMusic)
        #expect(i == kinds.firstIndex(of: .footageDecided).map { $0 + 1 })
        #expect(i.map { Array(kinds[($0 + 1)...]) } == [.archiveUpdated, .archiveUpdateRolledBack])
        #expect(MediaLedgerEvent.Kind.familyMusic.rawValue == "familyMusic")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let marked = MediaLedgerEvent(at: at, event: .familyMusic, recordID: UUID(), contentKey: "", filename: "a.m4a",
                                      fullPath: "/V/a.m4a", by: .rick, batchID: nil,
                                      detail: ["action": "marked", "performer": "Tim", "title": "Blackbird"])
        let s = LedgerNarrator.sentence(for: marked, dateText: "today")
        #expect(s.contains("family music") && s.contains("Blackbird") && s.contains("Tim"), "\(s)")
        let un = MediaLedgerEvent(at: at, event: .familyMusic, recordID: UUID(), contentKey: "", filename: "a.m4a",
                                  fullPath: "/V/a.m4a", by: .rick, batchID: nil, detail: ["action": "unmarked"])
        #expect(LedgerNarrator.sentence(for: un, dateText: "today").contains("off the Family Music shelf"))
    }
}

// MARK: - Sensors

@Suite("Family Music — sensors")
@MainActor
struct FamilyMusicSensorTests {

    @Test("Update Catalog keeps the mark: field snapshot is worth restoring and applies onto a fresh record")
    func familyMusicMarkSurvivesRescan() {
        let old = FM.rec("song.m4a")
        old.familyMusic = FamilyMusicInfo(performer: "Tim", title: "Blackbird")
        let snap = RescanPreservedFields(from: old)
        #expect(snap.isWorthRestoring, "a mark alone must be snapshotted")
        let fresh = FM.rec("song.m4a")
        _ = snap.apply(to: fresh)
        #expect(fresh.familyMusic == old.familyMusic)
    }

    @Test("Update Catalog keeps the mark end to end: snapshot → records wiped → fresh scan → apply")
    func familyMusicMarkSurvivesModelRescan() throws {
        let (m, sb) = try FM.model("rescan"); defer { sb.cleanup() }
        let target = CatalogScanTarget(searchPath: "/Volumes/Src")
        let old = FM.rec("song.m4a")
        old.familyMusic = FamilyMusicInfo(performer: "Tim", title: "Blackbird")
        m.records = [old]
        m.scanTargets = [target]
        m.snapshotPreservedFieldsForRescan(of: target)
        m.records.removeAll()
        let fresh = FM.rec("song.m4a")
        #expect(fresh.id != old.id)
        #expect(m.applyPreservedFieldsAfterRescan(of: target, onto: [fresh]) == 1)
        #expect(fresh.familyMusic?.performer == "Tim" && fresh.familyMusic?.title == "Blackbird")
    }
}
