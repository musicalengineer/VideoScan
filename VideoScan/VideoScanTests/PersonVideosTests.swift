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
