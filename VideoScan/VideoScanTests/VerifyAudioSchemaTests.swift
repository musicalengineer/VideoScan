// VerifyAudioSchemaTests.swift
// SCHEMA + SENSOR + ISOLATION dimensions for the Verify Audio verdict
// fields (GH #128): audioVerifyStatus / audioVerifyNote / audioVerifyDate.
//
//   * Byte-identity golden — never-verified records round-trip
//     BYTE-IDENTICAL through DTO encode/decode (the additive-Codable
//     contract: legacy catalog.json gains zero bytes and zero churn);
//     verified records round-trip losslessly.
//   * Clone parity — snapshotClone/deepCopySnapshot carry all three
//     fields (the off-main save must never drop a verdict).
//   * Journey-stamp lock-step SENSOR — "Verify Audio <ISO8601>: …" is
//     classified MACHINE by UserNotesMigration, using both a canonical
//     line and the EXACT strings RebuildAudioJob writes. This is the
//     sensor that stops stamps migrating into userNotes (the a769988
//     lock-step requirement).
//   * `notes:` token — audioVerifyNote joins the note:/notes: union,
//     field-prefix ONLY (machine state stays out of plain search).
//   * ISOLATION — the verdict persistence path (saveCatalogDebounced)
//     must never touch the real catalog from the test host (settings-
//     pollution class; CleanupIsolationTests pattern).

import Testing
import Foundation
@testable import VideoScan

// MARK: - DTO byte-identity + lossless round-trip

@Suite("VerifyAudio — Codable schema")
@MainActor
struct VerifyAudioCodableTests {

    /// Deterministic encoder — same shape as the CatalogStoreAsyncSaveTests
    /// golden guard (.sortedKeys so bytes are stable, .iso8601 dates like
    /// production).
    private func goldenEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    @Test func neverVerifiedRecordEmitsNoVerifyKeysAndRoundTripsByteIdentical() throws {
        let r = VideoRecord()
        r.filename = "legacy.mov"
        r.fullPath = "/Volumes/T/legacy.mov"
        r.notes = "[mov @ 0x0] moov atom not found"

        let first = try goldenEncoder().encode(VideoRecordDTO(r))
        let firstJSON = String(decoding: first, as: UTF8.self)
        #expect(!firstJSON.contains("audioVerify"),
                "never-verified records must not grow audioVerify keys — legacy catalogs stay byte-identical")

        // Decode → re-encode: byte-identical (the delta-minimal contract).
        let decoded = try decoder().decode(VideoRecord.self, from: first)
        #expect(decoded.audioVerifyStatus == "")
        #expect(decoded.audioVerifyNote == "")
        #expect(decoded.audioVerifyDate == nil)
        let second = try goldenEncoder().encode(VideoRecordDTO(decoded))
        #expect(first == second,
                "never-verified round trip drifted — a verify key is leaking into legacy JSON")
    }

    @Test func verifiedRecordRoundTripsLosslessly() throws {
        let r = VideoRecord()
        r.filename = "damaged.mov"
        r.fullPath = "/Volumes/T/damaged.mov"
        r.audioVerifyStatus = "damaged"
        r.audioVerifyNote = "reference movie — media missing"
        // Whole seconds: .iso8601 truncates sub-second precision, so a
        // fractional Date would fail equality for the wrong reason.
        r.audioVerifyDate = Date(timeIntervalSince1970: 1_753_300_000)

        let first = try goldenEncoder().encode(VideoRecordDTO(r))
        let firstJSON = String(decoding: first, as: UTF8.self)
        #expect(firstJSON.contains("\"audioVerifyStatus\":\"damaged\""))
        #expect(firstJSON.contains("\"audioVerifyNote\":\"reference movie — media missing\""))
        #expect(firstJSON.contains("\"audioVerifyDate\":"))

        let decoded = try decoder().decode(VideoRecord.self, from: first)
        #expect(decoded.audioVerifyStatus == "damaged")
        #expect(decoded.audioVerifyNote == "reference movie — media missing")
        #expect(decoded.audioVerifyDate == r.audioVerifyDate)

        // And the re-encode is byte-identical: lossless, stable.
        #expect(try goldenEncoder().encode(VideoRecordDTO(decoded)) == first)
    }

    @Test func okVerdictWithEmptyNotePersistsStatusOnly() throws {
        // A clean verify persists status "ok" + date but NO note key —
        // the note gate is per-field, not all-or-nothing.
        let r = VideoRecord()
        r.filename = "fine.mov"
        r.audioVerifyStatus = "ok"
        r.audioVerifyDate = Date(timeIntervalSince1970: 1_753_300_000)
        let json = String(decoding: try goldenEncoder().encode(VideoRecordDTO(r)),
                          as: UTF8.self)
        #expect(json.contains("\"audioVerifyStatus\":\"ok\""))
        #expect(json.contains("\"audioVerifyDate\":"))
        #expect(!json.contains("audioVerifyNote"))

        let decoded = try decoder().decode(VideoRecord.self, from: Data(json.utf8))
        #expect(decoded.audioVerifyStatus == "ok")
        #expect(decoded.audioVerifyNote == "")
    }

    @Test func legacyJSONWithoutKeysDecodesAsNeverVerified() throws {
        // Hand-written legacy catalog JSON (pre-#128) — no version bump,
        // no migration, just "" / nil defaults.
        let legacy = """
        {"id":"11111111-2222-3333-4444-555555555555",
         "filename":"clip.mov","fullPath":"/Volumes/T/clip.mov"}
        """
        let r = try decoder().decode(VideoRecord.self, from: Data(legacy.utf8))
        #expect(r.audioVerifyStatus == "")
        #expect(r.audioVerifyNote == "")
        #expect(r.audioVerifyDate == nil)
    }

    // MARK: Clone parity

    @Test func snapshotCloneCarriesAllThreeVerifyFields() throws {
        let r = VideoRecord()
        r.filename = "v.mov"
        r.fullPath = "/Volumes/T/v.mov"
        r.audioVerifyStatus = "damaged"
        r.audioVerifyNote = "invalid codec (qdm2)"
        r.audioVerifyDate = Date(timeIntervalSince1970: 1_753_300_000)

        let clone = r.snapshotClone()
        #expect(clone !== r)
        #expect(clone.audioVerifyStatus == "damaged")
        #expect(clone.audioVerifyNote == "invalid codec (qdm2)")
        #expect(clone.audioVerifyDate == r.audioVerifyDate)

        // Encode parity — the off-main save encodes CLONES; a missing
        // field here silently drops verdicts from catalog.json.
        let a = try goldenEncoder().encode(VideoRecordDTO(r))
        let b = try goldenEncoder().encode(VideoRecordDTO(clone))
        #expect(a == b, "clone drifted from original for the audioVerify fields")

        // deepCopySnapshot (the actual save path) too.
        let deep = try #require(CatalogStore.deepCopySnapshot(records: [r]).first)
        #expect(try goldenEncoder().encode(VideoRecordDTO(deep)) == a)
    }
}

// MARK: - Journey-stamp lock-step sensor

@Suite("VerifyAudio — journey stamp lock-step")
struct VerifyAudioJourneyStampTests {

    @Test func verifyAudioStampIsClassifiedMachine() {
        // THE sensor: if "Verify Audio" ever falls out of
        // UserNotesMigration.journeyStampVerbs, this line flips human
        // and stamps start migrating into userNotes.
        let line = "Verify Audio 2026-07-24T00:00:00Z: whatever"
        #expect(UserNotesMigration.isJourneyStampLine(line[...]),
                "Verify Audio stamps must be machine — lock-step with journeyStampVerbs")
        #expect(UserNotesMigration.migrate(notes: line, userNotes: "") == nil)
    }

    /// The EXACT sourceNote/derivedNote shapes RebuildAudioJob writes —
    /// if the writer's format changes, update journeyStampVerbs AND
    /// these fixtures together (the WorkflowTagsAndUserNotesTests rule).
    @Test func realRebuildStampsStayInNotes() {
        let stamps = [
            "Verify Audio 2026-07-24T18:00:12Z: repaired copy written to Clip 05_RepairedAudio.mov",
            "Verify Audio 2026-07-24T18:00:12Z: rebuilt audio track from Clip 05.mov (invalid codec (qdm2))",
        ]
        for stamp in stamps {
            #expect(UserNotesMigration.migrate(notes: stamp, userNotes: "") == nil,
                    "journey stamp must NOT migrate: '\(stamp)'")
        }
    }

    @Test func humanNotesMentioningVerifyAudioStillMigrate() {
        // Verb without the ISO-date shape = human text.
        let humans = [
            "Verify Audio next week before deleting",
            "verify audio 2026-07-24T00:00:00Z: lowercase is not the writer",
            "Verify Audio2026-07-24T00:00:00Z: missing space",
            "Verify Audio someday: no date",
        ]
        for note in humans {
            let result = UserNotesMigration.migrate(notes: note, userNotes: "")
            #expect(result?.userNotes == note && result?.notes.isEmpty == true,
                    "human note must migrate intact: '\(note)'")
        }
    }
}

// MARK: - notes: token — audioVerifyNote joins the union, prefix-only

@Suite("VerifyAudio — notes: token")
@MainActor
struct VerifyAudioNotesTokenTests {

    private func record(verifyNote: String = "",
                        status: String = "") -> VideoRecord {
        let r = VideoRecord()
        r.filename = "clip.mov"
        r.fullPath = "/Volumes/T/clip.mov"
        r.directory = "/Volumes/T"
        r.audioVerifyNote = verifyNote
        r.audioVerifyStatus = status
        return r
    }

    @Test func notesTokenReachesAudioVerifyNote() {
        let r = record(verifyNote: "reference movie — media missing",
                       status: "damaged")
        // Both matchers, both prefix spellings — the batch-find surface.
        #expect(pfRecordFilenameOrPersonMatch(r, query: "notes:reference"))
        #expect(pfRecordFilenameOrPersonMatch(r, query: "note:missing"))
        #expect(pfRecordMatchesQuery(r, query: "notes:reference"))
        // And the extracted helper directly (value pre-lowercased).
        #expect(pfNotesFieldMatches(value: "reference", rec: r))
        #expect(!pfNotesFieldMatches(value: "zzz", rec: r))
    }

    @Test func notesTokenUnionStillCoversLegacyNotesAndUserNotes() {
        // The pfNotesFieldMatches extraction must not have dropped the
        // pre-existing two legs of the union.
        let legacy = record()
        legacy.notes = "[mov @ 0x0] moov atom not found"
        #expect(pfRecordFilenameOrPersonMatch(legacy, query: "note:moov"))
        let human = record()
        human.userNotes = "check the wedding audio"
        #expect(pfRecordFilenameOrPersonMatch(human, query: "notes:wedding"))
    }

    @Test func verifyNoteStaysOutOfPlainSearch() {
        // Field-prefix ONLY: the verdict is machine state. A casual
        // query must never surface it — via the narrow catalog matcher,
        // the universal matcher, or the search index.
        let r = record(verifyNote: "glorbex marker", status: "damaged")
        #expect(!pfRecordFilenameOrPersonMatch(r, query: "glorbex"))
        #expect(!pfRecordMatchesQuery(r, query: "glorbex"))

        let index = CatalogSearchIndex()
        index.rebuild(records: [r])
        #expect(index.filter(records: [r], query: "glorbex").isEmpty,
                "audioVerifyNote leaked into the plain-search haystack")
        #expect(index.filter(records: [r], query: "notes:glorbex").count == 1,
                "notes: opt-in must still reach the verdict note through the index")
    }
}

// MARK: - Isolation — verdict persistence never touches real state

@Suite("VerifyAudio — persistence isolation", .serialized)
@MainActor
struct VerifyAudioIsolationTests {

    private var realAppSupportVideoScan: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)
            .first?.appendingPathComponent("VideoScan", isDirectory: true)
    }

    /// rel-path → "size@mtime" for the real VideoScan Application
    /// Support tree (CleanupIsolationTests pattern).
    private func appSupportSnapshot() -> [String: String] {
        guard let root = realAppSupportVideoScan,
              let e = FileManager.default.enumerator(atPath: root.path) else { return [:] }
        var snap: [String: String] = [:]
        for case let rel as String in e {
            let full = root.appendingPathComponent(rel).path
            let attrs = (try? FileManager.default.attributesOfItem(atPath: full)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            snap[rel] = "\(size)@\(mtime)"
        }
        return snap
    }

    @Test func persistVerdictPathNeverWritesTheRealCatalog() async throws {
        // The seam the whole isolation story rests on: in the test host
        // CatalogStore.shared neither loads nor saves.
        #expect(TestEnvironment.isTestHost,
                "test host detection broke — every catalog write below would hit the REAL catalog")

        let before = appSupportSnapshot()

        // The sheet's persistVerdict flow: write the verdict fields,
        // then schedule the debounced save — plus the terminal saveNow
        // for good measure (both must be inert here).
        let model = VideoScanModel()
        let r = VideoRecord()
        r.filename = "damaged.mov"
        r.fullPath = "/Volumes/T/damaged.mov"
        model.records = [r]
        r.audioVerifyStatus = "damaged"
        r.audioVerifyNote = "reference movie — media missing"
        r.audioVerifyDate = Date()
        model.saveCatalogDebounced()
        model.saveCatalogNow()

        // Let any (buggy) debounce fire before checking.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(appSupportSnapshot() == before,
                "verdict persistence touched the REAL Application Support tree from a test")
    }
}
