import SwiftUI

// MARK: - Triage Filter

enum TriageFilter: String, CaseIterable {
    case all          = "All Needing Triage"
    case untriaged    = "Untriaged"
    case important    = "Important"
    case suspectedJunk = "Suspected Junk"
    case confirmedJunk = "Confirmed Junk"
    case recoverable  = "Recoverable"

    var icon: String {
        switch self {
        case .all:           return "tray.full"
        case .untriaged:     return "circle"
        case .important:     return "star.fill"
        case .suspectedJunk: return "exclamationmark.triangle"
        case .confirmedJunk: return "xmark.circle.fill"
        case .recoverable:   return "wrench.and.screwdriver.fill"
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
        }
    }
}

// MARK: - Triage Tab

struct TriageView: View {
    @EnvironmentObject var model: VideoScanModel
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
    @State private var showJunkConfirmSheet = false
    @State private var showJunkResultSheet = false
    @State private var junkResult: VideoScanModel.JunkDeletionResult?
    @State private var junkResultMode: VideoScanModel.JunkDeletionMode = .toTrash
    @State private var junkResultBytesSucceeded: Int64 = 0

    private var confirmedJunk: [VideoRecord] {
        model.records.filter {
            $0.mediaDisposition == .confirmedJunk && $0.purgedAt == nil
        }
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
        }
        // Delete-Junk sheets — mirror the catalog-toolbar wiring so users
        // can tag-then-delete without leaving Triage. Confirm sheet asks
        // Move-to-Trash vs Delete Permanently; result sheet shows the
        // per-bucket breakdown.
        .sheet(isPresented: $showJunkConfirmSheet) {
            let snapshot = confirmedJunk
            DeleteConfirmedJunkConfirmSheet(
                records: snapshot,
                onCancel: { /* dismiss is automatic */ },
                onAct: { mode in
                    let targets = model.records.filter {
                        $0.mediaDisposition == .confirmedJunk && $0.purgedAt == nil
                    }
                    let split = VideoScanModel.splitByReachability(targets)
                    let bytesBefore = split.reachableBytes
                    let result = model.deleteConfirmedJunk(targets, mode: mode)
                    junkResult = result
                    junkResultMode = mode
                    let actionable = max(
                        result.attempted - result.alreadyMissing - result.skippedOffline,
                        0
                    )
                    junkResultBytesSucceeded = actionable > 0
                        ? Int64(Double(bytesBefore) * Double(result.succeeded) / Double(actionable))
                        : 0
                    showJunkResultSheet = true
                }
            )
        }
        .sheet(isPresented: $showJunkResultSheet) {
            if let r = junkResult {
                DeleteConfirmedJunkResultSheet(
                    mode: junkResultMode,
                    result: r,
                    bytesSucceeded: junkResultBytesSucceeded
                )
            }
        }
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
                    showJunkConfirmSheet = true
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
