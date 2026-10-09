import SwiftUI
import UniformTypeIdentifiers

// MARK: - Triage Filter

enum TriageFilter: String, CaseIterable, Sendable {
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
    // Workbench merged into Triage (Rick 2026-08-19): files a pipeline
    // PRODUCED (Combine / Repair / Transcode output) are "under
    // construction" — review, then Promote / Drop to Catalog / Discard.
    // `lifecycleStage == .workbench`, a workflow flag, not a disposition.
    case underConstruction = "Under Construction"
    // Cleaned-filter pass (Rick 2026-07-08) — DERIVED filter, not a
    // stored tag: a record is "Cleaned up" iff CleanupJob stamped
    // provenance on it (cleanupRecipeID != nil). Like .workspace it's
    // a flag rather than a disposition pick, so it lives in the
    // WORKFLOW sidebar section.
    case cleaned      = "Cleaned up"

    var icon: String {
        switch self {
        case .all:           return "tray.full"
        case .untriaged:     return "circle"
        case .important:     return "star.fill"
        case .suspectedJunk: return "exclamationmark.triangle"
        case .confirmedJunk: return "xmark.circle.fill"
        case .recoverable:   return "wrench.and.screwdriver.fill"
        case .workspace:     return "shippingbox.fill"
        case .underConstruction: return "hammer.fill"
        case .cleaned:       return "sparkles"
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
        case .underConstruction: return .orange
        case .cleaned:       return .purple
        }
    }

    /// The per-record predicate for this filter. BOTH the table
    /// (`filteredRecords`) and the sidebar count badges (`countFor`)
    /// route through here, so the row set and the badge number can
    /// never drift apart — previously they were two hand-duplicated
    /// switches that had to be edited in lockstep. Pure function
    /// (≈ a C++ free function: no view state), so it's unit-testable
    /// without SwiftUI — see TriageCleanedFilterTests. (2026-10-03: the
    /// table and the badges are now built off-main in
    /// TriageSnapshotBuilder, through this same predicate.)
    func matches(_ record: VideoRecord) -> Bool {
        matches(disposition: record.mediaDisposition, workspaceActive: record.workspaceActive,
                lifecycleStage: record.lifecycleStage, cleaned: record.cleanupRecipeID != nil)
    }

    /// The predicate itself, over the four facts it reads — so the live
    /// record and the snapshot's row (`matches(_: TriageRow)`,
    /// TriageSnapshot.swift) cannot answer differently.
    func matches(disposition: MediaDisposition, workspaceActive: Bool,
                 lifecycleStage: LifecycleStage, cleaned: Bool) -> Bool {
        switch self {
        case .all:           return true
        case .untriaged:     return disposition == .unreviewed
        case .important:     return disposition == .important
        case .suspectedJunk: return disposition == .suspectedJunk
        case .confirmedJunk: return disposition == .confirmedJunk
        case .recoverable:   return disposition == .recoverable
        case .workspace:     return workspaceActive
        case .underConstruction: return lifecycleStage == .workbench
        // Derived provenance: cleanupRecipeID is the stamp CleanupJob
        // writes when it catalogs a recipe's output file.
        case .cleaned:       return cleaned
        }
    }
}

// MARK: - Triage Tab

// PERF RULE (2026-10-03, measured): this view reads ONLY `snapshot` and
// its own small @State. It does NOT observe the model or the job centre —
// both publish many times a second during a long run, and each publish
// used to re-run this body, which walked the whole catalog a dozen times
// (85% of the main thread in a sample taken during Delete Duplicates).
// Everything O(records) is built off-main in TriageSnapshotBuilder and
// published, equality-gated, through the model's `triageSnapshot`. Records
// are looked up by id in EVENT HANDLERS only. Pinned by
// TriageViewSensorTests.
//
// (For Rick: `let model` ≈ holding a plain pointer — we can call it, but
// SwiftUI does not subscribe this view to its change signal.
// `@ObservedObject` IS the subscription, and it is to the snapshot alone.)
struct TriageView: View {
    /// Sliding selected-filter highlight in the sidebar.
    @Namespace private var filterHighlightNS
    let model: VideoScanModel
    @ObservedObject private var snapshot: TriageSnapshot
    // Pass C (Rick 2026-06-14): MFO verbs are available from triage too.
    // A plain reference (not @EnvironmentObject): the centre forwards every
    // job's progress tick, and this view only needs "is a transcode of
    // this file running?" at the moment a context menu opens.
    @Environment(\.mediaFileOperationsCenterReference) private var fileOpsCenterReference
    @Environment(\.openWindow) private var openWindow
    @AppStorage("selectedTab") private var selectedTab: Int = 0

    @State private var selectedFilter: TriageFilter = .all
    @State private var selectedIDs: Set<UUID> = []
    @State private var searchText: String = ""
    @State private var sortOrder = TriageQuery.defaultSort
    /// Search-as-you-type: the text is handed to the snapshot 200 ms after
    /// the last keystroke.
    @State private var searchDebounce: Task<Void, Never>?
    @State private var isAnalyzing = false
    @State private var analysisSummary: MediaAnalyzer.AnalysisSummary?
    @State private var showAnalysisSummary = false

    // The steward pane's "Review these below" (trial UI, 2026-10-03;
    // design §5.6): the table shows JUST these records, selected, until
    // "Show everything" — a view state like the search field, nothing
    // stored. Empty = the table as it always was.
    @State private var stewardReviewIDs: Set<UUID> = []
    @State private var stewardReviewLabel: String = ""
    /// QA F8: what has been decided here about the reviewed card's clips.
    @State private var stewardReview = StewardReview()

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
    @State private var transcodeRequest: TranscodeRequest?
    // Disables the Import button while a probe is in flight so the
    // user can't queue up half-a-dozen overlapping probes by mashing
    // the button.
    @State private var isImporting: Bool = false

    // Offline-aware filter. When on, the triage table hides any record
    // whose volume isn't currently mounted — useful when the user wants
    // to focus on what they can actually act on right now. Default off
    // so the existing "show everything" behavior is preserved.
    // `@AppStorage` ≈ a C++ singleton-backed bool whose value is
    // persisted to NSUserDefaults under the named key — survives
    // relaunches.
    @AppStorage("triageShowOnlineOnly") private var showOnlineOnly: Bool = false

    // View ▸ Curator (2026-10-07): the CLEAN UP section and its panes show
    // only when it is on — calm by default, depth on request.
    @AppStorage(CuratorMode.key) private var curator: Bool = false
    /// The excess-copies plan, built off-main on demand (≈ a cached value a
    /// worker thread fills). A plain reference: only the CLEAN UP row and
    /// the pane observe it, so TriageView's body never re-runs for it.
    private let excessStore = ExcessCopiesStore.shared
    @State private var showingExcess = false

    init(model: VideoScanModel) {
        self.model = model
        // Property-wrapper backing init (`_snapshot` ≈ the wrapper struct
        // itself, not the wrapped value).
        self._snapshot = ObservedObject(wrappedValue: model.triageSnapshot)
    }

    /// What the person is asking to see, as the snapshot's build key.
    private var currentQuery: TriageQuery {
        TriageQuery(filter: selectedFilter, search: searchText, onlineOnly: showOnlineOnly,
                    reviewIDs: stewardReviewIDs, sortOrder: sortOrder)
    }

    /// Hand the current filter / search / sort to the snapshot now (the
    /// build is off-main; the rows on screen stay until it lands).
    private func pushQuery() {
        searchDebounce?.cancel()
        searchDebounce = nil
        model.setTriageQuery(currentQuery)
    }

    private func pushQueryAfterTyping() {
        searchDebounce?.cancel()
        guard !searchText.isEmpty else { pushQuery(); return }
        searchDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            model.setTriageQuery(currentQuery)
        }
    }

    /// An edit made here (a disposition, a promote, an import): show it
    /// without waiting out the catalog-change debounce.
    private func catalogEdited() {
        model.refreshTriageSnapshotNow()
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 180, idealWidth: 210, maxWidth: 260)
            if curator && showingExcess {
                ExcessCopiesPane(model: model, store: excessStore)
                    .frame(minWidth: 500)
            } else {
                mainContent
                    .frame(minWidth: 500)
            }
        }
        .onChange(of: selectedIDs) {
            if let first = selectedIDs.first {
                model.focusedMediaIDs = model.focusSet(for: first)
            }
        }
        .onAppear {
            restoreFocus()
            model.triageViewAppeared(query: currentQuery)
        }
        .onDisappear {
            searchDebounce?.cancel()
            model.triageViewDisappeared()
        }
        .onChange(of: selectedFilter) { _, _ in pushQuery() }
        .onChange(of: showOnlineOnly) { _, _ in pushQuery() }
        .onChange(of: stewardReviewIDs) { _, _ in pushQuery() }
        .onChange(of: sortOrder) { _, _ in pushQuery() }
        .onChange(of: searchText) { _, _ in pushQueryAfterTyping() }
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
                        filterRow(.underConstruction)
                        filterRow(.workspace)
                        // Derived from cleanup provenance (recipeID
                        // stamp), so it sits with the workflow flags —
                        // it isn't an alternative to Important/Junk.
                        filterRow(.cleaned)
                    }

                    Divider().padding(.vertical, 6)

                    sidebarSection("DISPOSITION") {
                        filterRow(.untriaged)
                        filterRow(.important)
                        filterRow(.recoverable)
                        filterRow(.suspectedJunk)
                        filterRow(.confirmedJunk)
                    }

                    if curator {
                        Divider().padding(.vertical, 6)
                        CleanUpSidebarSection(store: excessStore, showingExcess: $showingExcess) {
                            showingExcess = true
                            excessStore.refresh(model: model)
                        }
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
        let count = snapshot.value.count(filter)
        return Button {
            selectedFilter = filter
            selectedIDs = []
            showingExcess = false
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
            // The selected-filter highlight SLIDES between rows (Liquid
            // Glass refresh, 2026-10-04), matching the main tab lens. Only
            // the highlight animates — the table swap stays instant.
            .background {
                ZStack {
                    if selectedFilter == filter {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.accentColor.opacity(0.16))
                            .overlay(RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                            .matchedGeometryEffect(id: "triageFilterHighlight", in: filterHighlightNS)
                    }
                }
                .animation(.bouncy(duration: 0.4, extraBounce: 0.08), value: selectedFilter)
            }
        }
        .buttonStyle(.plain)
    }

    private var triageProgress: some View {
        let total = snapshot.value.triageTotal
        let reviewed = snapshot.value.reviewed
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
            // The content steward's pane (trial UI, 2026-10-03; design
            // §5.6): what would tidy the catalog most, one case at a time.
            // Collapsible; everything below it is the Triage tab as before.
            StewardPaneView(snapshot: model.stewardSnapshot,
                            coverage: model.analyzeCoverageSnapshot,
                            onReviewBelow: { ids, label, caseID in reviewFromSteward(ids, label: label, caseID: caseID) })

            toolbar

            if let summary = analysisSummary, showAnalysisSummary {
                analysisBanner(summary)
            }

            if !stewardReviewIDs.isEmpty {
                stewardReviewBanner
            }

            Divider()

            // Built off-main (TriageSnapshotBuilder): filtered, searched,
            // sorted. Blank — not "Nothing to triage" — until the first
            // build lands.
            let rows = snapshot.value.rows
            if !snapshot.value.isReady {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                emptyState
            } else {
                fileTable(rows: rows)
            }

            statusBar
        }
        // Delete-Junk sheets — mirror the catalog-toolbar wiring so users
        // can tag-then-delete without leaving Triage. The confirm sheet
        // shows the frozen set and moves it to the Trash (the only way
        // out); the result sheet shows what moved and what was held back.
        // Single .sheet(item:) drives both confirm and result. Cancel sets
        // junkSheet = nil; Delete buttons don't call dismiss() — the
        // JunkDeleteAction callback transitions the binding from .confirm
        // to .result(...) when the disk pass returns, swapping content
        // atomically inside the same modal presentation. No race possible.
        .sheet(item: $junkSheet) { sheet in
            switch sheet {
            case .confirm(let frozen):
                DeleteConfirmedJunkConfirmSheet(
                    // Frozen when the sheet opened (the Delete Junk button);
                    // Move to Trash acts on exactly this set (design R1).
                    snapshot: frozen,
                    onCancel: { /* dismiss is automatic via @Environment(\.dismiss) */ },
                    onAct: JunkDeleteAction.makeOnAct(model: model, snapshot: frozen) { result, bytesSucceeded in
                        // Atomic content transition: confirm → result.
                        junkSheet = .result(JunkDeletionReport(result), bytesSucceeded)
                    }
                )
            case .result(let report, let bytes):
                DeleteConfirmedJunkResultSheet(report: report, bytesMoved: bytes)
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
        .sheet(item: $transcodeRequest) { request in
            TranscodeSheet(request: request)
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
            Text("\(snapshot.value.rows.count) \(selectedFilter.rawValue.lowercased())")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            // The rows on screen are for the previous filter / search /
            // sort until the new build lands (milliseconds; they stay put).
            if snapshot.value.query != currentQuery {
                Text("\u{00B7}").foregroundColor(.secondary)
                Text("updating…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            if !selectedIDs.isEmpty {
                Text("\u{00B7}").foregroundColor(.secondary)
                Text("\(selectedIDs.count) selected")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            if selectedFilter == .confirmedJunk && snapshot.value.archivedConfirmedJunk > 0 {
                Text("\u{00B7}").foregroundColor(.secondary)
                Text("\(snapshot.value.archivedConfirmedJunk) archived (hidden)")
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

    // Glass toolbar controls (Liquid Glass refresh, 2026-10-04); tints keep
    // the per-action colour cues.
    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: selectedFilter.icon)
                .foregroundColor(selectedFilter.color)
            Text(selectedFilter.rawValue)
                .font(.headline)

            Spacer()

            if selectedFilter == .underConstruction {
                underConstructionButtons
                Divider().frame(height: 18)
            }

            triageButtons

            // Delete Junk — only visible when there's confirmed junk to act on.
            // Sheet pattern mirrors the catalog toolbar so the model code can
            // be reused (confirmedJunk + DeleteConfirmedJunkConfirmSheet).
            // Scoped to the same Triage set the table renders, so the count
            // matches what the user sees (archived junk is in the status
            // bar instead — Rick 2026-06-15). The records themselves are
            // gathered at click time.
            if snapshot.value.count(.confirmedJunk) > 0 {
                Button {
                    openJunkConfirmation()
                } label: {
                    Label("Delete Junk (\(snapshot.value.count(.confirmedJunk)))",
                          systemImage: "trash.fill")
                }
                .vsGlassButtonStyle()
                .tint(.red)
                // A viewer never deletes; the model refuses too (C04-F5).
                .disabled(model.isReadOnly)
                .help("Move the Confirmed Junk to the Trash — the sheet shows exactly which files will move and which are held back, and why")
            }

            // Footage Spectrum trial (2026-10-03): 2–8 rows → one MFO job,
            // the result in its own window. The ids are resolved when the
            // button is pressed, never here.
            Button {
                compareFootage(selectedIDs)
            } label: {
                Label("Compare Footage…", systemImage: "waveform.path.ecg.rectangle")
            }
            .vsGlassButtonStyle()
            .tint(.purple)
            .disabled(!FootageSpectrumPlanner.selectionAllowed(selectedIDs.count))
            .help(FootageSpectrumPlanner.selectionHelp(selectedIDs.count))
            .accessibilityIdentifier("triage.compareFootage")

            Button {
                promoteSelectedToArchive()
            } label: {
                Label("Archive", systemImage: "archivebox.fill")
            }
            .vsGlassButtonStyle()
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
            .vsGlassButtonStyle()
            .tint(.mint)
            .disabled(isImporting)
            .help("Import a media file from disk into the catalog as workspace-active")

            Menu {
                Button("Analyze All (\(snapshot.value.triageTotal))") {
                    runAnalysis(records: model.triageScopeRecords())
                }
                if !selectedIDs.isEmpty {
                    Button("Analyze Selected (\(selectedIDs.count))") {
                        let selected = model.triageScopeRecords().filter { selectedIDs.contains($0.id) }
                        runAnalysis(records: selected)
                    }
                }
            } label: {
                Label(isAnalyzing ? "Analyzing..." : "Analyze", systemImage: "wand.and.stars")
            }
            .menuStyle(.button)
            .vsGlassButtonStyle()
            .controlSize(.large)
            .disabled(snapshot.value.triageTotal == 0 || isAnalyzing)
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

    /// What the orange Junk button marks. A human's Junk click IS the
    /// decision (Rick 2026-10-09, "marking is deciding"), so it marks
    /// Confirmed Junk — the set Delete Junk acts on. Machine guesses stay
    /// Suspected until a human agrees (right-click ▸ Confirm as Junk).
    /// (A `static let` on a View struct ≈ a C++ `static constexpr` member:
    /// one value, readable by tests.)
    static let junkButtonDisposition: MediaDisposition = .confirmedJunk
    static let junkButtonHelp = "Mark selected as Confirmed Junk — Delete Junk moves them to the Trash"

    private var triageButtons: some View {
        HStack(spacing: 6) {
            Button {
                triageSelected(.important)
            } label: {
                Label("Keep", systemImage: "star.fill")
            }
            .vsGlassButtonStyle()
            .tint(.blue)
            .disabled(selectedIDs.isEmpty)
            .help("Mark selected as Important")

            Button {
                triageSelected(.recoverable)
            } label: {
                Label("Repair", systemImage: "wrench.and.screwdriver.fill")
            }
            .vsGlassButtonStyle()
            .tint(.teal)
            .disabled(selectedIDs.isEmpty)
            .help("Mark selected as Recoverable")

            Button {
                triageSelected(Self.junkButtonDisposition)
            } label: {
                Label("Junk", systemImage: "exclamationmark.triangle")
            }
            .vsGlassButtonStyle()
            .tint(.orange)
            .disabled(selectedIDs.isEmpty)
            .help(Self.junkButtonHelp)

            Button {
                triageSelected(.unreviewed)
            } label: {
                Label("Undo", systemImage: "arrow.counterclockwise")
            }
            .vsGlassButtonStyle()
            .disabled(selectedIDs.isEmpty)
            .help("Reset to Unreviewed")
        }
    }

    /// Under Construction bulk actions (ex-Workbench toolbar, merged
    /// 2026-08-19): Promote / Drop to Catalog / Discard over the selection.
    private var underConstructionButtons: some View {
        HStack(spacing: 6) {
            Button {
                let recs = selectedRecords
                model.promoteWorkbenchToArchive(recs)
                selectedIDs = []
                catalogEdited()
            } label: {
                Label("Promote", systemImage: "archivebox.fill")
            }
            .vsGlassProminentButtonStyle()
            .disabled(selectedIDs.isEmpty)
            .help("Promote selected files to the Archive tab")

            Button {
                let recs = selectedRecords
                model.dropWorkbenchToCatalog(recs)
                selectedIDs = []
                catalogEdited()
            } label: {
                Label("Drop to Catalog", systemImage: "tray.and.arrow.down.fill")
            }
            .vsGlassButtonStyle()
            .disabled(selectedIDs.isEmpty)
            .help("Treat as ordinary media — moves off Under Construction but keeps the file")

            Button(role: .destructive) {
                discardUnderConstruction(selectedRecords)
            } label: {
                Label("Discard", systemImage: "trash")
            }
            .vsGlassButtonStyle()
            // A viewer never trashes; the model refuses too.
            .disabled(selectedIDs.isEmpty || model.isReadOnly)
            .help("Move the file to Trash and remove the record (recoverable from Finder until emptied)")
        }
    }

    /// Event handlers only: the selection through the model's id index.
    private var selectedRecords: [VideoRecord] {
        model.triageRecords(withIDs: selectedIDs)
    }

    private func discardUnderConstruction(_ recs: [VideoRecord]) {
        let n = model.discardWorkbench(recs)
        selectedIDs = []
        catalogEdited()
        if n > 0 {
            model.log("Under Construction: discarded \(n) file\(n == 1 ? "" : "s") to Trash")
        }
    }

    // MARK: - Table

    /// `rows` are the snapshot's value rows (TriageRow), already in order.
    /// Cells read the row; anything that WRITES goes to the live record by
    /// id. The per-row reachability check is one cache read for each
    /// VISIBLE row (the Table builds cells lazily), as before.
    private func fileTable(rows: [TriageRow]) -> some View {
        Table(rows, selection: $selectedIDs, sortOrder: $sortOrder) {
            TableColumn("") { rec in
                // Under-construction rows wear the hammer instead of the
                // disposition glyph — they're work in progress, not a
                // review verdict (Workbench merge 2026-08-19).
                if rec.lifecycleStage == .workbench {
                    Image(systemName: "hammer.fill")
                        .foregroundColor(.orange)
                        .help("Under construction — produced by a Combine / Repair / Transcode run; Promote, Drop to Catalog, or Discard")
                } else {
                    Image(systemName: rec.mediaDisposition.icon)
                        .foregroundColor(rec.mediaDisposition.color)
                }
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
                Text(rec.streamTypeLabel)
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
                // The live record (one index lookup), so a tap reads back
                // at once; the row's copy catches up with the next build.
                StarRatingView(rating: Binding(
                    get: { model.record(forID: rec.id)?.starRating ?? rec.starRating },
                    set: { model.record(forID: rec.id)?.starRating = $0 }
                ), onCommit: { model.saveCatalogDebounced() })
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
            MediaOpener.openInQuickTime(model.triageRecords(withIDs: ids))
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

        // Under Construction verbs (ex-Workbench, merged 2026-08-19) —
        // only when the selection contains produced-file rows.
        // Which of them are under construction is read off the snapshot's
        // rows; the records are resolved when a button is pressed.
        let ucIDs = ids.filter { snapshot.value.row($0)?.lifecycleStage == .workbench }
        if !ucIDs.isEmpty {
            Section("Under Construction (\(ucIDs.count))") {
                Button {
                    model.promoteWorkbenchToArchive(underConstructionRecords(ucIDs))
                    selectedIDs = []
                    catalogEdited()
                } label: {
                    Label("Promote to Archive", systemImage: "archivebox.fill")
                }
                Button {
                    model.dropWorkbenchToCatalog(underConstructionRecords(ucIDs))
                    selectedIDs = []
                    catalogEdited()
                } label: {
                    Label("Drop to Catalog", systemImage: "tray.and.arrow.down.fill")
                }
                Button(role: .destructive) {
                    discardUnderConstruction(underConstructionRecords(ucIDs))
                } label: {
                    Label("Discard (move to Trash)", systemImage: "trash")
                }
            }
        }

        Divider()

        // Transcode — Pass C (Rick 2026-06-14). MFO verbs work from
        // triage too: two-preset faithful conversion for FCP edits or
        // long-term archive. Single-row only (matches Show in Catalog
        // / Reveal in Finder above — these are per-file operations).
        // Disabled when the file is offline OR a transcode is already
        // running for it.
        let singleRec: TriageRow? = (count == 1)
            ? ids.first.flatMap { snapshot.value.row($0) }
            : nil
        let transcodeRunning: Bool = {
            guard let r = singleRec, let center = fileOpsCenterReference else { return false }
            return center.jobs.contains { job in
                guard job.state.isActive, let t = job as? TranscodeJob else { return false }
                return t.record.id == r.id
            }
        }()
        let transcodeBlocked = (singleRec == nil)
            || !VolumeReachability.isReachable(path: singleRec?.fullPath ?? "")
            || transcodeRunning

        Menu {
            Button("For Editing…") {
                if let r = singleRec.flatMap({ model.record(forID: $0.id) }) {
                    configureTranscode(for: r, preset: .editingLT)
                }
            }
            .disabled(transcodeBlocked)
            .accessibilityIdentifier("catalog.row.transcodeEditing")

            // Mirrors the catalog row menu: archival nests an HEVC
            // access copy and a verified FFV1 v3 preservation master.
            Menu("For Archival…") {
                Button("Access Copy (HEVC 10-bit)") {
                    if let r = singleRec.flatMap({ model.record(forID: $0.id) }) {
                        configureTranscode(for: r, preset: .archival)
                    }
                }
                .disabled(transcodeBlocked)
                .accessibilityIdentifier("catalog.row.transcodeArchival")

                Button("Preservation Master (FFV1 v3, verified)") {
                    if let r = singleRec.flatMap({ model.record(forID: $0.id) }) {
                        configureTranscode(for: r, preset: .preservation)
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
            compareFootage(ids)
        } label: {
            Label("Compare Footage…", systemImage: "waveform.path.ecg.rectangle")
        }
        .disabled(!FootageSpectrumPlanner.selectionAllowed(count))
        .help(FootageSpectrumPlanner.selectionHelp(count))

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
            if let rec = ids.first.flatMap({ model.record(forID: $0) }) {
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
            Image(systemName: selectedFilter == .underConstruction ? "hammer" : "checkmark.circle")
                .font(.system(size: 40))
                .foregroundColor(selectedFilter == .underConstruction ? .secondary : .green)
            Text(selectedFilter == .underConstruction ? "No work in progress" : "Nothing to triage")
                .font(.headline)
                .foregroundColor(.secondary)
            Text(selectedFilter == .underConstruction
                 ? "Run a Combine batch from the Catalog tab — new files land here for review before you promote them to the Archive."
                 : "All media has been reviewed or archived. Scan more volumes in the Catalog tab to populate this list.")
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

    /// Delete Junk: freeze the set the sheet will show — and the only set
    /// Move to Trash may act on (design R1) — then open the sheet. Held-back
    /// files (Master Archive, Read-only drives) are in the snapshot WITH
    /// their reason. The freeze is O(n) on main plus one stat per file
    /// off-main — never in a view body.
    private func openJunkConfirmation() {
        let records = model.triageConfirmedJunkRecords()
        Task { @MainActor in
            junkSheet = .confirm(await model.freezeJunkSnapshot(records))
        }
    }

    /// The under-construction records among `ids`, at click time.
    private func underConstructionRecords(_ ids: Set<UUID>) -> [VideoRecord] {
        model.triageRecords(withIDs: ids).filter { $0.lifecycleStage == .workbench }
    }

    /// O(selection): each id goes through the model's id index (this was
    /// a linear scan of the catalog per selected id).
    private func applyDisposition(_ disposition: MediaDisposition, to ids: Set<UUID>) {
        for rec in model.triageRecords(withIDs: ids) {
            rec.mediaDisposition = disposition
            if rec.lifecycleStage == .cataloged && disposition != .unreviewed {
                rec.lifecycleStage = .reviewing
            }
        }
        model.saveCatalogDebounced()
        catalogEdited()
        noteStewardReviewDecision(disposition, on: ids)
    }

    /// QA F8: a decision pressed while a steward card's clips are shown.
    /// When every one of them has a person's decision, the card is
    /// finished: its rebuilt facts (the clips marked Junk here) are stored
    /// so it stays gone until they move. O(selection) + O(clips marked Junk).
    private func noteStewardReviewDecision(_ disposition: MediaDisposition, on ids: Set<UUID>) {
        guard stewardReview.isActive, stewardReview.note(disposition, on: ids) else { return }
        let junked = model.triageRecords(withIDs: stewardReview.markedJunk)
        let facts = StewardFacts(bytes: junked.reduce(Int64(0)) { $0 + max(0, $1.sizeBytes) }, count: junked.count)
        StewardSkipStore(defaults: model.stewardDefaults).markReviewed(caseID: stewardReview.caseID, facts: facts)
        let line = "Tidy suggestions: reviewed — \(StewardCaseKind.junk.chip) · \(stewardReview.ids.count.formatted()) files decided"
        model.log(line)
        appLog.write(line)
        stewardReview = StewardReview()
        model.scheduleStewardRefresh()
    }

    /// "Compare Footage…": the selection, through the
    /// model's id index (O(selection)) → an MFO job → the Footage Spectrum
    /// window, which says "Preparing…" until the page exists.
    private func compareFootage(_ ids: Set<UUID>) {
        guard let center = fileOpsCenterReference,
              FootageSpectrumPlanner.selectionAllowed(ids.count) else { return }
        // The planner orders them (archive copy, then the biggest).
        // nil = refused outright (a viewer): the console says why, no window.
        guard model.startFootageSpectrum(ids: Array(ids), title: "\(ids.count) videos from Triage",
                                         center: center, source: "Triage") != nil else { return }
        FootageSpectrumWindowOpener.open(using: openWindow, source: "triage")
    }

    private func showInCatalog(_ id: UUID) {
        model.focusedMediaIDs = model.focusSet(for: id)
        model.pendingCatalogSelection = id
        model.pendingCatalogPairMode = false
        selectedTab = 1
    }

    private func promoteSelectedToArchive() {
        for rec in model.triageRecords(withIDs: selectedIDs) {
            rec.lifecycleStage = .archived
        }
        selectedIDs = []
        model.saveCatalogDebounced()
        catalogEdited()
    }

    // MARK: - Import to Workspace (Pass B)

    private func configureTranscode(for record: VideoRecord, preset: TranscodePreset) {
        transcodeRequest = TranscodeRequest(record: record, initialPreset: preset)
    }

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
        catalogEdited()
    }

    // MARK: - Steward review (trial UI, 2026-10-03)

    /// "Review these below" on a steward card: show just those records in
    /// the table — every disposition, no search — with NOTHING selected
    /// (QA 2026-10-03, F3: one click on Junk must never mark a whole
    /// cluster by accident; the person selects what they mean). Nothing is
    /// changed.
    private func reviewFromSteward(_ ids: Set<UUID>, label: String, caseID: String) {
        selectedFilter = .all
        searchText = ""
        stewardReviewIDs = ids
        stewardReviewLabel = label
        stewardReview = StewardReview(caseID: caseID, ids: ids)
        selectedIDs = []
    }

    private var stewardReviewBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundColor(.accentColor)
            Text("Showing \(stewardReviewLabel)")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            if showOnlineOnly {
                Text("· files on drives that are not connected are hidden")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Show everything") {
                stewardReviewIDs = []
                stewardReviewLabel = ""
                stewardReview = StewardReview()
                selectedIDs = []
            }
            .accessibilityIdentifier("steward.review.showEverything")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
        .accessibilityIdentifier("steward.review.banner")
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
        // Scores and dispositions just changed in place.
        catalogEdited()
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
