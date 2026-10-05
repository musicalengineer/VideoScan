import Testing
import Foundation
import VideoScanCore
@testable import VideoScan

// "Videos of <person>" — the People tab's primary view (Rick 2026-10-04,
// GH #272 trial). Logic (tiers, aliases, exact names, archive folding is
// covered by the model's own isArchived tests), scale (100k records, a
// person in 2k of them, built in a time budget from the index — never a
// catalog pass), and a sensor that the view keeps it that way.

@Suite("People — videos of a person")
@MainActor
struct PersonVideosTests {

    private func record(_ path: String, confirmed: [String] = [], detected: [String] = [],
                        suspected: [String] = [], date: String? = nil) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.confirmedByUserPeople = confirmed.map { ConfirmedTag(name: $0, confirmedAt: Date()) }
        r.detectedPeople = detected
        r.suspectedPeople = suspected
        r.userDate = date
        return r
    }

    private func model(_ records: [VideoRecord]) -> VideoScanModel {
        let m = VideoScanModel()
        m.records = records
        m.searchIndex.rebuild(records: records)
        return m
    }

    private func donna(aliases: [String] = []) -> POIProfile {
        var p = POIProfile(name: "Donna", referencePath: "")
        p.aliases = aliases
        return p
    }

    @Test func tiersComeFromTheThreeListsStrongestFirst() {
        let keys: Set<String> = ["donna"]
        #expect(PersonVideos.tier(of: record("/a", confirmed: ["Donna"], suspected: ["Donna"]), keys: keys) == .tagged)
        #expect(PersonVideos.tier(of: record("/b", detected: ["donna"]), keys: keys) == .foundByFace)
        #expect(PersonVideos.tier(of: record("/c", suspected: ["DONNA"]), keys: keys) == .maybe)
        #expect(PersonVideos.tier(of: record("/d", confirmed: ["Rick"]), keys: keys) == nil)
    }

    @Test func aliasesCountAndNamesAreExactNotSubstrings() {
        let m = model([record("/Volumes/X/a.mov", confirmed: ["Goldilocks"]),
                       record("/Volumes/X/b.mov", confirmed: ["Donna"]),
                       record("/Volumes/X/c.mov", confirmed: ["Don"]),
                       record("/Volumes/X/d.mov", confirmed: ["Donnatella"])])
        let rows = PersonVideos.rows(for: donna(aliases: ["Goldilocks"]), in: m)
        #expect(Set(rows.map(\.path)) == ["/Volumes/X/a.mov", "/Volumes/X/b.mov"])
    }

    @Test func removedAndSetAsideRecordsAreLeftOut() {
        let purged = record("/Volumes/X/gone.mov", confirmed: ["Donna"])
        purged.purgedAt = Date()
        let m = model([purged, record("/Volumes/X/kept.mov", confirmed: ["Donna"])])
        #expect(PersonVideos.rows(for: donna(), in: m).map(\.path) == ["/Volumes/X/kept.mov"])
    }

    @Test func oldestFirstUndatedLastGroupedByDecade() {
        let rows = PersonVideos.sorted([
            PersonVideoRow(id: UUID(), path: "1", title: "b", year: nil, durationSeconds: 0, tier: .tagged, isArchived: false, volume: ""),
            PersonVideoRow(id: UUID(), path: "2", title: "a", year: 1995, durationSeconds: 0, tier: .tagged, isArchived: false, volume: ""),
            PersonVideoRow(id: UUID(), path: "3", title: "c", year: 1987, durationSeconds: 0, tier: .tagged, isArchived: false, volume: ""),
            PersonVideoRow(id: UUID(), path: "4", title: "d", year: 1989, durationSeconds: 0, tier: .tagged, isArchived: false, volume: ""),
        ])
        #expect(rows.map(\.path) == ["3", "4", "2", "1"])
        #expect(PersonVideos.byDecade(rows).map(\.decade) == ["1980s", "1990s", "Date unknown"])
    }

    /// SCALE: 100k records, Donna in 2k. The rows come from the person
    /// index plus O(her videos) — well inside a click's budget.
    @Test func hundredThousandRecordsAnswersFast() {
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        for i in 0..<100_000 {
            records.append(record("/Volumes/Scale/v\(i).mov",
                                  confirmed: i % 50 == 0 ? ["Donna"] : (i % 7 == 0 ? ["Rick"] : []),
                                  date: String(1980 + i % 40)))
        }
        let m = model(records)
        let clock = ContinuousClock()
        var rows: [PersonVideoRow] = []
        let elapsed = clock.measure { rows = PersonVideos.rows(for: donna(), in: m) }
        #expect(rows.count == 2_000)
        #expect(elapsed < .milliseconds(500), "rows for one person took \(elapsed)")
    }

    /// SENSOR: the section must not observe the catalog model wholesale,
    /// and must not walk `records` itself.
    @Test func sectionNeverWalksTheCatalog() throws {
        let source = try SourceTree.appSource(named: "PersonVideosSection.swift")
        #expect(source.contains("let catalogModel: VideoScanModel"), "a plain reference, not observed")
        #expect(!source.contains("@ObservedObject var catalogModel"))
        #expect(!source.contains(".records"), "never iterate the catalog")
        #expect(source.contains("paths(forPersonNamesExactly:"))
    }
}

// MARK: - Hand-picked videos (2026-10-04) + the born-before guard

@Suite("People — hand-picked videos")
@MainActor
struct FeaturedVideosTests {

    private func rec(_ path: String, hash: String = "") -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.contentHash = hash
        return r
    }

    @Test func aPickIsFoundByIdPathOrContentHash() {
        let r = rec("/Volumes/X/a.mov", hash: "abc")
        let byID = FeaturedVideo(recordID: r.id, path: "/old/elsewhere.mov", filename: "", contentHash: nil, addedAt: Date())
        let byPath = FeaturedVideo(recordID: UUID(), path: "/Volumes/X/a.mov", filename: "", contentHash: nil, addedAt: Date())
        let byHash = FeaturedVideo(recordID: UUID(), path: "/renamed.mov", filename: "", contentHash: "abc", addedAt: Date())
        let none = FeaturedVideo(recordID: UUID(), path: "/nope.mov", filename: "", contentHash: "", addedAt: Date())
        #expect(FeaturedVideos.matches(byID, r))
        #expect(FeaturedVideos.matches(byPath, r))
        #expect(FeaturedVideos.matches(byHash, r))
        #expect(!FeaturedVideos.matches(none, r), "an empty hash never matches an unhashed record")
    }

    @Test func olderAndDamagedProfilesStillLoad() throws {
        let old = #"{"name":"Donna","referencePath":""}"#
        let p1 = try JSONDecoder().decode(POIProfile.self, from: Data(old.utf8))
        #expect(p1.featuredVideos.isEmpty)
        let damaged = #"{"name":"Donna","referencePath":"","featuredVideos":"not a list"}"#
        let p2 = try JSONDecoder().decode(POIProfile.self, from: Data(damaged.utf8))
        #expect(p2.featuredVideos.isEmpty, "a bad list degrades to empty, never bricks the profile")
    }

    @Test func picksRoundTripThroughProfileJSON() throws {
        var p = POIProfile(name: "Donna", referencePath: "")
        p.featuredVideos = [FeaturedVideo(recordID: UUID(), path: "/Volumes/X/a.mov", filename: "a.mov",
                                          contentHash: "abc", addedAt: Date(timeIntervalSince1970: 1_000))]
        let back = try JSONDecoder().decode(POIProfile.self, from: JSONEncoder().encode(p))
        #expect(back.featuredVideos == p.featuredVideos)
    }

    @Test func resolveFindsPicksInOrderAndCountsTheMissing() {
        let a = rec("/Volumes/X/a.mov"), b = rec("/Volumes/X/b.mov")
        let m = VideoScanModel()
        m.records = [a, b]
        var p = POIProfile(name: "Donna", referencePath: "")
        p.featuredVideos = [
            FeaturedVideo(recordID: b.id, path: b.fullPath, filename: b.filename, contentHash: nil, addedAt: Date()),
            FeaturedVideo(recordID: UUID(), path: "/Volumes/Gone/x.mov", filename: "x.mov", contentHash: nil, addedAt: Date()),
            FeaturedVideo(recordID: a.id, path: a.fullPath, filename: a.filename, contentHash: nil, addedAt: Date()),
        ]
        let r = FeaturedVideos.resolve(p, in: m)
        #expect(r.videos.map(\.id) == [b.id, a.id], "pick order kept")
        #expect(r.missing == 1)
    }

    @Test func notShownWhenDatedBeforeTheyWereBorn() {
        func row(_ year: Int?) -> PersonVideoRow {
            PersonVideoRow(id: UUID(), path: "", title: "", year: year, durationSeconds: 0,
                           tier: .tagged, isArchived: false, volume: "")
        }
        #expect(!PersonVideos.plausible(row(1947), bornYear: 1957), "Donna wasn't alive in 1947")
        #expect(PersonVideos.plausible(row(1957), bornYear: 1957))
        #expect(PersonVideos.plausible(row(nil), bornYear: 1957), "undated passes")
        #expect(PersonVideos.plausible(row(1947), bornYear: nil), "no birthdate, no guard")
    }
}

// MARK: - Family groups (2026-10-04)

@Suite("People — family groups")
@MainActor
struct FamilyGroupTests {

    @Test func aFamilySavesAndLoadsInTheTestSandbox() throws {
        // POIStorage.storeDir is a per-process temp dir under a test host,
        // so this never touches the real People store.
        #expect(FamilyGroupStore.directory.path.contains("VideoScanTestPOI-"))
        let family = FamilyGroup(name: FamilyGroupStore.defaultName)
        try FamilyGroupStore.save(family)
        #expect(FamilyGroupStore.load(family.uuid) == family)
        #expect(FamilyGroupStore.listAll().contains(family))
    }

    @Test func aDamagedFamilyFileStillLoadsItsName() throws {
        let json = #"{"uuid":"\#(UUID().uuidString)","name":"Breen Family","featuredVideos":"garbage"}"#
        let family = try JSONDecoder().decode(FamilyGroup.self, from: Data(json.utf8))
        #expect(family.name == "Breen Family")
        #expect(family.featuredVideos.isEmpty)
    }

    @Test func picksAddOnceAndRemoveCleanly() {
        let rec = VideoRecord()
        rec.fullPath = "/Volumes/X/cape.mov"
        rec.filename = "cape.mov"
        var picks: [FeaturedVideo] = []
        #expect(FeaturedVideos.apply([rec], on: true, to: &picks) == 1)
        #expect(FeaturedVideos.apply([rec], on: true, to: &picks) == 0, "no duplicate pick")
        #expect(picks.count == 1)
        #expect(FeaturedVideos.apply([rec], on: false, to: &picks) == 1)
        #expect(picks.isEmpty)
    }

    /// A family must never be a POIProfile (face matching, Hallie's alias
    /// joins and tree identity all read POIProfile.listAll()).
    @Test func familiesAreNotPeople() throws {
        let source = try SourceTree.appSource(named: "FamilyGroup.swift")
        #expect(!source.contains("POIProfile("), "a family is never written as a person profile")
        #expect(source.contains("appendingPathComponent(\"Families\""))
    }
}
