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
