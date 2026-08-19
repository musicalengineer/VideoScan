import Foundation
import Testing
@testable import VideoScan

// "Audit Catalog" (Storage ▸ Catalog row, 2026-08-19) — pure auditor.
// Logic: each check fires on a constructed defect and stays quiet on a
// clean catalog. Scale: 100k records under 1 s. Isolation: no I/O.

private func rec(_ path: String, bytes: Int64 = 1_000, active: Bool = true, purged: Bool = false,
                 stage: String = "Cataloged", group: UUID? = nil, groupCount: Int = 0,
                 pairedWith: UUID? = nil, promoted: Bool = false, id: UUID = UUID()) -> CatalogAuditRecord {
    CatalogAuditRecord(id: id, fullPath: path, sizeBytes: bytes, isActive: active && !purged, isPurged: purged,
                       lifecycleRaw: stage, duplicateGroupID: group, duplicateGroupCount: groupCount,
                       pairedWithID: pairedWith, isPromotedCopy: promoted)
}
private func tgt(_ p: String, retired: Bool = false, cached: Int? = nil) -> CatalogAuditTarget {
    CatalogAuditTarget(searchPath: p, isRetired: retired, cachedRecordCount: cached)
}
private func status(_ r: CatalogAuditReport, _ check: String) -> CatalogAuditStatus {
    r.findings.first { $0.check == check }!.status
}

@Suite("Catalog audit")
struct CatalogAuditTests {

    @Test func cleanCatalogPassesEverything() {
        let g = UUID()
        let a = UUID(), b = UUID()
        let r = CatalogAuditor.run(CatalogAuditInputs(records: [
            rec("/Volumes/A/x.mov", group: g, groupCount: 2, pairedWith: b, id: a),
            rec("/Volumes/A/y.mov", group: g, groupCount: 2, pairedWith: a, id: b),
            rec("/Volumes/B/z.mov", promoted: true),
            rec("/Volumes/B/t.mov", purged: true, stage: "Trashed"),
        ], targets: [tgt("/Volumes/A", cached: 2), tgt("/Volumes/B", cached: 1)], archiveIndexPromoted: 1))
        #expect(r.overall == .pass, "\(r.text)")
        #expect(r.activeRecords == 3)
        #expect(r.totalRecords == 4)
    }

    @Test func eachDefectIsCaught() {
        let g = UUID()
        let ghost = UUID()
        let r = CatalogAuditor.run(CatalogAuditInputs(records: [
            rec("/Volumes/A/x.mov", bytes: 0),                                  // bad size
            rec("/Volumes/A/sub/y.mov"),                                       // double-claimed (A and A/sub)
            rec("/Volumes/Nowhere/z.mov"),                                     // orphan
            rec("/Volumes/A/d1.mov", group: g, groupCount: 3),                  // group says 3, has 2
            rec("/Volumes/A/d2.mov", group: g, groupCount: 3),
            rec("/Volumes/A/p.mov", pairedWith: ghost),                        // dangling pair
            rec("/Volumes/A/q.mov", purged: true, stage: "Cataloged"),         // purged but staged
            rec("/Volumes/A/arch.mov", promoted: true),                        // index says 0
        ], targets: [tgt("/Volumes/A", cached: 99), tgt("/Volumes/A/sub"), tgt("/Volumes/Empty")],
           archiveIndexPromoted: 0))
        #expect(status(r, "Sizes") == .warn)
        #expect(status(r, "Nested scan targets") == .warn)
        #expect(status(r, "Unplaced records") == .warn)
        #expect(status(r, "Duplicate groups") == .warn)
        #expect(status(r, "A/V pairs") == .warn)
        #expect(status(r, "Purged records") == .warn)
        #expect(status(r, "Master Archive index") == .fail)
        #expect(status(r, "Empty drives") == .warn)
        #expect(status(r, "Per-drive cache") == .warn)
        #expect(status(r, "Totals reconcile") == .warn)     // closes, but with a double count
        #expect(r.overall == .fail)
        #expect(r.text.contains("[FAIL] Master Archive index"))
    }

    @Test func hundredThousandUnderBudget() {
        var records: [CatalogAuditRecord] = []
        records.reserveCapacity(100_000)
        for i in 0..<100_000 {
            records.append(rec("/Volumes/D\(i % 8)/f\(i % 50)/c\(i).mov", bytes: Int64(i % 9 + 1)))
        }
        let targets = (0..<8).map { tgt("/Volumes/D\($0)", cached: 12_500) }
        let start = ContinuousClock.now
        let r = CatalogAuditor.run(CatalogAuditInputs(records: records, targets: targets, archiveIndexPromoted: 0))
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(r.overall == .pass, "\(r.text)")
    }
}

@Suite("Catalog audit — Show me actions")
struct CatalogAuditActionTests {
    @Test func actionableFindingsCarryDestinations() {
        let r = CatalogAuditor.run(CatalogAuditInputs(records: [
            rec("/Volumes/Nowhere/z.mov"),
            rec("/Volumes/A/sub/y.mov"),
            rec("/Volumes/A/x.mov", bytes: 0),
        ], targets: [tgt("/Volumes/A"), tgt("/Volumes/A/sub"), tgt("/Volumes/Empty")], archiveIndexPromoted: 0))
        func action(_ c: String) -> CatalogAuditAction { r.findings.first { $0.check == c }!.action }
        if case .focusRecords(let ids, _) = action("Unplaced records") { #expect(ids.count == 1) } else { Issue.record("no focus action") }
        #expect(action("Nested scan targets") == .selectVolume(searchPath: "/Volumes/A/sub"))
        #expect(action("Empty drives") == .selectVolume(searchPath: "/Volumes/Empty"))
        if case .focusRecords(let ids, let label) = action("Sizes") { #expect(ids.count == 1); #expect(label.contains("size")) } else { Issue.record("no focus action") }
        #expect(action("Master Archive index") == .none)       // advice-only
        #expect(action("Per-drive cache") == .none)
    }
}

@Suite("Catalog audit — Fix it for me")
@MainActor
struct CatalogAuditFixerTests {
    private func vr(_ path: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.directory = (path as NSString).deletingLastPathComponent
        r.fullPath = path
        r.sizeBytes = 10
        return r
    }

    @Test func fixesEachDeterministicDefectAndAuditThenPasses() {
        let model = VideoScanModel()
        let a = vr("/Volumes/A/a.mov"), b = vr("/Volumes/A/b.mov"), c = vr("/Volumes/A/c.mov")
        let d1 = vr("/Volumes/A/d1.mov"), d2 = vr("/Volumes/A/d2.mov"), d3 = vr("/Volumes/A/d3.mov")
        let purged = vr("/Volumes/A/p.mov")
        let g = UUID()
        // purged but staged
        purged.purgedAt = Date(); purged.lifecycleStage = .cataloged
        // dangling pair: a ↔ purged
        a.pairedWith = purged; purged.pairedWith = a
        // stale dup group: 3 members claim 4; d3 is purged → live members 2
        for r in [d1, d2, d3] { r.duplicateGroupID = g; r.duplicateGroupCount = 4 }
        d3.purgedAt = Date(); d3.lifecycleStage = .trashed
        model.records = [a, b, c, d1, d2, d3, purged]
        model.scanTargets = [CatalogScanTarget(searchPath: "/Volumes/A"), CatalogScanTarget(searchPath: "/Volumes/Empty")]

        let before = CatalogAuditor.run(CatalogAuditor.project(model: model))
        #expect(before.overall != .pass)
        for f in before.findings {
            if let fix = f.fix { _ = CatalogAuditFixer.apply(fix, model: model) }
        }
        #expect(purged.lifecycleStage == .trashed)
        #expect(a.pairedWith == nil && purged.pairedWith == nil)
        #expect(d1.duplicateGroupCount == 2 && d2.duplicateGroupCount == 2)
        #expect(model.scanTargets.count == 1)

        let after = CatalogAuditor.run(CatalogAuditor.project(model: model))
        let remaining = after.findings.filter { $0.status != .pass && $0.check != "Per-drive cache" }
        #expect(remaining.isEmpty, "\(after.text)")
    }
}
