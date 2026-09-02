import SwiftUI

// MARK: - Archive Tab
//
// Master-Archive-driven since 2026-08-17 (Rick): the sidebar reads the
// promoted-copy set (ArchiveView+Categories.swift), NOT the legacy
// lifecycleStage/archiveStage pipeline stamps. Layout:
//
//   ArchiveView.swift             — shell, sidebar, MASTER ARCHIVE panel, footer
//   ArchiveView+Table.swift       — file table, status cell, context menu
//   ArchiveView+Categories.swift  — pure derivations (categories, status, people)
//   ArchiveView+DetailSheet.swift — the per-record detail sheet
//   ArchiveHomeState.swift        — entry/hand-off state machine (HOME =
//                                   Archived + Timeline; see that file)

struct ArchiveView: View {
    @EnvironmentObject var model: VideoScanModel
    /// Verify copies… dispatches a VerifyArchiveCopiesJob (GH #167).
    @EnvironmentObject var fileOpsCenter: MediaFileOperationsCenter

    @State var selectedCategory: ArchiveCategory = .archived
    @State var selectedIDs: Set<UUID> = []
    @State var searchText: String = ""
    @State var sortOrder = [KeyPathComparator(\VideoRecord.filename)]
    @State var archiveDetailRecord: VideoRecord?
    /// "Show this file's journey" from the Archive tab (Rick 2026-08-19)
    /// — same FileJourneySheet the catalog uses.
    @State var fileJourneyPayload: FileJourney?
    /// Retired volumes are noise in the archive sidebar by default — same
    /// convention as the Volumes window's "show retired" (Rick 2026-08-16).
    @AppStorage("archive.sidebar.showRetired") private var showRetiredVolumes = false
    /// Category lists + volume counts, computed ONCE per records version
    /// (see ArchiveCategorySnapshot). A class held by @State: mutating it
    /// during body does not re-render.
    @State private var categoryMemo = RenderMemo<ArchiveCategoryKey, ArchiveCategorySnapshot>()
    /// Timeline items (ArchiveView+Timeline.swift), memoized per records
    /// version — same discipline as categoryMemo. Not private: the
    /// Timeline extension lives in its own file.
    @State var timelineItemMemo = RenderMemo<RecordsVersion, [ArchiveTimelineItem]>()
    /// Unique-file totals for the progress bar (ArchiveProgress.swift),
    /// memoized per records version — CatalogStorageTotals.compute is
    /// O(records) and must never run in body.
    @State var storageTotalsMemo = RenderMemo<RecordsVersion, CatalogStorageTotals>()
    /// "It looks like N files are ready" (ArchiveNudge.swift), memoized
    /// per records version.
    @State var nudgeMemo = RenderMemo<RecordsVersion, ArchiveNudge>()
    /// "timeline" | "files" — the Archived category's in-session view
    /// switch (ArchiveViewMode.rawValue). Timeline is the default and
    /// every tab ENTRY resets to it (ArchiveHomeState rule 1/2): the
    /// archive is the story, Files the bench.
    @AppStorage("archive.viewMode") var archiveViewMode: String = ArchiveViewMode.timeline.rawValue
    /// Non-nil while a hand-off has detoured the tab to a non-archived
    /// list ("Showing Not Yet Archived — Back to archive"). Set only by
    /// ArchiveHomeState; cleared by any sidebar click or Back.
    @State var detourCategory: ArchiveCategory?
    /// Timeline item to scroll to after an archived hand-off.
    @State var timelineScrollTarget: UUID?
    /// Main-window tab index (1 = Catalog) — "Show in Catalog" writes it.
    @AppStorage("selectedTab") var selectedTab: Int = 0

    @Environment(\.openWindow) var openWindow

    var body: some View {
        HSplitView {
            sidebar
                // Rick 2026-08-19: "plenty of room in this window" — wider
                // sidebar so MASTER ARCHIVE and the stage rows breathe.
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            fileList
                .frame(minWidth: 500)
        }
        // ContentView renders tabs via `switch selectedTab`, so this view
        // is rebuilt on every tab entry and onAppear IS the entry point.
        // One resolver decides what to show (ArchiveHomeState) — it used
        // to be three independent writers, and the focus-restore one
        // landed the tab in a file list nearly every time (Rick 2026-08-26).
        .onAppear { applyEntry(.appear) }
        // Consuming the request sets it to nil, which fires this again;
        // ArchiveEntryController makes that transition a no-op so the
        // first resolution (with its search) is what stays on screen.
        .onChange(of: model.pendingArchiveSelection) { _, newValue in
            applyEntry(.pendingSelectionChanged(newValue))
        }
        .sheet(item: $fileJourneyPayload) { payload in
            FileJourneySheet(journey: payload)
        }
        .sheet(item: $archiveDetailRecord) { rec in
            ArchiveDetailSheet(record: rec, allRecords: model.records)
        }
    }

    // MARK: - Snapshot access

    /// The volume rows the sidebar shows (scratch screened, retired
    /// optionally hidden). Their searchPaths key the memo so a volume
    /// add/remove recomputes the counts.
    private var visibleVolumeTargets: [CatalogScanTarget] {
        CatalogScanTarget.excludingScratch(model.scanTargets)
    }

    /// Memoized: O(1) on every render except the first after a records
    /// change. Everything in the sidebar, footer and table reads THIS.
    var snapshot: ArchiveCategorySnapshot {
        ArchiveCategorySnapshot.cached(in: categoryMemo,
                                       model: model,
                                       volumeSearchPaths: visibleVolumeTargets.map(\.searchPath))
    }

    /// True when the record has a Master Archive copy (any status but
    /// notArchived) — the timeline can show it.
    private func isArchived(_ id: UUID) -> Bool {
        guard let rec = model.record(forID: id) else { return false }
        if case .notArchived = ArchiveCategorySnapshot.status(of: rec, model: model) { return false }
        return true
    }

    /// Which sidebar row a record lives under (for navigation from
    /// elsewhere — Catalog "Show in Archive", focus restore).
    private func category(containing id: UUID) -> ArchiveCategory {
        isArchived(id) ? .archived : .notYetArchived
    }

    /// Tab entry + "Show in Archive" hand-off. Snapshots the model's
    /// one-shot requests, lets ArchiveEntryController consume and resolve
    /// them, writes the consumed snapshot back once, and applies the state.
    private func applyEntry(_ trigger: ArchiveEntryController.Trigger) {
        var request = ArchiveEntryRequest(pendingSelection: model.pendingArchiveSelection,
                                          pendingSearch: model.pendingArchiveSearch,
                                          focusedIDs: model.focusedMediaIDs)
        guard let outcome = ArchiveEntryController.handle(trigger,
                                                          request: &request,
                                                          persistedViewMode: archiveViewMode,
                                                          isArchived: isArchived,
                                                          category: category(containing:),
                                                          focusSet: model.focusSet(for:))
        else { return }
        if outcome.consumed {
            // Order matters: the selection write fires onChange(nil), a
            // no-op above, so nothing re-resolves from the cleared model.
            model.pendingArchiveSearch = request.pendingSearch
            model.focusedMediaIDs = request.focusedIDs
            model.pendingArchiveSelection = request.pendingSelection
        }
        apply(outcome.state)
    }

    /// Copy a resolved state into the view's storage. The only place
    /// selectedCategory / archiveViewMode / detour are written together.
    func apply(_ state: ArchiveTabState) {
        selectedCategory = state.category
        // The persisted Timeline/Files switch belongs to the Archived
        // category only; a list pick must not leave "files" behind and
        // turn the next Archived click into a table.
        if state.category == .archived {
            archiveViewMode = state.viewMode.rawValue
        }
        selectedIDs = state.selectedIDs
        searchText = state.searchText
        detourCategory = state.detour
        timelineScrollTarget = state.scrollTarget
    }

    /// "Back to archive" (detour banner) — HOME, and drop the app-wide
    /// focus so the next entry is HOME as well.
    func backToArchive() {
        model.focusedMediaIDs = []
        apply(ArchiveHomeState.backToArchive())
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Archive")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    masterArchivePanel
                        .padding(.horizontal, 8)
                        .padding(.bottom, 12)

                    Divider().padding(.vertical, 8)

                    // Stage rows — the two most important lines in this
                    // sidebar (Rick 2026-08-19): give them air.
                    VStack(alignment: .leading, spacing: 6) {
                        sidebarRow(.archived)
                        sidebarRow(.notYetArchived)
                        sidebarRow(.needsDate)
                            .padding(.leading, 14)
                    }
                    .padding(.horizontal, 4)

                    Divider().padding(.vertical, 12)

                    sidebarSection("VOLUMES") {
                        // Screen the RAM-disk scratch volume — plumbing,
                        // not an archive target. Retired volumes hidden
                        // unless asked for.
                        let all = visibleVolumeTargets
                        let retiredCount = all.filter(\.isRetired).count
                        let counts = snapshot.volumeFileCounts
                        ForEach(all.filter { showRetiredVolumes || !$0.isRetired }, id: \.id) { target in
                            volumeRoleRow(target, fileCount: counts[target.searchPath] ?? 0)
                        }
                        if retiredCount > 0 {
                            Toggle(isOn: $showRetiredVolumes) {
                                Text("Show retired (\(retiredCount))")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .padding(.leading, 8)
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }

            Divider()

            archiveFooter
                .padding(12)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: Master Archive panel (docs/archive_promotion_workflow.md §4)
    //
    // The archive's home base: the ONE designated volume, or the way to
    // designate one. Rick 2026-08-16: "not seeing any Archive: none in
    // the sidebar" — it should be discoverable without knowing the menu.
    @ViewBuilder
    private var masterArchivePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MASTER ARCHIVE")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
                .padding(.bottom, 2)
            if let designation = model.masterArchive {
                let reachable = FileManager.default.fileExists(atPath: designation.rootPath)
                // Green = designated and reachable; yellow = designated
                // but offline; the "none" state below is yellow too —
                // attention, not alarm (Rick 2026-08-16).
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: reachable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(reachable ? Color.green : Color.yellow)
                        .font(.system(size: 18))
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(VolumeReachability.displayLabel(forPath: designation.targetPath))
                            .font(.system(size: 17, weight: .semibold))
                        Text(reachable ? "Breen_Family_Archive" : "offline")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                let totals = model.masterArchiveTotals
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(totals.verified > 0 ? Color.green : Color.secondary)
                        .font(.system(size: 14))
                        .frame(width: 18)
                    Text("\(totals.verified) verified · \(MediaBytes.display(totals.verifiedBytes))")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    if totals.unverified > 0 {
                        Text("· \(totals.unverified) unverified")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.yellow)
                            .help("Archive copies cataloged by rescan without a fixity record — re-promote or verify to record their checksums.")
                    }
                }
                .padding(.leading, 8)
                .help("Every promoted file is byte-verified: copied, then re-read and its SHA-256 compared before it is recorded. This count is those files.")
                HStack(spacing: 14) {
                    Button("Reveal") { model.revealMasterArchiveInFinder() }
                    Button("Manifest") { model.openMasterArchiveManifest() }
                    // GH #167: manifest-driven fixity audit + recovery —
                    // re-reads every archive copy, restores archiveFixity
                    // on a manifest match, flags mismatches loudly. The
                    // '· N unverified' count above is what it repairs.
                    Button("Verify copies…") {
                        fileOpsCenter.startVerifyArchiveCopies(model: model)
                        MediaFileOperationsWindowOpener.openBehindMain(openWindow)   // Media File Operations window (legacy id)
                    }
                    .disabled(model.isReadOnly)
                    .help("Re-read every Master Archive copy end to end and compare its SHA-256 against the manifest. Matches restore the catalog's fixity record; a mismatch is flagged and never papered over.")
                }
                .buttonStyle(.link)
                .font(.system(size: 13))
                .disabled(!reachable)
                .padding(.leading, 34)   // aligns under the volume name, not the icon
                .padding(.top, 2)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.yellow)
                    Text("None designated")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.yellow)
                    Spacer()
                }
                .padding(.horizontal, 8)
                Button("Initialize Master Archive…") {
                    model.chooseAndOfferInitializeMasterArchive()
                }
                .controlSize(.small)
                .disabled(model.isReadOnly)
                .padding(.leading, 8)
                .help("Choose the volume that will hold the family's master archive; the app creates the Breen_Family_Archive tree, manifest and README.")
            }
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private func sidebarSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 2)
            content()
        }
    }

    private func sidebarRow(_ category: ArchiveCategory) -> some View {
        let count = snapshot.count(for: category)
        // Archived is the home row (Rick 2026-08-26: "a user has to figure
        // out what button to click on the left") — bold, archive glyph,
        // first. The lists below it read as secondary.
        let isHome = category == .archived
        return Button {
            model.focusedMediaIDs = []
            apply(ArchiveHomeState.sidebarPick(
                category,
                viewMode: ArchiveViewMode(rawValue: archiveViewMode) ?? .timeline))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: category.icon)
                    .foregroundColor(category.color)
                    .font(.system(size: isHome ? 17 : 15, weight: isHome ? .semibold : .regular))
                    .frame(width: 20)
                Text(category.label)
                    .font(.system(size: isHome ? 16 : 15, weight: isHome ? .bold : .regular))
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                selectedCategory == category
                    ? Color.accentColor.opacity(0.12)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(categoryHelp(category))
    }

    private func categoryHelp(_ category: ArchiveCategory) -> String {
        switch category {
        case .archived:
            return "The archive — the family's story by decade and year. Every asset with a byte-verified copy in the Master Archive."
        case .notYetArchived:
            return "Active catalog assets with no Master Archive copy yet. Right-click → Promote to Archive."
        case .needsDate:
            return "Not-yet-archived assets with no resolvable date — Promote would file them under Undated/. Set a date in the Inspector first."
        }
    }

    /// `fileCount` comes from the memoized snapshot — no per-row filter.
    private func volumeRoleRow(_ target: CatalogScanTarget, fileCount: Int) -> some View {
        let name = VolumeReachability.displayLabel(forPath: target.searchPath)

        return HStack(spacing: 6) {
            VolumeBadge(role: target.role,
                        trust: target.trust,
                        isReachable: target.isReachable,
                        isRetired: target.isRetired)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(name)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(target.isReachable ? .primary : .secondary)
                        .lineLimit(1)
                    if !target.isReachable {
                        Text("offline")
                            .font(.system(size: 14))
                            .foregroundColor(.orange)
                    }
                }
                HStack(spacing: 4) {
                    Text("\(fileCount)")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(.secondary)
                    PolicyBadge(policy: target.destinationPolicy)
                        .scaleEffect(0.75, anchor: .leading)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.pendingVolumesSelectionID = target.id
            openWindow(id: "volumes")
        }
        .contextMenu {
            Button("Edit Volume…") {
                model.pendingVolumesSelectionID = target.id
                openWindow(id: "volumes")
            }
            Divider()
            // User-selectable roles only (Archive = Master Archive via
            // Initialize; System = boot volume, auto). Never `allCases`.
            Menu("Role") {
                ForEach(VolumeRole.pickerCases, id: \.self) { role in
                    Button {
                        model.setRole(role, for: target)
                    } label: {
                        HStack {
                            Image(systemName: role.icon)
                            Text(role.rawValue)
                            if target.role == role {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            // The Master Archive and the boot volume keep their display-
            // only role; the menu is inert for them.
            .disabled(model.isMasterArchive(target) || target.isBootVolumeRoot)
            Menu("Reliability") {
                ForEach(VolumeTrust.allCases, id: \.self) { trust in
                    Button {
                        model.setTrust(trust, for: target)
                    } label: {
                        HStack {
                            Image(systemName: trust.icon)
                            Text(trust.rawValue)
                            if target.trust == trust {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }
    }

    /// "N of M media files archived · X GB verified" — one honest line.
    private var archiveFooter: some View {
        Text(snapshot.footerText(totals: model.masterArchiveTotals))
            .font(.system(size: 14))
            .foregroundColor(.secondary)
            .lineLimit(2)
            .help("N = assets with a verified Master Archive copy; M = every active catalog asset (archive copies not double-counted).")
    }

    // MARK: - Filtering

    /// The selected category's rows, narrowed by the search box.
    /// Category membership itself is memoized (snapshot); only the
    /// search filter runs per keystroke, over that category's rows.
    var filteredRecords: [VideoRecord] {
        let byCategory = snapshot.records(for: selectedCategory)
        if searchText.isEmpty { return byCategory }
        let q = searchText.lowercased()
        return byCategory.filter {
            $0.filename.lowercased().contains(q) ||
            $0.fullPath.lowercased().contains(q) ||
            $0.videoCodec.lowercased().contains(q) ||
            $0.notes.lowercased().contains(q) ||
            $0.detectedPeople.contains { $0.lowercased().contains(q) } ||
            $0.confirmedByUserPeople.contains { $0.name.lowercased().contains(q) } ||
            $0.suspectedPeople.contains { $0.lowercased().contains(q) }
        }
    }
}
