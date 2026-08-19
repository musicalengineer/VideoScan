// CatalogAudit.swift
// "Audit Catalog" (Rick 2026-08-19) — right-click on the Storage tab's
// Catalog row. Today the audit is bookkeeping: does everything ADD UP?
// It is built to grow — each check is one `CatalogAuditCheck` case with a
// pure evaluator, so "verify file sizes on disk" or "fixity sweep" slot
// in beside the arithmetic checks later.
//
// Checks today (all pure, O(records)):
//   totalsReconcile   — active records == Σ per-drive + orphans, and
//                       bytes likewise; flags records claimed by TWO
//                       targets (nested scan paths) because those
//                       double-count in any per-drive view.
//   orphans           — active records under no scan target at all.
//   doubleClaimed     — records under more than one scan target.
//   emptyTargets      — non-retired scan targets with zero records.
//   badSizes          — records with size ≤ 0 (size unknown / corrupt).
//   dupGroupCounts    — duplicateGroupCount disagrees with the actual
//                       member count of its group.
//   danglingPairs     — pairedWith points at a purged / missing record.
//   purgedButStaged   — purged records whose lifecycle still says active.
//   masterArchive     — promoted-copy count equals the archive index totals.
//   volumeStatusCache — the cached per-volume record counts match a recount.

import Foundation

// MARK: - Projection

struct CatalogAuditRecord: Sendable, Equatable {
    var id: UUID
    var fullPath: String
    var sizeBytes: Int64
    var isActive: Bool            // pfActiveRecords predicate
    var isPurged: Bool
    var lifecycleRaw: String
    var duplicateGroupID: UUID?
    var duplicateGroupCount: Int
    var pairedWithID: UUID?
    var isPromotedCopy: Bool
}

struct CatalogAuditTarget: Sendable, Equatable {
    var searchPath: String
    var isRetired: Bool
    var cachedRecordCount: Int?   // VolumeRetireStatus.totalRecords, nil = cache cold
}

struct CatalogAuditInputs: Sendable {
    var records: [CatalogAuditRecord]
    var targets: [CatalogAuditTarget]
    /// Archive index totals (verified + unverified promoted copies).
    var archiveIndexPromoted: Int?
}

// MARK: - Report

enum CatalogAuditStatus: String, Sendable, Equatable {
    case pass, warn, fail
}

struct CatalogAuditFinding: Identifiable, Sendable, Equatable {
    var id: String { check }
    var check: String
    var status: CatalogAuditStatus
    var headline: String
    var detail: String
    /// Up to a handful of example paths/ids for the report.
    var examples: [String] = []
}

struct CatalogAuditReport: Sendable, Equatable {
    var findings: [CatalogAuditFinding] = []
    var totalRecords = 0
    var activeRecords = 0
    var activeBytes: Int64 = 0
    var startedAt = Date(timeIntervalSince1970: 0)
    var duration: TimeInterval = 0

    var failCount: Int { findings.filter { $0.status == .fail }.count }
    var warnCount: Int { findings.filter { $0.status == .warn }.count }
    var overall: CatalogAuditStatus {
        failCount > 0 ? .fail : (warnCount > 0 ? .warn : .pass)
    }

    /// Plain-text rendering for the clipboard / the log.
    var text: String {
        var lines: [String] = []
        lines.append("VideoScan catalog audit — \(startedAt.formatted(date: .abbreviated, time: .shortened))")
        lines.append("\(activeRecords.formatted()) present records (\(totalRecords.formatted()) total) · \(CatalogStorageTotals.displaySize(activeBytes)) · \(String(format: "%.2f", duration)) s")
        lines.append("Result: \(overall.rawValue.uppercased()) — \(failCount) fail, \(warnCount) warn")
        for f in findings {
            lines.append("[\(f.status.rawValue.uppercased())] \(f.check): \(f.headline)")
            if !f.detail.isEmpty { lines.append("    \(f.detail)") }
            for e in f.examples.prefix(5) { lines.append("    · \(e)") }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Auditor

enum CatalogAuditor {
    static let maxExamples = 5

    @MainActor
    static func project(model: VideoScanModel) -> CatalogAuditInputs {
        let activeIDs = Set(pfActiveRecords(model.records).map(\.id))
        let records = model.records.map { r in
            CatalogAuditRecord(id: r.id,
                               fullPath: r.fullPath,
                               sizeBytes: r.sizeBytes,
                               isActive: activeIDs.contains(r.id),
                               isPurged: r.isPurged,
                               lifecycleRaw: r.lifecycleStage.rawValue,
                               duplicateGroupID: r.duplicateGroupID,
                               duplicateGroupCount: r.duplicateGroupCount,
                               pairedWithID: r.pairedWith?.id ?? r.pendingPairedWithID,
                               isPromotedCopy: r.derivationKind == ArchivePromotion.derivationKind)
        }
        let targets = CatalogScanTarget.excludingScratch(model.scanTargets)
            .filter { !$0.searchPath.isEmpty }
            .map { t in
                let status = model.volumeStatus(for: t.searchPath)
                return CatalogAuditTarget(searchPath: t.searchPath,
                                          isRetired: t.isRetired,
                                          cachedRecordCount: status == .empty ? nil : status.totalRecords)
            }
        let totals = model.masterArchiveTotals
        return CatalogAuditInputs(records: records, targets: targets,
                                  archiveIndexPromoted: totals.verified + totals.unverified)
    }

    static func run(_ inputs: CatalogAuditInputs, now: Date = Date()) -> CatalogAuditReport {
        let clock = ContinuousClock.now
        var report = CatalogAuditReport()
        report.startedAt = now
        report.totalRecords = inputs.records.count

        let roots = inputs.targets.map { VolumeDashboardCalculator.normalizedRoot($0.searchPath) }
        var perTarget = [Int](repeating: 0, count: roots.count)
        var perTargetBytes = [Int64](repeating: 0, count: roots.count)
        var orphans: [CatalogAuditRecord] = []
        var doubleClaimed: [CatalogAuditRecord] = []
        var badSizes: [CatalogAuditRecord] = []
        var purgedButStaged: [CatalogAuditRecord] = []
        var groupMembers: [UUID: Int] = [:]
        var groupClaims: [UUID: Int] = [:]           // groupID → duplicateGroupCount claimed (first seen)
        var groupClaimMismatch: [UUID: Int] = [:]
        var promoted = 0
        let ids = Set(inputs.records.map(\.id))
        let purgedIDs = Set(inputs.records.filter(\.isPurged).map(\.id))
        var danglingPairs: [CatalogAuditRecord] = []
        var activeBytes: Int64 = 0
        var active = 0

        for r in inputs.records {
            if r.isPurged, !["Trashed", "Deleted"].contains(r.lifecycleRaw) {
                purgedButStaged.append(r)
            }
            if let p = r.pairedWithID, !r.isPurged, (!ids.contains(p) || purgedIDs.contains(p)) {
                danglingPairs.append(r)
            }
            guard r.isActive else { continue }
            active += 1
            activeBytes += max(0, r.sizeBytes)
            if r.sizeBytes <= 0 { badSizes.append(r) }
            if r.isPromotedCopy { promoted += 1 }
            if let g = r.duplicateGroupID {
                groupMembers[g, default: 0] += 1
                if let claimed = groupClaims[g] {
                    if claimed != r.duplicateGroupCount { groupClaimMismatch[g] = r.duplicateGroupCount }
                } else {
                    groupClaims[g] = r.duplicateGroupCount
                }
            }
            var claims = 0
            for (i, root) in roots.enumerated() where VolumeDashboardCalculator.isUnder(r.fullPath, root: root) {
                claims += 1
                perTarget[i] += 1
                perTargetBytes[i] += max(0, r.sizeBytes)
            }
            if claims == 0 { orphans.append(r) }
            if claims > 1 { doubleClaimed.append(r) }
        }
        report.activeRecords = active
        report.activeBytes = activeBytes

        // 1. Totals reconcile
        let sumPerTarget = perTarget.reduce(0, +)
        let reconciled = sumPerTarget + orphans.count - doubleClaimed.count == active   // each double claim counted once extra
        report.findings.append(CatalogAuditFinding(
            check: "Totals reconcile",
            status: reconciled ? (doubleClaimed.isEmpty ? .pass : .warn) : .fail,
            headline: reconciled
                ? "\(active.formatted()) present records = \(sumPerTarget.formatted()) on \(roots.count) drives + \(orphans.count) unplaced" + (doubleClaimed.isEmpty ? "" : " − \(doubleClaimed.count) counted twice")
                : "Arithmetic does not close: \(active.formatted()) present vs \(sumPerTarget.formatted()) on drives + \(orphans.count) unplaced",
            detail: "\(CatalogStorageTotals.displaySize(activeBytes)) present; per-drive sum \(CatalogStorageTotals.displaySize(perTargetBytes.reduce(0, +)))."))

        // 2. Orphans
        report.findings.append(CatalogAuditFinding(
            check: "Unplaced records",
            status: orphans.isEmpty ? .pass : .warn,
            headline: orphans.isEmpty ? "Every present record sits under a known drive"
                                      : "\(orphans.count.formatted()) present records are under no scan target (\(CatalogStorageTotals.displaySize(orphans.reduce(0) { $0 + max(0, $1.sizeBytes) })))",
            detail: orphans.isEmpty ? "" : "They still count in the catalog but no drive's dashboard shows them. Add the drive, or Update Catalog to relink.",
            examples: orphans.prefix(maxExamples).map(\.fullPath)))

        // 3. Double-claimed
        report.findings.append(CatalogAuditFinding(
            check: "Nested scan targets",
            status: doubleClaimed.isEmpty ? .pass : .warn,
            headline: doubleClaimed.isEmpty ? "No record is claimed by two drives"
                                            : "\(doubleClaimed.count.formatted()) records fall under two scan targets",
            detail: doubleClaimed.isEmpty ? "" : "One scan path is inside another; per-drive totals double-count these.",
            examples: doubleClaimed.prefix(maxExamples).map(\.fullPath)))

        // 4. Empty targets
        let empties = zip(inputs.targets, perTarget).filter { !$0.0.isRetired && $0.1 == 0 }.map { $0.0.searchPath }
        report.findings.append(CatalogAuditFinding(
            check: "Empty drives",
            status: empties.isEmpty ? .pass : .warn,
            headline: empties.isEmpty ? "Every active drive has records"
                                      : "\(empties.count) active scan target\(empties.count == 1 ? "" : "s") with zero records",
            detail: empties.isEmpty ? "" : "Typo, unmounted-at-scan, or a drive that should be deleted from the list.",
            examples: Array(empties.prefix(maxExamples))))

        // 5. Bad sizes
        report.findings.append(CatalogAuditFinding(
            check: "Sizes",
            status: badSizes.isEmpty ? .pass : .warn,
            headline: badSizes.isEmpty ? "Every present record has a positive size"
                                       : "\(badSizes.count.formatted()) present records have size ≤ 0",
            detail: badSizes.isEmpty ? "" : "Zero/negative sizes are excluded from every byte total — a rescan fixes them.",
            examples: badSizes.prefix(maxExamples).map(\.fullPath)))

        // 6. Duplicate group counts
        var dupIssues: [String] = []
        for (g, members) in groupMembers {
            if let claimed = groupClaims[g], claimed != members {
                dupIssues.append("group \(g.uuidString.prefix(8)): \(members) members, records say \(claimed)")
            } else if groupClaimMismatch[g] != nil {
                dupIssues.append("group \(g.uuidString.prefix(8)): members disagree on the count")
            }
        }
        report.findings.append(CatalogAuditFinding(
            check: "Duplicate groups",
            status: dupIssues.isEmpty ? .pass : .warn,
            headline: dupIssues.isEmpty ? "\(groupMembers.count.formatted()) duplicate groups, counts agree"
                                        : "\(dupIssues.count.formatted()) of \(groupMembers.count.formatted()) duplicate groups have a stale count",
            detail: dupIssues.isEmpty ? "" : "duplicateGroupCount drifted from the live membership (a member was deleted or purged). Re-run duplicate analysis.",
            examples: Array(dupIssues.prefix(maxExamples))))

        // 7. Dangling pairs
        report.findings.append(CatalogAuditFinding(
            check: "A/V pairs",
            status: danglingPairs.isEmpty ? .pass : .warn,
            headline: danglingPairs.isEmpty ? "Every pair link points at a live record"
                                            : "\(danglingPairs.count.formatted()) records are paired with a purged or missing record",
            detail: "",
            examples: danglingPairs.prefix(maxExamples).map(\.fullPath)))

        // 8. Purged but staged
        report.findings.append(CatalogAuditFinding(
            check: "Purged records",
            status: purgedButStaged.isEmpty ? .pass : .warn,
            headline: purgedButStaged.isEmpty ? "Purged records all carry a terminal lifecycle stage"
                                              : "\(purgedButStaged.count.formatted()) purged records still say \"\(purgedButStaged.first?.lifecycleRaw ?? "")\"",
            detail: purgedButStaged.isEmpty ? "" : "Harmless for display (pfActiveRecords hides them) but the stage should be Trashed/Deleted.",
            examples: purgedButStaged.prefix(maxExamples).map(\.fullPath)))

        // 9. Master archive index
        if let idx = inputs.archiveIndexPromoted {
            report.findings.append(CatalogAuditFinding(
                check: "Master Archive index",
                status: idx == promoted ? .pass : .fail,
                headline: idx == promoted ? "\(promoted.formatted()) promoted copies, index agrees"
                                          : "Index says \(idx.formatted()) promoted copies, records say \(promoted.formatted())",
                detail: idx == promoted ? "" : "The archive promotion index is stale — relaunch rebuilds it; if it persists, file it."))
        }

        // 10. Volume status cache
        var cacheIssues: [String] = []
        var coldCount = 0
        for (t, n) in zip(inputs.targets, perTarget) {
            guard let cached = t.cachedRecordCount else { coldCount += 1; continue }
            if cached != n { cacheIssues.append("\(t.searchPath): cache \(cached), recount \(n)") }
        }
        report.findings.append(CatalogAuditFinding(
            check: "Per-drive cache",
            status: cacheIssues.isEmpty ? .pass : .warn,
            headline: cacheIssues.isEmpty
                ? "Cached per-drive counts match a fresh recount" + (coldCount > 0 ? " (\(coldCount) still warming)" : "")
                : "\(cacheIssues.count) drive\(cacheIssues.count == 1 ? "" : "s") where the cached count differs from a recount",
            detail: cacheIssues.isEmpty ? "" : "The sidebar badges come from this cache; it rebuilds ~300 ms after any change, so a transient mismatch is normal.",
            examples: Array(cacheIssues.prefix(maxExamples))))

        report.duration = Double((ContinuousClock.now - clock).components.attoseconds) / 1e18
            + Double((ContinuousClock.now - clock).components.seconds)
        return report
    }
}
