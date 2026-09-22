// ArchiveItemVersionsTests.swift
// One card per archive item, its versions as chips (Rick 2026-09-22).
// Fixtures are the REAL FamilyArchive filenames of 2026-09-22 (1965,
// 1990, 1994, 1998 folders), so the grouping is pinned against the names
// the app actually wrote — including the Angel outputs filed under their
// render year.
//
// Five dimensions: LOGIC (roles, keys, grouping rules), SCALE (10k items
// under a budget), SENSOR (nothing ever vanishes: every input id appears
// exactly once as a card or a chip). MEDIA MATRIX / ISOLATION: n/a — pure
// strings, no files, no global state.

import Foundation
import Testing
@testable import VideoScan

@Suite("Archive timeline — versions fold into one card")
struct ArchiveItemVersionsTests {

    private func item(_ rel: String) -> ArchiveTimelineItem {
        let name = (rel as NSString).lastPathComponent
        return ArchiveTimelineItem(id: UUID(), title: ArchiveTimelinePath.title(fromArchiveFilename: name),
                                   archiveFilename: name, relPath: rel,
                                   year: ArchiveTimelinePath.year(fromRelPath: rel),
                                   kind: .video, durationSeconds: 60, peopleText: "", isVerified: true)
    }

    private func cards(_ rels: [String]) -> [ArchiveTimelineItem] {
        ArchiveItemVersions.group(rels.map(item))
    }

    /// Every input id appears exactly once — as a card or a chip.
    private func expectNothingVanishes(_ input: [String], _ out: [ArchiveTimelineItem]) {
        let ids = out.flatMap { $0.versions.isEmpty ? [$0.id] : $0.versions.map(\.id) }
        #expect(ids.count == input.count && Set(ids).count == input.count, "every file shows exactly once")
    }

    @Test("1965: original + cleaned + the Angel's three .vs.* files → ONE card with five chips")
    func the1960sReel() {
        let rels = [
            "30_Video/1960-1969/1965/1960s-with-music-3-songs.vs.archive.mov",
            "30_Video/1960-1969/1965/1960s-with-music-3-songs.vs.edit.mov",
            "30_Video/1960-1969/1965/1960s-with-music-3-songs.vs.preserve.mkv",
            "30_Video/1960-1969/1965/1965-xx-xx_1960s-with-music-3-songs_cleaned.mov",
            "30_Video/1960-1969/1965/1965-xx-xx_1960s-with-music-3-songs.mov",
        ]
        let out = cards(rels)
        #expect(out.count == 1)
        #expect(out.first?.archiveFilename == "1965-xx-xx_1960s-with-music-3-songs.mov", "the original is the card's face")
        #expect(out.first?.versions.map(\.label) == ["original", "preservation", "access", "editable", "restored"])
        expectNothingVanishes(rels, out)
    }

    @Test("an Angel output filed under its RENDER year joins the original's card (Christmas 1990 Part 3 sat in 1994)")
    func misfiledAngelOutputJoinsItsOriginal() {
        let rels = [
            "30_Video/1990-1999/1990/1990-xx-xx_Christmas1990-Part3-47mins.mov",
            "30_Video/1990-1999/1990/1990-xx-xx_Christmas1990-Part3-47mins_balanced.mov",
            "30_Video/1990-1999/1994/Christmas1990-Part3-47mins.vs.archive.mov",
            "30_Video/1990-1999/1994/Christmas1990-Part3-47mins.vs.preserve.mkv",
            "30_Video/1990-1999/1994/1994-xx-xx_Christmas_1994_etc.mkv",
        ]
        let out = cards(rels)
        let xmas90 = out.first { $0.archiveFilename.contains("Christmas1990") }
        #expect(xmas90?.year == 1990, "the card sits in the memory's year")
        #expect(xmas90?.versions.map(\.label) == ["original", "preservation", "access", "restored"])
        #expect(out.contains { $0.archiveFilename == "1994-xx-xx_Christmas_1994_etc.mkv" && $0.versions.isEmpty },
                "a different Christmas is untouched")
        #expect(out.count == 2)
        expectNothingVanishes(rels, out)
    }

    @Test("a promote collision (_02) is 'version 2' of its item; doubled date prefixes are stripped from titles")
    func collisionSuffixAndDoubledPrefix() {
        let rels = [
            "30_Video/1990-1999/1990/1990-xx-xx_1990-xx-xx_Christmas-1990-something_02.mov",
            "30_Video/1990-1999/1990/1990-xx-xx_1990-xx-xx_Christmas-1990-something.mov",
        ]
        let out = cards(rels)
        #expect(out.count == 1)
        #expect(out.first?.title == "Christmas-1990-something")
        #expect(out.first?.versions.map(\.label) == ["original", "version 2"])
        #expect(ArchiveTimelinePath.title(fromArchiveFilename: "1984-xx-xx_xxxx-xx-xx_Thanksgiving-Raw.mov") == "Thanksgiving-Raw")
    }

    @Test("promoted -vs-edit names and _02 of them group with each other, not with a differently-named item")
    func promotedEditNames() {
        let rels = [
            "30_Video/1980-1989/1984/1984-xx-xx_xxxx-xx-xx_Thanksgiving-Raw_Default_denoise_thm2_nyx3_hyp1-vs-edit_02.mov",
            "30_Video/1980-1989/1984/1984-xx-xx_xxxx-xx-xx_Thanksgiving-Raw_Default_denoise_thm2_nyx3_hyp1-vs-edit.mov",
            "30_Video/1980-1989/1984/1984-11-xx_Thanksgiving_1984.mkv",
            "30_Video/1980-1989/1984/1984-xx-xx_Mark-s-Bday-1984-mo4C0189BF_combined.mov",
            "30_Video/1980-1989/1984/Mark's-Bday-1984.mo4C0189BF_combined.vs.archive.mov",
        ]
        let out = cards(rels)
        let raw = out.first { $0.archiveFilename.contains("Thanksgiving-Raw") }
        #expect(raw?.versions.count == 2 && raw?.versions.allSatisfy { $0.role == .editable || $0.role == .original } == true)
        #expect(out.contains { $0.archiveFilename == "1984-11-xx_Thanksgiving_1984.mkv" && $0.versions.isEmpty })
        let mark = out.first { $0.archiveFilename.hasPrefix("1984-xx-xx_Mark") }
        #expect(mark?.versions.map(\.label) == ["original", "access"], "apostrophe vs dash in the stem still groups")
        expectNothingVanishes(rels, out)
    }

    @Test("camera-counter stems never group across years; within a folder they only take their own .vs.* siblings")
    func genericStemsStayPut() {
        let rels = [
            "30_Video/1990-1999/1998/Clip 04.vs.preserve.mkv",
            "30_Video/1990-1999/1990/1990-xx-xx_Clip 04.dv",
            "30_Video/1990-1999/1990/clip-135-02-05 05;27;15 1.vs.archive.mov",
            "30_Video/1990-1999/1990/clip-135-02-05 05;27;15 1.vs.preserve.mkv",
        ]
        let out = cards(rels)
        #expect(out.contains { $0.relPath.hasPrefix("30_Video/1990-1999/1998/Clip 04") && $0.versions.isEmpty },
                "a 1998 'Clip 04' is not folded into a 1990 'Clip 04'")
        let clip135 = out.first { $0.archiveFilename.hasPrefix("clip-135") }
        #expect(clip135?.versions.map(\.label).sorted() == ["access", "preservation"])
        expectNothingVanishes(rels, out)
    }

    @Test("a single-file item has no chips; unrelated items are never merged")
    func singlesStaySingle() {
        let rels = [
            "30_Video/1990-1999/1994/1994-xx-xx_CapeCod_1994.mov",
            "30_Video/1990-1999/1994/1994-xx-xx_Westford_1994-1995.mkv",
        ]
        let out = cards(rels)
        #expect(out.count == 2 && out.allSatisfy { $0.versions.isEmpty })
    }

    @Test("the timeline finds a folded version's card (hand-off lands on the item), and search sees version names")
    func cardLookupAndSearch() {
        let rels = [
            "30_Video/1960-1969/1965/1965-xx-xx_1960s-with-music-3-songs.mov",
            "30_Video/1960-1969/1965/1965-xx-xx_1960s-with-music-3-songs_cleaned.mov",
        ]
        let out = cards(rels)
        let card = try! #require(out.first)
        let cleanedID = card.versions.first { $0.role == .restored }!.id
        let tl = ArchiveTimeline.build(items: out)
        #expect(tl.cardID(for: cleanedID) == card.id)
        #expect(ArchiveTimeline.build(items: out, matching: "cleaned").datedCount == 1)
    }

    @Test("SCALE + SENSOR: 10,000 items group in under 1 s and none vanish")
    func tenThousand() {
        var rels: [String] = []
        for i in 0..<2_500 {
            let y = 1960 + i % 60
            let dec = "\(y / 10 * 10)-\(y / 10 * 10 + 9)"
            rels.append("30_Video/\(dec)/\(y)/\(y)-xx-xx_FamilyReel\(i).mov")
            rels.append("30_Video/\(dec)/\(y)/\(y)-xx-xx_FamilyReel\(i)_cleaned.mov")
            rels.append("30_Video/\(dec)/\(y)/FamilyReel\(i).vs.archive.mov")
            rels.append("30_Video/\(dec)/\(y + 3)/FamilyReel\(i).vs.preserve.mkv")
        }
        let input = rels.map(item)
        let t0 = Date()
        let out = ArchiveItemVersions.group(input)
        let elapsed = Date().timeIntervalSince(t0)
        #expect(out.count == 2_500)
        #expect(elapsed < 1.0, "took \(elapsed) s")
        expectNothingVanishes(rels, out)
    }
}
