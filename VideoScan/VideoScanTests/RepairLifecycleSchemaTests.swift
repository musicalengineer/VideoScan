// RepairLifecycleSchemaTests.swift
// SCHEMA + SENSOR dimensions for the repair-lifecycle fields (GH #132):
// supersededByID (on the original) / repairConfirmedDate (on the repair).
//
//   * Byte-identity — never-superseded / never-confirmed records (all
//     legacy records) round-trip BYTE-IDENTICAL through the DTO (the
//     additive-Codable contract, audioVerify* precedent); lifecycle
//     records round-trip losslessly.
//   * Clone parity — snapshotClone/deepCopySnapshot carry both fields
//     (the off-main save must never drop a confirm or a supersede).
//   * Derived helpers — isSuperseded / isAwaitingConfirmation truth
//     tables, including the repair-kind gate (trim/balance derivatives
//     are NOT repairs).
//   * Journey-stamp lock-step SENSOR — "Confirm <ISO8601>: …" is
//     classified MACHINE by UserNotesMigration (the verb was appended to
//     journeyStampVerbs in the SAME commit that introduces the stamps —
//     the a769988 lock-step rule).
//   * Rescan-never-resurrects SENSOR — RescanPreservedFields carries
//     both fields, so a routine rescan can never resurrect a superseded
//     original into the default view nor un-confirm a confirmed repair
//     (same contract as setAsideReason).

import Testing
import Foundation
@testable import VideoScan

// MARK: - Codable schema

@Suite("RepairLifecycle — Codable schema")
@MainActor
struct RepairLifecycleCodableTests {

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

    @Test func normalRecordEmitsNoLifecycleKeysAndRoundTripsByteIdentical() throws {
        let r = VideoRecord()
        r.filename = "legacy.mov"
        r.fullPath = "/Volumes/T/legacy.mov"
        r.notes = "Verify Audio 2026-07-24T18:00:12Z: rebuilt audio track"

        let first = try goldenEncoder().encode(VideoRecordDTO(r))
        let firstJSON = String(decoding: first, as: UTF8.self)
        #expect(!firstJSON.contains("supersededByID")
                    && !firstJSON.contains("repairConfirmedDate"),
                "never-superseded / never-confirmed records must not grow lifecycle keys — legacy catalogs stay byte-identical")

        let decoded = try decoder().decode(VideoRecord.self, from: first)
        #expect(decoded.supersededByID == nil)
        #expect(decoded.repairConfirmedDate == nil)
        let second = try goldenEncoder().encode(VideoRecordDTO(decoded))
        #expect(first == second,
                "never-superseded round trip drifted — a lifecycle key is leaking into legacy JSON")
    }

    @Test func supersededOriginalRoundTripsLosslessly() throws {
        let repairID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let r = VideoRecord()
        r.filename = "original.mov"
        r.fullPath = "/Volumes/T/original.mov"
        r.supersededByID = repairID

        let data = try goldenEncoder().encode(VideoRecordDTO(r))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"supersededByID\":\"44444444-4444-4444-4444-444444444444\""))
        #expect(!json.contains("repairConfirmedDate"),
                "an original carries supersededByID only — per-field gating, not all-or-nothing")

        let decoded = try decoder().decode(VideoRecord.self, from: data)
        #expect(decoded.supersededByID == repairID)
        #expect(try goldenEncoder().encode(VideoRecordDTO(decoded)) == data)
    }

    @Test func confirmedRepairRoundTripsLosslessly() throws {
        let r = VideoRecord()
        r.filename = "repair.mov"
        r.fullPath = "/Volumes/T/repair.mov"
        r.derivedFrom = UUID()
        r.derivationKind = "rebuildAudio"
        // Whole seconds: .iso8601 truncates sub-second precision, so a
        // fractional Date would fail equality for the wrong reason.
        r.repairConfirmedDate = Date(timeIntervalSince1970: 1_753_400_000)

        let data = try goldenEncoder().encode(VideoRecordDTO(r))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"repairConfirmedDate\":"))
        #expect(!json.contains("supersededByID"))

        let decoded = try decoder().decode(VideoRecord.self, from: data)
        #expect(decoded.repairConfirmedDate == r.repairConfirmedDate)
        #expect(try goldenEncoder().encode(VideoRecordDTO(decoded)) == data)
    }

    @Test func legacyJSONWithoutKeysDecodesAsNormal() throws {
        let legacy = """
        {"id":"11111111-2222-3333-4444-555555555555",
         "filename":"clip.mov","fullPath":"/Volumes/T/clip.mov"}
        """
        let r = try decoder().decode(VideoRecord.self, from: Data(legacy.utf8))
        #expect(r.supersededByID == nil)
        #expect(r.repairConfirmedDate == nil)
        #expect(!r.isSuperseded)
        #expect(!r.isAwaitingConfirmation)
    }

    // MARK: Clone parity

    @Test func snapshotCloneCarriesBothLifecycleFields() throws {
        let r = VideoRecord()
        r.filename = "original.mov"
        r.fullPath = "/Volumes/T/original.mov"
        r.supersededByID = UUID()
        r.repairConfirmedDate = Date(timeIntervalSince1970: 1_753_400_000)

        let clone = r.snapshotClone()
        #expect(clone !== r)
        #expect(clone.supersededByID == r.supersededByID)
        #expect(clone.repairConfirmedDate == r.repairConfirmedDate)

        // Encode parity — the off-main save encodes CLONES; a missing
        // field here silently forgets a confirm/supersede in catalog.json.
        let a = try goldenEncoder().encode(VideoRecordDTO(r))
        let b = try goldenEncoder().encode(VideoRecordDTO(clone))
        #expect(a == b, "clone drifted from original for the repair-lifecycle fields")

        // deepCopySnapshot (the actual save path) too.
        let deep = try #require(CatalogStore.deepCopySnapshot(records: [r]).first)
        #expect(try goldenEncoder().encode(VideoRecordDTO(deep)) == a)
    }
}

// MARK: - Derived helpers

@Suite("RepairLifecycle — derived state")
@MainActor
struct RepairLifecycleDerivedTests {

    @Test func isSupersededTracksTheField() {
        let r = VideoRecord()
        #expect(!r.isSuperseded)
        r.supersededByID = UUID()
        #expect(r.isSuperseded)
        r.supersededByID = nil     // "Restore Original (Un-supersede)"
        #expect(!r.isSuperseded)
    }

    @Test func awaitingConfirmationRequiresRepairProvenance() {
        // Truth table over (derivedFrom, derivationKind, repairConfirmedDate).
        let plain = VideoRecord()
        #expect(!plain.isAwaitingConfirmation, "original records never await confirmation")

        let rebuilt = VideoRecord()
        rebuilt.derivedFrom = UUID()
        rebuilt.derivationKind = "rebuildAudio"
        #expect(rebuilt.isAwaitingConfirmation)

        let adopted = VideoRecord()
        adopted.derivedFrom = UUID()
        adopted.derivationKind = "externalRepair"
        #expect(adopted.isAwaitingConfirmation)

        // Confirming ends the wait.
        rebuilt.repairConfirmedDate = Date()
        #expect(!rebuilt.isAwaitingConfirmation)

        // Non-repair derivatives (trim / balance / cleanup outputs)
        // must NEVER enter the confirm worklist.
        for kind in ["trim", "balanceAudio", "cleanup", ""] {
            let d = VideoRecord()
            d.derivedFrom = UUID()
            d.derivationKind = kind.isEmpty ? nil : kind
            #expect(!d.isAwaitingConfirmation,
                    "derivationKind \(kind.isEmpty ? "nil" : kind) is not a repair")
        }

        // Repair kind without derivedFrom (defensive — malformed record).
        let orphanKind = VideoRecord()
        orphanKind.derivationKind = "rebuildAudio"
        #expect(!orphanKind.isAwaitingConfirmation)
    }

    @Test func repairKindsMatchTheWriters() {
        // Lock-step sensor: RebuildAudioFix.derivationKind must stay in
        // the repair-kind set — if the writer's constant drifts, repairs
        // stop entering the lifecycle silently.
        #expect(VideoRecord.repairDerivationKinds.contains(RebuildAudioFix.derivationKind))
        #expect(VideoRecord.repairDerivationKinds.count == 2)
    }
}

// MARK: - Journey-stamp lock-step sensor

@Suite("RepairLifecycle — Confirm stamp lock-step")
struct ConfirmJourneyStampTests {

    @Test func confirmStampIsClassifiedMachine() {
        // THE sensor: if "Confirm" ever falls out of
        // UserNotesMigration.journeyStampVerbs, this line flips human
        // and Confirm stamps start migrating into userNotes.
        let line = "Confirm 2026-07-24T00:00:00Z: whatever"
        #expect(UserNotesMigration.isJourneyStampLine(line[...]),
                "Confirm stamps must be machine — lock-step with journeyStampVerbs")
        #expect(UserNotesMigration.migrate(notes: line, userNotes: "") == nil)
    }

    /// The EXACT stamp shapes VideoScanModel+RepairLifecycle writes —
    /// if the writer's format changes, update journeyStampVerbs AND
    /// these fixtures together (the WorkflowTagsAndUserNotesTests rule).
    @Test func realConfirmStampsStayInNotes() {
        let stamps = [
            "Confirm 2026-07-24T18:00:12Z: repair confirmed by Rick — replaces Clip 05.mov",
            "Confirm 2026-07-24T18:00:12Z: superseded by Clip 05_RepairedAudio.mov — confirmed by Rick",
        ]
        for stamp in stamps {
            #expect(UserNotesMigration.migrate(notes: stamp, userNotes: "") == nil,
                    "journey stamp must NOT migrate: '\(stamp)'")
        }
    }

    @Test func humanNotesMentioningConfirmStillMigrate() {
        // Verb without the ISO-date shape = human text.
        let humans = [
            "Confirm with Donna which tape this is",
            "confirm 2026-07-24T00:00:00Z: lowercase is not the writer",
            "Confirm2026-07-24T00:00:00Z: missing space",
            "Confirm someday: no date",
        ]
        for note in humans {
            let result = UserNotesMigration.migrate(notes: note, userNotes: "")
            #expect(result?.userNotes == note && result?.notes.isEmpty == true,
                    "human note must migrate intact: '\(note)'")
        }
    }
}

// MARK: - Rescan-never-resurrects sensor

@Suite("RepairLifecycle — rescan preservation")
@MainActor
struct RepairLifecycleRescanTests {

    @Test func snapshotCarriesLifecycleFieldsAndIsWorthRestoring() {
        // A superseded original whose ONLY curated state is the supersede
        // — the snapshot must still be worth restoring, or the rescan
        // merge would drop it and resurrect the record.
        let original = VideoRecord()
        original.filename = "original.mov"
        original.fullPath = "/Volumes/T/original.mov"
        original.supersededByID = UUID()
        let snap = RescanPreservedFields(from: original)
        #expect(snap.isWorthRestoring,
                "supersede alone must make a snapshot worth restoring")

        let confirmed = VideoRecord()
        confirmed.repairConfirmedDate = Date()
        #expect(RescanPreservedFields(from: confirmed).isWorthRestoring,
                "a confirm date alone must make a snapshot worth restoring")
    }

    @Test func rescanNeverResurrectsASupersededOriginal() {
        // SENSOR (same contract as setAsideReason): startTarget removes
        // records under the target then re-creates them from disk. A
        // brand-new instance has supersededByID == nil — apply() must
        // restore the supersede or the retired original pops back into
        // the default catalog view on every routine rescan.
        let repairID = UUID()
        let old = VideoRecord()
        old.fullPath = "/Volumes/T/original.mov"
        old.supersededByID = repairID
        old.repairConfirmedDate = nil
        let snap = RescanPreservedFields(from: old)

        let fresh = VideoRecord()             // what the rescan produces
        fresh.fullPath = "/Volumes/T/original.mov"
        #expect(!fresh.isSuperseded)
        snap.apply(to: fresh)
        #expect(fresh.supersededByID == repairID,
                "rescan resurrected a superseded original — GH #132 sensor")
        #expect(fresh.isSuperseded)
    }

    @Test func rescanNeverUnconfirmsAConfirmedRepair() {
        let confirmedAt = Date(timeIntervalSince1970: 1_753_400_000)
        let old = VideoRecord()
        old.fullPath = "/Volumes/T/repair.mov"
        old.repairConfirmedDate = confirmedAt
        let snap = RescanPreservedFields(from: old)

        let fresh = VideoRecord()
        fresh.fullPath = "/Volumes/T/repair.mov"
        snap.apply(to: fresh)
        #expect(fresh.repairConfirmedDate == confirmedAt,
                "rescan dropped a repair confirmation — GH #132 sensor")
    }
}
