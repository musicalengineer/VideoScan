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
// did. "Also clean up working copies" moved here from the old Duplicates
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
    @Environment(\.openWindow) private var openWindow

    let volumePath: String
    let isReachable: Bool
    let estimate: ReclaimableEstimate?

    // Delete flow state (mirrors CatalogView's; see the file header).
    @State private var picker: DeleteDuplicatesVolumePickerRequest?
    @State private var picked: CatalogDuplicatesMenu.Volume?
    @State private var showConfirm = false
    @State private var confirmVolume = ""
    @State private var confirmCount = 0
    @State private var confirmForecast = ""
    @State private var confirmSummary = ""
    @State private var confirmCrossMode = false

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
        .sheet(item: $picker, onDismiss: {
            // Runs after the sheet is fully dismissed, so the alert never
            // races the sheet (the chained-sheet antipattern).
            guard let vol = picked else { return }
            picked = nil
            prepareConfirmation(path: vol.path, count: vol.count)
        }) { _ in
            DeleteDuplicatesVolumePicker(
                volumes: model.deletableDupVolumes.map { CatalogDuplicatesMenu.Volume(path: $0.path, count: $0.count) },
                onPick: { vol in
                    appLog.write("Delete Duplicates: picked \(vol.path) (\(vol.count) candidate(s)) in the volume picker (Storage tab)")
                    picked = vol
                    picker = nil
                },
                onCancel: {
                    picked = nil
                    picker = nil
                },
                preselectedPath: deletableHere?.path)
        }
        .alert("Delete Duplicates", isPresented: $showConfirm) {
            Button(DeleteDuplicatesForecast.confirmationButtonTitle, role: .destructive) {
                // A Media File Operation since 2026-09-20 — the job is
                // unchanged; only the button moved.
                guard let center = fileOpsCenterReference else {
                    model.log("Delete Duplicates: not started — Media File Operations is not available in this window.")
                    return
                }
                _ = center.startedByUser { $0.startDeleteDuplicates(onVolume: confirmVolume, model: model) }
                MediaFileOperationsWindowOpener.openInFront(openWindow)
            }
            .disabled(model.isReadOnly || model.isDeletingDuplicates)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(confirmMessage)
        }
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
                      ? "Re-check this drive's files for duplicates now. (Phase A: this clears and redoes this drive's duplicate marks — the catalog-wide pass in the Analyze panel is the incremental one.)"
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
        picked = nil
        picker = DeleteDuplicatesVolumePickerRequest()
    }

    /// One O(records) pass at CLICK time (not in a body) so the alert can
    /// state the mode, the split and the forecast honestly — the same
    /// text CatalogView built.
    private func prepareConfirmation(path: String, count: Int) {
        confirmVolume = path
        confirmCount = count
        let volumeName = URL(fileURLWithPath: path).lastPathComponent
        let selection = model.duplicateDeletionSelection(onVolume: path)
        confirmSummary = selection.confirmationText(volumeName: volumeName)
        confirmCrossMode = selection.crossVolumeMode
        let forecast = model.deleteDuplicatesForecast(onVolume: path)
        confirmForecast = forecast.confirmationText(volume: volumeName)
        appLog.write(forecast.logLine(volume: volumeName) + " (Start confirmation, Storage tab)")
        showConfirm = true
    }

    private var confirmMessage: String {
        let volume = URL(fileURLWithPath: confirmVolume).lastPathComponent
        var text = confirmForecast.isEmpty
            ? "Check \(confirmCount) high-confidence duplicate(s) on \(volume).\n\n"
            : confirmForecast + "\n\n"
        if confirmCrossMode {
            text += "\(confirmSummary)\n\n"
            text += WorkingCopyCleanupText.confirmationOn + "\n\n"
        } else {
            text += WorkingCopyCleanupText.confirmationOff(volume: volume) + "\n\n"
        }
        text += "Are you sure? Do you have backups and/or are these really junk or duplicates?"
        return text
    }
}
