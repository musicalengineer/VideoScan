import SwiftUI
import UniformTypeIdentifiers

// MARK: - Triage Filter

enum TriageFilter: String, CaseIterable {
    case all          = "All Needing Triage"
    case untriaged    = "Untriaged"
    case important    = "Important"
    case suspectedJunk = "Suspected Junk"
    case confirmedJunk = "Confirmed Junk"
    case recoverable  = "Recoverable"
    // Pass B — Workflow filter, not a disposition. `workspaceActive`
    // is independent of MediaDisposition; a record can be Untriaged
    // AND workspace-active. Lives in its own sidebar section so the
    // user reads it as "workflow state" rather than "disposition pick."
    case workspace    = "In Workspace"

    var icon: String {
        switch self {
        case .all:           return "tray.full"
        case .untriaged:     return "circle"
        case .important:     return "star.fill"
        case .suspectedJunk: return "exclamationmark.triangle"
        case .confirmedJunk: return "xmark.circle.fill"
        case .recoverable:   return "wrench.and.screwdriver.fill"
        case .workspace:     return "hammer.fill"
        }
    }

    var color: Color {
        switch self {
        case .all:           return .accentColor
        case .untriaged:     return .secondary
        case .important:     return .blue
        case .suspectedJunk: return .orange
        case .confirmedJunk: return .red
        case .recoverable:   return .teal
        case .workspace:     return .mint
        }
    }
}

// MARK: - Triage Tab

struct TriageView: View {
    @EnvironmentObject var model: VideoScanModel
    // Pass C (Rick 2026-06-14): MFO verbs are available from triage too —
    // Rick explicitly called this out. Pull in the same env objects the
    // catalog tab uses so the Transcode menu can dispatch a job and open
    // the Media File Operations window.
    @EnvironmentObject var fileOpsCenter: MediaFileOperationsCenter
    @Environment(\.openWindow) private var openWindow
    @AppStorage("selectedTab") private var selectedTab: Int = 0

    @State private var selectedFilter: TriageFilter = .all
    @State private var selectedIDs: Set<UUID> = []
    @State private var searchText: String = ""
    @State private var sortOrder = [KeyPathComparator(\VideoRecord.filename)]
    @State private var isAnalyzing = false
    @State private var analysisSummary: MediaAnalyzer.AnalysisSummary?
    @State private var showAnalysisSummary = false

    // Delete-Junk sheet state — mirror of the catalog-toolbar pattern in
    // CatalogHelpers.swift. Users naturally expect to tag-then-delete in
    // the same view, so we expose the same workflow here.
    // Junk-sheet state — a single Identifiable enum drives one .sheet(item:)
    // modifier, replacing the previous pair of chained .sheet(isPresented:)
    // bindings. The chained pattern raced: when the delete task completed
    // faster than the 0.4s defer allowed (or when the system was busy and
    // dismiss took longer than 0.4s), the result sheet tried to present
    // while the confirm sheet was still dismissing — SwiftUI choked,
    // confirm sheet stuck mid-iconify, app appeared unresponsive ("cannot
    // return to main window" — Rick's report 2026-06-02 night). With
    // .sheet(item:), the .confirm → .result transition is one atomic
    // item-binding mutation and SwiftUI swaps content inside the same
    // modal presentation. See JunkSheet definition in JunkDeleteAction.swift.
    @State private var junkSheet: JunkSheet? = nil

    // Pass B — Import-to-Workspace sheet state. Same Identifiable-enum
    // pattern as JunkSheet to avoid chained-.sheet races. Set by the
    // Import button's NSOpenPanel callback once the probe completes.
    @State private var importSheet: WorkspaceImportSheet? = nil
    // Disables the Import button while a probe is in flight so the
    // user can't queue up half-a-dozen overlapping probes by mashing
    // the button.
    @State private var isImporting: Bool = false

    /// Records the Delete Junk button operates on. Scoped to the same
    /// `triageRecords` set the table renders so the button's count
    /// matches what the user sees. Without this scoping the button
    /// silently included archived-but-junk records the user had no
    /// way to inspect — Rick 2026-06-15. Archived junk surfaces in
    /// the status bar instead, with an explanatory tooltip.
    private var confirmedJunk: [VideoRecord] {
        triageRecords.filter { $0.mediaDisposition == .confirmedJunk }
    }

    /// Records tagged `.confirmedJunk` but already archived — outside
    /// triage scope but still tagged junk. Surfaced in the status bar
    /// so the discrepancy is visible, not silent. NOT included in the
    /// Delete Junk button's target.
    private var archivedConfirmedJunkCount: Int {
        model.records.filter {
            $0.mediaDisposition == .confirmedJunk
                && $0.purgedAt == nil
                && $0.lifecycleStage == .archived
        }.count
    }

    // Offline-aware filter. When on, the triage table hides any record
    // whose volume isn't currently mounted — useful when the user wants
    // to focus on what they can actually act on right now. Default off
    // so the existing "show everything" behavior is preserved.
    // `@AppStorage` ≈ a C++ singleton-backed bool whose value is
    // persisted to NSUserDefaults under the named key — survives
    // relaunches.
    @AppStorage("triageShowOnlineOnly") private var showOnlineOnly: Bool = false

    private var triageRecords: [VideoRecord] {
        // Global-inert filter: purged records are out of scope for triage —
        // a removed-from-catalog file shouldn't show up as something to
        // review. Restoring puts it back in scope automatically.
        pfActiveRecords(model.records).filter { $0.lifecycleStage != .archived }
    }

    private var filteredRecords: [VideoRecord] {
        let base: [VideoRecord]
        switch selectedFilter {
        case .all:
            base = triageRecords
        case .untriaged:
            base = triageRecords.filter { $0.mediaDisposition == .unreviewed }
        case .important:
            base = triageRecords.filter { $0.mediaDisposition == .important }
        case .suspectedJunk:
            base = triageRecords.filter { $0.mediaDisposition == .suspectedJunk }
        case .confirmedJunk:
            base = triageRecords.filter { $0.mediaDisposition == .confirmedJunk }
        case .recoverable:
            base = triageRecords.filter { $0.mediaDisposition == .recoverable }
        case .workspace:
            base = triageRecords.filter { $0.workspaceActive }
        }

        // Apply the "Online volumes only" toggle BEFORE the search filter
        // so the search runs over the smaller set. The reachability check
        // is backed by VolumeReachability's 5s per-volume cache, so even
        // with thousands of records this is at most one stat() per volume
        // every five seconds.
        let afterOnline = showOnlineOnly
            ? base.filter { VolumeReachability.isReachable(path: $0.fullPath) }
            : base

        if searchText.isEmpty { return afterOnline }
        let q = searchText.lowercased()
        return afterOnline.filter {
            $0.filename.lowercased().contains(q) ||
            $0.directory.lowercased().contains(q) ||
            $0.notes.lowercased().contains(q) ||
            $0.volumeName.lowercased().contains(q)
        }
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 180, idealWidth: 210, maxWidth: 260)
            mainContent
                .frame(minWidth: 500)
        }
        .onChange(of: selectedIDs) {
            if let first = selectedIDs.first {
                model.focusedMediaIDs = model.focusSet(for: first)
            }
        }
        .onAppear {
            restoreFocus()
        }
    }

    private func restoreFocus() {
        guard !model.focusedMediaIDs.isEmpty else { return }
        selectedIDs = model.focusedMediaIDs
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Triage")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    filterRow(.all)

                    Divider().padding(.vertical, 6)

                    // Pass B — WORKFLOW section sits above DISPOSITION
                    // because workspace-active is a flag, not a
                    // disposition pick. Keeping them visually distinct
                    // prevents the user from misreading "In Workspace"
                    // as an alternative to Important / Suspected Junk.
                    sidebarSection("WORKFLOW") {
                        filterRow(.workspace)
                    }

                    Divider().padding(.vertical, 6)

                    sidebarSection("DISPOSITION") {
                        filterRow(.untriaged)
                        filterRow(.important)
                        filterRow(.recoverable)
                        filterRow(.suspectedJunk)
                        filterRow(.confirmedJunk)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }

            Divider()

            triageProgress
                .padding(12)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    @ViewBuilder
    private func sidebarSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 2)
            content()
        }
    }

    private func filterRow(_ filter: TriageFilter) -> some View {
        let count = countFor(filter)
        return Button {
            selectedFilter = filter
            selectedIDs = []
        } label: {
            HStack(spacing: 8) {
                Image(systemName: filter.icon)
                    .foregroundColor(filter.color)
                    .frame(width: 18)
                Text(filter.rawValue)
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                selectedFilter == filter
                    ? Color.accentColor.opacity(0.12)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    private func countFor(_ filter: TriageFilter) -> Int {
        switch filter {
        case .all:           return triageRecords.count
        case .untriaged:     return triageRecords.filter { $0.mediaDisposition == .unreviewed }.count
        case .important:     return triageRecords.filter { $0.mediaDisposition == .important }.count
        case .suspectedJunk: return triageRecords.filter { $0.mediaDisposition == .suspectedJunk }.count
        case .confirmedJunk: return triageRecords.filter { $0.mediaDisposition == .confirmedJunk }.count
        case .recoverable:   return triageRecords.filter { $0.mediaDisposition == .recoverable }.count
        case .workspace:     return triageRecords.filter { $0.workspaceActive }.count
        }
    }

    private var triageProgress: some View {
        let total = triageRecords.count
        let reviewed = triageRecords.filter { $0.mediaDisposition != .unreviewed }.count
        let pct = total > 0 ? Double(reviewed) / Double(total) : 0

        return VStack(alignment: .leading, spacing: 4) {
            Text("\(reviewed) of \(total) triaged")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            ProgressView(value: pct)
                .tint(pct >= 1.0 ? .green : .accentColor)
            Text("\(Int(pct * 100))% complete")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(spacing: 0) {
            toolbar

            if let summary = analysisSummary, showAnalysisSummary {
                analysisBanner(summary)
            }

            Divider()

            let rows = filteredRecords.sorted(using: sortOrder)
            if rows.isEmpty {
                emptyState
            } else {
                fileTable(rows: rows)
            }

            statusBar
        }
        // Delete-Junk sheets — mirror the catalog-toolbar wiring so users
        // can tag-then-delete without leaving Triage. Confirm sheet asks
        // Move-to-Trash vs Delete Permanently; result sheet shows the
        // per-bucket breakdown.
        // Single .sheet(item:) drives both confirm and result. Cancel sets
        // junkSheet = nil; Delete buttons don't call dismiss() — the
        // JunkDeleteAction callback transitions the binding from .confirm
        // to .result(...) when the disk pass returns, swapping content
        // atomically inside the same modal presentation. No race possible.
        .sheet(item: $junkSheet) { sheet in
            switch sheet {
            case .confirm:
                DeleteConfirmedJunkConfirmSheet(
                    records: confirmedJunk,
                    onCancel: { /* dismiss is automatic via @Environment(\.dismiss) */ },
                    onAct: JunkDeleteAction.makeOnAct(model: model) { result, mode, bytesSucceeded in
                        // Atomic content transition: confirm → result.
                        junkSheet = .result(result, mode, bytesSucceeded)
                    }
                )
            case .result(let r, let mode, let bytes):
                DeleteConfirmedJunkResultSheet(
                    mode: mode,
                    result: r,
                    bytesSucceeded: bytes
                )
            }
        }
        // Pass B — Workspace-import lineage picker. Driven by the same
        // single-Identifiable-enum pattern as junkSheet so cancelling
        // and committing always nil out the binding atomically.
        .sheet(item: $importSheet) { sheet in
            switch sheet {
            case .lineagePicker(let pendingRecord):
                WorkspaceImportLineageSheet(
                    imported: pendingRecord,
                    catalogRecords: model.records,
                    onCommit: { parentID in
                        commitImportedRecord(pendingRecord, parentID: parentID)
                        importSheet = nil
                    },
                    onCancel: {
                        // Cancel discards the probe result. User has to
                        // re-pick the file if they want to retry —
                        // intentional, keeps the flow honest.
                        importSheet = nil
                    }
                )
            }
        }
    }

    /// Finder-style status bar at the bottom of the main pane. Always
    /// shows the visible record count under the current filter; adds
    /// "N selected" when there's a selection; surfaces archived-but-
    /// confirmed-junk count when the user is on the Confirmed Junk
    /// filter so they can see why the Delete Junk count and the table
    /// row count match each other but differ from the model-wide total.
    /// Rick 2026-06-15.
    private var statusBar: some View {
        HStack(spacing: 8) {
            Text("\(filteredRecords.count) \(selectedFilter.rawValue.lowercased())")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            if !selectedIDs.isEmpty {
                Text("\u{00B7}").foregroundColor(.secondary)
                Text("\(selectedIDs.count) selected")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            if selectedFilter == .confirmedJunk && archivedConfirmedJunkCount > 0 {
                Text("\u{00B7}").foregroundColor(.secondary)
                Text("\(archivedConfirmedJunkCount) archived (hidden)")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .help("Records tagged Confirmed Junk but already promoted to Archive. They are intentionally out of scope for the triage view and are NOT included in the Delete Junk button's count.")
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(Divider(), alignment: .top)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: selectedFilter.icon)
                .foregroundColor(selectedFilter.color)
            Text(selectedFilter.rawValue)
                .font(.headline)

            Spacer()

            triageButtons

            // Delete Junk — only visible when there's confirmed junk to act on.
            // Sheet pattern mirrors the catalog toolbar so the model code can
            // be reused (confirmedJunk + DeleteConfirmedJunkConfirmSheet).
            if !confirmedJunk.isEmpty {
                Button {
                    junkSheet = .confirm
                } label: {
                    Label("Delete Junk (\(confirmedJunk.count))",
                          systemImage: "trash.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .help("Move to Trash or delete permanently — sheet shows the split between reachable and offline volumes")
            }

            Button {
                promoteSelectedToArchive()
            } label: {
                Label("Archive", systemImage: "archivebox.fill")
            }
            .buttonStyle(.bordered)
            .tint(.green)
            .disabled(selectedIDs.isEmpty)
            .help("Promote selected to Archive vault")

            // Pass B — Import to Workspace. Sits left of the Analyze
            // menu (per spec) so the natural toolbar reading order is
            // triage actions → archive → import → analyze. Mint tint
            // matches the workspace color story established in Pass A.
            Button {
                runImportFlow()
            } label: {
                Label(isImporting ? "Importing…" : "Import…",
                      systemImage: "square.and.arrow.down.on.square")
            }
            .buttonStyle(.bordered)
            .tint(.mint)
            .disabled(isImporting)
            .help("Import a media file from disk into the catalog as workspace-active")

            Menu {
                Button("Analyze All (\(triageRecords.count))") {
                    runAnalysis(records: triageRecords)
                }
                if !selectedIDs.isEmpty {
                    Button("Analyze Selected (\(selectedIDs.count))") {
                        let selected = triageRecords.filter { selectedIDs.contains($0.id) }
                        runAnalysis(records: selected)
                    }
                }
            } label: {
                Label(isAnalyzing ? "Analyzing..." : "Analyze", systemImage: "wand.and.stars")
            }
            .menuStyle(.borderedButton)
            .controlSize(.large)
            .disabled(triageRecords.isEmpty || isAnalyzing)
            .help("Score and classify files using heuristics")

            // "Online volumes only" — sibling to the search field. Lives
            // here (not in the sidebar) because it's a view-modifier, not
            // a disposition pick. State is @AppStorage-backed so it
            // survives relaunches at the user's preference.
            Toggle(isOn: $showOnlineOnly) {
                Label("Online volumes only", systemImage: "externaldrive.connected.to.line.below")
                    .labelStyle(.titleAndIcon)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Hide records whose volume isn't currently mounted")

            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var triageButtons: some View {
        HStack(spacing: 6) {
            Button {
                triageSelected(.important)
            } label: {
                Label("Keep", systemImage: "star.fill")
            }
            .buttonStyle(.bordered)
            .tint(.blue)
            .disabled(selectedIDs.isEmpty)
            .help("Mark selected as Important")

            Button {
                triageSelected(.recoverable)
            } label: {
                Label("Repair", systemImage: "wrench.and.screwdriver.fill")
            }
            .buttonStyle(.bordered)
            .tint(.teal)
            .disabled(selectedIDs.isEmpty)
            .help("Mark selected as Recoverable")

            Button {
                triageSelected(.suspectedJunk)
            } label: {
                Label("Junk", systemImage: "exclamationmark.triangle")
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .disabled(selectedIDs.isEmpty)
            .help("Mark selected as Suspected Junk")

            Button {
                triageSelected(.unreviewed)
            } label: {
                Label("Undo", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .disabled(selectedIDs.isEmpty)
            .help("Reset to Unreviewed")
        }
    }

    // MARK: - Table

    private func fileTable(rows: [VideoRecord]) -> some View {
        Table(rows, selection: $selectedIDs, sortOrder: $sortOrder) {
            TableColumn("") { rec in
                Image(systemName: rec.mediaDisposition.icon)
                    .foregroundColor(rec.mediaDisposition.color)
            }
            .width(30)

            TableColumn("Filename", value: \.filename) { rec in
                // Italic + secondary when the row's volume isn't mounted —
                // mirrors the catalog-table pattern (CatalogHelpers.swift
                // around line 854). Visual cue that "you can't act on
                // this right now". When the toggle filter is active these
                // rows are hidden entirely, but the toggle defaults off,
                // so we still need a clear marker in the default view.
                let offline = !VolumeReachability.isReachable(path: rec.fullPath)
                Text(rec.filename)
                    .font(.system(size: 13, design: .monospaced))
                    .italic(offline)
                    .foregroundColor(offline ? .secondary : rec.filenameColor)
                    .lineLimit(1)
                    .help(offline ? "\(rec.fullPath) (offline)" : rec.fullPath)
            }
            .width(min: 150, ideal: 250)

            TableColumn("Type", value: \.streamTypeRaw) { rec in
                Text(rec.streamType.rawValue)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .width(min: 80, ideal: 100)

            TableColumn("Duration", value: \.durationSeconds) { rec in
                Text(rec.duration.isEmpty ? "—" : rec.duration)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .width(min: 60, ideal: 70)

            TableColumn("Size", value: \.sizeBytes) { rec in
                Text(rec.size.isEmpty ? "—" : rec.size)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .width(min: 60, ideal: 80)

            TableColumn("Volume", value: \.volumeName) { rec in
                Text(rec.volumeName)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .width(min: 80, ideal: 110)

            TableColumn("Rating") { rec in
                StarRatingView(rating: Binding(
                    get: { rec.starRating },
                    set: { rec.starRating = $0 }
                ))
            }
            .width(min: 60, ideal: 70)

            TableColumn("Score", value: \.junkScore) { rec in
                if rec.junkScore > 0 {
                    Text("\(rec.junkScore)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(rec.junkScore >= 8 ? .red : rec.junkScore >= 5 ? .orange : .yellow)
                } else {
                    Text("—")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .width(min: 40, ideal: 50)

            TableColumn("Why") { rec in
                if !rec.junkReasons.isEmpty {
                    Text(rec.junkReasons.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .help(rec.junkReasons.joined(separator: "\n"))
                } else {
                    Text("—")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .width(min: 100, ideal: 180)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            triageContextMenu(for: ids)
        } primaryAction: { ids in
            // Double-click / Return on row(s) → open in QuickTime.
            let recs = ids.compactMap { id in rows.first { $0.id == id } }
            MediaOpener.openInQuickTime(recs)
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func triageContextMenu(for ids: Set<UUID>) -> some View {
        let count = ids.count

        Section("Triage (\(count) file\(count == 1 ? "" : "s"))") {
            Button {
                applyDisposition(.important, to: ids)
            } label: {
                Label("Keep (Important)", systemImage: "star.fill")
            }
            Button {
                applyDisposition(.recoverable, to: ids)
            } label: {
                Label("Needs Repair", systemImage: "wrench.and.screwdriver.fill")
            }
            Button {
                applyDisposition(.suspectedJunk, to: ids)
            } label: {
                Label("Suspected Junk", systemImage: "exclamationmark.triangle")
            }
            Button {
                applyDisposition(.confirmedJunk, to: ids)
            } label: {
                Label("Confirm as Junk", systemImage: "xmark.circle.fill")
            }
            Divider()
            Button {
                applyDisposition(.unreviewed, to: ids)
            } label: {
                Label("Reset to Unreviewed", systemImage: "arrow.counterclockwise")
            }
        }

        Divider()

        // Transcode — Pass C (Rick 2026-06-14). MFO verbs work from
        // triage too: two-preset faithful conversion for FCP edits or
        // long-term archive. Single-row only (matches Show in Catalog
        // / Reveal in Finder above — these are per-file operations).
        // Disabled when the file is offline OR a transcode is already
        // running for it.
        let singleRec: VideoRecord? = (count == 1)
            ? ids.first.flatMap { id in model.records.first { $0.id == id } }
            : nil
        let transcodeRunning: Bool = {
            guard let r = singleRec else { return false }
            return fileOpsCenter.jobs.contains { job in
                guard job.state.isActive, let t = job as? TranscodeJob else { return false }
                return t.record.id == r.id
            }
        }()
        let transcodeBlocked = (singleRec == nil)
            || !VolumeReachability.isReachable(path: singleRec?.fullPath ?? "")
            || transcodeRunning

        Menu {
            Button("For Editing (ProRes 422 HQ)") {
                if let r = singleRec {
                    fileOpsCenter.startTranscode(record: r, preset: .editing, model: model)
                    openWindow(id: "combine")
                }
            }
            .disabled(transcodeBlocked)
            .accessibilityIdentifier("catalog.row.transcodeEditing")

            // Mirrors the catalog row menu: archival nests an HEVC
            // access copy and a verified FFV1 v3 preservation master.
            Menu("For Archival…") {
                Button("Access Copy (HEVC 10-bit)") {
                    if let r = singleRec {
                        fileOpsCenter.startTranscode(record: r, preset: .archival, model: model)
                        openWindow(id: "combine")
                    }
                }
                .disabled(transcodeBlocked)
                .accessibilityIdentifier("catalog.row.transcodeArchival")

                Button("Preservation Master (FFV1 v3, verified)") {
                    if let r = singleRec {
                        fileOpsCenter.startTranscode(record: r, preset: .preservation, model: model)
                        openWindow(id: "combine")
                    }
                }
                .disabled(transcodeBlocked)
                .accessibilityIdentifier("catalog.row.transcodePreservation")
            }
        } label: {
            Label("Transcode", systemImage: "wand.and.rays")
        }
        .disabled(transcodeBlocked)

        Divider()

        Button {
            if let id = ids.first {
                showInCatalog(id)
            }
        } label: {
            Label("Show in Catalog", systemImage: "film.stack")
        }
        .disabled(count != 1)

        Button {
            if let rec = ids.first.flatMap({ id in model.records.first { $0.id == id } }) {
                NSWorkspace.shared.selectFile(rec.fullPath, inFileViewerRootedAtPath: "")
            }
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        .disabled(count != 1)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40))
                .foregroundColor(.green)
            Text("Nothing to triage")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("All media has been reviewed or archived. Scan more volumes in the Catalog tab to populate this list.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func triageSelected(_ disposition: MediaDisposition) {
        applyDisposition(disposition, to: selectedIDs)
    }

    private func applyDisposition(_ disposition: MediaDisposition, to ids: Set<UUID>) {
        for id in ids {
            guard let rec = model.records.first(where: { $0.id == id }) else { continue }
            rec.mediaDisposition = disposition
            if rec.lifecycleStage == .cataloged && disposition != .unreviewed {
                rec.lifecycleStage = .reviewing
            }
        }
        model.saveCatalogDebounced()
    }

    private func showInCatalog(_ id: UUID) {
        model.focusedMediaIDs = model.focusSet(for: id)
        model.pendingCatalogSelection = id
        model.pendingCatalogPairMode = false
        selectedTab = 1
    }

    private func promoteSelectedToArchive() {
        for id in selectedIDs {
            guard let rec = model.records.first(where: { $0.id == id }) else { continue }
            rec.lifecycleStage = .archived
        }
        selectedIDs = []
        model.saveCatalogDebounced()
    }

    // MARK: - Import to Workspace (Pass B)

    /// Drives the full import flow: NSOpenPanel → ffprobe → lineage sheet.
    /// Single-file only this pass — see spec "Out of scope: multi-file".
    /// The panel runs synchronously on the main thread (NSOpenPanel doesn't
    /// have a good async API), then the probe is awaited on a Task so the UI
    /// stays responsive.
    private func runImportFlow() {
        // Lock the button so a double-click can't queue two probes.
        // Swift's `guard ... else { return }` ≈ a C++ early-return after
        // a null check.
        guard !isImporting else { return }

        let panel = NSOpenPanel()
        panel.title = "Import Media to Workspace"
        panel.message = "Pick a media file to add to the catalog as workspace-active."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // .movie covers most container types Vision/AVFoundation know
        // about (mov, mp4, m4v, mxf via UTI lookup); .audio for music
        // and orphaned audio-only stems. Conservative pair; the user
        // can broaden later if they need to import .avi etc.
        panel.allowedContentTypes = [.movie, .audio]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isImporting = true
        // Task ≈ a detached fiber — runs on the cooperative pool until
        // we hop back to @MainActor with the result. Memory: probeFile
        // streams ffprobe output, so worst-case footprint is the
        // returned VideoRecord (small) plus whatever ffprobe holds in
        // its own process. No file buffering on our side.
        Task { @MainActor in
            let probed = await model.probeFile(url: url)
            isImporting = false

            // Mark the freshly probed record as workspace-active. The
            // lineage sheet will decide derivedFrom; we don't touch it
            // here so cancel leaves the record un-committed.
            probed.workspaceActive = true

            importSheet = .lineagePicker(probed)
        }
    }

    /// Append the probed record (with chosen parent lineage) into the
    /// catalog and save. Called from the lineage sheet's onCommit.
    private func commitImportedRecord(_ rec: VideoRecord, parentID: UUID?) {
        rec.derivedFrom = parentID
        // workspaceActive was set in runImportFlow before the sheet
        // opened; the lineage sheet doesn't change it.
        model.records.append(rec)
        model.saveCatalogDebounced()
        model.log("Imported \(rec.filename) to workspace" +
                  (parentID == nil ? "." : " (derived from parent record)."))

        // Focus the new row. The "Untriaged" or "All" filters will
        // already include it because the fresh probe yields
        // mediaDisposition == .unreviewed and lifecycleStage ==
        // .cataloged. If the user is on the .workspace filter we just
        // added, they'll see it there too — workspaceActive is true.
        selectedIDs = [rec.id]
        model.focusedMediaIDs = model.focusSet(for: rec.id)
    }

    // MARK: - Analysis

    private func runAnalysis(records: [VideoRecord]) {
        isAnalyzing = true
        // MediaAnalyzer.analyzeAll mutates each record in place
        // (junkScore, mediaDisposition). Records are class instances,
        // not Sendable, so can't cross to a background queue without
        // racing. Until MediaAnalyzer is refactored to return a delta
        // (per #66 architecture work), run synchronously on the actor
        // that owns the records.
        let summary = MediaAnalyzer.analyzeAll(records)
        analysisSummary = summary
        showAnalysisSummary = true
        isAnalyzing = false
    }

    private func analysisBanner(_ summary: MediaAnalyzer.AnalysisSummary) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text("Analyzed \(summary.total):")
                .font(.system(size: 13, weight: .medium))
            Group {
                Label("\(summary.junkCount) junk", systemImage: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                Label("\(summary.familyCount) family", systemImage: "person.2.fill")
                    .foregroundColor(.blue)
                if summary.recoverableCount > 0 {
                    Label("\(summary.recoverableCount) recoverable", systemImage: "wrench.and.screwdriver.fill")
                        .foregroundColor(.teal)
                }
                Text("\(summary.stillUnreviewed) unclassified")
                    .foregroundColor(.secondary)
                if summary.unchanged > 0 {
                    Text("(\(summary.unchanged) unchanged)")
                        .foregroundColor(.secondary)
                }
            }
            .font(.system(size: 12))
            Spacer()
            Button {
                showAnalysisSummary = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.08))
    }
}
