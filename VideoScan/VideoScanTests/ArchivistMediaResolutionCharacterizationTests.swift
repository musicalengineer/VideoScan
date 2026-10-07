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
    play => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0])
    watch => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0])
    show => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.show, indices: [0])
    reveal => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.reveal, indices: [0])
    finder => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.reveal, indices: [0])
    play it => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0])
    play them => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0, 1, 2])
    play those => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0, 1, 2])
    play one of them => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0])
    show these => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.show, indices: [0, 1, 2])
    play all => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0, 1, 2])
    play both of them => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0, 1, 2])
    play everything => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0, 1, 2])
    play the first one => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0])
    play the second one => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [1])
    play the 3rd one => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [2])
    play number 2 => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [1])
    play number 9 => declineOutOfRange(requested: 9, available: 3)
    show me number 3 => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.show, indices: [2])
    play the twelfth one => declineOutOfRange(requested: 12, available: 3)
    play two => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0])
    play the last one => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [2])
    play the latest one => dateOrdered(order: VideoScan.ArchivistFollowUpResolver.DateOrder.newestFirst, ordinal: 1, verb: Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.play))
    show it in finder => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.reveal, indices: [0])
    show me the first one in finder => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.reveal, indices: [0])
    reveal it => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.reveal, indices: [0])
    reveal the last one => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.reveal, indices: [2])
    play the one from 1994 => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0])
    play the one from 1987 => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [2])
    play the one from 1960 => declineNoMatchingItem("1960")
    play the ones from 1994 => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0])
    play the second one from 1994 => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [1])
    play the last one from 1994 => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [1])
    play all of the ones from 1994 => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0, 1])
    play the cape one => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0])
    play the cape ones => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0])
    play the lighthouse one => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [2])
    play the cape one from 1994 => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0])
    play the cape one from 1987 => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [2])
    play the zebra one => searchThenPlay("the zebra one")
    show the one called christmas => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.show, indices: [1])
    play the one with cape => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0])
    play cape cod => searchThenPlay("cape cod")
    show cape cod => none
    reveal cape cod => none
    play 1994 => searchThenPlay("1994")
    show 1994 => none
    play something from 1994 => searchThenPlay("something from 1994")
    play the second cape one => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [2])
    play the last cape one => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [2])
    play every cape one => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0, 2])
    play number 2 from 1994 => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [1])
    show me the one about christmas => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.show, indices: [1])
    please play it => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0])
    can you play the first one => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0])
    ok play them all => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0, 1, 2])
    play it again => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0])
    play that one => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0])
    play the video => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0])
    play the clip from 1994 => mediaAction(verb: VideoScan.ArchivistFollowUpResolver.MediaVerb.play, indices: [0])
    """

    static let goldenEmpty = """
    play => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.play))
    watch => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.play))
    show => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.show))
    reveal => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.reveal))
    finder => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.reveal))
    play it => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.play))
    play them => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.play))
    play those => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.play))
    play one of them => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.play))
    show these => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.show))
    play all => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.play))
    play both of them => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.play))
    play everything => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.play))
    play the first one => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.play))
    play the second one => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.play))
    play the 3rd one => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.play))
    play number 2 => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.play))
    play number 9 => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.play))
    show me number 3 => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.show))
    play the twelfth one => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.play))
    play two => searchThenPlay("two")
    play the last one => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.play))
    play the latest one => dateOrdered(order: VideoScan.ArchivistFollowUpResolver.DateOrder.newestFirst, ordinal: 1, verb: Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.play))
    show it in finder => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.reveal))
    show me the first one in finder => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.reveal))
    reveal it => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.reveal))
    reveal the last one => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.reveal))
    play the one from 1994 => searchThenPlay("the one from 1994")
    play the one from 1987 => searchThenPlay("the one from 1987")
    play the one from 1960 => searchThenPlay("the one from 1960")
    play the ones from 1994 => searchThenPlay("the ones from 1994")
    play the second one from 1994 => searchThenPlay("the second one from 1994")
    play the last one from 1994 => searchThenPlay("the last one from 1994")
    play all of the ones from 1994 => searchThenPlay("all of the ones from 1994")
    play the cape one => searchThenPlay("the cape one")
    play the cape ones => searchThenPlay("the cape ones")
    play the lighthouse one => searchThenPlay("the lighthouse one")
    play the cape one from 1994 => searchThenPlay("the cape one from 1994")
    play the cape one from 1987 => searchThenPlay("the cape one from 1987")
    play the zebra one => searchThenPlay("the zebra one")
    show the one called christmas => none
    play the one with cape => searchThenPlay("the one with cape")
    play cape cod => searchThenPlay("cape cod")
    show cape cod => none
    reveal cape cod => none
    play 1994 => searchThenPlay("1994")
    show 1994 => none
    play something from 1994 => searchThenPlay("something from 1994")
    play the second cape one => searchThenPlay("the second cape one")
    play the last cape one => searchThenPlay("the last cape one")
    play every cape one => searchThenPlay("every cape one")
    play number 2 from 1994 => searchThenPlay("number 2 from 1994")
    show me the one about christmas => none
    please play it => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.play))
    can you play the first one => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.play))
    ok play them all => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.play))
    play it again => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.play))
    play that one => declineNoPriorResult(Optional(VideoScan.ArchivistFollowUpResolver.MediaVerb.play))
    play the video => searchThenPlay("the video")
    play the clip from 1994 => searchThenPlay("the clip from 1994")
    """
}
