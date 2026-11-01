// CatalogTidyTests.swift
// Catalog ▸ Tidy Catalog… (Rick 2026-11-01): the one-off hygiene verbs in
// one sheet, each with its live count and a Run through its existing engine.
//
//   LOGIC     — the split count's rule (more than one known digest, case-
//               insensitive); the total; the rows; hidden at zero
//   TRUTH     — each count equals what its engine would act on, on the same
//               records: non-video = the purge dialog's classification;
//               groups = the split plan's split groups
//   ISOLATION — poisoned rows: removed grouped rows, rows with no digest, a
//               sampled-only row, an extensionless file — never counted wrong
//   SCALE     — 100k rows: project + count inside the budget
//   SENSOR    — the Runs call the engines the retired items called; the
//               sheet body walks no records; no `extension VideoScanModel`

import Foundation
import Testing
@testable import VideoScan

@MainActor
enum TidyFixture {
    static func record(_ path: String, group: UUID? = nil, digest: String? = nil) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.directory = (path as NSString).deletingLastPathComponent
        r.ext = (path as NSString).pathExtension
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.sizeBytes = 1_000
        r.duplicateGroupID = group
        if let digest {
            r.contentFixity = ContentFixity(digest: digest, byteCount: r.sizeBytes,
                                            stamp: FileIdentityStamp(device: 1, inode: 1, size: r.sizeBytes, mtimeNs: 0),
                                            computedAt: Date())
        }
        return r
    }

    static let d1 = String(repeating: "a", count: 64)
    static let d2 = String(repeating: "b", count: 64)

    /// Two groups to split (G1 two digests; G3 two digests with case noise), one
    /// that agrees (G2), one with a single known digest (G4), a removed member
    /// that would have made G2 a split, 3 non-video rows (jpg, mp3, CR3), an
    /// extensionless file and a video file.
    static func catalog() -> (records: [VideoRecord], g1: UUID, g3: UUID) {
        let g1 = UUID(), g2 = UUID(), g3 = UUID(), g4 = UUID()
        let removed = record("/Volumes/X9/test_gone.mov", group: g2, digest: d2)
        removed.removal = .removedFromCatalog(at: Date(), reason: .userRemoved)
        let records = [
            record("/Volumes/X9/test_a.mov", group: g1, digest: d1),
            record("/Volumes/X9/test_b.mov", group: g1, digest: d2),
            record("/Volumes/X9/test_c.mov", group: g2, digest: d1),
            record("/Volumes/X9/test_d.mov", group: g2, digest: d1),
            removed,
            record("/Volumes/X9/test_e.mov", group: g3, digest: d1.uppercased()),
            record("/Volumes/X9/test_f.mov", group: g3, digest: d2),
            record("/Volumes/X9/test_g.mov", group: g3),              // no digest
            record("/Volumes/X9/test_h.mov", group: g4, digest: d1),
            record("/Volumes/X9/test_i.mov", group: g4),
            record("/Volumes/X9/test_photo.jpg"),
            record("/Volumes/X9/test_song.mp3"),
            record("/Volumes/Y/test_raw.CR3"),
            record("/Volumes/Y/test_noext"),
            record("/Volumes/Y/test_clip.mp4"),
        ]
        return (records, g1, g3)
    }
}

@Suite("Tidy Catalog — counts, rows, truth", .serialized)
@MainActor
struct CatalogTidyTests {

    @Test("LOGIC: a group needs a split only when it holds more than one known digest; case does not count")
    func groupsToSplitRule() {
        let g = UUID(), h = UUID()
        let members = [CatalogTidyMember(groupID: g, digest: "AA"), CatalogTidyMember(groupID: g, digest: "aa"),
                       CatalogTidyMember(groupID: g, digest: nil),
                       CatalogTidyMember(groupID: h, digest: "aa"), CatalogTidyMember(groupID: h, digest: "bb")]
        #expect(CatalogTidyCalculator.groupsToSplit(members) == 1)
        #expect(CatalogTidyCalculator.groupsToSplit([]) == 0)
    }

    @Test("LOGIC: the total sums the three counts; hidden from the menu at zero; the rows say which have a Run")
    func totalRowsAndHiddenAtZero() {
        let zero = CatalogTidyCounts()
        #expect(zero.total == 0)
        #expect(!CatalogMenuLayout.entries(tidyTotal: zero.total).contains(.tidyCatalog(total: 0)))
        let c = CatalogTidyCounts(nonVideoRows: 5, duplicateGroupsToSplit: 2, degenerateOCRCaptions: 7)
        #expect(c.total == 14)
        #expect(CatalogMenuLayout.entries(tidyTotal: c.total).contains(.tidyCatalog(total: 14)))
        let rows = CatalogTidyRow.rows(c)
        #expect(rows.map(\.kind) == CatalogTidyRow.Kind.allCases)
        #expect(rows.map(\.number) == [5, 2, 7])
        #expect(rows.map(\.runTitle) == ["Run…", "Run", nil], "junk captions have no engine yet — no Run")
        #expect(rows[2].detail.contains("no cleanup action yet"))
    }

    @Test("TRUTH + ISOLATION: each count equals what its engine acts on, on the same records (removed, digest-less, extensionless rows included)")
    func countsMatchTheEngines() {
        let (records, g1, g3) = TidyFixture.catalog()
        let counts = CatalogTidyCalculator.counts(CatalogTidyCalculator.project(records), degenerateOCRCaptions: 0)

        // Non-video: the purge dialog's own classification over the same records.
        let classification = NonVideoMediaPurge.classify(records: records)
        let dialogTotal = classification.totalCount(extensions: Set(classification.extensions),
                                                    volumeKeys: Set(classification.volumeKeys))
        #expect(counts.nonVideoRows == dialogTotal)
        #expect(counts.nonVideoRows == 3, "jpg, mp3, CR3 — never the extensionless file or a video container")

        // Groups: the split engine's plan over the facts it builds itself.
        let model = VideoScanModel()
        model.records = records
        let plan = DuplicateGroupDigestSplit.plan(model.duplicateDigestSplitFacts())
        #expect(counts.duplicateGroupsToSplit == plan.splitGroups.count)
        #expect(Set(plan.splitGroups.map(\.oldGroupID)) == [g1, g3], "the removed member never makes G2 a split")
        #expect(counts.duplicateGroupsToSplit == 2)
    }

    @Test("TRUTH: the coverage pass carries the counts the menu and the sheet read")
    func theReportCarriesTheCounts() async throws {
        let (records, _, _) = TidyFixture.catalog()
        let model = VideoScanModel()
        model.records = records
        model.scheduleAnalyzeCoverageRefresh()
        let deadline = Date().addingTimeInterval(10)
        while model.analyzeCoverageSnapshot.report.tidy.total == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let tidy = model.analyzeCoverageSnapshot.report.tidy
        #expect(tidy.nonVideoRows == 3 && tidy.duplicateGroupsToSplit == 2)
        #expect(tidy.degenerateOCRCaptions == model.analyzeCoverageSnapshot.report.degenerateOCRDates)
    }

    @Test("SCALE: 100k rows — project + count well inside 1 s (Debug)")
    func scale() {
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let group: UUID? = i % 4 == 0 ? UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i / 8)) : nil
            let ext = i % 10 == 0 ? "jpg" : "mov"
            records.append(TidyFixture.record("/Volumes/X9/test_\(i).\(ext)", group: group,
                                              digest: group == nil ? nil : (i % 8 == 0 ? TidyFixture.d1 : TidyFixture.d2)))
        }
        let start = Date()
        let counts = CatalogTidyCalculator.counts(CatalogTidyCalculator.project(records), degenerateOCRCaptions: 0)
        let elapsed = Date().timeIntervalSince(start)
        #expect(counts.nonVideoRows == 10_000)
        #expect(counts.duplicateGroupsToSplit == 12_500)
        #expect(elapsed < 1.0, "project + count took \(elapsed) s")
    }
}

@Suite("Tidy Catalog — sensors: the existing engines, nothing of its own")
@MainActor
struct CatalogTidySensorTests {

    static func code(_ name: String) throws -> String {
        SourceTree.strippingComments(try SourceTree.appSource(named: name))
    }

    @Test("SENSOR: each Run calls the retired item's engine; the sheet body walks no records; no model extension")
    func runsCallTheEngines() throws {
        let tidy = try Self.code("CatalogTidy.swift")
        #expect(tidy.contains("center.splitDuplicateGroupsKeepingSameFootage(model: model)"), "the retired menu item's exact call")
        #expect(tidy.contains("NonVideoMediaPurgeSheet(preselectedVolumeKey: nil)"), "the purge dialog the menu opened")
        #expect(!tidy.contains("purgeNonVideoMedia(") && !tidy.contains("splitDuplicateGroupsByFullDigest("),
                "no second door into either engine")
        #expect(!tidy.contains("extension VideoScanModel"))
        let sheet = try #require(tidy.range(of: "struct CatalogTidySheet")).lowerBound
        let body = String(tidy[sheet...])
        for walk in ["model.records", "records.filter", "for r in records", "records.count"] {
            #expect(!body.contains(walk), "the sheet walks records: \(walk)")
        }
        #expect(body.contains("CatalogTidyRow.rows(coverage.report.tidy)"), "the sheet reads the coverage report")
        let pass = try Self.code("VideoScanModel+AnalyzeCoverage.swift")
        #expect(pass.contains("let tidy = CatalogTidyCalculator.project(records)"))
        #expect(pass.contains("report.tidy = CatalogTidyCalculator.counts(tidy, degenerateOCRCaptions: report.degenerateOCRDates)"))
        let menu = try Self.code("CatalogMenu.swift")
        #expect(menu.contains("private var tidyTotal: Int { coverage.report.tidy.total }"))
        #expect(menu.contains("CatalogTidySheet(model: model, center: center)"))
    }
}
