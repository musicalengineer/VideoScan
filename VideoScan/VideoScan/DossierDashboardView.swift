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
    @AppStorage("DossierAutoResume") private var autoResume: Bool = false

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
    /// Polling 15k records per second is a few hundred microseconds on
    /// M-series silicon — cheap enough that we don't need to subscribe
    /// to model.objectWillChange and risk a render storm during heavy
    /// dossier writeback.
    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
            // drill-down focus below).
            VStack(spacing: 6) {
                ForEach(reachableVolumes, id: \.id) { vol in
                    DossierVolumeRow(
                        target: vol,
                        coverage: volumeCoverage[vol.searchPath] ?? .empty,
                        isAnalyzing: captionOrchestrator.currentVolumePrefix == vol.searchPath
                            && captionOrchestrator.currentStatus.isActive,
                        isPaused: captionOrchestrator.currentVolumePrefix == vol.searchPath
                            && captionOrchestrator.paused,
                        isSelected: selectedVolumePath == vol.searchPath,
                        canStart: !captionOrchestrator.currentStatus.isActive,
                        onSelect: { selectedVolumePath = vol.searchPath },
                        onAnalyze: { Task { await captionOrchestrator.startAnalyzing(
                            volumePrefix: vol.searchPath, model: model) } },
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
                    .help("Auto-resume any volume that was analyzing when the app last quit.")
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

    // MARK: - Per-volume coverage

    /// The list of volumes shown as rows. Only reachable, non-retired,
    /// non-empty scan targets — matches the candidate filter's gate so
    /// what the user sees in a row matches what Analyze will queue.
    private var reachableVolumes: [CatalogScanTarget] {
        model.scanTargets.filter {
            $0.isReachable && !$0.searchPath.isEmpty && !$0.isRetired
        }
    }

    /// Refresh every per-volume coverage stat from the catalog. Cheap
    /// on M-series: ~15k records × a few field reads = sub-millisecond.
    /// Also nudges the per-volume rate tracker so rate/ETA tick along
    /// with the analyzing volume.
    private func refreshCounts() {
        for vol in reachableVolumes {
            let prefix = vol.searchPath
            let subset = model.records.filter { $0.fullPath.hasPrefix(prefix) }
            let cov = CatalogCoverage(records: subset)
            volumeCoverage[prefix] = cov
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
