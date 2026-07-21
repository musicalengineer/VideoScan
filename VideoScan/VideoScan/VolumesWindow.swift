//
//  VolumesWindow.swift
//  VideoScan
//
//  Full editor for volume metadata: role, trust, media tech, filesystem,
//  purchase year, capacity, notes. Reachable via Window menu (⌘⇧V) or by
//  clicking a VolumeBadge anywhere in the app. Shows the computed
//  destination policy so you see at a glance what's archive-safe.
//

import SwiftUI

struct VolumesWindow: View {
    @EnvironmentObject var model: VideoScanModel
    @State private var selectedID: UUID?
    @State private var sidebarWidth: CGFloat = 320
    /// §1B — toggle to surface retired volumes in this editor. Default
    /// OFF so the everyday view stays uncluttered; the Reinstate context
    /// menu is reachable by flipping this on.
    @State private var showRetired: Bool = true
    /// Confirmation alert backing for Reinstate. Holds the target path
    /// while the user decides yes/no. Reinstate is reversible (just
    /// re-retire), so a single yes/no alert is friction enough.
    @State private var reinstateTarget: ReinstateTarget?
    /// Retire confirmation sheet backing. Carries the source volume +
    /// pre-aggregated witness list so the sheet can render the verified-
    /// backups summary. Built lazily from the selected target's records
    /// at click time.
    @State private var retireOffer: PendingRetireOffer?

    /// §2 Provenance & Audit Trail — "Where files from <vol> live now"
    /// sheet backing. Built on demand from the right-clicked target via
    /// `model.makeVolumeProvenance`. Swift's optional → `.sheet(item:)`
    /// gives us auto-dismiss when the user closes.
    @State private var provenanceTarget: VolumeProvenance?

    /// §2 Provenance & Audit Trail — Migration Overview sheet backing.
    /// Built fresh each time the toolbar button fires; cheap enough on
    /// the catalog sizes Rick has (~10s of K records).
    @State private var migrationOverview: MigrationOverview?

    /// §3 Relocate Job Queue — Jobs panel sheet backing. Toolbar
    /// button toggles this; the panel itself observes `model.relocateQueue`.
    @State private var showRelocateJobsPanel: Bool = false

    /// Drive Health — standalone sheet target. Lives at the window
    /// level (not the row) so the sheet inherits the parent's
    /// environmentObject reliably.
    @State private var driveHealthTarget: CatalogScanTarget?

    /// "Purge Non-Video Media…" sheet backing for the volume right-click
    /// entry point. Carries the derived volume key + name so the unified
    /// dialog opens with THIS volume pre-selected (others off). Local @State
    /// (not the model's menu bool) so the sheet attaches to the Volumes
    /// window and can pass a pre-selection.
    @State private var nonVideoPurgeTarget: NonVideoPurgeTarget?

    /// "Delete from list" confirmation alert backing. Distinct from
    /// Retire — this is for orphan / typo / dangling scan targets
    /// (e.g. `/Volumes/rickb` with 0 records) that should never have
    /// been added. See `delete-vs-retire` note in
    /// docs/relocate_volume_plan.md. Carries the pre-computed orphan
    /// count so the alert can render "N catalog records will become
    /// orphans" without re-walking records on each render.
    @State private var deleteTarget: DeleteTarget?

    /// Sidebar font/badge scale — grows from 1.0 at 320pt to 1.5 at 540pt.
    /// The text and badge metrics in `VolumeListRow` multiply by this so a wider
    /// sidebar gets proportionally bigger labels (Rick's stretch goal).
    private var sidebarScale: CGFloat {
        let base: CGFloat = 320
        let max: CGFloat = 540
        let raw = (sidebarWidth - base) / (max - base)
        return 1.0 + (Swift.max(0, Swift.min(1, raw)) * 0.5)
    }

    /// Hide the RAM disk scratch volume (VideoScan_Temp) — it's plumbing,
    /// not an archive target, and shouldn't show up in the Volumes editor.
    /// §1B: retired volumes sort to the bottom; hidden entirely when the
    /// `Show retired` toggle is OFF.
    private var sortedTargets: [CatalogScanTarget] {
        CatalogScanTarget.excludingScratch(model.scanTargets)
            .filter { showRetired || !$0.isRetired }
            .sorted { a, b in
                // Retired-vs-active first: active before retired.
                if a.isRetired != b.isRetired { return !a.isRetired }
                return VolumeReachability.displayLabel(forPath: a.searchPath)
                    .localizedCaseInsensitiveCompare(
                        VolumeReachability.displayLabel(forPath: b.searchPath)
                    ) == .orderedAscending
            }
    }

    /// Identifiable wrapper so `.alert(item:)` can drive the confirmation
    /// dialog from `reinstateTarget`. A bare String would also work but
    /// SwiftUI prefers an `Identifiable` payload for sheet/alert items.
    private struct ReinstateTarget: Identifiable {
        let id: UUID
        let path: String
        let name: String
    }

    /// Identifiable wrapper for the Delete confirmation alert. Carries
    /// the orphan-record count snapshotted at right-click time so the
    /// alert body can be a plain `Text` without re-querying records.
    private struct DeleteTarget: Identifiable {
        let id: UUID
        let path: String
        let name: String
        let orphanCount: Int
    }

    /// Identifiable payload for the "Purge Non-Video Media…" sheet. `volumeKey`
    /// is the SAME pure derivation the purge classification uses
    /// (`VolumeReachability.volumeName(forPath:)`) so the pre-selection matches
    /// a real volume bucket in the dialog.
    private struct NonVideoPurgeTarget: Identifiable {
        let id = UUID()
        let volumeKey: String
        let name: String
    }

    private var selectedTarget: CatalogScanTarget? {
        if let id = selectedID,
           let t = sortedTargets.first(where: { $0.id == id }) {
            return t
        }
        return sortedTargets.first
    }

    var body: some View {
        HSplitView {
            volumeList
                .frame(minWidth: 280, idealWidth: 360, maxWidth: 600)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: SidebarWidthKey.self, value: geo.size.width)
                    }
                )
                .onPreferenceChange(SidebarWidthKey.self) { sidebarWidth = $0 }
            if let target = selectedTarget {
                VolumeEditor(target: target)
                    .id(target.id)
                    .frame(minWidth: 460)
            } else {
                placeholder
                    .frame(minWidth: 460)
            }
        }
        .frame(minWidth: 820, minHeight: 540)
        .onAppear { honorPendingSelection() }
        .onChange(of: model.pendingVolumesSelectionID) { honorPendingSelection() }
        // Retire confirmation — driven by the context-menu Mark Retired
        // action. Reuses the existing RelocateRetireSheet so the copy +
        // editable reason field stay in one place.
        .sheet(item: $retireOffer) { offer in
            RelocateRetireSheet(offer: offer)
        }
        // §2 Provenance & Audit Trail — Volume Provenance sheet. Reads
        // a pre-built `VolumeProvenance` payload from `provenanceTarget`
        // so SwiftUI tears it down cleanly on dismiss.
        .sheet(item: $provenanceTarget) { prov in
            VolumeProvenanceSheet(provenance: prov)
        }
        // §2 Provenance & Audit Trail — Migration Overview sheet.
        .sheet(item: $migrationOverview) { overview in
            MigrationOverviewSheet(overview: overview)
        }
        // §3 Relocate Job Queue — Jobs panel.
        .sheet(isPresented: $showRelocateJobsPanel) {
            RelocateJobsPanel()
                .environmentObject(model)
        }
        // Drive Health standalone sheet. Triggered from the row
        // context menu ("Show Drive Health…"). Same data as the
        // inline editor card, but bigger.
        .sheet(item: $driveHealthTarget) { target in
            DriveHealthSheet(target: target)
                .environmentObject(model)
        }
        // Volume right-click entry point for the unified purge dialog. Same
        // NonVideoMediaPurgeSheet the Catalog menu opens, but pre-selected to
        // THIS volume so Rick can clean drives one at a time.
        .sheet(item: $nonVideoPurgeTarget) { target in
            NonVideoMediaPurgeSheet(preselectedVolumeKey: target.volumeKey)
                .environmentObject(model)
        }
    }

    private func honorPendingSelection() {
        if let pending = model.pendingVolumesSelectionID {
            selectedID = pending
            model.pendingVolumesSelectionID = nil
        }
    }

    private var volumeList: some View {
        List(selection: $selectedID) {
            Section("Volumes") {
                ForEach(sortedTargets) { target in
                    VolumeListRow(target: target,
                                  scale: sidebarScale,
                                  retireStatus: retireStatus(for: target))
                        .tag(Optional(target.id))
                        // §1B + 2026-05-30: right-click menu surfaces
                        // Reinstate for retired volumes AND Mark Retired
                        // for 100%-disposed volumes. Mark-Retired is the
                        // new explicit retire surface — Relocate no
                        // longer auto-prompts. See
                        // feedback_friendly_language.md.
                        .contextMenu {
                            contextMenuItems(for: target)
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            // Show retired toggle — pinned to the toolbar so it's always
            // reachable without scrolling.
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: $showRetired) {
                    Label("Show retired", systemImage: "archivebox")
                }
                .toggleStyle(.button)
                .help("Surface retired volumes in this list so you can reinstate them.")
                .accessibilityIdentifier("volumesWindow.showRetired")
            }
            // §2 Provenance & Audit Trail — Migration Overview entry.
            // Builds the overview payload on click; the sheet binding
            // tears down the value when the sheet dismisses.
            ToolbarItem(placement: .automatic) {
                Button {
                    migrationOverview = model.makeMigrationOverview()
                } label: {
                    Label("Migration Overview", systemImage: "chart.bar.doc.horizontal")
                }
                .help("From aging drives to safe homes — a snapshot of where your library lives now.")
                .accessibilityIdentifier("volumesWindow.migrationOverview")
            }
            // §3 Relocate Job Queue — entry point for the Jobs panel.
            // Badge mirrors the Migration Overview button style; the
            // queued-count overlay only renders when there's something
            // to see, so the everyday "no jobs" toolbar stays clean.
            ToolbarItem(placement: .automatic) {
                Button {
                    showRelocateJobsPanel = true
                } label: {
                    RelocateJobsBadge(activeCount: model.activeJobCount,
                                      runningCount: model.runningCount)
                }
                .help("Queue of Migrate runs — kick off several and walk away. A running job stays here after you Hide its progress; cancel or monitor it from this panel.")
                .accessibilityIdentifier("volumesWindow.relocateJobs")
            }
        }
        .alert(item: $reinstateTarget) { tgt in
            Alert(
                title: Text("Reinstate \(tgt.name)?"),
                message: Text("This volume will go back to active status. Catalog records are not affected."),
                primaryButton: .default(Text("Reinstate")) {
                    model.reinstateVolume(at: tgt.path)
                },
                secondaryButton: .cancel()
            )
        }
        // "Delete from list" — destructive confirmation. The
        // `.destructive` role colors the button red so the user can't
        // miss what kind of action they're confirming. Cancel is the
        // default-highlighted button (safety first).
        .alert(item: $deleteTarget) { tgt in
            Alert(
                title: Text("Delete \(tgt.name) from the Volumes list?"),
                message: Text(deleteAlertMessage(for: tgt)),
                primaryButton: .destructive(Text("Delete")) {
                    if let target = model.scanTargets.first(where: { $0.searchPath == tgt.path }) {
                        // If the deleted target was selected, clear
                        // selection so the editor pane falls back to
                        // its placeholder gracefully.
                        if selectedID == target.id { selectedID = nil }
                        model.deleteScanTarget(target)
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    /// Compose the alert body. Pulled out so it stays one expression and
    /// the count + orphan language is in one place.
    private func deleteAlertMessage(for tgt: DeleteTarget) -> String {
        let recordsClause: String
        switch tgt.orphanCount {
        case 0:
            recordsClause = "No catalog records point at this path."
        case 1:
            recordsClause = "The 1 catalog record still pointing at this path will become an orphan (kept for history but no scan-target context)."
        default:
            recordsClause = "The \(tgt.orphanCount) catalog records still pointing at this path will become orphans (kept for history but no scan-target context)."
        }
        return """
        This removes it from the scan-targets list. \(recordsClause) You can re-add the volume by scanning again.

        This cannot be undone.
        """
    }

    /// Compose the right-click menu for a sidebar row. Split out for
    /// readability and because SwiftUI ViewBuilder is happiest with one
    /// expression per branch.
    @ViewBuilder
    private func contextMenuItems(for target: CatalogScanTarget) -> some View {
        // §2 Provenance — "Show where files went…" works on both retired
        // and active volumes. Enabled as long as the catalog has any
        // record originally cataloged on or relocated from this volume.
        // Cache read — context menus are re-evaluated with the row body.
        let hasRecords = retireStatus(for: target).totalRecords > 0
        Button("Show where files went…") {
            provenanceTarget = model.makeVolumeProvenance(for: target)
        }
        .disabled(!hasRecords)
        .help(hasRecords
              ? "See where every file from this drive lives now."
              : "No catalogued files for this volume yet.")
        .accessibilityIdentifier("volumeRow.showProvenance")

        // Drive Health — quick way to inspect SMART data without
        // entering the editor. Enabled whenever the volume is
        // online; offline drives can't be probed.
        Button("Show Drive Health…") {
            driveHealthTarget = target
        }
        .disabled(!target.isReachable)
        .help(target.isReachable
              ? "Check this drive's health (SMART data, age, sector health)."
              : "Drive is offline — connect it to probe its health.")
        .accessibilityIdentifier("volumeRow.showDriveHealth")

        // Unified purge, this volume pre-selected. Opens the same dialog as
        // Catalog ▸ "Purge Non-Video Media…" but scoped to this drive so the
        // user can clean volumes separately. The dialog computes live counts
        // on appear and disables Purge when nothing matches, so this stays
        // enabled unconditionally (gating it would need an O(records) sweep
        // inside the context-menu builder — forbidden by the view-body rule).
        Button("Purge Non-Video Media…") {
            nonVideoPurgeTarget = NonVideoPurgeTarget(
                volumeKey: VolumeReachability.volumeName(forPath: target.searchPath),
                name: volumeName(target)
            )
        }
        .help("Remove cover-art music and unrelated audio-only records from this volume. Files on disk are untouched.")
        .accessibilityIdentifier("volumeRow.purgeNonVideoMedia")

        Divider()

        if target.isRetired {
            Button("Reinstate \(volumeName(target))") {
                reinstateTarget = ReinstateTarget(
                    id: target.id,
                    path: target.searchPath,
                    name: volumeName(target)
                )
            }
            .accessibilityIdentifier("volumeRow.reinstate")
        } else {
            let status = retireStatus(for: target)
            Button("Mark Retired…") {
                guard status.canRetire else { return }
                presentRetireSheet(for: target, status: status)
            }
            .disabled(!status.canRetire)
            .help(status.tooltipForRetireAction)
            .accessibilityIdentifier("volumeRow.markRetired")
        }

        Divider()

        // "Delete from list…" — orphan/erroneous scan-target cleanup.
        // Distinct from Mark Retired: retire is for safely-backed-up
        // drives going on the shelf; delete is for entries that
        // shouldn't exist at all (typos, dangling mounts, /Volumes/rickb
        // with 0 records). Available for ALL volumes including retired
        // and System-tagged. Only the actual boot volume root "/" is
        // hard-blocked — `role == .system` is a user policy tag (skip
        // during scans), not a "this is undeleteable" assertion, so it
        // does not gate this action.
        let isBootRoot = target.searchPath == "/"
        // Cache read (see retireStatus) — this used to be a full-catalog
        // sweep inside the context-menu builder.
        let orphanCount = retireStatus(for: target).totalRecords
        Button(role: .destructive) {
            deleteTarget = DeleteTarget(
                id: target.id,
                path: target.searchPath,
                name: volumeName(target),
                orphanCount: orphanCount
            )
        } label: {
            Text("Delete from list…")
        }
        .disabled(isBootRoot)
        .help(isBootRoot
              ? "The boot volume can't be deleted from this list."
              : "Remove this volume entry from the scan-targets list. Catalog records are kept as orphans.")
        .accessibilityIdentifier("volumeRow.deleteFromList")
    }

    /// "Mini2TB" — the trailing volume-name component. Used in menu labels
    /// and the Reinstate target struct.
    private func volumeName(_ target: CatalogScanTarget) -> String {
        if let last = target.searchPath.split(separator: "/").last {
            return String(last)
        }
        return target.searchPath
    }

    /// Build the retire offer payload for the confirmation sheet. Pulls
    /// the witness union from the volume's `.manuallyDeleted` records via
    /// the existing aggregator, so the sheet shows exactly the same
    /// witnesses the post-Relocate flow would have shown.
    private func presentRetireSheet(for target: CatalogScanTarget,
                                     status: VolumeRetireStatus) {
        let witnesses = VideoScanModel.aggregateRetiredWitnesses(
            volumeRootPath: target.searchPath, in: model.records
        )
        retireOffer = PendingRetireOffer(
            volumeRootPath: target.searchPath,
            volumeName: volumeName(target),
            recordCount: status.totalRecords,
            suggestedReason: VideoScanModel.defaultRetireReason(),
            witnesses: witnesses
        )
    }

    /// Retire-readiness status for a target — an O(1) read of the model's
    /// per-volume status cache (2026-07-05 beachball fix). The cache is
    /// rebuilt off the main thread whenever records or targets change;
    /// the Bucket E/B/A/D semantics live in
    /// `VideoScanModel.computeVolumeStatuses` (pinned by
    /// VolumeStatusCacheTests). NO O(records) work may return to this
    /// view — a keystroke in the notes pane re-evaluates every row.
    private func retireStatus(for target: CatalogScanTarget) -> VolumeRetireStatus {
        model.volumeStatus(for: target.searchPath)
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No volumes")
                .font(.title3)
                .foregroundColor(.secondary)
            Text("Add a volume from the Catalog tab to manage its metadata here.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Retire-readiness status
//
// VolumeRetireStatus moved to VideoScanModel+VolumeStatusCache.swift
// (2026-07-05) — the model computes it now; this window only reads.

// MARK: - Sidebar Row

private struct VolumeListRow: View {
    @ObservedObject var target: CatalogScanTarget
    var scale: CGFloat = 1.0
    /// Retire-readiness signal from the parent. Optional because the
    /// parent only computes it for non-retired rows; retired rows get
    /// the brown badge instead.
    var retireStatus: VolumeRetireStatus?

    // 2026-05-31: Rick's "old eyes" font bump — base sizes bumped +2pt
    // across every text element in this row. The existing `scale`
    // multiplier still applies on top of the new base so the
    // wider-sidebar growth from 1.0x → 1.5x stays intact.
    //
    //   Volume label     14 → 16
    //   Path subtitle    11 → 13
    //   Retired badge     9 → 11
    //   Safe/Degraded     9 → 11   (see retirePill)
    var body: some View {
        HStack(spacing: 8) {
            VolumeBadge(role: target.role,
                        trust: target.trust,
                        isReachable: target.isReachable)
                .scaleEffect(scale, anchor: .leading)
                .frame(width: 38 * scale, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(VolumeReachability.displayLabel(forPath: target.searchPath))
                        .font(.system(size: 16 * scale, weight: .medium))
                        .lineLimit(1)
                    // §1B retired badge. "Retired YYYY-MM-DD" — replaces
                    // the policy badge visually because a retired volume
                    // isn't a viable destination.
                    if target.isRetired, let r = target.retiredAt {
                        Text("Retired \(Self.shortStamp(r))")
                            .font(.system(size: 11 * scale, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.brown.opacity(0.18))
                            .foregroundColor(.brown)
                            .cornerRadius(3)
                            .accessibilityIdentifier("volumeRow.retiredBadge")
                    } else if let s = retireStatus, s.isSafeToRetire {
                        // Green pill — all records disposed, safe
                        // witness present. The "you can retire this now"
                        // green light.
                        retirePill(text: "Safe to retire",
                                   bg: .green,
                                   identifier: "volumeRow.safeToRetireBadge")
                    } else if let s = retireStatus, s.isDegradedDisposed {
                        // Yellow pill — disposed but no safe backup. The
                        // "do not retire yet" warning state.
                        retirePill(text: "Disposed, degraded backups",
                                   bg: .yellow,
                                   identifier: "volumeRow.degradedDisposedBadge")
                    }
                }
                Text(target.searchPath)
                    .font(.system(size: 13 * scale, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            // Hide the destination-policy badge for retired drives — the
            // retired badge tells you everything you need.
            if !target.isRetired {
                PolicyBadge(policy: target.destinationPolicy)
                    .scaleEffect(0.95 * scale, anchor: .trailing)
            }
        }
        .padding(.vertical, 3)
        // Grey out the whole row for retired drives.
        .opacity(target.isRetired ? 0.55 : 1.0)
    }

    /// Small coloured pill. Shared between the green safe-to-retire and
    /// yellow degraded-disposed states. Background uses `opacity(0.22)`
    /// so the foreground colour stays the legible side.
    private func retirePill(text: String,
                             bg: Color,
                             identifier: String) -> some View {
        Text(text)
            .font(.system(size: 11 * scale, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(bg.opacity(0.22))
            .foregroundColor(bg)
            .cornerRadius(3)
            .accessibilityIdentifier(identifier)
    }

    /// "2026-05-30" — short, locale-neutral, sortable. Used for the
    /// retired badge so the badge stays one line at all sidebar widths.
    static func shortStamp(_ d: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone.current
        return fmt.string(from: d)
    }
}

private struct SidebarWidthKey: PreferenceKey {
    // PreferenceKey's `static var defaultValue { get }` requirement is
    // satisfied by a `let` (gets you the getter for free) and avoids the
    // global-mutable-state warning.
    static let defaultValue: CGFloat = 320
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
