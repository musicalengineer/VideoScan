// VideoScanModel+CatalogAudit.swift
// The model half of "Audit Catalog…" tier 0: the ONE place the audit
// touches a catalog row (docs/design/catalog_status_freshness_2026_10_16.md
// §6). CatalogAuditSensorTests pins that `stampRemoval` / `clearRemoval`
// appear in no other audit source.
//
// Compare-and-set (invariant 4; codex 2026-10-16 F3, r2 F3): a stat's
// answer is applied only to the row it was asked about — same id and the
// SAME snapshot of the fields that matter (path, size, marker, lifecycle,
// archive stage and fixity, derivation, supersession, hash time, mtime,
// the where-seen stamp) as when planned. A row rescanned, edited,
// restored, marked or superseded by another door while the stats ran is
// "changed meanwhile" and left alone. Whether a row is an archive copy,
// and where its file was last seen, are read from the LIVE record here,
// never from the plan.
//
// PROVE AT THE MARK (codex F1/F2, r2 F2, r3 F1/F2): the chunk's ENOENT
// decides nothing. A gone answer is walked again SYNCHRONOUSLY here,
// through a directory handle, just before the one `stampRemoval`
// (CatalogAuditProof), under THE ONE RULE (D5): gone is proven only when
// the folder the file is not in is on the volume the file was LAST SEEN on
// — the handle's volume UUID equals the row's `auditSeenOn` stamp. Present
// now → present; any other errno → could not check; a link in the path,
// the folder changed under the audit, the drive's root not there → could
// not check (not provable); another volume → could not check, "drive not
// connected?"; no stamp → "never seen by an audit" (the Fix Links bucket).
// Nothing here awaits: the proof and the mark are one synchronous step on
// the main actor.
//
// What may change a row here, and nothing else:
//   gone (live row, not archived)  → stampRemoval(.missing, reason .missingAtAudit)
//   came back (a Missing row)       → clearRemoval (it validates the file is back first)
//   present / changed / came back   → the where-seen STAMP (`auditSeenOn`),
//                                     when the handle found the file
// An archived copy's gone file is reported, never marked (Verify Archive
// owns the archive). A changed size is reported, never marked (§6: that
// is a decision). Every other answer writes nothing.
//
// The stamp is NOT a mark: no undo bookkeeping (a save that is not
// acknowledged simply loses the stamps; the next run writes them again),
// no revision, no mirror. The job flushes stamps on the clock, at lane end
// and at run end — never per row.
//
// Undo (invariant 6; codex F4, r2 F4): each mark is a VALUE — what the
// row's marker was, what the audit wrote, the REVISION that write produced,
// and the legacy mirrors before and after. A save that is not acknowledged
// puts the marker back on the CURRENT instance of the row, only if it still
// carries exactly what the audit wrote AT THAT REVISION — an equal value
// written since by another door (nil → Trash → Put Back → Restore → nil)
// has a higher revision and is left alone; mirrors go back only where the
// write itself moved them; no other field is touched. No object memento
// (`RemovalUndo`) is held.

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
    /// `removalRevision` after the write — the audit OWNS the marker only
    /// while the row still sits at this revision (codex r2 F4).
    let revision: Int
    let mirrorsBefore: RemovalMirrors
    let mirrorsAfter: RemovalMirrors
}

/// What applying one stat did. Pure value; the job tallies it.
struct CatalogAuditApply: Equatable {
    let result: CatalogAuditResult
    let detail: String
    /// The where-seen stamp was written (a save is owed, on the clock).
    var stamped = false
}

extension VideoScanModel {

    /// The one sink: console + catalog.log, videoscan.log, unified log.
    func catalogAuditNote(_ line: String) {
        log("Audit catalog: " + line)
        appLog.write("[audit-catalog] " + line)
        catalogAuditLog.notice("\(line, privacy: .public)")
    }

    func catalogAuditPlan(laneRoot: @Sendable (String) -> String = CatalogAuditPlanner.productionLaneRoot) -> CatalogAuditPlan {
        CatalogAuditPlanner.plan(records: records, laneRoot: laneRoot)
    }

    /// Apply one stat to the row it was asked about. `seenOn` is where the
    /// first pass found the file (nil = it did not, or the volume has no
    /// UUID). Returns what happened and, when a marker changed, the mark to
    /// undo if the save is not acknowledged. Does not save: the job batches
    /// saves.
    func applyCatalogAudit(_ stat: CatalogAuditStat, seenOn: AuditSeenOn? = nil, to item: CatalogAuditItem,
                           now: Date = Date()) -> (apply: CatalogAuditApply, mark: CatalogAuditMark?) {
        guard let rec = record(forID: item.id), CatalogAuditRowSnapshot.of(rec) == item.planned else {
            return (CatalogAuditApply(result: .recordChanged,
                                      detail: "moved, rescanned, restored, edited, superseded or marked by another door while the audit ran — left alone; the next run asks again"), nil)
        }
        switch stat {
        case .unreadable, .notAFile:
            return (Self.couldNotCheck(stat), nil)
        case .gone:
            return applyGone(rec, item: item, now: now)
        case .file(let size):
            return applyPresent(rec, item: item, sizeOnDisk: size, seenOn: seenOn)
        }
    }

    /// The chunk's stat said ENOENT. That was the first pass; the mark is
    /// decided here by the second look, at this moment, through a handle,
    /// against where the LIVE record says the file was last seen.
    private func applyGone(_ rec: VideoRecord, item: CatalogAuditItem, now: Date) -> (apply: CatalogAuditApply, mark: CatalogAuditMark?) {
        switch CatalogAuditProof.atTheMark(item, lastSeenOn: rec.auditSeenOn, now: now) {
        case .notGone(.file(let size), let seenOn):
            return applyPresent(rec, item: item, sizeOnDisk: size, seenOn: seenOn)
        case .notGone(let other, _):
            return (Self.couldNotCheck(other, atTheMark: true), nil)
        case .notProvable(let why):
            return (CatalogAuditApply(result: .couldNotCheck, detail: "not at its path, but that is not proof here: \(why) — not marked"), nil)
        case .neverSeenByAnAudit:
            if item.wasMissing {
                return (CatalogAuditApply(result: .stillMissing, detail: "already marked Missing (\(item.plannedMarker?.reason.rawValue ?? "")) — still not at its path"), nil)
            }
            return (CatalogAuditApply(result: .neverSeenByAnAudit,
                                      detail: "not at its path, and no audit has seen it before — nothing says which drive to believe; not marked. Fix Links decides"), nil)
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
        return (CatalogAuditApply(result: .gone, detail: "not at its path, in a folder on the drive it was last seen on, at the moment of marking — marked Missing"),
                CatalogAuditMark(id: item.id, path: item.path, previous: item.plannedMarker, wrote: marker,
                                 revision: rec.removalRevision, mirrorsBefore: before, mirrorsAfter: .of(rec)))
    }

    /// The file is there: a Missing row goes live again (the engine checks
    /// the file itself first); a live row is present, or "changed" when the
    /// size differs from the catalog's (a catalog size of 0 is unknown, so
    /// nothing is compared). Where the handle found it is stamped on the
    /// row (D5) — the stamp is not a mark.
    private func applyPresent(_ rec: VideoRecord, item: CatalogAuditItem, sizeOnDisk: Int64,
                              seenOn: AuditSeenOn?) -> (apply: CatalogAuditApply, mark: CatalogAuditMark?) {
        if item.wasMissing {
            let before = RemovalMirrors.of(rec)
            if let refusal = clearRemoval(rec) {
                return (CatalogAuditApply(result: .couldNotCheck, detail: "the file is back but the row could not be restored: \(refusal)"), nil)
            }
            let sizeNote = sizeOnDisk == item.sizeBytes || item.sizeBytes == 0 ? "" : " (now \(MediaBytes.display(sizeOnDisk)), the catalog said \(MediaBytes.display(item.sizeBytes)))"
            return (stamped(rec, seenOn, CatalogAuditApply(result: .cameBack, detail: "the file is back at its path — live again" + sizeNote)),
                    CatalogAuditMark(id: item.id, path: item.path, previous: item.plannedMarker, wrote: nil,
                                     revision: rec.removalRevision, mirrorsBefore: before, mirrorsAfter: .of(rec)))
        }
        if item.sizeBytes > 0, sizeOnDisk != item.sizeBytes {
            return (stamped(rec, seenOn, CatalogAuditApply(result: .changed,
                                                           detail: "on disk \(MediaBytes.display(sizeOnDisk)), the catalog says \(MediaBytes.display(item.sizeBytes)) — replaced since it was cataloged? Not marked; Update Catalog rescans it")), nil)
        }
        return (stamped(rec, seenOn, CatalogAuditApply(result: .present, detail: "at its path, \(MediaBytes.display(sizeOnDisk))")), nil)
    }

    /// The where-seen stamp (D5): written only when the directory handle
    /// found the file on a volume with a UUID. The apply says so, so the
    /// job owes a save on the clock.
    private func stamped(_ rec: VideoRecord, _ seenOn: AuditSeenOn?, _ apply: CatalogAuditApply) -> CatalogAuditApply {
        guard let seenOn else { return apply }
        rec.auditSeenOn = seenOn
        var withStamp = apply
        withStamp.stamped = true
        return withStamp
    }

    /// The words for a stat that is neither a file nor ENOENT. Never a mark.
    private static func couldNotCheck(_ stat: CatalogAuditStat, atTheMark: Bool = false) -> CatalogAuditApply {
        let when = atTheMark ? " at the moment of marking" : ""
        switch stat {
        case .unreadable(let e):
            return CatalogAuditApply(result: .couldNotCheck, detail: "stat failed\(when): \(errnoWords(e)) — not marked")
        case .notAFile:
            return CatalogAuditApply(result: .couldNotCheck, detail: "not a regular file any more\(when) (a folder, device or link is at the path) — not marked; a person decides")
        case .file, .gone:
            return CatalogAuditApply(result: .couldNotCheck, detail: "no answer\(when) — not marked")
        }
    }

    /// Take one mark back, by value AND revision, on the CURRENT instance of
    /// the row — only while it still carries exactly what the audit wrote
    /// at the revision that write produced. False when the row moved on
    /// (another door changed it, even back to an equal value; nothing of
    /// ours to undo), and the console says so.
    @discardableResult
    func revertCatalogAuditMark(_ mark: CatalogAuditMark) -> Bool {
        guard let rec = record(forID: mark.id), rec.fullPath == mark.path,
              Self.revertRemoval(rec, wrote: mark.wrote, previous: mark.previous, revision: mark.revision,
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
        case ENOTDIR: name = "ENOTDIR"
        case ENAMETOOLONG: name = "ENAMETOOLONG"
        default: name = "errno \(e)"
        }
        return "\(name) (\(String(cString: strerror(e))))"
    }
}
