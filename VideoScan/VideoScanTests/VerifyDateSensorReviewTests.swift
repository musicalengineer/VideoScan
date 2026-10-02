// VerifyDateSensorReviewTests.swift
// Codex review 2026-10-02, findings 5 (P2) and 6 (P3) — the GH #219 date
// sensor inside Verify Archive Copies.
//
//   #5: after a record-id / source-id FALLBACK match (the copy's current
//       path is not the manifest row's path), the sensor compared the
//       manifest's placement against ITSELF. It must compare the index
//       date against the record's CURRENT relative path.
//   #6: placement vs index used exact equality; the rule is agreement at
//       the coarser precision (`ArchiveDateAgreement.agree`), as for the
//       catalog leg — 2001-02-03 on disk agrees with an index "2001".
//
// Pure / synthetic: no files are hashed. Sandbox only.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Codex 2026-10-02 #5/#6 — Verify date sensor: current placement, coarser precision", .serialized)
@MainActor
struct VerifyDateSensorReviewTests {

    @Test("#6: a day-precise placement agrees with a year-precise index and user date")
    func placementVersusIndexUsesCoarserPrecision() {
        #expect(ArchiveDateAgreement.problems(
            relPath: "30_Video/2000-2009/2001/2001-02-03_test_clip.mov",
            manifestDate: "2001-xx-xx",
            userDate: "2001",
            filedDate: "2001-02-03"
        ).isEmpty)
        // …and a real placement disagreement is still reported.
        let p = ArchiveDateAgreement.problems(relPath: "30_Video/2000-2009/2002/2002-02-03_test_clip.mov",
                                              manifestDate: "2001-xx-xx", userDate: nil, filedDate: nil)
        #expect(p.count == 1 && p[0].contains("index says 2001"), "\(p)")
        // Month-level disagreement inside the same year is still a disagreement.
        let m = ArchiveDateAgreement.problems(relPath: "30_Video/2000-2009/2001/2001-03-xx_test_clip.mov",
                                              manifestDate: "2001-02-xx", userDate: nil, filedDate: nil)
        #expect(m.count == 1, "\(m)")
    }

    @Test("#5: a fallback (record-id) match compares the index against the record's CURRENT path")
    func fallbackMatchUsesCurrentPath() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("verify_current")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        let root = sb.archiveRoot.path

        let rec = VideoRecord()
        rec.derivationKind = ArchivePromotion.derivationKind
        rec.fullPath = root + "/30_Video/2000-2009/2002/2002-xx-xx_test_clip.mov"   // where it is NOW
        rec.filename = "2002-xx-xx_test_clip.mov"
        rec.userDate = "2001"
        model.records = [rec]

        let filedRel = "30_Video/2000-2009/2001/2001-xx-xx_test_clip.mov"              // where the index says
        let text = MasterArchiveLayout.manifestHeader + "\n"
            + ArchiveManifestCSV.line(for: .init(promotedAt: Date(), archiveRelPath: filedRel,
                                                 sha256: String(repeating: "a", count: 64), sizeBytes: 10,
                                                 originalPath: "/Volumes/test_V/c.mov", originalVolume: "test_V",
                                                 recordID: rec.id, sourceRecordID: UUID(),
                                                 recordDate: "2001-xx-xx", dateConfidence: "user-known",
                                                 people: [], starRating: 3))
        let manifest = VerifyArchiveManifestIndex.parse(text: text)
        let plan = VerifyArchiveCopiesJob.collectPlan(model: model, root: root, manifest: manifest)
        #expect(plan.items.count == 1)
        #expect(plan.dateDisagreements.count == 1, "\(plan.dateDisagreements)")
        #expect(plan.dateDisagreements.first?.contains("2002") == true, "names the current placement: \(plan.dateDisagreements)")
    }

    @Test("#5 control: an exact relpath match that agrees is not flagged")
    func exactMatchAgreeing() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("verify_exact")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        let root = sb.archiveRoot.path
        let rel = "30_Video/2000-2009/2001/2001-02-03_test_clip.mov"
        let rec = VideoRecord()
        rec.derivationKind = ArchivePromotion.derivationKind
        rec.fullPath = root + "/" + rel
        rec.filename = (rel as NSString).lastPathComponent
        rec.userDate = "2001"
        model.records = [rec]
        let text = MasterArchiveLayout.manifestHeader + "\n"
            + ArchiveManifestCSV.line(for: .init(promotedAt: Date(), archiveRelPath: rel,
                                                 sha256: String(repeating: "b", count: 64), sizeBytes: 10,
                                                 originalPath: "/Volumes/test_V/c.mov", originalVolume: "test_V",
                                                 recordID: rec.id, sourceRecordID: UUID(),
                                                 recordDate: "2001-xx-xx", dateConfidence: "user-known",
                                                 people: [], starRating: 3))
        let plan = VerifyArchiveCopiesJob.collectPlan(model: model, root: root,
                                                      manifest: VerifyArchiveManifestIndex.parse(text: text))
        #expect(plan.dateDisagreements.isEmpty, "\(plan.dateDisagreements)")
    }
}
