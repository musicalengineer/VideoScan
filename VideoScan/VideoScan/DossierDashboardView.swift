import SwiftUI

// MARK: - Dossier Dashboard
//
// Live monitor for the catalog-wide dossier sweep started from the
// Catalog tab's "Dossier All Reachable Volumes" button. Pulls all its
// state from the shared `CaptionOrchestrator` so the dashboard, the
// modal progress sheet, and the orchestrator's internal loop are
// always seeing the same truth.
//
// Opened either via the toolbar chip or `openWindow(id: "dossier")`.

struct DossierDashboardView: View {

    @EnvironmentObject var captionOrchestrator: CaptionOrchestrator
    @EnvironmentObject var model: VideoScanModel

    var body: some View {
        VStack(alignment: .center, spacing: 20) {

            // Title
            Text("Catalog Dossier")
                .font(.title)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)

            // MARK: Dial + headline counters
            HStack(alignment: .center, spacing: 32) {
                DialRing(
                    progress: dialProgress,
                    centerLabel: dialCenterLabel
                )
                .frame(width: 180, height: 180)

                VStack(alignment: .leading, spacing: 12) {
                    StatRow(label: "Done", value: "\(captionOrchestrator.liveCaptioned)", color: .green)
                    StatRow(label: "Skipped", value: "\(captionOrchestrator.liveSkipped)", color: .secondary)
                    StatRow(label: "Failed", value: "\(captionOrchestrator.liveFailed)", color: .orange)
                    StatRow(label: "Total", value: "\(captionOrchestrator.liveTotal)", color: .primary)
                    Divider().frame(width: 160)
                    Text(etaText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            // MARK: Currently processing
            HStack {
                Image(systemName: "play.circle.fill")
                    .foregroundColor(.blue)
                    .imageScale(.large)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Now processing")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(currentFileLabel)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(8)

            // MARK: Channel totals (catalog-wide, not per-batch)
            GroupBox(label: Text("Total dossier coverage").font(.headline)) {
                HStack(spacing: 24) {
                    ChannelStat(
                        icon: "text.bubble.fill",
                        label: "Scene captions",
                        value: scenesPopulatedCount,
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

            // MARK: Action buttons
            HStack(spacing: 12) {
                Button {
                    Task { await captionOrchestrator.startCatalogWideDossier(model: model) }
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .disabled(captionOrchestrator.currentStatus.isActive)

                Button(role: .destructive) {
                    captionOrchestrator.cancel()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!captionOrchestrator.currentStatus.isActive)

                Spacer()

                StatusBadge(status: captionOrchestrator.currentStatus)
            }
        }
        .padding(20)
        .frame(minWidth: 580, minHeight: 480)
    }

    // MARK: - Derived state

    /// Progress 0.0–1.0 for the dial. Reads currentStatus when running,
    /// falls back to live counters during transition states.
    private var dialProgress: Double {
        if case .running(let p, _, _) = captionOrchestrator.currentStatus {
            return p
        }
        let total = captionOrchestrator.liveTotal
        guard total > 0 else { return 0 }
        return Double(captionOrchestrator.liveCurrentIndex) / Double(total)
    }

    private var dialCenterLabel: String {
        let pct = Int(dialProgress * 100)
        return "\(pct)%"
    }

    private var currentFileLabel: String {
        if case .running(_, let file, _) = captionOrchestrator.currentStatus {
            return file
        }
        switch captionOrchestrator.currentStatus {
        case .idle:       return "(idle — click Start to begin)"
        case .cancelling: return "(stopping…)"
        case .finished:   return "(idle)"
        default:          return "(idle)"
        }
    }

    private var etaText: String {
        guard case .running(_, _, let eta?) = captionOrchestrator.currentStatus else {
            return "ETA: —"
        }
        return "ETA: \(formatETA(seconds: eta))"
    }

    /// Catalog-wide totals — counts every record in `model.records` that
    /// has the corresponding dossier channel populated, not just the
    /// current batch. So Rick can see "707 scene captions in catalog"
    /// even when no batch is running.
    private var scenesPopulatedCount: Int {
        model.records.reduce(0) { $0 + ($1.sceneCaptions.isEmpty ? 0 : 1) }
    }
    private var ocrDatesCount: Int {
        model.records.reduce(0) { $0 + ($1.ocrDateCandidates.isEmpty ? 0 : 1) }
    }
    private var transcriptsCount: Int {
        model.records.reduce(0) { $0 + (($1.audioTranscript ?? "").isEmpty ? 0 : 1) }
    }
}

// MARK: - Subviews

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
                Text("complete")
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
                .frame(width: 70, alignment: .leading)
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
        case .idle:       return "idle"
        case .running:    return "running"
        case .cancelling: return "stopping…"
        case .finished:   return "finished"
        }
    }
}

// MARK: - Helpers

private func formatETA(seconds: Int) -> String {
    let s = max(0, seconds)
    if s < 60 { return "\(s)s" }
    let m = s / 60
    if m < 60 { return "\(m)m \(s % 60)s" }
    let h = m / 60
    if h < 24 { return "\(h)h \(m % 60)m" }
    let d = h / 24
    return "\(d)d \(h % 24)h"
}
