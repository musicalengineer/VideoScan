import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - The preservation ladder (Rick 2026-11-14)
//
// Catalogued · Analyzed · Reviewed · Archived, and Offsite once the person
// has answered. These pin the scoring — pure over `PreservationEvidence` —
// and the three rules in PreservationChecklist.swift's header:
//
//   * HONEST   — a green tick is proven; the person's word about an off-site
//                copy is drawn apart and is not in "N of M".
//   * NO WOLF  — an open circle is the person's real work: the machine's
//                queue is "waiting", and Offsite is absent until answered.
//   * COMPLETE — a fully protected file can reach N of N; no step is
//                unreachable.

@Suite("Preservation ladder — scoring")
struct PreservationChecklistTests {

    private static let sep23 = Date(timeIntervalSince1970: 1_790_000_000)
    private static let oct15 = sep23.addingTimeInterval(22 * 86_400)

    private static func analysis(_ covered: [Bool]) -> JourneyAnalysis {
        JourneyAnalysis(items: covered.enumerated().map {
            JourneyAnalysisItem(title: "pass \($0.offset + 1)", covered: $0.element, at: $0.element ? sep23 : nil)
        })
    }

    /// Everything proven: the shape a kept family video ends in.
    private static var complete: PreservationEvidence {
        PreservationEvidence(catalogued: JourneyCatalogued(date: sep23, isExact: false),
                             analysis: analysis([true, true, true]),
                             review: JourneyReview(acts: ["date set", "note"], latest: oct15),
                             archive: .archived(place: "FamilyArchive", at: sep23, checkedAt: oct15),
                             offsite: nil)
    }

    // MARK: Logic

    @Test("a fresh file: Catalogued only, four steps, and the next move is the person's")
    func freshFile() {
        let steps = PreservationChecklist.steps(from: PreservationEvidence(analysis: Self.analysis([false, false])))
        #expect(steps.map(\.kind) == [.catalogued, .analyzed, .reviewed, .archived], "no Offsite until the person answers")
        #expect(steps.map(\.done) == [true, false, false, false])
        #expect(steps.map(\.state) == [.done, .waiting, .open, .open])
        #expect(PreservationChecklist.tally(steps).done == 1 && PreservationChecklist.tally(steps).of == 4)
        #expect(PreservationChecklist.nextAction(steps) == PreservationChecklist.reviewTodo)
    }

    @Test("a fully protected file reaches 4 of 4 with nothing left to say")
    func completeFile() {
        let steps = PreservationChecklist.steps(from: Self.complete)
        #expect(steps.allSatisfy { $0.done })
        #expect(PreservationChecklist.tally(steps).done == 4 && PreservationChecklist.tally(steps).of == 4)
        #expect(PreservationChecklist.nextAction(steps) == nil)
        #expect(steps.allSatisfy { $0.todo.isEmpty }, "a done step carries no to-do")
    }

    @Test("Catalogued: an inexact date is shown 'by …', an exact one bare, and no date is still a tick")
    func cataloguedDate() {
        let bound = PreservationChecklist.catalogued(JourneyCatalogued(date: Self.sep23, isExact: false))
        #expect(bound.done && bound.date == Self.sep23 && bound.datePrefix == "by ")
        let exact = PreservationChecklist.catalogued(JourneyCatalogued(date: Self.sep23, isExact: true))
        #expect(exact.datePrefix.isEmpty)
        let unknown = PreservationChecklist.catalogued(JourneyCatalogued())
        #expect(unknown.done && unknown.date == nil && unknown.datePrefix.isEmpty, "holding the record is the proof")
    }

    @Test("Analyzed: ticked only when every pass that applies has run; otherwise it is the machine's queue, named")
    func analyzed() {
        let done = PreservationChecklist.analyzed(Self.analysis([true, true]))
        #expect(done.state == .done && done.date == Self.sep23 && done.detail == "2 of 2 passes")

        let partial = PreservationChecklist.analyzed(Self.analysis([true, false, false]))
        #expect(partial.state == .waiting, "the machine's backlog is never an open circle for the person")
        #expect(partial.detail == "1 of 3 passes · in the queue")
        #expect(partial.todo == "Content Analysis still has to run: pass 2, pass 3.")

        let nothing = PreservationChecklist.analyzed(JourneyAnalysis())
        #expect(nothing.state == .waiting && !nothing.done && nothing.todo.isEmpty && nothing.detail == "nothing to analyze")
    }

    @Test("Reviewed: any act of the person's ticks it; the detail names the first two and counts the rest")
    func reviewed() {
        let none = PreservationChecklist.reviewed(JourneyReview())
        #expect(none.state == .open && none.todo == PreservationChecklist.reviewTodo)
        let one = PreservationChecklist.reviewed(JourneyReview(acts: ["note"], latest: nil))
        #expect(one.done && one.date == nil && one.detail == "note", "an undated act still ticks, without a date")
        let many = PreservationChecklist.reviewed(JourneyReview(acts: ["date set", "note", "place set", "2 people confirmed"],
                                                                latest: Self.oct15))
        #expect(many.detail == "date set · note · +2" && many.date == Self.oct15)
    }

    @Test("Archived: the day it was archived, the place, and a LATER read-back in words")
    func archived() {
        let open = PreservationChecklist.archived(.notArchived)
        #expect(open.state == .open && open.todo == PreservationChecklist.archiveTodo)

        let unproven = PreservationChecklist.archived(.unproven(todo: "Connect FamilyArchive — the archived copy could not be checked."))
        #expect(!unproven.done && unproven.todo.hasPrefix("Connect FamilyArchive"))

        let checked = PreservationChecklist.archived(.archived(place: "FamilyArchive", at: Self.sep23, checkedAt: Self.oct15))
        #expect(checked.done && checked.date == Self.sep23, "the date is the archive day, not the last check")
        #expect(checked.detail == "FamilyArchive\nchecked \(PreservationChecklist.shortDate(Self.oct15))")

        let sameDay = PreservationChecklist.archived(.archived(place: "FamilyArchive", at: Self.sep23, checkedAt: Self.sep23))
        #expect(sameDay.detail == "FamilyArchive", "the promote's own read-back is not a second check")

        let undated = PreservationChecklist.archived(.archived(place: "FamilyArchive", at: nil, checkedAt: Self.oct15))
        #expect(undated.done && undated.date == nil, "a check is never shown as the day it was archived")
        #expect(undated.detail == "FamilyArchive\nchecked \(PreservationChecklist.shortDate(Self.oct15))")
    }

    // MARK: Truth — the person's word is not proof

    @Test("TRUTH: 'yes, there is an off-site copy' is drawn apart, never a green tick, and is not in N of M")
    func offsiteYesIsTheirWord() {
        var evidence = Self.complete
        evidence.offsite = JourneyOffsite(exists: true, label: "iCloud", at: Self.oct15)
        let steps = PreservationChecklist.steps(from: evidence)
        let offsite = steps[4]
        #expect(offsite.kind == .offsite && offsite.state == .attested && !offsite.done)
        #expect(offsite.color != PreservationStep(kind: .archived, state: .done).color, "never the green of a proven tick")
        #expect(offsite.detail == "your word · iCloud" && offsite.date == Self.oct15)
        #expect(PreservationChecklist.tally(steps).done == 4 && PreservationChecklist.tally(steps).of == 4,
                "the count is what the app can prove")
        #expect(PreservationChecklist.nextAction(steps) == nil)
    }

    @Test("'no off-site copy' is an open step with its door")
    func offsiteNo() {
        var evidence = Self.complete
        evidence.offsite = JourneyOffsite(exists: false, label: "off-site", at: Self.oct15)
        let steps = PreservationChecklist.steps(from: evidence)
        #expect(steps[4].state == .open && steps[4].todo == PreservationChecklist.offsiteTodo)
        #expect(PreservationChecklist.tally(steps).done == 4 && PreservationChecklist.tally(steps).of == 5)
        #expect(PreservationChecklist.nextAction(steps) == PreservationChecklist.offsiteTodo)
    }

    // MARK: Sensors — the design rules

    @Test("SENSOR: the next action is the person's first open step; only when none is open does it name the machine's queue")
    func nextActionPrefersThePerson() {
        var evidence = Self.complete
        evidence.analysis = Self.analysis([true, false])
        evidence.archive = .notArchived
        #expect(PreservationChecklist.nextAction(PreservationChecklist.steps(from: evidence)) == PreservationChecklist.archiveTodo)
        evidence.archive = .archived(place: "FamilyArchive", at: Self.sep23, checkedAt: nil)
        let machineOnly = PreservationChecklist.steps(from: evidence)
        #expect(PreservationChecklist.nextAction(machineOnly) == "Content Analysis still has to run: pass 2.")
        #expect(PreservationChecklist.nextLine(machineOnly) == "Content Analysis still has to run: pass 2.",
                "the machine's queue is never called the person's Next")
        evidence.review = JourneyReview()
        #expect(PreservationChecklist.nextLine(PreservationChecklist.steps(from: evidence))
                == "Next: \(PreservationChecklist.reviewTodo)")
        #expect(PreservationChecklist.nextLine(PreservationChecklist.steps(from: Self.complete)) == nil)
    }

    @Test("SENSOR: every open step says what to do, and no step is titled Signed or shows a hash")
    func everyOpenStepCarriesAnAction() {
        var evidence = PreservationEvidence(analysis: Self.analysis([false]))
        evidence.offsite = JourneyOffsite(exists: false, label: "cloud", at: Self.oct15)
        let steps = PreservationChecklist.steps(from: evidence)
        for step in steps where step.state == .open {
            #expect(!step.todo.isEmpty, "\(step.kind) has no next action")
        }
        #expect(PreservationStep.Kind.allCases.map(\.rawValue) == ["catalogued", "analyzed", "reviewed", "archived", "offsite"])
        #expect(steps.map(\.title) == ["Catalogued", "Analyzed", "Reviewed", "Archived", "Offsite"])
    }
}
