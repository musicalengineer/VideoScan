// VideoScanModel+CatalogAudit.swift
// The model half of "Audit Catalog…" tier 0: the ONE place the audit
// touches a catalog row (docs/design/catalog_status_freshness_2026_10_16.md
// §6). CatalogAuditSensorTests pins that `stampRemoval` / `clearRemoval`
// appear in no other audit source.
//
// Compare-and-set (invariant 4; codex 2026-10-16 F3): a stat's answer is
// applied only to the row it was asked about — same id and the SAME
// snapshot of the fields that matter (path, size, marker, lifecycle,
// archive stage and fixity, hash time, mtime) as when planned. A row
// rescanned, edited, restored or marked by another door while the stats
// ran is "changed meanwhile" and left alone. Whether a row is an archive
// copy is read from the LIVE record here, never from the plan.
//
// PROVE AT THE MARK (codex F1/F2): the chunk's ENOENT decides nothing. A
// gone answer is re-stat'ed SYNCHRONOUSLY here, just before the one
// `stampRemoval`, and marked only if the file is still ENOENT on the SAME
// filesystem the plan anchored (CatalogAuditProof). Present now → present;
// any other errno → could not check; another filesystem → could not check,
// "drive not connected". Nothing here awaits: the proof and the mark are
// one synchronous step on the main actor.
//
// What may change a row here, and nothing else:
//   gone (live row, not archived)  → stampRemoval(.missing, reason .missingAtAudit)
//   came back (a Missing row)       → clearRemoval (it validates the file is back first)
// An archived copy's gone file is reported, never marked (Verify Archive
// owns the archive). A changed size is reported, never marked (§6: that
// is a decision). Every other answer writes nothing.
//
// Undo (invariant 6; codex F4): each mark is a VALUE — what the row's
// marker was, what the audit wrote, and the legacy mirrors before and
// after. A save that is not acknowledged puts the marker back on the
// CURRENT instance of the row, only if it still carries exactly what the
// audit wrote; mirrors go back only where the write itself moved them; no
// other field is touched. No object memento (`RemovalUndo`) is held.

import Foundation
import VideoScanCore
import os

private let catalogAuditLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "auditCatalog")

/// One mark the audit wrote, as values — everything needed to take it back
/// by compare-and-set on whatever instance the row is by then.
struct CatalogAuditMark: Sendable, Equatable {
    let id: UUID
    let path: String
    /// The marker the row carried when planned (nil, or the planned `.missing`).
    let previous: RemovalMarker?
    /// The marker the row carries after the write (nil = restored to live).
    let wrote: RemovalMarker?
    let mirrorsBefore: RemovalMirrors
    let mirrorsAfter: RemovalMirrors
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
        guard let rec = record(forID: item.id), CatalogAuditRowSnapshot.of(rec) == item.planned else {
            return (CatalogAuditApply(result: .recordChanged,
                                      detail: "moved, rescanned, restored, edited or marked by another door while the audit ran — left alone; the next run asks again"), nil)
        }
        switch stat {
        case .unreadable, .notAFile:
            return (Self.couldNotCheck(stat), nil)
        case .gone:
            return applyGone(rec, item: item, now: now)
        case .file(let size):
            return applyPresent(rec, item: item, sizeOnDisk: size)
        }
    }

    /// The chunk's stat said ENOENT. That was the first pass; the mark is
    /// decided here by the second look, at this moment, on the filesystem
    /// the file was expected on.
    private func applyGone(_ rec: VideoRecord, item: CatalogAuditItem, now: Date) -> (apply: CatalogAuditApply, mark: CatalogAuditMark?) {
        switch CatalogAuditProof.atTheMark(item) {
        case .notGone(.file(let size)):
            return applyPresent(rec, item: item, sizeOnDisk: size)
        case .notGone(let other):
            return (Self.couldNotCheck(other, atTheMark: true), nil)
        case .driveNotConnected(let expected, let found):
            let words = "expected \(expected?.words ?? "a filesystem that could not be identified"); found \(found?.words ?? "none")"
            return (CatalogAuditApply(result: .couldNotCheck,
                                      detail: "not at its path, but the drive it was expected on is not connected (\(words)) — not marked"), nil)
        case .gone:
            return markGone(rec, item: item, now: now)
        }
    }

    /// Proven gone: a live row is marked Missing through the one engine; a
    /// Missing row is simply still missing; an archived copy (read from the
    /// live record) is reported.
    private func markGone(_ rec: VideoRecord, item: CatalogAuditItem, now: Date) -> (apply: CatalogAuditApply, mark: CatalogAuditMark?) {
        if item.wasMissing {
            return (CatalogAuditApply(result: .stillMissing, detail: "already marked Missing (\(item.plannedMarker?.reason.rawValue ?? "")) — still not at its path"), nil)
        }
        if CatalogAuditPlanner.isArchived(rec) {
            return (CatalogAuditApply(result: .goneArchived, detail: "an archive copy is not at its path — not marked here; run Verify Archive"), nil)
        }
        let before = RemovalMirrors.of(rec)
        let marker = RemovalMarker.missing(noticedAt: now, lastSeen: rec.contentHashAt, reason: .missingAtAudit)
        Self.stampRemoval(rec, marker)
        return (CatalogAuditApply(result: .gone, detail: "not at its path, on its connected drive, at the moment of marking — marked Missing"),
                CatalogAuditMark(id: item.id, path: item.path, previous: item.plannedMarker, wrote: marker,
                                 mirrorsBefore: before, mirrorsAfter: .of(rec)))
    }

    /// The file is there: a Missing row goes live again (the engine checks
    /// the file itself first); a live row is present, or "changed" when the
    /// size differs from the catalog's (a catalog size of 0 is unknown, so
    /// nothing is compared).
    private func applyPresent(_ rec: VideoRecord, item: CatalogAuditItem, sizeOnDisk: Int64) -> (apply: CatalogAuditApply, mark: CatalogAuditMark?) {
        if item.wasMissing {
            let before = RemovalMirrors.of(rec)
            if let refusal = clearRemoval(rec) {
                return (CatalogAuditApply(result: .couldNotCheck, detail: "the file is back but the row could not be restored: \(refusal)"), nil)
            }
            let sizeNote = sizeOnDisk == item.sizeBytes || item.sizeBytes == 0 ? "" : " (now \(MediaBytes.display(sizeOnDisk)), the catalog said \(MediaBytes.display(item.sizeBytes)))"
            return (CatalogAuditApply(result: .cameBack, detail: "the file is back at its path — live again" + sizeNote),
                    CatalogAuditMark(id: item.id, path: item.path, previous: item.plannedMarker, wrote: nil,
                                     mirrorsBefore: before, mirrorsAfter: .of(rec)))
        }
        if item.sizeBytes > 0, sizeOnDisk != item.sizeBytes {
            return (CatalogAuditApply(result: .changed,
                                      detail: "on disk \(MediaBytes.display(sizeOnDisk)), the catalog says \(MediaBytes.display(item.sizeBytes)) — replaced since it was cataloged? Not marked; Update Catalog rescans it"), nil)
        }
        return (CatalogAuditApply(result: .present, detail: "at its path, \(MediaBytes.display(sizeOnDisk))"), nil)
    }

    /// The words for a stat that is neither a file nor ENOENT. Never a mark.
    private static func couldNotCheck(_ stat: CatalogAuditStat, atTheMark: Bool = false) -> CatalogAuditApply {
        let when = atTheMark ? " at the moment of marking" : ""
        switch stat {
        case .unreadable(let e):
            return CatalogAuditApply(result: .couldNotCheck, detail: "stat failed\(when): \(errnoWords(e)) — not marked")
        case .notAFile:
            return CatalogAuditApply(result: .couldNotCheck, detail: "not a regular file any more\(when) (a folder or device is at the path) — not marked; a person decides")
        case .file, .gone:
            return CatalogAuditApply(result: .couldNotCheck, detail: "no answer\(when) — not marked")
        }
    }

    /// Take one mark back, by value, on the CURRENT instance of the row —
    /// only while it still carries exactly what the audit wrote. False when
    /// the row moved on (another door changed it; nothing of ours to undo),
    /// and the console says so.
    @discardableResult
    func revertCatalogAuditMark(_ mark: CatalogAuditMark) -> Bool {
        guard let rec = record(forID: mark.id), rec.fullPath == mark.path,
              Self.revertRemoval(rec, wrote: mark.wrote, previous: mark.previous,
                                 mirrorsBefore: mark.mirrorsBefore, mirrorsAfter: mark.mirrorsAfter) else {
            catalogAuditNote("undo: \(mark.path) was changed by another door since the audit marked it — left as it is now")
            return false
        }
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
