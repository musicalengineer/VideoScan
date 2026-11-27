// CuratedRecordEdits.swift
// Rick's hand on a record — the curated fields a person sets from a menu or
// the Inspector — and THE one guard every such edit passes first (codex
// #388 P1, GH #343).
//
// Why: a read-only session (a viewer Mac; a launch that opened read-only;
// Restore from Backup… running or done) refused the SAVE, but the edit
// itself still landed in memory. During a restore that edit is in neither
// the safety copy nor the restored catalog, and the quit writes no recovery
// copy of a read-only session — it was silently lost. Refusing at the save
// is too late: the edit must be refused where it is made.
//
// The rule: every curated-edit mutator asks `CuratedEditGuard.refuses` first
// and touches nothing when it says yes. The guard reads the model's one
// read-only flag (`VideoScanModel.isReadOnly`, the OR of the read-only facts)
// and logs ONE line per read-only episode with the reason in Rick's words
// (`CatalogReadOnlyFacts.readOnlyWords`) — not one per click.
//
// Who calls the guard:
//   * the model's own mutators (unchanged homes): setTag / addTag /
//     removeTag / removeAllTags, setUserNotes (VideoScanModel+WorkflowTags);
//     setPerson, clearMachinePeopleTags, clearRejections, removeAllPeople
//     (VideoScanModel+PeopleTags); dropWorkbenchToCatalog
//     (VideoScanModel+Workbench); Confirm Person's catalog writeback;
//   * this type — the edits that used to be written straight into the
//     record from a view: star rating, disposition (Organize menu and
//     Triage), user date (then InspectorDateEdit's archived-copy rule),
//     user place, the Inspector's people chips.
// The views keep their own refresh/persist tails; they run them only when
// the edit was taken (each method returns true).
//
// (For Rick: `CuratedRecordEdits` is a tiny value type holding a reference
// to the model — ≈ a C++ helper struct with a `Model&` member whose methods
// are the only writers of those fields. `@MainActor` = "UI thread only".)

import Foundation
import VideoScanCore

/// The one gate in front of every curated edit.
@MainActor
enum CuratedEditGuard {

    /// The last episode logged: which model (weak — a freed model's address
    /// may be reused, so never an ObjectIdentifier), which reason. One line
    /// per episode, not per click; a writable edit in between starts a new
    /// one. Bounded: one reference and one string.
    private static weak var loggedModel: VideoScanModel?
    private static var loggedReason: String?

    /// The reason when the session's read-only flag is up but no fact
    /// says why (a test that sets `isReadOnly` directly).
    static let fallbackWords = "this session is read-only"

    /// True = refuse: touch nothing. `action` names the edit for the log.
    static func refuses(_ action: String, model: VideoScanModel) -> Bool {
        guard model.isReadOnly else {
            if loggedModel === model { loggedModel = nil; loggedReason = nil }
            return false
        }
        let reason = model.readOnlyFacts.editRefusalWords ?? fallbackWords
        if loggedModel !== model || loggedReason != reason {
            loggedModel = model
            loggedReason = reason
            model.log("Edit refused (\(action)) — \(reason). Nothing was changed; edits made now would not be saved.")
        }
        return true
    }
}

/// The curated edits that views used to write straight into a record.
@MainActor
struct CuratedRecordEdits {
    let model: VideoScanModel

    // MARK: Rating

    /// Star rating (0…3) on `rec`. Persistence: the caller's onCommit
    /// (`saveCatalogDebounced`), as before.
    @discardableResult
    func setStarRating(_ stars: Int, on rec: VideoRecord) -> Bool {
        guard !CuratedEditGuard.refuses("rating", model: model) else { return false }
        rec.starRating = stars
        return true
    }

    // MARK: Disposition

    /// The Organize menu's verdict on `recs`, then the debounced save.
    @discardableResult
    func setDisposition(_ disposition: MediaDisposition, on recs: [VideoRecord]) -> Bool {
        guard !CuratedEditGuard.refuses("disposition", model: model) else { return false }
        for r in recs { r.mediaDisposition = disposition }
        model.saveCatalogDebounced()
        return true
    }

    /// Triage's verdict: as above, and a Cataloged file given a verdict
    /// moves to Reviewing. The caller runs its own refresh tail.
    @discardableResult
    func triageDisposition(_ disposition: MediaDisposition, on recs: [VideoRecord]) -> Bool {
        guard !CuratedEditGuard.refuses("disposition", model: model) else { return false }
        for rec in recs {
            rec.mediaDisposition = disposition
            if rec.lifecycleStage == .cataloged && disposition != .unreviewed {
                rec.lifecycleStage = .reviewing
            }
        }
        model.saveCatalogDebounced()
        return true
    }

    // MARK: Date and place ("When was this?" / "Where was this?")

    /// Rick's "When was this?" entry (empty = clear) — both rules, in order:
    /// the session's read-only guard (codex #388: nil = refused, nothing
    /// touched), then the archive's (GH #221 / codex #383: `InspectorDateEdit`
    /// refuses when `archived` — the record, or a live same-content copy, is
    /// archived — and is the one writer of `userDate`). `archived` is the
    /// caller's fresh `InspectorDateEdit.archivedCopy(fixing:…) != nil`.
    /// The caller posts the mutation on `.saved` / `.cleared`, as before.
    /// GH #528: the model's date seam is asked here as well, so a caller that
    /// passes a stale `archived` can never write a date onto any copy of
    /// archived content.
    func saveUserDate(entry: String, known: Bool, on rec: VideoRecord, archived: Bool) -> InspectorDateEdit.Outcome? {
        guard !CuratedEditGuard.refuses("date", model: model) else { return nil }
        return InspectorDateEdit.save(entry: entry, known: known, to: rec, readOnly: archived || model.isDateReadOnly(rec))
    }

    /// Forget the date: the read-only guard, then the archive's rule.
    func clearUserDate(on rec: VideoRecord, archived: Bool) -> InspectorDateEdit.Outcome? {
        guard !CuratedEditGuard.refuses("date", model: model) else { return nil }
        return InspectorDateEdit.clear(rec, readOnly: archived || model.isDateReadOnly(rec))
    }

    /// `place` nil clears (with its confidence). Caller posts the mutation.
    @discardableResult
    func setUserPlace(_ place: String?, known: Bool, on rec: VideoRecord) -> Bool {
        guard !CuratedEditGuard.refuses("place", model: model) else { return false }
        rec.userPlace = place
        rec.userPlaceConfidence = place == nil ? nil
            : (known ? UserPlaceConfidence.known : UserPlaceConfidence.estimated).rawValue
        return true
    }

    // MARK: The Inspector's people chips

    /// Confirm `name` (idempotent, case-insensitive) and un-reject it.
    @discardableResult
    func confirmPerson(_ name: String, on rec: VideoRecord) -> Bool {
        guard !name.isEmpty, !CuratedEditGuard.refuses("people", model: model) else { return false }
        guard !rec.confirmedByUserPeople.contains(where: {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }) else { return false }
        rec.confirmedByUserPeople.append(ConfirmedTag(name: name, confirmedAt: Date()))
        rec.rejectedPeople.removeAll { $0 == name }
        return true
    }

    /// Reject an engine detection: into rejectedPeople, out of detectedPeople.
    @discardableResult
    func rejectDetected(_ name: String, on rec: VideoRecord) -> Bool {
        guard !CuratedEditGuard.refuses("people", model: model) else { return false }
        if !rec.rejectedPeople.contains(name) { rec.rejectedPeople.append(name) }
        rec.detectedPeople.removeAll { $0 == name }
        return true
    }

    @discardableResult
    func unconfirm(tagID: String, on rec: VideoRecord) -> Bool {
        guard !CuratedEditGuard.refuses("people", model: model) else { return false }
        rec.confirmedByUserPeople.removeAll { $0.id == tagID }
        return true
    }

    @discardableResult
    func unreject(_ name: String, on rec: VideoRecord) -> Bool {
        guard !CuratedEditGuard.refuses("people", model: model) else { return false }
        rec.rejectedPeople.removeAll { $0 == name }
        return true
    }
}
