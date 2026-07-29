// CatalogLivePreview.swift
// Pure logic for "live preview follows selection" in the Catalog table
// (2026-07-28). Two testable seams, zero I/O, zero AppKit:
//
//   1. CatalogLivePreview — the selection→preview-path resolver. Given
//      the current selection and the table's rows (in table order), it
//      answers "which media file should the live preview show?" — or nil
//      when nothing previewable is selected (audio-only / offline /
//      empty selection → Space no-ops).
//
//   2. LivePreviewMode — the mode state machine. Spacebar toggles it;
//      while ON, a selection change restarts the filmstrip for the new
//      row; the Stop button exits the mode. It only ever RETURNS the
//      action the view must perform (start/stop/none) — it never touches
//      the model, so it unit-tests without a running app.
//
// For Rick: this is the classic "extract the decision from the widget"
// move — like pulling business logic out of a C++ dialog's message
// handler into a free function so it can be tested headless. The view
// keeps only the AppKit/model plumbing; the branching lives here.

import Foundation

// MARK: - Selection → preview-path resolver

/// Namespace (a caseless `enum` ≈ a C++ struct of only static members —
/// it can't be instantiated) for the pure "what should preview" decision.
enum CatalogLivePreview {

    /// One row's contribution to the decision: its id, media path, and
    /// whether it can be previewed at all. `isPreviewable` folds in the
    /// runtime bits (stream type + volume reachability) at the call site
    /// so this type stays a plain value the tests can hand-build.
    struct Candidate: Equatable {
        let id: UUID
        let path: String
        let isPreviewable: Bool
    }

    /// Whether a row can drive the live preview. Video-bearing AND on a
    /// mounted volume. Audio-only / no-A-V / offline → false, so Space
    /// (and arrow-follow) no-op gracefully rather than ripping nothing.
    static func isPreviewable(streamType: StreamType, reachable: Bool) -> Bool {
        guard reachable else { return false }
        return streamType == .videoAndAudio || streamType == .videoOnly
    }

    /// The media path the live preview should show for this selection, or
    /// nil if nothing previewable is selected.
    ///
    /// Contract: the "primary" of a selection is the FIRST selected row in
    /// TABLE ORDER (not Set iteration order, which is non-deterministic).
    /// For a single-row selection — the arrow-navigation and normal case —
    /// that's simply the selected row. For a multi-row selection, Space
    /// acts on the top-most selected row, and returns its path only if it
    /// is previewable (else nil → no-op). The `orderedCandidates` sequence
    /// is consumed lazily and short-circuits at the first selected row, so
    /// the caller can pass a `.lazy` map over the whole table without doing
    /// O(records) work per keystroke.
    static func previewPath<S: Sequence>(orderedCandidates: S,
                                         selectedIDs: Set<UUID>) -> String?
        where S.Element == Candidate {
        for candidate in orderedCandidates where selectedIDs.contains(candidate.id) {
            return candidate.isPreviewable ? candidate.path : nil
        }
        return nil
    }
}

// MARK: - Preview-follows-selection mode state machine

/// What the view must do to the preview surface in response to a mode
/// event. `start` carries the path to preview; `stop` tears the current
/// preview down; `none` means "leave the preview exactly as it is".
/// Swift enum-with-payload ≈ a C++ tagged union the compiler forces every
/// caller to switch over exhaustively.
enum LivePreviewAction: Equatable {
    case none
    case start(String)
    case stop
}

/// The "preview follows selection" mode. Holds whether the mode is armed
/// and which path is currently showing, and turns the three UI events
/// (Space toggle, selection change, external Stop) into a `LivePreviewAction`.
///
/// It is deliberately model-free: every method is a pure transition that
/// returns the side effect for the caller to perform. That is the whole
/// reason it can be unit-tested without a view or a VideoScanModel.
struct LivePreviewMode: Equatable {

    /// True while arrow-follow is armed.
    private(set) var isActive = false

    /// Path currently being previewed (nil when inactive, or when the
    /// mode is armed but the current selection has nothing previewable).
    private(set) var activePath: String?

    /// Spacebar. `candidatePath` = the previewable path for the current
    /// selection (nil = nothing previewable). Off→On starts the preview
    /// and arms follow-mode; On→Off stops the preview and disarms. Pressing
    /// Space with nothing previewable selected is a no-op (stays Off).
    mutating func toggle(candidatePath: String?) -> LivePreviewAction {
        if isActive {
            isActive = false
            activePath = nil
            return .stop
        }
        guard let path = candidatePath else {
            // Nothing previewable under the cursor — don't arm on nothing.
            return .none
        }
        isActive = true
        activePath = path
        return .start(path)
    }

    /// Selection changed (arrow keys / click). Only does anything while
    /// armed. Moving to a new previewable row restarts the filmstrip for
    /// it; re-landing on the SAME path is a no-op (no needless re-rip);
    /// moving to a non-previewable row stops the current preview but keeps
    /// the mode armed, so arrowing onward to a video row resumes.
    mutating func selectionChanged(candidatePath: String?) -> LivePreviewAction {
        guard isActive else { return .none }
        guard let path = candidatePath else {
            // Non-previewable row while armed: clear the surface, stay armed.
            if activePath == nil { return .none }
            activePath = nil
            return .stop
        }
        if path == activePath { return .none }
        activePath = path
        return .start(path)
    }

    /// External Stop (the preview pane's Stop button). Exits the mode
    /// entirely and tears the preview down.
    mutating func stop() -> LivePreviewAction {
        let wasShowing = isActive || activePath != nil
        isActive = false
        activePath = nil
        return wasShowing ? .stop : .none
    }
}
