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
//   2. The shared JSONL delta directory
//      (/Volumes/Crucial2TB/dossier-deltas/*.jsonl) — per-host line
//      counts and last-write timestamps so Rick can see which fleet
//      members are alive and how many records each has produced this
//      session.
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

    /// Per-worker JSONL stats. Refreshed by the timer below; never
    /// blocking the main thread on its read.
    @State private var fleet: FleetStats = .empty

    /// Tick the UI every 5s so the dial / counters / fleet panel
    /// stay current. Matches the merger's 60s catalog write cadence —
    /// the dial updates well within a worker's per-file budget.
    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .center, spacing: 18) {

            // Title
            Text("Catalog Dossier")
                .font(.title)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)

            // MARK: Dial + headline coverage counters
            HStack(alignment: .center, spacing: 32) {
                DialRing(
                    progress: dialProgress,
                    centerLabel: dialCenterLabel
                )
                .frame(width: 180, height: 180)

                VStack(alignment: .leading, spacing: 10) {
                    StatRow(label: "Dossiered", value: "\(coverage.dossiered)", color: .green)
                    StatRow(label: "Remaining", value: "\(coverage.remaining)", color: .secondary)
                    StatRow(label: "Catalog", value: "\(coverage.total)", color: .primary)
                    Divider().frame(width: 160)
                    StatRow(label: "OCR dates", value: "\(coverage.ocrDates)", color: .purple)
                    StatRow(label: "Strong dates", value: "\(coverage.strongDates)", color: .green)
                }
                Spacer()
            }

            // MARK: Per-host fleet panel
            GroupBox(label:
                HStack(spacing: 4) {
                    Text("Fleet").font(.headline)
                    Spacer()
                    Text("from JSONL deltas — refreshed every 5s")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            ) {
                VStack(spacing: 6) {
                    ForEach(WorkerHost.allCases, id: \.self) { host in
                        FleetRow(host: host, stat: fleet[host])
                    }
                    if fleet.isEmpty {
                        Text("No worker JSONLs found at /Volumes/Crucial2TB/dossier-deltas/")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 4)
            }

            // MARK: Channel totals (catalog-wide, across both fleet and in-app sweep)
            GroupBox(label: Text("Channel coverage").font(.headline)) {
                HStack(spacing: 24) {
                    ChannelStat(
                        icon: "text.bubble.fill",
                        label: "Scene captions",
                        value: coverage.scenes,
                        color: .indigo
                    )
                    ChannelStat(
                        icon: "calendar.badge.clock",
                        label: "OCR dates",
                        value: coverage.ocrDates,
                        color: .purple
                    )
                    ChannelStat(
                        icon: "waveform.circle.fill",
                        label: "Transcripts",
                        value: coverage.transcripts,
                        color: .teal
                    )
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
            }

            // MARK: In-app sweep controls (separate from fleet workers)
            HStack(spacing: 12) {
                Button {
                    Task { await captionOrchestrator.startCatalogWideDossier(model: model) }
                } label: {
                    Label("In-app Sweep", systemImage: "play.fill")
                }
                .disabled(captionOrchestrator.currentStatus.isActive)
                .help("Start a dossier sweep from within the app (separate from the external fleet workers).")

                Button(role: .destructive) {
                    captionOrchestrator.cancel()
                } label: {
                    Label("Stop In-app", systemImage: "stop.fill")
                }
                .disabled(!captionOrchestrator.currentStatus.isActive)

                Spacer()

                StatusBadge(status: captionOrchestrator.currentStatus)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 540)
        .onAppear { refreshFleet() }
        .onReceive(refreshTimer) { _ in refreshFleet() }
    }

    // MARK: - Catalog-wide coverage

    private var coverage: CatalogCoverage {
        CatalogCoverage(records: model.records)
    }

    private var dialProgress: Double {
        guard coverage.total > 0 else { return 0 }
        return Double(coverage.dossiered) / Double(coverage.total)
    }

    private var dialCenterLabel: String {
        let pct = dialProgress * 100
        if pct < 1 && coverage.dossiered > 0 { return "<1%" }
        return "\(Int(pct))%"
    }

    // MARK: - Fleet refresh

    private func refreshFleet() {
        let dir = URL(fileURLWithPath: "/Volumes/Crucial2TB/dossier-deltas")
        fleet = FleetStats.load(from: dir)
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

    var remaining: Int { max(0, total - dossiered) }

    init(records: [VideoRecord]) {
        var t = 0, d = 0, s = 0, o = 0, x = 0, sd = 0
        for r in records {
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

// MARK: - Fleet stats

/// Known worker hosts. Add an entry here when expanding the fleet
/// (e.g. add Intel one day) — the dashboard's `ForEach` picks it up.
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

        var aliveLabel: String {
            guard let lastWrite else { return "no JSONL" }
            let age = Date().timeIntervalSince(lastWrite)
            if age < 120 { return "active" }       // wrote in last 2 min
            if age < 600 { return "warm" }         // last 10 min
            if age < 3600 { return "idle" }        // last hour
            return "stale"
        }

        var aliveColor: Color {
            guard let lastWrite else { return .gray }
            let age = Date().timeIntervalSince(lastWrite)
            if age < 120 { return .green }
            if age < 600 { return .yellow }
            if age < 3600 { return .orange }
            return .red
        }

        static let empty = HostStat(recordCount: 0, lastWrite: nil, fileBytes: 0)
    }

    var byHost: [WorkerHost: HostStat]

    subscript(host: WorkerHost) -> HostStat {
        byHost[host] ?? .empty
    }

    var isEmpty: Bool {
        byHost.values.allSatisfy { $0.recordCount == 0 && $0.lastWrite == nil }
    }

    static let empty = FleetStats(byHost: [:])

    /// Load per-host stats from JSONL files in `dir`. Each file's line
    /// count is the worker's record count; the file's mtime is its
    /// last-write time. Doesn't parse the JSONL contents — line count
    /// alone is enough for the dashboard.
    static func load(from dir: URL) -> FleetStats {
        var out: [WorkerHost: HostStat] = [:]
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
            // Line count via simple read. Files are kilobytes-to-low-MB;
            // synchronous read is fine here. For files into the
            // hundreds of MB we'd want a streamed line counter.
            let count: Int
            if let data = try? Data(contentsOf: file) {
                count = data.lazy.filter { $0 == 0x0A }.count  // count of \n
            } else {
                count = 0
            }
            out[host] = HostStat(recordCount: count, lastWrite: mtime, fileBytes: size)
        }
        return FleetStats(byHost: out)
    }
}

// MARK: - Fleet row

private struct FleetRow: View {
    let host: WorkerHost
    let stat: FleetStats.HostStat

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(host.color)
                .frame(width: 10, height: 10)
            Text(host.displayName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 160, alignment: .leading)
            Text("\(stat.recordCount) record(s)")
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 110, alignment: .leading)
                .foregroundColor(.secondary)
            HStack(spacing: 4) {
                Circle()
                    .fill(stat.aliveColor)
                    .frame(width: 7, height: 7)
                Text(stat.aliveLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(width: 70, alignment: .leading)
            Spacer()
            if let last = stat.lastWrite {
                Text(relativeTime(last))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let age = Date().timeIntervalSince(date)
        if age < 60 { return "\(Int(age))s ago" }
        if age < 3600 {
            let m = Int(age / 60)
            return "\(m)m ago"
        }
        if age < 86400 {
            let h = Int(age / 3600)
            return "\(h)h ago"
        }
        let d = Int(age / 86400)
        return "\(d)d ago"
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
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: 16)

            Circle()
                .trim(from: 0, to: max(0, min(progress, 1)))
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [.blue, .indigo, .purple, .pink, .orange]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 16, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: progress)

            VStack(spacing: 4) {
                Text(centerLabel)
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                Text("dossiered")
                    .font(.caption)
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
