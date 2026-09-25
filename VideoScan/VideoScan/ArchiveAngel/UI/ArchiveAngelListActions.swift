// ArchiveAngelListActions.swift
// What the five buttons on an Archive Angel recommendations row do (Rick
// 2026-09-24). Every one goes through a path the app already has — no new
// file-mutation path:
//   Play            → ArchiveAngelPlayerChoice → MediaOpener.open
//   Show in Catalog → the AngelNavigator seam (ArchiveAngelRowActions)
//   Show in Finder  → NSWorkspace (ArchiveAngelRowActions)
//   Promote         → Ready: VideoScanModel.requestPromote (the catalog's
//                     Promote to Archive sheet and all its gates);
//                     needs work: Archive Angel Prepare for that one record
//                     (the catalog's "Prepare with Archive Angel" path)
//   Archive Readiness → builds the explanation for the sheet
// Each logs one line (console + videoscan.log) saying what it did.
//
// (For Rick: a small value type holding references + closures — like a C++
// struct of a few pointers and std::function members, built fresh by the
// view each time it is needed; it owns nothing.)

import Foundation
import VideoScanCore

@MainActor
struct ArchiveAngelListActions {
    let model: VideoScanModel
    let angel: ArchiveAngel
    /// Starts Archive Angel's Prepare for exactly these records (the strip
    /// owns the MFO center and passes this in).
    let prepare: ([UUID]) -> Void

    /// A fresh snapshot for one record — nil when it left the catalog.
    func facts(_ id: UUID) -> ArchiveAngelRowFacts? {
        guard let rec = model.record(forID: id) else { return nil }
        return ArchiveAngelRowFacts.make(record: rec, evidence: angel.evidence(for: id),
                                         kind: angel.recommendationClass(for: id) ?? .notNow,
                                         isBeingChecked: angel.checkingIDs.contains(id))
    }

    func play(_ row: ArchiveAngelListRow) {
        guard let rec = model.record(forID: row.id) else { return gone(row) }
        ArchiveAngelPlayerChoice.play(rec) { model.log($0) }
    }

    func showInCatalog(_ row: ArchiveAngelListRow) {
        ArchiveAngelRowActions.showInCatalog(model: model, recordID: row.id, filename: row.filename)
    }

    func showInFinder(_ row: ArchiveAngelListRow) {
        ArchiveAngelRowActions.showInFinder(model: model, path: row.path)
    }

    /// Re-decides the route from a FRESH snapshot (the row may be a
    /// minute old: a date typed since then makes it Ready).
    func promote(_ row: ArchiveAngelListRow) {
        guard let f = facts(row.id) else { return gone(row) }
        let fresh = ArchiveAngelListRowBuilder.row(f)
        switch fresh.route {
        case .direct:
            model.log("Archive Angel: \(f.filename) is ready — opening Promote to Archive.")
            if let rec = model.record(forID: f.id) { model.noteMissingFileForUserAction(rec) }
            model.requestPromote(recordIDs: [f.id])
        case .prepare:
            model.log("Archive Angel: \(f.filename) \(fresh.statusWords.lowercased()) — preparing it first; it will be waiting under \u{201C}to review\u{201D} when done.")
            prepare([f.id])
        case .unavailable(let why):
            model.log("Archive Angel: \(f.filename) — not promoted. \(why)")
        }
    }

    func readiness(_ row: ArchiveAngelListRow) -> ArchiveAngelReadinessExplanation? {
        guard var f = facts(row.id) else {
            gone(row)
            return nil
        }
        // The row's off-main existence probe, carried over (no stat here).
        if row.location == .fileNotFound { f.fileExists = false }
        return ArchiveAngelReadinessExplanation.make(f)
    }

    private func gone(_ row: ArchiveAngelListRow) {
        model.log("Archive Angel: \(row.filename) is no longer in the catalog — it may have been removed or replaced by a re-scan.")
    }
}
