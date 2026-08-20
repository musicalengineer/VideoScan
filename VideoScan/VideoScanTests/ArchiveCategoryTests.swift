// ArchiveCategoryTests.swift
// The Archive tab's Master-Archive-driven sidebar/table derivations
// (ArchiveView+Categories.swift), headless. Feature-test checklist:
//   1. Logic  — category membership, status, people cell, footer text
//   2. Scale  — 100k records: one compute per RecordsVersion, under budget
//   4. Isolation — model uses CatalogStore(directory:) in a temp dir
//   5. Sensor — the "one recompute per version" pin at production scale
//
// Rick 2026-08-17: the old sidebar counted lifecycleStage=.archived
// stamps (737 "keepers" from the 2026-05-31 Reconcile) as archive
// progress. These tests pin that the new numbers come ONLY from promoted
// copies (derivationKind == archivePromotion) and never double-count a
// source with its copy.

import Foundation
import Testing
@testable import VideoScan

@Suite("Archive tab — categories")
@MainActor
struct ArchiveCategoryTests {

    // MARK: - Fixtures

    private static let archiveRoot = "/Volumes/TestArchive/Breen_Family_Archive"

    private static func makeModel() throws -> (VideoScanModel, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_archivecat_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        model.masterArchive = MasterArchiveDesignation(targetPath: "/Volumes/TestArchive",
                                                       rootPath: archiveRoot)
        return (model, dir)
    }

    private static func source(_ name: String, volume: String = "/Volumes/Src") -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "\(volume)/\(name)"
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.sizeBytes = 1_000
        return r
    }

    /// A promoted copy of `src` inside the archive; verified unless told otherwise.
    private static func copy(of src: VideoRecord, rel: String, verified: Bool = true) -> VideoRecord {
        let c = VideoRecord()
        c.filename = (rel as NSString).lastPathComponent
        c.fullPath = archiveRoot + "/" + rel
        c.derivedFrom = src.id
        c.derivationKind = ArchivePromotion.derivationKind
        c.sizeBytes = src.sizeBytes
        if verified {
            c.archiveFixity = ArchiveFixity(digest: "ab", verifiedAt: Date(), sizeBytes: src.sizeBytes)
        }
        return c
    }

    private static func snapshot(_ model: VideoScanModel, volumes: [String] = []) -> ArchiveCategorySnapshot {
        ArchiveCategorySnapshot.compute(active: pfActiveRecords(model.records),
                                        allRecords: model.records,
                                        model: model,
                                        volumeSearchPaths: volumes)
    }

    // MARK: - 1. Logic: membership

    @Test("archived asset counted ONCE (source with copy), orphan copy counted, plain source not-yet")
    func membership() throws {
        let (model, dir) = try Self.makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = Self.source("a_1995.mov")
        let aCopy = Self.copy(of: a, rel: "30_Video/1995/1995-xx-xx_a.mov")
        let orphanSrcID = UUID()
        let orphan = VideoRecord()
        orphan.filename = "orphan.mov"
        orphan.fullPath = Self.archiveRoot + "/30_Video/Undated/orphan.mov"
        orphan.derivedFrom = orphanSrcID
        orphan.derivationKind = ArchivePromotion.derivationKind
        orphan.archiveFixity = ArchiveFixity(digest: "cd", verifiedAt: Date(), sizeBytes: 5)
        let plain = Self.source("plain_2001.mov")
        model.records = [a, aCopy, orphan, plain]

        let snap = Self.snapshot(model)
        #expect(snap.archived.map(\.id) == [a.id, orphan.id],
                "archived = the SOURCE a (not its copy) + the orphan copy")
        #expect(snap.notYetArchived.map(\.id) == [plain.id],
                "not-yet excludes the copy AND the promoted source")
        #expect(snap.activeAssetCount == 3, "a, orphan, plain — the copy of a is not a second asset")
        #expect(snap.count(for: .archived) == 2)
        #expect(snap.count(for: .notYetArchived) == 1)
    }

    @Test("purged / set-aside / superseded records are excluded everywhere")
    func inertExcluded() throws {
        let (model, dir) = try Self.makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        let purged = Self.source("purged.mov"); purged.purgedAt = Date()
        let aside = Self.source("aside.mov"); aside.setAsideReason = "junk"
        let sup = Self.source("sup.mov"); sup.supersededByID = UUID()
        let purgedSrc = Self.source("psrc.mov"); purgedSrc.purgedAt = Date()
        let purgedCopy = Self.copy(of: purgedSrc, rel: "30_Video/x.mov"); purgedCopy.purgedAt = Date()
        let live = Self.source("live.mov")
        model.records = [purged, aside, sup, purgedSrc, purgedCopy, live]

        let snap = Self.snapshot(model)
        #expect(snap.archived.isEmpty)
        #expect(snap.notYetArchived.map(\.id) == [live.id])
        #expect(snap.activeAssetCount == 1)
    }

    @Test("legacy lifecycleStage=.archived stamps do NOT count as archived")
    func legacyStampsIgnored() throws {
        let (model, dir) = try Self.makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        let stamped = Self.source("witness.mov")
        stamped.lifecycleStage = .archived
        stamped.archiveStage = .archived
        model.records = [stamped]
        let snap = Self.snapshot(model)
        #expect(snap.archived.isEmpty, "a Reconcile witness stamp is provenance, not a promoted copy")
        #expect(snap.notYetArchived.count == 1)
        #expect(ArchiveCategorySnapshot.status(of: stamped, model: model) == .notArchived)
    }

    @Test("Needs a Date = not-yet-archived with unresolvable date; dated files excluded")
    func needsDate() throws {
        let (model, dir) = try Self.makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        let undated = Self.source("MVI_0042.MOV")
        let byFilename = Self.source("Christmas_1994.mov")
        let byUser = Self.source("clip.mov"); byUser.userDate = "1988"
        let promotedUndated = Self.source("MVI_0043.MOV")
        let promotedCopy = Self.copy(of: promotedUndated, rel: "30_Video/Undated/MVI_0043.MOV")
        model.records = [undated, byFilename, byUser, promotedUndated, promotedCopy]
        let snap = Self.snapshot(model)
        #expect(snap.needsDate.map(\.id) == [undated.id],
                "only the unarchived undated one — the promoted undated file is already archived")
        #expect(snap.notYetArchived.count == 3)
    }

    // MARK: - 1. Logic: per-row status + relpath

    @Test("status: verified / unverified / orphan / not archived, with archive relpaths")
    func rowStatus() throws {
        let (model, dir) = try Self.makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        let v = Self.source("v.mov"); let vCopy = Self.copy(of: v, rel: "30_Video/1990/v.mov")
        let u = Self.source("u.mov"); let uCopy = Self.copy(of: u, rel: "30_Video/1991/u.mov", verified: false)
        let orphan = VideoRecord()
        orphan.fullPath = Self.archiveRoot + "/20_Audio/Undated/o.wav"
        orphan.filename = "o.wav"
        orphan.derivedFrom = UUID()
        orphan.derivationKind = ArchivePromotion.derivationKind
        let plain = Self.source("p.mov")
        model.records = [v, vCopy, u, uCopy, orphan, plain]

        #expect(ArchiveCategorySnapshot.status(of: v, model: model) == .verified(relPath: "30_Video/1990/v.mov"))
        #expect(ArchiveCategorySnapshot.status(of: vCopy, model: model) == .verified(relPath: "30_Video/1990/v.mov"),
                "a copy with a live source reports like its source")
        #expect(ArchiveCategorySnapshot.status(of: u, model: model) == .unverified(relPath: "30_Video/1991/u.mov"))
        #expect(ArchiveCategorySnapshot.status(of: orphan, model: model) == .orphanCopy(relPath: "20_Audio/Undated/o.wav"))
        #expect(ArchiveCategorySnapshot.status(of: plain, model: model) == .notArchived)
        #expect(ArchiveRowStatus.notArchived.relPath == nil)
        #expect(ArchiveRowStatus.orphanCopy(relPath: "x").label == "orphan copy (source gone)")
    }

    @Test("relpath falls back to the full path when no root / outside root")
    func relPathFallback() {
        #expect(ArchiveCategorySnapshot.relativePath("/Volumes/X/a.mov", root: nil) == "/Volumes/X/a.mov")
        #expect(ArchiveCategorySnapshot.relativePath("/Volumes/X/a.mov", root: "/Volumes/Y") == "/Volumes/X/a.mov")
        #expect(ArchiveCategorySnapshot.relativePath("/Volumes/X/A/b/c.mov", root: "/Volumes/X/A") == "b/c.mov")
        // Prefix-string trap: "/Volumes/AB" is NOT inside "/Volumes/A".
        #expect(ArchiveCategorySnapshot.relativePath("/Volumes/AB/c.mov", root: "/Volumes/A") == "/Volumes/AB/c.mov")
    }

    // MARK: - 1. Logic: people cell

    @Test("people cell: confirmed → detected → suspected?, deduped, em dash when empty")
    func peopleCell() {
        let r = VideoRecord()
        r.confirmedByUserPeople = [ConfirmedTag(name: "Rick", confirmedAt: Date()),
                                   ConfirmedTag(name: "Matt", confirmedAt: Date())]
        r.detectedPeople = ["rick", "Tim"]          // "rick" dupes the confirmed Rick
        r.suspectedPeople = ["Donna", "matt"]       // "matt" dupes the confirmed Matt
        #expect(ArchivePeopleCell.text(for: r) == "Rick, Matt, Tim · Donna?")

        let confirmedOnly = VideoRecord()
        confirmedOnly.confirmedByUserPeople = [ConfirmedTag(name: "Donna", confirmedAt: Date())]
        #expect(ArchivePeopleCell.text(for: confirmedOnly) == "Donna",
                "the old column showed '—' here — 'people not following' (Rick 2026-08-17)")

        let suspectedOnly = VideoRecord()
        suspectedOnly.suspectedPeople = ["Donna"]
        #expect(ArchivePeopleCell.text(for: suspectedOnly) == "Donna?")

        #expect(ArchivePeopleCell.text(for: VideoRecord()) == "—")
    }

    // MARK: - 1. Logic: footer + volume counts

    @Test("footer 'N of M media files archived · X verified' + per-volume counts")
    func footerAndVolumeCounts() throws {
        let (model, dir) = try Self.makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = Self.source("a.mov", volume: "/Volumes/A"); a.sizeBytes = 2_000_000
        let aCopy = Self.copy(of: a, rel: "30_Video/1990/a.mov")
        let b = Self.source("b.mov", volume: "/Volumes/A")
        let c = Self.source("c.mov", volume: "/Volumes/B")
        let ab = Self.source("x.mov", volume: "/Volumes/AB")   // prefix trap
        model.records = [a, aCopy, b, c, ab]

        let snap = Self.snapshot(model, volumes: ["/Volumes/A", "/Volumes/B", "/Volumes/TestArchive"])
        let text = snap.footerText(totals: model.masterArchiveTotals)
        #expect(text.hasPrefix("1 of 4 media files archived · "), "got: \(text)")
        #expect(text.hasSuffix(" verified"))
        #expect(text.contains("2 MB") || text.contains("2,0") || text.contains("2.0"), "bytes = the copy's size, got: \(text)")
        #expect(snap.volumeFileCounts["/Volumes/A"] == 2, "component boundary: /Volumes/A must NOT swallow /Volumes/AB (codex QA 2026-08-20)")
        #expect(snap.volumeFileCounts["/Volumes/B"] == 1)
        #expect(snap.volumeFileCounts["/Volumes/TestArchive"] == 1)
    }

    // MARK: - 2. Scale + 5. Sensor

    @Test("100k records: one compute per RecordsVersion, under budget", .timeLimit(.minutes(1)))
    func scale() throws {
        let (model, dir) = try Self.makeModel(); defer { try? FileManager.default.removeItem(at: dir) }
        var records: [VideoRecord] = []
        records.reserveCapacity(105_000)
        var sources: [VideoRecord] = []
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.filename = i % 3 == 0 ? "clip_\(i).mov" : "Trip_1990_\(i).mov"
            r.fullPath = "/Volumes/Src\(i % 4)/clip_\(i).mov"
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            records.append(r)
            if i % 20 == 0 { sources.append(r) }   // 5,000 promoted
        }
        for s in sources { records.append(Self.copy(of: s, rel: "30_Video/1990/\(s.filename)")) }
        model.records = records
        let volumes = ["/Volumes/Src0", "/Volumes/Src1", "/Volumes/Src2", "/Volumes/Src3", "/Volumes/TestArchive"]

        let memo = RenderMemo<ArchiveCategoryKey, ArchiveCategorySnapshot>()
        let t0 = CFAbsoluteTimeGetCurrent()
        let first = ArchiveCategorySnapshot.cached(in: memo, model: model, volumeSearchPaths: volumes)
        let computeMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        #expect(first.archived.count == 5_000)
        #expect(first.notYetArchived.count == 95_000)
        #expect(first.activeAssetCount == 100_000)
        #expect(first.volumeFileCounts["/Volumes/Src0"] == 25_000)
        #expect(computeMs < 2_000, "one full compute at 100k+5k took \(Int(computeMs)) ms — budget 2 s (measured ~780 ms Debug on M4 Max)")

        // 1,000 "renders" at the same version → zero recomputes.
        let t1 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<1_000 {
            _ = ArchiveCategorySnapshot.cached(in: memo, model: model, volumeSearchPaths: volumes)
        }
        let renderMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
        #expect(memo.computeCount == 1, "1,000 renders must not recompute (was \(memo.computeCount))")
        #expect(renderMs < 200, "1,000 memo hits took \(Int(renderMs)) ms")

        // A mutation (revision bump) → exactly ONE more compute.
        model.volumeAggregatesRevision &+= 1
        _ = ArchiveCategorySnapshot.cached(in: memo, model: model, volumeSearchPaths: volumes)
        _ = ArchiveCategorySnapshot.cached(in: memo, model: model, volumeSearchPaths: volumes)
        #expect(memo.computeCount == 2)

        // A volume list change → one more.
        _ = ArchiveCategorySnapshot.cached(in: memo, model: model, volumeSearchPaths: Array(volumes.dropLast()))
        #expect(memo.computeCount == 3)
    }
}
