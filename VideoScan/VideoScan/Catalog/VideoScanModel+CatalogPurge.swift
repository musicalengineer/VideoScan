// VideoScanModel+CatalogPurge.swift
// Cutover B2.3 (codex B2.2 finding (e)): a record leaves catalog.sqlite ONLY
// when a door that removes it from the catalog says so. One sentence: the
// door that takes a record out of `records` names its id here, in the same
// main-actor turn, and the committer purges that row (tombstoned, never
// deleted; a held row's payload kept).
//
// Before B2.3 the committer INFERRED a purge from absence (an id missing at
// two full commits, or at a synchronous save). Codex showed a live file's
// row could be purged that way and its saved curated values hidden. Absence
// now proves nothing: a record that leaves memory without a door's purge is
// a bug — the committer says so once and keeps the row.
//
// The doors (CatalogPurgeDoorSensorTests pins that each one calls
// `purgeCatalogRows(ids:`): the scan merge (re-seen replacement, prune of
// gone files, partial upsert), Forget a volume's records, the three
// catalog-scope purges (non-video, cover-art music, unrelated audio), Find
// Missing Audio's undo of its own probe row, Delete All and Clear Results,
// the volume-rename Undo, and — through `placeRecord` — every job that lands
// a new record at a path an older record held (Promote, Balance Audio,
// Repair, a derivative's landing).
//
// Cutover B2.4 (codex B2.3 finding "placeRecord purges a replaced row's
// curation"): `placeRecord` purges the replaced id ONLY when the new record
// is provably the same bytes (same whole-file digest), and only after the
// new record has inherited every curated value. Otherwise the old record is
// kept — removed from the catalog as `replacedAtPath`, its curation intact —
// and one log line names what it carried (CatalogReplacedRecord.swift).
//
// Cutover B2.5 (codex B2.4 finding 1 "an unsaved edit before a same-digest
// heir"): BEFORE any inherit / purge / retire, `placeRecord` commits the old
// record (`commitBeforeReplacing`), so an edit made inside the 2 s debounce
// is durable — and in row_knowledge — first. When that commit cannot run
// (held, blocked, refused) nothing is replaced: the old record stays live,
// the new one lands beside it, and the log says NOT RECORDED and why.
//
// Under catalog.json both are plain array work: the JSON save writes the
// whole array, so there is nothing to tell.
//
// (For Rick: an explicit `erase(key)` call to the write-behind cache from the
// code that erased the element — instead of the cache diffing the container
// and guessing which keys were meant to go.)

import Foundation
import VideoScanCore

extension VideoScanModel {

    /// These records were taken out of `records` by a door, in this turn.
    /// Under catalog.sqlite their rows are purged now (one synchronous
    /// commit); an id that is still in `records` (it came back under the
    /// same id) is never purged. Nothing to do under catalog.json.
    func purgeCatalogRows(ids: Set<UUID>, reason: String) {
        guard let committer = catalogCutover.committer, !ids.isEmpty else { return }
        let gone = ids.subtracting(records.lazy.map(\.id))
        guard !gone.isEmpty else { return }
        committer.purge(ids: gone, reason: reason)
    }

    /// Put `newRec` at `path` — the one door for a job's output landing in
    /// the catalog. The LIVE record that holds the path now (a removed one
    /// no longer holds it) is replaced:
    ///   same id            → swapped in place;
    ///   same whole-file digest → `newRec` inherits its curated values, then
    ///                        its id is purged;
    ///   otherwise          → it is kept, removed from the catalog as
    ///                        `replacedAtPath` with its curation, and logged.
    /// Before replacing (B2.5) the old record is committed as it is now;
    /// when that cannot run, nothing is replaced and both stay live.
    /// No live record at the path → appended.
    func placeRecord(_ newRec: VideoRecord, atPath path: String, reason: String) {
        guard let existing = records.firstIndex(where: { $0.fullPath == path && $0.removal == nil }) else {
            records.append(newRec)
            return
        }
        let replaced = records[existing]
        if replaced === newRec { return }
        if replaced.id == newRec.id {
            landSameID(newRec, over: replaced, at: existing, path: path)
        } else if let why = catalogCutover.committer?.commitBeforeReplacing(replaced.id) {
            keepBoth(replaced, newRec, at: existing, path: path, why: why)
        } else if CatalogReplacedRecord.sameContent(replaced, newRec) {
            inheritThenPurge(replaced, heir: newRec, at: existing, path: path, reason: reason)
        } else {
            retire(replaced, for: newRec, at: existing, path: path)
        }
    }

    /// A job lands a record with the SAME id as the live one (codex B2.5/B2.6
    /// closing pass, 2026-10-18): it may be a snapshot taken before the
    /// person's latest edit. The live record is committed first (its values
    /// reach SQLite and history), and the person's curated values carry onto
    /// the incoming record — a job's snapshot never overwrites what a person
    /// wrote. When the commit cannot run, the live record stays and the job's
    /// update is not recorded (refused, not lost).
    private func landSameID(_ newRec: VideoRecord, over live: VideoRecord, at index: Int, path: String) {
        if let why = catalogCutover.committer?.commitBeforeReplacing(live.id) {
            noteReplacement("NOT RECORDED: a job's update to \(path) landed, but the record there "
                            + "(\(CatalogReplacedRecord.describe(live))) could not be saved first — \(why). "
                            + "The record is kept as it is; run the job again when the catalog can save.")
            return
        }
        let persons = CatalogSharedCurated(live)
        for group in CatalogSharedCurated.Group.allCases {
            persons.apply(group, to: newRec)
        }
        newRec.setAsideReason = live.setAsideReason
        records[index] = newRec
    }

    /// The old record's current values could not be saved first: nothing
    /// is replaced, inherited or purged. Both stay live (refused, not lost).
    private func keepBoth(_ old: VideoRecord, _ newRec: VideoRecord, at index: Int, path: String, why: String) {
        records.insert(newRec, at: index + 1)
        noteReplacement("NOT RECORDED: a new file landed at \(path), but the earlier record there "
                        + "(\(CatalogReplacedRecord.describe(old))) could not be saved first — \(why). Nothing was "
                        + "replaced; both stay in the catalog; Verify Catalog will find it.")
    }

    /// The same bytes: every curated value moves to `heir`, then the old id goes.
    private func inheritThenPurge(_ old: VideoRecord, heir: VideoRecord, at index: Int, path: String, reason: String) {
        let differing = CatalogReplacedRecord.inherit(from: old, onto: heir)
        if !differing.isEmpty {
            noteReplacement("the earlier record at \(path) (the same bytes) had \(differing.joined(separator: "; ")). "
                            + "The new record's own values are kept; the earlier ones were saved first and stay in "
                            + "the catalog's history")
        }
        records[index] = heir
        purgeCatalogRows(ids: [old.id], reason: reason)
    }

    /// Different (or unknown) bytes: the old record stays, removed from the
    /// catalog as `replacedAtPath`; the new one lands beside it. A disk fact
    /// (the file at that path is no longer those bytes), so refused only when
    /// the old row's earlier marker change cannot be stored first — then the
    /// old row stays live, the new one waits for the path (refused, not lost),
    /// and the words say so.
    private func retire(_ old: VideoRecord, for newRec: VideoRecord, at index: Int, path: String) {
        let carried = CatalogReplacedRecord.describe(old)
        let marker = RemovalMarker.removedFromCatalog(at: Date(), reason: .replacedAtPath)
        // Marker FIRST (it frees the live path), then the new record right
        // after the old one, so a commit in records order lands them in that order.
        let refusal = Self.stampRemoval(old, marker, kind: .diskFact)
        records.insert(newRec, at: index + 1)
        if let why = refusal {
            noteReplacement("NOT RECORDED: a new file landed at \(path), but the earlier record there (\(carried)) could not be "
                            + "marked replaced — \(why). Both stay in the catalog; Verify Catalog will find it.")
            return
        }
        noteReplacement("the earlier file at \(path) had \(carried) — kept in the catalog's history "
                        + "(removed from the catalog as replacedAtPath; nothing purged)")
    }

    /// One line to the console, catalog.log and videoscan.log.
    private func noteReplacement(_ line: String) {
        log("Catalog: " + line)
        appLog.write("[catalog] " + line)
    }
}
