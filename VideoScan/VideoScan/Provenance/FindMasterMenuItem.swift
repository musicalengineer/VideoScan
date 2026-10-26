// FindMasterMenuItem.swift — Catalog row menu ▸ Provenance ▸ Find Master.
// Design: docs/design/provenance_retroactive_2026_10_26.md §Phase A.
//
// A View, not a model extension (rule 12): on click it snapshots the
// selected records, builds the plan ONCE (O(records), in the action, never
// in the body) and starts the job on the MFO center. The job writes nothing.
// The menu name is Rick's to change; the answers never say which copy is
// the original.

import SwiftUI
import VideoScanCore

struct FindMasterMenuItem: View {
    /// NOT observed: the body reads no model state, so a catalog change must
    /// not re-render this menu (the click action reads the model once).
    /// (For Rick: a plain pointer member, not a subscription.)
    let model: VideoScanModel
    @Environment(\.mediaFileOperationsCenterReference) private var center
    let recordIDs: Set<UUID>

    var body: some View {
        Menu("Provenance") {
            Button("Find Master (sound)") { start() }
                .disabled(recordIDs.isEmpty)
                .help("Find every other content in the catalog whose sound lines up with the selected file(s): the same recording, a longer recording it sits inside, a clip of it, or a shared stretch. Uses the sound prints already made by Fingerprint Sound; writes nothing.")
        }
    }

    private func start() {
        let all = model.records
        let selected = all.filter { recordIDs.contains($0.id) }
        let plan = FindMasterPlan.make(selected: selected, all: all, isArchived: { model.isArchiveElement($0) })
        let directory = model.audioFingerprintSidecarDirectory
        _ = center?.startedByUser {
            $0.startFindMaster(plan: plan, sidecarDirectory: directory,
                               note: { [weak model] line in
                                   model?.log(line)
                                   if !line.hasPrefix("START "), !line.hasPrefix("OUTCOME ") { appLog.write(line) }
                               },
                               reveal: { [weak model] id in
                                   guard let model, model.canNavigateToRecord(id: id) else { return }
                                   UserDefaults.standard.set(1, forKey: "selectedTab")
                                   model.pendingCatalogSelection = id
                                   MainWindowHelper.shared.openMainWindow()
                               })
        }
    }
}
