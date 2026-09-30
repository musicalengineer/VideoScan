import SwiftUI
import Combine
import os

// MARK: - Dossier Dashboard
//
// Live monitor for catalog-wide dossier coverage. Pulls progress from
// two independent sources so it tells the truth regardless of which
// path is doing the work:
//
//   1. The in-memory catalog (`model.records`) — counts dossier'd
//      records and per-channel coverage. Updated by both the in-app
//      orchestrator's writeback AND the live-reload poller that
//      ingests external worker JSONL deltas via the merger.
//   2. The orchestrator's dashboard SNAPSHOT
//      (`orchestrator.dashboardSnapshot`, ≤2 Hz, Equatable-gated) —
//      lanes, completed history, and the queue/parked/paused state.
//
// RENDER-LOOP FIX (perf/dashboard-render, 2026-07-14). This view used
// to observe CaptionOrchestrator and VideoScanModel wholesale via
// @EnvironmentObject: every per-record @Published write (skip storms,
// lane churn, live counters, catalog mutations) re-evaluated this
// body — 6.2 CPU-hours over a 9.8 h batch, pegging the MainActor and
// starving the orchestrator's inter-file hops. Now:
//   - `model` and `orchestrator` are held as PLAIN references — reads
//     and action calls only, no observation. (≈ C++ holding a pointer
//     vs. subscribing to its change signal.)
//   - The ONLY observed object is DossierDashboardSnapshot (≤2 Hz).
//   - The 1 s timer's refreshCounts performs ZERO @State writes when
//     nothing changed (pfRefreshVolumeCoverage returns nil), so an
//     idle tick invalidates nothing.
//   - NO O(records) work in this body — the O(records × volumes)
//     refilter runs in the timer callback, gated on `coverageKey`.
//
// Opened via Window menu → Dossier Dashboard (⌘⇧O) or
// `openWindow(id: "dossier")`.

struct DossierDashboardView: View {

    /// Catalog access (records / scanTargets) and navigation. Plain
    /// reference — deliberately NOT @ObservedObject/@EnvironmentObject:
    /// the dashboard reads it on its own 1 s tick instead of being
    /// invalidated by every catalog publish.
    let model: VideoScanModel

    /// Action target (Analyze / Pause / Stop / queue verbs / scope).
    /// Plain reference — never observed; all rendered orchestrator
    /// state comes through `snapshot`.
    let orchestrator: CaptionOrchestrator

    /// The ONE observed object. See DossierDashboardSnapshot.swift.
    @ObservedObject var snapshot: DossierDashboardSnapshot

    @AppStorage(CaptionOrchestrator.autoResumePrefsKey) private var autoResume: Bool = false

    init(model: VideoScanModel, orchestrator: CaptionOrchestrator) {
        self.model = model
        self.orchestrator = orchestrator
        // Property-wrapper backing init (`_snapshot` ≈ the wrapper
        // struct itself, not the wrapped value — C++ analogy: member
        // initializer for the wrapper object).
        self._snapshot = ObservedObject(wrappedValue: orchestrator.dashboardSnapshot)
    }

    /// Per-volume coverage — keyed by `searchPath`. Refreshed by the
    /// 1s tick. Each value mirrors what CatalogCoverage exposes for the
    /// catalog as a whole, but restricted to records whose `fullPath`
    /// starts with the volume's search path. Volumes without entries
    /// render as empty in the row.
    @State private var volumeCoverage: [String: CatalogCoverage] = [:]

    /// Per-volume rate trackers — keyed by `searchPath`. Each row reads
    /// rate / ETA from its own tracker so a single volume's progress
    /// doesn't drag the global number.
    @State private var volumeRates: [String: RateTracker] = [:]

    /// Tick the UI every 1s so the dial / counters move in near-real
    /// time. Rick 2026-06-13: 5s felt static — files complete every few
    /// seconds on a healthy run, and a 5s sample window means the rate
    /// tracker stays on "—" for 5 seconds after the first completion.
    /// 2026-07-05: the tick itself stays at 1 s, but the O(records ×
    /// volumes) refilter now runs only when the catalog actually changed
    /// (see `coverageKey`) — at 103k records the unconditional per-second
    /// refilter was 52% of an idle main-thread sample (beachball fix).
    /// 2026-07-14: a no-change tick now also performs ZERO @State
    /// writes (the writes themselves used to invalidate the body 1/s).
    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Change signature for the coverage refilter gate. Moves when any
    /// catalog mutation lands (dossier writes bump the debounced
    /// dossier-counts recompute; array-level changes move `records.count`;
    /// in-place path rewrites bump `volumeAggregatesRevision`), when the
    /// visible volume-row set changes (mount/unmount/retire — membership,
    /// not just count), or when the Analysis Scope changes (the scope
    /// decides `eligible`, so a toggle flip must refilter).
    private func coverageKey(for volumes: [CatalogScanTarget]) -> [Int] {
        [model.dossierCountsRecomputeCount,
         model.volumeAggregatesRevision,
         model.records.count,
         volumes.map(\.searchPath).joined(separator: "|").hashValue,
         snapshot.state.analysisScope.hashValue]
    }

    /// Last signature we refiltered for. `-1` sentinel forces the first
    /// pass on appear.
    @State private var lastCoverageKey: [Int] = [-1]

    /// Number of reserved slots under "Now Analyzing". Rick 2026-06-13:
    /// the area should NOT resize as lanes come and go (jitters the
    /// layout) — instead reserve N rows worth of height up-front and
    /// pad with placeholder rows when fewer lanes are in flight.
    ///
    /// 2 matches the real pipeline depth: VLM(N+1) || Whisper(N). The
    /// strict backpressure (one Whisper outstanding) caps actual
    /// concurrency at 2. A wider pipeline would lift this.
    static let activeLanesVisibleCap = 2

    /// Pinned height per active-lane row. Reading the system font's
    /// metrics inline would be more correct but couples this view to
    /// layout details we don't otherwise depend on — a measured
    /// constant is simpler and matches the row's actual rendered size
    /// (spinner + filename + badge + verb, 13pt font with 10pt VStack
    /// spacing).
    static let activeLaneRowHeight: CGFloat = 28

    /// Currently focused volume in the drill-down. Defaults to the
    /// first analyzing volume, then the first reachable one. nil
    /// before the first refresh.
    @State private var selectedVolumePath: String?

    var body: some View {
        // Rick 2026-08-19: with 8 reachable volumes the rows outgrew the
        // window and there was no scroll bar — the root is a ScrollView now
        // and the window is resizable beyond content (.contentMinSize).
        ScrollView(.vertical) {
        VStack(alignment: .center, spacing: 14) {

            // Title
            Text("Analyze Catalog")
                .font(.title)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)

            // MARK: Per-volume rows (Rick 2026-06-13: replaces the
            // big dial + global counters with a row per reachable
            // scanTarget — each volume gets its own Analyze /
            // Pause / Stop, and clicking a row sets it as the
            // drill-down focus below). 2026-07-14: Analyze while
            // another volume runs ENQUEUES (FIFO) instead of being
            // disabled, and Analyze All lines up every volume with
            // remaining work. Row state (analyzing / paused /
            // Queued (#n) / parked banners) renders from the snapshot
            // — same definitions as the orchestrator's own helpers,
            // ≤500 ms staleness, direct user actions echo immediately
            // via `intent(_:)`.
            VStack(spacing: 6) {
                HStack {
                    if snapshot.state.queuePaused
                        && !snapshot.state.queuedVolumePrefixes.isEmpty {
                        // Queue restored from the last session with
                        // Resume on Launch OFF — visible, never
                        // auto-started, never silently dropped.
                        Label("\(snapshot.state.queuedVolumePrefixes.count) volume(s) waiting from last session",
                              systemImage: "pause.circle")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                        Button("Resume the Line") {
                            intent { orchestrator.resumeQueue(model: model) }
                        }
                        .controlSize(.small)
                    }
                    if !snapshot.state.parkedVolumePrefixes.isEmpty {
                        // Queued volumes whose drive is offline (QA F2):
                        // they hold their place in line but can't run —
                        // and their row may not render at all (the row
                        // list is reachable volumes only), so this
                        // banner is their visible state.
                        Label("\(snapshot.state.parkedVolumePrefixes.count) volume(s) in line waiting for their drive to reconnect",
                              systemImage: "externaldrive.badge.exclamationmark")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                            .help("These volumes stay in the analyze line but won't start until their drive is mounted again. Nothing is changed or removed while a drive is offline.")
                            .accessibilityIdentifier("dossier.parkedBanner")
                    }
                    Spacer()
                    Button {
                        analyzeAll()
                    } label: {
                        Label("Analyze All", systemImage: "play.circle.fill")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .controlSize(.small)
                    .disabled(analyzeAllPrefixes.isEmpty)
                    .help("Line up every volume that still has files to analyze. They run one at a time, top to bottom — start it at bedtime, see progress by morning.")
                    .accessibilityIdentifier("dossier.analyzeAll")
                }
                ForEach(reachableVolumes, id: \.id) { vol in
                    DossierVolumeRow(
                        target: vol,
                        coverage: volumeCoverage[vol.searchPath] ?? .empty,
                        // isVolumeAnalyzing (not a raw currentVolumePrefix
                        // check) so the dequeue→batch-start dispatch
                        // window reads "analyzing", never "Queued" (QA F6).
                        // Derived from the snapshot with the SAME
                        // definition as the orchestrator's helper.
                        isAnalyzing: snapshot.state.isVolumeAnalyzing(vol.searchPath),
                        isPaused: snapshot.state.isVolumePaused(vol.searchPath),
                        isSelected: selectedVolumePath == vol.searchPath,
                        queuePosition: snapshot.state.queuePosition(of: vol.searchPath),
                        onSelect: { selectedVolumePath = vol.searchPath },
                        onAnalyze: { intent { orchestrator.enqueueAnalyze(
                            volumePrefix: vol.searchPath, model: model) } },
                        onDequeue: { intent { orchestrator.dequeueAnalyze(
                            volumePrefix: vol.searchPath) } },
                        onPause: { intent { orchestrator.pause() } },
                        onResume: { intent { orchestrator.resume() } },
                        onStop: { intent { orchestrator.cancel() } }
                    )
                    .equatable()
                }
                if reachableVolumes.isEmpty {
                    Text("No reachable scan-target volumes — register volumes in the catalog tab.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }
            }

            // MARK: Analysis Scope (2026-07-14) — what kinds of files
            // Analyze spends GPU time on. Audio-only files (Rick's
            // music-production archive: 81k of the 92k "remaining"
            // files) are set aside by DEFAULT so Analyze focuses on
            // home video. Setting aside is reversible and never
            // touches a record's tag. Photos are never analyzed here.
            // The AnalysisScope model has room for more categories —
            // Rick: the skip list is "TBD, more to come".
            GroupBox {
                HStack(spacing: 10) {
                    Toggle("Include music and other audio-only files", isOn: includeAudioBinding)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .help("Off (recommended): Analyze focuses on files with video. On: audio-only files (music, voice recordings) are transcribed too. Either way, nothing is tagged or removed — set-aside files just wait.")
                        .accessibilityIdentifier("dossier.scope.includeAudio")
                    Spacer()
                    Text("Photos and camera raw files are never analyzed here.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
            } label: {
                Text("Analysis Scope").font(.headline)
            }

            // Drill-down header — what volume is the activity feed
            // showing? Falls back to "all volumes" when nothing is
            // selected (legacy view during transition).
            HStack(spacing: 6) {
                Text(drillDownLabel)
                    .font(.headline)
                Spacer()
                Toggle("Resume on Launch", isOn: $autoResume)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help("Auto-resume any volume that was analyzing — or waiting in line — when the app last quit.")
            }
            .padding(.top, 6)

            // MARK: Live pipeline activity
            //
            // Mirrors what the log shows, cleaned up: one row per
            // in-flight stage, plus the trailing completed-file
            // history. Both lists come from the SNAPSHOT (≤2 Hz); the
            // 1s TimelineView clock below re-evaluates ONLY the
            // Now Analyzing subtree so the elapsed "(Ns)" readout
            // ticks without touching the rest of the window. The
            // Recently Completed section lost its TimelineView
            // (2026-07-14): its rows never used the clock — "how long
            // it took", not "how long ago" — so the second 1 Hz
            // invalidation source was pure waste.

            GroupBox(label: Text("Now Analyzing").font(.headline)) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(0..<Self.activeLanesVisibleCap, id: \.self) { i in
                            if i < drillDownLanes.count {
                                ActiveLaneRow(
                                    lane: drillDownLanes[i],
                                    now: context.date,
                                    onSkip: { lane in orchestrator.skipLane(lane.id) }
                                )
                                .equatable()
                                .frame(height: Self.activeLaneRowHeight)
                            } else if drillDownLanes.isEmpty && i == 0 {
                                Text(idleLabel)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity,
                                           minHeight: Self.activeLaneRowHeight,
                                           alignment: .leading)
                            } else {
                                Color.clear
                                    .frame(height: Self.activeLaneRowHeight)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                }
            }

            GroupBox(label: Text("Recently Completed").font(.headline)) {
                if drillDownCompleted.isEmpty {
                    Text("no files analyzed yet this session for this volume")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(drillDownCompleted) { item in
                            CompletedActivityRow(
                                item: item,
                                // `now` is unused by the row (kept for
                                // signature stability); a constant means
                                // row equality never churns on it.
                                now: .distantPast,
                                onShowInCatalog: { item in showInCatalog(path: item.path) }
                            )
                            .equatable()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                    .animation(.default, value: drillDownCompleted)
                }
            }

            // MARK: Total Processed — per-selected-volume channel counts.
            GroupBox(label: Text("Total Processed").font(.headline)) {
                HStack(spacing: 24) {
                    ChannelStat(
                        icon: "text.bubble.fill",
                        label: "Scene captions",
                        value: (volumeCoverage[selectedVolumePath ?? ""] ?? .empty).scenes,
                        color: .indigo
                    )
                    ChannelStat(
                        icon: "calendar.badge.clock",
                        label: "OCR dates",
                        value: (volumeCoverage[selectedVolumePath ?? ""] ?? .empty).ocrDates,
                        color: .purple
                    )
                    ChannelStat(
                        icon: "waveform.circle.fill",
                        label: "Transcripts",
                        value: (volumeCoverage[selectedVolumePath ?? ""] ?? .empty).transcripts,
                        color: .teal
                    )
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        }
        // minHeight grew 700 → 760: the two activity sections can run
        // taller than the 3-row fleet panel they replaced (2 lanes +
        // up to 8 history rows). Ideal height leaves room for ~8 volume
        // rows; anything more scrolls.
        .frame(minWidth: 700, idealWidth: 760, minHeight: 760, idealHeight: 900)
        .onAppear {
            dossierWindowLog.info("dossier dashboard body appeared")
            refreshCounts()
        }
        .onReceive(refreshTimer) { _ in
            refreshCounts()
        }
    }

    // MARK: - Direct-intent echo

    /// Run a user action against the (unobserved) orchestrator, then
    /// publish the snapshot immediately so the click's result renders
    /// this frame instead of waiting out the ≤2 Hz coalescing floor.
    /// Rate stays bounded — clicks aren't a storm, and the immediate
    /// publish resets the interval clock.
    private func intent(_ action: () -> Void) {
        action()
        orchestrator.publishDashboardSnapshotNow()
    }

    // MARK: - Analysis scope plumbing

    /// Two-way binding onto the orchestrator's scope. All writes go
    /// through updateAnalysisScope — the ONE mutation point that does
    /// the explicit save() (@Observable/@Published kill didSet
    /// persistence; see project_settings_persistence). The get side
    /// reads the SNAPSHOT (the observed object) and the set side's
    /// `intent` echo republishes it synchronously, so the checkbox
    /// never visually snaps back while the coalescer waits.
    private var includeAudioBinding: Binding<Bool> {
        Binding(
            get: { snapshot.state.analysisScope.includeAudioOnly },
            set: { on in
                var scope = snapshot.state.analysisScope
                scope.includeAudioOnly = on
                intent { orchestrator.updateAnalysisScope(scope) }
            }
        )
    }

    // MARK: - Analyze All

    /// Volumes "Analyze All" would enqueue right now. O(volumes) over
    /// the CACHED coverage — no records pass in a view body.
    private var analyzeAllPrefixes: [String] {
        pfAnalyzeAllPrefixes(
            remainingByVolume: reachableVolumes.map {
                (prefix: $0.searchPath,
                 remaining: (volumeCoverage[$0.searchPath] ?? .empty).remaining)
            },
            queued: snapshot.state.queuedVolumePrefixes,
            activePrefix: snapshot.state.statusIsActive
                ? snapshot.state.currentVolumePrefix : nil
        )
    }

    private func analyzeAll() {
        intent {
            orchestrator.enqueueAnalyzeAll(
                volumePrefixes: analyzeAllPrefixes, model: model)
        }
    }

    // MARK: - Per-volume coverage

    /// The list of volumes shown as rows. Shares the canonical
    /// `isAnalyzeCandidate` gate (reachable, non-retired, non-empty,
    /// NOT the RAM-disk scratch volume) with the caption sweep and the
    /// dossier queue, so what the user sees in a row matches what
    /// Analyze will queue. The scratch volume showing up here was the
    /// 2026-07-08 regression — see ScratchVolumeScreeningTests.
    /// (Non-observed read of model.scanTargets — O(targets).)
    private var reachableVolumes: [CatalogScanTarget] {
        CatalogScanTarget.analyzeCandidates(model.scanTargets)
    }

    /// Refresh per-volume coverage stats from the catalog, and nudge the
    /// per-volume rate tracker so rate/ETA tick along with the analyzing
    /// volume. The O(records × volumes) refilter is GATED on `coverageKey`
    /// — a 1 s tick with an unchanged catalog only checks the (cheap)
    /// rate trackers. 2026-07-14: the WRITES are gated too — the core
    /// (pfRefreshVolumeCoverage) returns nil on a no-change tick and we
    /// touch no @State at all, so the tick invalidates nothing.
    private func refreshCounts() {
        let vols = reachableVolumes
        if let out = pfRefreshVolumeCoverage(
            coverage: volumeCoverage,
            rates: volumeRates,
            lastKey: lastCoverageKey,
            key: coverageKey(for: vols),
            volumePrefixes: vols.map(\.searchPath),
            records: model.records,
            scope: snapshot.state.analysisScope,
            now: Date()
        ) {
            volumeCoverage = out.coverage
            volumeRates = out.rates
            lastCoverageKey = out.lastKey
        }
        // Default-select the currently-analyzing volume; fall back to
        // the first volume so the drill-down always shows something.
        // Already write-gated by the nil/membership check.
        if selectedVolumePath == nil ||
           !vols.contains(where: { $0.searchPath == selectedVolumePath }) {
            selectedVolumePath = snapshot.state.currentVolumePrefix
                ?? vols.first?.searchPath
        }
    }

    // MARK: - Drill-down derivation (depends on selectedVolumePath)

    /// Header text above the activity feed: name of the selected
    /// volume, or a fallback when nothing's selected.
    private var drillDownLabel: String {
        guard let sel = selectedVolumePath,
              let vol = reachableVolumes.first(where: { $0.searchPath == sel })
        else { return "Activity" }
        return "Activity — \(VolumeReachability.displayLabel(forPath: vol.searchPath))"
    }

    /// Idle-state message inside the Now Analyzing box. Speaks in
    /// terms of the selected volume so it's always actionable.
    private var idleLabel: String {
        guard let sel = selectedVolumePath,
              let vol = reachableVolumes.first(where: { $0.searchPath == sel })
        else { return "select a volume above to see analysis activity" }
        return "\(VolumeReachability.displayLabel(forPath: vol.searchPath)): pipeline idle — press Analyze to start"
    }

    /// Active lanes filtered to the selected volume. When nothing is
    /// selected, shows all lanes (rare edge case during transitions).
    /// O(lanes) with lanes ≤ 2 — snapshot values, not live state.
    private var drillDownLanes: [PipelineLane] {
        guard let sel = selectedVolumePath else { return snapshot.state.activeLanes }
        return snapshot.state.activeLanes.filter { $0.path.hasPrefix(sel) }
    }

    /// Completed-activity filtered to the selected volume's prefix.
    /// O(history) with history ≤ 8.
    private var drillDownCompleted: [CompletedActivity] {
        guard let sel = selectedVolumePath else { return snapshot.state.recentActivity }
        return snapshot.state.recentActivity.filter { $0.path.hasPrefix(sel) }
    }

    /// Right-click → "Show in Catalog" on an active lane.
    ///
    /// 1) Look up the record by full path (the lane carries it).
    /// 2) Switch the main window's `selectedTab` to the Catalog tab
    ///    (index 1 in ContentView's tab order — @AppStorage so we can
    ///    write through UserDefaults).
    /// 3) Set `pendingCatalogSelection` — ContentView observes this
    ///    via `.onChange` and routes the catalog table to focus +
    ///    select that record.
    /// 4) Bring the main window forward; the user's eyes follow the
    ///    new focus.
    ///
    /// Silently no-ops if the record isn't in the catalog (e.g. a
    /// lane for a file the merger has since purged). O(records) but
    /// only on an explicit user click — never per render.
    private func showInCatalog(path: String) {
        guard let rec = model.records.first(where: { $0.fullPath == path }) else { return }
        UserDefaults.standard.set(1, forKey: "selectedTab")
        model.pendingCatalogSelection = rec.id
        MainWindowHelper.shared.openMainWindow()
    }

    /// Filename-based fallback. CompletedActivity only stores the
    /// filename (leaf path) — it doesn't preserve the full path because
    /// the lane already has it. To navigate, we resolve filename → first
    /// matching record. If duplicates exist (same name on multiple
    /// volumes — common with AVCHD camera files like 00088.MTS), we pick
    /// the first reachable hit; the user can dig into the others via
    /// the catalog's regular search.
    private func showInCatalog(filename: String) {
        guard let rec = model.records.first(where: { $0.filename == filename }) else { return }
        UserDefaults.standard.set(1, forKey: "selectedTab")
        model.pendingCatalogSelection = rec.id
        MainWindowHelper.shared.openMainWindow()
    }
}
