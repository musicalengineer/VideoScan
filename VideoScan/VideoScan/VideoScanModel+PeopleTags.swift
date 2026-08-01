import Combine
import Foundation

// MARK: - People tags (Rick 2026-08-01: "People →" context menu)
//
// The ONE mutation path for `confirmedByUserPeople` from the catalog
// context menu. Same three-step contract as VideoScanModel+WorkflowTags
// (mutate → searchIndex.update per changed record → debounced save +
// republish), so a person click is people:-searchable immediately —
// which also makes it visible to the archivist's translated queries.
//
// Vocabulary policy (Rick): the People menu offers POI-database names
// ONLY — a controlled vocabulary keeps manual tags joined to the
// gallery the recognition engine trains against. This model layer
// doesn't enforce the vocabulary (the Inspector's free-text path still
// exists pending the tag-consolidation decision); the MENU does.

extension VideoScanModel {

    /// Set `name`'s presence across `recs` — context-menu toggle
    /// semantics: mixed selections apply to ALL. Case-insensitive
    /// matching so a menu "Dan" toggles a free-text "dan" rather than
    /// double-tagging.
    ///
    /// present=true: confirm (and clear a matching rejection — the user
    /// changed their mind; same rule as the Inspector).
    ///
    /// present=false means "NOT in this video" (Rick 2026-08-01, the
    /// Beth case): scrub the name from confirmed AND the auto lists —
    /// un-confirming alone left an old engine detection visible, so the
    /// un-tag looked ignored. An auto-sourced name also lands in
    /// rejectedPeople so a future rescan can't silently resurrect it.
    func setPerson(_ name: String, on recs: [VideoRecord], present: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        func same(_ other: String) -> Bool {
            other.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }
        var changed: [VideoRecord] = []
        for rec in recs {
            let hasConfirmed = rec.confirmedByUserPeople.contains { same($0.name) }
            if present, !hasConfirmed {
                rec.confirmedByUserPeople.append(
                    ConfirmedTag(name: trimmed, confirmedAt: Date()))
                rec.rejectedPeople.removeAll { same($0) }
                changed.append(rec)
            } else if !present {
                let wasAuto = rec.detectedPeople.contains(where: same)
                    || rec.suspectedPeople.contains(where: same)
                guard hasConfirmed || wasAuto else { continue }
                rec.confirmedByUserPeople.removeAll { same($0.name) }
                rec.detectedPeople.removeAll(where: same)
                rec.suspectedPeople.removeAll(where: same)
                if wasAuto, !rec.rejectedPeople.contains(where: same) {
                    rec.rejectedPeople.append(trimmed)
                }
                changed.append(rec)
            }
        }
        finishPeopleMutation(changed)
    }

    /// Wipe every people list on `recs` — the mistake-cleanup verb for
    /// records the old auto-tagger got wrong ("Remove All People").
    /// Clears rejections too: this is "start this file's people over",
    /// not "reject everyone".
    func removeAllPeople(from recs: [VideoRecord]) {
        var changed: [VideoRecord] = []
        for rec in recs {
            guard !rec.detectedPeople.isEmpty || !rec.suspectedPeople.isEmpty
                || !rec.confirmedByUserPeople.isEmpty || !rec.rejectedPeople.isEmpty
            else { continue }
            rec.detectedPeople = []
            rec.suspectedPeople = []
            rec.confirmedByUserPeople = []
            rec.rejectedPeople = []
            changed.append(rec)
        }
        finishPeopleMutation(changed)
    }

    /// Shared tail — same contract as finishTagMutation: index refresh
    /// per changed record + debounced save + republish; no-op when
    /// nothing changed so idle toggles never schedule a write.
    private func finishPeopleMutation(_ changed: [VideoRecord]) {
        guard !changed.isEmpty else { return }
        for rec in changed { searchIndex.update(rec) }
        saveCatalogDebounced()
        objectWillChange.send()
    }
}
