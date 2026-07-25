// RepairLifecycleAdoptionTests.swift
// LOGIC + MEDIA + SENSOR dimensions for "Link Repaired Copy…" (GH #132
// P4): adopting an externally-repaired file onto a damaged record.
//
//   * Media (real probe): a synthetic healthy mov adopted onto a
//     damaged record gets full two-way provenance (derivedFrom +
//     "externalRepair" + "Verify Audio" journey stamps), carries the
//     hand-entered date, and enters the awaiting-confirmation state —
//     then flows through the SAME confirm + supersede lifecycle the
//     in-app rebuild uses (end-to-end integration).
//   * Upsert: re-adopting an already-cataloged path updates the record
//     — never duplicates it.
//   * Refusals: missing original / unreadable file throw the family-
//     language error and insert NOTHING.
//   * Lock-step SENSOR: ExternalRepairAdoption.derivationKind must stay
//     in VideoRecord.repairDerivationKinds, or adopted files silently
//     drop out of the confirm lifecycle.

import Testing
import Foundation
@testable import VideoScan

@MainActor
@Suite("RepairLifecycle — Link Repaired Copy", .serialized)
struct RepairLifecycleAdoptionTests {

    private func makeDamagedOriginal(model: VideoScanModel) -> VideoRecord {
        let r = VideoRecord()
        r.filename = "JustPatsHouse.mov"
        r.fullPath = "/Volumes/T/JustPatsHouse.mov"
        r.directory = "/Volumes/T"
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.audioVerifyStatus = "damaged"
        r.audioVerifyNote = "Damaged audio — invalid codec (qdm2)"
        r.userDate = "1994-11"
        r.userDateConfidence = "estimated"
        model.records.append(r)
        return r
    }

    // MARK: Sensor — lifecycle membership

    @Test func adoptedKindIsARepairKind() {
        // If this drifts, adopted files stop being awaiting-confirmation
        // and the whole P4 flow silently dies.
        #expect(VideoRecord.repairDerivationKinds.contains(ExternalRepairAdoption.derivationKind))
        #expect(ExternalRepairAdoption.derivationKind == "externalRepair")
    }

    // MARK: Media — real probe, full provenance, lifecycle integration

    @Test(.enabled(if: VerifyAudioTestMedia.toolsAvailable))
    func adoptionWiresProvenanceAndEntersTheConfirmLifecycle() async throws {
        let dir = try VerifyAudioTestMedia.makeScratchDir("adopt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyAudioTestMedia.generate(
            into: dir, name: "test_JustPatsHouse_Recovered_v2.mov",
            videoCodec: "prores_ks", extraVideoArgs: ["-profile:v", "1"],
            audioCodec: "pcm_s16le")

        let model = VideoScanModel()
        let original = makeDamagedOriginal(model: model)

        let adopted = try await model.adoptExternalRepair(
            originalID: original.id, fileURL: URL(fileURLWithPath: path))

        // Provenance both ways.
        #expect(adopted.derivedFrom == original.id)
        #expect(adopted.derivationKind == "externalRepair")
        #expect(adopted.isAwaitingConfirmation,
                "an adopted repair enters the repaired-unconfirmed state automatically")
        #expect(adopted.userDate == "1994-11", "same footage — the hand-entered date carries")
        #expect(adopted.userDateConfidence == "estimated")
        #expect(model.records.contains(where: { $0.id == adopted.id }))

        // Journey stamps — existing "Verify Audio" verb, machine-classified.
        let sourceStamp = try #require(original.notes.split(separator: "\n").last)
        #expect(sourceStamp.hasPrefix("Verify Audio "))
        #expect(sourceStamp.hasSuffix(": repaired copy linked: test_JustPatsHouse_Recovered_v2.mov"))
        #expect(UserNotesMigration.isJourneyStampLine(sourceStamp))
        let derivedStamp = try #require(adopted.notes.split(separator: "\n").last)
        #expect(derivedStamp.hasSuffix(": adopted as repaired copy of JustPatsHouse.mov"))
        #expect(UserNotesMigration.isJourneyStampLine(derivedStamp))

        // …and the SAME lifecycle finishes it: worklist → confirm →
        // supersede, exactly like an in-app rebuild.
        #expect(model.records.filter(pfAwaitingConfirmation).map(\.id) == [adopted.id])
        #expect(model.confirmRepair(repairID: adopted.id))
        #expect(adopted.repairConfirmedDate != nil)
        #expect(original.supersededByID == adopted.id)
        #expect(pfActiveRecords(model.records).map(\.id) == [adopted.id])
    }

    @Test(.enabled(if: VerifyAudioTestMedia.toolsAvailable))
    func readoptingACatalogedPathUpdatesInsteadOfDuplicating() async throws {
        let dir = try VerifyAudioTestMedia.makeScratchDir("readopt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyAudioTestMedia.generate(
            into: dir, name: "test_recovered.mov",
            videoCodec: "prores_ks", extraVideoArgs: ["-profile:v", "1"],
            audioCodec: "pcm_s16le")

        let model = VideoScanModel()
        let original = makeDamagedOriginal(model: model)

        let first = try await model.adoptExternalRepair(
            originalID: original.id, fileURL: URL(fileURLWithPath: path))
        let countAfterFirst = model.records.count
        let second = try await model.adoptExternalRepair(
            originalID: original.id, fileURL: URL(fileURLWithPath: path))

        #expect(model.records.count == countAfterFirst,
                "re-adopting the same path must update, never duplicate")
        #expect(model.records.filter { $0.fullPath == path }.count == 1)
        #expect(second.derivedFrom == original.id)
        #expect(first.id != second.id || first === second,
                "either replaced wholesale (new id) or the same record — but only ONE row")
    }

    // MARK: Refusals — nothing inserted

    @Test func adoptingWithAMissingOriginalThrowsAndInsertsNothing() async {
        let model = VideoScanModel()
        let before = model.records.count
        await #expect(throws: AdoptRepairError.originalNotFound) {
            try await model.adoptExternalRepair(
                originalID: UUID(),
                fileURL: URL(fileURLWithPath: "/tmp/whatever.mov"))
        }
        #expect(model.records.count == before)
    }

    @Test func adoptingAnUnreadableFileThrowsAndInsertsNothing() async {
        let model = VideoScanModel()
        let original = makeDamagedOriginal(model: model)
        let notesBefore = original.notes
        let missing = URL(fileURLWithPath: "/tmp/does_not_exist_\(UUID().uuidString).mov")

        do {
            _ = try await model.adoptExternalRepair(originalID: original.id, fileURL: missing)
            Issue.record("adopting a nonexistent file must throw")
        } catch let error as AdoptRepairError {
            guard case .fileUnreadable = error else {
                Issue.record("expected fileUnreadable, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        #expect(model.records.count == 1, "nothing inserted")
        #expect(original.notes == notesBefore, "no half-applied stamp on the original")
    }
}
