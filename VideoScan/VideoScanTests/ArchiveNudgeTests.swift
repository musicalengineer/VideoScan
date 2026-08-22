import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// "It looks like N files are ready to be archived" — only files a human
/// has vouched for, never junk, never an extra copy (Rick 2026-08-21).
struct ArchiveNudgeTests {

    private func record(_ name: String, stars: Int = 0,
                        disposition: MediaDisposition = .unreviewed,
                        stage: ArchiveStage = .none,
                        dup: DuplicateDisposition = .none,
                        junk: Int = 0,
                        dated: Bool = true) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/LaCie/\(name)"
        r.starRating = stars
        r.mediaDisposition = disposition
        r.archiveStage = stage
        r.duplicateDisposition = dup
        r.junkScore = junk
        if dated {
            r.embeddedCreationDate = Calendar.current.date(from: DateComponents(year: 1994, month: 7, day: 4))
        }
        return r
    }

    @Test func onlyVouchedDatedKeepersAreReady() {
        let nudge = ArchiveNudge.assess([
            record("christmas_1994.mov", stars: 3),
            record("cape.mov", disposition: .important),
            record("ready.mov", stage: .readyForArchive),
            record("unrated.mov"),                              // nobody vouched
            record("one_star.mov", stars: 1),                   // 1 star is not a vouch
            record("copy.mov", stars: 3, dup: .extraCopy),      // never an extra copy
            record("junk.mov", stars: 3, disposition: .suspectedJunk),
            record("scored_junk.mov", stars: 3, junk: 80),
            record("undated.mov", stars: 2, dated: false),
        ])
        #expect(nudge.ready.map(\.filename) == ["cape.mov", "christmas_1994.mov", "ready.mov"])
        #expect(nudge.nearReady.map(\.filename) == ["undated.mov"])
        #expect(nudge.ready.first { $0.filename == "christmas_1994.mov" }?.reasons == ["★★★"])
        #expect(nudge.ready.first { $0.filename == "christmas_1994.mov" }?.year == 1994)
        #expect(nudge.ready.first { $0.filename == "cape.mov" }?.reasons == ["marked Important"])
        #expect(nudge.nearReady.first?.needsDate == true)
        #expect(nudge.nearReady.first?.year == nil)
    }

    @Test func strongerVouchingSortsFirstAndKeepIsNotAVouchByItself() {
        let nudge = ArchiveNudge.assess([
            record("b.mov", stars: 2),
            record("a.mov", stars: 3, disposition: .important, dup: .keep),
            record("keeper_only.mov", dup: .keep),
        ])
        #expect(nudge.ready.map(\.filename) == ["a.mov", "b.mov"])
        #expect(nudge.ready.first?.reasons == ["marked Important", "★★★", "the copy to keep"])
    }

    @Test func headlinesUseLooseHonestWording() {
        #expect(ArchiveNudge.empty.headline.hasPrefix("Nothing is waving its hand yet"))
        #expect(ArchiveNudge.assess([record("x.mov", stars: 3)]).headline
                == "It looks like 1 file is ready to be archived.")
        let many = ArchiveNudge.assess((1...15).map { record("f\($0).mov", stars: 2) }
                                       + [record("u.mov", stars: 2, dated: false)])
        #expect(many.headline == "It looks like 15 files are ready to be archived, and 1 more just need a date.")
        #expect(ArchiveNudge.assess([record("u.mov", stars: 2, dated: false)]).headline
                == "1 keeper is nearly ready — it just needs a date.")
    }

    @Test func copiesOfOneRecordingCollapseToTheKeeperOrTheBestVouched() {
        let group = UUID()
        func copy(_ name: String, stars: Int, dup: DuplicateDisposition) -> VideoRecord {
            let r = record(name, stars: stars, dup: dup)
            r.duplicateGroupID = group
            r.duplicateGroupCount = 3
            return r
        }
        let withKeeper = ArchiveNudge.assess([
            copy("lacie/xmas.mov", stars: 3, dup: .review),
            copy("mybook/xmas.mov", stars: 2, dup: .keep),
            copy("x9/xmas.mov", stars: 3, dup: .review),
        ])
        #expect(withKeeper.ready.map(\.filename) == ["mybook/xmas.mov"], "the chosen keeper wins even with fewer stars")
        #expect(withKeeper.ready.first?.reasons.last == "3 copies — this one")

        let noKeeper = ArchiveNudge.assess([
            copy("lacie/xmas.mov", stars: 2, dup: .review),
            copy("mybook/xmas.mov", stars: 3, dup: .none),
        ])
        #expect(noKeeper.ready.map(\.filename) == ["mybook/xmas.mov"], "no keeper chosen → the best-vouched copy, once")
        #expect(noKeeper.ready.first?.reasons.last == "2 copies — this one")
    }

    @Test func theShortlistIsAtMostFifteenReadyFirstStrongestFirst() {
        var records = (1...20).map { record("r\($0).mov", stars: 2) }
        records.append(record("important.mov", disposition: .important))
        records.append(contentsOf: (1...5).map { record("u\($0).mov", stars: 2, dated: false) })
        let nudge = ArchiveNudge.assess(records)
        #expect(nudge.shortlist.count == ArchiveNudge.listLimit)
        #expect(nudge.shortlist.first?.filename == "important.mov", "strongest vouching first")
        #expect(nudge.shortlist.allSatisfy { !$0.needsDate }, "ready rows fill the list before nearly-ready")
        let few = ArchiveNudge.assess([record("a.mov", stars: 2), record("u.mov", stars: 2, dated: false)])
        #expect(few.shortlist.map(\.filename) == ["a.mov", "u.mov"], "nearly-ready fills in when there is room")
    }

    @Test func sameCameraNameAndLengthCollapsesAndOlderTapesRankFirst() {
        func mts(_ path: String) -> VideoRecord {
            let r = record("00000.MTS", disposition: .important)
            r.fullPath = path
            r.durationSeconds = 612.4
            return r
        }
        let fixture2026 = record("2026-07-05_12-55-56.mkv", disposition: .important)
        fixture2026.embeddedCreationDate = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 5))
        let nudge = ArchiveNudge.assess([
            fixture2026,
            mts("/Volumes/X9/card1/00000.MTS"), mts("/Volumes/X10/card2/00000.MTS"),
            mts("/Volumes/LaCie/00000.MTS"), mts("/Volumes/MyBook/00000.MTS"),
            record("Cape-1993-archive.mkv", disposition: .important),
        ])
        let names = nudge.ready.map(\.filename)
        #expect(names.filter { $0 == "00000.MTS" }.count == 1, "four cards, one recording")
        #expect(names.first == "00000.MTS" || names.first == "Cape-1993-archive.mkv")
        #expect(names.last == "2026-07-05_12-55-56.mkv", "older recordings first among equal vouching")
        #expect(nudge.ready.first { $0.filename == "00000.MTS" }?.reasons.last == "4 copies — this one")
    }

    @Test func tenThousandCandidatesAssessWellUnderASecond() {
        let records = (0..<10_000).map { i in
            record("f\(i).mov", stars: i % 4, disposition: i % 7 == 0 ? .important : .unreviewed,
                   dated: i % 5 != 0)
        }
        let start = Date()
        let nudge = ArchiveNudge.assess(records)
        let elapsed = Date().timeIntervalSince(start)
        #expect(!nudge.isEmpty)
        #expect(elapsed < 1.0, "took \(elapsed)s")
    }
}
