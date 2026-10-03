// StorageReclaimableCard.swift
// The Storage tab's "Reclaimable" card for ONE drive (Phase A trial,
// 2026-10-02; design §3.1 — Rick: "I see tons of file usage and I want to
// know: how many dups do I have, can I clean some of this up?"):
//
//   ┌─ Reclaimable ──────────────────────────────────────────────┐
//   │ 412 GB in 1,208 duplicate copies on this drive              │
//   │ each has 3+ verified copies elsewhere          (estimate)   │
//   │ Duplicate knowledge: current · last checked 2 h ago [Update]│
//   │ ☐ Also clean up working copies                              │
//   │ Only copies with at least 3 verified copies remaining …     │
//   │                              [ Delete duplicates here… ]    │
//   └─────────────────────────────────────────────────────────────┘
//
// Delete belongs where its operand lives: the button runs TODAY's flow —
// the volume picker (this drive preselected) → the forecast confirmation
// → DeleteDuplicatesJob, unchanged (sibling proof at delete time,
// checkpoints, Trash first). Nothing about safety moves; only the button
// did. The flow itself is the shared `deleteDuplicatesFlow` modifier
// (MediaOps/DeleteDuplicatesFlow.swift). "Also clean up working copies" moved here from the old Duplicates
// menu (same persisted setting as the Volumes sheet).
//
// "Update" re-checks duplicates for this drive's records through the
// existing `analyzeDuplicates(selectedIDs:)` "redo these" path — which
// CLEARS and REDOES those records (the catalog-wide pass is the
// incremental one; a volume scope is a Phase C item).
//
// The numbers come from ReclaimableCalculator (off-main, cached by the
// parent VolumeDetailPane, refreshed on catalog mutation). This view does
// NO O(records) work. The survival rule is quoted from
// DeletionTierDecision, not paraphrased.
//
// (For Rick: `@Environment(\.mediaFileOperationsCenterReference)` ≈ a
// pointer to the job center WITHOUT subscribing to its change signal.)

import SwiftUI

struct StorageReclaimableCard: View {
    @EnvironmentObject var model: VideoScanModel
    @Environment(\.mediaFileOperationsCenterReference) private var fileOpsCenterReference

    let volumePath: String
    let isReachable: Bool
    let estimate: ReclaimableEstimate?

    // The Delete front door (picker → forecast → job) lives in
    // DeleteDuplicatesFlow.swift since 2026-10-03, shared with the Triage
    // tab's steward pane; this card only asks it to open.
    @State private var picker: DeleteDuplicatesVolumePickerRequest?

    /// The count the Delete flow itself would offer for this drive — the
    /// model's cached menu payload (O(volumes), computed off the debounced
    /// catalog-change pass; never from `records` here).
    private var deletableHere: CatalogDuplicatesMenu.Volume? {
        model.deletableDupVolumes
            .first { VolumeDashboardCalculator.normalizedRoot($0.path) == VolumeDashboardCalculator.normalizedRoot(volumePath) }
            .map { CatalogDuplicatesMenu.Volume(path: $0.path, count: $0.count) }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                headline
                knowledgeLine
                Toggle(WorkingCopyCleanupText.toggleLabel, isOn: Binding(
                    get: { model.duplicateKeeperSettings.alsoCleanUpWorkingCopies },
                    set: { on in
                        model.duplicateKeeperSettings.alsoCleanUpWorkingCopies = on
                        model.noteDuplicateKeeperSettingsChanged()
                    }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help(WorkingCopyCleanupText.caption(volume: VolumeReachability.displayLabel(forPath: volumePath)))
                    .disabled(model.isReadOnly)
                    .accessibilityIdentifier("storage.reclaimable.workingCopies")
                Text(ReclaimableEstimate.survivalRule)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("storage.reclaimable.rule")
                HStack {
                    Text(ReclaimableEstimate.estimateNote)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Delete duplicates here…") { startDeleteFlow() }
                        .disabled(deleteDisabled)
                        .help(deleteHelp)
                        .accessibilityIdentifier("storage.reclaimable.delete")
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
        } label: {
            Label("Reclaimable", systemImage: "arrow.3.trianglepath")
                .font(.headline)
        }
        .accessibilityIdentifier("storage.reclaimable")
        .deleteDuplicatesFlow(picker: $picker, preselectedPath: deletableHere?.path, source: "Storage tab")
    }

    // MARK: Lines

    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(estimate?.headline ?? "Counting duplicate copies…")
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .accessibilityIdentifier("storage.reclaimable.headline")
            if let e = estimate, !e.copiesLine.isEmpty {
                Text(e.copiesLine + "  ·  estimate")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("storage.reclaimable.copies")
            }
            if let here = deletableHere, let e = estimate, here.count != e.copies {
                // The Delete flow's own count differs from the estimate
                // (keeper-policy verdicts, archive protection): say so.
                Text("The Delete step would check \(here.count.formatted()) of these.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var knowledgeLine: some View {
        HStack(spacing: 8) {
            Text(estimate?.knowledgeLine(policyStale: model.isDuplicateKeeperPolicyStale) ?? "Duplicate knowledge: counting…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("storage.reclaimable.knowledge")
            Button(model.isAnalyzingDuplicates ? "Updating…" : "Update") { update() }
                .controlSize(.small)
                .disabled(model.isAnalyzingDuplicates || model.isReadOnly || !isReachable)
                .help(isReachable
                      ? "Re-check this drive's files for duplicates now — from scratch: their duplicate marks are cleared and redone. (The catalog-wide Run now in the Analyze panel only checks new files.)"
                      : "Drive not connected.")
                .accessibilityIdentifier("storage.reclaimable.update")
        }
    }

    private var deleteDisabled: Bool {
        model.isReadOnly || model.isDeletingDuplicates || !isReachable || deletableHere == nil
    }

    private var deleteHelp: String {
        if model.isReadOnly { return "The catalog is read-only." }
        if model.isDeletingDuplicates { return "A Delete Duplicates run is already going — see Media File Operations." }
        if !isReachable { return "Drive not connected." }
        if deletableHere == nil { return "No duplicate copies on this drive can be deleted right now." }
        return "Check and remove this drive's proven duplicate copies. The next step shows the forecast and asks again."
    }

    // MARK: Actions

    private func update() {
        AnalyzeRunner(model: model, orchestrator: nil, center: fileOpsCenterReference)
            .runNow(.duplicates, volume: volumePath, source: "storage card")
    }

    private func startDeleteFlow() {
        picker = DeleteDuplicatesVolumePickerRequest()
    }
}
