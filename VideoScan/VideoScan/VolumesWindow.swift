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
        model.scanTargets
            .filter { !$0.searchPath.contains("VideoScan_Temp") }
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
                    Label("Relocate Jobs", systemImage: "tray.full")
                        .overlay(alignment: .topTrailing) {
                            if model.queuedCount > 0 {
                                Text("\(model.queuedCount)")
                                    .font(.caption2.bold())
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.red)
                                    .clipShape(Capsule())
                                    .offset(x: 8, y: -8)
                            }
                        }
                }
                .help("Queue of Relocate runs — kick off several and walk away.")
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
        let hasRecords = VideoScanModel.totalRecordsOn(
            volumeRootPath: target.searchPath, in: model.records
        ) > 0
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
        // with 0 records). Available for ALL volumes including retired,
        // gated only by the system-volume guard.
        let isSystem = target.role == .system || target.searchPath == "/"
        let orphanCount = VideoScanModel.totalRecordsOn(
            volumeRootPath: target.searchPath, in: model.records
        )
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
        .disabled(isSystem)
        .help(isSystem
              ? "The system volume can't be deleted from this list."
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

    /// Compute the retire-readiness status for a target. Drives:
    ///   - Mark Retired enabled / disabled
    ///   - Tooltip when disabled
    ///   - The sidebar row badge (Safe to retire / Disposed degraded)
    private func retireStatus(for target: CatalogScanTarget) -> VolumeRetireStatus {
        let total = VideoScanModel.totalRecordsOn(
            volumeRootPath: target.searchPath, in: model.records
        )
        let disposed = VideoScanModel.manuallyDeletedOn(
            volumeRootPath: target.searchPath, in: model.records
        )
        // 100%-disposed predicate matches `shouldOfferRetire`.
        let allDisposed = total > 0 && disposed == total
        // Safe-witness aggregate: at least one Bucket E note from the
        // volume's records contributes at least one witness on a safe
        // host. We reuse the witness-union list and resolve each through
        // the model's safety resolver — cheap because Rick has ~10s of
        // scan targets and the aggregate is typically a few thousand
        // paths max.
        let witnesses = VideoScanModel.aggregateRetiredWitnesses(
            volumeRootPath: target.searchPath, in: model.records
        )
        let resolver = model.makeVolumeSafetyResolver()
        let hasSafeWitness = witnesses.contains { path in
            let (role, trust) = resolver(path)
            return role != .retired && trust != .unreliable
        }
        return VolumeRetireStatus(
            totalRecords: total,
            disposedRecords: disposed,
            allDisposed: allDisposed,
            hasSafeWitness: hasSafeWitness
        )
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

// MARK: - Retire-readiness status (UI-only)

/// Per-volume readiness signal. Computed by `VolumesWindow.retireStatus`
/// from the model's records + scan targets. Drives badge + menu state.
/// Internal struct — not part of the persisted model.
struct VolumeRetireStatus {
    let totalRecords: Int
    let disposedRecords: Int
    let allDisposed: Bool
    let hasSafeWitness: Bool

    /// "Safe to retire" — every record is disposed AND there's a safe
    /// witness backing up the contents. Matches Rick's description of
    /// the green-pill state.
    var isSafeToRetire: Bool { allDisposed && hasSafeWitness }

    /// "Disposed but degraded" — every record disposed, but no safe
    /// witness yet. Yellow-pill state.
    var isDegradedDisposed: Bool { allDisposed && !hasSafeWitness }

    /// Predicate gating the Mark Retired action. We require BOTH 100%
    /// disposed AND at least one safe witness — otherwise the user could
    /// retire a drive whose only backup is on another retiring drive,
    /// which is exactly the regression Rick called out.
    var canRetire: Bool { isSafeToRetire }

    /// Tooltip shown on the disabled Mark Retired menu item. Tells the
    /// user what's missing without making them guess.
    var tooltipForRetireAction: String {
        if totalRecords == 0 {
            return "No catalogued files on this volume yet."
        }
        if !allDisposed {
            return "Not all files on this volume are accounted for yet — run Relocate first."
        }
        if !hasSafeWitness {
            return "Files are marked disposed, but no backup copies are confirmed on safer drives."
        }
        return "Mark this volume retired."
    }
}

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

// MARK: - Editor

private struct VolumeEditor: View {
    @EnvironmentObject var model: VideoScanModel
    @ObservedObject var target: CatalogScanTarget

    @State private var purchaseYearText: String = ""
    @State private var capacityTBText: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                // 2026-05-31: "Relocated to" indicator. Sits between the
                // Volume ID header and the Workflow picker so users see
                // at a glance that the catalog for this drive now lives
                // somewhere else. Shows nothing when no records have
                // moved off this volume.
                if let summary = relocatedSummary {
                    relocatedBanner(summary)
                }
                Divider()
                workflowSection
                Divider()
                hardwareSection
                Divider()
                notesSection
                Spacer(minLength: 8)
            }
            .padding(20)
        }
        .onAppear { syncTextFields() }
        .onChange(of: target.id) { syncTextFields() }
    }

    /// Compute the relocated-to summary for the current target. Reads
    /// `model.records` so the banner updates live when a Relocate job
    /// finishes and the @Published records array changes. Returns nil
    /// when no records originated on this volume OR all of them are still
    /// resident here.
    private var relocatedSummary: VideoScanModel.RelocatedDestinationSummary? {
        let leaf: String = {
            if let last = target.searchPath.split(separator: "/").last {
                return String(last)
            }
            return target.searchPath
        }()
        return VideoScanModel.relocatedDestinationSummary(
            sourceVolumeRootPath: target.searchPath,
            sourceVolumeName: leaf,
            allRecords: model.records
        )
    }

    /// Blue-tinted banner. SF Symbol arrow + headline + monospaced
    /// destination path + count subtitle. Path is `textSelection(.enabled)`
    /// so the user can copy it.
    @ViewBuilder
    private func relocatedBanner(_ s: VideoScanModel.RelocatedDestinationSummary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(.blue)
            VStack(alignment: .leading, spacing: 3) {
                Text("Relocated to:")
                    .font(.callout.weight(.semibold))
                    .foregroundColor(.blue)
                Text(s.dominantDestinationPath)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(relocatedSubtitle(s))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 4)
        }
        .padding(10)
        .background(Color.blue.opacity(0.10))
        .cornerRadius(6)
        .accessibilityIdentifier("volumeEditor.relocatedBanner")
    }

    /// "<moved> of <total> records moved" + optional
    /// "(... and N more on other volumes)".
    private func relocatedSubtitle(_ s: VideoScanModel.RelocatedDestinationSummary) -> String {
        let recordWord = s.movedRecordCount == 1 ? "record" : "records"
        var base: String
        if s.movedRecordCount == s.totalOriginRecords {
            base = "All \(s.movedRecordCount) \(recordWord) moved."
        } else {
            base = "\(s.movedRecordCount) of \(s.totalOriginRecords) \(recordWord) moved."
        }
        if s.hasOtherDestinations {
            let volWord = s.otherDestinationVolumeCount == 1 ? "volume" : "volumes"
            base += " (… and \(s.otherDestinationVolumeCount) more on other \(volWord).)"
        }
        return base
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: target.role.icon)
                    .font(.system(size: 32))
                    .foregroundColor(target.role.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(VolumeReachability.displayLabel(forPath: target.searchPath))
                        .font(.title.bold())
                    Text(target.searchPath)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                // §1B: retired drives don't show a destination-policy
                // badge — they're not viable destinations. The retired
                // banner below tells the whole story.
                if !target.isRetired {
                    PolicyBadge(policy: target.destinationPolicy)
                        .scaleEffect(1.15)
                }
            }
            // §1B: retired status replaces the online/offline line. A
            // retired drive being offline is the expected steady state,
            // so the "Offline" badge would be noise; instead we show
            // when + why it was retired.
            if target.isRetired {
                retiredStatusLine
            } else {
                HStack(spacing: 6) {
                    Image(systemName: target.isReachable ? "checkmark.circle.fill" : "wifi.slash")
                        .foregroundColor(target.isReachable ? .green : .orange)
                    Text(target.isReachable ? "Online" : "Offline")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    /// Retired drives get a brown archive banner with the date stamp +
    /// reason. The Reinstate affordance lives in the sidebar context
    /// menu, not here — clicking through to the editor is read-only for
    /// retired volumes (matches the "fully reversible, just not via
    /// every surface" UX).
    @ViewBuilder
    private var retiredStatusLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "archivebox.fill")
                .foregroundColor(.brown)
            VStack(alignment: .leading, spacing: 2) {
                Text("Retired" + (target.retiredAt.map { " on \(Self.shortDateStamp($0))" } ?? ""))
                    .font(.callout.bold())
                    .foregroundColor(.brown)
                if let reason = target.retiredReason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let w = target.retiredWitnesses, !w.isEmpty {
                    Text("\(w.count) witness path(s) recorded.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color.brown.opacity(0.08))
        .cornerRadius(6)
        .accessibilityIdentifier("volumeEditor.retiredBanner")
    }

    static func shortDateStamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: d)
    }

    private var workflowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Workflow").font(.title3.bold())
            HStack(alignment: .top, spacing: 24) {
                pickerColumn(title: "Role") {
                    Picker("", selection: Binding(
                        get: { target.role },
                        set: { model.setRole($0, for: target) }
                    )) {
                        ForEach(VolumeRole.allCases, id: \.self) { r in
                            Label(r.rawValue, systemImage: r.icon).tag(r)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                pickerColumn(title: "Reliability") {
                    Picker("", selection: Binding(
                        get: { target.trust },
                        set: { model.setTrust($0, for: target) }
                    )) {
                        ForEach(VolumeTrust.allCases, id: \.self) { t in
                            Label(t.rawValue, systemImage: t.icon).tag(t)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                Spacer()
            }
        }
    }

    private var hardwareSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Hardware").font(.title3.bold())
                Spacer()
                Button {
                    detectHardware()
                } label: {
                    Label("Detect Hardware", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
                .disabled(!target.isReachable)
                .help(target.isReachable
                      ? "Auto-fill filesystem and capacity from the mounted volume"
                      : "Volume offline — connect it to detect hardware")
            }
            HStack(alignment: .top, spacing: 24) {
                pickerColumn(title: "Media") {
                    Picker("", selection: Binding(
                        get: { target.mediaTech },
                        set: { model.setMediaTech($0, for: target) }
                    )) {
                        ForEach(VolumeMediaTech.allCases, id: \.self) { m in
                            Label(m.rawValue, systemImage: m.icon).tag(m)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }
                pickerColumn(title: "Filesystem") {
                    TextField("APFS, exFAT, …", text: Binding(
                        get: { target.filesystem },
                        set: { model.setFilesystem($0, for: target) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                }
                Spacer()
            }
            HStack(alignment: .top, spacing: 24) {
                pickerColumn(title: "Purchased (year)") {
                    TextField("YYYY", text: $purchaseYearText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onChange(of: purchaseYearText) { _, _ in commitPurchaseYear() }
                        .onSubmit { commitPurchaseYear() }
                }
                pickerColumn(title: "Capacity (TB)") {
                    TextField("0.0", text: $capacityTBText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onChange(of: capacityTBText) { _, _ in commitCapacity() }
                        .onSubmit { commitCapacity() }
                }
                Spacer()
            }
            // Drive Health card — sits at the bottom of Hardware so
            // the SMART-driven recommendation is right next to the
            // manual Reliability/purchase-year fields it informs.
            // Retired/offline drives skip the card entirely; the rest
            // get an async probe.
            if !target.isRetired {
                DriveHealthCard(target: target)
                    .padding(.top, 4)
            }
        }
    }

    /// Pull filesystem name and total capacity from the live mount via
    /// URLResourceValues. Media tech and purchase year stay user-driven —
    /// macOS doesn't expose "is this RAID-0?" or purchase date.
    private func detectHardware() {
        let url = URL(fileURLWithPath: target.searchPath)
        let keys: Set<URLResourceKey> = [
            .volumeLocalizedFormatDescriptionKey,
            .volumeTotalCapacityKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return }

        if let fs = values.volumeLocalizedFormatDescription, !fs.isEmpty {
            model.setFilesystem(fs, for: target)
        }
        if let bytes = values.volumeTotalCapacity, bytes > 0 {
            let tb = Double(bytes) / 1_000_000_000_000.0
            model.setCapacityTB(tb, for: target)
            capacityTBText = String(format: "%.2f", tb)
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes").font(.title3.bold())
            TextEditor(text: Binding(
                get: { target.notes },
                set: { model.setNotes($0, for: target) }
            ))
            .font(.system(size: 14))
            .frame(minHeight: 100, maxHeight: 220)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
        }
    }

    // MARK: Helpers

    private func pickerColumn<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout)
                .foregroundColor(.secondary)
            content()
        }
    }

    private func syncTextFields() {
        purchaseYearText = target.purchaseYear.map(String.init) ?? ""
        capacityTBText = target.capacityTB.map { String(format: "%.2f", $0) } ?? ""
    }

    private func commitPurchaseYear() {
        let trimmed = purchaseYearText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            model.setPurchaseYear(nil, for: target)
        } else if let y = Int(trimmed), (1990...2100).contains(y) {
            model.setPurchaseYear(y, for: target)
        }
        // else: partial / invalid input — don't reset; let user keep typing.
        // syncTextFields() will restore saved value on next re-open if needed.
    }

    private func commitCapacity() {
        let trimmed = capacityTBText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            model.setCapacityTB(nil, for: target)
        } else if let v = Double(trimmed), v > 0 {
            model.setCapacityTB(v, for: target)
        }
        // else: partial / invalid input — don't reset; let user keep typing.
    }
}
