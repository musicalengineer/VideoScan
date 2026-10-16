// VideoScanModel+CatalogAudit.swift
// The model half of "Audit Catalog…" tier 0: the ONE place the audit
// touches a catalog row (docs/design/catalog_status_freshness_2026_10_16.md
// §6). CatalogAuditSensorTests pins that `stampRemoval` / `clearRemoval`
// appear in no other audit source.
//
// Compare-and-set (invariant 4): a stat's answer is applied only to the row
// it was asked about — same id, same path, and the SAME removal marker the
// row carried when planned. A row rescanned, edited, restored or marked by
// another door while the stats ran is "changed meanwhile" and left alone.
//
// What may change a row here, and nothing else:
//   gone (live row, not archived)  → stampRemoval(.missing, reason .missingAtAudit)
//   came back (a Missing row)       → clearRemoval (it validates the file is back first)
// An archived copy's gone file is reported, never marked (Verify Archive
// owns the archive). A changed size is reported, never marked (§6: that
// is a decision). Every other answer writes nothing.
//
// Undo (invariant 6): each mark carries a RemovalUndo memento taken before
// the write; a save that is not acknowledged puts the row back EXACTLY —
// and only if the row still carries the very marker the audit wrote.

import Foundation
import VideoScanCore
import os

private let catalogAuditLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "auditCatalog")

/// One mark the audit wrote, with everything needed to take it back.
/// Main-actor only (it holds the record through its memento).
struct CatalogAuditMark {
    let id: UUID
    let path: String
    let before: RemovalUndo
    /// The marker the row carries after the write (nil = restored to live).
    let wrote: RemovalMarker?
}

/// What applying one stat did. Pure value; the job tallies it.
struct CatalogAuditApply: Equatable {
    let result: CatalogAuditResult
    let detail: String
}

extension VideoScanModel {

    /// The one sink: console + catalog.log, videoscan.log, unified log.
    func catalogAuditNote(_ line: String) {
        log("Audit catalog: " + line)
        appLog.write("[audit-catalog] " + line)
        catalogAuditLog.notice("\(line, privacy: .public)")
    }

    func catalogAuditPlan() -> CatalogAuditPlan {
        CatalogAuditPlanner.plan(records: records)
    }

    /// Apply one stat to the row it was asked about. Returns what happened
    /// and, when a row changed, the mark to undo if the save is not
    /// acknowledged. Does not save: the job batches saves.
    func applyCatalogAudit(_ stat: CatalogAuditStat, to item: CatalogAuditItem,
                           now: Date = Date()) -> (apply: CatalogAuditApply, mark: CatalogAuditMark?) {
        guard let rec = record(forID: item.id), rec.fullPath == item.path, rec.removal == item.plannedMarker else {
            return (CatalogAuditApply(result: .recordChanged,
                                      detail: "moved, rescanned, restored or marked by another door while the audit ran — left alone; the next run asks again"), nil)
        }
        switch stat {
        case .unreadable(let e):
            return (CatalogAuditApply(result: .couldNotCheck, detail: "stat failed: \(Self.errnoWords(e)) — not marked"), nil)
        case .notAFile:
            return (CatalogAuditApply(result: .couldNotCheck, detail: "not a regular file any more (a folder or device is at the path) — not marked; a person decides"), nil)
        case .gone:
            return applyGone(rec, item: item, now: now)
        case .file(let size):
            return applyPresent(rec, item: item, sizeOnDisk: size)
        }
    }

    /// The file is not at its path (and the job proved the drive is still
    /// mounted before calling): a live row is marked Missing through the
    /// one engine; a Missing row is simply still missing; an archived
    /// copy is reported.
    private func applyGone(_ rec: VideoRecord, item: CatalogAuditItem, now: Date) -> (apply: CatalogAuditApply, mark: CatalogAuditMark?) {
        if item.wasMissing {
            return (CatalogAuditApply(result: .stillMissing, detail: "already marked Missing (\(item.plannedMarker?.reason.rawValue ?? "")) — still not at its path"), nil)
        }
        if item.isArchived {
            return (CatalogAuditApply(result: .goneArchived, detail: "an archive copy is not at its path — not marked here; run Verify Archive"), nil)
        }
        let before = RemovalUndo(rec)
        let marker = RemovalMarker.missing(noticedAt: now, lastSeen: rec.contentHashAt, reason: .missingAtAudit)
        Self.stampRemoval(rec, marker)
        return (CatalogAuditApply(result: .gone, detail: "not at its path (the drive is connected) — marked Missing"),
                CatalogAuditMark(id: item.id, path: item.path, before: before, wrote: marker))
    }

    /// The file is there: a Missing row goes live again (the engine checks
    /// the file itself first); a live row is present, or "changed" when the
    /// size differs from the catalog's (a catalog size of 0 is unknown, so
    /// nothing is compared).
    private func applyPresent(_ rec: VideoRecord, item: CatalogAuditItem, sizeOnDisk: Int64) -> (apply: CatalogAuditApply, mark: CatalogAuditMark?) {
        if item.wasMissing {
            let before = RemovalUndo(rec)
            if let refusal = clearRemoval(rec) {
                return (CatalogAuditApply(result: .couldNotCheck, detail: "the file is back but the row could not be restored: \(refusal)"), nil)
            }
            let sizeNote = sizeOnDisk == item.sizeBytes || item.sizeBytes == 0 ? "" : " (now \(MediaBytes.display(sizeOnDisk)), the catalog said \(MediaBytes.display(item.sizeBytes)))"
            return (CatalogAuditApply(result: .cameBack, detail: "the file is back at its path — live again" + sizeNote),
                    CatalogAuditMark(id: item.id, path: item.path, before: before, wrote: nil))
        }
        if item.sizeBytes > 0, sizeOnDisk != item.sizeBytes {
            return (CatalogAuditApply(result: .changed,
                                      detail: "on disk \(MediaBytes.display(sizeOnDisk)), the catalog says \(MediaBytes.display(item.sizeBytes)) — replaced since it was cataloged? Not marked; Update Catalog rescans it"), nil)
        }
        return (CatalogAuditApply(result: .present, detail: "at its path, \(MediaBytes.display(sizeOnDisk))"), nil)
    }

    /// Take one mark back — only while the row still carries exactly what
    /// the audit wrote (compare-and-set). False when the row moved on.
    @discardableResult
    func revertCatalogAuditMark(_ mark: CatalogAuditMark) -> Bool {
        guard let rec = record(forID: mark.id), rec.fullPath == mark.path, rec.removal == mark.wrote else { return false }
        mark.before.reinstate()
        return true
    }

    /// "EACCES (permission denied)"
    nonisolated static func errnoWords(_ e: Int32) -> String {
        let name: String
        switch e {
        case EACCES: name = "EACCES"
        case EPERM: name = "EPERM"
        case EIO: name = "EIO"
        case ETIMEDOUT: name = "ETIMEDOUT"
        case ENXIO: name = "ENXIO"
        case ELOOP: name = "ELOOP"
        case ENAMETOOLONG: name = "ENAMETOOLONG"
        default: name = "errno \(e)"
        }
        return "\(name) (\(String(cString: strerror(e))))"
    }
}
