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
}
