// CatalogRowContextMenu+Observations.swift — the row menu's "Observations…"
// (Rick 2026-11-06): what the machine observed in the selected files, in the
// Observations window scoped to them (docs/design/file_dossier_view.md
// Part II). Reads only; the one door (ObservationsWindowController).

import SwiftUI

extension CatalogContent {

    /// In the `.find` group, after the find verbs: one item for the whole selection.
    @ViewBuilder
    func observationsItem(selectedRecs: [VideoRecord]) -> some View {
        Button(selectedRecs.count > 1 ? "Observations for \(selectedRecs.count) Files…" : "Observations…") {
            ObservationsWindowController.shared.show(model: model, scope: .files(selectedRecs.map { $0.id.uuidString }), source: "catalog-row")
        }
        .help("What the machine observed in these files — technical readings, eras, scenes, speech, on-screen text, people — searchable, read-only")
        .disabled(selectedRecs.isEmpty)
    }
}
