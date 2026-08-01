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

    /// Set `name`'s confirmed presence across `recs` — context-menu
    /// toggle semantics: mixed selections apply to ALL. Case-insensitive
    /// matching so a menu "Dan" toggles a free-text "dan" rather than
    /// double-tagging. Confirming also clears a matching rejection (the
    /// user changed their mind — same rule as the Inspector).
    func setPerson(_ name: String, on recs: [VideoRecord], present: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var changed: [VideoRecord] = []
        for rec in recs {
            let has = rec.confirmedByUserPeople.contains {
                $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame
            }
            if present, !has {
                rec.confirmedByUserPeople.append(
                    ConfirmedTag(name: trimmed, confirmedAt: Date()))
                rec.rejectedPeople.removeAll {
                    $0.compare(trimmed, options: .caseInsensitive) == .orderedSame
                }
                changed.append(rec)
            } else if !present, has {
                rec.confirmedByUserPeople.removeAll {
                    $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame
                }
                changed.append(rec)
            }
        }
        guard !changed.isEmpty else { return }
        for rec in changed { searchIndex.update(rec) }
        saveCatalogDebounced()
        objectWillChange.send()
    }
}
