// CatalogToolbar.swift
// Catalog tab toolbar (post-scan actions: correlate, combine, search,
// export) plus the search-grammar help popover the toolbar presents.
// Extracted verbatim from CatalogHelpers.swift (refactor 2026-06-11).

import SwiftUI

// MARK: - Toolbar (post-scan actions: correlate, combine, search, export)

struct CatalogToolbar<Dashboard: View>: View {
    @EnvironmentObject var model: VideoScanModel
    @Environment(\.openWindow) private var openWindow
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
    /// Parent's debounced mirror of `searchText` (GH #123 PR B: the
    /// toolbar's own private 250 ms debouncer is gone — ContentView owns
    /// the ONE debouncer and passes the settled value down). Read only
    /// for the "Searching…" vs badge display decision.
    let debouncedSearchText: String
    /// Search-hit badge count, computed by CatalogContent as a
    /// by-product of the table filter pass and handed down by the parent
    /// (GH #123 PR B — this used to be a SECOND full catalog scan per
    /// settled keystroke, doubling every search's main-thread cost).
    /// Semantics unchanged: hits over pfSearchBadgeBase (purge +
    /// set-aside pre-filter), pinned by CatalogSearchBudgetSensorTests.
    let searchHitCount: Int
    @Binding var showInspector: Bool
    let cacheCount: Int
    let dashboard: DashboardState
    let onStopCombine: () -> Void
    let onCorrelateAll: () -> Void
    let onCorrelateSelected: () -> Void
    let onCorrelateAcrossVolumes: () -> Void
    let onClearAndRecorrelateAll: () -> Void
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
    /// Baseline reachability opt-out (2026-07-20). Reachable-only is the
    /// DEFAULT; when this is ON the catalog also shows media on disconnected
    /// volumes. Persisted in @AppStorage("catalog.showDisconnectedMedia") by
    /// the parent. NOT part of `viewFilters` — "Clear All Filters" leaves it.
    @Binding var showDisconnectedMedia: Bool
    /// When on, purged rows render alongside active rows (italic + orange).
    /// Persisted in @AppStorage("catalogShowRemoved") by the parent.
    @Binding var showRemoved: Bool
    /// When on, set-aside rows (catalog scope: photos / music / audio with
    /// no matching video) render alongside active rows (italic + purple).
    /// Persisted in @AppStorage("catalogShowSetAside") by the parent.
    @Binding var showSetAside: Bool
    /// When on, superseded rows (originals retired by a confirmed repair,
    /// GH #132) render alongside active rows (italic + brown). Session-
    /// scoped @State in the parent — deliberately NOT persisted.
    @Binding var showSuperseded: Bool

    /// True when the View menu holds any non-default state — an active
    /// filter, or one of the hidden-record reveals that moved into the
    /// menu on 2026-08-11. Drives the menu's filled icon so a toggle
    /// buried one click deep still announces itself.
    private var viewIsModified: Bool {
        !viewFilters.isEmpty || showRemoved || showSetAside || showSuperseded
    }
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
    // MARK: - Toolbar layout tuning
    //
    // The toolbar deliberately mirrors the VOLUME TABLE's column positions
    // above it, so the eye reads down a column and lands on the related
    // control. TWO fixed insets do that. A flexible Spacer anywhere between
    // them would collapse the alignment by absorbing all the slack — which
    // is exactly what pinned the Archivist to the far right before.
    //
    //   searchLeftInset — gap from the last left-hand control to the
    //                     magnifier.  Target: magnifier under MEDIA SIZE.
    //   archivistGap    — gap from the `?` help button to the sparkles.
    //                     Target: sparkles under PHASE.
    //
    // Bigger = further right. Tune these two and rebuild; nothing else in
    // the row needs touching. Rick 2026-08-14.
    static var searchLeftInset: CGFloat { 460 }
    static var archivistGap: CGFloat { 70 }

    @State private var showJunkConfirmSheet = false
    @State private var showJunkResultSheet = false
    @State private var junkResult: VideoScanModel.JunkDeletionResult?
    @State private var junkResultMode: VideoScanModel.JunkDeletionMode = .toTrash
    @State private var junkResultBytesSucceeded: Int64 = 0
    /// Search-syntax help popover toggled by the `?` button next to
    /// the catalog search field. Local UI state — no need to persist.
    @State private var showSearchHelp = false
    /// Family Archivist ask popover (P2 front door) — plain English in,
    /// composed search grammar out, visible in the search field.
    @State private var showAskPopover = false

    /// Active (non-purged) records currently marked .confirmedJunk. This is
    /// the same query the model exposes via `confirmedJunkRecords`; we read
    /// it directly off the published `records` array so the button label
    /// updates live as the user tags more rows.
    private var confirmedJunk: [VideoRecord] {
        model.records.filter {
            $0.mediaDisposition == .confirmedJunk && $0.purgedAt == nil
        }
    }

    // The memoized badge count + its recompute chain lived here from
    // 2026-06-10 to 2026-07-19. GH #123 PR B removed them: the count
    // was a SECOND full catalog scan on every settled keystroke —
    // identical work to the table filter running 250 ms-debounced in
    // parallel. CatalogContent.computeFiltered() now derives the badge
    // count from its own single pass — over the same purge → set-aside
    // → kind-facet base (#124) the old pfSearchBadgeBase scan used —
    // and publishes it up through ContentView (`searchHitCount` above).

    /// Facet chip binding — explicit save() on every change (@Published
    /// kills didSet; same pattern as the catalog-scope binding in
    /// ScanOptionsMenu).
    private var kindFacetBinding: Binding<CatalogKindFacet> {
        Binding(
            get: { model.kindFacetSetting.facet },
            set: { newVal in
                model.kindFacetSetting.facet = newVal
                model.saveKindFacetSetting()
            }
        )
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
                // GH #124: the facet-family grammar. type:video is the
                // video-BEARING bucket (V+A or video-only), matching the
                // toolbar facet chip's Videos spelling.
                Menu("Media kind") {
                    Button("Video (any)")    { insertSearchToken("type:video") }
                    Button("Video only")     { insertSearchToken("type:video-only") }
                    Button("Audio only")     { insertSearchToken("type:audio") }
                    Button("Video + audio")  { insertSearchToken("type:both") }
                }
                Menu("Stream type") {
                    Button("Audio only")     { insertSearchToken("stream:audio") }
                    Button("Video only")     { insertSearchToken("stream:video") }
                    Button("Both")           { insertSearchToken("stream:both") }
                    Button("ffprobe failed") { insertSearchToken("stream:failed") }
                    Button("No streams")     { insertSearchToken("stream:empty") }
                }
                Button("Codec…")  { insertSearchPrefix("codec:") }
                Button("Year…")   { insertSearchPrefix("year:") }
                Button("Decade…") { insertSearchPrefix("decade:") }
            }
        } label: {
            // Matched to the `?` beside it (Rick 2026-08-14). Both are
            // discovery affordances sitting next to an 18pt magnifier; at
            // body default they read as specks rather than as buttons.
            Image(systemName: "plus.circle")
                .font(.system(size: 17, weight: .medium))
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
                    Button("Correlate A/V", action: onCorrelateAll)
                    Button("Correlate A/V for Selected", action: onCorrelateSelected)
                        .disabled(selectedIDs.isEmpty)
                    Divider()
                    Button("Find A/V Pairs Across Volumes", action: onCorrelateAcrossVolumes)
                        .accessibilityIdentifier("catalog.correlate.findPairsAcrossVolumes")
                    Divider()
                    // Analysis-ledger (2026-07-05): Correlate All is
                    // incremental — existing pairs are never touched. This
                    // is the ONLY from-scratch redo, and it confirms first.
                    Button("Clear && Re-correlate All…", role: .destructive,
                           action: onClearAndRecorrelateAll)
                        .accessibilityIdentifier("catalog.correlate.clearAndRecorrelate")
                    Divider()
                    Toggle("Show Pairs Only", isOn: $showPairsOnly)
                        .disabled(!hasCorrelatedPairs)
                    Divider()
                    // BATCH combine. Moved off the toolbar row 2026-08-11
                    // (Rick: the centre was too busy) but deliberately NOT
                    // deleted: the row's right-click only offers "Combine
                    // This Pair…", so removing this would have left no way
                    // to mux thousands of MXF pairs in one pass — the app's
                    // whole A/V-stitching mission. The Correlate menu is
                    // arguably its right home anyway: combining is the step
                    // AFTER correlating.
                    Button("Combine All Correlated Pairs…") { showCombineSheet = true }
                        .disabled(!canCombine && !isCombining)
                        .accessibilityIdentifier("catalog.combine.openSheet")
                } label: {
                    if isCorrelating {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("Correlating…")
                        }
                    } else {
                        Label("Correlate A/V Pairs", systemImage: "arrow.triangle.2.circlepath")
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
                    Button("Find Duplicates", action: onAnalyzeDuplicatesAll)
                    Button("Find Duplicates of Selected", action: onAnalyzeDuplicatesSelected)
                        .disabled(selectedIDs.isEmpty)

                    if !model.isReadOnly && !volumesWithDeletableDups.isEmpty {
                        Divider()
                        Menu("Delete Duplicates on Volume…") {
                            ForEach(volumesWithDeletableDups, id: \.path) { vol in
                                Button("\(URL(fileURLWithPath: vol.path).lastPathComponent) — \(vol.count) file\(vol.count == 1 ? "" : "s")") {
                                    onDeleteDuplicates(vol.path, vol.count)
                                }
                            }
                        }
                    }
                    if !model.isReadOnly {
                        Divider()
                        // "Also clean up working copies" (2026-08-18) —
                        // same persisted setting as the Volumes sheet; the
                        // caption lives there. Default OFF.
                        Toggle(WorkingCopyCleanupText.toggleLabel, isOn: Binding(
                            get: { model.duplicateKeeperSettings.alsoCleanUpWorkingCopies },
                            set: { on in
                                model.duplicateKeeperSettings.alsoCleanUpWorkingCopies = on
                                model.saveDuplicateKeeperSettings()
                                model.refreshDossierCountsNow()
                            }))
                    }
                } label: {
                    if isAnalyzingDuplicates || model.isDeletingDuplicates {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text(isAnalyzingDuplicates ? "Analyzing…" : "Deleting…")
                        }
                    } else {
                        Label("Duplicates", systemImage: "doc.on.doc")
                    }
                }
                .menuStyle(.borderlessButton)
                .disabled(isScanning || isAnalyzingDuplicates
                          || model.isDeletingDuplicates || !hasRecords)
                .help("Find duplicate files by comparing hash, duration, filename, resolution, and other signals")

                if !duplicateStatus.isEmpty {
                    Text(duplicateStatus)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(isAnalyzingDuplicates ? .secondary : .yellow)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 120)

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

            Menu {
                // Media kind, merged in from the old standalone "All
                // Kinds" chip (Rick 2026-08-11: the two menus overlapped).
                // It is a view narrowing like everything else here, so it
                // belongs in the same menu — and the label below still
                // names the active facet, so the default-off state stays
                // visible without its own button.
                Section("Show files — media kind") {
                    Picker("Media kind", selection: kindFacetBinding) {
                        ForEach(CatalogKindFacet.allCases) { facet in
                            Label(facet.label, systemImage: facet.icon)
                                .tag(facet)
                                .help(facet.help)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                // Baseline reachability opt-out (2026-07-20). Reachable-only
                // is the DEFAULT; this toggle lifts that baseline. Kept in its
                // own section ABOVE the additive filters — and deliberately
                // NOT reset by "Clear All Filters" (it's a preference, not a
                // filter). Same VolumeReachability the Volumes view uses.
                Section {
                    Toggle(isOn: $showDisconnectedMedia) {
                        Label("Show disconnected media",
                              systemImage: showDisconnectedMedia
                              ? "externaldrive.badge.xmark"
                              : "externaldrive.fill.badge.checkmark")
                    }
                    .help(showDisconnectedMedia
                          ? "Showing media on disconnected volumes too. Turn off to show only reachable media (the default)."
                          : "Only media on connected volumes is shown (the default). Turn on to also list files on disconnected drives.")
                }
                Section("Show files — filters") {
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
                }
                // Hidden-record reveals, moved off the toolbar row into
                // this menu (Rick 2026-08-11 — the middle of the window
                // was too busy for a new user). They are view state, so
                // the View menu is their natural home; Tidy Catalog
                // stayed a button because it PERFORMS an action rather
                // than toggling what you can see.
                //
                // Moving them costs the at-a-glance colour cue the
                // toolbar buttons gave, so the menu's own icon now fills
                // in when any of them is on — otherwise you could leave
                // "Show removed" enabled, see italic orange rows, and
                // have nothing on screen explaining why.
                Section("Show files — hidden records") {
                    Toggle(isOn: $showRemoved) {
                        Label("Removed", systemImage: showRemoved
                              ? "eye.trianglebadge.exclamationmark"
                              : "eye.slash")
                    }
                    .help(showRemoved
                          ? "Removed (purged) records are visible — italic + orange. Click to hide."
                          : "Click to show removed records alongside active ones.")

                    Toggle(isOn: $showSetAside) {
                        Label("Set aside", systemImage: "archivebox")
                    }
                    .help(showSetAside
                          ? "Set-aside files are visible — italic + purple. Right-click one to put it back. Click to hide."
                          : "Click to show the files Tidy Catalog set aside (photos, music, audio with no matching video).")

                    Toggle(isOn: $showSuperseded) {
                        Label("Superseded originals", systemImage: "arrow.triangle.swap")
                    }
                    .help(showSuperseded
                          ? "Superseded originals (replaced by a confirmed repair) are visible — italic + brown. Right-click one to restore it. Click to hide."
                          : "Click to show originals that a confirmed repair has replaced. Their files are never touched.")
                }
                if !viewFilters.isEmpty {
                    Divider()
                    Button("Clear All Filters") { viewFilters.removeAll() }
                }
                // Maintenance: one-click reversible removal of the extensionless
                // files ffprobe can't read (caches/previews/app data) that the
                // "Scan Files With No Extension" pass can sweep in. Soft-delete —
                // files on disk untouched, recoverable via Show Removed.
                let junkCount = VideoScanModel.unreadableExtensionlessIDs(in: model.records).count
                if junkCount > 0 {
                    Divider()
                    Button("Remove \(junkCount) Unreadable Extensionless File\(junkCount == 1 ? "" : "s")") {
                        _ = model.softDeleteUnreadableExtensionless()
                    }
                    .help("Hide non-media files with no extension that ffprobe can't read (caches, previews, app data). Files on disk are not deleted; toggle Show Removed to restore.")
                }
            } label: {
                HStack(spacing: 3) {
                    // Filled whenever ANY view state is non-default —
                    // filters or the hidden-record reveals above. A
                    // toggle hidden in a menu with no outward sign is
                    // how you end up staring at orange rows wondering
                    // what changed.
                    Image(systemName: "line.3.horizontal.decrease.circle\(viewIsModified ? ".fill" : "")")
                    Text("Show")
                }
                .foregroundColor(model.kindFacetSetting.facet == .videoBearing
                                 ? .primary : .teal)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose which files are shown — media kind, filters, and hidden records")

            if !outputCSVPath.isEmpty {
                Button(action: {
                    NSWorkspace.shared.selectFile(outputCSVPath, inFileViewerRootedAtPath: "")
                }) {
                    Label("Show CSV", systemImage: "doc.text")
                }
                .buttonStyle(.bordered)
            }

            // FIXED inset, not a flexible Spacer (Rick 2026-08-14). This is
            // the one number that positions the search capsule: it is the
            // gap between the last left-hand control and the magnifier, so
            // raising it slides search right, lowering it slides search
            // left. The goal is the capsule centred under the Errors
            // column. Tune HERE — the flexible Spacer that pushes the
            // Archivist away lives further down, so the two do not fight.
            Spacer().frame(width: Self.searchLeftInset)

            HStack(spacing: 6) {
                // Deliberately oversized (18pt semibold vs the old 13pt
                // secondary): the magnifier IS the affordance, and at
                // body size it disappeared into a row of same-weight
                // glyphs. Accent-tinted for the same reason.
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.accentColor)
                // Just "Search" (Rick 2026-08-14). The old example-laden
                // placeholder taught the grammar but filled the capsule with
                // text that read as content rather than an empty field — and
                // the `?` popover teaches the grammar properly anyway.
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .frame(width: 320)
                    .accessibilityIdentifier("catalog.searchField")
                    // No debouncer and no recompute chain here anymore
                    // (GH #123 PR B): ContentView owns the single 250 ms
                    // debouncer, and CatalogContent's filter pass — which
                    // already re-runs on every one of these triggers
                    // (debounced text, records.count, showRemoved,
                    // showSetAside, tidy/purge batches) — publishes the
                    // badge count as a by-product of the SAME scan.
                if !searchText.isEmpty {
                    Button(action: {
                        // Parent's onChange(searchText) instant-clears its
                        // debounced mirror on empty, so one write is enough.
                        searchText = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            // Capsule rather than a 7pt rounded rect (Rick 2026-08-14): the
            // squared-off box read as "a field among fields". A full capsule
            // with a hairline border is the Finder search idiom — it reads as
            // a distinct place you type into rather than another control in
            // the row.
            .background(Capsule().fill(Color(NSColor.textBackgroundColor)))
            // Ring weight is deliberate (Rick 2026-08-14: "maybe even more
            // emphasized given this dark background"). A hairline that reads
            // fine on light chrome vanishes on dark, so this is a 1.5pt ring
            // at higher opacity plus a soft halo — the capsule should read as
            // a lit portal, not a faint outline.
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.55), lineWidth: 1.5))
            .shadow(color: Color.white.opacity(0.12), radius: 3)
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
                // Family further narrow). Reads the count the table's
                // filter pass published (GH #123 PR B) — never scan
                // records inside body.
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
                // Sized up from body-default (Rick 2026-08-14: "make the ?
                // bigger so people can see help is available"). At default
                // weight it was invisible next to the 18pt magnifier.
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Search syntax reference")
            .popover(isPresented: $showSearchHelp, arrowEdge: .bottom) {
                CatalogSearchHelpPopover()
            }

            // FIXED, not flexible. The Archivist has to land under PHASE,
            // and a flexible Spacer here would push it to the far right
            // regardless of what we ask for. Close enough to the search
            // that the pair reads as one idea: "Search, or Chat with the
            // Family Archivist."
            // Family Archivist front door MOVED to the tab bar (Rick
            // 2026-08-16: "move the Pink AI Archivist to be after the
            // Family Tree tab, prominently displayed"). The ⌥ quick
            // popover stays reachable here so the old muscle memory
            // (⌥-click near the search) still works.
            Spacer().frame(width: Self.archivistGap)
            Color.clear.frame(width: 1, height: 1)
                .popover(isPresented: $showAskPopover, arrowEdge: .bottom) {
                    ArchivistAskPopover(searchText: $searchText,
                                        isPresented: $showAskPopover)
                }

            // The row's ONE flexible Spacer, and it lives here — after the
            // Archivist — so everything to its left keeps the fixed column
            // alignment and only the inspector toggle floats right.
            Spacer(minLength: 16)

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
            // Gauntlet flow 5 toggles the inspector here. Test-only.
            .accessibilityIdentifier("catalog.inspectorToggle")

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
                CatalogSearchExampleRow(query: "type:video",
                                        meaning: "video-bearing files — video+audio or video-only")
                CatalogSearchExampleRow(query: "type:audio",
                                        meaning: "audio-only files (type:video-only for strict video-only)")
                CatalogSearchExampleRow(query: "codec:mp3",
                                        meaning: "video OR audio codec contains mp3 (codec:prores, codec:pcm…)")
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
