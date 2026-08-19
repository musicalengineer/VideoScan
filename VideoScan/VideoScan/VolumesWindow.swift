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
    /// Sidebar sentinel for the pinned "Catalog" row (Rick 2026-08-19):
    /// selecting it shows the catalog-wide distribution pane instead of a
    /// single drive. Stable so `List(selection:)` can round-trip it.
    static let catalogRowID = UUID(uuidString: "0000C0DE-0000-4000-8000-00000000CA7A")!
    /// Storage tab (2026-08-19): the same editor hosted inside the main
    /// window as a top-tier tab. When embedded, the window-toolbar actions
    /// render as an in-content header bar instead (the main window has no
    /// NSToolbar — its tab strip is custom — so `.toolbar` would grow a
    /// second title bar). The standalone ⌘⇧V window keeps the real toolbar.
    var embedded: Bool = false
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

    /// "Which copy do we keep?" — duplicate keeper precedence sheet
    /// (2026-08-18). A volumes-level preference, so it lives here rather
    /// than in the Catalog toolbar.
    /// `.sheet(item:)` (not isPresented) — project_chained_sheet_antipattern.
    @State private var keeperPrecedenceSheet: KeeperPrecedenceSheetToken?
    private struct KeeperPrecedenceSheetToken: Identifiable { let id = 0 }

    /// "Where media lives" — donut of the catalog by (non-retired) volume
    /// (2026-08-18, after the LaCie redistribution). Same token pattern
    /// as the keeper-precedence sheet: `.sheet(item:)`, not isPresented.
    @State private var mediaDistributionSheet: MediaDistributionSheetToken?
    private struct MediaDistributionSheetToken: Identifiable { let id = 0 }

    /// "Audit Catalog…" — does everything add up (2026-08-19). Right-click
    /// on the pinned Catalog row. Same token pattern.
    @State private var auditSheet: AuditSheetToken?
    private struct AuditSheetToken: Identifiable { let id = 0 }

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

    /// "Initialize as Master Archive…" sheet backing for THIS window's
    /// right-click (docs/archive_promotion_workflow.md §4). Local (not
    /// the model's shared offer) so the sheet attaches to the Volumes
    /// window rather than the main window behind it.
    @State private var masterArchiveInitOffer: MasterArchiveInitOffer?

    /// Volume-role taxonomy migration (2026-08-16): one-time "these were
    /// Archive; pick Workspace / Backup" sheet. Presented when
    /// the window opens with a non-empty `model.pendingRoleReclassifications`
    /// and again whenever the queue refills (bundle import). "Decide
    /// later" simply dismisses; the queue persists in-memory until answered.
    @State private var showRoleReclassification = false

    /// Sidebar font/badge scale — grows from 1.0 at 320pt to 1.5 at 540pt.
    /// The text and badge metrics in `VolumeListRow` multiply by this so a wider
    /// sidebar gets proportionally bigger labels (Rick's stretch goal).
    private var sidebarScale: CGFloat {
        let base: CGFloat = 270
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
    }

    /// nil while the Catalog row is selected (or nothing is selected yet
    /// → Catalog is the default view).
    private var selectedTarget: CatalogScanTarget? {
        guard let id = selectedID, id != Self.catalogRowID else { return nil }
        return sortedTargets.first(where: { $0.id == id })
    }
    private var isCatalogSelected: Bool { selectedTarget == nil }

    var body: some View {
        attachSheets(to: hostedContent)
    }

    /// Header-bar-or-not + editor, with the selection/reclassification
    /// plumbing. Sheets attach in `attachSheets` so both hosts share them.
    private var hostedContent: some View {
        VStack(spacing: 0) {
            if embedded {
                embeddedHeaderBar
                Divider()
            }
            splitView
        }
        .onAppear {
            honorPendingSelection()
            showRoleReclassification = !model.pendingRoleReclassifications.isEmpty
        }
        .onChange(of: model.pendingVolumesSelectionID) { honorPendingSelection() }
        .onChange(of: model.pendingRoleReclassifications.count) { _, count in
            if count > 0 { showRoleReclassification = true }
        }
    }

    /// The editor proper — sidebar + detail. Shared by both hosts.
    private var splitView: some View {
        HSplitView {
            volumeList
                // Narrower by default so the dashboard pies get the room
                // (Rick 2026-08-19); still draggable out to 480.
                .frame(minWidth: 230, idealWidth: 270, maxWidth: 480)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: SidebarWidthKey.self, value: geo.size.width)
                    }
                )
                .onPreferenceChange(SidebarWidthKey.self) { sidebarWidth = $0 }
            if let target = selectedTarget {
                // Info card on top, dashboard charts (or the editor)
                // below — VolumeDetailPane (Storage tab, 2026-08-19).
                VolumeDetailPane(target: target)
                    .id(target.id)
                    .frame(minWidth: 460)
            } else if !sortedTargets.isEmpty {
                // Pinned Catalog row: the whole library by drive + safety.
                CatalogDistributionPane()
                    .frame(minWidth: 460)
            } else {
                placeholder
                    .frame(minWidth: 460)
            }
        }
        .frame(minWidth: 820, minHeight: 540)
    }

    /// Sheet + alert attachments, hoisted out of `body` so the embedded and
    /// standalone hosts share one chain.
    private func attachSheets<C: View>(to content: C) -> some View {
        content
        // Role taxonomy migration — legacy non-master "Archive" targets.
        .sheet(isPresented: $showRoleReclassification) {
            RoleReclassificationSheet()
                .environmentObject(model)
        }
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
        // Duplicate keeper precedence (2026-08-18).
        .sheet(item: $keeperPrecedenceSheet) { _ in
            DuplicateKeeperPrecedenceSheet()
                .environmentObject(model)
        }
        // Audit Catalog (2026-08-19).
        .sheet(item: $auditSheet) { _ in
            CatalogAuditSheet()
                .environmentObject(model)
        }
        // Where media lives — by-volume donut (2026-08-18).
        .sheet(item: $mediaDistributionSheet) { _ in
            MediaDistributionSheet()
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
        // Master Archive — Initialize confirmation for the row right-click.
        .sheet(item: $masterArchiveInitOffer) { offer in
            MasterArchiveInitSheet(offer: offer)
                .environmentObject(model)
        }
    }

    // MARK: - Actions (shared by the toolbar and the embedded header bar)

    /// Show retired toggle — always reachable without scrolling.
    private var showRetiredToggle: some View {
        Toggle(isOn: $showRetired) {
            Label("Show retired", systemImage: "archivebox")
        }
        .toggleStyle(.button)
        .help("Surface retired volumes in this list so you can reinstate them.")
        .accessibilityIdentifier("volumesWindow.showRetired")
    }

    /// §2 Provenance & Audit Trail — Migration Overview entry. Builds
    /// the overview payload on click; the sheet binding tears down the
    /// value when the sheet dismisses.
    private var migrationOverviewButton: some View {
        Button {
            migrationOverview = model.makeMigrationOverview()
        } label: {
            Label("Migration Overview", systemImage: "chart.bar.doc.horizontal")
        }
        .help("From aging drives to safe homes — a snapshot of where your library lives now.")
        .accessibilityIdentifier("volumesWindow.migrationOverview")
    }

    /// §3 Relocate Job Queue — entry point for the Jobs panel. The
    /// queued-count overlay only renders when there's something to see.
    private var relocateJobsButton: some View {
        Button {
            showRelocateJobsPanel = true
        } label: {
            RelocateJobsBadge(activeCount: model.activeJobCount,
                              runningCount: model.runningCount)
        }
        .help("Queue of Migrate runs — kick off several and walk away. A running job stays here after you Hide its progress; cancel or monitor it from this panel.")
        .accessibilityIdentifier("volumesWindow.relocateJobs")
    }

    /// Duplicate keeper precedence — which drive's copy we keep when the
    /// same video is on several (2026-08-18).
    private var keeperPrecedenceButton: some View {
        Button {
            keeperPrecedenceSheet = KeeperPrecedenceSheetToken()
        } label: {
            Label("Which copy to keep", systemImage: "list.number")
        }
        .help("Order your drives so duplicate cleanup keeps the copy on the drive you trust most.")
        .accessibilityIdentifier("volumesWindow.keeperPrecedence")
    }

    /// Where media lives — donut of the catalog by volume, non-retired
    /// drives only (2026-08-18).
    private var mediaDistributionButton: some View {
        Button {
            mediaDistributionSheet = MediaDistributionSheetToken()
        } label: {
            Label("Where media lives", systemImage: "chart.pie")
        }
        .help("A picture of how your library is spread across your drives right now.")
        .accessibilityIdentifier("volumesWindow.mediaDistribution")
    }

    /// Storage tab header (2026-08-19): title on the left, the toolbar
    /// actions on the right, as labeled bordered buttons so they read as
    /// a control strip rather than a bare icon row. Rick tunes the look
    /// in RD mode — keep this one place.
    private var embeddedHeaderBar: some View {
        HStack(spacing: 10) {
            Label("Storage", systemImage: "externaldrive.fill")
                .font(.title2.weight(.semibold))
                .labelStyle(.titleAndIcon)
            Text("\(sortedTargets.filter { !$0.isRetired }.count) active · \(model.scanTargets.filter(\.isRetired).count) retired")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            Spacer()
            Group {
                showRetiredToggle
                migrationOverviewButton
                relocateJobsButton
                keeperPrecedenceButton
                mediaDistributionButton
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.regular)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func honorPendingSelection() {
        if let pending = model.pendingVolumesSelectionID {
            selectedID = pending
            model.pendingVolumesSelectionID = nil
        } else if selectedID == nil {
            selectedID = Self.catalogRowID     // default view: the whole catalog
        }
    }

    private var volumeList: some View {
        List(selection: $selectedID) {
            // Pinned: the catalog as a whole — where it lives, how safely.
            Section {
                // A bare (non-ForEach) row's `.tag` is not reliably
                // selectable on macOS once another row has been chosen
                // (Rick 2026-08-19: "can't get back to the catalog
                // summary") — so the row is a Button that sets the
                // selection itself; the tag keeps the highlight in sync.
                Button {
                    selectedID = Self.catalogRowID
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.pie.fill")
                            .foregroundColor(.accentColor)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Catalog")
                                .font(.system(size: 13 * sidebarScale, weight: .semibold))
                            Text("where it all lives")
                                .font(.system(size: 11 * sidebarScale))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tag(Optional(Self.catalogRowID))
                .contextMenu {
                    Button {
                        auditSheet = AuditSheetToken()
                    } label: {
                        Label("Audit Catalog…", systemImage: "list.bullet.clipboard")
                    }
                    .help("Check that the catalog adds up: per-drive totals, unplaced records, nested targets, duplicate-group counts, pair links, archive index.")
                    .accessibilityIdentifier("volumeRow.catalog.audit")
                }
                .accessibilityIdentifier("volumeRow.catalog")
            }
            Section("Volumes") {
                ForEach(sortedTargets) { target in
                    VolumeListRow(target: target,
                                  scale: sidebarScale,
                                  retireStatus: retireStatus(for: target),
                                  isMasterArchive: model.isMasterArchive(target))
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
        // Standalone window: real NSToolbar. Embedded (Storage tab): the
        // same actions render in `embeddedHeaderBar` above the split view.
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .automatic) { showRetiredToggle }
                ToolbarItem(placement: .automatic) { migrationOverviewButton }
                ToolbarItem(placement: .automatic) { relocateJobsButton }
                ToolbarItem(placement: .automatic) { keeperPrecedenceButton }
                ToolbarItem(placement: .automatic) { mediaDistributionButton }
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
        // Update Catalog (2026-08-17): rescan + relink with a preview.
        // Eligible for reachable, non-retired volumes (and offline volumes
        // with a detected rename — the sheet handles both).
        Button("Update Catalog…") {
            model.openUpdateCatalog(preselecting: [target.id])
        }
        .disabled(model.isReadOnly || target.isRetired || target.isScratchVolume)
        .help("Files or folders moved outside VideoScan? Preview what a rescan would change and relink moved files to their records.")
        .accessibilityIdentifier("volumeRow.updateCatalog")

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
                volumeKey: VolumeReachability.volumeName(forPath: target.searchPath)
            )
        }
        .help("Remove cover-art music and unrelated audio-only records from this volume. Files on disk are untouched.")
        .accessibilityIdentifier("volumeRow.purgeNonVideoMedia")

        Divider()

        // Master Archive (docs/archive_promotion_workflow.md §4): ONE
        // gesture — designate + scaffold the tree + index files. Shown
        // for every non-retired volume; the sheet spells out the Safe
        // Archive assessment so a bad choice is visible before Confirm.
        if !target.isRetired {
            let isMaster = model.isMasterArchive(target)
            Button(isMaster ? "Master Archive ✓ (re-initialize…)" : "Initialize as Master Archive…") {
                masterArchiveInitOffer = MasterArchiveInitOffer(
                    targetPath: target.searchPath, isNewTarget: false)
            }
            .disabled(!target.isReachable || model.isReadOnly)
            .help(target.isReachable
                  ? (isMaster
                     ? "This is the Master Archive. Re-running Initialize repairs missing folders/index files without touching existing ones."
                     : "Designate this volume as the family's Master Archive and create the Breen_Family_Archive tree with its manifest and README.")
                  : "Volume is offline — connect it to initialize the archive.")
            .accessibilityIdentifier("volumeRow.initializeMasterArchive")
            if isMaster {
                Button("Reveal Master Archive in Finder") {
                    model.revealMasterArchiveInFinder()
                }
                .accessibilityIdentifier("volumeRow.revealMasterArchive")
            }
        }

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
    /// Master Archive chip (docs/archive_promotion_workflow.md §4) —
    /// the ONE designated volume. Passed in by the parent (O(1) path
    /// compare on the model), never derived here.
    var isMasterArchive: Bool = false

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
                        isReachable: target.isReachable,
                        isRetired: target.isRetired)
                .scaleEffect(scale, anchor: .leading)
                .frame(width: 38 * scale, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(VolumeReachability.displayLabel(forPath: target.searchPath))
                        .font(.system(size: 16 * scale, weight: .medium))
                        .lineLimit(1)
                    // Master Archive chip — the designated volume. Rendered
                    // before the retire pills so it reads first.
                    if isMasterArchive {
                        retirePill(text: "Master Archive",
                                   bg: .yellow,
                                   identifier: "volumeRow.masterArchiveBadge")
                    }
                    // §1B retired badge. "Retired YYYY-MM-DD" — replaces
                    // the policy badge visually because a retired volume
                    // isn't a viable destination.
                    // Retirement is a badge on ANY role (taxonomy
                    // 2026-08-16) — rendered from `retiredAt`, the one owner.
                    if let r = target.retiredAt {
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
