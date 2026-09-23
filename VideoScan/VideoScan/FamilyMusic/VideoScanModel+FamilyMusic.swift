// VideoScanModel+FamilyMusic.swift
// Family Music (Rick 2026-09-23) — the model half: Rick's explicit mark /
// unmark, mirrored to the Media Ledger (one line per record). These two
// functions are the ONLY writers of `VideoRecord.familyMusic`; nothing
// automatic ever calls them, so the shelf holds only what Rick chose.
//
// Both are O(selection) and run on the main actor (VideoRecord is a
// main-actor reference type). They bump the records revision
// (noteCatalogRecordsMutated), so the Archive tab's memoized snapshot —
// and with it the "Music" row count — recomputes exactly once.

import Foundation
import VideoScanCore

extension VideoScanModel {

    /// Mark `ids` as family music. A single file takes `performer` and
    /// `title` as given (blank → nil, i.e. cleared). A multi-selection
    /// passes `title: nil` so each file keeps its own (an existing mark's
    /// title survives a re-mark, else the list shows the filename), and a
    /// blank performer there also keeps each file's existing performer.
    /// Returns the ledger flush (tests await it); nil when nothing changed.
    @discardableResult
    func markFamilyMusic(_ ids: [UUID], performer: String?, title: String?,
                         at now: Date = Date()) -> Task<Void, Never>? {
        guard !isReadOnly else { return nil }
        let recs = ids.compactMap { record(forID: $0) }
        guard !recs.isEmpty else { return nil }
        var events: [MediaLedgerEvent] = []
        for rec in recs {
            let keepPerformer = title == nil && FamilyMusicInfo.clean(performer) == nil
            let mark = FamilyMusicInfo(performer: keepPerformer ? rec.familyMusic?.performer : performer,
                                       title: title ?? rec.familyMusic?.title,
                                       markedAt: now)
            rec.familyMusic = mark
            var detail = [MediaLedgerEvent.Detail.action: "marked"]
            if let p = mark.performer { detail[MediaLedgerEvent.Detail.performer] = p }
            if let t = mark.title { detail[MediaLedgerEvent.Detail.title] = t }
            events.append(ledgerEvent(.familyMusic, for: rec, by: .rick, at: now, detail: detail))
        }
        noteCatalogRecordsMutated()
        saveCatalogDebounced()
        log("Family Music: marked \(recs.count == 1 ? recs[0].filename : "\(recs.count) files")"
            + (FamilyMusicInfo.clean(performer).map { " — \($0)" } ?? ""))
        return ledgerAppend(events)
    }

    /// Take `ids` off the shelf. Records that were not marked are ignored
    /// (no ledger line for a no-op).
    @discardableResult
    func unmarkFamilyMusic(_ ids: [UUID], at now: Date = Date()) -> Task<Void, Never>? {
        guard !isReadOnly else { return nil }
        let recs = ids.compactMap { record(forID: $0) }.filter { $0.familyMusic != nil }
        guard !recs.isEmpty else { return nil }
        for rec in recs { rec.familyMusic = nil }
        noteCatalogRecordsMutated()
        saveCatalogDebounced()
        log("Family Music: unmarked \(recs.count == 1 ? recs[0].filename : "\(recs.count) files")")
        return ledgerAppend(recs.map {
            ledgerEvent(.familyMusic, for: $0, by: .rick, at: now,
                        detail: [MediaLedgerEvent.Detail.action: "unmarked"])
        })
    }
}
