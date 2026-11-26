// ArchivedContentDateRefusal.swift
// GH #528 (rule 3, defence in depth): the commit refuses a date on a copy
// of ARCHIVED content — Rick's date AND the machine's inferred date.
//
// catalog.sqlite keeps one date per content (`user_dates` and
// `inferred_dates` are keyed by the whole-file digest), so a row that writes
// a date writes it for EVERY copy of its content — the archived copy
// included, after the next launch. The date seam
// (`VideoScanModel.isDateReadOnly`) is twin-aware and every writer asks it;
// this is the second wall, for a writer that did not — and for the case no
// writer can see: identity arriving AFTER the date (Codex round 2). A row
// with no whole-file digest is no twin, so an inference lane may date it;
// when its hash later lands on archived content's digest, its first commit
// would replace that content's `inferred_dates` row.
//
// Before a commit is planned, every changed row that is not archived itself
// and whose whole-file digest a LIVE archived copy holds is checked:
//   * USER DATE (userDate + confidence): when the row writes that group
//     (it differs from what the row last agreed with the store; a row the
//     store never saw counts when it carries a date) it is put back — to
//     its own baseline (the row then writes no date), or for a row the store
//     never saw to the archived copy's.
//   * INFERRED DATE (all five fields: inferredRecordDate, confidence,
//     source, range, reason — one `inferred_dates` row per digest): when
//     they differ from the archived copy's they are set to the archived
//     copy's. The store's row for the digest IS the archived copy's (both
//     were joined from it at load, and every inference writer refuses the
//     archived copy), so the row then writes nothing new, whether it is an
//     update or a first insert.
// The row is re-snapshotted (dropped if nothing else changed) and one line
// per refused group says what was refused. A later Update… on the archived
// copy still reaches its twins (the commit's copy step).
// A date written BY an archived copy (Update…, Promote) passes.
//
// The archived copies are found by a fresh scan, independent of the
// model's ArchivedContentIndex, once per commit that has changed rows.
// Cost: O(records) with an O(1) per-row test plus a digest read for the
// archived rows — small beside the commit's own O(records) detection (a DTO
// and fingerprint per record); memory: one dictionary entry per live
// archived content (≈ 100 B each; ≈ 10 MB worst case at 100k archived).
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
        guard !items.isEmpty else { return Result(items: items, lines: []) }
        let wanted = Set(items.map(\.id))
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
        for i in items.indices {
            guard let rec = rows[items[i].id], owns(rec), !isArchivedItself(rec),
                  let digest = CatalogCommit.digest(of: rec), let copy = archived[digest], copy !== rec else { continue }
            var refused = false
            if writesDate(items[i]) {
                let attempted = rec.userDate
                // Put back what the store holds as far as this row knows (its
                // own baseline — then the row writes no date at all); a row the
                // store never saw takes the archived copy's date. Either way the
                // content keeps the archived copy's date.
                if let baseline = items[i].sharedBaseline {
                    rec.userDate = baseline.userDate
                    rec.userDateConfidence = baseline.userDateConfidence
                } else {
                    rec.userDate = copy.userDate
                    rec.userDateConfidence = copy.userDateConfidence
                }
                lines.append(line(row: rec.id, archived: copy, digest: digest, attempted: attempted))
                refused = true
            }
            let filed = InferredDate(copy), attempted = InferredDate(rec)
            if attempted != filed {
                filed.put(on: rec)
                lines.append(inferredLine(row: rec.id, archived: copy, digest: digest, filed: filed, attempted: attempted))
                refused = true
            }
            guard refused else { continue }
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

    /// The five inferred-date fields — the one `inferred_dates` row a
    /// content has (CatalogRecordDTO+Derived `.inferredDate`). A value, so
    /// "differs" is one `!=` (≈ a C++ struct with a defaulted operator==).
    struct InferredDate: Equatable {
        let date: Date?
        let confidence: Float?
        let source: String?
        let range: InferredDateRange?
        let reason: String?

        init(_ r: VideoRecord) {
            date = r.inferredRecordDate; confidence = r.inferredDateConfidence; source = r.inferredDateSource
            range = r.inferredDateRange; reason = r.inferredDateReason
        }

        func put(on r: VideoRecord) {
            r.inferredRecordDate = date; r.inferredDateConfidence = confidence; r.inferredDateSource = source
            r.inferredDateRange = range; r.inferredDateReason = reason
        }

        /// The year (UTC) for the log line, or "none".
        var words: String {
            guard let date else { return "none" }
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
            return String(utc.component(.year, from: date))
        }
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

    static func inferredLine(row: UUID, archived copy: VideoRecord, digest: String,
                             filed: InferredDate, attempted: InferredDate) -> String {
        "Catalog store: REFUSED inferred date on \(row.uuidString) — its content (sha256 \(digest.prefix(12))…) has an "
            + "archived copy \(copy.id.uuidString); inferred date left as filed (\(filed.words)), \(attempted.words) not written. "
            + "The catalog keeps one date per content."
    }
}
