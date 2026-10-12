// RemovalMarker+Presentation.swift
// Display words for the one removal marker (GH #143): what Show Removed
// says about a hidden row — In the Trash / Removed from the catalog /
// Missing — in family words, with the date. App-side, like the other
// ModelsUI presentation extensions, so the domain type in VideoScanCore
// stays Foundation-only. Pure: no disk access, safe to call from a view
// body for one visible row.

import Foundation
import VideoScanCore

extension RemovalMarker {

    /// The state alone: "In the Trash", "Removed from the catalog", "Missing".
    var stateWords: String {
        switch state {
        case .inTrash: return "In the Trash"
        case .removedFromCatalog: return "Removed from the catalog"
        case .missing: return "Missing"
        }
    }

    /// One sentence for the row's tooltip, e.g. "in the Trash since
    /// 11 Oct 2026 — the Trash has since been emptied".
    func sentence(dateStyle: Date.FormatStyle = .dateTime.day().month(.abbreviated).year()) -> String {
        let when = since.formatted(dateStyle)
        switch state {
        case .inTrash:
            return "in the Trash since \(when)"
                + (isTrashEmptied ? " — the Trash has since been emptied" : "")
        case .removedFromCatalog:
            // The old "Manually Deleted" label never moved a file (the 959
            // classification, 2026-10-11): say so, not "deleted".
            return reason == .legacyDeletedLabel
                ? "hidden by an old “deleted” label — the file was never moved"
                : "removed from the catalog on \(when) — the file was not touched"
        case .missing:
            return "missing since \(when)" + (lastSeen.map { " — last seen \($0.formatted(dateStyle))" } ?? "")
        }
    }
}
