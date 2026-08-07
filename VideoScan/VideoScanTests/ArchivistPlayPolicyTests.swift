import Testing
import Foundation
@testable import VideoScan

// ArchivistPlayPolicy — the honest-play selection seam (codex #300-
// #305). Selection uses CACHED reachability only (the fileExists-on-
// MainActor version was NO-GO'd as the documented 60s beachball
// class); existence is probed off-main for the single chosen file by
// the caller. codex extends with chip/flow interleavings.
@MainActor
struct ArchivistPlayPolicyTests {

    private func record(_ name: String, path: String) -> VideoRecord {
        let rec = VideoRecord()
        rec.filename = name
        rec.fullPath = path
        return rec
    }

    @Test func firstReachableWinsInCatalogOrder() {
        let a = record("a.mov", path: "/Volumes/Off/a.mov")
        let b = record("b.mov", path: "/Volumes/On/b.mov")
        let c = record("c.mov", path: "/Volumes/On/c.mov")
        let choice = ArchivistPlayPolicy.choose(
            matches: [a, b, c],
            isReachable: { $0.hasPrefix("/Volumes/On/") })
        #expect(choice == .play(b, substitutedForOffline: true),
                "offline first match substitutes to the FIRST reachable, order preserved")
    }

    @Test func reachableFirstMatchIsNotASubstitution() {
        let a = record("a.mov", path: "/Volumes/On/a.mov")
        let b = record("b.mov", path: "/Volumes/On/b.mov")
        let choice = ArchivistPlayPolicy.choose(
            matches: [a, b], isReachable: { _ in true })
        #expect(choice == .play(a, substitutedForOffline: false))
    }

    @Test func allUnreachableIsNoneNeverFalsePlaying() {
        let a = record("a.mov", path: "/Volumes/Off/a.mov")
        let b = record("b.mov", path: "/Volumes/Off/b.mov")
        #expect(ArchivistPlayPolicy.choose(matches: [a, b],
                                           isReachable: { _ in false }) == .none)
        #expect(ArchivistPlayPolicy.choose(matches: [],
                                           isReachable: { _ in true }) == .none)
    }

    @Test func hundredThousandRecordSelectionStaysCheap() {
        // Scale budget (feature checklist dimension 2): selection is a
        // first(where:) over cached lookups — 100k all-unreachable
        // records (the worst case: full scan) must complete in
        // milliseconds, never a beachball.
        var matches: [VideoRecord] = []
        matches.reserveCapacity(100_000)
        for i in 0..<100_000 {
            matches.append(record("r\(i).mov", path: "/Volumes/Off/r\(i).mov"))
        }
        let started = CFAbsoluteTimeGetCurrent()
        let choice = ArchivistPlayPolicy.choose(matches: matches,
                                                isReachable: { _ in false })
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        #expect(choice == .none)
        #expect(elapsed < 0.25, "100k selection took \(elapsed)s — budget is 250ms")
    }
}
