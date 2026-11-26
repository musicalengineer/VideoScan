// ProductionShapeArchivedTwinDateTests.swift
// GH #528 at PRODUCTION SHAPE: Rick's real catalog (a sqlite .backup copy in
// a temp folder, ProductionShapeScene), the app's real launch. No media file
// is opened.
//
// The test: (1) every live unarchived copy of archived content (same whole-
// file digest as a live archived row — the plain scan, independent of the
// index) is called date-read-only by the seam, and no other row is; (2) a
// date written on one such twin BEHIND the seam's back is refused at commit,
// and after a relaunch the archived copy still shows the date it was filed
// under. Counts only (privacy).
//
// Red/green: the red is ArchivedTwinDateWritersTests (seen RED on the
// pre-fix code). This is the guard at production shape.
//
// ISOLATION: reads the real catalog (read-only .backup) — skipped where it is
// absent (sealed homes, other Macs); runs in the nightly all-tests pass and by
// hand on Rick's Mac. Writes only to the copy.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Production-shape: every copy of archived content is date-fixed (GH #528) — ISOLATION: reads the real catalog",
       .serialized, .enabled(if: LiveCatalogCopy.present, LiveCatalogCopy.skipWords))
@MainActor
struct ProductionShapeArchivedTwinDateTests {

    @Test("the live copy: every twin of archived content is date-fixed, nothing else is; a twin's date written behind the seam is refused and the relaunch shows the filed date")
    func everyTwinIsFixed() async throws {
        let shape = try await ProductionShapeScene.make("twin528"); defer { shape.cleanup() }
        let model = shape.model

        var archivedByDigest: [String: VideoRecord] = [:]
        for r in model.records where r.removal == nil && model.isDateReadOnlyItself(r) {
            if let d = CatalogCommit.digest(of: r), archivedByDigest[d] == nil { archivedByDigest[d] = r }
        }
        try #require(!archivedByDigest.isEmpty, "the copy has no live archived content — the test lost its teeth")
        let twins = model.records.filter { r in
            !model.isDateReadOnlyItself(r) && CatalogCommit.digest(of: r).flatMap { archivedByDigest[$0] } != nil
        }
        let twinIDs = Set(twins.map(\.id))
        let notFixed = twins.filter { !model.isDateReadOnly($0) }.count
        let wronglyFixed = model.records.filter {
            !model.isDateReadOnlyItself($0) && !twinIDs.contains($0.id) && model.isDateReadOnly($0)
        }.count
        let disagreeing = twins.filter { t in
            CatalogCommit.digest(of: t).flatMap { archivedByDigest[$0] }.map { $0.userDate != t.userDate } ?? false
        }.count
        print("archived twins (production shape): \(model.records.count) rows · \(archivedByDigest.count) live archived contents · "
              + "\(twins.count) unarchived copies of them (\(disagreeing) showing a different user date in memory) · "
              + "rebuilds \(model.archivedContentIndex.rebuildCount)")
        #expect(notFixed == 0, "\(notFixed) twin(s) of archived content are still date-writable")
        #expect(wronglyFixed == 0, "\(wronglyFixed) row(s) with no archived copy were called date-fixed")

        // A write behind the seam's back on one live twin: refused at commit.
        guard let twin = twins.first(where: { $0.removal == nil && model.catalogCutover.committer?.owns($0) ?? true }),
              let digest = CatalogCommit.digest(of: twin), let archived = archivedByDigest[digest] else {
            print("archived twins (production shape): no live twin to write — the commit leg is covered by ArchivedTwinDateWritersTests")
            await shape.close()
            return
        }
        let filed = archived.userDate
        twin.userDate = "1888"
        #expect(model.saveCatalogNow())
        #expect(twin.userDate == archived.userDate, "the twin is put back to the archived copy's date")
        let fresh = try await shape.relaunchedModel()
        let back = try #require(fresh.records.first { $0.id == archived.id })
        #expect(back.userDate == filed, "the archived copy shows the date it was filed under after relaunch")
        #expect(fresh.records.first { $0.id == twin.id }?.userDate != "1888")
        await ProductionShapeScene.close(fresh)
    }
}
