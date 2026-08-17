// ArchiveView+Categories.swift
// The Archive tab's sidebar/table derivations, kept OUT of SwiftUI so
// they are headless-testable (ArchiveCategoryTests) and so no O(records)
// work rides on `body` (feature-test checklist: "NO O(records) work in
// view bodies").
//
// Rick 2026-08-17: the tab used to show a LEGACY pipeline (All Keepers /
// Has Family / Master Set / Backed Up / Ready / Fully Archived, H M B R A
// pills, "737 keepers · 731 backed up") that predates the Master Archive.
// Those numbers were `lifecycleStage == .archived` stamps left by the
// 2026-05-31 Reconcile — provenance, not archive progress. The REAL
// archive is the set of promoted copies (`derivationKind ==
// archivePromotion` + `archiveFixity`). Everything here reads THAT.
//
// The legacy stamps are NOT touched — File Journey still shows them.

import Foundation
import SwiftUI

// MARK: - Sidebar categories

/// The two (three) honest buckets: every active asset is either archived
/// (a source with a promoted copy, or an orphan copy standing in for a
/// vanished source) or not. "Needs a date" is the slice of Not Yet
/// Archived the promote flow will file under Undated/.
enum ArchiveCategory: String, CaseIterable {
    case archived       = "archived"
    case notYetArchived = "notYetArchived"
    case needsDate      = "needsDate"

    var label: String {
        switch self {
        case .archived:       return "Archived"
        case .notYetArchived: return "Not Yet Archived"
        case .needsDate:      return "Needs a Date"
        }
    }

    var icon: String {
        switch self {
        case .archived:       return "checkmark.seal.fill"
        case .notYetArchived: return "tray.fill"
        case .needsDate:      return "calendar.badge.exclamationmark"
        }
    }

    var color: Color {
        switch self {
        case .archived:       return .green
        case .notYetArchived: return .primary
        case .needsDate:      return .orange
        }
    }
}

// MARK: - Per-row archive status

/// What the table's Status cell says about ONE row. Computed per visible
/// row from O(1) index lookups — never scans records.
enum ArchiveRowStatus: Equatable {
    /// Source with a promoted copy whose fixity was recorded (byte-verified).
    case verified(relPath: String)
    /// Source with a promoted copy that has NO fixity record (cataloged by
    /// rescan, not by Promote) — should not happen; shown, not hidden.
    case unverified(relPath: String)
    /// A promoted copy whose source record is gone from the catalog.
    case orphanCopy(relPath: String)
    /// Everything else — the row is an active asset with no master copy.
    case notArchived

    var label: String {
        switch self {
        case .verified:    return "verified"
        case .unverified:  return "unverified"
        case .orphanCopy:  return "orphan copy (source gone)"
        case .notArchived: return "not archived"
        }
    }

    /// The archive-relative path for the "Archived To" column, or nil.
    var relPath: String? {
        switch self {
        case .verified(let p), .unverified(let p), .orphanCopy(let p): return p
        case .notArchived: return nil
        }
    }
}

// MARK: - Category snapshot (memoized per RecordsVersion)

/// One pass over the active records → the three category lists, the
/// footer numbers and the per-volume file counts. Built ONCE per
/// `RecordsVersion` (count + volumeAggregatesRevision — the CatalogHelpers
/// memo discipline) and held in a `RenderMemo` inside the view.
///
/// Memory: three arrays of record REFERENCES over the active subset plus a
/// tiny [path: Int] — 8 bytes per active record per list, worst case
/// ~2.4 MB at 100k records. No record data is copied.
struct ArchiveCategorySnapshot {
    /// ONE row per archived asset: the source that has a master copy, or
    /// an orphan copy whose source is gone. Never both (Rick 2026-08-16:
    /// "Master Set 5" vs "4 verified" was this double count).
    var archived: [VideoRecord] = []
    /// Active assets that are neither an archive copy nor promoted.
    var notYetArchived: [VideoRecord] = []
    /// `notYetArchived` whose resolved date precision is decade/unknown.
    var needsDate: [VideoRecord] = []
    /// Footer "M": every active asset (archive copies excluded — a copy is
    /// not a second asset).
    var activeAssetCount: Int = 0
    /// Sidebar VOLUMES row counts, keyed by CatalogScanTarget.searchPath.
    /// Counts ALL catalog records under the path (parity with the old
    /// per-row filter), one pass instead of one pass per row per render.
    var volumeFileCounts: [String: Int] = [:]

    func records(for category: ArchiveCategory) -> [VideoRecord] {
        switch category {
        case .archived:       return archived
        case .notYetArchived: return notYetArchived
        case .needsDate:      return needsDate
        }
    }

    func count(for category: ArchiveCategory) -> Int { records(for: category).count }

    /// Footer "N of M media files archived · X GB verified".
    func footerText(totals: ArchivePromotionIndex.Totals) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: totals.verifiedBytes, countStyle: .file)
        return "\(archived.count) of \(activeAssetCount) media files archived · \(bytes) verified"
    }

    /// Build from `active` (already `pfActiveRecords`-filtered) plus the
    /// FULL records array for the volume counts. All per-record model
    /// calls are O(1) after the promotion index's one rebuild per version.
    @MainActor
    static func compute(active: [VideoRecord],
                        allRecords: [VideoRecord],
                        model: VideoScanModel,
                        volumeSearchPaths: [String]) -> ArchiveCategorySnapshot {
        var snap = ArchiveCategorySnapshot()
        snap.archived.reserveCapacity(active.count / 8)
        snap.notYetArchived.reserveCapacity(active.count)
        for rec in active {
            if model.isArchiveCopy(rec) {
                // Orphan copy stands in for its vanished source; a copy
                // with a live source is represented BY that source.
                if model.promotionSource(of: rec) == nil {
                    snap.archived.append(rec)
                    snap.activeAssetCount += 1
                }
                continue
            }
            snap.activeAssetCount += 1
            if model.masterArchiveCopy(of: rec) != nil {
                snap.archived.append(rec)
            } else {
                snap.notYetArchived.append(rec)
                if needsDate(rec) { snap.needsDate.append(rec) }
            }
        }
        // Volume counts: O(records × targets); targets are a handful.
        var counts: [String: Int] = [:]
        for path in volumeSearchPaths { counts[path] = 0 }
        for rec in allRecords {
            for path in volumeSearchPaths where rec.fullPath.hasPrefix(path) {
                counts[path, default: 0] += 1
            }
        }
        snap.volumeFileCounts = counts
        return snap
    }

    /// The SAME resolver the promote flow uses for placement, so this list
    /// is exactly "would land in Undated/".
    static func needsDate(_ rec: VideoRecord) -> Bool {
        let r = RecordDateResolver.resolve(userDate: rec.userDate,
                                           userDateConfidence: rec.userDateConfidence,
                                           embeddedCreationDate: rec.embeddedCreationDate,
                                           originMake: rec.originMake,
                                           originModel: rec.originModel,
                                           originEncoder: rec.originEncoder,
                                           inferredRecordDate: rec.inferredRecordDate,
                                           inferredDateConfidence: rec.inferredDateConfidence,
                                           filename: rec.filename.isEmpty ? nil : rec.filename)
        return r.precision >= .decade
    }

    /// Per-row status from O(1) lookups. `archiveRoot` = the master
    /// archive root path (relPaths are relative to it; absent root → the
    /// copy's full path is shown so nothing is hidden).
    @MainActor
    static func status(of rec: VideoRecord, model: VideoScanModel) -> ArchiveRowStatus {
        let root = model.masterArchiveRootPath
        if model.isArchiveCopy(rec) {
            if model.promotionSource(of: rec) == nil {
                return .orphanCopy(relPath: relativePath(rec.fullPath, root: root))
            }
            // A copy with a live source shows the same status its source does.
            return rec.archiveFixity != nil
                ? .verified(relPath: relativePath(rec.fullPath, root: root))
                : .unverified(relPath: relativePath(rec.fullPath, root: root))
        }
        guard let copy = model.masterArchiveCopy(of: rec) else { return .notArchived }
        let rel = relativePath(copy.fullPath, root: root)
        return copy.archiveFixity != nil ? .verified(relPath: rel) : .unverified(relPath: rel)
    }

    /// `path` relative to `root` when inside it, else the path itself.
    static func relativePath(_ path: String, root: String?) -> String {
        guard let root, ArchivePathResolver.isInside(path: path, root: root) else { return path }
        let rootComps = URL(fileURLWithPath: root).standardizedFileURL.pathComponents
        let pathComps = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        return pathComps.dropFirst(rootComps.count).joined(separator: "/")
    }
}

/// Memo key: records version + the volume list the counts were built
/// for. `// In C++ terms: the cache tag — equal tag ⇒ reuse.`
struct ArchiveCategoryKey: Equatable {
    let version: RecordsVersion
    let volumeSearchPaths: [String]
}

extension ArchiveCategorySnapshot {
    /// Get-or-compute through `memo`; exactly one compute per key change.
    @MainActor
    static func cached(in memo: RenderMemo<ArchiveCategoryKey, ArchiveCategorySnapshot>,
                       model: VideoScanModel,
                       volumeSearchPaths: [String]) -> ArchiveCategorySnapshot {
        let key = ArchiveCategoryKey(version: RecordsVersion(count: model.records.count,
                                                             revision: model.volumeAggregatesRevision),
                                     volumeSearchPaths: volumeSearchPaths)
        return memo.value(for: key) {
            compute(active: pfActiveRecords(model.records),
                    allRecords: model.records,
                    model: model,
                    volumeSearchPaths: volumeSearchPaths)
        }
    }
}

// MARK: - People cell

/// "Rick, Matt · Donna?" — confirmed people first (user's spelling), then
/// engine-detected names not already confirmed, then suspected names with
/// a trailing "?". Rick 2026-08-17: the column showed only detectedPeople,
/// so a row whose people were CONFIRMED read "—" ("people not following").
enum ArchivePeopleCell {
    static func text(for rec: VideoRecord) -> String {
        var seen: Set<String> = []
        var strong: [String] = []
        for name in rec.confirmedByUserPeople.map(\.name) + rec.detectedPeople {
            let key = name.lowercased()
            if !key.isEmpty, seen.insert(key).inserted { strong.append(name) }
        }
        var suspected: [String] = []
        for name in rec.suspectedPeople {
            let key = name.lowercased()
            if !key.isEmpty, seen.insert(key).inserted { suspected.append(name + "?") }
        }
        if strong.isEmpty && suspected.isEmpty { return "—" }
        if strong.isEmpty { return suspected.joined(separator: ", ") }
        if suspected.isEmpty { return strong.joined(separator: ", ") }
        return strong.joined(separator: ", ") + " · " + suspected.joined(separator: ", ")
    }
}
