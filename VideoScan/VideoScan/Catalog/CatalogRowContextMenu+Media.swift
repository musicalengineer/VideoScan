// CatalogRowContextMenu+Media.swift
// Get Media Info… / Check Media… and the repair-lifecycle items of the
// Catalog row menu, plus the Link Repaired Copy handler (R1 refactor,
// GH #281; was +Audio.swift until the 2026-10-07 consolidation folded
// Verify Audio + Verify Video into one Check Media…).
// (Swift extension ≈ C++ partial class via free member functions: no new
// stored state allowed, methods share the same `self`; `private` here
// means file-private to THIS file.)

import SwiftUI

extension CatalogContent {

    /// "Check Media…" (Rick 2026-10-07) — replaces the separate Verify
    /// Audio and Verify Video verbs. Interim (Phase 1): dispatches the two
    /// existing verify jobs per reachable row (audio where there is sound,
    /// picture where there is a picture), into the MFO window, any
    /// selection size. O(selection), never O(records).
    @ViewBuilder
    private func checkMediaMenuItem(activeRecs: [VideoRecord]) -> some View {
        // The label counts exactly the rows the action runs on (the
        // CatalogVerifyMenuPlan rule, stage-0 triage R4).
        let plan = CatalogVerifyMenuPlan(verb: "Check Media", selection: activeRecs) {
            VolumeReachability.isReachable(path: $0.fullPath)
        }
        let checkable = plan.runnable
        Button(CatalogRowMenuText.checkMedia(count: checkable.count)) {
            // One scope for the whole selection: N jobs, one raise.
            fileOpsCenter.startedByUser { center in
                for r in checkable {
                    model.noteMissingFileForUserAction(r)
                    if CatalogRowMenuRules.hasAudio(r.streamType) {
                        center.startVerifyAudio(record: r, model: model)
                    }
                    if r.streamType != .audioOnly {
                        center.startVerifyVideo(record: r, model: model)
                    }
                }
            }
            MediaFileOperationsWindowOpener.openBehindMain(openWindow)
        }
        .disabled(plan.isDisabled)
        .help("Check the file — picture, sound and timing — and say in plain words whether it is OK, has a warning, or has a problem, and what to do. Runs in the operations window; the catalog stays usable.")
        .accessibilityIdentifier("catalog.row.checkMedia")
    }

    /// Get Media Info… / Check Media… + the repair-lifecycle cluster
    /// (GH #128 / #132 / #135), extracted from the row context menu so
    /// the menu's ViewBuilder expression stays inside Xcode's type-check
    /// budget (the onlineCopyMenu precedent).
    ///
    ///   Get Media Info…             — instant facts sheet (single row).
    ///   Check Media…                — the checks, as MFO jobs.
    ///   Repair Damaged Audio (N)    — re-verify each damaged row and
    ///     chain into Rebuild Audio Track when the damage is the
    ///     repairable codec class (GH #132 P1).
    ///   Link Repaired Copy…         — adopt an externally repaired file.
    ///   Sounds Good — Confirm Repair — the lifecycle heart (GH #132
    ///     P2): Confirm stamps both records, human metadata carries
    ///     over, the original is retired (hidden, never deleted).
    @ViewBuilder
    func mediaCheckMenuItems(rec: VideoRecord,
                             activeRecs: [VideoRecord],
                             pureActive: Bool) -> some View {
        Divider()

        // Always available for a single row (Rick 2026-08-14, renamed
        // 2026-10-07): instant, no media I/O beyond one header probe.
        if activeRecs.count == 1 {
            Button("Get Media Info\u{2026}") {
                verifyAudioRequest = VerifyAudioRequest(
                    record: rec,
                    diagnosis: fileOpsCenter.verifyDiagnosis(forRecordID: rec.id),
                    onFindMatchingAudio: {
                        repairAudio(for: rec)   // Combine sheet or alert is the result; no job window (codex #964)
                    })
            }
            .help("What this file is made of — container, picture, sound, timing — and the last Check Media verdict.")
            .accessibilityIdentifier("catalog.row.getMediaInfo")
        }

        checkMediaMenuItem(activeRecs: activeRecs)

        let reachable = activeRecs.filter { VolumeReachability.isReachable(path: $0.fullPath) }
        let damagedRecs = CatalogRowMenuRules.damagedAudio(reachable)
        if !damagedRecs.isEmpty {
            Button(CatalogRowMenuText.repairDamagedAudio(count: damagedRecs.count)) {
                _ = fileOpsCenter.startedByUser { center in
                    for r in damagedRecs {
                        center.startVerifyAudio(record: r, model: model, autoRepair: true)
                    }
                }
                MediaFileOperationsWindowOpener.openBehindMain(openWindow)
            }
            .help("Re-check each damaged file and, where the damage is fixable (an old sound format), rebuild a repaired copy next to the original. Originals are never changed.")
            .accessibilityIdentifier("catalog.row.repairDamagedAudio")
        }

        // Link Repaired Copy… (GH #132 P4) — Rick fixed the file
        // himself in another tool; adopt that file as this damaged
        // record's repaired copy (same two-way provenance the in-app
        // rebuild writes; enters the awaiting-confirmation state).
        if pureActive, activeRecs.count == 1,
           rec.audioVerifyStatus == "damaged" {
            Button("Link Repaired Copy…") {
                linkRepairedCopy(for: rec)
            }
            .help("Already repaired this file with another tool? Pick that repaired file and it joins the catalog as this one's repaired copy — then confirm it when it sounds right.")
            .accessibilityIdentifier("catalog.row.linkRepairedCopy")
        }

        let awaitingRecs = pureActive
            ? activeRecs.filter {
                $0.isAwaitingConfirmation
                    && $0.derivedFrom.flatMap { model.record(forID: $0) } != nil
            }
            : []
        if !awaitingRecs.isEmpty {
            Button(CatalogRowMenuText.confirmRepairs(count: awaitingRecs.count)) {
                _ = model.confirmRepairs(
                    repairIDs: Set(awaitingRecs.map(\.id)))
            }
            .help("You've listened and it sounds right: keep this repaired copy as the one to use. The original is hidden from the everyday view — never deleted — and your tags, notes, people, and ratings carry over.")
            .accessibilityIdentifier("catalog.row.confirmRepair")
        }
    }

    /// "Link Repaired Copy…" handler (GH #132 P4): pick the externally-
    /// repaired file, adopt it onto the damaged record, and select the
    /// new row. Failures (unreadable file, vanished original) alert with
    /// the model's family-language message and change nothing.
    private func linkRepairedCopy(for rec: VideoRecord) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the repaired copy of \(rec.filename)"
        panel.prompt = "Link Repaired Copy"
        panel.directoryURL = URL(fileURLWithPath: rec.directory, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                let newRec = try await model.adoptExternalRepair(
                    originalID: rec.id, fileURL: url)
                selectedIDs = [newRec.id]
                onSelect(newRec.id)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't Link the Repaired Copy"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
}
