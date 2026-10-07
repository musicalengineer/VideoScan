// CatalogRowContextMenu+Audio.swift
// Verify Audio / Verify Video and the repair-lifecycle items of the
// Catalog row menu, plus the Link Repaired Copy handler — moved verbatim
// out of CatalogContent+Table.swift (R1 refactor, GH #281).
// (Swift extension ≈ C++ partial class via free member functions: no new
// stored state allowed, methods share the same `self`; `private` here
// means file-private to THIS file.)

import SwiftUI

extension CatalogContent {

    /// "Verify Video" (Rick 2026-09-23) — Verify Audio's picture-side
    /// sibling, dispatched identically: one VerifyVideoJob per reachable
    /// selected row with a picture, into the MFO window, any selection
    /// size (the full decode reads the whole file, so never a sheet). No
    /// ellipsis: nothing opens before the action (macOS convention; Verify
    /// Audio has none either). Audio-only rows are skipped and the item
    /// greys out when nothing selected has a picture — O(selection), never
    /// O(records).
    @ViewBuilder
    private func verifyVideoMenuItem(activeRecs: [VideoRecord]) -> some View {
        let plan = CatalogVerifyMenuPlan(verb: "Verify Video", selection: activeRecs) {
            $0.streamType != .audioOnly
                && VolumeReachability.isReachable(path: $0.fullPath)
        }
        let verifiableRecs = plan.runnable
        Button(plan.label) {
            fileOpsCenter.startedByUser { center in
                for r in verifiableRecs {
                    model.noteMissingFileForUserAction(r)
                    center.startVerifyVideo(record: r, model: model)
                }
            }
            MediaFileOperationsWindowOpener.openBehindMain(openWindow)
        }
        .disabled(plan.isDisabled)
        .help("Check the picture — does every frame decode, are the timing and frame rate sane, is the file a sensible size for its picture? Says OK, Warning or Broken, and what to do. Runs in the operations window; the catalog stays usable.")
        .accessibilityIdentifier("catalog.row.verifyVideo")
    }

    /// Verify Audio + repair-lifecycle context-menu cluster (GH #128 /
    /// #132 / #135), extracted from the row context menu so the menu's
    /// ViewBuilder expression stays inside Xcode's type-check budget
    /// (the onlineCopyMenu precedent).
    ///
    ///   Verify Audio (N Files)      — dispatch VerifyAudioJob rows to
    ///     the MFO window for ANY selection size. The levels pass
    ///     decodes the whole track (minutes on long tapes), so it must
    ///     never block the catalog in a modal sheet (GH #135).
    ///   Verification Results…       — instant presentation of the
    ///     already-computed diagnosis; the sheet performs NO probe and
    ///     NO levels decode (its request type requires a diagnosis).
    ///   Repair Damaged Audio (N)    — re-verify each damaged row and
    ///     chain into Rebuild Audio Track when the damage is the
    ///     repairable codec class (GH #132 P1).
    ///   Sounds Good — Confirm Repair — the lifecycle heart (GH #132
    ///     P2): Confirm stamps both records, human metadata carries
    ///     over, the original is retired (hidden, never deleted). The
    ///     banner above the table offers one-tap undo.
    @ViewBuilder
    func audioLifecycleMenuItems(rec: VideoRecord,
                                         activeRecs: [VideoRecord],
                                         pureActive: Bool) -> some View {
        let plan = CatalogVerifyMenuPlan(verb: "Verify Audio", selection: activeRecs) {
            VolumeReachability.isReachable(path: $0.fullPath)
        }
        let verifiableRecs = plan.runnable
        Button(plan.label) {
            // One scope for the whole selection: N jobs, one raise.
            fileOpsCenter.startedByUser { center in
                for r in verifiableRecs {
                    model.noteMissingFileForUserAction(r)
                    center.startVerifyAudio(record: r, model: model)
                }
            }
            MediaFileOperationsWindowOpener.openBehindMain(openWindow)
        }
        .disabled(plan.isDisabled)
        .help("Check the sound track — levels, format, and whether the audio really belongs to the picture. Runs in the operations window; the catalog stays usable.")
        .accessibilityIdentifier("catalog.row.verifyAudio")

        // Verify Video — right beside Verify Audio, built the same way
        // (Rick 2026-09-23).
        verifyVideoMenuItem(activeRecs: activeRecs)

        // Always available for a single row (Rick 2026-08-14): with a
        // cached Verify Audio diagnosis the sheet shows findings; without
        // one it shows the catalog's ffprobe basics (codec, channels,
        // sample rate, bit depth) — instant either way, no media I/O.
        if activeRecs.count == 1 {
            Button("Audio Info…") {
                verifyAudioRequest = VerifyAudioRequest(
                    record: rec,
                    diagnosis: fileOpsCenter.verifyDiagnosis(forRecordID: rec.id),
                    onFindMatchingAudio: {
                        repairAudio(for: rec)   // Combine sheet or alert is the result; no job window (codex #964)
                    })
            }
            .help("Audio properties from the catalog — plus Verify Audio findings and any repair offer when a check has run.")
            .accessibilityIdentifier("catalog.row.verifyResults")
        }

        let damagedRecs = CatalogRowMenuRules.damagedAudio(verifiableRecs)
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
