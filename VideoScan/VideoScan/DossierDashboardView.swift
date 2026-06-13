import SwiftUI
import Combine

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

    /// Sliding-window rate of records added to the catalog. Driven
    /// by the 5s refresh tick — each tick records (count, now) into
    /// the window; the window itself is trimmed to the last 5 minutes
    /// inside RateTracker. Public surface is just `rate.perMinute`
    /// for display.
    @State private var rate: RateTracker = .init()
    @State private var dossieredCount: Int = 0
    @State private var totalCount: Int = 0
    @State private var scenesCount: Int = 0
    @State private var ocrDatesCount: Int = 0
    @State private var strongDatesCount: Int = 0
    @State private var transcriptsCount: Int = 0

    /// Tick the UI every 1s so the dial / counters move in near-real
    /// time. Rick 2026-06-13: 5s felt static — files complete every few
    /// seconds on a healthy run, and a 5s sample window means the rate
    /// tracker stays on "—" for 5 seconds after the first completion.
    /// Polling 15k records per second is a few hundred microseconds on
    /// M-series silicon — cheap enough that we don't need to subscribe
    /// to model.objectWillChange and risk a render storm during heavy
    /// dossier writeback.
    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Hard cap on rows shown under "Now Analyzing". Rick 2026-06-13:
    /// more than 5 makes the window too tall. Excess lanes still tick
    /// through the pipeline; they're collapsed into a "+ N more"
    /// trailing line so the user knows the cap is active.
    static let activeLanesVisibleCap = 5

    var body: some View {
        VStack(alignment: .center, spacing: 18) {

            // Title
            Text("Catalog Dossier")
                .font(.title)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)

            // MARK: Dial + headline coverage counters
            HStack(alignment: .center, spacing: 36) {
                // Big dial per Rick's preference for bigger graphics.
                // Was 180 — bumped to 270 (50% larger) so the % readout
                // is legible from across the room.
                DialRing(
                    progress: dialProgress,
                    centerLabel: dialCenterLabel
                )
                .frame(width: 270, height: 270)

                VStack(alignment: .leading, spacing: 10) {
                    StatRow(label: "Media Files", value: "\(totalCount)", color: .primary)
                    StatRow(label: "Analyzed", value: "\(dossieredCount)", color: .green)
                    StatRow(label: "Remaining", value: "\(max(0, totalCount - dossieredCount))", color: .secondary)

                    Divider().frame(width: 160)
                    StatRow(label: "Rate", value: rate.displayText, color: rate.color)
                    StatRow(label: "ETA",
                            value: rate.etaDisplayText(remaining: max(0, totalCount - dossieredCount)),
                            color: rate.hasEnoughSamples ? .primary : .secondary)
                    StatRow(label: "OCR dates", value: "\(ocrDatesCount)", color: .purple)
                    StatRow(label: "Strong dates", value: "\(strongDatesCount)", color: .green)
                }
                Spacer()
            }

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
                if captionOrchestrator.activeLanes.isEmpty {
                    Text("pipeline idle — press Analyze Local Media")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                } else {
                    // Rick 2026-06-13: cap visible lanes at 5. The pipeline
                    // itself only runs a handful in flight, but the cap
                    // also bounds window height if a future change widens
                    // concurrency. `prefix(5)` is taken before iterating
                    // so the slice itself is the @Published-driven input.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(captionOrchestrator.activeLanes.prefix(Self.activeLanesVisibleCap))) { lane in
                                ActiveLaneRow(lane: lane, now: context.date)
                            }
                            if captionOrchestrator.activeLanes.count > Self.activeLanesVisibleCap {
                                Text("+ \(captionOrchestrator.activeLanes.count - Self.activeLanesVisibleCap) more in flight")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                    }
                }
            }

            GroupBox(label: Text("Recently Completed").font(.headline)) {
                if captionOrchestrator.recentActivity.isEmpty {
                    Text("no files analyzed yet this session")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(captionOrchestrator.recentActivity) { item in
                                CompletedActivityRow(item: item, now: context.date)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                    }
                    // Subtle slide-in when a new row lands at the top.
                    .animation(.default, value: captionOrchestrator.recentActivity)
                }
            }

            // MARK: Total processed (catalog-wide, across both fleet and in-app sweep)
            GroupBox(label: Text("Total Processed").font(.headline)) {
                HStack(spacing: 24) {
                    ChannelStat(
                        icon: "text.bubble.fill",
                        label: "Scene captions",
                        value: scenesCount,
                        color: .indigo
                    )
                    ChannelStat(
                        icon: "calendar.badge.clock",
                        label: "OCR dates",
                        value: ocrDatesCount,
                        color: .purple
                    )
                    ChannelStat(
                        icon: "waveform.circle.fill",
                        label: "Transcripts",
                        value: transcriptsCount,
                        color: .teal
                    )
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
            }

            // MARK: Local analysis controls
            HStack(spacing: 12) {
                Button {
                    Task { await captionOrchestrator.startCatalogWideDossier(model: model) }
                } label: {
                    Label("Analyze Local Media", systemImage: "play.fill")
                }
                .disabled(captionOrchestrator.currentStatus.isActive)
                .help("Run dossier analysis on all reachable local media files.")

                Button(role: .destructive) {
                    captionOrchestrator.cancel()
                } label: {
                    Label("Stop Analyzing", systemImage: "stop.fill")
                }
                .disabled(!captionOrchestrator.currentStatus.isActive)

                Toggle("Resume on Launch", isOn: $autoResume)
                    .toggleStyle(.checkbox)
                    .help("Automatically start dossier analysis when the app launches.")

                Spacer()

                StatusBadge(status: captionOrchestrator.currentStatus)
            }
        }
        .padding(20)
        // minHeight grew 700 → 760: the two activity sections can run
        // taller than the 3-row fleet panel they replaced (2 lanes +
        // up to 8 history rows).
        .frame(minWidth: 700, minHeight: 760)
        .onAppear { refreshCounts() }
        .onReceive(refreshTimer) { _ in
            refreshCounts()
        }
    }

    // MARK: - Catalog-wide coverage

    private func refreshCounts() {
        let c = CatalogCoverage(records: model.records)
        dossieredCount = c.dossiered
        totalCount = c.total
        scenesCount = c.scenes
        ocrDatesCount = c.ocrDates
        strongDatesCount = c.strongDates
        transcriptsCount = c.transcripts
        rate.record(count: c.dossiered, at: Date())
    }

    private var dialProgress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(dossieredCount) / Double(totalCount)
    }

    private var dialCenterLabel: String {
        let pct = dialProgress * 100
        if pct < 1 && dossieredCount > 0 { return "<1%" }
        return "\(Int(pct))%"
    }
}

// MARK: - Live activity rows

/// One in-flight FILE row (not stage). Shows: spinner + filename, a
/// stage badge ([Whisper]/[MLXVLM]), the present-tense verb with the
/// live elapsed readout, then per-channel indicators on the trailing
/// edge. `now` comes from the enclosing TimelineView's 1s clock so
/// the "(Ns)" ticks without any per-row timers.
///
/// Indicator semantics:
///   - Audio Transcript: gray dash for `isVideoOnly`; green ✓ when
///     `hasTranscript`; red ✗ when `transcriptFailed` or not yet.
///   - Captions: green ✓ when `hasCaptions`; red ✗ otherwise.
private struct ActiveLaneRow: View {
    let lane: PipelineLane
    let now: Date

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            SpinningRing(color: .cyan, size: 16)
            Text(lane.filename)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 280, alignment: .leading)
            StageBadge(stage: lane.stageName)
            Text("\(lane.verb)  (\(elapsedSeconds)s)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            ChannelIndicator(label: "Audio Transcript", state: transcriptState)
            ChannelIndicator(label: "Captions", state: captionsState)
        }
    }

    private var elapsedSeconds: Int {
        max(0, Int(now.timeIntervalSince(lane.startedAt)))
    }

    private var transcriptState: ChannelIndicator.State {
        if lane.isVideoOnly { return .notApplicable }
        if lane.hasTranscript { return .ok }
        return .missing  // not yet OR transcriptFailed — both render as red ✗
    }

    private var captionsState: ChannelIndicator.State {
        lane.hasCaptions ? .ok : .missing
    }
}

/// Stage name in a small rounded chip, e.g. `[Whisper]`. Color tracks
/// the engine family so the dashboard reads at a glance.
private struct StageBadge: View {
    let stage: String

    var body: some View {
        Text(stage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color)
            )
    }

    private var color: Color {
        let lower = stage.lowercased()
        if lower.contains("whisper") { return .teal }
        if lower.contains("mlxvlm") || lower.contains("vlm") || lower.contains("qwen") { return .indigo }
        return .gray
    }
}

/// Per-channel checkmark used both on the active-row trailing edge.
/// Three states: green ✓, red ✗, gray — for "n/a" (e.g. video-only file
/// for the Audio Transcript channel).
private struct ChannelIndicator: View {
    enum State { case ok, missing, notApplicable }

    let label: String
    let state: State

    var body: some View {
        HStack(spacing: 4) {
            icon
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 13))
        case .missing:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
                .font(.system(size: 13))
        case .notApplicable:
            Image(systemName: "minus.circle.fill")
                .foregroundColor(.gray)
                .font(.system(size: 13))
        }
    }
}

/// One completed file: checkmark, filename, per-stage timing summary.
/// Rick 2026-06-13: we deliberately do NOT show "how long ago" — only
/// "how long it took". The `now: Date` argument is unused but kept so
/// the enclosing TimelineView can still trigger redraws without a
/// signature change to every callsite.
private struct CompletedActivityRow: View {
    let item: CompletedActivity
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(.green)
            Text(item.filename)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 280, alignment: .leading)
            Text(summary)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
        }
    }

    /// "VLM 11.2s · Whisper 6.4s · Synced" — segments drop out when a
    /// stage didn't run, and the note ("no audio", "transcript failed",
    /// "no transcriber") slots in where the missing stage's timing
    /// would have been.
    private var summary: String {
        var parts: [String] = []
        if let v = item.vlmSeconds {
            parts.append(String(format: "VLM %.1fs", v))
        }
        if let w = item.whisperSeconds {
            parts.append(String(format: "Whisper %.1fs", w))
        }
        if let note = item.note {
            parts.append(note)
        }
        parts.append("Synced")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Catalog coverage (pure value type)

/// `internal` (not `private`) so unit tests in CatalogCoverageTests
/// can exercise the channel-counting logic without spinning a window.
struct CatalogCoverage {
    let total: Int
    let dossiered: Int
    let scenes: Int
    let ocrDates: Int
    let transcripts: Int
    let strongDates: Int

    static let empty = CatalogCoverage()
    var remaining: Int { max(0, total - dossiered) }

    init(total: Int = 0, dossiered: Int = 0, scenes: Int = 0,
         ocrDates: Int = 0, transcripts: Int = 0, strongDates: Int = 0) {
        self.total = total; self.dossiered = dossiered; self.scenes = scenes
        self.ocrDates = ocrDates; self.transcripts = transcripts; self.strongDates = strongDates
    }

    init(records: [VideoRecord]) {
        var t = 0, d = 0, s = 0, o = 0, x = 0, sd = 0
        for r in records {
            // Skip records that are out of scope for dossier work.
            // Rick 2026-06-10: confirmedJunk records are stuff the user
            // has already decided to delete — counting them inflates the
            // "Remaining" pool and tricks the dial into looking stuck.
            // Purged records are tombstones from prior removals; they
            // shouldn't count toward active progress either.
            if r.mediaDisposition == .confirmedJunk { continue }
            if r.purgedAt != nil { continue }
            t += 1
            if r.dossierProcessedAt != nil { d += 1 }
            if !r.sceneCaptions.isEmpty { s += 1 }
            if !r.ocrDateCandidates.isEmpty { o += 1 }
            if !(r.audioTranscript ?? "").isEmpty { x += 1 }
            if let conf = r.inferredDateConfidence, conf >= 0.85 { sd += 1 }
        }
        total = t; dossiered = d; scenes = s
        ocrDates = o; transcripts = x; strongDates = sd
    }
}

// MARK: - Sliding-window rate tracker

/// Records (count, timestamp) samples over a sliding window and
/// reports the average rate of growth as files per minute. Designed
/// for the dashboard refresh tick — pure value semantics so it
/// works as @State and is easy to unit-test.
///
/// `internal` (not `private`) so RateTrackerTests can drive it
/// without spinning a window.
struct RateTracker: Equatable {

    /// Default sliding-window size — 5 minutes. Short enough that the
    /// rate is responsive to "still cooking?" questions; long enough
    /// that one slow file doesn't dip the number to zero.
    static let defaultWindow: TimeInterval = 300

    private struct Sample: Equatable {
        let count: Int
        let at: Date
    }

    private var samples: [Sample] = []
    let window: TimeInterval

    init(window: TimeInterval = RateTracker.defaultWindow) {
        self.window = window
    }

    /// Add a new sample. Older samples outside the window are trimmed.
    /// If the count went down (e.g. catalog reset), we drop the
    /// stale samples and start fresh — otherwise a reset would
    /// produce a negative rate which is meaningless to the user.
    mutating func record(count: Int, at: Date) {
        // Detect a reset (count went down) and clear the window.
        if let last = samples.last, count < last.count {
            samples.removeAll()
        }
        samples.append(Sample(count: count, at: at))
        // Trim anything outside the window.
        let cutoff = at.addingTimeInterval(-window)
        samples.removeAll { $0.at < cutoff }
    }

    /// Average rate over the recorded window, expressed as files
    /// per minute. Returns 0 if there's only one sample (need a
    /// delta) or if the elapsed time is zero.
    var perMinute: Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        let elapsed = last.at.timeIntervalSince(first.at)
        guard elapsed > 0 else { return 0 }
        let delta = Double(last.count - first.count)
        return delta / elapsed * 60.0
    }

    /// True once we have at least two samples in the window — i.e.
    /// enough to compute a real rate.
    var hasEnoughSamples: Bool { samples.count >= 2 }

    /// User-facing label. Prefers files/min for human-scale rates,
    /// switches to files/sec when the rate is high enough that
    /// "per second" is more readable. Uses "—" until two samples
    /// land so we don't flash a misleading "0/min" on first paint.
    var displayText: String {
        guard hasEnoughSamples else { return "—" }
        let perMin = perMinute
        if perMin >= 60 {
            return String(format: "%.1f/s", perMin / 60)
        }
        if perMin >= 10 {
            return String(format: "%.0f/min", perMin)
        }
        return String(format: "%.1f/min", perMin)
    }

    /// Quick traffic-light color hint for the StatRow. Green when the
    /// fleet is actively producing (>= 1 file/min), gray when it's
    /// idle, secondary while we wait for the second sample.
    var color: Color {
        guard hasEnoughSamples else { return .secondary }
        if perMinute >= 1 { return .green }
        return .gray
    }

    // MARK: - ETA
    //
    // Rick 2026-06-09: "estimated time to completion, just a rough
    // guess." Computed from the rolling rate × remaining records.
    // Caveats baked into the display string so the user trusts it:
    //   - Returns nil if rate is 0 (would be ∞) or if we don't have
    //     enough samples yet — the dashboard then shows "—".
    //   - Rounds aggressively: "~3h", "~45m" — not "3 hours 14 minutes
    //     22 seconds" which would just be misleading precision.

    /// Estimated wall-clock time to dossier `remaining` more records,
    /// at the current rolling rate. Nil when the rate is too low to
    /// be meaningful or when there's nothing left to do.
    func eta(remaining: Int) -> TimeInterval? {
        guard remaining > 0, hasEnoughSamples else { return nil }
        let rateMin = perMinute
        guard rateMin > 0.1 else { return nil }  // <0.1/min ≈ "forever"
        let minutes = Double(remaining) / rateMin
        return minutes * 60   // seconds
    }

    /// User-facing rough ETA string. Bands chosen so the precision
    /// matches the uncertainty:
    ///   <  1 m  → "<1m"
    ///   <  1 h  → "~Nm"
    ///   <  1 d  → "~Nh"  (1h granularity is enough; we don't know
    ///                     to the minute over hours-long horizons)
    ///   ≥  1 d  → "~Nd Mh"
    /// Returns "—" for nil ETA (rate too low or nothing left).
    func etaDisplayText(remaining: Int) -> String {
        guard let secs = eta(remaining: remaining) else { return "—" }
        let mins = secs / 60
        if mins < 1 { return "<1m" }
        if mins < 60 { return "~\(Int(mins.rounded()))m" }
        let hours = mins / 60
        if hours < 24 { return "~\(Int(hours.rounded()))h" }
        let days = Int(hours / 24)
        let leftover = Int(hours.rounded()) - days * 24
        return leftover > 0 ? "~\(days)d \(leftover)h" : "~\(days)d"
    }
}

// MARK: - Fleet stats
//
// No longer rendered by the dashboard (the "Participating Computers"
// panel was replaced by the live pipeline activity sections,
// 2026-06-12). Kept because the JSONL parsing logic has unit tests
// (FleetStatsTailTests) and the multi-machine fleet may return.

/// Known worker hosts. Add an entry here when expanding the fleet
/// (e.g. add Intel one day).
enum WorkerHost: String, CaseIterable {
    case m4 = "RicksM4"
    case m5 = "RicksM5"
    case m1 = "RicksM1"

    var displayName: String {
        switch self {
        case .m4: return "M4 Mac Studio"
        case .m5: return "M5 MacBook Pro"
        case .m1: return "M1 MacBook Pro"
        }
    }

    var jsonlBasename: String {
        switch self {
        case .m4: return "m4.jsonl"
        case .m5: return "m5.jsonl"
        case .m1: return "m1.jsonl"
        }
    }

    var color: Color {
        switch self {
        case .m4: return .blue
        case .m5: return .green
        case .m1: return .orange
        }
    }
}

struct FleetStats {
    struct HostStat {
        let recordCount: Int
        let lastWrite: Date?
        let fileBytes: Int64
        /// Closure sentinel — present when the worker wrote a `_status`
        /// line as its final JSONL entry. Absent for a crashed/killed
        /// worker (the honest signal: we don't know if it finished).
        let sentinel: Sentinel?

        struct Sentinel: Equatable {
            /// "done" = paths file exhausted cleanly.
            /// "interrupted" = SIGINT mid-run (Ctrl-C).
            let status: String
            let processedOk: Int
            let processedFailed: Int
            let targetsTotal: Int
            let exitedAt: Date?
        }

        /// Four-state user-facing label, ranked by certainty.
        ///   sentinel present                → "done" or "stopped"  (factual)
        ///   wrote in last 2 min             → "running"            (factual)
        ///   wrote 2 min – 1 hr ago          → "stale"              (factual)
        ///   quiet >1 hr AND has records     → "done?"              (heuristic)
        ///   never wrote / no records        → "idle"               (factual)
        var aliveLabel: String {
            if let s = sentinel {
                return s.status == "done" ? "done" : "stopped"
            }
            guard let lastWrite else {
                return recordCount > 0 ? "done?" : "idle"
            }
            let age = Date().timeIntervalSince(lastWrite)
            if age < 120 { return "running" }
            if age < 3600 { return "stale" }
            return recordCount > 0 ? "done?" : "idle"
        }

        /// Color map keyed to the label above. Green is reserved for
        /// "done" (factual or heuristic). Cyan = active processing.
        /// Orange = stale (alive but quiet). Gray = idle / not yet
        /// touched. This separates "currently working" from "finished
        /// working" visually — a request from Rick 2026-06-07.
        var aliveColor: Color {
            if let s = sentinel {
                return s.status == "done" ? .green : .orange
            }
            guard let lastWrite else {
                return recordCount > 0 ? .green.opacity(0.65) : .gray
            }
            let age = Date().timeIntervalSince(lastWrite)
            if age < 120 { return .cyan }
            if age < 3600 { return .orange }
            return recordCount > 0 ? .green.opacity(0.65) : .gray
        }

        static let empty = HostStat(recordCount: 0, lastWrite: nil,
                                    fileBytes: 0, sentinel: nil)
    }

    /// Parsed result from a previous tick, keyed by the file's stat()
    /// identity (mtime + size). If neither changed, the bytes didn't
    /// either — workers only ever append — so the previous line count
    /// and sentinel are still valid and we skip the read entirely.
    struct CachedEntry: Equatable {
        let mtime: Date?
        let size: Int64
        let recordCount: Int
        let sentinel: HostStat.Sentinel?
    }

    var byHost: [WorkerHost: HostStat]

    subscript(host: WorkerHost) -> HostStat {
        byHost[host] ?? .empty
    }

    var isEmpty: Bool {
        byHost.values.allSatisfy { $0.recordCount == 0 && $0.lastWrite == nil }
    }

    static let empty = FleetStats(byHost: [:])

    /// Convenience overload — uncached load. Kept for existing callers
    /// and tests; the dashboard tick uses the cached variant below.
    static func load(from dir: URL) -> FleetStats {
        load(from: dir, cache: [:]).stats
    }

    /// Load per-host stats from JSONL files in `dir`. Each file's line
    /// count is the worker's record count; the file's mtime is its
    /// last-write time.
    ///
    /// Cost discipline (these files are now ~tens of MB — the old
    /// "kilobytes-to-low-MB" assumption is dead):
    ///   - stat() every tick (cheap)
    ///   - if (mtime, size) match the previous tick's cache → reuse the
    ///     parsed result, zero reads
    ///   - if changed → count 0x0A over raw bytes in chunked reads
    ///     (never via String — grapheme-aware splitting of a 28 MB file
    ///     was the measured beachball), and parse the sentinel from a
    ///     small FileHandle tail read instead of the whole file.
    static func load(from dir: URL,
                     cache: [WorkerHost: CachedEntry])
        -> (stats: FleetStats, cache: [WorkerHost: CachedEntry]) {
        var out: [WorkerHost: HostStat] = [:]
        var newCache: [WorkerHost: CachedEntry] = [:]
        let fm = FileManager.default
        for host in WorkerHost.allCases {
            let file = dir.appendingPathComponent(host.jsonlBasename)
            guard fm.fileExists(atPath: file.path) else {
                out[host] = .empty
                continue
            }
            let attrs = (try? fm.attributesOfItem(atPath: file.path)) ?? [:]
            let mtime = attrs[FileAttributeKey.modificationDate] as? Date
            let size = (attrs[FileAttributeKey.size] as? NSNumber)?.int64Value ?? 0

            let recordCount: Int
            let sentinel: HostStat.Sentinel?
            if let hit = cache[host], hit.mtime == mtime, hit.size == size {
                // Unchanged since last tick — no I/O beyond the stat.
                recordCount = hit.recordCount
                sentinel = hit.sentinel
            } else {
                let lineCount = Self.countNewlines(at: file)
                // The `_status` sentinel, when present, is the file's
                // LAST line (workers append it on clean exit). A small
                // tail read finds it without touching the rest.
                sentinel = Self.readTail(of: file)
                    .flatMap(Self.lastLine(ofTail:))
                    .flatMap(Self.parseSentinel(line:))
                // Don't count the sentinel line as a record — it's not a delta.
                recordCount = sentinel != nil ? max(0, lineCount - 1) : lineCount
            }
            newCache[host] = CachedEntry(mtime: mtime, size: size,
                                         recordCount: recordCount,
                                         sentinel: sentinel)
            out[host] = HostStat(recordCount: recordCount,
                                 lastWrite: mtime,
                                 fileBytes: size,
                                 sentinel: sentinel)
        }
        return (FleetStats(byHost: out), newCache)
    }

    // MARK: - Byte-level helpers (pure pieces are unit-tested)

    /// How many bytes of file tail to read when hunting the sentinel.
    /// Sentinel lines are a few hundred bytes; 4 KB is generous slack.
    static let tailWindowBytes = 4096

    /// Read up to `maxBytes` from the END of `url` via seek — never the
    /// whole file. Returns nil if the file can't be opened/read.
    static func readTail(of url: URL, maxBytes: Int = FleetStats.tailWindowBytes) -> Data? {
        guard maxBytes > 0, let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let end = try? fh.seekToEnd() else { return nil }
        let offset = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        guard (try? fh.seek(toOffset: offset)) != nil else { return nil }
        return (try? fh.readToEnd()) ?? Data()
    }

    /// Extract the last complete line from a tail-of-file byte window.
    /// Pure function over Data so it's testable without I/O.
    ///
    /// Trailing newlines are stripped, then everything after the last
    /// remaining 0x0A is the candidate line. Because 0x0A never occurs
    /// inside a multi-byte UTF-8 sequence, any slice that starts right
    /// after a newline is valid UTF-8 (if the file is). If the window
    /// contains NO newline before the candidate (seek landed mid-line,
    /// possibly mid-character), UTF-8 decoding may fail — we return nil
    /// rather than a garbled partial line.
    static func lastLine(ofTail tail: Data) -> String? {
        var bytes = tail[...]
        while bytes.last == 0x0A { bytes = bytes.dropLast() }
        guard !bytes.isEmpty else { return nil }
        let start: Data.Index
        if let nl = bytes.lastIndex(of: 0x0A) {
            start = bytes.index(after: nl)
        } else {
            start = bytes.startIndex
        }
        return String(data: bytes[start...], encoding: .utf8)
    }

    /// Count 0x0A bytes in a Data chunk. Pure, raw-byte — deliberately
    /// NOT String-based: Swift's Character is a grapheme cluster, so
    /// String splitting walks Unicode segmentation over every byte.
    /// (C++ analogy: this is memchr-in-a-loop, not std::getline.)
    static func newlineCount(in data: Data) -> Int {
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int in
            var n = 0
            for byte in buf where byte == 0x0A { n += 1 }
            return n
        }
    }

    /// Streamed newline count over a file in `chunkSize` reads, each
    /// inside an autoreleasepool so Foundation's transient buffers
    /// don't accumulate (memory-pressure discipline for media-size files).
    static func countNewlines(at url: URL, chunkSize: Int = 1 << 20) -> Int {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? fh.close() }
        var total = 0
        var done = false
        while !done {
            autoreleasepool {
                guard let chunk = try? fh.read(upToCount: chunkSize), !chunk.isEmpty else {
                    done = true
                    return
                }
                total += newlineCount(in: chunk)
            }
        }
        return total
    }

    /// Decode a single JSONL line as a `_status` sentinel. Returns nil
    /// for ordinary delta lines (the steady state for a running worker)
    /// or for truncated/partial lines that don't parse.
    static func parseSentinel(line: String) -> HostStat.Sentinel? {
        guard line.contains("\"_status\""),
              let lineData = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let status = obj["_status"] as? String else { return nil }
        let exitDate = (obj["exitedAt"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0)
        }
        return HostStat.Sentinel(
            status: status,
            processedOk: obj["processedOk"] as? Int ?? 0,
            processedFailed: obj["processedFailed"] as? Int ?? 0,
            targetsTotal: obj["targetsTotal"] as? Int ?? 0,
            exitedAt: exitDate
        )
    }
}

// MARK: - Existing subviews (DialRing, StatRow, ChannelStat, StatusBadge)

/// The big colorful ring. Drawn as two stacked circles: faint full
/// circle (the track), then the colored arc trimmed to the progress
/// fraction. Center label is the % string.
private struct DialRing: View {
    let progress: Double
    let centerLabel: String

    var body: some View {
        ZStack {
            // Stroke width scaled with the ring — 24 reads better at
            // 270px than the old 16.
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: 24)

            Circle()
                .trim(from: 0, to: max(0, min(progress, 1)))
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [.blue, .indigo, .purple, .pink, .orange]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 24, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: progress)

            VStack(spacing: 4) {
                // Scaled with the ring — bigger graphics per Rick's
                // preference. Rounded font reads well at this size.
                Text(centerLabel)
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                    // numericText() animates digit changes (a brief
                    // scroll/flip) so the % readout glides instead of
                    // popping when the catalog ticks up.
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: centerLabel)
                Text("Analyzed")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
    }
}

private struct StatRow: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .frame(width: 90, alignment: .leading)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 60, alignment: .trailing)
                .foregroundColor(color)
                // Number-aware transition: each digit change scrolls
                // briefly rather than popping. Rate/ETA also pass
                // through here — a "—" → "1.2/min" transition still
                // animates because contentTransition handles both.
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.3), value: value)
        }
    }
}

private struct ChannelStat: View {
    let icon: String
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(color)
            Text("\(value)")
                .font(.system(.title3, design: .monospaced))
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.3), value: value)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StatusBadge: View {
    let status: CaptionJobStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(badgeColor)
                .frame(width: 8, height: 8)
            Text(badgeText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12))
        .cornerRadius(10)
    }

    private var badgeColor: Color {
        switch status {
        case .idle:       return .gray
        case .running:    return .green
        case .cancelling: return .orange
        case .finished:   return .blue
        }
    }

    private var badgeText: String {
        switch status {
        case .idle:       return "in-app sweep idle"
        case .running:    return "in-app sweep running"
        case .cancelling: return "stopping…"
        case .finished:   return "in-app sweep finished"
        }
    }
}
