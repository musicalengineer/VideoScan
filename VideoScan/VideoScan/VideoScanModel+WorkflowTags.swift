import Foundation
import Combine

// MARK: - Workflow tags + user notes (feature/tags-and-usernotes, 2026-07-23)
//
// The ONE mutation path for `VideoRecord.tags` and `VideoRecord.userNotes`.
// Every mutator here does the same three things, in order:
//
//   1. Mutate the record(s) through WorkflowTags' canonicalize/dedup rules.
//   2. `searchIndex.update(rec)` per changed record — same single-record
//      refresh the dossier writeback path uses, so a `tag:gold` search
//      reflects the click immediately (no full rebuild, no restart).
//   3. `saveCatalogDebounced()` + `objectWillChange.send()` — the exact
//      persistence + republish shape the disposition ("Mark as
//      Important/Junk") context-menu buttons use, plus the explicit
//      publish because class-typed record fields can't fire the records
//      array's @Published didSet on their own.
//
// Vocabulary + matching rules live in WorkflowTags (VideoScanCore);
// the notes → userNotes split rule lives in UserNotesMigration (same
// file). Both are pure, so tests pin them without a model.

extension VideoScanModel {

    // MARK: Tag mutations

    /// Set `tag`'s presence across `recs` — the context-menu toggle
    /// semantics: mixed selections apply to ALL (present=true adds the
    /// tag everywhere it's missing; present=false removes it everywhere).
    func setTag(_ tag: String, on recs: [VideoRecord], present: Bool) {
        var changed: [VideoRecord] = []
        for rec in recs {
            let before = rec.tags
            rec.tags = present
                ? WorkflowTags.adding(tag, to: rec.tags)
                : WorkflowTags.removing(tag, from: rec.tags)
            if rec.tags != before { changed.append(rec) }
        }
        finishTagMutation(changed)
    }

    /// Add a (possibly custom, user-typed) tag to every record in
    /// `recs`. Canonicalizes ("follow up" → "Follow Up") and dedups
    /// case-insensitively; whitespace-only input is a no-op.
    func addTag(_ raw: String, to recs: [VideoRecord]) {
        let tag = WorkflowTags.canonicalize(raw)
        guard !tag.isEmpty else { return }
        setTag(tag, on: recs, present: true)
    }

    /// Remove one tag from one record (inspector chip ×).
    func removeTag(_ tag: String, from rec: VideoRecord) {
        setTag(tag, on: [rec], present: false)
    }

    /// Clear every tag on every record in `recs`.
    func removeAllTags(from recs: [VideoRecord]) {
        var changed: [VideoRecord] = []
        for rec in recs where !rec.tags.isEmpty {
            rec.tags = []
            changed.append(rec)
        }
        finishTagMutation(changed)
    }

    /// Shared tail of every tag mutation: index refresh + debounced
    /// save + republish. No-op for an empty change set so an idle
    /// toggle doesn't schedule a catalog write.
    private func finishTagMutation(_ changed: [VideoRecord]) {
        guard !changed.isEmpty else { return }
        for rec in changed { searchIndex.update(rec) }
        saveCatalogDebounced()
        objectWillChange.send()
    }

    // MARK: User notes

    /// Write Rick's note text for `rec`. The "Notes…" sheet routes here
    /// (it used to assign `rec.notes` directly) so the search index and
    /// save path stay in lock-step with the edit.
    func setUserNotes(_ text: String, for rec: VideoRecord) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rec.userNotes != trimmed else { return }
        rec.userNotes = trimmed
        searchIndex.update(rec)
        saveCatalogDebounced()
        objectWillChange.send()
    }

    // MARK: One-time notes → userNotes migration (catalog load)

    /// Move legacy HUMAN text out of machine `notes` into `userNotes`,
    /// once, at catalog load. Rule (Rick-approved 2026-07-22 design +
    /// 2026-07-23 QA fix): only when `userNotes` is empty AND `notes`
    /// is non-empty; MACHINE lines stay in `notes` — "[" probe lines,
    /// File Journey stamps ("Transcode <ISO>: …" etc.), and the
    /// Combined/MXF-fallback literals (see UserNotesMigration
    /// .isMachineLine) — everything else MOVES to `userNotes`.
    /// Idempotent by construction — after a move, `userNotes` is
    /// non-empty, so the gate never fires again. Returns the number of
    /// records migrated; the caller schedules a save when > 0.
    ///
    /// Runs BEFORE the search-index load/rebuild in
    /// restoreCatalogFromDisk so the haystacks are built from the
    /// post-migration field values.
    @discardableResult
    func migrateLegacyUserNotes() -> Int {
        var migrated = 0
        for rec in records {
            guard let result = UserNotesMigration.migrate(
                notes: rec.notes, userNotes: rec.userNotes
            ) else { continue }
            rec.notes = result.notes
            rec.userNotes = result.userNotes
            migrated += 1
        }
        return migrated
    }
}
