// ArchiveAngelTableCellTests.swift
// The Archive Angel table (Rick, 2026-09-18): one row per file, the four
// stages as columns. Pins what each stage cell says — above all which stage
// reads "Working…" while a file is preparing.

import Foundation
import SwiftUI
import Testing
@testable import VideoScan

@Suite("Archive Angel table — stage cells")
struct ArchiveAngelTableCellTests {
    typealias Cell = ArchiveAngelStepPresentation.Cell

    private func entry(_ status: ArchiveAngelPlan.EntryStatus,
                       _ states: [ArchiveAngelPlan.StepState]) -> ArchiveAngelPlan.Entry {
        var e = ArchiveAngelPlan.Entry(
            id: UUID(), sourcePath: "/tmp/clip.mov", filename: "clip.mov", sizeBytes: 1,
            sourceContentHash: "", sourceModifiedAt: nil, durationSeconds: 60, score: 1,
            evidence: [], proposedName: "clip.mov", proposedDate: nil, status: status)
        for (i, state) in states.enumerated() { e.steps[i].state = state }
        return e
    }

    private func cells(_ e: ArchiveAngelPlan.Entry) -> [Cell] {
        ArchiveAngelPlan.StepKind.allCases.map { ArchiveAngelStepPresentation.cell($0, in: e) }
    }

    @Test func preparingMarksOnlyTheFirstPendingStageAsWorking() {
        #expect(cells(entry(.preparing, [.done, .pending, .pending, .pending]))
                == [.done, .working, .pending, .pending])
        #expect(cells(entry(.preparing, [.pending, .pending, .pending, .pending]))
                == [.working, .pending, .pending, .pending])
        #expect(cells(entry(.preparing, [.skipped, .done, .pending, .pending]))
                == [.skipped, .done, .working, .pending])
    }

    @Test func waitingFilesHaveNothingWorking() {
        #expect(!cells(entry(.pending, [.pending, .pending, .pending, .pending])).contains(.working))
        #expect(!cells(entry(.ready, [.done, .done, .done, .pending])).contains(.working))
    }

    @Test func stoppedFilesSayNotRunNotPending() {
        #expect(cells(entry(.skipped, [.done, .pending, .pending, .pending]))
                == [.done, .notRun, .notRun, .notRun])
        #expect(cells(entry(.failed, [.failed, .pending, .pending, .pending]))
                == [.failed, .notRun, .notRun, .notRun])
    }

    @Test func aStageMissingFromTheEntryIsNotInBatch() {
        var e = entry(.pending, [])
        e.steps.removeAll { $0.kind == .balanceAudio }
        #expect(ArchiveAngelStepPresentation.cell(.balanceAudio, in: e) == .notInBatch)
    }

    @Test func cellWordsAndColorsAreDistinctForStates() {
        let all: [Cell] = [.notInBatch, .working, .pending, .notRun, .done, .skipped, .failed]
        #expect(Set(all.map(\.word)).count == all.count)
        #expect(Cell.failed.color == .red && Cell.done.color == .green && Cell.working.color == .orange)
    }

    /// Rick 2026-09-19: review and promote from the Angel window itself —
    /// only once the batch has finished with files ready and not promoted.
    @Test func reviewIsOfferedOnlyWhenFinishedWithReadyFiles() {
        typealias V = ArchiveAngelDetailView
        #expect(V.offersReview(isActive: false, readyCount: 2, status: .ready))
        #expect(!V.offersReview(isActive: true, readyCount: 2, status: .ready), "still preparing")
        #expect(!V.offersReview(isActive: false, readyCount: 0, status: .ready), "nothing to review")
        #expect(!V.offersReview(isActive: false, readyCount: 2, status: .promoting))
        #expect(!V.offersReview(isActive: false, readyCount: 2, status: .promoted))
    }
}
