import Testing
import Foundation
@testable import VideoScan

// Codex review F1 (P1): a user YEAR refined by a SOFTWARE stamp became a
// day-precise .embedded resolution at confidence 1.0; footage sharing read
// that as camera provenance and copied the export's DAY to a sibling, and
// Promote filed by day though Rick typed only a year.

@MainActor
@Suite("Codex F1 — a software stamp never refines a user year, and its day never travels")
struct DateReviewF1Tests {
    typealias F = DateReviewFixtures

    @Test("user '2004' + Apple-no-model export 2004-12-31: resolution and dateHint stay YEAR; a device stamp still refines")
    func userYearSurvivesASoftwareStamp() {
        let r = RecordDateResolver.resolve(userDate: "2004", userDateConfidence: "known",
                                           embeddedCreationDate: F.utc(2004, 12, 31), originMake: "Apple",
                                           inferredRecordDate: nil, inferredDateConfidence: nil,
                                           filename: "clip.mov", now: F.now)
        #expect(r.isoString == "2004" && r.precision == .year && r.source == .userDate, "\(r)")
        let rec = VideoRecord()
        rec.filename = "clip.mov"; rec.userDate = "2004"; rec.userDateConfidence = "known"
        rec.embeddedCreationDate = F.utc(2004, 12, 31); rec.originMake = "Apple"
        #expect(ArchivePathResolver.facts(for: rec).dateHint == .year(2004))
        // A camera (a model is named) still sharpens the user's year.
        let cam = RecordDateResolver.resolve(userDate: "2004", embeddedCreationDate: F.utc(2004, 12, 31),
                                             originMake: "Sony", originModel: "DCR-TRV27",
                                             inferredRecordDate: nil, inferredDateConfidence: nil,
                                             filename: "clip.mov", now: F.now)
        #expect(cam.isoString == "2004-12-31" && cam.source == .embedded)
    }

    @Test("the sibling inherits the YEAR 2004 — never the export's month/day")
    func siblingNeverInheritsTheExportDay() {
        let model = F.model("f1")
        let (a, b) = F.pair()
        a.userDate = "2004"; a.userDateConfidence = "known"
        a.embeddedCreationDate = F.utc(2004, 12, 31); a.originMake = "Apple"
        model.records = [a, b]
        model.catchUpInferredDates(trigger: "test")
        #expect(b.inferredRecordDate == pfJanuaryFirst(of: 2004), "\(String(describing: b.inferredRecordDate))")
        #expect(b.inferredDateRange == InferredDateRange(year: 2004))
        #expect(b.inferredDateReason?.contains("your date 2004") == true, "\(b.inferredDateReason ?? "nil")")
        let rb = F.resolve(b)
        #expect(rb.precision == .year && rb.isoString == "2004", "\(rb)")
        #expect(ArchivePathResolver.facts(for: b).dateHint == .year(2004))
    }
}
