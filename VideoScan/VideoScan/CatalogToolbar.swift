// CatalogToolbar.swift
// Catalog tab toolbar (post-scan actions: correlate, combine, search,
// export) plus the search-grammar help popover the toolbar presents.
// Extracted verbatim from CatalogHelpers.swift (refactor 2026-06-11).

import SwiftUI

// MARK: - Toolbar (post-scan actions: correlate, combine, search, export)

struct CatalogToolbar<Dashboard: View>: View {
    @EnvironmentObject var model: VideoScanModel
    let isScanning: Bool
    let isCombining: Bool
    let isCorrelating: Bool
    let isAnalyzingDuplicates: Bool
    let correlateStatus: String
    let duplicateStatus: String
    let videoOnlyCount: Int
    let audioOnlyCount: Int
    let hasRecords: Bool
    let hasCorrelatedPairs: Bool
    let outputCSVPath: String
    let selectedIDs: Set<UUID>
    @Binding var showCombineSheet: Bool
    @Binding var showRelocateSheet: Bool
    @Binding var showDashboard: Bool
    @Binding var searchText: String
    @Binding var showInspector: Bool
    let cacheCount: Int
    let dashboard: DashboardState
    let onStopCombine: () -> Void
    let onCorrelateAll: () -> Void
    let onCorrelateSelected: () -> Void
    let onCorrelateAcrossVolumes: () -> Void
    let onAnalyzeDuplicatesAll: () -> Void
    let onAnalyzeDuplicatesSelected: () -> Void
    let volumesWithDeletableDups: [(path: String, count: Int)]
    let onDeleteDuplicates: (String, Int) -> Void
    let onClearResults: () -> Void
    let onClearCache: () -> Void
    let onScanAvidBins: () -> Void
    let avidBinCount: Int
    let avidBinFiles: Int
    @Binding var showPairsOnly: Bool
    @Binding var viewFilters: Set<CatalogViewFilter>
    /// When on, purged rows render alongside active rows (italic + orange).
    /// Persisted in @AppStorage("catalogShowRemoved") by the parent.
    @Binding var showRemoved: Bool
    @ViewBuilder let dashboardContent: () -> Dashboard

    // MARK: Delete-Confirmed-Junk sheet state
    //
    // Owned by the toolbar so the entry point and the two sheets live in
    // one file — the parent doesn't need to know about either sheet. The
    // workflow is:
    //   1. user clicks "Delete Confirmed Junk… (N)" → showConfirmSheet=true
    //   2. confirm sheet's "Move to Trash" or "Delete Permanently" → run
    //      model.deleteConfirmedJunk, stash result + mode, dismiss confirm,
    //      open result sheet
    //   3. result sheet's OK → dismiss result.
    //
    // SwiftUI `@State` here ≈ a C++ member variable that triggers a view
    // re-render when written. The struct is a value type but @State boxes
    // its storage so mutations persist across re-renders.
    @State private var showJunkConfirmSheet = false
    @State private var showJunkResultSheet = false
    @State private var junkResult: VideoScanModel.JunkDeletionResult?
    @State private var junkResultMode: VideoScanModel.JunkDeletionMode = .toTrash
    @State private var junkResultBytesSucceeded: Int64 = 0
    /// Search-syntax help popover toggled by the `?` button next to
    /// the catalog search field. Local UI state — no need to persist.
    @State private var showSearchHelp = false
    /// Debounced mirror of `searchText`. Updated 250ms after the last
    /// keystroke so the toolbar hit-count badge doesn't recompute on
    /// every character typed. Rick 2026-06-09: this + the CatalogSearch-
    /// Index were the two-part fix for sluggish search typing.
    @State private var debouncedSearchText: String = ""
    /// Cancellable task that fires 250ms after the last keystroke and
    /// propagates `searchText` → `debouncedSearchText`. Reset each
    /// keystroke so only the trailing edge ever lands.
    @State private var searchDebounceTask: Task<Void, Never>? = nil

    /// Active (non-purged) records currently marked .confirmedJunk. This is
    /// the same query the model exposes via `confirmedJunkRecords`; we read
    /// it directly off the published `records` array so the button label
    /// updates live as the user tags more rows.
    private var confirmedJunk: [VideoRecord] {
        model.records.filter {
            $0.mediaDisposition == .confirmedJunk && $0.purgedAt == nil
        }
    }

    /// Memoized badge count for the catalog search bar. A @State cache,
    /// NOT a computed property: this toolbar sits in a nested hosting
    /// view whose constraint passes re-evaluate `body` constantly, and
    /// post-dossier haystacks are multi-KB transcripts. Computing the
    /// scan in `body` (twice — text + color) was 87% of main-thread
    /// time in the 2026-06-10 beachball. Recomputed only when the
    /// debounced query or the record set changes.
    @State private var searchHitCount: Int = 0

    private func recomputeSearchHitCount() {
        guard !debouncedSearchText.isEmpty else {
            searchHitCount = 0
            return
        }
        searchHitCount = model.searchIndex.count(records: model.records,
                                                 query: debouncedSearchText)
    }

    /// "+ Filter" menu next to the search field. Each pick appends a
    /// field-prefix token (or a complete `stream:...` token) to the
    /// current searchText so users discover the grammar by clicking
    /// instead of memorizing it. Rick 2026-06-16. The menu deliberately
    /// uses friendly labels (e.g. "Transcript", not "transcript:") and
    /// surfaces the streamType values as a submenu so the user picks
    /// from a finite list rather than typing free-form.
    private var filterInsertMenu: some View {
        Menu {
            Section("Field filters") {
                Button("Filename")    { insertSearchPrefix("filename:") }
                Button("Transcript")  { insertSearchPrefix("transcript:") }
                Button("Captions")    { insertSearchPrefix("caption:") }
                Button("OCR text")    { insertSearchPrefix("ocr:") }
                Button("People")      { insertSearchPrefix("people:") }
                Button("Notes")       { insertSearchPrefix("notes:") }
            }
            Section("Structural") {
                Menu("Stream type") {
                    Button("Audio only")     { insertSearchToken("stream:audio") }
                    Button("Video only")     { insertSearchToken("stream:video") }
                    Button("Both")           { insertSearchToken("stream:both") }
                    Button("ffprobe failed") { insertSearchToken("stream:failed") }
                    Button("No streams")     { insertSearchToken("stream:empty") }
                }
                Button("Year…")   { insertSearchPrefix("year:") }
                Button("Decade…") { insertSearchPrefix("decade:") }
            }
        } label: {
            Image(systemName: "plus.circle")
                .foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Insert a filter (filename:, transcript:, stream:audio, year:…)")
    }

    /// Append a field-prefix at the end of the search field, with a
    /// leading space if needed. Cursor stays at end so the user can
    /// type the value immediately. We don't try to be cursor-aware —
    /// SwiftUI's TextField doesn't expose cursor position, and
    /// end-append matches the common case (build the query left-to-
    /// right) without false precision.
    private func insertSearchPrefix(_ prefix: String) {
        if searchText.isEmpty {
            searchText = prefix
        } else {
            let needsSpace = !searchText.hasSuffix(" ")
            searchText = searchText + (needsSpace ? " " : "") + prefix
        }
    }

    /// Same as insertSearchPrefix but for complete tokens (stream:audio
    /// is a complete filter, not a "needs a value" prefix). Adds a
    /// trailing space so the user can continue typing.
    private func insertSearchToken(_ token: String) {
        if searchText.isEmpty {
            searchText = token + " "
        } else {
            let needsSpace = !searchText.hasSuffix(" ")
            searchText = searchText + (needsSpace ? " " : "") + token + " "
        }
    }

    private var canCombine: Bool {
        guard !isScanning && !isCombining else { return false }
        return hasCorrelatedPairs
    }

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Clear Results") { onClearResults() }
                    .disabled(!hasRecords)
                Divider()
                Button("Clear All Cache — All Volumes (\(cacheCount) entries)") { onClearCache() }
                    .disabled(cacheCount == 0)
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 80)
            .disabled(isScanning)
            .help("Clear catalog results or cached probe data")

            Divider().frame(height: 22)

            VStack(spacing: 2) {
                Menu {
                    Button("Correlate All", action: onCorrelateAll)
                    Button("Correlate Selected", action: onCorrelateSelected)
                        .disabled(selectedIDs.isEmpty)
                    Divider()
                    Button("Find A/V Pairs Across Volumes", action: onCorrelateAcrossVolumes)
                        .accessibilityIdentifier("catalog.correlate.findPairsAcrossVolumes")
                    Divider()
                    Toggle("Show Pairs Only", isOn: $showPairsOnly)
                        .disabled(!hasCorrelatedPairs)
                } label: {
                    if isCorrelating {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("Correlating…")
                        }
                    } else {
                        Label("Correlate", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .menuStyle(.borderlessButton)
                .disabled(isScanning || isCorrelating || !hasRecords)
                .accessibilityIdentifier("catalog.correlate.menu")
                .help("Match video-only files with their corresponding audio-only files (e.g. Avid MXF pairs)")

                if !correlateStatus.isEmpty {
                    Text(correlateStatus)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(isCorrelating ? .secondary : .green)
                        .lineLimit(1)
                } else if videoOnlyCount > 0 || audioOnlyCount > 0 {
                    Text("\(videoOnlyCount)V + \(audioOnlyCount)A candidates")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 120)

            VStack(spacing: 2) {
                Menu {
                    Button("Analyze All", action: onAnalyzeDuplicatesAll)
                    Button("Analyze Selected", action: onAnalyzeDuplicatesSelected)
                        .disabled(selectedIDs.isEmpty)

                    if !volumesWithDeletableDups.isEmpty {
                        Divider()
                        Menu("Delete Duplicates on Volume…") {
                            ForEach(volumesWithDeletableDups, id: \.path) { vol in
                                Button("\(URL(fileURLWithPath: vol.path).lastPathComponent) — \(vol.count) file\(vol.count == 1 ? "" : "s")") {
                                    onDeleteDuplicates(vol.path, vol.count)
                                }
                            }
                        }
                    }
                } label: {
                    if isAnalyzingDuplicates {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("Analyzing…")
                        }
                    } else {
                        Label("Duplicates", systemImage: "doc.on.doc")
                    }
                }
                .menuStyle(.borderlessButton)
                .disabled(isScanning || isAnalyzingDuplicates || !hasRecords)
                .help("Find duplicate files by comparing hash, duration, filename, resolution, and other signals")

                if !duplicateStatus.isEmpty {
                    Text(duplicateStatus)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(isAnalyzingDuplicates ? .secondary : .yellow)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 120)

            VStack(spacing: 2) {
                Button(action: onScanAvidBins) {
                    HStack(spacing: 4) {
                        Label("Avid Bins", systemImage: "film.stack")
                        if avidBinCount > 0 {
                            Text("\(avidBinCount) clips")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isScanning)
                .help("Scan for Avid .avb bin files and extract clip metadata — badge shows total clips found across all bins")

                if avidBinFiles > 0 {
                    Text("\(avidBinFiles) bins · \(avidBinCount) clips")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.cyan)
                        .lineLimit(1)
                }
            }

            Button(action: { showCombineSheet = true }) {
                Label("Combine", systemImage: "rectangle.stack.badge.plus")
            }
            .buttonStyle(.bordered)
            .disabled(!canCombine && !isCombining)
            .accessibilityIdentifier("catalog.combine.openSheet")
            .help("Mux correlated video + audio pairs into combined files using ffmpeg (no re-encode)")

            Button(action: { showRelocateSheet = true }) {
                Label("Migrate…", systemImage: "externaldrive.badge.checkmark")
            }
            .buttonStyle(.bordered)
            .disabled(!hasRecords)
            .accessibilityIdentifier("catalog.relocate.openSheet")
            .help("Copy catalogued files from a flaky source volume onto a healthier destination and rewrite catalog paths.")

            if isCombining {
                Button(action: onStopCombine) {
                    Label("Stop Combine", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            // Delete Confirmed Junk lives in the Triage toolbar (which has
            // the dispositions + analyze + filters in one place). The
            // confirm/result sheets stay attached below for sheet plumbing
            // — they're presented from this view when invoked from any
            // future entry point in the catalog row context menu.

            Button {
                CatalogScanWindowController.shared.show(dashboard: dashboard, model: model)
            } label: {
                Label("Realtime Scan", systemImage: "waveform.path.ecg.rectangle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)

            if !outputCSVPath.isEmpty {
                Button(action: {
                    NSWorkspace.shared.selectFile(outputCSVPath, inFileViewerRootedAtPath: "")
                }) {
                    Label("Show CSV", systemImage: "doc.text")
                }
                .buttonStyle(.bordered)
            }

            Divider().frame(height: 22)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Try: donna 1990s · mark dan grampa · cape cod beach",
                          text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 320)
                    .accessibilityIdentifier("catalog.searchField")
                    .onChange(of: searchText) { _, newValue in
                        // Cancel any pending debounce so only the trailing
                        // edge of typing lands on debouncedSearchText.
                        searchDebounceTask?.cancel()
                        if newValue.isEmpty {
                            // Empty-clear is instant — no point waiting.
                            debouncedSearchText = ""
                            return
                        }
                        searchDebounceTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            if !Task.isCancelled {
                                debouncedSearchText = newValue
                            }
                        }
                    }
                    .onChange(of: debouncedSearchText) { _, _ in
                        recomputeSearchHitCount()
                    }
                    .onChange(of: model.records.count) { _, _ in
                        recomputeSearchHitCount()
                    }
                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                        debouncedSearchText = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(6)
            // Searching... indicator. Shows while the user is mid-typing
            // and the 250 ms debounce window hasn't yet propagated
            // searchText → debouncedSearchText. Distinguishes the "still
            // working" state from the "search complete, zero results"
            // state (Rick 2026-06-16 — empty results were ambiguous).
            if !searchText.isEmpty && searchText != debouncedSearchText {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                    Text("Searching\u{2026}")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .help("Filter recomputes 250 ms after you stop typing.")
            } else if !searchText.isEmpty {
                // Match count badge — visible only while the search has
                // settled (debouncedSearchText caught up). Counts against
                // the full record set so the badge reflects pre-filter
                // results (i.e. before View-menu filters like Online/Has
                // Family further narrow). Reads the memoized
                // searchHitCount — never scan records inside body.
                Text("\(searchHitCount) of \(model.records.count)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(searchHitCount == 0 ? .red : .secondary)
                    .help("Search hits across filename, people tags, captions, transcripts, and OCR text. Each whitespace-separated word must match somewhere on the record (AND). Year shorthand: 1990s · 199x.")
            }

            // "+ Filter" menu — inserts a field-prefix token at the
            // end of the search field so users discover the grammar
            // through clicks instead of reading the help popover.
            // Rick 2026-06-16.
            filterInsertMenu

            // Help popover — surfaces the field-prefix grammar so users
            // don't have to read a docs file to discover `people:donna`
            // / `year:1989..1995` / `caption:beach`. Added 2026-06-08
            // alongside the field-prefix feature itself; without this
            // the feature is invisible.
            Button {
                showSearchHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Search syntax reference")
            .popover(isPresented: $showSearchHelp, arrowEdge: .bottom) {
                CatalogSearchHelpPopover()
            }

            // Persistent dossier progress chip — small ring + N/M label.
            // Click opens the full Dossier Dashboard (⌘⇧O). Always
            // visible while in the catalog tab so Rick can monitor
            // fleet progress without keeping the dashboard window open.
            DossierToolbarChip(model: model)

            Menu {
                ForEach(CatalogViewFilter.allCases, id: \.self) { filter in
                    Toggle(isOn: Binding(
                        get: { viewFilters.contains(filter) },
                        set: { on in
                            if on { viewFilters.insert(filter) }
                            else  { viewFilters.remove(filter) }
                        }
                    )) {
                        Label(filter.rawValue, systemImage: filter.icon)
                    }
                }
                if !viewFilters.isEmpty {
                    Divider()
                    Button("Clear All Filters") { viewFilters.removeAll() }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "line.3.horizontal.decrease.circle\(viewFilters.isEmpty ? "" : ".fill")")
                    Text("View")
                }
            }
            .menuStyle(.borderlessButton)
            .frame(width: 70)
            .help("Filter catalog results")

            // Show-removed toggle — composes with online/View filters above.
            // Purged rows render italic + orange in the table when on.
            // Persisted in @AppStorage by CatalogView.
            Toggle(isOn: $showRemoved) {
                Label("Show removed", systemImage: showRemoved
                      ? "eye.trianglebadge.exclamationmark"
                      : "eye.slash")
                    .labelStyle(.titleAndIcon)
                    .foregroundColor(showRemoved ? .orange : .secondary)
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help(showRemoved
                  ? "Removed (purged) records are visible — italic + orange. Click to hide."
                  : "Click to show removed records alongside active ones.")

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showInspector.toggle()
                }
            } label: {
                Image(systemName: showInspector ? "sidebar.right" : "sidebar.right")
                    .font(.system(size: 14))
                    .foregroundColor(showInspector ? .accentColor : .secondary)
            }
            .buttonStyle(.bordered)
            .help(showInspector ? "Hide Inspector" : "Show Inspector")

            dashboardContent()
        }
        .padding(10)
        .background(Color(NSColor.windowBackgroundColor))
        // Confirmation sheet — picks Move to Trash vs Delete Permanently.
        .sheet(isPresented: $showJunkConfirmSheet) {
            let snapshot = confirmedJunk
            DeleteConfirmedJunkConfirmSheet(
                records: snapshot,
                onCancel: { /* dismiss is automatic */ },
                onAct: JunkDeleteAction.makeOnAct(model: model) { result, mode, bytesSucceeded in
                    junkResult = result
                    junkResultMode = mode
                    junkResultBytesSucceeded = bytesSucceeded
                    // Chained .sheet trap: flipping the result-sheet
                    // flag synchronously collides with the confirm
                    // sheet's dismiss animation — SwiftUI only allows
                    // one sheet per view at a time. Defer just past
                    // the dismiss animation window.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showJunkResultSheet = true
                    }
                }
            )
        }
        // Result sheet — shows succeeded/missing/failed breakdown.
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

}

// MARK: - Catalog search help popover
//
// Added 2026-06-08 alongside the field-prefix grammar (Phase B of the
// Google-like search). The grammar is useless if users can't discover
// it — a `?` button next to the search field shows this card with
// concrete examples. Keep examples narrow and copy-paste-ready;
// no big tables, no theory.

private struct CatalogSearchHelpPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tint)
                Text("Search syntax")
                    .font(.headline)
            }

            Group {
                Text("Plain words — match anywhere on the record")
                    .font(.subheadline.weight(.medium))
                CatalogSearchExampleRow(query: "donna",
                                        meaning: "any record mentioning donna")
                CatalogSearchExampleRow(query: "mark dan grampa",
                                        meaning: "all three names somewhere on the record (AND)")
                CatalogSearchExampleRow(query: "cape cod 1990s",
                                        meaning: "cape, cod, and a 1990s year signal")
                CatalogSearchExampleRow(query: "elevator, cape, donna",
                                        meaning: "commas and semicolons also separate tokens")
            }

            Divider()

            Group {
                Text("Quoted phrases — match the literal string")
                    .font(.subheadline.weight(.medium))
                CatalogSearchExampleRow(query: "\"cape cod\"",
                                        meaning: "the two words side-by-side, not separately")
                CatalogSearchExampleRow(query: "\"hello, world\"",
                                        meaning: "the comma is part of the phrase, not a separator")
            }

            Divider()

            Group {
                Text("Year shorthand")
                    .font(.subheadline.weight(.medium))
                CatalogSearchExampleRow(query: "1990s",
                                        meaning: "decade 1990–1999")
                CatalogSearchExampleRow(query: "199x",
                                        meaning: "same — decade wildcard")
            }

            Divider()

            Group {
                Text("Field-prefix grammar")
                    .font(.subheadline.weight(.medium))
                CatalogSearchExampleRow(query: "people:donna",
                                        meaning: "donna in the people tags only (not paths/captions)")
                CatalogSearchExampleRow(query: "transcript:birthday",
                                        meaning: "birthday in the audio transcript")
                CatalogSearchExampleRow(query: "caption:guitar",
                                        meaning: "guitar in scene captions")
                CatalogSearchExampleRow(query: "ocr:1991",
                                        meaning: "1991 in burned-in text / OCR")
                CatalogSearchExampleRow(query: "name:cape",
                                        meaning: "cape in the filename (not path)")
                CatalogSearchExampleRow(query: "notes:keeper",
                                        meaning: "your notes (otherwise excluded)")
                CatalogSearchExampleRow(query: "year:1991",
                                        meaning: "single year")
                CatalogSearchExampleRow(query: "year:1989..1995",
                                        meaning: "year range")
                CatalogSearchExampleRow(query: "decade:1990s",
                                        meaning: "decade")
                CatalogSearchExampleRow(query: "stream:audio",
                                        meaning: "audio-only files (or video / both / failed)")
            }

            Divider()

            Text("Field-prefix tokens compose with plain words. Every token must match (AND). The \u{201C}+ Filter\u{201D} menu next to the search field inserts prefixes for you.")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: 360, alignment: .leading)
        }
        .padding(16)
        .frame(width: 440)
    }
}

private struct CatalogSearchExampleRow: View {
    let query: String
    let meaning: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(query)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.12))
                )
                .frame(minWidth: 140, alignment: .leading)
            Text(meaning)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
    }
}
