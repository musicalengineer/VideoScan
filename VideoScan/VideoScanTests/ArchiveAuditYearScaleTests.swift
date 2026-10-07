import Foundation
import Testing
@testable import VideoScan

// Archive ▸ Audit <year>… — SCALE (CLAUDE.md dimension 2). The builder
// runs off-main once per open over EVERY archived card (the
// filed-from-another-year rule indexes the whole archive). 100k cards —
// far beyond the real archive for years — with 2,000 of them in the
// audited year, half carrying transcripts, must build well under a
// budget, and every planted repeat must be found (a sensor: the counts
// are pinned, so a rule that silently stops firing fails here).

@Suite("Audit year — 100k archived cards budget")
struct ArchiveAuditYearScaleTests {

    private static let phrases = [
        "happy birthday to you happy birthday dear timmy blow out the candles now",
        "merry christmas everybody look at the tree and all the presents under it this morning",
        "we are at the lake and the water is cold but the kids are swimming anyway today",
        "grandpa is telling the story about the marines again while everybody eats dessert",
    ]

    /// Even cards i and i+2 tell the same 20-word story (k = i / 4); each
    /// then ends in a stock phrase shared by 250 cards — common enough to be
    /// skipped as evidence (maxPosting), so only the story makes the match.
    private static func transcript(_ i: Int) -> String {
        let k = i / 4
        let story = (0..<20).map { "w\($0)x\(k)" }.joined(separator: " ")
        return story + " " + phrases[i % phrases.count]
    }

    private func cards() -> [ArchiveAuditInput] {
        var out: [ArchiveAuditInput] = []
        out.reserveCapacity(100_000)
        let groups = (0..<5).map { _ in UUID() }
        for i in 0..<100_000 {
            let year = i < 2_000 ? 1995 : 1940 + i % 85
            let id = UUID()
            var c = ArchiveAuditInput(id: id, title: "Clip \(i)", year: year == 1995 && i >= 2_000 ? 1996 : year,
                                      durationSeconds: Double(60 + i % 600))
            c.memberIDs = [id]
            c.lineageKeys = [id]
            c.occasion = i % 5 == 0 ? .unlabeled
                : ArchiveOccasionCue(occasion: .birthday, word: "Birthday \(i % 300)", help: "")
            // Plant: every 50th card shares a content hash with its neighbour.
            if i % 50 == 1 { c.contentHashes = ["v1:\(i - 1)"] }
            if i % 50 == 0 { c.contentHashes = ["v1:\(i)"] }
            // Plant: footage groups spanning 1995 and other years.
            // Five groups, each with one 1995 card (7, 407, … 1607) and ~49
            // cards filed in other years.
            if i % 400 == 7 { c.footageGroupIDs = [groups[(i / 400) % 5]] }
            if i < 2_000 && i % 2 == 0 { c.transcript = Self.transcript(i) }
            out.append(c)
        }
        return out
    }

    @Test func build100kCardAuditUnderBudget() {
        let inputs = cards()
        let start = ContinuousClock.now
        let r = ArchiveAuditBuilder.build(year: 1995, inputs: inputs, decisions: [])
        let elapsed = ContinuousClock.now - start

        let inYear = inputs.filter { $0.year == 1995 }.count
        #expect(inYear == 2_000)
        #expect(r.repeats.filter { $0.kind == .sameFootage }.count == 40, "one per planted hash pair in 1995")
        #expect(r.repeats.filter { $0.kind == .possiblySame }.count == 500,
                "every planted story pair; stock phrases alone match nothing")
        #expect(r.repeats.filter { $0.kind == .filedFromAnotherYear }.count == 5,
                "cards 7, 407, 807, 1207, 1607 share a group with other years")
        #expect(r.unlabeledIDs.count == 400)
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(3)), "100k audit build took \(elapsed)")
    }
}
