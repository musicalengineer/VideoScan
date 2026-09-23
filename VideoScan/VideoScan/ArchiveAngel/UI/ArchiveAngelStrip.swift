// ArchiveAngelStrip.swift
// The Archive Angel's whole presence in the Archive tab, as ONE view the tab
// places under its progress bar (public surface). Consolidation S2 moved it
// here from ArchiveView / ArchiveView+Table, unchanged: the assessment strip
// (grades, review chip, Prepare Batch…, Show in Catalog, ⋯), the unreadable
// row, the buffer-hygiene "What next?" card, the ready-batch disclosure, and
// the start + review sheets. The batches it shows are the façade's
// (`ArchiveAngel.batches`), refreshed by `refreshBatches` — never read in body.
//
// Both sheets are `.sheet(item:)` with struct payloads (the chained-sheet
// rule — never two `.sheet(isPresented:)` in a row).

import SwiftUI

struct ArchiveAngelStrip: View {
    // Forwarded to the two sheets (sheets are given their objects
    // explicitly, as ArchiveView did before S2) — intentional.
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject var model: VideoScanModel
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject var fileOpsCenter: MediaFileOperationsCenter
    @ObservedObject var angel: ArchiveAngel
    /// Land the Archive tab on the Archived column — the start sheet's
    /// hygiene banner ("Show them") ends there, where the card lives.
    let revealArchived: () -> Void

    /// Archive Angel (2026-09-09): Stage 1 entry sheet + Stage 2 review sheet.
    @State private var startRequest: ArchiveAngelStartRequest?
    @State private var reviewRequest: ArchiveAngelReviewRequest?

    var body: some View {
        VStack(spacing: 0) {
            // Archive Angel — ONE strip (Rick 2026-09-22): grades, the
            // review chip, Prepare Batch…, Show in Catalog, ⋯ sweep
            // controls. Moved here from the sidebar.
            ArchiveAngelAssessmentPanel(
                angel: angel,
                store: angel.store,
                sweep: angel.sweep,
                prepare: { startRequest = ArchiveAngelStartRequest() },
                review: angel.batches.ready.first.map { (ready: $0.readyCount, batches: angel.batches.ready.count) },
                openReview: { openNewestBatch() })
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            if !angel.batches.unreadable.isEmpty {
                ArchiveAngelUnreadableRow(batches: angel.batches.unreadable)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            // Buffer hygiene (curation Phase 2, Rick 2026-09-19): when
            // prepared batches are waiting in the buffer, or finished
            // ones still hold files, ask "What next?" before anything.
            if !angel.batches.hygiene.isEmpty {
                ArchiveAngelBufferHygieneCard(
                    report: angel.batches.hygiene,
                    openReview: { reviewRequest = ArchiveAngelReviewRequest(plan: $0) },
                    batchesChanged: { angel.refreshBatches(reason: "buffer changed (hygiene card)") })
            }
            // Archive Angel's PREPARED batch sits above the loose nudge
            // (Rick 2026-09-09: "10 are actually preprocessed and really
            // ready" must catch the eye before "it looks like 598…").
            if let batch = angel.batches.ready.first {
                ArchiveAngelReadyDisclosure(
                    plan: batch,
                    openReview: { openNewestBatch() },
                    batchesChanged: { angel.refreshBatches(reason: "batch changed (ready disclosure)") })
                    // Re-seed the row's @State when the sheet edited the same
                    // batch (same id, different content) — cheap fingerprint.
                    .id("\(batch.id)-\(batch.status.rawValue)-" + batch.entries.map {
                        "\($0.id)\($0.selected)\($0.filename)\($0.proposedName)\($0.proposedDate ?? "")\($0.status.rawValue)"
                    }.joined().hashValue.description)
            }
        }
        .sheet(item: $startRequest) { _ in
            ArchiveAngelStartSheet(angel: angel, hygiene: angel.batches.hygiene, revealHygiene: {
                angel.revealHygiene()
                revealArchived()
            })
                .environmentObject(model)
                .environmentObject(fileOpsCenter)
        }
        .sheet(item: $reviewRequest, onDismiss: { angel.refreshBatches(reason: "review sheet closed") }) { req in
            ArchiveAngelReviewSheet(plan: req.plan)
                .environmentObject(model)
                .environmentObject(fileOpsCenter)
        }
    }

    private func openNewestBatch() {
        guard let newest = angel.batches.ready.first else { return }
        reviewRequest = ArchiveAngelReviewRequest(plan: newest)
    }
}
