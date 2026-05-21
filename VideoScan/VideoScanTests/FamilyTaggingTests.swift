import Testing
import Foundation
@testable import VideoScan

// MARK: - Family Tagging Writeback Tests
//
// These tests pin down the bridge between PersonFinder's recognition results
// and the catalog's per-record `detectedPeople` tag list. The disconnect was
// the original bug: PersonFinder produced ClipResult rows showing "Donna
// found in /v/family.mov" but nothing wrote "Donna" into that VideoRecord's
// detectedPeople array, so the catalog filter for "has Donna" came back
// empty even after a successful scan.
//
// applyDetectedPeople(matches:person:) is the writeback API. Phase 1
// (this file) covers the confirmed-tier writeback only. Suspected-tier
// (score-based gray-zone tagging) lands with the suspectedPeople sidecar
// field + CatalogSnapshot v3 migration in a follow-up.

@MainActor
struct FamilyTaggingTests {

    private func record(_ path: String) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        return r
    }

    private func match(path: String, bestDistance: Float = 0.40) -> pfVideoResult {
        pfVideoResult(
            filename: (path as NSString).lastPathComponent,
            filePath: path,
            durationSeconds: 60,
            fps: 30,
            totalHits: 5,
            segments: [
                pfSegment(startSecs: 0, endSecs: 5,
                          bestDistance: bestDistance,
                          avgDistance: bestDistance + 0.05)
            ]
        )
    }

    private func noHitsMatch(path: String) -> pfVideoResult {
        pfVideoResult(
            filename: (path as NSString).lastPathComponent,
            filePath: path,
            durationSeconds: 60,
            fps: 30,
            totalHits: 0,
            segments: []
        )
    }

    // Bug-catcher: PersonFinder reports a match for Donna in /v/family.mov;
    // after writeback the catalog row for that path carries "Donna" in
    // detectedPeople. Before the writeback existed this was impossible —
    // PersonFinder's ClipResults and the catalog never met.
    @Test func applyDetectedPeopleWritesConfirmedTag() {
        let model = VideoScanModel()
        let family = record("/v/family.mov")
        let landscape = record("/v/landscape.mov")
        model.records = [family, landscape]

        let updated = model.applyDetectedPeople(
            matches: [match(path: "/v/family.mov")],
            person: "Donna"
        )

        #expect(updated == 1)
        #expect(family.detectedPeople == ["Donna"])
        #expect(landscape.detectedPeople.isEmpty)
    }

    // Defense in depth: presence-filtered upstream should already strip
    // empty-segment results, but the writeback must not tag a record that
    // had no hits even if it slips through.
    @Test func applyDetectedPeopleSkipsEmptySegments() {
        let model = VideoScanModel()
        let r = record("/v/borderline.mov")
        model.records = [r]

        let updated = model.applyDetectedPeople(
            matches: [noHitsMatch(path: "/v/borderline.mov")],
            person: "Donna"
        )

        #expect(updated == 0)
        #expect(r.detectedPeople.isEmpty)
    }

    // Re-running the same scan must not produce ["Donna", "Donna"]. Match
    // the case-insensitive rule already used by PersonFinderCatalogFilter
    // Rule 2 (see CatalogTests.alreadyKnownIsCaseInsensitive).
    @Test func applyDetectedPeopleDedupsCaseInsensitive() {
        let model = VideoScanModel()
        let r = record("/v/family.mov")
        r.detectedPeople = ["donna"]
        model.records = [r]

        let updated = model.applyDetectedPeople(
            matches: [match(path: "/v/family.mov")],
            person: "Donna"
        )

        #expect(updated == 0)
        #expect(r.detectedPeople == ["donna"])
    }

    // Multi-record: only the matched paths get the tag. Mixed-volume runs
    // are common (one POI scan across N videos, only K matched).
    @Test func applyDetectedPeopleOnlyTagsMatchedPaths() {
        let model = VideoScanModel()
        let a = record("/v/a.mov")
        let b = record("/v/b.mov")
        let c = record("/v/c.mov")
        model.records = [a, b, c]

        let updated = model.applyDetectedPeople(
            matches: [match(path: "/v/a.mov"), match(path: "/v/c.mov")],
            person: "Tim"
        )

        #expect(updated == 2)
        #expect(a.detectedPeople == ["Tim"])
        #expect(b.detectedPeople.isEmpty)
        #expect(c.detectedPeople == ["Tim"])
    }

    // Empty person label → no-op. Defensive: the UI defaults to "(global)"
    // when no profile is selected and we don't want that literal in tags.
    @Test func applyDetectedPeopleNoOpOnEmptyName() {
        let model = VideoScanModel()
        let r = record("/v/family.mov")
        model.records = [r]

        let updated = model.applyDetectedPeople(
            matches: [match(path: "/v/family.mov")],
            person: ""
        )

        #expect(updated == 0)
        #expect(r.detectedPeople.isEmpty)
    }

    // Paths PersonFinder returns that have no catalog row are silently
    // skipped — a folder scan can include files the user never cataloged.
    @Test func applyDetectedPeopleSkipsUnknownPaths() {
        let model = VideoScanModel()
        model.records = []

        let updated = model.applyDetectedPeople(
            matches: [match(path: "/v/family.mov")],
            person: "Donna"
        )

        #expect(updated == 0)
    }

    // Multi-POI run on one video should accumulate tags additively.
    // Simulates "Search for Family" producing two writebacks against the
    // same record.
    @Test func applyDetectedPeopleAccumulatesAcrossPeople() {
        let model = VideoScanModel()
        let r = record("/v/holiday.mov")
        model.records = [r]

        _ = model.applyDetectedPeople(
            matches: [match(path: "/v/holiday.mov")],
            person: "Donna"
        )
        _ = model.applyDetectedPeople(
            matches: [match(path: "/v/holiday.mov")],
            person: "Tim"
        )

        #expect(Set(r.detectedPeople) == Set(["Donna", "Tim"]))
    }
}
