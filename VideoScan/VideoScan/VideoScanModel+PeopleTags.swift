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

    /// Wipe only the MACHINE tiers (name* / name?) on `recs` — the
    /// recipe-pollution cleanup (Rick 2026-08-02: false positives must
    /// be clearable WITHOUT losing manual confirms). Confirmed and
    /// rejected are human judgments and survive untouched.
    func clearMachinePeopleTags(from recs: [VideoRecord]) {
        var changed: [VideoRecord] = []
        for rec in recs {
            guard !rec.detectedPeople.isEmpty || !rec.suspectedPeople.isEmpty
            else { continue }
            rec.detectedPeople = []
            rec.suspectedPeople = []
            changed.append(rec)
        }
        finishPeopleMutation(changed)
    }

    /// Clear ONLY rejections ("not X") on `recs` — lets the recipe judge
    /// these files again without confirming anything (Rick 2026-08-02:
    /// a bulk un-tag cleanup swept a true-Donna file into a rejection,
    /// which then invisibly blocked Find & Tag).
    func clearRejections(from recs: [VideoRecord]) {
        var changed: [VideoRecord] = []
        for rec in recs where !rec.rejectedPeople.isEmpty {
            rec.rejectedPeople = []
            changed.append(rec)
        }
        finishPeopleMutation(changed)
    }

    /// Wipe every people list on `recs` — the mistake-cleanup verb for
    /// records the old auto-tagger got wrong ("Clear People Tags").
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

    // MARK: Recipe (machine-tier) verdicts — Find & Tag

    /// Recipe score thresholds are PER ENGINE — cosine scores are not
    /// comparable across embedding spaces (docs/donna-recipe-v1.md;
    /// the 2026-08-02 native calibration sweep proved it: python-space
    /// 0.55 ≈ native-ArcFace-space 0.46). Nonisolated statics so codex
    /// can unit-test tier mapping purely.
    nonisolated static let recipeThresholds: [String: (detected: Double, suspected: Double)] = [
        // Smoke-derived on DonnaTestVideos (AUC 0.995) — w600k ArcFace
        // via insightface, WITH sex gate.
        "recipe-v1-python": (detected: 0.55, suspected: 0.38),
        // Measured calibration sweep, native ArcFace CoreML path, small-
        // face bar 0.65, NO sex gate yet (AUC 0.954): 0.46 → 12/15
        // recall 0 FP on the dev corpus; 0.30 catches one more Donna
        // with 3 NotDonna landing in the maybe tier.
        "recipe-v1-native": (detected: 0.46, suspected: 0.30),
    ]

    /// Back-compat spellings (python-space) — several tests and the
    /// benchmark reference these directly.
    nonisolated static let recipeDetectedMinScore = 0.55
    nonisolated static let recipeSuspectedMinScore = 0.38

    /// Pure tier decision — "Donna*" vs "Donna?" vs nothing, in the
    /// given engine's score space. Unknown recipe IDs fail CLOSED to
    /// the python thresholds (strictest detected bar).
    nonisolated static func recipeTier(forScore score: Double,
                                       recipeID: String = "recipe-v1-python") -> RecipeTier {
        let t = recipeThresholds[recipeID] ?? (detected: recipeDetectedMinScore,
                                               suspected: recipeSuspectedMinScore)
        if score >= t.detected { return .detected }
        if score >= t.suspected { return .suspected }
        return .none
    }

    enum RecipeTier: String { case detected, suspected, none }

    /// Apply one FindPersonJob verdict to one record. MACHINE tiers only:
    /// - rejectedPeople veto → untouched (the "not Donna" must stick rule)
    /// - already user-confirmed → untouched (nothing to add)
    /// - detected tier → detectedPeople ("Donna*"), removed from suspected
    /// - suspected tier → suspectedPeople ("Donna?") unless already detected
    /// - .none → REMOVES any previous machine tags for this person (a
    ///   re-run with a better recipe may clear an old machine mistake;
    ///   Immich rescan rule — machine replaces machine, never human)
    /// Provenance stamp appended to machine `notes` on any change.
    /// Returns true when the record changed.
    @discardableResult
    func applyRecipeVerdict(person: String, record rec: VideoRecord,
                            score: Double, recipeID: String) -> Bool {
        func same(_ other: String) -> Bool {
            other.compare(person, options: .caseInsensitive) == .orderedSame
        }
        guard !rec.rejectedPeople.contains(where: same) else { return false }
        guard !rec.confirmedByUserPeople.contains(where: { same($0.name) }) else { return false }

        let tier = Self.recipeTier(forScore: score, recipeID: recipeID)
        let hadDetected = rec.detectedPeople.contains(where: same)
        let hadSuspected = rec.suspectedPeople.contains(where: same)
        var changed = false
        switch tier {
        case .detected:
            if !hadDetected { rec.detectedPeople.append(person); changed = true }
            if hadSuspected { rec.suspectedPeople.removeAll(where: same); changed = true }
        case .suspected:
            if !hadDetected, !hadSuspected {
                rec.suspectedPeople.append(person); changed = true
            }
        case .none:
            if hadDetected { rec.detectedPeople.removeAll(where: same); changed = true }
            if hadSuspected { rec.suspectedPeople.removeAll(where: same); changed = true }
        }
        if changed {
            let stamp = ISO8601DateFormatter().string(from: Date())
            let outcome = tier == .none ? "cleared" : "\(person)\(tier == .detected ? "*" : "?")"
            let line = "FindPerson(\(person)) \(recipeID) \(stamp): score \(String(format: "%.3f", score)) → \(outcome)"
            rec.notes = rec.notes.isEmpty ? line : rec.notes + "\n" + line
            finishPeopleMutation([rec])
        }
        return changed
    }
}
