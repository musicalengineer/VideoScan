// ArchiveAngelReviewDatesTests.swift
// Angel Review's "use the date I already gave its copies" (Rick 2026-09-27):
// one line per row, only disagreements ask, the answer rides the plan row,
// and the promoter turns it into the right ArchiveDateSource — a machine
// proposal is never written as Rick's date.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Angel Review — dates from copies")
@MainActor
struct ArchiveAngelReviewDatesTests {

    private func entry(proposed: String? = nil, inherited: ArchiveAngelPlan.InheritedFact? = nil) -> ArchiveAngelPlan.Entry {
        var e = ArchiveAngelPlan.Entry(id: UUID(), sourcePath: "/Volumes/test_V/a.mov", filename: "a.mov", sizeBytes: 10,
                                       durationSeconds: 60, score: 1, evidence: [], proposedName: "a.mov",
                                       proposedDate: proposed)
        e.inheritedDate = inherited
        return e
    }

    private func d(_ date: String, known: Bool, _ name: String) -> PromoteCopyDate {
        PromoteCopyDate(recordID: UUID(), filename: name, volume: "LaCie", date: date, known: known, via: .sameBytes)
    }

    @Test("a single known date is pre-selected over the machine default; a date the person typed stands")
    func preselection() {
        let choice = PromoteCopyDates.decide([d("1984", known: true, "t.dv")])
        var e = entry(proposed: "2004")
        ArchiveAngelReviewDates.applyPreselection(choice, to: &e, machineDefault: "2004")
        #expect(e.proposedDate == "1984" && e.inheritedDate?.fromFilename == "t.dv")
        #expect(ArchiveAngelReviewDates.line(e, choice: choice) == "dated 1984 (known) from 1 copy")
        var typed = entry(proposed: "1990")
        ArchiveAngelReviewDates.applyPreselection(choice, to: &typed, machineDefault: "2004")
        #expect(typed.proposedDate == "1990", "the person's own date wins")
    }

    @Test("disagreement asks until answered: Use / Enter a date… / Promote undated")
    func askUntilAnswered() {
        let choice = PromoteCopyDates.decide([d("1984", known: true, "a"), d("1985", known: false, "b")])
        var e = entry(proposed: "2004")
        #expect(ArchiveAngelReviewDates.needsAnswer(e, choice: choice))
        ArchiveAngelReviewDates.applyPreselection(choice, to: &e, machineDefault: "2004")
        #expect(e.proposedDate == "2004", "an ask never pre-selects")
        guard case .ask(let list) = choice else { Issue.record("\(choice)"); return }
        var used = e
        ArchiveAngelReviewDates.use(list[1], on: &used)
        #expect(!ArchiveAngelReviewDates.needsAnswer(used, choice: choice) && used.proposedDate == "1985")
        var declined = e
        ArchiveAngelReviewDates.decline(on: &declined, machineDefault: "2004")
        #expect(declined.proposedDate == "2004" && declined.inheritedDate == nil && declined.dateFromCopiesAnswered == true)
        var typing = e
        ArchiveAngelReviewDates.enterDate(on: &typing)
        #expect(!ArchiveAngelReviewDates.needsAnswer(typing, choice: choice))
    }

    @Test("codex r1 #4: the promoter reads the row's EXPLICIT source — Rick typing the machine's own date is still Rick's; a stale machine proposal is still the machine's")
    func promoterSourceIsExplicit() {
        let fact = ArchiveAngelPlan.InheritedFact(value: "1984", confidence: "known", fromRecordID: UUID(), fromFilename: "t.dv")
        var copy = entry(proposed: "1984", inherited: fact)
        copy.proposedDateSource = .fromCopy
        #expect(ArchiveAngelPromoter.dateSource(entry: copy, hint: .year(1984)) == .copy(filename: "t.dv", known: true))
        // Rick typed 2004 — which happens to be what the machine says.
        var typedSame = entry(proposed: "2004")
        typedSame.proposedDateSource = .typed
        #expect(ArchiveAngelPromoter.dateSource(entry: typedSame, hint: .year(2004)) == .typed)
        // The plan build's machine proposal (1999), stale against today's machine hint.
        var stale = entry(proposed: "1999")
        stale.proposedDateSource = .machine
        #expect(ArchiveAngelPromoter.dateSource(entry: stale, hint: .year(1999)) == nil)
        // An older plan with no source: never guessed to be Rick's.
        #expect(ArchiveAngelPromoter.dateSource(entry: entry(proposed: "1990"), hint: .year(1990)) == nil)
        #expect(ArchiveAngelPromoter.dateSource(entry: entry(proposed: nil), hint: nil) == nil)
    }

    @Test("Review answers set the source: Use → fromCopy, Enter a date… → typed, Promote undated → machine, pre-selection → fromCopy")
    func reviewAnswersSetSource() {
        let d = d("1984", known: true, "t.dv")
        var e = entry(proposed: "2004"); ArchiveAngelReviewDates.use(d, on: &e)
        #expect(e.proposedDateSource == .fromCopy)
        ArchiveAngelReviewDates.enterDate(on: &e)
        #expect(e.proposedDateSource == .typed)
        ArchiveAngelReviewDates.decline(on: &e, machineDefault: "2004")
        #expect(e.proposedDateSource == .machine)
        var p = entry(proposed: "2004")
        ArchiveAngelReviewDates.applyPreselection(PromoteCopyDates.decide([d]), to: &p, machineDefault: "2004")
        #expect(p.proposedDateSource == .fromCopy)
    }

    @Test("the plan row's new field decodes from an older plan (nil = not answered)")
    func additiveField() throws {
        let e = entry(proposed: "1984")
        var json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(e)) as? [String: Any] ?? [:]
        json.removeValue(forKey: "dateFromCopiesAnswered")
        let back = try JSONDecoder().decode(ArchiveAngelPlan.Entry.self, from: try JSONSerialization.data(withJSONObject: json))
        #expect(back.dateFromCopiesAnswered == nil && back.proposedDate == "1984")
    }
}
