// ArchivedContentDateRefusal.swift
// GH #528 (rule 3, defence in depth): the commit refuses Rick's date on a
// copy of ARCHIVED content.
//
// catalog.sqlite keeps one date per content (`user_dates` is keyed by the
// whole-file digest), so a row that writes a date writes it for EVERY copy
// of its content — the archived copy included, after the next launch. The
// date seam (`VideoScanModel.isDateReadOnly`) is twin-aware and every writer
// asks it; this is the second wall, for a writer that did not. Before a
// commit is planned, every changed row whose DATE GROUP is being written
// (its date and confidence differ from what it last agreed with the store;
// a row the store never saw counts when it carries a date) is checked: if
// it is not archived itself and a LIVE archived copy holds its whole-file
// digest, its date is put back — to its own baseline (what the store holds;
// the row then writes no date), or for a row the store never saw to the
// archived copy's — the row is re-snapshotted, and one line says what was
// refused. A later Update… on the archived copy still reaches it (the
// commit's copy step).
// A date written BY an archived copy (Update…, Promote) passes.
//
// The archived copies are found by a fresh scan, independent of the
// model's ArchivedContentIndex — and only when some row in the commit is
// writing a date (rare). Cost: O(records) once in that case, an O(1)
// per-row test plus a digest read for archived rows; memory: one
// dictionary entry per live archived content (≈ 100 B each).
//
// Log line: ids and a digest prefix only (DECISIONS 2026-10-02, ARCH-7).
//
// (For Rick: a pure function over the commit's change list — a filter pass
// that may rewrite an element, like a `std::transform` with a side list of
// messages.)

import Foundation
import VideoScanCore

@MainActor
enum ArchivedContentDateRefusal {

    struct Result {
        var items: [CatalogCommit.Item]
        var lines: [String]
    }

    /// `isArchivedItself` is the seam's per-row rule; `owns` keeps detached
    /// snapshots out; `baselinePrints` drops a row whose only change was the
    /// refused date (nothing is left to write).
    static func refuse(_ items: [CatalogCommit.Item], records: [VideoRecord],
                       isArchivedItself: (VideoRecord) -> Bool, owns: (VideoRecord) -> Bool,
                       baselinePrints: [UUID: CatalogChangeDetector.Fingerprint]) -> Result {
        let writing = items.indices.filter { writesDate(items[$0]) }
        guard !writing.isEmpty else { return Result(items: items, lines: []) }
        let wanted = Set(writing.map { items[$0].id })
        var rows: [UUID: VideoRecord] = [:]
        var archived: [String: VideoRecord] = [:]
        for rec in records {
            if wanted.contains(rec.id) { rows[rec.id] = rec }
            if rec.removal == nil, isArchivedItself(rec), let digest = CatalogCommit.digest(of: rec),
               archived[digest] == nil {
                archived[digest] = rec
            }
        }
        guard !archived.isEmpty else { return Result(items: items, lines: []) }
        var out = items
        var dropped = Set<Int>()
        var lines: [String] = []
        for i in writing {
            guard let rec = rows[items[i].id], owns(rec), !isArchivedItself(rec),
                  let digest = CatalogCommit.digest(of: rec), let copy = archived[digest], copy !== rec else { continue }
            let attempted = rec.userDate
            // Put back what the store holds as far as this row knows (its own
            // baseline — then the row writes no date at all); a row the store
            // never saw takes the archived copy's date. Either way the content
            // keeps the archived copy's date.
            if let baseline = items[i].sharedBaseline {
                rec.userDate = baseline.userDate
                rec.userDateConfidence = baseline.userDateConfidence
            } else {
                rec.userDate = copy.userDate
                rec.userDateConfidence = copy.userDateConfidence
            }
            lines.append(line(row: rec.id, archived: copy, digest: digest, attempted: attempted))
            let snapshot = VideoRecordDTO(rec)
            let print = CatalogChangeDetector.fingerprint(snapshot)
            if baselinePrints[rec.id] == print {
                dropped.insert(i)
            } else {
                out[i] = CatalogCommit.Item(id: rec.id, snapshot: snapshot, fingerprint: print,
                                            sharedBaseline: items[i].sharedBaseline)
            }
        }
        if !dropped.isEmpty { out = out.indices.filter { !dropped.contains($0) }.map { out[$0] } }
        return Result(items: out, lines: lines)
    }

    /// True when this item writes the shared date group: its date differs
    /// from its own baseline, or (never stored by this session) it carries one.
    static func writesDate(_ item: CatalogCommit.Item) -> Bool {
        guard let baseline = item.sharedBaseline else { return item.snapshot.userDate != nil }
        return !CatalogSharedCurated(item.snapshot).same(.date, as: baseline)
    }

    static func line(row: UUID, archived copy: VideoRecord, digest: String, attempted: String?) -> String {
        "Catalog store: REFUSED date on \(row.uuidString) — its content (sha256 \(digest.prefix(12))…) has an archived copy "
            + "\(copy.id.uuidString); date left as filed (\(copy.userDate ?? "none")), \(attempted ?? "no date") not written. "
            + "The catalog keeps one date per content. Use Update… on the archived copy to change it."
    }
}
