// DeleteDuplicatesFlow.swift
// The Delete Duplicates FRONT DOOR, in one place (extracted 2026-10-03 from
// StorageReclaimableCard so the Triage tab's steward pane can open the very
// same door instead of growing a third copy of it):
//
//     volume picker (a drive preselected)  →  forecast confirmation  →
//     MediaFileOperationsCenter.startDeleteDuplicates(onVolume:model:)
//
// Behaviour-preserving: the sheet, the onDismiss hand-off (never an alert
// raised while the sheet is still up — the chained-sheet rule), the alert's
// text, the destructive button, its disabled rule and both app-log lines
// are the ones the Storage card had. Only the host's NAME in the two log
// lines is a parameter (`source`: "Storage tab", "Triage tab").
//
// Nothing here deletes anything. The job (DeleteDuplicatesJob), its plan,
// its sibling proof and its forecast are untouched; this file only decides
// WHEN the existing job is asked to start, exactly as before.
//
// One O(records) pass runs at CLICK time (`prepareConfirmation`, after the
// picker is dismissed) so the alert can state the mode, the split and the
// forecast honestly. Never in a view body.
//
// (For Rick: a `ViewModifier` ≈ a decorator object — it wraps the view it
// is applied to and owns its own @State, so two hosts share the code but
// not the state. `@Binding` ≈ a non-const reference to the host's variable.)

import SwiftUI

struct DeleteDuplicatesFlow: ViewModifier {
    @EnvironmentObject var model: VideoScanModel
    @Environment(\.mediaFileOperationsCenterReference) private var fileOpsCenterReference
    @Environment(\.openWindow) private var openWindow

    /// Set by the host to open the picker; cleared here when it closes.
    @Binding var picker: DeleteDuplicatesVolumePickerRequest?
    /// The drive the host already has in hand (shown first, "this drive").
    let preselectedPath: String?
    /// The host's name for the two app-log lines ("Storage tab").
    let source: String
    /// Called once the person has confirmed and the job was asked to start.
    var onStarted: ((_ volumePath: String) -> Void)?

    @State private var picked: CatalogDuplicatesMenu.Volume?
    @State private var showConfirm = false
    @State private var confirmVolume = ""
    @State private var confirmCount = 0
    @State private var confirmForecast = ""
    @State private var confirmSummary = ""
    @State private var confirmCrossMode = false
    /// GH #258: "2 copies left alone for the Archive Angel" — "" for none.
    @State private var confirmLeftAlone = ""

    func body(content: Content) -> some View {
        content
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
                        appLog.write("Delete Duplicates: picked \(vol.path) (\(vol.count) candidate(s)) in the volume picker (\(source))")
                        picked = vol
                        picker = nil
                    },
                    onCancel: {
                        picked = nil
                        picker = nil
                    },
                    preselectedPath: preselectedPath,
                    readOnlyVolumeNames: model.readOnlyVolumeNamesForPicker)
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
                    onStarted?(confirmVolume)
                }
                .disabled(model.isReadOnly || model.isDeletingDuplicates)
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(confirmMessage)
            }
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
        confirmLeftAlone = selection.leftAlone.line ?? ""
        let forecast = model.deleteDuplicatesForecast(onVolume: path)
        confirmForecast = forecast.confirmationText(volume: volumeName)
        appLog.write(forecast.logLine(volume: volumeName) + " (Start confirmation, \(source))")
        showConfirm = true
    }

    private var confirmMessage: String {
        let volume = URL(fileURLWithPath: confirmVolume).lastPathComponent
        var text = confirmForecast.isEmpty
            ? "Check \(confirmCount) high-confidence duplicate(s) on \(volume).\n\n"
            : confirmForecast + "\n\n"
        // The copies the run will not consider at all (GH #258).
        if !confirmLeftAlone.isEmpty { text += "Not part of this: \(confirmLeftAlone).\n\n" }
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

extension View {
    /// Attach the Delete Duplicates front door. Set `picker` to a new
    /// `DeleteDuplicatesVolumePickerRequest()` to open it.
    func deleteDuplicatesFlow(picker: Binding<DeleteDuplicatesVolumePickerRequest?>,
                              preselectedPath: String?,
                              source: String,
                              onStarted: ((_ volumePath: String) -> Void)? = nil) -> some View {
        modifier(DeleteDuplicatesFlow(picker: picker, preselectedPath: preselectedPath,
                                      source: source, onStarted: onStarted))
    }
}
