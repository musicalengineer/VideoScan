// CatalogRowContextMenu+Media.swift
// Get Info… / Verify… / Repair… of the Catalog row menu (R1 refactor,
// GH #281; was +Audio.swift until the 2026-10-07 consolidation folded
// Verify Audio + Verify Video into one Check Media…, renamed Verify… on
// 2026-10-08).
// (Swift extension ≈ C++ partial class via free member functions: no new
// stored state allowed, methods share the same `self`; `private` here
// means file-private to THIS file.)

import SwiftUI

extension CatalogContent {

    /// "Verify…" (renamed from "Check Media…", Rick 2026-10-08; that one
    /// replaced the separate Verify Audio and Verify Video verbs on
    /// 2026-10-07). Opens the quick / full choice (CheckMediaSheet); the
    /// run is ONE CheckMediaJob for the reachable rows. O(selection),
    /// never O(records).
    @ViewBuilder
    private func checkMediaMenuItem(activeRecs: [VideoRecord]) -> some View {
        // The label counts exactly the rows the action runs on (the
        // CatalogVerifyMenuPlan rule, stage-0 triage R4).
        let plan = CatalogVerifyMenuPlan(verb: "Verify", selection: activeRecs) {
            VolumeReachability.isReachable(path: $0.fullPath)
        }
        let checkable = plan.runnable
        Button(CatalogRowMenuText.verify(count: checkable.count)) {
            checkMediaRequest = CheckMediaRequest(records: checkable)
        }
        .disabled(plan.isDisabled)
        .help("Verify the file — picture, sound and timing — and say in plain words whether it is OK, has a warning, or has a problem, and what to do. Runs in the operations window; the catalog stays usable.")
        .accessibilityIdentifier("catalog.row.checkMedia")
    }

    /// "Repair…" (Rick 2026-10-08) — the one repair door: the plan, then
    /// ONE job writing ONE new file; the original is never changed.
    /// Enabled / disabled by MediaRepairPlan.menuState (one file, its drive
    /// connected; a card with nothing to fix says why). O(1).
    @ViewBuilder
    private func repairMenuItem(rec: VideoRecord, activeRecs: [VideoRecord]) -> some View {
        let state = MediaRepairPlan.menuState(
            card: rec.mediaReportCard, fileSizeBytes: rec.sizeBytes,
            sound: MediaRepairSoundFacts(diagnosis: fileOpsCenter.verifyDiagnosis(forRecordID: rec.id)),
            reachable: VolumeReachability.isReachable(path: rec.fullPath),
            selectionCount: activeRecs.count,
            lifecycle: hasRepairLifecycleAction(rec))
        Button(CatalogRowMenuText.repair) { presentRepair(for: rec) }
            .disabled(!state.isEnabled)
            .help(state.help)
            .accessibilityIdentifier("catalog.row.repair")
    }

    /// The sheet has a Link (damaged sound) or Confirm (awaiting copy)
    /// action for this row — the two lifecycle items that left the menu.
    private func hasRepairLifecycleAction(_ rec: VideoRecord) -> Bool {
        (rec.derivedFrom == nil && !CatalogRowMenuRules.damagedAudio([rec]).isEmpty)
            || (rec.isAwaitingConfirmation && rec.derivedFrom.flatMap { model.record(forID: $0) } != nil)
    }

    /// The Repair sheet for one record (the row menu and Get Info's banner).
    func presentRepair(for rec: VideoRecord) {
        repairSheetRequest = MediaRepairSheetRequest(
            record: rec,
            audioDiagnosis: fileOpsCenter.verifyDiagnosis(forRecordID: rec.id),
            onVerify: { checkMediaRequest = CheckMediaRequest(records: [rec]) },
            onSelectRecord: { id in
                selectedIDs = [id]
                onSelect(id)
            })
    }

    /// Get Info… / Verify… / Repair… — the `.inspect` group — extracted
    /// from the row context menu so the menu's ViewBuilder expression
    /// stays inside Xcode's type-check budget (the onlineCopyMenu
    /// precedent).
    ///
    ///   Get Info…  — instant facts sheet (single row).
    ///   Verify…    — the checks, as MFO jobs.
    ///   Repair…    — the one repair door: the fixes, Link Repaired
    ///                Copy…, and Sounds Good — Confirm Repair (GH #132)
    ///                all live in MediaRepairSheet since 2026-10-08.
    @ViewBuilder
    func mediaCheckMenuItems(rec: VideoRecord,
                             activeRecs: [VideoRecord]) -> some View {
        // Always available for a single row (Rick 2026-08-14, renamed
        // 2026-10-07 and 2026-10-08): instant, no media I/O beyond one
        // header probe.
        if activeRecs.count == 1 {
            Button(CatalogRowMenuText.getInfo) {
                presentMediaInfo(for: rec)
            }
            // Display only: in a context menu the shortcut is a hint; the
            // live ⌘I is File ▸ Get Info (CatalogInfoCommand.swift).
            .keyboardShortcut("i", modifiers: .command)
            .help("What this file is made of — container, picture, sound, timing — and the last Verify verdict.")
            .accessibilityIdentifier("catalog.row.getMediaInfo")
        }

        checkMediaMenuItem(activeRecs: activeRecs)
        repairMenuItem(rec: rec, activeRecs: activeRecs)

        // Repair Damaged Audio, Link Repaired Copy… and Sounds Good —
        // Confirm Repair moved behind Repair… (Rick 2026-10-08: "all
        // repair goes behind ONE door") — MediaRepairSheet.
    }

    /// Get Info… (the row menu and File ▸ Get Info ⌘I). Its
    /// Verify… button opens the quick/full choice for this file; its
    /// Sound Details… button (only with a session sound diagnosis) opens
    /// the Verify Audio results sheet with the Balance / Rebuild offers.
    func presentMediaInfo(for rec: VideoRecord) {
        let diagnosis = fileOpsCenter.verifyDiagnosis(forRecordID: rec.id)
        mediaInfoRequest = MediaInfoRequest(
            record: rec,
            audioDiagnosis: diagnosis,
            onCheckMedia: { checkMediaRequest = CheckMediaRequest(records: [rec]) },
            onRepair: { presentRepair(for: rec) },
            onSoundDetails: diagnosis.map { d in
                {
                    verifyAudioRequest = VerifyAudioRequest(
                        record: rec, diagnosis: d,
                        onFindMatchingAudio: { repairAudio(for: rec) })   // Combine sheet or alert; no job window (codex #964)
                }
            })
    }
}
