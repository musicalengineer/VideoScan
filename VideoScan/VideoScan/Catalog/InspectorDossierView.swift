import SwiftUI

// MARK: - Inspector Dossier section
//
// The inspector's Dossier section IS the file dossier view (docs/design/
// file_dossier_view.md §2, Rick 2026-11-05): three collapsed groups —
// Technical, Patterns & events, Across the collection — read from
// catalog.sqlite through the one door (FileDossierLoader.production). The
// lines this view used to draw from the record (inferred date, transcript,
// scene captions, usable OCR dates, OCR text, the dossier run) are layer 2's
// lines now, so nothing is lost and there is no second dossier view.
//
// Shown for every file (no longer only once the dossier pipeline has run):
// Technical always has the stored probe facts, and every missing analyzer
// says why in words.

struct InspectorDossierView: View {

    let record: VideoRecord
    let loader: FileDossierLoader

    var body: some View {
        FileDossierView(fileID: record.id, loader: loader)
    }
}
