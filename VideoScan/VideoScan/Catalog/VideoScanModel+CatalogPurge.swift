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
// Under catalog.json both are plain array work: the JSON save writes the
// whole array, so there is nothing to tell.
//
// (For Rick: an explicit `erase(key)` call to the write-behind cache from the
// code that erased the element — instead of the cache diffing the container
// and guessing which keys were meant to go.)

import Foundation

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

    /// Put `newRec` at `path`: it replaces the record that holds the path
    /// now (that record's id is purged when it differs), or is appended.
    /// The one door for a job's output landing in the catalog.
    func placeRecord(_ newRec: VideoRecord, atPath path: String, reason: String) {
        guard let existing = records.firstIndex(where: { $0.fullPath == path }) else {
            records.append(newRec)
            return
        }
        let replaced = records[existing].id
        records[existing] = newRec
        if replaced != newRec.id { purgeCatalogRows(ids: [replaced], reason: reason) }
    }
}
