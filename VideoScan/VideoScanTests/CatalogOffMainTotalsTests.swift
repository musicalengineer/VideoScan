// CatalogOffMainTotalsTests.swift
// 2026-10-04 perf: the Catalog's two size figures moved OFF the main thread
// (Rick's Release Time Profiler trace: 0.8 s in
// `recomputeVolumeAggregates → CatalogStorageTotalsCalculator.compute` —
// MusicTriage's stem keys, the library-path test, a volume name per record
// — and 0.3 s in `scheduleSizeTotals → isArchived → isInsideMasterArchive`).
//
//   Logic/Equivalence — the TOTAL MEDIA footer computed from Sendable
//               `CatalogStorageRow`s off the main actor equals the footer
//               computed from the live records, on a catalog that hits every
//               bucket and veto; MusicTriage's candidates likewise; the size
//               line's split archived predicate equals `isArchived` record
//               for record, and the totals are equal.
//   Scale     — 100k records: main-actor projection and off-main compute
//               under explicit budgets; the old main-thread cost printed
//               beside them (PERF_SCALE lines in the test log).
//   Sensor    — the recompute no longer calls the footer arithmetic or the
//               full archived predicate on the main actor.
// Isolation: pure functions over constructed records; the size-line model
// has its own temp catalog directory. Media matrix: N/A — no media opened.
//
// Suites: CatalogOffMainTotalsEquivalenceTests · CatalogOffMainTotalsScaleTests ·
//         CatalogOffMainTotalsSensorTests

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func rec(_ filename: String, stream: StreamType = .videoAndAudio, bytes: Int64 = 1_000_000,
                 dir: String = "/Volumes/LaCie/Family", md5: String = "",
                 disposition: MediaDisposition = .unreviewed, dup: DuplicateDisposition = .none) -> VideoRecord {
    let r = VideoRecord()
    r.filename = filename
    r.ext = (filename as NSString).pathExtension.uppercased()
    r.streamTypeRaw = stream.rawValue
    r.directory = dir
    r.fullPath = dir + "/" + filename
    r.sizeBytes = bytes
    r.partialMD5 = md5
    r.mediaDisposition = disposition
    r.duplicateDisposition = dup
    return r
}

/// Every bucket, veto and exclusion the footer and the music chip know.
private func mixedCatalog(scale: Int = 1) -> [VideoRecord] {
    var out: [VideoRecord] = []
    for k in 0..<scale {
        let vol = ["/Volumes/LaCie", "/Volumes/MyBook", "/Volumes/Gone", "/Users/rick/Movies"][k % 4]
        out.append(rec("home\(k).mov", bytes: 2_000_000_000, dir: "\(vol)/Family", md5: "v\(k % 7)"))
        out.append(rec("home\(k).mov", bytes: 2_000_000_000, dir: "\(vol)/Copy", md5: "v\(k % 7)"))
        out.append(rec("track\(k).mp3", stream: .audioOnly, dir: "\(vol)/Music"))
        out.append(rec("song\(k).wav", stream: .audioOnly, dir: "\(vol)/iTunes/iTunes Media"))
        out.append(rec("home\(k).wav", stream: .audioOnly, dir: "\(vol)/Family"))      // same stem as a video
        out.append(rec("A01\(k).mxf", stream: .audioOnly, dir: "\(vol)/Avid"))         // MXF audio half
        let paired = rec("paired\(k).m4a", stream: .audioOnly, dir: "\(vol)/Music")
        paired.pairGroupID = UUID()
        out.append(paired)
        out.append(rec("img\(k).CR3", stream: .videoOnly, dir: "\(vol)/Photos", md5: "p\(k)"))
        out.append(rec("blank\(k).dat", stream: .noStreams, dir: "\(vol)/Misc"))
        out.append(rec("junk\(k).mov", dir: "\(vol)/Misc", disposition: .suspectedJunk))
        out.append(rec("bad\(k).mov", dir: "\(vol)/Misc", disposition: .confirmedJunk))
        out.append(rec("extra\(k).mov", dir: "\(vol)/Dup", dup: .extraCopy))
        let analysed = rec("analysed\(k).mov", dir: "\(vol)/Family")
        analysed.dupAnalyzedAt = Date(timeIntervalSince1970: 1_700_000_000)
        out.append(analysed)
        let gone = rec("gone\(k).mov", dir: "\(vol)/Family")
        gone.purgedAt = Date(timeIntervalSince1970: 1_000_000)
        out.append(gone)
        let aside = rec("aside\(k).mov", dir: "\(vol)/Family")
        aside.setAsideReason = "test"
        out.append(aside)
        let superseded = rec("old\(k).mov", stream: .videoOnly, dir: "\(vol)/Family")
        superseded.supersededByID = UUID()
        out.append(superseded)
        let deleted = rec("deleted\(k).mov", bytes: 7_000_000, dir: "\(vol)/Family")
        deleted.archiveStage = .manuallyDeleted
        out.append(deleted)
        out.append(rec("neg\(k).mov", bytes: -5, dir: "\(vol)/Family"))
    }
    return out
}

@Suite("Catalog totals off the main actor — same answers")
@MainActor
struct CatalogOffMainTotalsEquivalenceTests {

    @Test func theFooterFromRowsEqualsTheFooterFromRecords() async {
        let records = mixedCatalog(scale: 12)
        for online in [nil, Set(["LaCie", "Movies"]), Set<String>()] as [Set<String>?] {
            let reference = CatalogStorageTotalsCalculator.compute(records: records, onlineVolumes: online)
            let rows = CatalogStorageRow.projectForStorageTotals(records)
            let offMain = await Task.detached(priority: .utility) {
                CatalogStorageTotalsCalculator.compute(facts: rows, onlineVolumes: online)
            }.value
            #expect(offMain == reference, "online=\(String(describing: online))")
            #expect(reference.waterfallBalances)
        }
        // Not vacuous: every bucket and the manually-deleted tally are hit.
        let t = CatalogStorageTotalsCalculator.compute(records: records)
        #expect(t.musicFiles > 0 && t.junkFiles > 0 && t.nonVideoFiles > 0 && t.duplicateFiles > 0
                && t.uniqueFileCount > 0 && t.manuallyDeletedFiles > 0 && t.unanalyzedFiles > 0)
    }

    @Test func theMusicChipFromRowsEqualsTheChipFromRecords() async {
        let records = mixedCatalog(scale: 12)
        let reference = MusicTriage.candidateIDs(in: records)
        let rows = CatalogStorageRow.project(records)
        let offMain = await Task.detached(priority: .utility) { MusicTriage.candidateIDs(in: rows) }.value
        #expect(offMain == reference)
        #expect(!reference.isEmpty && reference.count < records.count)
    }

    /// The size line: `isArchivedExceptPath || inside(root)` IS `isArchived`.
    @Test func theSplitArchivedPredicateIsIsArchived() async {
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("test_offmain_totals_\(UUID().uuidString.prefix(8))", isDirectory: true))
        model.masterArchive = MasterArchiveDesignation(
            targetPath: "/Volumes/FamilyArchive", rootPath: "/Volumes/FamilyArchive/Test_Family_Archive", volumeUUID: nil)
        var records = mixedCatalog(scale: 4)
        let source = rec("source.mov", dir: "/Volumes/LaCie/Family", md5: "s1")
        let copy = rec("source.mov", dir: "/Volumes/FamilyArchive/Test_Family_Archive/1990s", md5: "s1")
        copy.derivationKind = ArchivePromotion.derivationKind
        copy.derivedFrom = source.id
        let looseInTree = rec("loose.mov", dir: "/Volumes/FamilyArchive/Test_Family_Archive/other/../2000s")
        let besideTree = rec("beside.mov", dir: "/Volumes/FamilyArchive/Test_Family_ArchiveX")
        records += [source, copy, looseInTree, besideTree]
        model.records = records
        let root = model.masterArchiveRootPath
        var kinds = Set<String>()
        for r in records {
            let byRecord = model.isArchivedExceptPath(r)
            let byPath = VideoScanModel.isInsideMasterArchive(path: r.fullPath, root: root)
            #expect(model.isArchived(r) == (byRecord || byPath), "\(r.fullPath)")
            if byRecord { kinds.insert("record") }
            if byPath && !byRecord { kinds.insert("path") }
            if !byRecord && !byPath { kinds.insert("neither") }
        }
        #expect(kinds == ["record", "path", "neither"], "covered: \(kinds.sorted())")
        let reference = CatalogSizeTotals.compute(CatalogSizeTotals.project(model.records) { model.isArchived($0) })
        let entries = CatalogSizeTotals.projectDeferringArchivePath(model.records) { model.isArchivedExceptPath($0) }
        let offMain = await Task.detached(priority: .utility) { CatalogSizeTotals.compute(entries, archiveRoot: root) }.value
        #expect(offMain == reference)
        #expect(reference.archivedCount >= 3)
    }
}

@Suite("Catalog totals off the main actor — scale", .serialized)
@MainActor
struct CatalogOffMainTotalsScaleTests {

    /// 100k records (the mixed catalog's 18 shapes, ~5,600 times). Budgets
    /// (Release): the footer's main-actor projection under 250 ms and its
    /// off-main compute under 3 s; the size line's main-actor projection
    /// under 400 ms. The old main-thread costs are printed beside them.
    @Test func hundredThousandRecordsUnderBudget() async {
        let records = Array(mixedCatalog(scale: 5_556).prefix(100_000))
        #expect(records.count == 100_000)
        let clock = ContinuousClock()

        var start = clock.now
        let reference = CatalogStorageTotalsCalculator.compute(records: records, onlineVolumes: ["LaCie"])
        let oldFooter = clock.now - start
        start = clock.now
        let rows = CatalogStorageRow.projectForStorageTotals(records)
        let newFooterMain = clock.now - start
        let (offMain, footerOff) = await Task.detached(priority: .utility) {
            let s = ContinuousClock.now
            let t = CatalogStorageTotalsCalculator.compute(facts: rows, onlineVolumes: ["LaCie"])
            return (t, ContinuousClock.now - s)
        }.value
        #expect(offMain == reference)

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("test_offmain_totals_scale_\(UUID().uuidString.prefix(8))", isDirectory: true))
        model.masterArchive = MasterArchiveDesignation(
            targetPath: "/Volumes/LaCie", rootPath: "/Volumes/LaCie/Family", volumeUUID: nil)
        model.records = records
        start = clock.now
        let oldEntries = CatalogSizeTotals.project(model.records) { model.isArchived($0) }
        let oldSizeMain = clock.now - start
        start = clock.now
        let entries = CatalogSizeTotals.projectDeferringArchivePath(model.records) { model.isArchivedExceptPath($0) }
        let newSizeMain = clock.now - start
        let root = model.masterArchiveRootPath
        let sizeOff = await Task.detached(priority: .utility) { CatalogSizeTotals.compute(entries, archiveRoot: root) }.value
        #expect(sizeOff == CatalogSizeTotals.compute(oldEntries))
        #expect(sizeOff.archivedCount > 0)

        print("PERF_SCALE footer: old main-actor compute \(oldFooter); new main-actor projection \(newFooterMain); off-main compute \(footerOff)")
        print("PERF_SCALE size line: old main-actor projection \(oldSizeMain); new main-actor projection \(newSizeMain)")
        #expect(newFooterMain < PerformanceLane.debugCeiling(.milliseconds(250)), "footer projection took \(newFooterMain)")
        #expect(footerOff < .seconds(3), "footer compute took \(footerOff)")
        #expect(newSizeMain < PerformanceLane.debugCeiling(.milliseconds(400)), "size-line projection took \(newSizeMain)")
    }
}

@Suite("Catalog totals off the main actor — sensors")
struct CatalogOffMainTotalsSensorTests {

    private func code(_ name: String) throws -> String {
        try SourceTree.appSource(named: name).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    @Test func theRecomputeLeavesTheArithmeticToADetachedTask() throws {
        let src = try code("CatalogView+ScanTargetsPane.swift")
        let start = try #require(src.range(of: "private func recomputeVolumeAggregates() {"))
        let end = try #require(src.range(of: "func scheduleStorageTotals(onlineVolumes: Set<String>) {", range: start.upperBound..<src.endIndex))
        let recompute = String(src[start.upperBound..<end.lowerBound])
        #expect(!recompute.contains("CatalogStorageTotalsCalculator.compute("), "the footer arithmetic is back on the main actor")
        #expect(recompute.contains("scheduleStorageTotals(onlineVolumes: onlineVolumes)"))
        let schedule = try #require(src.range(of: "func scheduleStorageTotals(onlineVolumes: Set<String>) {"))
        let body = String(src[schedule.upperBound...].prefix(900))
        #expect(body.contains("CatalogStorageRow.projectForStorageTotals(model.records)"))
        let detached = try #require(body.range(of: "Task.detached(priority: .utility) {"))
        #expect(String(body[detached.upperBound...]).contains("CatalogStorageTotalsCalculator.compute(facts: rows, onlineVolumes: onlineVolumes)"),
                "the footer arithmetic runs in the detached task")
        let size = try #require(src.range(of: "func scheduleSizeTotals() {"))
        let sizeBody = String(src[size.upperBound...].prefix(1_200))
        #expect(sizeBody.contains("CatalogSizeTotals.projectDeferringArchivePath(model.records) { model.isArchivedExceptPath($0) }"))
        #expect(sizeBody.contains("CatalogSizeTotals.compute(entries, archiveRoot: archiveRoot)"))
        #expect(!sizeBody.contains("model.isArchived($0)"), "the full archived predicate is asked per record on the main actor again")
    }

    @Test func theCalculatorsAreOneImplementationOverBothShapes() throws {
        let totals = try code("CatalogStorageTotals.swift")
        #expect(totals.contains("compute(facts: records, onlineVolumes: onlineVolumes)"),
                "the VideoRecord entry point forwards to the one generic implementation")
        let music = try code("MusicTriage.swift")
        #expect(music.contains("static func candidateVerdict<R: CatalogStorageFacts>("))
        #expect(music.contains("static func videoStemKeys<R: CatalogStorageFacts>("))
    }
}
