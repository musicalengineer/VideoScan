import Foundation
import Testing
@testable import VideoScan

// R2 refactor gate (GH #281, plan docs/reviews/cloud/N1006-D-next-refactors.md
// "Guards and the test that must go red"). Each test pins one guard of
// CatalogAuditor.run that no existing test failed on when the guard was
// deleted (A2, A8–A13), plus a whole-report snapshot. They were written
// BEFORE run() was split, and each was shown red under a mutation of its
// guard. Logic only; scale stays with CatalogAuditTests.hundredThousand….

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
private func finding(_ r: CatalogAuditReport, _ check: String) -> CatalogAuditFinding? {
    r.findings.first { $0.check == check }
}
/// Fixed UUIDs so the snapshot is reproducible ("…0001", "…0002", …).
private func uid(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
}

@Suite("Catalog audit — guards pinned before the R2 split")
struct CatalogAuditGuardTests {

    /// A2: a purged record whose stage is "Deleted" is terminal, like "Trashed".
    @Test func purgedAndDeletedIsTerminal() {
        let r = CatalogAuditor.run(CatalogAuditInputs(records: [
            rec("/Volumes/A/x.mov"),
            rec("/Volumes/A/gone.mov", purged: true, stage: "Deleted"),
        ], targets: [tgt("/Volumes/A", cached: 1)], archiveIndexPromoted: 0))
        #expect(finding(r, "Purged records")?.status == .pass, "\(r.text)")
        #expect(finding(r, "Purged records")?.fix == nil)
    }

    /// A8: a RETIRED drive with zero records is not an empty drive to delete.
    @Test func retiredEmptyTargetIsNotOffered() {
        let r = CatalogAuditor.run(CatalogAuditInputs(records: [
            rec("/Volumes/A/x.mov"),
        ], targets: [tgt("/Volumes/A", cached: 1), tgt("/Volumes/OldTape", retired: true, cached: 0)],
           archiveIndexPromoted: 0))
        let f = finding(r, "Empty drives")
        #expect(f?.status == .pass, "\(r.text)")
        #expect(f?.fix == nil)
        #expect(f?.action == CatalogAuditAction.none)
    }

    /// A9: members of one group that disagree on the count (first says 2,
    /// which equals the live membership; the second says 3) → stale.
    @Test func membersThatDisagreeAreStale() {
        let g = uid(900)
        let r = CatalogAuditor.run(CatalogAuditInputs(records: [
            rec("/Volumes/A/d1.mov", group: g, groupCount: 2),
            rec("/Volumes/A/d2.mov", group: g, groupCount: 3),
        ], targets: [tgt("/Volumes/A", cached: 2)], archiveIndexPromoted: 0))
        let f = finding(r, "Duplicate groups")
        #expect(f?.status == .warn, "\(r.text)")
        #expect(f?.fix == .recountDuplicateGroups(groupIDs: [g]))
        #expect(f?.examples.first?.contains("members disagree") == true)
    }

    /// A10: "Show me" for a stale group lists ACTIVE members only.
    @Test func staleGroupFocusSkipsPurgedMembers() {
        let g = uid(901)
        let a = uid(1), b = uid(2), purged = uid(3)
        let r = CatalogAuditor.run(CatalogAuditInputs(records: [
            rec("/Volumes/A/d1.mov", group: g, groupCount: 3, id: a),
            rec("/Volumes/A/d2.mov", group: g, groupCount: 3, id: b),
            rec("/Volumes/A/d3.mov", purged: true, stage: "Trashed", group: g, groupCount: 3, id: purged),
        ], targets: [tgt("/Volumes/A", cached: 2)], archiveIndexPromoted: 0))
        guard case .focusRecords(let ids, _)? = finding(r, "Duplicate groups")?.action else {
            Issue.record("no focus action: \(r.text)"); return
        }
        #expect(Set(ids) == [a, b])
    }

    /// A11: no archive index → the Master Archive check is skipped, not failed.
    @Test func masterArchiveCheckSkippedWithoutIndex() {
        let r = CatalogAuditor.run(CatalogAuditInputs(records: [
            rec("/Volumes/A/arch.mov", promoted: true),
        ], targets: [tgt("/Volumes/A", cached: 1)], archiveIndexPromoted: nil))
        #expect(finding(r, "Master Archive index") == nil)
        #expect(r.overall == .pass, "\(r.text)")
    }

    /// A12: a cold cache (nil) is "warming", never a mismatch.
    @Test func coldCacheIsWarmingNotMismatch() {
        let r = CatalogAuditor.run(CatalogAuditInputs(records: [
            rec("/Volumes/A/x.mov"), rec("/Volumes/B/y.mov"),
        ], targets: [tgt("/Volumes/A"), tgt("/Volumes/B")], archiveIndexPromoted: 0))
        let f = finding(r, "Per-drive cache")
        #expect(f?.status == .pass, "\(r.text)")
        #expect(f?.headline.contains("(2 still warming)") == true, "\(f?.headline ?? "")")
    }

    /// A13: the sheet and the tests key on `check`; the order is the report order.
    @Test func findingOrderAndNames() {
        let names = ["Totals reconcile", "Unplaced records", "Nested scan targets", "Empty drives", "Sizes",
                     "Duplicate groups", "A/V pairs", "Purged records", "Master Archive index", "Per-drive cache"]
        let inputs = CatalogAuditInputs(records: [rec("/Volumes/A/x.mov")],
                                        targets: [tgt("/Volumes/A", cached: 1)], archiveIndexPromoted: 0)
        #expect(CatalogAuditor.run(inputs).findings.map(\.check) == names)
        var noIndex = inputs
        noIndex.archiveIndexPromoted = nil
        #expect(CatalogAuditor.run(noIndex).findings.map(\.check) == names.filter { $0 != "Master Archive index" })
    }

    /// Whole-report snapshot: every check fires once (one stale group only,
    /// because the group check walks a Dictionary). Must stay green with
    /// ZERO edits across the split.
    @Test func wholeReportSnapshot() {
        let g = uid(902)
        let ghost = uid(999)
        var r = CatalogAuditor.run(CatalogAuditInputs(records: [
            rec("/Volumes/A/x.mov", bytes: 0, id: uid(10)),
            rec("/Volumes/A/sub/y.mov", id: uid(11)),
            rec("/Volumes/Nowhere/z.mov", id: uid(12)),
            rec("/Volumes/A/d1.mov", group: g, groupCount: 3, id: uid(13)),
            rec("/Volumes/A/d2.mov", group: g, groupCount: 3, id: uid(14)),
            rec("/Volumes/A/p.mov", pairedWith: ghost, id: uid(15)),
            rec("/Volumes/A/q.mov", purged: true, stage: "Cataloged", id: uid(16)),
            rec("/Volumes/A/arch.mov", promoted: true, id: uid(17)),
            rec("/Volumes/T/u.mov", purged: true, stage: "Trashed", id: uid(18)),
        ], targets: [tgt("/Volumes/A", cached: 99), tgt("/Volumes/A/sub"), tgt("/Volumes/Empty", cached: 0),
                     tgt("/Volumes/Retired", retired: true, cached: 0)],
           archiveIndexPromoted: 0), now: Date(timeIntervalSince1970: 1_000_000))
        #expect(r.duration >= 0)
        r.duration = 0
        var s = ""
        dump(r, to: &s)
        #expect(s == catalogAuditGoldenReport, "\n\(s)")
    }
}

/// `dump` of the output, captured from main@6db24a65 before the split.
/// Regenerate ONLY for a deliberate behaviour change, never for a refactor.
/// (A file-scope constant, not an enum member, so the type-body lint stays quiet.)
private let catalogAuditGoldenReport = #"""
▿ VideoScan.CatalogAuditReport
  ▿ findings: 10 elements
    ▿ VideoScan.CatalogAuditFinding
      - check: "Totals reconcile"
      - status: VideoScan.CatalogAuditStatus.warn
      - headline: "7 present records = 7 on 4 drives + 1 unplaced − 1 counted twice"
      - detail: "6.0 KB present; per-drive sum 6.0 KB."
      - examples: 0 elements
      - action: VideoScan.CatalogAuditAction.none
      - fix: nil
    ▿ VideoScan.CatalogAuditFinding
      - check: "Unplaced records"
      - status: VideoScan.CatalogAuditStatus.warn
      - headline: "1 present records are under no scan target (1.0 KB)"
      - detail: "They still count in the catalog but no drive\'s dashboard shows them. Add the drive, or Update Catalog to relink."
      ▿ examples: 1 element
        - "/Volumes/Nowhere/z.mov"
      ▿ action: VideoScan.CatalogAuditAction.focusRecords
        ▿ focusRecords: (2 elements)
          ▿ ids: 1 element
            - 00000000-0000-0000-0000-000000000012
          - label: "Audit: unplaced records"
      - fix: nil
    ▿ VideoScan.CatalogAuditFinding
      - check: "Nested scan targets"
      - status: VideoScan.CatalogAuditStatus.warn
      - headline: "1 records fall under two scan targets"
      - detail: "One scan path is inside another; per-drive totals double-count these. Delete the inner target from the list (right-click it) or keep it knowingly."
      ▿ examples: 1 element
        - "/Volumes/A/sub/y.mov"
      ▿ action: VideoScan.CatalogAuditAction.selectVolume
        ▿ selectVolume: (1 element)
          - searchPath: "/Volumes/A/sub"
      - fix: nil
    ▿ VideoScan.CatalogAuditFinding
      - check: "Empty drives"
      - status: VideoScan.CatalogAuditStatus.warn
      - headline: "1 active scan target with zero records"
      - detail: "Typo, unmounted-at-scan, or a drive that should be deleted from the list (right-click ▸ Delete from list)."
      ▿ examples: 1 element
        - "/Volumes/Empty"
      ▿ action: VideoScan.CatalogAuditAction.selectVolume
        ▿ selectVolume: (1 element)
          - searchPath: "/Volumes/Empty"
      ▿ fix: Optional(VideoScan.CatalogAuditFix.deleteEmptyTargets(searchPaths: ["/Volumes/Empty"]))
        ▿ some: VideoScan.CatalogAuditFix.deleteEmptyTargets
          ▿ deleteEmptyTargets: (1 element)
            ▿ searchPaths: 1 element
              - "/Volumes/Empty"
    ▿ VideoScan.CatalogAuditFinding
      - check: "Sizes"
      - status: VideoScan.CatalogAuditStatus.warn
      - headline: "1 present records have size ≤ 0"
      - detail: "Zero/negative sizes are excluded from every byte total — Update Catalog on that drive fixes them."
      ▿ examples: 1 element
        - "/Volumes/A/x.mov"
      ▿ action: VideoScan.CatalogAuditAction.focusRecords
        ▿ focusRecords: (2 elements)
          ▿ ids: 1 element
            - 00000000-0000-0000-0000-000000000010
          - label: "Audit: size unknown"
      - fix: nil
    ▿ VideoScan.CatalogAuditFinding
      - check: "Duplicate groups"
      - status: VideoScan.CatalogAuditStatus.warn
      - headline: "1 of 1 duplicate groups have a stale count"
      - detail: "duplicateGroupCount drifted from the live membership (a member was deleted or purged). Catalog tab ▸ Analyze ▸ Duplicates re-scores them."
      ▿ examples: 1 element
        - "group 00000000: 2 members, records say 3"
      ▿ action: VideoScan.CatalogAuditAction.focusRecords
        ▿ focusRecords: (2 elements)
          ▿ ids: 2 elements
            - 00000000-0000-0000-0000-000000000013
            - 00000000-0000-0000-0000-000000000014
          - label: "Audit: stale duplicate groups"
      ▿ fix: Optional(VideoScan.CatalogAuditFix.recountDuplicateGroups(groupIDs: [00000000-0000-0000-0000-000000000902]))
        ▿ some: VideoScan.CatalogAuditFix.recountDuplicateGroups
          ▿ recountDuplicateGroups: (1 element)
            ▿ groupIDs: 1 element
              - 00000000-0000-0000-0000-000000000902
    ▿ VideoScan.CatalogAuditFinding
      - check: "A/V pairs"
      - status: VideoScan.CatalogAuditStatus.warn
      - headline: "1 records are paired with a purged or missing record"
      - detail: "Right-click the record in the Catalog ▸ Unpair, or re-run Correlate."
      ▿ examples: 1 element
        - "/Volumes/A/p.mov"
      ▿ action: VideoScan.CatalogAuditAction.focusRecords
        ▿ focusRecords: (2 elements)
          ▿ ids: 1 element
            - 00000000-0000-0000-0000-000000000015
          - label: "Audit: dangling A/V pairs"
      ▿ fix: Optional(VideoScan.CatalogAuditFix.unpair(ids: [00000000-0000-0000-0000-000000000015]))
        ▿ some: VideoScan.CatalogAuditFix.unpair
          ▿ unpair: (1 element)
            ▿ ids: 1 element
              - 00000000-0000-0000-0000-000000000015
    ▿ VideoScan.CatalogAuditFinding
      - check: "Purged records"
      - status: VideoScan.CatalogAuditStatus.warn
      - headline: "1 purged records still say \"Cataloged\""
      - detail: "Harmless for display (pfActiveRecords hides them) but the stage should be Trashed/Deleted."
      ▿ examples: 1 element
        - "/Volumes/A/q.mov"
      - action: VideoScan.CatalogAuditAction.none
      ▿ fix: Optional(VideoScan.CatalogAuditFix.setPurgedStages(ids: [00000000-0000-0000-0000-000000000016]))
        ▿ some: VideoScan.CatalogAuditFix.setPurgedStages
          ▿ setPurgedStages: (1 element)
            ▿ ids: 1 element
              - 00000000-0000-0000-0000-000000000016
    ▿ VideoScan.CatalogAuditFinding
      - check: "Master Archive index"
      - status: VideoScan.CatalogAuditStatus.fail
      - headline: "Index says 0 promoted copies, records say 1"
      - detail: "The archive promotion index is stale — relaunch rebuilds it; if it persists, file it."
      - examples: 0 elements
      - action: VideoScan.CatalogAuditAction.none
      - fix: nil
    ▿ VideoScan.CatalogAuditFinding
      - check: "Per-drive cache"
      - status: VideoScan.CatalogAuditStatus.warn
      - headline: "1 drive where the cached count differs from a recount"
      - detail: "The sidebar badges come from this cache; it rebuilds ~300 ms after any change, so a transient mismatch is normal."
      ▿ examples: 1 element
        - "/Volumes/A: cache 99, recount 6"
      - action: VideoScan.CatalogAuditAction.none
      - fix: nil
  - totalRecords: 9
  - activeRecords: 7
  - activeBytes: 6000
  ▿ startedAt: 1970-01-12 13:46:40 +0000
    - timeIntervalSinceReferenceDate: -977307200.0
  - duration: 0.0

"""#
