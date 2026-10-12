// FullHashBackfillMenuItem.swift
// Catalog ▸ "Fill In Full Hashes…" (Rick 2026-10-11) — starts the
// whole-catalog full-hash backfill as a Media File Operation (the MFO window
// comes forward via `startedByUser`). While the last run is unfinished the
// title reads "Resume Filling In Full Hashes…" — same job: a record whose
// hash was saved is skipped, so starting again IS the resume. Never starts
// on its own.

import SwiftUI

struct FullHashBackfillMenuItem: View {
    let model: VideoScanModel
    let center: MediaFileOperationsCenter
    @ObservedObject var marker: FullHashBackfillResumeMarker
    let isReadOnly: Bool

    var body: some View {
        Button(marker.menuTitle) {
            _ = center.startedByUser { $0.startFullHashBackfill(model: model, marker: marker) }
        }
        .disabled(isReadOnly)
        .help("Read every catalog file that has no full SHA-256 yet, in full, and keep its hash — one reader per drive, drives in parallel. Read only on media: nothing is moved, renamed or deleted. Safe to stop: running it again continues where it stopped.")
    }
}
