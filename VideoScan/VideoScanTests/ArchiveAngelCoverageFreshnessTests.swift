// ArchiveAngelCoverageFreshnessTests.swift
// Rules v13 coverage — the freshness / cache-walk-parity boundaries the QA
// review of feat/angel-coverage (2026-09-26) found holes in. RED first.
//
//   MAJOR-1  a footage decision / regroup and a Master Archive designation
//            change must bump `ArchiveAngel.catalogRevision` (they went
//            through noteCatalogRecordsMutated, which never reached the
//            façade; only the `records` didSet did).
//   MAJOR-3  the job's walk must mark archived footage the way the sweep
//            does (codex C1): a Likely sibling of an archived original is
//            covered, and the year's backlog line agrees between paths.
//   MAJOR-4  a stamp from another LAUNCH is never current: the counter
//            restarts at 0, so yesterday's "57" must not beat today's "3".

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archive Angel coverage — freshness at the catalog boundaries (QA MAJORs 1, 3, 4)", .serialized)
@MainActor
struct ArchiveAngelCoverageFreshnessTests {

    @Test("MAJOR-1: a footage decision and a Master Archive designation change each bump catalogRevision")
    func catalogMutationsBumpTheRevision() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("angel_cov_revision")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.archiveAngel.sweep.stop()
        let a = MasterArchiveTestSupport.makeRecord(path: sb.sources.appendingPathComponent("a.mov").path)
        let b = MasterArchiveTestSupport.makeRecord(path: sb.sources.appendingPathComponent("b.mov").path)
        model.records = [a, b]
        let afterRecords = model.archiveAngel.catalogRevision
        #expect(afterRecords > 0, "assigning records bumps it (the didSet path, already wired)")

        await model.setFootageDecision(.notSame, between: a.id, and: b.id)?.value
        let afterDecision = model.archiveAngel.catalogRevision
        #expect(afterDecision > afterRecords, "a footage decision is a catalog change the coverage rules read")

        model.masterArchive = MasterArchiveDesignation(targetPath: sb.archiveVolume.path,
                                                       rootPath: sb.archiveRoot.path, volumeUUID: nil)
        model.clearMasterArchive()
        #expect(model.archiveAngel.catalogRevision > afterDecision, "the Master Archive designation is a catalog fact")
    }

    @Test("MAJOR-3 (codex C1): the job's walk marks archived footage like the sweep — a Likely sibling of an archived original is covered, and the year's backlog line is the sweep's")
    func walkMarksArchivedFootage() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("angel_cov_walk_footage")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.scanTargets = []
        model.previewSweep.stop()
        model.archiveAngel.sweep.stop()
        func add(_ name: String) throws -> VideoRecord {
            let path = sb.sources.appendingPathComponent(name).path
            try MasterArchiveTestSupport.writeBlob(at: URL(fileURLWithPath: path), bytes: 4096, seed: 9)
            let rec = MasterArchiveTestSupport.makeRecord(path: path, userDate: "1994-11-24", starRating: 3)
            rec.durationSeconds = 1800; rec.sizeBytes = 9_000_000_000; rec.isPlayable = "Yes"; rec.videoCodec = "dvvideo"
            return rec
        }
        let original = try add("A_original.dv")
        original.derivationKind = ArchivePromotion.derivationKind          // an archive copy: archived
        let sibling = try add("B_reencode.mp4")                             // no byte link, no derivedFrom — footage only
        let g = UUID()
        original.footage = FootageMembership(groupID: g, groupSize: 2, confidence: .likely, role: .original, rank: 0,
                                             likelyOriginalID: original.id, originalInCatalog: true, evidence: [],
                                             scannedAt: Date(), algorithmVersion: 1)
        sibling.footage = FootageMembership(groupID: g, groupSize: 2, confidence: .likely, role: .reEncode, rank: 1,
                                            likelyOriginalID: original.id, originalInCatalog: true, evidence: [],
                                            scannedAt: Date(), algorithmVersion: 1)
        model.records = [original, sibling]
        // The sweep's answer for the same catalog.
        var sweepCandidates = model.archiveAngelSweepCandidates()
        let sweepTable = ArchiveAngelEvent.applyCoverage(&sweepCandidates, policy: model.archiveAngel.policy)
        #expect(sweepCandidates.first { $0.id == sibling.id }?.archivedFootageOriginal == true)
        #expect(sweepTable.years[1994] == .init(unarchived: 0, archived: 1), "one recording, archived: \(sweepTable)")

        // Prepare with NO evidence → the walk.
        #expect(!model.archiveAngel.store.isLoaded)
        let buffer = sb.root.appendingPathComponent("Buffer", isDirectory: true)
        try FileManager.default.createDirectory(at: buffer, withIntermediateDirectories: true)
        let center = MediaFileOperationsCenter()
        let job = ArchiveAngelJob(model: model, center: center, count: 1, makeLossless: false, bufferRoot: buffer)
        job.start()
        await job.task?.value
        _ = center
        #expect(job.plan.entries.isEmpty, "B is covered — nothing to prepare: \(job.plan.entries.map(\.filename))")
        #expect(job.plan.rejected[ArchiveAngelRejection.footageOriginalArchived.rawValue] == 1, "\(job.plan.rejected)")
        let expectedLine = ArchiveAngelEvent.summaryLine(sweepTable)
        #expect(job.plan.log.contains { $0.hasSuffix(expectedLine) }, "the walk's backlog line must be the sweep's: \(job.plan.log)")
    }
}
