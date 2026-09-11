// ArchiveAngelExplicitPickTests.swift
// "Prepare with Archive Angel" from the catalog (Rick 2026-09-11): the
// selection IS the pick list — every record that clears the hard floor,
// best first; refusals counted by reason; rows already in a batch refused
// as such; unknown ids and repeats ignored. Pure.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

struct ArchiveAngelExplicitPickTests {

    private func candidate(_ name: String, seconds: Double, stars: Int = 3,
                           people: [String] = ["Donna"]) -> ArchiveAngelCandidate {
        .init(filename: name, fullPath: "/Volumes/Src/\(name)", sizeBytes: 4_000_000_000,
              durationSeconds: seconds, starRating: stars, mediaDisposition: .important,
              junkScore: 0, confirmedPeople: people, detectedPeople: [], hasUserNotes: false,
              tagCount: 1, inferredRecordDate: Date(timeIntervalSince1970: 700_000_000),
              inferredDateConfidence: 0.9)
    }

    @Test func selectionIsThePickListBestFirst() {
        let tape = candidate("Christmas_1990_2_hours.dv", seconds: 7_200)
        let clip = candidate("Peekaboo.dv", seconds: 600, stars: 1, people: [])
        let short = candidate("edit.mov", seconds: 30)
        let inBatch = candidate("already.mov", seconds: 3_000)
        let table = Dictionary(uniqueKeysWithValues: [tape, clip, short, inBatch].map { ($0.id, $0) })
        let unknown = UUID()
        let selection = ArchiveAngelJob.explicitSelection(
            ids: [clip.id, tape.id, short.id, inBatch.id, unknown, tape.id],
            inFlight: [inBatch.id],
            project: { table[$0] })
        #expect(selection.picks.map(\.candidate.filename) == ["Christmas_1990_2_hours.dv", "Peekaboo.dv"],
                "both eligible, the long tape first; the repeat counted once")
        #expect(selection.picks[0].score > selection.picks[1].score)
        #expect(selection.rejected[.tooShort] == 1)
        #expect(selection.rejected[.inAnotherBatch] == 1)
        #expect(selection.rejectedTotal == 2)
        #expect(selection.overflow == 0, "nothing is 'more would qualify' — the user chose the list")
    }

    @Test func emptyAndAllRefused() {
        let none = ArchiveAngelJob.explicitSelection(ids: [], inFlight: [], project: { _ in nil })
        #expect(none.picks.isEmpty && none.rejectedTotal == 0)
        let short = candidate("x.mov", seconds: 5)
        let refused = ArchiveAngelJob.explicitSelection(ids: [short.id], inFlight: [], project: { _ in short })
        #expect(refused.picks.isEmpty && refused.rejected[.tooShort] == 1)
    }
}
