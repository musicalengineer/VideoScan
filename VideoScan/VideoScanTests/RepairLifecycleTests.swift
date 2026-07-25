// RepairLifecycleTests.swift
// LOGIC + SENSOR dimensions for the confirm + supersede heart of the
// repair lifecycle (GH #132 P2, Commit 4):
//
//   * Human-metadata inheritance field-by-field, including the
//     never-clobber rules (repair's own values win / merge).
//   * Confirm stamp shapes — the EXACT strings the writer produces must
//     classify MACHINE via UserNotesMigration (lock-step with the
//     "Confirm" verb added in Commit 1).
//   * The one-click transition: repairConfirmedDate + supersededByID +
//     visibility flip (original leaves pfActiveRecords).
//   * Undo restores EXACTLY (every inherited field, both notes, both
//     markers), missing-original no-op, second-confirm idempotence,
//     multi-select batch confirm + batch undo.

import Testing
import Foundation
@testable import VideoScan

@MainActor
@Suite("RepairLifecycle — confirm + supersede")
struct RepairLifecycleTests {

    // MARK: Fixtures

    /// An original + its awaiting-confirmation rebuild, wired the way
    /// RebuildAudioJob.catalogRebuildOutput wires them.
    private func makePair(
        model: VideoScanModel,
        suffix: String = ""
    ) -> (original: VideoRecord, repair: VideoRecord) {
        let original = VideoRecord()
        original.filename = "tape\(suffix).mov"
        original.fullPath = "/Volumes/T/tape\(suffix).mov"
        original.directory = "/Volumes/T"
        original.streamTypeRaw = StreamType.videoAndAudio.rawValue
        original.audioVerifyStatus = "damaged"
        original.audioVerifyNote = "Damaged audio — invalid codec (qdm2)"

        let repair = VideoRecord()
        repair.filename = "tape\(suffix)_RepairedAudio.mov"
        repair.fullPath = "/Volumes/T/tape\(suffix)_RepairedAudio.mov"
        repair.directory = "/Volumes/T"
        repair.streamTypeRaw = StreamType.videoAndAudio.rawValue
        repair.derivedFrom = original.id
        repair.derivationKind = "rebuildAudio"

        model.records.append(contentsOf: [original, repair])
        return (original, repair)
    }

    // MARK: Inheritance

    @Test func inheritanceCopiesHumanFieldsOntoABlankRepair() {
        let model = VideoScanModel()
        let (original, repair) = makePair(model: model)
        original.tags = ["Gold", "Follow Up"]
        original.userNotes = "the birthday tape"
        original.confirmedByUserPeople = [ConfirmedTag(name: "Donna", confirmedAt: Date())]
        original.rejectedPeople = ["Anna"]
        original.starRating = 3
        original.mediaDisposition = .important
        original.lifecycleStage = .archived
        original.archiveStage = .backedUp
        original.userDate = "1992-06"
        original.userDateConfidence = "known"

        model.applyHumanMetadataInheritance(from: original, to: repair)

        #expect(repair.tags == ["Gold", "Follow Up"])
        #expect(repair.userNotes == "the birthday tape")
        #expect(repair.confirmedByUserPeople.map(\.name) == ["Donna"])
        #expect(repair.rejectedPeople == ["Anna"])
        #expect(repair.starRating == 3)
        #expect(repair.mediaDisposition == .important)
        #expect(repair.lifecycleStage == .archived)
        #expect(repair.archiveStage == .backedUp)
        #expect(repair.userDate == "1992-06")
        #expect(repair.userDateConfidence == "known")
    }

    @Test func inheritanceNeverClobbersTheRepairsOwnValues() {
        let model = VideoScanModel()
        let (original, repair) = makePair(model: model)
        original.tags = ["Gold"]
        original.userNotes = "original note"
        original.starRating = 1
        original.mediaDisposition = .suspectedJunk
        original.userDate = "1992"
        original.userDateConfidence = "estimated"

        // Rick already curated the repair.
        repair.tags = ["Fix Audio", "gold"]           // "gold" ≈ "Gold" case-insensitively
        repair.userNotes = "repair note"
        repair.starRating = 2
        repair.mediaDisposition = .important
        repair.userDate = "1993"
        repair.userDateConfidence = "known"

        model.applyHumanMetadataInheritance(from: original, to: repair)

        #expect(repair.tags == ["Fix Audio", "gold"],
                "tag union must not duplicate a case-variant tag")
        #expect(repair.userNotes == "repair note\noriginal note",
                "existing repair notes keep the lead; original text appends")
        #expect(repair.starRating == 2, "starRating takes the max")
        #expect(repair.mediaDisposition == .important,
                "a non-default disposition on the repair is Rick's call — never overwritten")
        #expect(repair.userDate == "1993")
        #expect(repair.userDateConfidence == "known",
                "the repair's own hand-entered date wins")
    }

    @Test func inheritanceDoesNotCopyMachineNotes() {
        let model = VideoScanModel()
        let (original, repair) = makePair(model: model)
        original.notes = "[mov @ 0x0] moov atom not found"
        model.applyHumanMetadataInheritance(from: original, to: repair)
        #expect(repair.notes.isEmpty,
                "machine File Journey / probe notes are per-file — never inherited")
    }

    // MARK: Confirm

    @Test func confirmStampsInheritsAndSupersedes() throws {
        let model = VideoScanModel()
        let (original, repair) = makePair(model: model)
        original.tags = ["Gold"]

        #expect(model.confirmRepair(repairID: repair.id))

        // State machine.
        #expect(repair.repairConfirmedDate != nil)
        #expect(!repair.isAwaitingConfirmation)
        #expect(original.supersededByID == repair.id)
        #expect(original.isSuperseded)

        // Visibility flip: the original leaves every active surface.
        let active = pfActiveRecords(model.records)
        #expect(active.map(\.id) == [repair.id])
        // …but still travels in exports.
        #expect(pfExportableRecords(model.records).count == 2)

        // Inheritance ran.
        #expect(repair.tags == ["Gold"])

        // Stamp shapes — exact writer strings, machine-classified.
        let repairStamp = try #require(repair.notes.split(separator: "\n").last)
        #expect(repairStamp.hasPrefix("Confirm "))
        #expect(repairStamp.hasSuffix(": repair confirmed by Rick — replaces \(original.filename)"))
        #expect(UserNotesMigration.isJourneyStampLine(repairStamp),
                "the Confirm stamp must classify machine or it migrates into userNotes")

        let originalStamp = try #require(original.notes.split(separator: "\n").last)
        #expect(originalStamp.hasPrefix("Confirm "))
        #expect(originalStamp.hasSuffix(": superseded by \(repair.filename) — confirmed by Rick"))
        #expect(UserNotesMigration.isJourneyStampLine(originalStamp))

        // Undo banner armed.
        #expect(model.lastConfirmBatch?.snapshots.count == 1)
    }

    @Test func secondConfirmIsANoOp() {
        let model = VideoScanModel()
        let (original, repair) = makePair(model: model)
        #expect(model.confirmRepair(repairID: repair.id))
        let notesAfterFirst = repair.notes
        let confirmedAt = repair.repairConfirmedDate

        #expect(!model.confirmRepair(repairID: repair.id),
                "a confirmed repair is no longer awaiting — confirm must no-op")
        #expect(repair.notes == notesAfterFirst, "no duplicate stamp")
        #expect(repair.repairConfirmedDate == confirmedAt)
        #expect(original.supersededByID == repair.id)
    }

    @Test func confirmWithMissingOriginalIsACompleteNoOp() {
        let model = VideoScanModel()
        let repair = VideoRecord()
        repair.filename = "orphan_RepairedAudio.mov"
        repair.fullPath = "/Volumes/T/orphan_RepairedAudio.mov"
        repair.derivedFrom = UUID()          // original not in the catalog
        repair.derivationKind = "rebuildAudio"
        model.records = [repair]

        #expect(!model.confirmRepair(repairID: repair.id))
        #expect(repair.repairConfirmedDate == nil)
        #expect(repair.notes.isEmpty, "no half-applied stamp")
        #expect(model.lastConfirmBatch == nil, "no undo target armed for a no-op")
    }

    @Test func confirmOfANonRepairIsANoOp() {
        let model = VideoScanModel()
        let (original, trimmed) = makePair(model: model)
        trimmed.derivationKind = "trim"      // not a repair kind
        #expect(!model.confirmRepair(repairID: trimmed.id))
        #expect(!original.isSuperseded)
        #expect(!model.confirmRepair(repairID: UUID()), "bogus id no-ops too")
    }

    // MARK: Undo

    @Test func undoRestoresExactly() throws {
        let model = VideoScanModel()
        let (original, repair) = makePair(model: model)
        original.tags = ["Gold"]
        original.userNotes = "keeper"
        original.starRating = 3
        original.notes = "Verify Audio 2026-07-24T18:00:12Z: repaired copy written to tape_RepairedAudio.mov"
        repair.notes = "Verify Audio 2026-07-24T18:00:12Z: rebuilt audio track from tape.mov (invalid codec (qdm2))"
        let originalNotesBefore = original.notes
        let repairNotesBefore = repair.notes

        #expect(model.confirmRepair(repairID: repair.id))
        #expect(repair.tags == ["Gold"])   // inherited

        #expect(model.undoConfirmRepair())

        // Exact restore, field by field.
        #expect(repair.tags.isEmpty)
        #expect(repair.userNotes.isEmpty)
        #expect(repair.starRating == 0)
        #expect(repair.repairConfirmedDate == nil)
        #expect(repair.isAwaitingConfirmation)
        #expect(repair.notes == repairNotesBefore, "the Confirm stamp is removed, prior journey kept")
        #expect(original.supersededByID == nil)
        #expect(!original.isSuperseded)
        #expect(original.notes == originalNotesBefore)
        #expect(original.userNotes == "keeper", "the original's own fields were never touched")
        #expect(model.lastConfirmBatch == nil, "banner drops after undo")

        // Nothing left to undo.
        #expect(!model.undoConfirmRepair())
    }

    @Test func batchConfirmAndBatchUndo() {
        let model = VideoScanModel()
        let pairA = makePair(model: model, suffix: "A")
        let pairB = makePair(model: model, suffix: "B")
        let ids: Set<UUID> = [pairA.repair.id, pairB.repair.id]

        #expect(model.confirmRepairs(repairIDs: ids) == 2)
        #expect(pairA.original.isSuperseded && pairB.original.isSuperseded)
        #expect(model.lastConfirmBatch?.snapshots.count == 2)

        #expect(model.undoConfirmRepair())
        #expect(!pairA.original.isSuperseded && !pairB.original.isSuperseded)
        #expect(pairA.repair.isAwaitingConfirmation && pairB.repair.isAwaitingConfirmation)
    }

    @Test func batchConfirmSkipsIneligibleMembers() {
        let model = VideoScanModel()
        let good = makePair(model: model, suffix: "G")
        let orphan = VideoRecord()
        orphan.filename = "orphan_RepairedAudio.mov"
        orphan.fullPath = "/Volumes/T/orphan_RepairedAudio.mov"
        orphan.derivedFrom = UUID()
        orphan.derivationKind = "rebuildAudio"
        model.records.append(orphan)

        #expect(model.confirmRepairs(repairIDs: [good.repair.id, orphan.id]) == 1)
        #expect(good.original.isSuperseded)
        #expect(orphan.repairConfirmedDate == nil)
        #expect(model.lastConfirmBatch?.snapshots.count == 1,
                "only the confirmed member is in the undo batch")
    }

    // MARK: QA hardening (overnight review 2026-07-24)

    @Test func confirmOfAPurgedRepairIsACompleteNoOp() {
        // QA M1 sensor: the inspector's confirm button was reachable for
        // a PURGED repair copy — confirming it would supersede the
        // original too, hiding the footage behind TWO invisible records.
        // The model-layer gate must refuse regardless of entry point.
        let model = VideoScanModel()
        let (original, repair) = makePair(model: model)
        repair.purgedAt = Date()

        #expect(!model.confirmRepair(repairID: repair.id))
        #expect(repair.repairConfirmedDate == nil)
        #expect(repair.notes.isEmpty, "no half-applied stamp")
        #expect(original.supersededByID == nil, "the original stays visible")
        #expect(original.notes.isEmpty, "the original is untouched")
        #expect(model.lastConfirmBatch == nil, "no undo target armed for a no-op")
    }

    @Test func confirmOfASetAsideRepairIsACompleteNoOp() {
        // Same M1 gate, set-aside flavor.
        let model = VideoScanModel()
        let (original, repair) = makePair(model: model)
        repair.setAsideReason = "video-only scope"

        #expect(!model.confirmRepair(repairID: repair.id))
        #expect(repair.repairConfirmedDate == nil)
        #expect(original.supersededByID == nil)
        #expect(original.notes.isEmpty)
        #expect(model.lastConfirmBatch == nil)
    }

    @Test func undoRestoresTheOriginalEvenWhenTheRepairRecordIsGone() {
        // QA m3: undo used to `continue` past the WHOLE snapshot when
        // the repair record was missing — stranding the original in the
        // superseded shadow with no repair to point at.
        let model = VideoScanModel()
        let (original, repair) = makePair(model: model)
        original.notes = "Verify Audio 2026-07-24T18:00:12Z: repaired copy written to tape_RepairedAudio.mov"
        let originalNotesBefore = original.notes

        #expect(model.confirmRepair(repairID: repair.id))
        #expect(original.isSuperseded)

        // Hard-delete the repair record out from under the armed undo.
        model.records.removeAll { $0.id == repair.id }

        #expect(model.undoConfirmRepair(),
                "the original side still restores — undo must not no-op")
        #expect(original.supersededByID == nil)
        #expect(!original.isSuperseded)
        #expect(original.notes == originalNotesBefore,
                "the Confirm stamp is removed, prior journey kept")
    }

    @Test func manualUnsupersedeDropsTheStaleUndoBanner() {
        let model = VideoScanModel()
        let (original, repair) = makePair(model: model)
        #expect(model.confirmRepair(repairID: repair.id))
        #expect(model.lastConfirmBatch != nil)

        #expect(model.unsupersede(id: original.id))
        #expect(model.lastConfirmBatch == nil,
                "a manual restore makes the armed undo stale — banner must drop")
        #expect(repair.repairConfirmedDate != nil,
                "un-supersede restores the ORIGINAL only; the repair keeps its confirmation")
    }
}
