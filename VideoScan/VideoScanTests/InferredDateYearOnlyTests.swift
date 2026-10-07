import Testing
import Foundation
import VideoScanCore
@testable import VideoScan

// MARK: - InferredDateYearOnlyTests (GH #293 item 2, 2026-10-07)
//
// The bug: an archived edit copy of a 1992 tape (Cape-1992-archive.vs.edit.mov,
// transcoded straight into .../30_Video/1990-1999/1995/ on 2026-08-22) showed
// an inferred date of "1995-01-01". Forensics on a read-only copy of the real
// catalog:
//   • the date came from the BARE-YEAR FOLDER PRIOR (rule 3) reading the
//     archive folder the file had been put in — written by the pre-GH #201
//     code (before 2026-09-26) as Jan 1 noon UTC with NO span and NO reason;
//   • since 2026-09-27 archive files are frozen to the date passes, so the
//     row can never be re-derived;
//   • every reader that keys "year-only" on `inferredDateRange != nil`
//     therefore showed a fabricated DAY ("1995-01-01") and claimed it was
//     "figured out from the video".
// 63 live rows have this shape (Jan 1 noon, no span, no reason): 20 folder-year
// at 0.30, 40 legacy path-year at 0.50, 3 at 0.55. None reaches the resolver's
// 0.6 trust floor, so no archive placement used them — the leak is display /
// WHY, and it misleads the person who files by hand.
//
// Rule pinned here: a year-only inference stays YEAR precision everywhere it
// is shown, and the WHY says where the year came from.
//
// Five dimensions:
//   logic      the Cape replica (folder-year 0.30), a legacy path-year 0.50
//              row, day-precise rows unchanged
//   scale      100k legacy rows through the Date column's display in budget
//   media      n/a — no media is opened (stored fields only)
//   isolation  pure record properties; no model, no global state
//   sensor     no year-only row ever renders a "-01-01" day

private func noonJan1(_ year: Int) -> Date {
    var dc = DateComponents()
    dc.year = year; dc.month = 1; dc.day = 1; dc.hour = 12
    dc.timeZone = TimeZone(identifier: "UTC")
    return Calendar(identifier: .gregorian).date(from: dc)!
}

private func utcDay(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var dc = DateComponents()
    dc.year = y; dc.month = m; dc.day = d; dc.hour = 12
    dc.timeZone = TimeZone(identifier: "UTC")
    return Calendar(identifier: .gregorian).date(from: dc)!
}

/// The real record's date fields, copied by hand (no media, no catalog read).
private func capeEditReplica() -> VideoRecord {
    let r = VideoRecord()
    r.filename = "Cape-1992-archive.vs.edit.mov"
    r.fullPath = "/Volumes/FamilyArchive/Breen_Family_Archive/30_Video/1990-1999/1995/Cape-1992-archive.vs.edit.mov"
    r.inferredRecordDate = noonJan1(1995)
    r.inferredDateConfidence = 0.3
    r.inferredDateSource = "folder-year"
    // Legacy: no span, no reason (written before GH #201).
    return r
}

/// A pre-GH #201 dossier row whose only date was a path year (0.50 tier).
private func legacyPathYearRow(_ year: Int = 1990, confidence: Float = 0.5) -> VideoRecord {
    let r = VideoRecord()
    r.filename = "Franklin_\(year)_p216.mkv"
    r.inferredRecordDate = noonJan1(year)
    r.inferredDateConfidence = confidence
    return r
}

@Suite("GH #293 — a year-only inferred date never becomes a day (logic)")
struct InferredDateYearOnlyLogicTests {

    @Test("the Cape-1992 edit copy shows 1995 as a year, with the folder named as the WHY")
    func capeReplicaShowsYearAndWhy() {
        let r = capeEditReplica()
        #expect(r.inferredDateIsYearOnly)
        #expect(r.effectiveInferredDateRange == InferredDateRange(year: 1995))
        #expect(r.resolvedDateDisplay == "1995", "was \(r.resolvedDateDisplay)")
        #expect(!r.resolvedDateDisplay.contains("-01-01"))
        // The WHY: never "figured out from the video" for a folder name.
        #expect(!r.resolvedDateHelp.contains("figured out from the video"), "\(r.resolvedDateHelp)")
        #expect(r.resolvedDateHelp.contains("Why (30% sure):"), "\(r.resolvedDateHelp)")
        #expect(r.resolvedDateHelp.contains("folder"), "\(r.resolvedDateHelp)")
        #expect(r.inferredDateReasonShown?.contains("'1995'") == true, "\(r.inferredDateReasonShown ?? "nil")")
    }

    @Test("the inspector line reads 'Guess: 1995' with the folder reason, not 'Guess: 1995-01-01'")
    func inspectorLineForCapeReplica() {
        let line = InspectorDateView.inferredSummary(capeEditReplica())
        #expect(line?.hasPrefix("Guess: 1995 (30% sure) — ") == true, "\(line ?? "nil")")
        #expect(line?.contains("1995-01-01") == false, "\(line ?? "nil")")
        #expect(line?.contains("folder") == true, "\(line ?? "nil")")
    }

    @Test("a legacy path-year row (0.50 / 0.55, no span, no reason) is a year, not Jan 1")
    func legacyPathYearIsAYear() {
        for conf: Float in [0.5, 0.55, 0.6] {
            let r = legacyPathYearRow(1990, confidence: conf)
            #expect(r.inferredDateIsYearOnly, "conf \(conf)")
            #expect(r.resolvedDateDisplay == "1990", "conf \(conf): \(r.resolvedDateDisplay)")
            #expect(InspectorDateView.inferredSummary(r)?.hasPrefix("Guess: 1990 (") == true,
                    "\(InspectorDateView.inferredSummary(r) ?? "nil")")
        }
    }

    @Test("day-precise inferences are untouched: a burn-in day, a legacy 0.75 day, a no-confidence date")
    func dayPreciseUnchanged() {
        let burnIn = VideoRecord()
        burnIn.inferredRecordDate = utcDay(1991, 6, 21); burnIn.inferredDateConfidence = 0.95
        burnIn.inferredDateReason = "on-screen date 1991-06-21 ×3"
        #expect(!burnIn.inferredDateIsYearOnly)
        #expect(burnIn.effectiveInferredDateRange == nil)
        #expect(burnIn.resolvedDateDisplay == "1991-06-21")

        let legacyDay = VideoRecord()
        legacyDay.inferredRecordDate = utcDay(1991, 6, 21); legacyDay.inferredDateConfidence = 0.75
        #expect(!legacyDay.inferredDateIsYearOnly)
        #expect(legacyDay.resolvedDateDisplay == "1991-06-21")

        let noConf = VideoRecord()
        noConf.inferredRecordDate = utcDay(1995, 3, 4)
        #expect(!noConf.inferredDateIsYearOnly)
        #expect(noConf.resolvedDateDisplay == "1995-03-04")
    }

    @Test("a WRITTEN reason means the GH #201 triangulator decided: its span (or none) is authoritative")
    func writtenReasonTrustsTheSpan() {
        let r = VideoRecord()
        r.inferredRecordDate = utcDay(2004, 1, 1); r.inferredDateConfidence = 0.55
        r.inferredDateReason = "on-screen date JAN 1 2004 ×1"
        #expect(!r.inferredDateIsYearOnly, "a day with a written reason stays a day")
        #expect(r.resolvedDateDisplay == "2004-01-01")
        #expect(r.inferredDateReasonShown == "on-screen date JAN 1 2004 ×1")
    }

    @Test("a current folder-year row (span + reason, GH #201 shape) still reads as before")
    func currentFolderYearUnchanged() {
        let r = VideoRecord()
        r.inferredRecordDate = noonJan1(1998); r.inferredDateConfidence = 0.3
        r.inferredDateRange = InferredDateRange(year: 1998)
        r.inferredDateReason = "bare-year folder '1998' — a placeholder any real evidence replaces"
        r.inferredDateSource = "folder-year"
        #expect(r.resolvedDateDisplay == "1998")
        #expect(r.inferredDateReasonShown == r.inferredDateReason)
    }

    @Test("a user date still outranks everything; the year-only rule never touches it")
    func userDateWins() {
        let r = capeEditReplica()
        r.userDate = "1992"; r.userDateConfidence = "known"
        #expect(r.resolvedDateDisplay == "1992")
    }
}

@Suite("GH #293 — year-only inferred dates at scale")
struct InferredDateYearOnlyScaleTests {

    @Test("100k legacy year-only rows render through the Date column in budget, none as a day")
    func hundredThousandRows() {
        let rows: [VideoRecord] = (0..<100_000).map { i in
            let r = VideoRecord()
            r.filename = "clip\(i).mov"
            r.inferredRecordDate = noonJan1(1960 + i % 60)
            r.inferredDateConfidence = i % 3 == 0 ? 0.3 : 0.5
            if i % 3 == 0 { r.inferredDateSource = "folder-year" }
            return r
        }
        let start = Date()
        var days = 0
        for r in rows where r.resolvedDateDisplay.count != 4 { days += 1 }
        let elapsed = Date().timeIntervalSince(start)
        #expect(days == 0)
        #expect(elapsed < 2.0, "100k Date-column reads took \(elapsed) s")
    }
}

@Suite("GH #293 — sensor: no year-only inference renders as a fabricated day")
struct InferredDateYearOnlySensorTests {

    @Test("every year-only provenance (folder-year, legacy 0.50–0.60, span) displays as a year")
    func noFabricatedJanFirst() {
        var rows: [VideoRecord] = [capeEditReplica(), legacyPathYearRow(1984), legacyPathYearRow(2001, confidence: 0.55)]
        let spanned = VideoRecord()
        spanned.inferredRecordDate = noonJan1(2003); spanned.inferredDateConfidence = 0.7
        spanned.inferredDateRange = InferredDateRange(startYear: 2003, endYear: 2004)
        spanned.inferredDateReason = "r"
        rows.append(spanned)
        for r in rows {
            #expect(r.inferredDateIsYearOnly, "\(r.filename)")
            #expect(!r.resolvedDateDisplay.contains("-01-01"), "\(r.filename): \(r.resolvedDateDisplay)")
            #expect(InspectorDateView.inferredSummary(r)?.contains("-01-01") == false,
                    "\(r.filename): \(InspectorDateView.inferredSummary(r) ?? "nil")")
        }
    }
}
