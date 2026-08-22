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
