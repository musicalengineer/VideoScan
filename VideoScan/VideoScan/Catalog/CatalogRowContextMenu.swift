// CatalogRowContextMenu.swift
// The Catalog files table's right-click menus — moved verbatim out of
// CatalogContent+Table.swift (R1 refactor, GH #281). The table itself,
// its columns and the ⌘⌫ / ⌘O handlers stay in that file.
// (Swift extension ≈ C++ partial class via free member functions: no new
// stored state allowed, methods share the same `self`; `private` here
// means file-private to THIS file.)

import SwiftUI

extension CatalogContent {

    /// Right-click menu shown when one or more purged rows is selected.
    /// Per spec, this is intentionally minimal: Restore + Reveal in Finder.
    /// Everything else (Combine, Correlate, Tag, Notes, ...) is suppressed —
    /// purged records are inert until restored.
    @ViewBuilder
    private func purgedRowContextMenu(rec: VideoRecord, selectedRecs: [VideoRecord]) -> some View {
        let purgedSelection = selectedRecs.filter { $0.isPurged }
        Button {
            for r in purgedSelection {
                _ = model.restoreRecord(id: r.id)
            }
        } label: {
            Label(CatalogRowMenuText.restoreToCatalog(count: purgedSelection.count),
                  systemImage: "arrow.uturn.backward.circle")
        }
        if VolumeReachability.isReachable(path: rec.fullPath) {
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(rec.fullPath, inFileViewerRootedAtPath: "")
            }
        }
    }

    /// Right-click menu for set-aside rows (video-only catalog scope,
    /// 2026-07-15). Same minimal shape as the purged menu: Put Back +
    /// Reveal. Set-aside records are inert until restored — they must not
    /// be offered Combine/Correlate/Tag actions.
    @ViewBuilder
    private func setAsideRowContextMenu(rec: VideoRecord, selectedRecs: [VideoRecord]) -> some View {
        let setAsideSelection = selectedRecs.filter { $0.isSetAside }
        Button {
            _ = model.restoreSetAsideRecords(ids: Set(setAsideSelection.map(\.id)))
        } label: {
            Label(CatalogRowMenuText.putBackInCatalog(count: setAsideSelection.count),
                  systemImage: "arrow.uturn.backward.circle")
        }
        if VolumeReachability.isReachable(path: rec.fullPath) {
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(rec.fullPath, inFileViewerRootedAtPath: "")
            }
        }
    }

    /// Right-click menu for superseded rows (repair lifecycle, GH #132).
    /// Same minimal shape as the purged / set-aside menus: superseded
    /// originals are inert until restored — no Combine/Correlate/Tag.
    /// "Show Repaired Copy in Catalog" jumps to the record that replaced
    /// this one.
    @ViewBuilder
    private func supersededRowContextMenu(rec: VideoRecord, selectedRecs: [VideoRecord]) -> some View {
        let supersededSelection = selectedRecs.filter { $0.isSuperseded }
        if supersededSelection.count == 1, let repairID = rec.supersededByID,
           model.record(forID: repairID) != nil {
            Button {
                onShowRepairedCopy?(repairID)
            } label: {
                Label("Show Repaired Copy in Catalog",
                      systemImage: "arrow.triangle.swap")
            }
            .accessibilityIdentifier("catalog.row.showRepairedCopy")
        }
        Button {
            for r in supersededSelection { _ = model.unsupersede(id: r.id) }
        } label: {
            Label(CatalogRowMenuText.restoreOriginals(count: supersededSelection.count),
                  systemImage: "arrow.uturn.backward.circle")
        }
        .help("Bring this original back into the catalog's default view. The repaired copy stays too — nothing on disk changes.")
        .accessibilityIdentifier("catalog.row.unsupersede")
        if VolumeReachability.isReachable(path: rec.fullPath) {
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(rec.fullPath, inFileViewerRootedAtPath: "")
            }
        }
    }

    /// The row context menu, extracted WHOLE from the Table's modifier
    /// chain (GH #132): the menu plus the grown onChange chain pushed the
    /// single `catalogTable` expression past Xcode's type-check budget.
    /// Same medicine as onlineCopyMenu / tagColumnCell — a dedicated
    /// function gives the compiler a small, isolated context.
    ///
    /// R1 (GH #281): the full menu's body is now one builder per section
    /// (activeRowContextMenu below, CatalogRowContextMenu+FileOps.swift,
    /// +Organize.swift, +Audio.swift); the selection split and menu
    /// choice are plain data (CatalogRowMenuPlan.swift). The old SwiftLint
    /// disable-next directive (cyclomatic complexity, function body length)
    /// is gone with it.
    @ViewBuilder
    func rowContextMenu(ids: Set<UUID>) -> some View {
        let selectedRecs = ids.compactMap { id in records.first { $0.id == id } }
        // Mixed-selection split (CatalogRowMenuPlan.swift). Each subset is
        // computed once so the Restore / Remove menu items use the same
        // record set their actions operate on (label counts ==
        // operated-on counts).
        let selection = CatalogRowMenuSelection(selected: selectedRecs)
        let activeRecs = selection.active
        // Delete File is never OFFERED for Master Archive files — the tree
        // or anywhere else on the archive's volume (Rick 2026-09-22). One
        // snapshot per menu open (right-click time, O(selection)); the
        // engine re-checks at the moment of the move regardless.
        let deletableRecs = model.recordsBulkVerbsMayRemove(activeRecs)
        if let id = ids.first,
           let rec = records.first(where: { $0.id == id }) {
            // Pure-purged selection: minimal menu (Restore + Reveal).
            // Pure set-aside selection: minimal menu (Put Back + Reveal).
            // Mixed selection: show the full active menu PLUS a Restore
            // item for the purged subset; row-targeted active actions
            // (Combine, Rename, Tag, etc.) are gated on
            // `purgedRecs.isEmpty` so a multi-select that pulled in any
            // purged row doesn't silently apply destructive ops to it.
            // Spec: "active-only row actions must be gated on
            // purgedRecs.isEmpty".
            if let shape = selection.shape(anchor: rec) {
                if shape == .purged {
                    purgedRowContextMenu(rec: rec, selectedRecs: selectedRecs)
                } else if shape == .setAside {
                    setAsideRowContextMenu(rec: rec, selectedRecs: selectedRecs)
                } else if shape == .superseded {
                    // Pure-superseded selection: minimal menu (Show
                    // Repaired Copy + Restore + Reveal) — GH #132.
                    supersededRowContextMenu(rec: rec, selectedRecs: selectedRecs)
                } else {
                    // Active or mixed selection — show the full menu,
                    // gating active-row actions on the selection being
                    // free of ALL inert states (purged / set-aside /
                    // superseded rows must never receive destructive ops).
                    activeRowContextMenu(rec: rec, selection: selection,
                                         deletableRecs: deletableRecs)
                }
            }
        }
    }

    /// The full menu for an active or mixed selection — its sections in
    /// menu order (R1 split, GH #281). Active-row actions are gated on the
    /// selection being free of ALL inert states: purged / set-aside /
    /// superseded rows must never receive destructive ops.
    @ViewBuilder
    private func activeRowContextMenu(rec: VideoRecord,
                                      selection: CatalogRowMenuSelection,
                                      deletableRecs: [VideoRecord]) -> some View {
        openItems(rec: rec)

        Divider()

        fileOperationItems(rec: rec, selection: selection)

        if selection.pureActive {
            organizeItems(rec: rec, selection: selection)
        } // end pureActive

        Divider()

        removeAndDeleteItems(activeRecs: selection.active, deletableRecs: deletableRecs)

        restoreItems(purgedRecs: selection.purged,
                     setAsideRecs: selection.setAside,
                     supersededRecs: selection.superseded)
    }

    /// Reveal in Finder / Open in QuickTime Player / Open in VLC.
    @ViewBuilder
    private func openItems(rec: VideoRecord) -> some View {
        Button(VolumeReachability.isReachable(path: rec.fullPath)
               ? "Reveal in Finder"
               : "Reveal in Finder (offline)") {
            if VolumeReachability.isReachable(path: rec.fullPath) {
                // Missing while mounted → "looks moved" banner
                // (Update Catalog); Finder can't select it anyway.
                if !model.noteMissingFileForUserAction(rec) {
                    NSWorkspace.shared.selectFile(rec.fullPath, inFileViewerRootedAtPath: "")
                }
            } else {
                let alert = NSAlert()
                alert.messageText = "File Offline"
                alert.informativeText = "The volume containing this file is not mounted.\n\n\(rec.fullPath)"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
        Button("Open in QuickTime Player") {
            model.noteMissingFileForUserAction(rec)
            if let qtURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.QuickTimePlayerX"
            ) {
                NSWorkspace.shared.open(
                    [URL(fileURLWithPath: rec.fullPath)],
                    withApplicationAt: qtURL,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            }
        }
        // Explicit manual override sibling of the QuickTime
        // item above — forces VLC regardless of the smart
        // double-click auto-decision. Falls back to the
        // system default handler when VLC isn't installed.
        Button("Open in VLC") {
            model.noteMissingFileForUserAction(rec)
            MediaOpener.openInVLC([rec])
        }
    }

    /// Remove from Catalog (hide the rows) and the Delete File submenu
    /// (Move to Trash / Delete Permanently…). Moved verbatim — the
    /// destructive scope is still exactly `deletableRecs`, the
    /// right-click-time snapshot the dispatcher takes.
    @ViewBuilder
    private func removeAndDeleteItems(activeRecs: [VideoRecord],
                                      deletableRecs: [VideoRecord]) -> some View {
        // Remove from Catalog — visible when the selection
        // contains at least one active row. The label and the
        // action both operate on `activeRecs` exclusively, so
        // a mixed selection's purged rows are never
        // double-stamped and the count in the label matches
        // the count actually mutated.
        if !activeRecs.isEmpty {
            Button(role: .destructive) {
                let targetIDs = Set(activeRecs.map { $0.id })
                _ = model.purgeRecords(ids: targetIDs)
            } label: {
                Label(CatalogRowMenuText.removeFromCatalog(count: activeRecs.count),
                      systemImage: "trash.slash")
            }
            .help("Hide these records from the default view. The files on disk are not deleted; toggle Show Removed in the toolbar to recover.")
        }

        // Delete File — per-row parity with the triage window's
        // batch path (Rick 2026-06-15). Move to Trash is
        // recoverable; Delete Permanently shows a confirmation
        // alert first. Both call deleteConfirmedJunk, which
        // already handles offline-skip, already-missing, and
        // per-file failures on a detached task. Distinct from
        // Remove from Catalog (above) which only hides the row.
        if !deletableRecs.isEmpty {
            Menu {
                Button(role: .destructive) {
                    let targets = deletableRecs
                    Task { @MainActor in
                        let result = await model.deleteConfirmedJunk(targets, mode: .toTrash)
                        reportDeleteResult(result, mode: .toTrash)
                    }
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .accessibilityIdentifier("catalog.row.deleteToTrash")

                Button(role: .destructive) {
                    let targets = deletableRecs
                    let count = targets.count
                    let alert = NSAlert()
                    alert.messageText = CatalogRowMenuText.permanentDeleteQuestion(
                        count: count, firstFilename: targets.first?.filename ?? "")
                    alert.informativeText = CatalogRowMenuText.permanentDeleteWarning(count: count)
                    alert.alertStyle = .critical
                    alert.addButton(withTitle: "Delete Permanently")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        Task { @MainActor in
                            let result = await model.deleteConfirmedJunk(targets, mode: .permanent)
                            reportDeleteResult(result, mode: .permanent)
                        }
                    }
                } label: {
                    Label("Delete Permanently\u{2026}", systemImage: "trash.fill")
                }
                .accessibilityIdentifier("catalog.row.deletePermanently")
            } label: {
                Label(CatalogRowMenuText.deleteFiles(count: deletableRecs.count),
                      systemImage: "xmark.bin")
            }
            // A viewer never deletes; the model refuses too (C04-F5).
            .disabled(model.isReadOnly)
            .help("Move the file(s) to Trash or remove them from disk permanently. Distinct from \u{201C}Remove from Catalog\u{201D} which only hides the row.")
        }
    }

    /// Restore / Put Back / Restore Original for the inert rows a
    /// mixed selection pulled in (pure inert selections get their
    /// minimal menus instead).
    @ViewBuilder
    private func restoreItems(purgedRecs: [VideoRecord],
                              setAsideRecs: [VideoRecord],
                              supersededRecs: [VideoRecord]) -> some View {
        // Restore to Catalog — visible when the selection
        // contains at least one purged row. Symmetric with
        // Remove: label count == operated-on count.
        if !purgedRecs.isEmpty {
            Button {
                for r in purgedRecs { _ = model.restoreRecord(id: r.id) }
            } label: {
                Label(CatalogRowMenuText.restoreToCatalog(count: purgedRecs.count),
                      systemImage: "arrow.uturn.backward.circle")
            }
            .help("Clear the removed marker on the selected rows.")
        }

        // Put Back in Catalog — visible when the selection
        // contains at least one set-aside row (mixed
        // selection; pure set-aside gets the minimal menu).
        if !setAsideRecs.isEmpty {
            Button {
                _ = model.restoreSetAsideRecords(ids: Set(setAsideRecs.map(\.id)))
            } label: {
                Label(CatalogRowMenuText.putBackInCatalog(count: setAsideRecs.count),
                      systemImage: "arrow.uturn.backward.circle")
            }
            .help("Clear the set-aside marker on the selected rows so they show up in lists and searches again.")
        }

        // Restore Original — visible when a mixed selection
        // pulled in superseded rows (pure superseded gets
        // the minimal menu above). GH #132.
        if !supersededRecs.isEmpty {
            Button {
                for r in supersededRecs { _ = model.unsupersede(id: r.id) }
            } label: {
                Label(CatalogRowMenuText.restoreOriginals(count: supersededRecs.count),
                      systemImage: "arrow.uturn.backward.circle")
            }
            .help("Bring these originals back into the catalog's default view. Their repaired copies stay too — nothing on disk changes.")
        }
    }

    /// Extracted "Find Online Copy" submenu for the active-row context
    /// menu. Inlining `Menu { ForEach { Section { ForEach { Button } } } }`
    /// inside the row's context menu confused Xcode 16.4's overload
    /// resolution — Charts' `ChartContentBuilder` was leaking into the
    /// candidate set for the nested Section/ForEach combinations,
    /// producing "result builder 'ChartContentBuilder' does not implement
    /// any 'buildBlock'" errors. Encapsulating the menu in a dedicated
    /// `@ViewBuilder` function gives the compiler a small, isolated
    /// type-check context where the SwiftUI ViewBuilder candidates win.
    /// Same root cause as `tagColumnCell` below — see commit history.
    @ViewBuilder
    func onlineCopyMenu(onlineMatches: [VideoRecord]) -> some View {
        // Flatten to a single (label, match) list and prefix the volume name
        // onto each button. We previously grouped with Section, but on
        // Xcode 16.4 Charts contributes a `Section`/`ForEach` overload
        // pair whose result-builder context (ChartContentBuilder) wins
        // overload resolution and breaks the build. Flattening sidesteps
        // the whole problem — one ForEach, one Button per row, no Section.
        // UX cost is small: instead of grouped submenu sections we get
        // "Volume — filename" labels in a single list.
        let byVolume = Dictionary(grouping: onlineMatches) {
            VolumeReachability.displayLabel(forPath: $0.fullPath)
        }
        let flat: [(id: UUID, label: String, path: String)] =
            byVolume.keys.sorted().flatMap { vol -> [(UUID, String, String)] in
                (byVolume[vol] ?? []).map { match in
                    (match.id, "\(vol) — \(match.filename)", match.fullPath)
                }
            }
        Menu("Find Online Copy (\(onlineMatches.count))") {
            ForEach(flat, id: \.id) { entry in
                Button(entry.label) {
                    NSWorkspace.shared.selectFile(
                        entry.path,
                        inFileViewerRootedAtPath: ""
                    )
                }
            }
        }
    }
}
