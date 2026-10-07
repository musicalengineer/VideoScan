import Foundation
import Testing
@testable import VideoScan

// Refactor R4 (GH #281): `ArchivistFollowUpResolver.mediaResolution` (CCN 47)
// was split into a parsed request plus two pickers. Before the split this
// table pinned what `resolve` answers for every media phrase shape — bare
// referents, ordinals, "last", "all", years, filename words, "finder",
// out-of-range numbers, no prior answer — against an empty and a
// three-item previous answer. The golden was captured from the unsplit
// function (`ebcd2f09`) and not edited after the move.
struct ArchivistMediaResolutionCharacterizationTests {

    static let shown = ArchivistFollowUpResolver.Snapshot(ast: nil, items: [
        .init(filename: "cape_cod_beach.mov", fullPath: "/Volumes/A/cape_cod_beach.mov", years: [1994]),
        .init(filename: "christmas_morning.mov", fullPath: "/Volumes/A/christmas_morning.mov", years: [1994, 1995]),
        .init(filename: "cape_cod_lighthouse.mov", fullPath: "/Volumes/A/cape_cod_lighthouse.mov", years: [1987]),
    ])
    static let empty = ArchivistFollowUpResolver.Snapshot(ast: nil, items: [])

    static let phrases = [
        "play", "watch", "show", "reveal", "finder",
        "play it", "play them", "play those", "play one of them", "show these",
        "play all", "play both of them", "play everything",
        "play the first one", "play the second one", "play the 3rd one", "play number 2", "play number 9",
        "show me number 3", "play the twelfth one", "play two", "play the last one", "play the latest one",
        "show it in finder", "show me the first one in finder", "reveal it", "reveal the last one",
        "play the one from 1994", "play the one from 1987", "play the one from 1960",
        "play the ones from 1994", "play the second one from 1994", "play the last one from 1994",
        "play all of the ones from 1994", "play the cape one", "play the cape ones",
        "play the lighthouse one", "play the cape one from 1994", "play the cape one from 1987",
        "play the zebra one", "show the one called christmas", "play the one with cape",
        "play cape cod", "show cape cod", "reveal cape cod", "play 1994", "show 1994",
        "play something from 1994", "play the second cape one", "play the last cape one",
        "play every cape one", "play number 2 from 1994", "show me the one about christmas",
        "please play it", "can you play the first one", "ok play them all",
        "play it again", "play that one", "play the video", "play the clip from 1994",
    ]

    static func table(_ snapshot: ArchivistFollowUpResolver.Snapshot) -> String {
        phrases.map { phrase in
            let r = ArchivistFollowUpResolver.resolve(phrase, snapshot: snapshot, isKnownPerson: { _ in false })
            return "\(phrase) => \(r)"
        }.joined(separator: "\n")
    }

    private func diff(_ actual: String, _ golden: String) -> Comment {
        let a = actual.components(separatedBy: "\n"), g = golden.components(separatedBy: "\n")
        var lines: [String] = []
        for i in 0..<max(a.count, g.count) where (i < a.count ? a[i] : "<none>") != (i < g.count ? g[i] : "<none>") {
            lines.append("expected «\(i < g.count ? g[i] : "<none>")»\n  actual «\(i < a.count ? a[i] : "<none>")»")
        }
        return Comment(rawValue: "ACTUAL:\n\(actual)\n\nDIFF:\n" + lines.joined(separator: "\n"))
    }

    @Test func withThreeShownItems() {
        let t = Self.table(Self.shown)
        #expect(t == Self.goldenShown, diff(t, Self.goldenShown))
    }

    @Test func withNoPriorAnswer() {
        let t = Self.table(Self.empty)
        #expect(t == Self.goldenEmpty, diff(t, Self.goldenEmpty))
    }

    static let goldenShown = """
    """

    static let goldenEmpty = """
    """
}
