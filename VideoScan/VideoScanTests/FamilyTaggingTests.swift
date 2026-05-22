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

    // MARK: - Step 1b: tier-aware writeback

    // Suspected matches land in suspectedPeople, not detectedPeople.
    // First-time gray-zone hit on a borderline file.
    @Test func applyDetectedPeopleWritesSuspectedTag() {
        let model = VideoScanModel()
        let r = record("/v/borderline.mov")
        model.records = [r]

        let updated = model.applyDetectedPeople(
            confirmed: [],
            suspected: [match(path: "/v/borderline.mov")],
            person: "Donna"
        )

        #expect(updated == 1)
        #expect(r.detectedPeople.isEmpty)
        #expect(r.suspectedPeople == ["Donna"])
    }

    // Upgrade: previously-suspected name promotes to confirmed when a
    // re-scan finds a strong match.
    @Test func applyDetectedPeopleUpgradesSuspectedToConfirmed() {
        let model = VideoScanModel()
        let r = record("/v/family.mov")
        r.suspectedPeople = ["Donna"]
        model.records = [r]

        let updated = model.applyDetectedPeople(
            confirmed: [match(path: "/v/family.mov")],
            suspected: [],
            person: "Donna"
        )

        #expect(updated == 1)
        #expect(r.detectedPeople == ["Donna"])
        #expect(r.suspectedPeople.isEmpty)
    }

    // Downgrade: previously-confirmed name moves to suspected when a
    // re-scan only produces a borderline match. Rick's "worst case
    // scenario you can say 'suspected Donna is in here'" path.
    @Test func applyDetectedPeopleDowngradesConfirmedToSuspected() {
        let model = VideoScanModel()
        let r = record("/v/family.mov")
        r.detectedPeople = ["Donna"]
        model.records = [r]

        let updated = model.applyDetectedPeople(
            confirmed: [],
            suspected: [match(path: "/v/family.mov")],
            person: "Donna"
        )

        #expect(updated == 1)
        #expect(r.detectedPeople.isEmpty)
        #expect(r.suspectedPeople == ["Donna"])
    }

    // Miss-on-rescan preserves existing tags (sampling miss is more
    // likely than a wrong prior tag). Neither array passed → no-op.
    @Test func applyDetectedPeopleMissPreservesExistingTags() {
        let model = VideoScanModel()
        let r = record("/v/family.mov")
        r.detectedPeople = ["Donna"]
        r.suspectedPeople = ["Tim"]
        model.records = [r]

        let updated = model.applyDetectedPeople(
            confirmed: [],
            suspected: [],
            person: "Donna"
        )

        #expect(updated == 0)
        #expect(r.detectedPeople == ["Donna"])
        #expect(r.suspectedPeople == ["Tim"])
    }

    // Suspected dedup is case-insensitive, mirroring the confirmed-side
    // rule and PersonFinderCatalogFilter Rule 2.
    @Test func suspectedPeopleDedupsCaseInsensitive() {
        let model = VideoScanModel()
        let r = record("/v/family.mov")
        r.suspectedPeople = ["donna"]
        model.records = [r]

        let updated = model.applyDetectedPeople(
            confirmed: [],
            suspected: [match(path: "/v/family.mov")],
            person: "Donna"
        )

        #expect(updated == 0)
        #expect(r.suspectedPeople == ["donna"])
    }

    // A name must never live in both arrays simultaneously: upgrading
    // strips suspected; downgrading strips confirmed. Verifies both
    // arms in a single record.
    @Test func applyDetectedPeopleKeepsNameInOneArrayOnly() {
        let model = VideoScanModel()
        let upgrading = record("/v/upgrade.mov")
        upgrading.suspectedPeople = ["Donna"]
        let downgrading = record("/v/downgrade.mov")
        downgrading.detectedPeople = ["Donna"]
        model.records = [upgrading, downgrading]

        _ = model.applyDetectedPeople(
            confirmed: [match(path: "/v/upgrade.mov")],
            suspected: [match(path: "/v/downgrade.mov")],
            person: "Donna"
        )

        #expect(upgrading.detectedPeople == ["Donna"])
        #expect(upgrading.suspectedPeople.isEmpty)
        #expect(downgrading.detectedPeople.isEmpty)
        #expect(downgrading.suspectedPeople == ["Donna"])
    }

    // MARK: - splitByConfidence

    // Strong-match distance (below threshold − margin) → confirmed.
    // Borderline distance (within margin of threshold) → suspected.
    @Test func splitByConfidencePartitionsAtCutoff() {
        let strong = pfVideoResult(
            filename: "strong.mov", filePath: "/v/strong.mov",
            durationSeconds: 60, fps: 30, totalHits: 1,
            segments: [pfSegment(startSecs: 0, endSecs: 1,
                                 bestDistance: 0.40, avgDistance: 0.40)]
        )
        let borderline = pfVideoResult(
            filename: "borderline.mov", filePath: "/v/borderline.mov",
            durationSeconds: 60, fps: 30, totalHits: 1,
            segments: [pfSegment(startSecs: 0, endSecs: 1,
                                 bestDistance: 0.50, avgDistance: 0.50)]
        )

        let (confirmed, suspected) = PersonFinderModel.splitByConfidence(
            [strong, borderline], threshold: 0.52, margin: 0.05
        )

        #expect(confirmed.map(\.filename) == ["strong.mov"])
        #expect(suspected.map(\.filename) == ["borderline.mov"])
    }

    // Values just below the (threshold − margin) cutoff go to confirmed;
    // values just above go to suspected. Avoids exact-equality comparison
    // at the cutoff because Float arithmetic on `0.52 − 0.05` isn't
    // bit-exactly `0.47` — real face-matching distances are continuous
    // and never hit precise boundaries anyway.
    @Test func splitByConfidenceJustBelowCutoffIsConfirmed() {
        let justUnder = pfVideoResult(
            filename: "under.mov", filePath: "/v/under.mov",
            durationSeconds: 60, fps: 30, totalHits: 1,
            segments: [pfSegment(startSecs: 0, endSecs: 1,
                                 bestDistance: 0.46, avgDistance: 0.46)]
        )
        let (confirmed, suspected) = PersonFinderModel.splitByConfidence(
            [justUnder], threshold: 0.52, margin: 0.05
        )
        #expect(confirmed.map(\.filename) == ["under.mov"])
        #expect(suspected.isEmpty)
    }

    @Test func splitByConfidenceJustAboveCutoffIsSuspected() {
        let justOver = pfVideoResult(
            filename: "over.mov", filePath: "/v/over.mov",
            durationSeconds: 60, fps: 30, totalHits: 1,
            segments: [pfSegment(startSecs: 0, endSecs: 1,
                                 bestDistance: 0.48, avgDistance: 0.48)]
        )
        let (confirmed, suspected) = PersonFinderModel.splitByConfidence(
            [justOver], threshold: 0.52, margin: 0.05
        )
        #expect(confirmed.isEmpty)
        #expect(suspected.map(\.filename) == ["over.mov"])
    }

    @Test func splitByConfidenceEmpty() {
        let (c, s) = PersonFinderModel.splitByConfidence(
            [], threshold: 0.52, margin: 0.05
        )
        #expect(c.isEmpty)
        #expect(s.isEmpty)
    }

    // Multi-segment record: split uses the BEST (lowest) distance across
    // a result's segments. One bad segment shouldn't drag down a strong
    // match.
    @Test func splitByConfidenceUsesBestSegmentDistance() {
        let mixed = pfVideoResult(
            filename: "mixed.mov", filePath: "/v/mixed.mov",
            durationSeconds: 120, fps: 30, totalHits: 2,
            segments: [
                pfSegment(startSecs: 0,  endSecs: 5,
                          bestDistance: 0.51, avgDistance: 0.51),   // borderline
                pfSegment(startSecs: 60, endSecs: 65,
                          bestDistance: 0.30, avgDistance: 0.30)    // strong
            ]
        )
        let (confirmed, _) = PersonFinderModel.splitByConfidence(
            [mixed], threshold: 0.52, margin: 0.05
        )
        #expect(confirmed.map(\.filename) == ["mixed.mov"])
    }

    // MARK: - Schema migration

    // A v2 catalog.json (no `suspectedPeople` key on records) must load
    // cleanly under v3, with each record's `suspectedPeople` defaulting
    // to []. decodeIfPresent in the VideoRecord decoder is the safety
    // net — this test pins it down.
    @Test func v2CatalogJsonRoundTripsWithEmptySuspectedPeople() throws {
        let v2Json = """
        {
          "version": 2,
          "savedAt": 0,
          "records": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "fullPath": "/v/old.mov",
              "filename": "old.mov",
              "detectedPeople": ["Donna"]
            }
          ]
        }
        """.data(using: .utf8)!

        let snap = try JSONDecoder().decode(CatalogSnapshot.self, from: v2Json)

        #expect(snap.records.count == 1)
        #expect(snap.records[0].detectedPeople == ["Donna"])
        #expect(snap.records[0].suspectedPeople.isEmpty)
    }

    // A v3 catalog.json round-trips both arrays through encode+decode.
    @Test func v3CatalogJsonRoundTripsBothArrays() throws {
        let r = VideoRecord()
        r.fullPath = "/v/family.mov"
        r.filename = "family.mov"
        r.detectedPeople = ["Donna"]
        r.suspectedPeople = ["Tim"]
        let snap = CatalogSnapshot(records: [r])

        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(CatalogSnapshot.self, from: data)

        #expect(decoded.version == CatalogSnapshot.currentVersion)
        #expect(decoded.records.count == 1)
        #expect(decoded.records[0].detectedPeople == ["Donna"])
        #expect(decoded.records[0].suspectedPeople == ["Tim"])
    }
}
