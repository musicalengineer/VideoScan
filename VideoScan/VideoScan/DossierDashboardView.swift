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
//   2. The orchestrator's live pipeline activity feed
//      (`activeLanes` / `recentActivity`) — what each stage is
//      working on right now, plus the trailing history of completed
//      files with per-stage timings. This replaced the per-host
//      "Participating Computers" fleet panel (2026-06-12); the
//      FleetStats/WorkerHost machinery below is kept because the
//      fleet may return and the parsing logic has unit tests.
//
// The dial reflects catalog-wide progress (dossier'd / total) rather
// than the in-app sweep's per-batch progress, because in practice the
// external worker fleet does most of the long-running work. Start/Stop
// remain wired to the in-app orchestrator for ad-hoc sweeps from
// within the app.
//
// Opened via Window menu → Dossier Dashboard (⌘⇧O) or
// `openWindow(id: "dossier")`.

struct DossierDashboardView: View {

    @EnvironmentObject var captionOrchestrator: CaptionOrchestrator
    @EnvironmentObject var model: VideoScanModel
    @AppStorage(CaptionOrchestrator.autoResumePrefsKey) private var autoResume: Bool = false

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
    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Change signature for the coverage refilter gate. Moves when any
    /// catalog mutation lands (dossier writes bump the debounced
    /// dossier-counts recompute; array-level changes move `records.count`;
    /// in-place path rewrites bump `volumeAggregatesRevision`), when the
    /// visible volume-row set changes (mount/unmount/retire), or when
    /// the Analysis Scope changes (the scope decides `eligible`, so a
    /// toggle flip must refilter).
    private var coverageKey: [Int] {
        [model.dossierCountsRecomputeCount,
         model.volumeAggregatesRevision,
         model.records.count,
         reachableVolumes.count,
         captionOrchestrator.analysisScope.hashValue]
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
        VStack(alignment: .center, spacing: 14) {

            // Title
            Text("Catalog Analyze")
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
            // remaining work.
            VStack(spacing: 6) {
                HStack {
                    if captionOrchestrator.queuePaused
                        && !captionOrchestrator.queuedVolumePrefixes.isEmpty {
                        // Queue restored from the last session with
                        // Resume on Launch OFF — visible, never
                        // auto-started, never silently dropped.
                        Label("\(captionOrchestrator.queuedVolumePrefixes.count) volume(s) waiting from last session",
                              systemImage: "pause.circle")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                        Button("Resume the Line") {
                            captionOrchestrator.resumeQueue(model: model)
                        }
                        .controlSize(.small)
                    }
                    if !captionOrchestrator.parkedVolumePrefixes.isEmpty {
                        // Queued volumes whose drive is offline (QA F2):
                        // they hold their place in line but can't run —
                        // and their row may not render at all (the row
                        // list is reachable volumes only), so this
                        // banner is their visible state.
                        Label("\(captionOrchestrator.parkedVolumePrefixes.count) volume(s) in line waiting for their drive to reconnect",
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
                        isAnalyzing: captionOrchestrator.isVolumeAnalyzing(vol.searchPath),
                        isPaused: captionOrchestrator.currentVolumePrefix == vol.searchPath
                            && captionOrchestrator.paused,
                        isSelected: selectedVolumePath == vol.searchPath,
                        queuePosition: captionOrchestrator.queuePosition(of: vol.searchPath),
                        onSelect: { selectedVolumePath = vol.searchPath },
                        onAnalyze: { captionOrchestrator.enqueueAnalyze(
                            volumePrefix: vol.searchPath, model: model) },
                        onDequeue: { captionOrchestrator.dequeueAnalyze(
                            volumePrefix: vol.searchPath) },
                        onPause: { captionOrchestrator.pause() },
                        onResume: { captionOrchestrator.resume() },
                        onStop: { captionOrchestrator.cancel() }
                    )
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
            // history. Both lists come straight from the
            // orchestrator's @Published activity feed; the 1s
            // TimelineView clock below re-evaluates ONLY these
            // subtrees so the elapsed "(Ns)" / "41s ago" readouts
            // tick without touching the rest of the window.

            GroupBox(label: Text("Now Analyzing").font(.headline)) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(0..<Self.activeLanesVisibleCap, id: \.self) { i in
                            if i < drillDownLanes.count {
                                ActiveLaneRow(
                                    lane: drillDownLanes[i],
                                    now: context.date,
                                    onSkip: { lane in captionOrchestrator.skipLane(lane.id) }
                                )
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
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(drillDownCompleted) { item in
                                CompletedActivityRow(
                                    item: item,
                                    now: context.date,
                                    onShowInCatalog: { item in showInCatalog(path: item.path) }
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                    }
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
        // minHeight grew 700 → 760: the two activity sections can run
        // taller than the 3-row fleet panel they replaced (2 lanes +
        // up to 8 history rows).
        .frame(minWidth: 700, minHeight: 760)
        .onAppear {
            dossierWindowLog.info("dossier dashboard body appeared")
            refreshCounts()
        }
        .onReceive(refreshTimer) { _ in
            refreshCounts()
        }
    }

    // MARK: - Analysis scope plumbing

    /// Two-way binding onto the orchestrator's scope. All writes go
    /// through updateAnalysisScope — the ONE mutation point that does
    /// the explicit save() (@Observable/@Published kill didSet
    /// persistence; see project_settings_persistence).
    private var includeAudioBinding: Binding<Bool> {
        Binding(
            get: { captionOrchestrator.analysisScope.includeAudioOnly },
            set: { on in
                var scope = captionOrchestrator.analysisScope
                scope.includeAudioOnly = on
                captionOrchestrator.updateAnalysisScope(scope)
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
            queued: captionOrchestrator.queuedVolumePrefixes,
            activePrefix: captionOrchestrator.currentStatus.isActive
                ? captionOrchestrator.currentVolumePrefix : nil
        )
    }

    private func analyzeAll() {
        captionOrchestrator.enqueueAnalyzeAll(
            volumePrefixes: analyzeAllPrefixes, model: model)
    }

    // MARK: - Per-volume coverage

    /// The list of volumes shown as rows. Shares the canonical
    /// `isAnalyzeCandidate` gate (reachable, non-retired, non-empty,
    /// NOT the RAM-disk scratch volume) with the caption sweep and the
    /// dossier queue, so what the user sees in a row matches what
    /// Analyze will queue. The scratch volume showing up here was the
    /// 2026-07-08 regression — see ScratchVolumeScreeningTests.
    private var reachableVolumes: [CatalogScanTarget] {
        CatalogScanTarget.analyzeCandidates(model.scanTargets)
    }

    /// Refresh per-volume coverage stats from the catalog, and nudge the
    /// per-volume rate tracker so rate/ETA tick along with the analyzing
    /// volume. The O(records × volumes) refilter is GATED on `coverageKey`
    /// — a 1 s tick with an unchanged catalog only updates the (cheap)
    /// rate trackers from cached coverage. At 103k records the ungated
    /// refilter was the dominant idle main-thread cost (2026-07-05).
    private func refreshCounts() {
        let key = coverageKey
        let catalogChanged = key != lastCoverageKey
        if catalogChanged { lastCoverageKey = key }
        for vol in reachableVolumes {
            let prefix = vol.searchPath
            let cov: CatalogCoverage
            if catalogChanged || volumeCoverage[prefix] == nil {
                let subset = model.records.filter { $0.fullPath.hasPrefix(prefix) }
                cov = CatalogCoverage(records: subset,
                                      scope: captionOrchestrator.analysisScope)
                volumeCoverage[prefix] = cov
            } else {
                cov = volumeCoverage[prefix] ?? .empty
            }
            var tracker = volumeRates[prefix] ?? RateTracker()
            tracker.record(count: cov.dossiered, at: Date())
            volumeRates[prefix] = tracker
        }
        // Default-select the currently-analyzing volume; fall back to
        // the first volume so the drill-down always shows something.
        if selectedVolumePath == nil ||
           !reachableVolumes.contains(where: { $0.searchPath == selectedVolumePath }) {
            selectedVolumePath = captionOrchestrator.currentVolumePrefix
                ?? reachableVolumes.first?.searchPath
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
    private var drillDownLanes: [PipelineLane] {
        guard let sel = selectedVolumePath else { return captionOrchestrator.activeLanes }
        return captionOrchestrator.activeLanes.filter { $0.path.hasPrefix(sel) }
    }

    /// Completed-activity filtered to the selected volume's prefix.
    private var drillDownCompleted: [CompletedActivity] {
        guard let sel = selectedVolumePath else { return captionOrchestrator.recentActivity }
        return captionOrchestrator.recentActivity.filter { $0.path.hasPrefix(sel) }
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
    /// lane for a file the merger has since purged).
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
