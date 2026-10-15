// ShowAgain+Apply.swift
// The writing half of "Show these files again" (see ShowAgain.swift for the
// workflow, the criteria and why the live value is `.none`).
//
// Order of a run — every check that can say no runs before the first label
// changes, and nothing awaits between the last check and the change:
//   1. refuse on a viewer Mac / with nothing reviewed;
//   2. each reviewed file must still be the record the review showed
//      (same id, path, size, still labelled, still active);
//   3. the check again, off the main actor: ledger read strictly, one stat
//      per file (Stop here = nothing changed);
//   4. the catalog safety snapshot (`catalog.pre-show-again.<stamp>.json`) —
//      none written → refuse, nothing changed;
//   5. on the main actor, with no await until the labels are set: the live
//      record re-checked once more, the receipt written (none → refuse),
//      each row restored through the engine (`clearRemoval`: marker and
//      label cleared together), the search index told;
//   6. one per-file line to catalog.log (one fsync), the acknowledged save,
//      the OUTCOME line with where the snapshot and the receipt are and how
//      to put the labels back.

import Foundation

/// One file that stays labelled, and why.
struct ShowAgainStayed: Equatable, Sendable {
    let candidate: ShowAgainCandidate
    let reason: ShowAgainStayReason
}

extension ShowAgainPlan {
    /// Every file this plan keeps labelled, as rows.
    var stayedRows: [ShowAgainStayed] {
        items.compactMap { item in
            guard case .stays(let why) = item.verdict else { return nil }
            return ShowAgainStayed(candidate: item.candidate, reason: why)
        }
    }

    /// What a run starts from, given the REVIEWED plan: the files the review
    /// offered whose live record is still the one reviewed (to be checked
    /// again), and everything that stays — the review's own stays (never
    /// changed, listed for the record) plus offered files whose record
    /// changed since. Pure.
    func runInputs(isStillSame: (ShowAgainCandidate) -> Bool) -> (recheck: [ShowAgainCandidate], stayed: [ShowAgainStayed]) {
        var stayed = stayedRows
        var recheck: [ShowAgainCandidate] = []
        for item in toShow {
            if isStillSame(item.candidate) {
                recheck.append(item.candidate)
            } else {
                stayed.append(ShowAgainStayed(candidate: item.candidate, reason: .changedSinceReview))
            }
        }
        return (recheck, stayed)
    }
}

extension VideoScanModel {

    struct ShowAgainRunResult: Equatable {
        enum Outcome: Equatable {
            /// Labels changed and the catalog save was acknowledged.
            case shown
            /// Nothing passed the re-check; nothing changed.
            case nothingToDo
            /// A check said no before anything changed.
            case refused(String)
            /// Stopped before anything changed.
            case stopped
            /// Labels changed in memory, but the save was not acknowledged:
            /// the debounced save retries; the receipt lists the changes.
            case saveUnconfirmed
        }
        var outcome: Outcome
        var shown: [ShowAgainCandidate] = []
        var stayed: [ShowAgainStayed] = []
        var snapshotPath: String?
        var receiptURL: URL?

        var shownBytes: Int64 { shown.reduce(Int64(0)) { $0 + $1.sizeBytes } }
        var summary: String {
            ShowAgainLines.outcome(shown: shown.count, bytes: shownBytes, stayed: stayed.count)
        }
    }

    // MARK: Run

    /// Show again exactly the files the review offered that still pass every
    /// check now. Label-only (see the file header for the order).
    func applyShowAgain(reviewed: ShowAgainPlan, disk: ShowAgainDisk = .live,
                        progress: (@Sendable (Int, Int) -> Void)? = nil) async -> ShowAgainRunResult {
        if let why = showAgainPreflightRefusal(reviewed) { return showAgainRefused(why) }
        let p = ShowAgainLines.prefix
        showAgainNote("\(p): START — \(reviewed.headline) (as reviewed); each is checked again on disk and in the ledger before its label changes. Label only: nothing is moved, renamed or opened for writing.")
        let inputs = reviewed.runInputs(isStillSame: showAgainLiveMatches)
        let fresh = await ShowAgainPlan.check(inputs.recheck, ledgerURL: mediaLedger.fileURL, disk: disk, progress: progress)
        if Task.isCancelled { return showAgainStopped(stayed: inputs.stayed) }
        if let why = fresh.refusal { return showAgainRefused(why) }
        let stayed = inputs.stayed + fresh.stayedRows
        let go = fresh.toShow.map(\.candidate)
        showAgainNote("\(p): checked \(fresh.items.count.formatted()) — \(go.count.formatted()) pass, \(stayed.count.formatted()) stay labelled")
        guard !go.isEmpty else { return showAgainFinish(.nothingToDo, shown: [], stayed: stayed, snapshot: nil, receipt: nil) }

        guard let snapshot = await snapshotCatalogAsync(prefix: "pre-show-again") else {
            return showAgainRefused("the catalog safety copy could not be written, so no label was changed")
        }
        if Task.isCancelled { return showAgainStopped(stayed: stayed) }
        let committed = showAgainCommit(go, stayed: stayed, snapshot: snapshot)
        // Only a commit that changed labels comes back `.saveUnconfirmed`;
        // everything else is already final.
        guard committed.outcome == .saveUnconfirmed else { return committed }
        let saved = await saveCatalogAcknowledged()
        if !saved { saveCatalogDebounced() }
        return showAgainFinish(saved ? .shown : .saveUnconfirmed, shown: committed.shown, stayed: committed.stayed,
                               snapshot: committed.snapshotPath, receipt: committed.receiptURL)
    }

    /// Step 5. Synchronous: no other main-actor work can interleave between
    /// the last check and the label change.
    private func showAgainCommit(_ go: [ShowAgainCandidate], stayed: [ShowAgainStayed],
                                 snapshot: String) -> ShowAgainRunResult {
        var stayed = stayed
        var final: [ShowAgainCandidate] = []
        for c in go {
            if showAgainLiveMatches(c) {
                final.append(c)
            } else {
                stayed.append(ShowAgainStayed(candidate: c, reason: .changedSinceReview))
            }
        }
        guard !final.isEmpty else {
            return showAgainFinish(.nothingToDo, shown: [], stayed: stayed, snapshot: snapshot, receipt: nil)
        }
        let receipt: URL
        do {
            receipt = try writeShowAgainReceipt(final, snapshot: snapshot)
        } catch {
            return showAgainRefused("the change list (receipt) could not be written (\(error.localizedDescription)), so no label was changed")
        }
        // The engine's Restore clears the marker AND the old label in one
        // step, and leaves the lifecycle stage of a not-Trashed row alone.
        // It never refuses a removed-from-catalog marker; a refusal (its
        // words) is a row that stays, never a crash.
        var shown: [ShowAgainCandidate] = []
        shown.reserveCapacity(final.count)
        for c in final {
            guard let rec = record(forID: c.id) else { continue }
            if let why = clearRemoval(rec) {
                stayed.append(ShowAgainStayed(candidate: c, reason: .restoreRefused(why)))
                continue
            }
            shown.append(c)
            searchIndex.update(rec)
        }
        noteCatalogRecordsMutated()
        dashboard.catalogLog.writeBatch(shown.map(ShowAgainLines.shownLine)
                                        + stayed.map { ShowAgainLines.stayedLine($0.candidate, $0.reason) })
        guard !shown.isEmpty else {
            return showAgainFinish(.nothingToDo, shown: [], stayed: stayed, snapshot: snapshot, receipt: receipt)
        }
        // Committed, not yet saved — the caller awaits the save.
        return ShowAgainRunResult(outcome: .saveUnconfirmed, shown: shown, stayed: stayed,
                                  snapshotPath: snapshot, receiptURL: receipt)
    }

    // MARK: Pieces

    /// Why the run cannot start. The scan check (codex r1 P2-2): a rescan
    /// carries a row's removal marker across the scan (the allowlisted
    /// RescanPreservation carry-over) — fields captured before this run and
    /// applied after it would re-hide the row while the receipt says it was
    /// shown. Same flag the Analyze cyclers refuse on.
    func showAgainPreflightRefusal(_ reviewed: ShowAgainPlan) -> String? {
        if isReadOnly || ViewerWriteGuard.refuse("VideoScanModel.applyShowAgain") {
            return "this Mac is a read-only viewer of the catalog"
        }
        if isScanning { return Self.scanRunningRefusal }
        if let why = reviewed.refusal { return why }
        if reviewed.toShow.isEmpty { return "the review offered nothing to show again" }
        return nil
    }

    /// The live record is still the one the review showed: same path and
    /// size, still a candidate, the same (or still no) legacy marker.
    func showAgainLiveMatches(_ c: ShowAgainCandidate) -> Bool {
        guard let rec = record(forID: c.id) else { return false }
        return ShowAgainRules.isCandidate(rec) && rec.fullPath == c.fullPath && rec.sizeBytes == c.sizeBytes
            && ShowAgainRules.legacyMarkerSince(rec) == c.removalSince
    }

    static let scanRunningRefusal = "a scan is running — let it finish, then show the files again"

    func writeShowAgainReceipt(_ changes: [ShowAgainCandidate], snapshot: String) throws -> URL {
        let dir = showAgainReceiptsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        var url = dir.appendingPathComponent("show-again-\(stamp).json")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("show-again-\(stamp).\(n).json")
            n += 1
        }
        let file = ShowAgainReceiptFile(
            runID: "show-again-\(stamp)", writtenAt: Date(), snapshotPath: snapshot,
            changes: changes.map {
                // The stage the row really has (a marker-only row is `.none`
                // already — QA P3-1) and the stage the engine's Restore will
                // leave it with: `.manuallyDeleted` → `.none`, any other
                // label stays (codex r1 P2-1: a Backed Up row with the
                // legacy marker is `from == to`). The reverse puts a label
                // back only where the run cleared one, and holds against
                // the real `to`.
                let from = record(forID: $0.id)?.archiveStage ?? ShowAgainRules.falseLabel
                let to = from == ShowAgainRules.falseLabel ? ShowAgainRules.liveLabel : from
                return .init(id: $0.id, path: $0.fullPath, from: from.rawValue, to: to.rawValue,
                             removalSince: $0.removalSince)
            })
        try ShowAgainReceiptFile.encode(file).write(to: url, options: .atomic)
        return url
    }

    private func showAgainRefused(_ why: String) -> ShowAgainRunResult {
        showAgainNote("\(ShowAgainLines.prefix): refused — \(why). Nothing was changed.")
        return ShowAgainRunResult(outcome: .refused(why))
    }

    private func showAgainStopped(stayed: [ShowAgainStayed]) -> ShowAgainRunResult {
        showAgainNote("\(ShowAgainLines.prefix): OUTCOME stopped before any label changed — nothing was changed.")
        return ShowAgainRunResult(outcome: .stopped, stayed: stayed)
    }

    @discardableResult
    private func showAgainFinish(_ outcome: ShowAgainRunResult.Outcome, shown: [ShowAgainCandidate],
                                 stayed: [ShowAgainStayed], snapshot: String?, receipt: URL?) -> ShowAgainRunResult {
        let result = ShowAgainRunResult(outcome: outcome, shown: shown, stayed: stayed,
                                        snapshotPath: snapshot, receiptURL: receipt)
        if outcome == .nothingToDo {
            dashboard.catalogLog.writeBatch(stayed.map { ShowAgainLines.stayedLine($0.candidate, $0.reason) })
        }
        let p = ShowAgainLines.prefix
        switch outcome {
        case .shown:
            showAgainNote("\(p): OUTCOME — \(result.summary). Catalog saved. Safety copy: \(snapshot ?? "?"). Change list: \(receipt?.path ?? "?"). To undo: Media File Operations ▸ this row ▸ Put the labels back.")
        case .saveUnconfirmed:
            showAgainNote("\(p): OUTCOME — \(result.summary), but the catalog save was NOT confirmed; it will be retried. Change list: \(receipt?.path ?? "?").")
        case .nothingToDo:
            showAgainNote("\(p): OUTCOME — nothing passed the check; nothing was changed (\(stayed.count.formatted()) left labelled).")
        case .refused, .stopped:
            break
        }
        return result
    }

    // MARK: Reverse

    struct ShowAgainReverseResult: Equatable {
        var restored = 0
        var skipped: [String] = []
        var refusal: String?
    }

    /// Put `.manuallyDeleted` (only where the receipt's `from` says the run
    /// cleared it) — and, where the receipt says the run cleared one, the
    /// legacy removal marker with its original `since` — back on exactly
    /// the records a run changed, only where the label is still the value
    /// the run set and the path is the same. The lifecycle stage is not put
    /// back (see the ShowAgain.swift header). Takes its own safety
    /// snapshot first. Catalog-only: the marker goes through the engine's
    /// one writer (`stampRemoval`), which leaves the lifecycle stage of a
    /// removed-from-catalog row alone.
    func reverseShowAgain(receiptURL: URL) async -> ShowAgainReverseResult {
        let p = ShowAgainLines.prefix
        if isReadOnly || ViewerWriteGuard.refuse("VideoScanModel.reverseShowAgain") {
            return showAgainReverseRefused("this Mac is a read-only viewer of the catalog")
        }
        if isScanning { return showAgainReverseRefused(Self.scanRunningRefusal) }
        let file: ShowAgainReceiptFile
        do {
            file = try ShowAgainReceiptFile.decode(Data(contentsOf: receiptURL))
        } catch {
            return showAgainReverseRefused("the change list \(receiptURL.path) could not be read (\(error.localizedDescription))")
        }
        showAgainNote("\(p): put the labels back — START — \(file.changes.count.formatted()) file(s) from \(receiptURL.lastPathComponent)")
        guard let snapshot = await snapshotCatalogAsync(prefix: "pre-show-again-undo") else {
            return showAgainReverseRefused("the catalog safety copy could not be written")
        }
        var out = ShowAgainReverseResult()
        var lines: [String] = []
        let activeInGroup = showAgainActiveGroupCounts()
        for change in file.changes {
            if let why = showAgainReverseHold(change, activeInGroup: activeInGroup) {
                out.skipped.append(change.path)
                lines.append("[show-again] label NOT put back: \(change.path) id=\(change.id.uuidString) — \(why) (left as it is)")
                continue
            }
            guard let rec = record(forID: change.id) else { continue }
            if let since = change.removalSince {
                Self.stampRemoval(rec, .removedFromCatalog(at: since, reason: .legacyDeletedLabel))
            }
            let labelPutBack = change.from == ShowAgainRules.falseLabel.rawValue
            if labelPutBack { rec.archiveStage = ShowAgainRules.falseLabel }
            searchIndex.update(rec)
            out.restored += 1
            lines.append(ShowAgainLines.revertedLine(path: change.path, id: change.id, labelPutBack: labelPutBack,
                                                     markerPutBack: change.removalSince != nil))
        }
        noteCatalogRecordsMutated()
        dashboard.catalogLog.writeBatch(lines)
        let saved = await saveCatalogAcknowledged()
        if !saved { saveCatalogDebounced() }
        showAgainNote("\(p): put the labels back — OUTCOME — \(out.restored.formatted()) put back, \(out.skipped.count.formatted()) left as they are\(saved ? "" : " (catalog save not confirmed; it will be retried)"). Safety copy: \(snapshot).")
        return out
    }

    /// Why one change must NOT be reversed (QA round 1): the record changed
    /// since; it left the catalog view (purged, set aside, superseded —
    /// relabelling a removed row writes a label nobody sees and hides it from
    /// Restore); or it is now the surviving copy of its duplicate group (its
    /// group's other copies left after the run — hiding it again would hide
    /// the footage). nil = put the label back.
    func showAgainReverseHold(_ change: ShowAgainReceiptFile.Change, activeInGroup: [UUID: Int]) -> String? {
        guard let rec = record(forID: change.id), rec.fullPath == change.path,
              rec.archiveStage.rawValue == change.to else { return "the record changed since" }
        if rec.isPurged || rec.isSetAside || rec.isSuperseded {
            return "it was removed from the catalog view since"
        }
        // Whatever its disposition (QA round 2): the group's last active copy.
        if let group = rec.duplicateGroupID, (activeInGroup[group] ?? 0) <= 1 {
            return "it is now the surviving copy of its duplicate group"
        }
        return nil
    }

    /// Active (not purged / set aside / superseded) records per duplicate
    /// group — one O(records) pass per reverse.
    func showAgainActiveGroupCounts() -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for r in records where !r.isPurged && !r.isSetAside && !r.isSuperseded {
            if let g = r.duplicateGroupID { counts[g, default: 0] += 1 }
        }
        return counts
    }

    private func showAgainReverseRefused(_ why: String) -> ShowAgainReverseResult {
        showAgainNote("\(ShowAgainLines.prefix): put the labels back — refused — \(why). Nothing was changed.")
        return ShowAgainReverseResult(refusal: why)
    }
}
