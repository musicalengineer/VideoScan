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

    /// Rick 2026-09-21 raised the AUTOMATIC floor to 2 min. An explicit
    /// pick keeps the pre-existing 60 s floor: a 90 s clip he chooses is
    /// still prepared, a 45 s one is still refused (as it was before).
    @Test func explicitPickKeepsTheSixtySecondFloor() {
        let ninety = candidate("ninety.mov", seconds: 90)
        let sixty = candidate("sixty.mov", seconds: 60)
        let fortyFive = candidate("fortyfive.mov", seconds: 45)
        let table = Dictionary(uniqueKeysWithValues: [ninety, sixty, fortyFive].map { ($0.id, $0) })
        let selection = ArchiveAngelJob.explicitSelection(
            ids: [ninety.id, sixty.id, fortyFive.id], inFlight: [], project: { table[$0] })
        #expect(Set(selection.picks.map(\.candidate.filename)) == ["ninety.mov", "sixty.mov"],
                "below the automatic 2-minute floor but chosen by hand")
        #expect(selection.rejected[.tooShort] == 1, "45 s was refused before the change and still is")
        #expect(ArchiveAngelScorer.verdict(ninety) == .rejected(.tooShort),
                "the same 90 s file is never PROPOSED automatically")
    }

    /// Rick 2026-09-21: Live Photo motion halves and recent phone clips are
    /// never PROPOSED, but one he chooses himself is still prepared. (A real
    /// Live Photo half is ~3 s, so in practice the 60 s explicit floor
    /// refuses it as too short; a long one shows the exemption itself.)
    @Test func explicitPickIgnoresPhoneClipRules() {
        var motion = candidate("jpegvideocomplement_A1.mov", seconds: 300)
        motion.deviceModel = "iPhone 12"
        var phone = candidate("IMG_5521.MOV", seconds: 300)
        phone.deviceModel = "iPhone 12"
        phone.captureDate = Date(timeIntervalSince1970: 1_620_000_000)   // 2021
        let table = Dictionary(uniqueKeysWithValues: [motion, phone].map { ($0.id, $0) })
        let selection = ArchiveAngelJob.explicitSelection(ids: [motion.id, phone.id], inFlight: [],
                                                          project: { table[$0] })
        #expect(Set(selection.picks.map(\.candidate.filename)) == ["jpegvideocomplement_A1.mov", "IMG_5521.MOV"])
        #expect(selection.rejectedTotal == 0)
        #expect(ArchiveAngelScorer.verdict(motion) == .rejected(.livePhotoMotion))
        #expect(ArchiveAngelScorer.verdict(phone) == .rejected(.recentPhoneClip))
    }
}
