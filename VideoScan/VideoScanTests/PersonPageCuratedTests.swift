// PersonPageCuratedTests.swift
// A person's People-tab page is a SHORT curated list (Rick 2026-10-24,
// DECISIONS "People tab vs Catalog"): at most PersonVideoPage.curatedCap rows
// — Rick's picks first, in his order (all of them, even past the cap), then
// the best of the rest, one row per piece of footage; hidden videos never.
// Below it, "See all N videos of <name> in the Catalog →" opens the Catalog
// with the Person picker set to them and Folders Only off.
//
//   LOGIC      ranking (confirmed > face; archived first; longer; title);
//              the cap (picks all shown, fill stops at the cap); no two rows
//              of one footage; hidden excluded; the honest Catalog count and
//              its words.
//   TRUTH      the count is the Catalog filter's own (same matcher, same
//              records): files equal CatalogPersonFilter.apply's rows.
//   ISOLATION  the link writes only Folders Only (a throwaway defaults
//              suite) and the session store.
//   SCALE      100k records, the person in 2k: the page in the People page
//              budget (500 ms).
//   SENSOR     the long "More videos tagged" list is gone; one cap constant;
//              the People view goes through the link seam.
//   (Media matrix: N/A — catalog and profile metadata only.)
// Synthetic fixtures only (sandbox POI store under the test host).

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func row(_ title: String, tier: PersonVideoTier = .tagged, archived: Bool = false,
                 seconds: Double = 60) -> PersonVideoRow {
    PersonVideoRow(id: UUID(), path: "/Volumes/test_T/\(title)", title: title, year: 1990,
                   durationSeconds: seconds, tier: tier, isArchived: archived, volume: "")
}

private func group(_ lead: PersonVideoRow, _ versions: PersonVideoRow...) -> PersonVideoGroup {
    PersonVideoGroup(lead: lead, versions: versions)
}

// MARK: - Ranking and the cap (pure)

@Suite("People page — curated: ranking and the cap")
struct PersonPageCuratedRankingTests {

    @Test func confirmedBeforeFaceArchivedBeforeNotLongerBeforeShorter() {
        let groups = [
            group(row("a-face-arch-long", tier: .foundByFace, archived: true, seconds: 9_000)),
            group(row("Beta", seconds: 600)),
            group(row("c-tag-arch-short", archived: true, seconds: 100)),
            group(row("e-face-long", tier: .foundByFace, seconds: 9_000)),
            group(row("d-tag-arch-long", archived: true, seconds: 900)),
            group(row("f-face-lead", tier: .foundByFace, seconds: 50), row("f-tagged-version", seconds: 50)),
            group(row("Alpha", seconds: 600)),
        ]
        #expect(PersonVideos.ranked(groups).map(\.lead.title) == [
            "d-tag-arch-long", "c-tag-arch-short",          // confirmed + archived, longer first
            "Alpha", "Beta",                                 // confirmed, same length: by title
            "f-face-lead",                                   // a confirmed version makes the footage confirmed
            "a-face-arch-long", "e-face-long",               // face matches: archived first
        ])
    }

    @Test func picksAreAllShownEvenPastTheCap() {
        let picks = (0..<20).map { group(row("pick\($0)")) }
        let tagged = (0..<10).map { group(row("t\($0)", seconds: 9_000)) }
        let page = PersonVideos.curate(picks: picks, tagged: tagged)
        #expect(page.map(\.id) == picks.map(\.id), "Rick's 20 picks, his order, no fill")
    }

    @Test func theFillStopsAtTheCapBestFirst() {
        #expect(PersonVideoPage.curatedCap == 15)
        let picks = [group(row("p2")), group(row("p1")), group(row("p3"))]
        let tagged = (0..<30).map { group(row(String(format: "t%02d", $0), seconds: Double($0))) }
        let page = PersonVideos.curate(picks: picks, tagged: tagged)
        #expect(page.count == PersonVideoPage.curatedCap)
        #expect(page.prefix(3).map(\.lead.title) == ["p2", "p1", "p3"], "picks first, in Rick's order")
        #expect(page.dropFirst(3).map(\.id) == PersonVideos.ranked(tagged).prefix(12).map(\.id), "then the best 12")
        #expect(PersonVideos.curate(picks: [], tagged: Array(tagged.prefix(5))).count == 5, "fewer than the cap: all")
        #expect(PersonVideos.curate(picks: [], tagged: tagged, cap: 4).count == 4, "the cap is a parameter")
    }

    @Test func theSeeAllWords() {
        #expect(PersonVideoPage.seeAllWords(videos: 3, files: 4, name: "Dana")
                == "See all 3 videos \u{00B7} 4 files of Dana in the Catalog \u{2192}")
        #expect(PersonVideoPage.seeAllWords(videos: 2, files: 2, name: "Dana") == "See all 2 videos of Dana in the Catalog \u{2192}")
        #expect(PersonVideoPage.seeAllWords(videos: 1, files: 1, name: "Dana") == "See 1 video of Dana in the Catalog \u{2192}")
        #expect(PersonVideoPage.seeAllWords(videos: 1, files: 3, name: "Dana")
                == "See 1 video \u{00B7} 3 files of Dana in the Catalog \u{2192}")
        #expect(PersonVideoPage.seeAllWords(videos: 0, files: 0, name: "Dana").isEmpty, "nothing to see: no link")
    }
}

// MARK: - The page (model, sandbox profiles)

@MainActor
@Suite("People page — curated: the page")
struct PersonPageCuratedPageTests {

    private func rec(_ name: String, digest: String? = nil, seconds: Double = 600, detected: [String] = [],
                     confirmed: [String] = [], suspected: [String] = [], rejected: [String] = [],
                     from parent: VideoRecord? = nil) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = "/Volumes/test_T/\(name)"
        r.filename = name
        r.directory = "/Volumes/test_T"
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.sizeBytes = 4_096
        r.durationSeconds = seconds
        r.detectedPeople = detected
        r.suspectedPeople = suspected
        r.rejectedPeople = rejected
        r.confirmedByUserPeople = confirmed.map { ConfirmedTag(name: $0, confirmedAt: Date()) }
        r.userDate = "1990"
        if let digest {
            r.contentFixity = ContentFixity(digest: digest, byteCount: 4_096,
                                            stamp: FileIdentityStamp(device: 1, inode: UInt64.random(in: 1...1_000_000),
                                                                     size: 4_096, mtimeNs: 3))
        }
        if let parent {
            r.derivedFrom = parent.id
            r.derivationKind = "transcode"
        }
        return r
    }

    private func digest(_ c: Character) -> String { String(repeating: String(c), count: 64) }

    private func model(_ recs: [VideoRecord]) -> VideoScanModel {
        let m = VideoScanModel()
        m.records = recs
        m.searchIndex.rebuild(records: recs)
        return m
    }

    private func savedPerson() throws -> POIProfile {
        let p = POIProfile(name: "Curated\(UUID().uuidString.prefix(6))", referencePath: "")
        try p.save()
        return p
    }

    private func page(_ p: POIProfile, _ m: VideoScanModel) throws -> PersonVideoPage {
        PersonVideos.page(for: try #require(POIProfile.listAll().first { $0.uuid == p.uuid }), in: m)
    }

    /// A pick's byte copy and its edit sit under the pick; two edits of one
    /// untagged raw are one row; every curated row is its own footage.
    @Test func noTwoRowsOfOneFootage() throws {
        let p = try savedPerson()
        let a1 = rec("a1.mov", digest: digest("a"), confirmed: [p.name])
        let a2 = rec("copy/a1.mov", digest: digest("a"), detected: [p.name])
        let a3 = rec("a1-edit.mov", digest: digest("b"), confirmed: [p.name], from: a1)
        let raw = rec("raw.dv", seconds: 3_000)
        let b1 = rec("b1.mov", digest: digest("c"), detected: [p.name], from: raw)
        let b2 = rec("b2.mov", digest: digest("d"), detected: [p.name], from: raw)
        let c = rec("c.mov", digest: digest("e"), detected: [p.name])
        let m = model([a1, a2, a3, raw, b1, b2, c])
        FeaturedVideos.set([a1], on: true, for: p.uuid)

        let curated = try page(p, m).curated
        #expect(curated.count == 3, "\(curated.map(\.lead.title))")
        #expect(curated.first?.lead.id == a1.id, "the pick leads")
        #expect(Set(curated.first?.rows.map(\.id) ?? []) == [a1.id, a2.id, a3.id], "its copy and edit sit under it")
        let ids = curated.flatMap(\.rows).map(\.id)
        #expect(ids.count == Set(ids).count, "no file twice")
        #expect(curated.filter { !Set($0.rows.map(\.id)).isDisjoint(with: [b1.id, b2.id]) }.count == 1,
                "two edits of one raw: one row")
    }

    @Test func hiddenVideosNeverAppear() throws {
        let p = try savedPerson()
        let t1 = rec("t1.mov", digest: digest("1"), confirmed: [p.name])
        let t2 = rec("t2.mov", digest: digest("2"), detected: [p.name])
        let pick = rec("pick.mov", digest: digest("3"), confirmed: [p.name])
        let m = model([t1, t2, pick])
        FeaturedVideos.set([pick], on: true, for: p.uuid)
        #expect(try Set(page(p, m).curated.map(\.id)) == [t1.id, t2.id, pick.id], "precondition")

        PersonVideoRemoval.perform(.removeFromPage, recs: [t1], profile: p, model: m)
        PersonVideoRemoval.perform(.removeFromPage, recs: [pick], profile: p, model: m)

        let after = try page(p, m)
        #expect(after.curated.map(\.id) == [t2.id])
        #expect(Set(after.hidden.flatMap(\.rows).map(\.id)) == [t1.id, pick.id], "listed under 'N hidden — Show'")
    }

    /// The link's N is the Catalog filter's own answer: every live record
    /// tagged or found by face (hidden ones too — a hide is page-only),
    /// grouped by the same proven evidence; maybes, rejections and removed
    /// records out.
    @Test func theCatalogCountIsHonest() throws {
        let p = try savedPerson()
        let a1 = rec("a1.mov", digest: digest("a"), confirmed: [p.name])
        let a2 = rec("copy/a1.mov", digest: digest("a"), confirmed: [p.name])
        let b = rec("b.mov", digest: digest("b"), detected: [p.name])
        let maybe = rec("c.mov", digest: digest("c"), suspected: [p.name])
        let rejected = rec("d.mov", digest: digest("d"), detected: [p.name], rejected: [p.name])
        let hidden = rec("e.mov", digest: digest("e"), confirmed: [p.name])
        let removed = rec("f.mov", digest: digest("f"), confirmed: [p.name])
        removed.purgedAt = Date()
        let m = model([a1, a2, b, maybe, rejected, hidden, removed])
        PersonVideoRemoval.perform(.removeFromPage, recs: [hidden], profile: p, model: m)

        let built = try page(p, m)
        #expect(built.catalogVideos == 3 && built.catalogFiles == 4, "A (2 copies), B, E: \(built.catalogVideos)/\(built.catalogFiles)")
        let live = m.records.filter { !$0.isPurged && !$0.isSetAside }
        #expect(CatalogPersonFilter.apply(live, person: CatalogPerson(p)).count == built.catalogFiles,
                "the same files the Catalog's Person filter shows")
    }

    /// The link: the picker set to this person, Folders Only off, the
    /// folder view and everything else left alone; the Catalog tab.
    @Test func theCatalogLinkSetsThePickerAndTurnsFoldersOnlyOff() throws {
        let suite = "PersonPageCuratedTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        CatalogFootageFoldersSetting.set(true, defaults)
        CatalogFoldersOnlySetting.set(true, defaults)
        let store = CatalogPersonFilterStore()
        var p = POIProfile(name: "Dana", referencePath: "")
        p.aliases = ["Dana B."]

        let tab = CatalogPersonLink.showAll(of: p, in: store, defaults: defaults)

        #expect(tab == MainTab.catalog.rawValue)
        #expect(store.selected?.id == p.uuid && store.selected?.name == "Dana B.")
        #expect(!CatalogFoldersOnlySetting.isOn(defaults), "Folders Only off")
        #expect(CatalogFootageFoldersSetting.isOn(defaults), "the folder view itself is left alone")
        #expect(!CatalogFoldersOnlyRule.launchFoldersOnly(defaults), "the rebuilt Catalog view reads it off")
        store.reload([POIProfile(name: "Ann", referencePath: ""), p])
        #expect(store.selected?.id == p.uuid, "the Catalog's own reload keeps the choice")
    }

    // MARK: Scale

    /// 100k records, the person in 2k (two edits of each untagged raw); the
    /// whole page — curated list and the Catalog count — in 500 ms.
    @Test func hundredThousandRecordsCuratedPageInBudget() {
        let p = POIProfile(name: "Scalecurated", referencePath: "")
        var records: [VideoRecord] = []
        records.reserveCapacity(101_000)
        var raw = rec("raw0.dv", seconds: 3_000)
        for i in 0..<100_000 {
            if i % 100 == 0 {
                raw = rec("raw\(i).dv", seconds: 3_000)
                records.append(raw)
            }
            if i % 50 == 0 {
                records.append(rec("v\(i).mov", digest: String(format: "%064x", i), seconds: Double(2_000 + i % 7),
                                   detected: i % 100 == 0 ? ["Scalecurated"] : [],
                                   confirmed: i % 100 == 0 ? [] : ["Scalecurated"], from: raw))
            } else {
                records.append(rec("x\(i).mov", detected: i % 7 == 0 ? ["Someone"] : []))
            }
        }
        let m = model(records)
        let clock = ContinuousClock()
        var built = PersonVideoPage.empty
        let elapsed = clock.measure { built = PersonVideos.page(for: p, in: m) }
        #expect(built.curated.count == PersonVideoPage.curatedCap)
        #expect(built.catalogFiles == 2_000)
        #expect(built.catalogVideos == 1_000, "two edits of each raw are one piece of footage")
        #expect(built.curated.allSatisfy { $0.lead.tier == .tagged || $0.rows.contains { $0.tier == .tagged } },
                "confirmed footage fills first")
        #expect(elapsed < .milliseconds(500), "curated page for one person took \(elapsed)")
    }
}

// MARK: - Sensor

@Suite("People page — curated wiring sensor")
struct PersonPageCuratedSensorTests {

    private func code(_ name: String) throws -> String {
        try SourceTree.strippingComments(SourceTree.appSource(named: name))
    }

    @Test func theLongListIsGoneAndTheLinkGoesThroughTheSeam() throws {
        let section = try code("PersonVideosSection.swift")
        #expect(!section.contains("More videos tagged"), "the long list is replaced by the Catalog link")
        #expect(!section.contains("showMaybes") && !section.contains("showTagged"))
        #expect(section.contains("ForEach(page.curated)"), "the page shows the curated list")
        #expect(section.contains("onShowAllInCatalog"))
        #expect(section.components(separatedBy: "static let curatedCap = 15").count == 2, "one named cap")
        #expect(section.contains("hiddenFooter"), "the hide footer stays")
        let finder = try code("PersonFinderView.swift")
        #expect(finder.contains("CatalogPersonLink.showAll(of: profile, in: catalogPersonFilter)"))
    }
}
