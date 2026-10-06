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

/// Where "Show me" takes you for a finding. `.none` → the detail text is
/// the advice ("go here, do this").
enum CatalogAuditAction: Sendable, Equatable {
    case none
    /// Open the Catalog tab filtered to these records (focus banner = label).
    case focusRecords(ids: [UUID], label: String)
    /// Select this scan target in the Storage sidebar.
    case selectVolume(searchPath: String)
}

/// A deterministic in-app repair the audit can offer ("Fix it for me",
/// Rick 2026-08-19). Applied by `CatalogAuditFixer` through the model —
/// never by a script against catalog.json, which would fight the
/// single-writer/OCC discipline. Judgment calls (unplaced records, which
/// nested target to keep) stay "Show me".
enum CatalogAuditFix: Sendable, Equatable {
    /// Purged records whose lifecycle still says active → Trashed.
    case setPurgedStages(ids: [UUID])
    /// Break pair links that point at purged/missing records.
    case unpair(ids: [UUID])
    /// Recount duplicate groups whose stored count drifted; singleton
    /// groups dissolve.
    case recountDuplicateGroups(groupIDs: [UUID])
    /// Delete zero-record, non-retired scan targets from the list.
    case deleteEmptyTargets(searchPaths: [String])

    /// Plan sentence shown before applying.
    var plan: String {
        switch self {
        case .setPurgedStages(let ids):
            return "Set the lifecycle stage to Trashed on \(ids.count.formatted()) purged record\(ids.count == 1 ? "" : "s"). Display is unchanged (they are already hidden)."
        case .unpair(let ids):
            return "Remove the A/V pair link from \(ids.count.formatted()) record\(ids.count == 1 ? "" : "s") whose partner is purged or missing. Re-run Correlate later to pair them afresh."
        case .recountDuplicateGroups(let g):
            return "Recount \(g.count.formatted()) duplicate group\(g.count == 1 ? "" : "s") from their live members; groups left with one member dissolve. Nothing is deleted."
        case .deleteEmptyTargets(let p):
            return "Delete \(p.count) empty scan target\(p.count == 1 ? "" : "s") from the Volumes list: \(p.joined(separator: ", ")). No catalog records are affected (there are none under them)."
        }
    }
    var buttonTitle: String {
        switch self {
        case .setPurgedStages:        return "Fix stages"
        case .unpair:                 return "Unpair them"
        case .recountDuplicateGroups: return "Recount groups"
        case .deleteEmptyTargets:     return "Delete from list"
        }
    }
}

struct CatalogAuditFinding: Identifiable, Sendable, Equatable {
    var id: String { check }
    var check: String
    var status: CatalogAuditStatus
    var headline: String
    var detail: String
    /// Up to a handful of example paths/ids for the report.
    var examples: [String] = []
    var action: CatalogAuditAction = .none
    var fix: CatalogAuditFix? = nil
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

// MARK: - Tally (the one pass over the records)

/// Everything the checks need, gathered in ONE pass over the records
/// (`CatalogAuditor.tally`); the checks read it and never walk the
/// records again, except the stale-group focus list.
struct CatalogAuditTally {
    var roots: [String]
    var perTarget: [Int]
    var perTargetBytes: [Int64]
    var orphans: [CatalogAuditRecord] = []
    var doubleClaimed: [CatalogAuditRecord] = []
    var badSizes: [CatalogAuditRecord] = []
    var purgedButStaged: [CatalogAuditRecord] = []
    var groupMembers: [UUID: Int] = [:]
    var groupClaims: [UUID: Int] = [:]           // groupID → duplicateGroupCount claimed (first seen)
    var groupClaimMismatch: [UUID: Int] = [:]
    var promoted = 0
    var danglingPairs: [CatalogAuditRecord] = []
    var activeBytes: Int64 = 0
    var active = 0

    init(roots: [String]) {
        self.roots = roots
        perTarget = [Int](repeating: 0, count: roots.count)
        perTargetBytes = [Int64](repeating: 0, count: roots.count)
    }

    /// The per-record work for an ACTIVE record (`mutating` ≈ a non-const
    /// C++ member function: it may change `self`).
    mutating func addActive(_ r: CatalogAuditRecord) {
        active += 1
        activeBytes += max(0, r.sizeBytes)
        if r.sizeBytes <= 0 { badSizes.append(r) }
        if r.isPromotedCopy { promoted += 1 }
        if let g = r.duplicateGroupID { addGroupMember(g, claimed: r.duplicateGroupCount) }
        var claims = 0
        for (i, root) in roots.enumerated() where VolumeDashboardCalculator.isUnder(r.fullPath, root: root) {
            claims += 1
            perTarget[i] += 1
            perTargetBytes[i] += max(0, r.sizeBytes)
        }
        if claims == 0 { orphans.append(r) }
        if claims > 1 { doubleClaimed.append(r) }
    }

    private mutating func addGroupMember(_ g: UUID, claimed count: Int) {
        groupMembers[g, default: 0] += 1
        if let claimed = groupClaims[g] {
            if claimed != count { groupClaimMismatch[g] = count }
        } else {
            groupClaims[g] = count
        }
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

    /// Runs every check in report order. The one pass over the records is
    /// `tally` (O(records); the 100k budget lives there); each `check…`
    /// reads the tally. A check that returns nil is left out of the report
    /// (Master Archive when there is no index).
    static func run(_ inputs: CatalogAuditInputs, now: Date = Date()) -> CatalogAuditReport {
        let clock = ContinuousClock.now
        var report = CatalogAuditReport()
        report.startedAt = now
        report.totalRecords = inputs.records.count

        let t = tally(inputs)
        report.activeRecords = t.active
        report.activeBytes = t.activeBytes

        // An array of function references ≈ a C++ table of function pointers.
        // The array order IS the report order (the sheet and tests key on it).
        let checks: [(CatalogAuditTally, CatalogAuditInputs) -> CatalogAuditFinding?] = [
            checkTotals, checkOrphans, checkNestedTargets, checkEmptyTargets, checkSizes,
            checkDuplicateGroups, checkPairs, checkPurgedStages, checkMasterArchive, checkVolumeCache,
        ]
        report.findings = checks.compactMap { $0(t, inputs) }

        report.duration = Double((ContinuousClock.now - clock).components.attoseconds) / 1e18
            + Double((ContinuousClock.now - clock).components.seconds)
        return report
    }

    static func tally(_ inputs: CatalogAuditInputs) -> CatalogAuditTally {
        var t = CatalogAuditTally(roots: inputs.targets.map { VolumeDashboardCalculator.normalizedRoot($0.searchPath) })
        let ids = Set(inputs.records.map(\.id))
        let purgedIDs = Set(inputs.records.filter(\.isPurged).map(\.id))

        for r in inputs.records {
            if r.isPurged, !["Trashed", "Deleted"].contains(r.lifecycleRaw) {
                t.purgedButStaged.append(r)
            }
            if let p = r.pairedWithID, !r.isPurged, (!ids.contains(p) || purgedIDs.contains(p)) {
                t.danglingPairs.append(r)
            }
            guard r.isActive else { continue }
            t.addActive(r)
        }
        return t
    }

    // MARK: Checks, in report order

    // 1. Totals reconcile
    static func checkTotals(_ t: CatalogAuditTally, _ inputs: CatalogAuditInputs) -> CatalogAuditFinding? {
        let sumPerTarget = t.perTarget.reduce(0, +)
        let reconciled = sumPerTarget + t.orphans.count - t.doubleClaimed.count == t.active   // each double claim counted once extra
        return CatalogAuditFinding(
            check: "Totals reconcile",
            status: reconciled ? (t.doubleClaimed.isEmpty ? .pass : .warn) : .fail,
            headline: reconciled
                ? "\(t.active.formatted()) present records = \(sumPerTarget.formatted()) on \(t.roots.count) drives + \(t.orphans.count) unplaced" + (t.doubleClaimed.isEmpty ? "" : " − \(t.doubleClaimed.count) counted twice")
                : "Arithmetic does not close: \(t.active.formatted()) present vs \(sumPerTarget.formatted()) on drives + \(t.orphans.count) unplaced",
            detail: "\(CatalogStorageTotals.displaySize(t.activeBytes)) present; per-drive sum \(CatalogStorageTotals.displaySize(t.perTargetBytes.reduce(0, +))).")
    }

    // 2. Orphans
    static func checkOrphans(_ t: CatalogAuditTally, _ inputs: CatalogAuditInputs) -> CatalogAuditFinding? {
        let orphans = t.orphans
        return CatalogAuditFinding(
            check: "Unplaced records",
            status: orphans.isEmpty ? .pass : .warn,
            headline: orphans.isEmpty ? "Every present record sits under a known drive"
                                      : "\(orphans.count.formatted()) present records are under no scan target (\(CatalogStorageTotals.displaySize(orphans.reduce(0) { $0 + max(0, $1.sizeBytes) })))",
            detail: orphans.isEmpty ? "" : "They still count in the catalog but no drive's dashboard shows them. Add the drive, or Update Catalog to relink.",
            examples: orphans.prefix(maxExamples).map(\.fullPath),
            action: orphans.isEmpty ? .none : .focusRecords(ids: orphans.map(\.id), label: "Audit: unplaced records"))
    }

    // 3. Double-claimed — point at the INNER target (the one whose root
    // sits under another target's root).
    static func checkNestedTargets(_ t: CatalogAuditTally, _ inputs: CatalogAuditInputs) -> CatalogAuditFinding? {
        let roots = t.roots
        let doubleClaimed = t.doubleClaimed
        let nestedTarget: String? = inputs.targets.first { target in
            let r = VolumeDashboardCalculator.normalizedRoot(target.searchPath)
            return roots.contains { other in other != r && VolumeDashboardCalculator.isUnder(r, root: other) }
        }?.searchPath
        return CatalogAuditFinding(
            check: "Nested scan targets",
            status: doubleClaimed.isEmpty ? .pass : .warn,
            headline: doubleClaimed.isEmpty ? "No record is claimed by two drives"
                                            : "\(doubleClaimed.count.formatted()) records fall under two scan targets",
            detail: doubleClaimed.isEmpty ? "" : "One scan path is inside another; per-drive totals double-count these. Delete the inner target from the list (right-click it) or keep it knowingly.",
            examples: doubleClaimed.prefix(maxExamples).map(\.fullPath),
            action: nestedTarget.map { .selectVolume(searchPath: $0) } ?? .none)
    }

    // 4. Empty targets
    static func checkEmptyTargets(_ t: CatalogAuditTally, _ inputs: CatalogAuditInputs) -> CatalogAuditFinding? {
        let empties = zip(inputs.targets, t.perTarget).filter { !$0.0.isRetired && $0.1 == 0 }.map { $0.0.searchPath }
        return CatalogAuditFinding(
            check: "Empty drives",
            status: empties.isEmpty ? .pass : .warn,
            headline: empties.isEmpty ? "Every active drive has records"
                                      : "\(empties.count) active scan target\(empties.count == 1 ? "" : "s") with zero records",
            detail: empties.isEmpty ? "" : "Typo, unmounted-at-scan, or a drive that should be deleted from the list (right-click ▸ Delete from list).",
            examples: Array(empties.prefix(maxExamples)),
            action: empties.first.map { .selectVolume(searchPath: $0) } ?? .none,
            fix: empties.isEmpty ? nil : .deleteEmptyTargets(searchPaths: empties))
    }

    // 5. Bad sizes
    static func checkSizes(_ t: CatalogAuditTally, _ inputs: CatalogAuditInputs) -> CatalogAuditFinding? {
        let badSizes = t.badSizes
        return CatalogAuditFinding(
            check: "Sizes",
            status: badSizes.isEmpty ? .pass : .warn,
            headline: badSizes.isEmpty ? "Every present record has a positive size"
                                       : "\(badSizes.count.formatted()) present records have size ≤ 0",
            detail: badSizes.isEmpty ? "" : "Zero/negative sizes are excluded from every byte total — Update Catalog on that drive fixes them.",
            examples: badSizes.prefix(maxExamples).map(\.fullPath),
            action: badSizes.isEmpty ? .none : .focusRecords(ids: badSizes.map(\.id), label: "Audit: size unknown"))
    }

    // 6. Duplicate group counts
    static func checkDuplicateGroups(_ t: CatalogAuditTally, _ inputs: CatalogAuditInputs) -> CatalogAuditFinding? {
        let groupMembers = t.groupMembers
        var dupIssues: [String] = []
        var staleGroups = Set<UUID>()
        for (g, members) in groupMembers {
            if let claimed = t.groupClaims[g], claimed != members {
                dupIssues.append("group \(g.uuidString.prefix(8)): \(members) members, records say \(claimed)")
                staleGroups.insert(g)
            } else if t.groupClaimMismatch[g] != nil {
                dupIssues.append("group \(g.uuidString.prefix(8)): members disagree on the count")
                staleGroups.insert(g)
            }
        }
        let staleGroupMembers = staleGroups.isEmpty ? [] : inputs.records
            .filter { $0.isActive && $0.duplicateGroupID.map(staleGroups.contains) == true }
            .map(\.id)
        return CatalogAuditFinding(
            check: "Duplicate groups",
            status: dupIssues.isEmpty ? .pass : .warn,
            headline: dupIssues.isEmpty ? "\(groupMembers.count.formatted()) duplicate groups, counts agree"
                                        : "\(dupIssues.count.formatted()) of \(groupMembers.count.formatted()) duplicate groups have a stale count",
            detail: dupIssues.isEmpty ? "" : "duplicateGroupCount drifted from the live membership (a member was deleted or purged). Catalog tab ▸ Analyze ▸ Duplicates re-scores them.",
            examples: Array(dupIssues.prefix(maxExamples)),
            action: staleGroupMembers.isEmpty ? .none : .focusRecords(ids: staleGroupMembers, label: "Audit: stale duplicate groups"),
            fix: staleGroups.isEmpty ? nil : .recountDuplicateGroups(groupIDs: Array(staleGroups)))
    }

    // 7. Dangling pairs
    static func checkPairs(_ t: CatalogAuditTally, _ inputs: CatalogAuditInputs) -> CatalogAuditFinding? {
        let danglingPairs = t.danglingPairs
        return CatalogAuditFinding(
            check: "A/V pairs",
            status: danglingPairs.isEmpty ? .pass : .warn,
            headline: danglingPairs.isEmpty ? "Every pair link points at a live record"
                                            : "\(danglingPairs.count.formatted()) records are paired with a purged or missing record",
            detail: danglingPairs.isEmpty ? "" : "Right-click the record in the Catalog ▸ Unpair, or re-run Correlate.",
            examples: danglingPairs.prefix(maxExamples).map(\.fullPath),
            action: danglingPairs.isEmpty ? .none : .focusRecords(ids: danglingPairs.map(\.id), label: "Audit: dangling A/V pairs"),
            fix: danglingPairs.isEmpty ? nil : .unpair(ids: danglingPairs.map(\.id)))
    }

    // 8. Purged but staged
    static func checkPurgedStages(_ t: CatalogAuditTally, _ inputs: CatalogAuditInputs) -> CatalogAuditFinding? {
        let purgedButStaged = t.purgedButStaged
        return CatalogAuditFinding(
            check: "Purged records",
            status: purgedButStaged.isEmpty ? .pass : .warn,
            headline: purgedButStaged.isEmpty ? "Purged records all carry a terminal lifecycle stage"
                                              : "\(purgedButStaged.count.formatted()) purged records still say \"\(purgedButStaged.first?.lifecycleRaw ?? "")\"",
            detail: purgedButStaged.isEmpty ? "" : "Harmless for display (pfActiveRecords hides them) but the stage should be Trashed/Deleted.",
            examples: purgedButStaged.prefix(maxExamples).map(\.fullPath),
            fix: purgedButStaged.isEmpty ? nil : .setPurgedStages(ids: purgedButStaged.map(\.id)))
    }

    // 9. Master archive index (skipped — nil — when there is no index)
    static func checkMasterArchive(_ t: CatalogAuditTally, _ inputs: CatalogAuditInputs) -> CatalogAuditFinding? {
        guard let idx = inputs.archiveIndexPromoted else { return nil }
        let promoted = t.promoted
        return CatalogAuditFinding(
            check: "Master Archive index",
            status: idx == promoted ? .pass : .fail,
            headline: idx == promoted ? "\(promoted.formatted()) promoted copies, index agrees"
                                      : "Index says \(idx.formatted()) promoted copies, records say \(promoted.formatted())",
            detail: idx == promoted ? "" : "The archive promotion index is stale — relaunch rebuilds it; if it persists, file it.")
    }

    // 10. Volume status cache
    static func checkVolumeCache(_ t: CatalogAuditTally, _ inputs: CatalogAuditInputs) -> CatalogAuditFinding? {
        var cacheIssues: [String] = []
        var coldCount = 0
        for (target, n) in zip(inputs.targets, t.perTarget) {
            guard let cached = target.cachedRecordCount else { coldCount += 1; continue }
            if cached != n { cacheIssues.append("\(target.searchPath): cache \(cached), recount \(n)") }
        }
        return CatalogAuditFinding(
            check: "Per-drive cache",
            status: cacheIssues.isEmpty ? .pass : .warn,
            headline: cacheIssues.isEmpty
                ? "Cached per-drive counts match a fresh recount" + (coldCount > 0 ? " (\(coldCount) still warming)" : "")
                : "\(cacheIssues.count) drive\(cacheIssues.count == 1 ? "" : "s") where the cached count differs from a recount",
            detail: cacheIssues.isEmpty ? "" : "The sidebar badges come from this cache; it rebuilds ~300 ms after any change, so a transient mismatch is normal.",
            examples: Array(cacheIssues.prefix(maxExamples)))
    }
}
