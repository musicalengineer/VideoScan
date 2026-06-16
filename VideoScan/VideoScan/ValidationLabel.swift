// ValidationLabel.swift
// One row of training data produced by the Confirm-Person workflow.
// Persisted to a sidecar JSON (`validation_labels.json`) NEXT TO the
// catalog, deliberately separate from VideoRecord so:
//   - Labels survive catalog rebuilds / wipes (training data isn't
//     coupled to whatever schema VideoRecord happens to have).
//   - We can prune / version / audit the training set without
//     touching the live catalog.
//   - A future classifier can train on labels >6 months old, OR filter
//     to recent ones for drift mitigation — call site's choice.
//
// Rick 2026-06-16.

import Foundation

struct ValidationLabel: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    /// fullPath of the labeled VideoRecord at label time. We key by
    /// path (not record UUID) because record IDs are not stable across
    /// catalog rebuilds, but a file's fullPath usually is — and when
    /// it isn't (Relocate run), originalFullPath preserves the lineage.
    let recordPath: String
    /// Person name the user was confirming. Case preserved for display;
    /// matching is case-insensitive in the store.
    let person: String
    let rating: ConfirmRating
    let labeledAt: Date
    /// The catalog signals that surfaced this candidate to the user
    /// (filename, transcript×N, PF-tagged, etc.). Preserved so a
    /// future analyst can compute precision-by-signal — i.e. "Whisper
    /// transcript mentions were 87% precise for Donna; PF-tagged were
    /// 53% precise" — which is the lever for deciding whether to
    /// retire PF or fix it.
    let signals: [String]
    /// Score at label time. Lets the analyst stratify accuracy by
    /// confidence and decide where to set the auto-confirm threshold.
    let score: Int
}
