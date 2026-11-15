// ArchiveStageArchivedLabelTests.swift — "Archive stops labelling files
// Masters" (DECISIONS 2026-10-26): the archive stage STORED as `Master`
// (ArchiveStage.masterAssigned) is SHOWN as "Archived" everywhere the UI
// says it; the stored value is unchanged (no migration). "Master" is now
// reserved for the provenance role Rick confirms (Provenance ▸ Set Role).
//
// Red before the change (2026-10-26): the Archive Angel sentence said "Its
// archive stage says Master.", the Archive detail sheet's pipeline said
// "Master Assigned", Hallie said "master assigned, not yet archived", and a
// search for "archived" did not find a promoted file whose stage is Master.
//
// Suites (filter by SUITE): ArchiveStageArchivedLabelTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archive stage Master is shown as Archived")
@MainActor
struct ArchiveStageArchivedLabelTests {

    @Test("the stored value stays Master; the shown label is Archived")
    func storedValueUnchangedShownLabelArchived() {
        #expect(ArchiveStage.masterAssigned.rawValue == "Master", "stored value unchanged — no migration")
        #expect(ArchiveStage.masterAssigned.displayName == "Archived")
        #expect(ArchiveStage.backedUp.displayName == "Backed Up", "every other stage shows its own words")
        let shown = ArchiveStage.allCases.map(\.displayName)
        #expect(!shown.contains("Master"))
    }

    @Test("Archive Angel's reason sentence says Archived, never Master")
    func angelSentenceSaysArchived() {
        let sentence = ArchiveAngelReadinessExplanation.sentence(forReason: "stage: Master")
        #expect(sentence == "Its archive stage says Archived.")
    }

    /// The Archive detail sheet and its stage pipeline were retired on
    /// 2026-11-14: Archive Details is the File Journey sheet, whose ladder
    /// has one step for this and calls it "Archived" — never "Master".
    @Test("Archive Details (the File Journey sheet's ladder) says Archived, never Master or \"Master Assigned\"")
    func detailSheetPipelineSaysArchived() throws {
        #expect(PreservationStep(kind: .archived, state: .done).title == "Archived")
        for file in ["Archive/PreservationChecklist.swift", "Catalog/FileJourneySheet.swift"] {
            let code = try SourceTree.appCode(named: file)
            #expect(!code.contains("Master Assigned") && !code.contains("pipelineRow("), "\(file) brings the stage pipeline back")
            #expect(!code.contains("archiveStage"), "\(file) reads the legacy stage stamp")
        }
    }

    @Test("Hallie never calls an archived file \"master assigned, not yet archived\"")
    func hallieSaysArchived() throws {
        let code = try SourceTree.appCode(named: "Hallie/ArchivistRecordExecutor.swift")
        #expect(!code.contains("master assigned, not yet archived"))
        #expect(code.contains("archive stage \\(snapshot.archiveStage.displayName)"))
    }

    @Test("a search for \"archived\" finds a file whose stored stage is Master; \"master\" still does (nothing findable becomes unfindable)")
    func searchFindsArchivedByItsShownLabel() {
        let record = VideoRecord()
        record.filename = "test_synthetic_clip.mov"
        record.archiveStage = .masterAssigned
        #expect(pfTokenMatches(.substring("archived"), record))
        #expect(pfTokenMatches(.substring("master"), record))
    }
}
