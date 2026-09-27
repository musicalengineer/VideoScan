import Testing
import Foundation
@testable import VideoScan

// Codex review F4 (P2): with a displaced software stamp the Date column
// returned moved.isoString ("2003") and never reached the range branch;
// without the stamp the same inference read "2003–2004".

@MainActor
@Suite("Codex F4 — a ranged inference reads the same with or without a displaced stamp; files under its point's UTC year")
struct DateReviewF4Tests {
    typealias F = DateReviewFixtures

    private func ranged(stamp: Bool, point: Int = 2003) -> VideoRecord {
        let r = VideoRecord()
        r.filename = "tape.mov"
        if stamp { r.embeddedCreationDate = F.utc(2008, 6, 1); r.originEncoder = "Apple ProRes 422" }
        r.inferredRecordDate = pfJanuaryFirst(of: point)
        r.inferredDateConfidence = 0.8
        r.inferredDateRange = InferredDateRange(startYear: 2003, endYear: 2004)
        r.inferredDateReason = "spoken now-cue 'christmas… 2003'; spoken now-cue 'new year… 2004'"
        return r
    }

    @Test("Date column: '2003–2004' both ways; sort key identical")
    func sameDisplayWithAndWithoutStamp() {
        let with = ranged(stamp: true), without = ranged(stamp: false)
        #expect(without.resolvedDateDisplay == "2003–2004")
        #expect(with.resolvedDateDisplay == "2003–2004", "got \(with.resolvedDateDisplay)")
        #expect(with.resolvedDateSortKey == UserDateEntry.date(from: "2003"))
        #expect(without.resolvedDateSortKey == pfJanuaryFirst(of: 2003))
    }

    @Test("dateHint is year-only and deterministic: the inferred POINT's UTC year, not a range endpoint")
    func filesUnderThePointYear() {
        #expect(ArchivePathResolver.facts(for: ranged(stamp: true)).dateHint == .year(2003))
        #expect(ArchivePathResolver.facts(for: ranged(stamp: false)).dateHint == .year(2003))
        // A point of 2004 inside the same 2003–2004 range files under 2004.
        #expect(ArchivePathResolver.facts(for: ranged(stamp: true, point: 2004)).dateHint == .year(2004))
        #expect(ArchivePathResolver.facts(for: ranged(stamp: false, point: 2004)).dateHint == .year(2004))
    }
}
