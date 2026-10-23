// ArchiveTimelineCompletenessSensorTests.swift
// P0 2026-10-22 — an archived Master ALWAYS shows in the Archive tab,
// whatever happened to its source or working copies. Rick promoted
// CapeCod_1998_old_codec.dv, Prune moved the source and two byte-identical
// copies to the Trash (the normal end of a promote), and the file vanished
// from the 1998 page. Cause: ArchiveCategorySnapshot.compute walks the
// ACTIVE records; the trashed source is not active, and the archive copy
// was skipped as "represented by its source" because the source row still
// existed. Neither row made it into `archived`.
//
//   LOGIC     promote → trash every outside copy → the item is in
//             `snapshot.archived` and on the timeline under 1998; the same
//             for a set-aside, a superseded and a removed source; a live
//             source still represents its copy (no double count).
//   SCALE     100k records, 5,000 promoted, every source trashed: 5,000
//             archived, one compute under budget.
//   SENSOR    production scale, every source state at once: EVERY live
//             archive copy is represented on the timeline (as itself or by
//             its active source), exactly once. Plus a source pin: the
//             snapshot asks `sourceRepresents`, never "source row exists".
//
// Suites (filter by SUITE): ArchiveTimelineCompletenessSensorTests

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Archive tab — an archived Master always shows, whatever happened to its source (P0 2026-10-22)")
@MainActor
struct ArchiveTimelineCompletenessSensorTests {

    private static let archiveRoot = "/Volumes/TestArchive/Breen_Family_Archive"

    private static func makeModel() throws -> (VideoScanModel, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_archivecomplete_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        model.masterArchive = MasterArchiveDesignation(targetPath: "/Volumes/TestArchive", rootPath: archiveRoot)
        return (model, dir)
    }

    private static func source(_ path: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.sizeBytes = 1_000
        return r
    }

    private static func copy(of src: VideoRecord, rel: String) -> VideoRecord {
        let c = VideoRecord()
        c.filename = (rel as NSString).lastPathComponent
        c.fullPath = archiveRoot + "/" + rel
        c.derivedFrom = src.id
        c.derivationKind = ArchivePromotion.derivationKind
        c.sizeBytes = src.sizeBytes
        c.streamTypeRaw = StreamType.videoAndAudio.rawValue
        c.lifecycleStage = .archived
        c.archiveStage = .masterAssigned
        c.archiveFixity = ArchiveFixity(digest: "a7010c01", verifiedAt: Date(), sizeBytes: src.sizeBytes)
        return c
    }

    /// What Prune leaves on a trashed copy: the one removal marker + its mirror.
    private static func trash(_ rec: VideoRecord) {
        rec.removal = .inTrash(movedAt: Date(), trashPath: "/Users/x/.Trash/\(rec.filename)", reason: .junk)
        rec.lifecycleStage = .trashed
    }

    private static func snapshot(_ model: VideoScanModel) -> ArchiveCategorySnapshot {
        ArchiveCategorySnapshot.compute(active: pfActiveRecords(model.records), allRecords: model.records,
                                        model: model, volumeSearchPaths: [])
    }

    private static func timeline(_ model: VideoScanModel, _ snap: ArchiveCategorySnapshot) -> ArchiveTimeline {
        let items = snap.archived.map { ArchiveView.timelineItem(for: $0, model: model) }
        return ArchiveTimelineSnapshot.build(items: items, matching: "").timeline
    }

    // MARK: - Logic

    @Test("promote, then Prune trashes the source and both identical copies: the Master is on the 1998 page")
    func promotedThenPrunedShowsUnder1998() throws {
        let (model, dir) = try Self.makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = Self.source("/Volumes/LaCieWorkspace/Tapes/CapeCod_1998_old_codec.dv")
        let twinA = Self.source("/Volumes/CrucialX10/Tapes/CapeCod_1998_old_codec.dv")
        let twinB = Self.source("/Volumes/SanDiskWorkspace/CapeCod_1998_old_codec.dv")
        let master = Self.copy(of: src, rel: "30_Video/1990-1999/1998/1998-xx-xx_CapeCod_1998_old_codec.dv")
        model.records = [src, twinA, twinB, master]
        // Before Prune: the source is the asset's one row.
        #expect(Self.snapshot(model).archived.map(\.id) == [src.id])

        for r in [src, twinA, twinB] { Self.trash(r) }
        model.volumeAggregatesRevision &+= 1

        let snap = Self.snapshot(model)
        #expect(snap.archived.map(\.id) == [master.id], "the archive copy stands in once its source is in the Trash")
        #expect(snap.activeAssetCount == 1)
        let year1998 = Self.timeline(model, snap).decades.first { $0.start == 1990 }?.years.first { $0.year == 1998 }
        #expect(year1998?.items.map(\.id) == [master.id])
        #expect(year1998?.items.first?.title.contains("CapeCod") == true)
    }

    @Test("a set-aside, a superseded and a removed source each leave their copy on the shelf")
    func everyInactiveSourceStateLeavesTheCopy() throws {
        let (model, dir) = try Self.makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        let aside = Self.source("/Volumes/Src/aside.mov"); aside.setAsideReason = "still-image"
        let sup = Self.source("/Volumes/Src/sup.mov"); sup.supersededByID = UUID()
        let removed = Self.source("/Volumes/Src/removed.mov")
        removed.removal = .removedFromCatalog(at: Date(), reason: .userRemoved)
        let copies = [Self.copy(of: aside, rel: "30_Video/1990-1999/1991/1991-xx-xx_aside.mov"),
                      Self.copy(of: sup, rel: "30_Video/1990-1999/1992/1992-xx-xx_sup.mov"),
                      Self.copy(of: removed, rel: "30_Video/1990-1999/1993/1993-xx-xx_removed.mov")]
        model.records = [aside, sup, removed] + copies
        #expect(Set(Self.snapshot(model).archived.map(\.id)) == Set(copies.map(\.id)))
    }

    @Test("a LIVE source still represents its copy — one row per asset, never both")
    func liveSourceStillRepresents() throws {
        let (model, dir) = try Self.makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = Self.source("/Volumes/Src/live.mov")
        let master = Self.copy(of: src, rel: "30_Video/1990-1999/1994/1994-xx-xx_live.mov")
        model.records = [src, master]
        let snap = Self.snapshot(model)
        #expect(snap.archived.map(\.id) == [src.id])
        #expect(snap.activeAssetCount == 1)
    }

    // MARK: - Scale

    @Test("100k records, 5,000 promoted and every source trashed: 5,000 archived, under budget", .timeLimit(.minutes(1)))
    func scaleAllSourcesTrashed() throws {
        let (model, dir) = try Self.makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        var records: [VideoRecord] = []
        records.reserveCapacity(105_000)
        for i in 0..<100_000 {
            let r = Self.source("/Volumes/Src\(i % 4)/clip_\(i).mov")
            records.append(r)
            if i % 20 == 0 {
                records.append(Self.copy(of: r, rel: "30_Video/1990-1999/1995/clip_\(i).mov"))
                Self.trash(r)
            }
        }
        model.records = records
        let t0 = CFAbsoluteTimeGetCurrent()
        let snap = Self.snapshot(model)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        #expect(snap.archived.count == 5_000)
        #expect(snap.notYetArchived.count == 95_000)
        #expect(.milliseconds(ms) < PerformanceLane.debugCeiling(.seconds(2)),
                "compute at 100k+5k took \(Int(ms)) ms — budget 2 s (the sibling ArchiveCategoryTests.scale measures ~780 ms Debug)")
    }

    // MARK: - Sensor

    @Test("SENSOR: every live archive copy is on the timeline exactly once, at production scale", .timeLimit(.minutes(1)))
    func everyLiveArchiveCopyIsOnTheTimeline() throws {
        let (model, dir) = try Self.makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        var records: [VideoRecord] = []
        var copies: [VideoRecord] = []
        records.reserveCapacity(110_000)
        for i in 0..<100_000 {
            let r = Self.source("/Volumes/Src\(i % 4)/clip_\(i).mov")
            records.append(r)
            guard i % 10 == 0 else { continue }
            let c = Self.copy(of: r, rel: "30_Video/1990-1999/\(1990 + i % 10)/clip_\(i).mov")
            copies.append(c)
            records.append(c)
            switch (i / 10) % 5 {
            case 0: break                                                   // live source
            case 1: Self.trash(r)                                            // Prune
            case 2: r.removal = .removedFromCatalog(at: Date(), reason: .userRemoved)
            case 3: r.setAsideReason = "still-image"
            default: r.supersededByID = UUID()
            }
        }
        // Sources the catalog never held (import-era copies): a realistic
        // minority — an id miss costs RecordIDIndex one linear scan.
        for i in 0..<50 {
            let orphan = Self.copy(of: Self.source("/Volumes/Gone/o\(i).mov"), rel: "30_Video/Undated/o\(i).mov")
            copies.append(orphan)
            records.append(orphan)
        }
        model.records = records
        let snap = Self.snapshot(model)
        let tl = Self.timeline(model, snap)
        let items = tl.decades.flatMap(\.years).flatMap(\.items) + tl.undated
        let shown = Dictionary(grouping: items, by: \.id).mapValues(\.count)
        var missing: [String] = []
        for c in copies where c.removal == nil {
            let source = ArchiveCategorySnapshot.sourceRepresents(c, model: model) ? model.promotionSource(of: c) : nil
            let representative = source?.id ?? c.id
            if shown[representative] != 1 { missing.append(c.filename) }
        }
        #expect(missing.isEmpty, "\(missing.count) live archive copies missing or doubled on the timeline, e.g. \(missing.prefix(5))")
        #expect(items.count == copies.count)
    }

    @Test("SENSOR (source): the snapshot decides representation through sourceRepresents, not 'a source row exists'")
    func snapshotAsksSourceRepresents() throws {
        let url = try #require(SourceTree.appSourceURL(named: "ArchiveView+Categories.swift"))
        let code = SourceTree.scan(try String(contentsOf: url, encoding: .utf8)).code
        let start = try #require(code.range(of: "static func compute("))
        let end = try #require(code.range(of: "static func sourceRepresents(", range: start.upperBound..<code.endIndex))
        let compute = String(code[start.upperBound..<end.lowerBound])
        #expect(compute.contains("sourceRepresents("), "compute must ask sourceRepresents for an archive copy")
        #expect(!compute.contains("promotionSource(of:"),
                "compute must not decide on 'promotionSource(of:) == nil' — a trashed source still exists (P0 2026-10-22)")
    }
}
