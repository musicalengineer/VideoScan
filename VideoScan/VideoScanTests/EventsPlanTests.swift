// EventsPlanTests.swift
// Events v1 — LOGIC for the pure planner (plan §7): identity (copies and
// A/V halves are one witness; lineage is evidence), the conservative run
// rules (folder years never chain; the span bound; one source for a
// folder's label and year; a reliable year conflict blocks; two birthdays
// a week apart stay apart; candles indoors and children outside can be
// one party), the one question, and the invariant that grouping never
// marks a clip covered. Media matrix: not applicable — no media opened.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Events — plan rules")
struct EventsPlanTests {

    private typealias F = EventsFixture

    @Test("two copies of one tape (same full SHA-256) are one witness, carrying BOTH folders' labels")
    func copiesCollapseToOneWitnessWithBothFolderLabels() {
        let plan = F.plan([
            F.row("/Volumes/LaCie/Xmas 1998/tape07.mov", key: "sha-a"),
            F.row("/Volumes/SanDisk/Christmas/tape07.mov", key: "sha-a"),
        ])
        #expect(plan.suggestions.count == 1)
        let s = try! #require(plan.suggestions.first)
        #expect(s.categories == ["Christmas"])
        #expect(s.members.count == 1, "one witness, not two")
        #expect(s.members[0].copies == 2)
        #expect(s.folders == ["/Volumes/LaCie/Xmas 1998", "/Volumes/SanDisk/Christmas"])
        let words = Set(s.members[0].evidence.map(\.words))
        #expect(words == ["folder name says 'xmas'", "folder name says 'christmas'"], "\(words)")
        #expect(s.members[0].strength == .nameOnly)
        #expect(plan.witnessesWithEvidence == 1 && plan.rowCount == 2)
    }

    @Test("the audio and video halves of an A/V pair are one witness")
    func pairHalvesAreOneWitness() {
        let plan = F.plan([
            F.row("/Volumes/Avid/MediaFiles/party.A1.mxf", key: "pair:1234", transcript: "happy birthday to you, make a wish"),
            F.row("/Volumes/Avid/MediaFiles/party.V1.mxf", key: "pair:1234",
                  caption: "A boy blows out the candles on a cake."),
        ])
        #expect(plan.suggestions.count == 1)
        let s = plan.suggestions[0]
        #expect(s.members.count == 1 && s.members[0].copies == 2)
        #expect(s.members[0].range.contentKey == "pair:1234")
        // The caption rode on one half and the speech on the other: together.
        #expect(s.members[0].strength == .seenAndSaid)
    }

    @Test("a footage-group sibling is named as lineage on the member, never pulled in as a member")
    func lineageIsEvidenceNeverMembership() {
        let group = UUID()
        let plan = F.plan([
            F.row("/Volumes/Tapes/1998/party.mov", key: "sha-master", caption: "A birthday cake with lit candles.",
                  footage: group, role: "likely original"),
            // (not "party_…": that word alone is a name label — this clip must have no words of its own)
            F.row("/Volumes/Exports/clip42_h264.mp4", key: "sha-export", footage: group, role: "re-encode"),
        ])
        #expect(plan.suggestions.count == 1)
        let s = plan.suggestions[0]
        #expect(s.members.map(\.filename) == ["party.mov"], "the export has no words of its own and no folder/date link")
        #expect(s.members[0].lineage == "same footage as clip42_h264.mp4, likely (likely original)")
        #expect(plan.leftOut[.noEvidence] == 1)
    }

    @Test("two clips dated only by a folder year never chain across folders")
    func folderYearOnlyDatesNeverChain() {
        let plan = F.plan([
            F.row("/Volumes/Tapes/1998/a.mov", caption: "A decorated Christmas tree in the living room."),
            F.row("/Volumes/Tapes/1998-tape2/b.mov", caption: "Santa hands out wrapped presents."),
        ])
        #expect(plan.suggestions.count == 2, "folder years are not dates")
        #expect(plan.suggestions.allSatisfy { $0.members[0].date.source == .folderYear })
        #expect(plan.suggestions.allSatisfy { $0.dateWords == "1998 (folder name (year only))" })
        #expect(plan.questions.isEmpty, "different folders: no question either")
    }

    @Test("clips 3 days apart chain until the 14-day span is used up; the 16th day starts a new run")
    func spanBoundStopsThreeHourGapChaining() {
        let rows = [1, 4, 7, 10, 13, 16].map { d in
            F.row("/Volumes/Tapes/day\(d)/clip.mov", caption: "Children blowing out the candles on a cake.",
                  userDate: F.iso(1998, 6, d))
        }
        let plan = F.plan(rows)
        #expect(plan.suggestions.map { $0.members.count }.sorted() == [1, 5], "\(plan.suggestions.map(\.dateWords))")
        #expect(plan.suggestions.first { $0.members.count == 5 }?.dateWords == "Jun 1, 1998 (your date) – Jun 13, 1998 (your date)")
    }

    @Test("a folder's label and a folder-derived year are one source: 'name only', one line, no date line")
    func folderLabelAndFolderDateAreOneSource() {
        let plan = F.plan([
            F.row("/Volumes/Tapes/Christmas 1998/t.mov", inferred: F.day(1998, 7, 1),
                  inferredSource: VideoScanModel.InferredDateSource.folderYear),
        ])
        let s = try! #require(plan.suggestions.first)
        #expect(s.members[0].strength == .nameOnly && s.strength?.words == "name only")
        #expect(s.members[0].evidence.count == 1)
        #expect(s.members[0].evidence[0].source == .folderName)
        #expect(s.members[0].date.source == .folderYear, "the catalog's folder-year inference keeps its source")
        #expect(s.dateWords == "1998 (folder name (year only))")
        #expect(!s.isStrong)
    }

    @Test("Christmas 1996 and Christmas 1999 in one folder: a reliable year conflict blocks the merge; the question asks")
    func yearsApartDateConflictBlocksMerge() {
        let plan = F.plan([
            F.row("/Volumes/Tapes/Xmas/a.mov", caption: "Ornaments on a Christmas tree.", userDate: F.iso(1996, 12, 25)),
            F.row("/Volumes/Tapes/Xmas/b.mov", caption: "Santa by the Christmas tree.", userDate: F.iso(1999, 12, 25)),
        ])
        #expect(plan.suggestions.count == 2)
        #expect(plan.questions.count == 1)
        let q = plan.questions[0]
        #expect(q.category == "Christmas" && q.folder == "/Volumes/Tapes/Xmas")
        #expect(Set([q.aWords, q.bWords]) == ["Christmas · Dec 25, 1996 (your date)", "Christmas · Dec 25, 1999 (your date)"])
    }

    @Test("two birthdays on successive weekends, in their own folders, stay apart")
    func twoBirthdaysOnSuccessiveWeekendsStayApart() {
        let plan = F.plan([
            F.row("/Volumes/Tapes/Timmy bday/a.mov", caption: "A birthday cake with candles.", userDate: F.iso(1998, 6, 6)),
            F.row("/Volumes/Tapes/Matt bday/b.mov", caption: "A birthday cake with candles.", userDate: F.iso(1998, 6, 13)),
        ])
        #expect(plan.suggestions.count == 2, "7 days > the 4-day adjacency")
        #expect(plan.questions.isEmpty)
        #expect(plan.byCategory["Birthday"] == 2 && plan.candidateCount == 2)
    }

    @Test("candles indoors (evidence) and children outside (none) on the same day in one folder are one party")
    func candlesIndoorsAndKidsOutsideCanBeOneParty() {
        let plan = F.plan([
            F.row("/Volumes/Tapes/June98/kids_outside.mov", caption: "Children run across a lawn.", userDate: F.iso(1998, 6, 5)),
            F.row("/Volumes/Tapes/June98/cake.mov", caption: "A boy leans over a cake with lit candles.", userDate: F.iso(1998, 6, 5)),
            F.row("/Volumes/Tapes/June98/later.mov", caption: "Children run across a lawn.", userDate: F.iso(1998, 6, 30)),
            F.row("/Volumes/Other/lawn.mov", caption: "Children run across a lawn.", userDate: F.iso(1998, 6, 5)),
        ])
        #expect(plan.suggestions.count == 1)
        let s = plan.suggestions[0]
        #expect(Set(s.members.map(\.filename)) == ["kids_outside.mov", "cake.mov"],
                "folder AND date together; the same folder 25 days on and the same day elsewhere stay out")
        let kids = s.members.first { $0.filename == "kids_outside.mov" }
        #expect(kids?.strength == nil && kids?.link != nil)
        // The name carries the date alone (2026-10-19); the source stays in dateWords.
        #expect(s.name == "Birthday · Jun 5, 1998")
        #expect(s.dateWords == "Jun 5, 1998 (your date)")
    }

    @Test("same folder, same category, inferred dates years apart: two suggestions and the one question; the answer survives a rerun")
    func sameOccasionQuestionAppearsForSameFolderDifferentYears() {
        let rows = [
            F.row("/Volumes/Tapes/Thanksgiving/a.mov", key: "sha-a", caption: "Carving the turkey at the table.", inferred: F.day(1994, 11, 24)),
            F.row("/Volumes/Tapes/Thanksgiving/b.mov", key: "sha-b", caption: "A roast turkey on the table.", inferred: F.day(1997, 11, 27)),
        ]
        let plan = F.plan(rows)
        #expect(plan.suggestions.count == 2 && plan.questions.count == 1)
        #expect(plan.toReview == 3)
        let q = plan.questions[0]
        // "Different occasions": the question is answered and stays answered.
        let answered = EventsDecisionSnapshot(events: [], decisions: [.differentOccasions(a: q.aRange, b: q.bRange)])
        #expect(plan.reapplying(answered).questions.isEmpty, "reapply drops it")
        let rerun = F.plan(rows, decisions: answered)
        #expect(rerun.suggestions.count == 2 && rerun.questions.isEmpty, "a rebuild keeps them apart")
    }

    @Test("SENSOR: membership never marks a recording covered — no Events source reaches a delete, trash, archive or removal path")
    func membershipNeverMarksCovered() throws {
        let files = SourceTree.appSources.filter {
            $0.relative.hasPrefix("Events/") || $0.relative == "Catalog/EventsPane.swift" || $0.relative == "Catalog/EventDetailSheet.swift"
        }
        // Reviewed 2026-10-16: VideoScanModel+RelatedEvidence builds Compare Media's evidence (values + the sidecar
        // audio match); it reads records and never changes one. Reviewed 2026-10-19: EventsFolderDraft turns
        // files into ContentRanges and calls `confirm` — it reads records and never changes one.
        #expect(Set(files.map(\.relative)) == ["Events/EventsPlan.swift", "Events/EventsDecisionStore.swift",
                                               "Events/EventsFolderDraft.swift",
                                               "Events/VideoScanModel+Events.swift", "Events/VideoScanModel+RelatedEvidence.swift",
                                               "Catalog/EventsPane.swift", "Catalog/EventDetailSheet.swift"],
                "a new Events file must be added here (and reviewed): \(files.map(\.relative).sorted())")
        let forbidden = ["deleteConfirmedJunk", "MediaTrash", "trashItem(", "removeItem(", "unlink(", "moveItem(", ".removal =",
                         "purgedAt =", "stampRemoval(", "records.remove", "mediaDisposition =", "duplicateDisposition =",
                         "isCovered", "covered =", "archiveFixity =", "promote(", "footage =", "lifecycleStage ="]
        for f in files {
            let code = try SourceTree.appCode(named: (f.relative as NSString).lastPathComponent)
            for token in forbidden {
                #expect(!code.contains(token), "\(f.relative) contains \(token) — grouping must never touch a recording's fate")
            }
        }
        // And the values carry no such notion: a member's state is suggested / accepted / rejected, nothing more.
        let states: [EventMember.State] = [.suggested, .accepted, .rejected]
        #expect(states.map(\.rawValue) == ["suggested", "accepted", "rejected"])
    }
}
