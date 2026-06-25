// DossierDashboardView+Rows.swift
// The dashboard's per-volume row and live-activity rows — extracted
// verbatim from DossierDashboardView.swift (refactor 2026-06-25):
// DossierVolumeRow, ActiveLaneRow, the humanStageVerb helper, the
// StageBadge_Removed stub, ChannelIndicator, and CompletedActivityRow.
// These are standalone SwiftUI views (no DossierDashboardView `self`
// dependency), so each moves as a whole type rather than into an
// extension. DossierVolumeRow / ActiveLaneRow / CompletedActivityRow
// lost their `private` because DossierDashboardView's body (still in
// the main file) instantiates them across the file boundary — Swift
// `private` is file-scoped. humanStageVerb / StageBadge_Removed /
// ChannelIndicator stay `private` because they are only referenced
// within THIS file.
// (Swift extension/file split ≈ C++ splitting a translation unit:
// `private` here means file-private to THIS .swift file.)

import SwiftUI

// MARK: - Per-volume row
//
// Rick 2026-06-13: dashboard is now per-volume — each row drives its
// own Analyze / Pause / Resume / Stop, and clicking the row sets it
// as the drill-down focus for Now Analyzing / Recently Completed.

/// One volume in the dashboard. Visible state at a glance:
///   - colored dot — gray (idle), blue (analyzing), yellow (paused),
///     green (100% done), red (error/cancelled — Phase 2)
///   - filename count / % done
///   - progress bar
///   - status word ("idle" / "analyzing" / "paused")
///   - action buttons appropriate to the state
///
/// Tap anywhere on the row body (not the buttons) to select it as the
/// drill-down focus. The selected row gets a subtle border.
struct DossierVolumeRow: View {
    @ObservedObject var target: CatalogScanTarget
    let coverage: CatalogCoverage
    let isAnalyzing: Bool
    let isPaused: Bool
    let isSelected: Bool
    /// True when the orchestrator is idle (no batch running). Drives
    /// the Analyze button's enabled state — Phase 1 caps concurrency
    /// at one volume at a time.
    let canStart: Bool

    let onSelect: () -> Void
    let onAnalyze: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(VolumeReachability.displayLabel(forPath: target.searchPath))
                        .font(.system(size: 13, weight: .semibold))
                    Text(countsLabel)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text(percentLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .contentTransition(.numericText())
                        .animation(.default, value: coverage.dossiered)
                    Spacer()
                    Text(statusLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(statusColor)
                }
                ProgressView(value: progressFraction)
                    .progressViewStyle(.linear)
                    .tint(statusColor)
            }
            buttonStack
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.2),
                              lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }

    private var progressFraction: Double {
        // Use eligible as the denominator so 100% means
        // "everything we CAN dossier IS dossiered" — Rick 2026-06-13.
        // Total includes DRM-flagged records the orchestrator skips
        // by design; counting them would lock the dial below 100%.
        guard coverage.eligible > 0 else { return 0 }
        return min(1.0, Double(coverage.dossiered) / Double(coverage.eligible))
    }

    private var percentLabel: String {
        let pct = progressFraction * 100
        if pct < 1 && coverage.dossiered > 0 { return "<1%" }
        return "\(Int(pct))%"
    }

    /// "4228 / 4419" — denominator is eligible, not raw total.
    private var countsLabel: String {
        "\(coverage.dossiered) / \(coverage.eligible)"
    }

    /// Status word matches the dot color. The complete-state language
    /// is deliberately affirmative ("Analyze Complete") so the user
    /// knows everything the orchestrator could touch IS touched —
    /// not just "idle, waiting."
    private var statusLabel: String {
        if isPaused { return "paused" }
        if isAnalyzing { return "analyzing" }
        if coverage.eligible > 0 && coverage.dossiered >= coverage.eligible {
            return "Analyze Complete"
        }
        return "idle"
    }

    private var statusColor: Color {
        if isPaused { return .yellow }
        if isAnalyzing { return .blue }
        if coverage.eligible > 0 && coverage.dossiered >= coverage.eligible {
            return .green
        }
        return .gray
    }

    /// Action buttons on the trailing edge. Three states:
    ///   - Idle: [Analyze] (disabled if another volume is busy)
    ///   - Analyzing: [Pause] [Stop]
    ///   - Paused: [Resume] [Stop]
    @ViewBuilder
    private var buttonStack: some View {
        if isPaused {
            Button { onResume() } label: {
                Label("Resume", systemImage: "play.fill")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button(role: .destructive) { onStop() } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else if isAnalyzing {
            Button { onPause() } label: {
                Label("Pause", systemImage: "pause.fill")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button(role: .destructive) { onStop() } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Button { onAnalyze() } label: {
                Label("Analyze", systemImage: "play.fill")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!canStart)
            .help(canStart
                  ? "Run dossier analysis on this volume's media"
                  : "Another volume is currently analyzing — pause or stop it first")
        }
    }
}

// MARK: - Live activity rows

/// One in-flight FILE row (not stage). Shows: spinner + filename, a
/// stage badge ([Whisper]/[MLXVLM]), the present-tense verb with the
/// live elapsed readout, then a Cancel button on the trailing edge.
///
/// Rick 2026-06-13: ✓/✗/— indicators moved to CompletedActivityRow —
/// they belong with the post-mortem summary, not while the file is
/// still being analyzed. The trailing-edge slot now holds the per-row
/// action (Cancel), which is visible rather than buried in a context
/// menu. Show in Catalog moved to the completed row's context menu.
struct ActiveLaneRow: View {
    let lane: PipelineLane
    let now: Date
    let onSkip: (PipelineLane) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            SpinningRing(color: .cyan, size: 16)
            Text(lane.filename)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 280, alignment: .leading)
            // Human verb — replaces the [Whisper] / [MLXVLM] badge.
            // Rick 2026-06-13: stage names should read as actions,
            // not engine families.
            Text("\(humanStageVerb(for: lane.stageName))  (\(elapsedSeconds)s)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(role: .destructive) {
                onSkip(lane)
            } label: {
                Label("Cancel", systemImage: "xmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Cancel processing on this file. Whisper subprocess is SIGTERMed; VLM result (if any) is preserved.")
        }
    }

    private var elapsedSeconds: Int {
        max(0, Int(now.timeIntervalSince(lane.startedAt)))
    }
}

/// Map the orchestrator's stage family ("Whisper", "MLXVLM", or any
/// future engine name) to a user-facing verb phrase. Anything not
/// recognized falls through so a brand-new stage shows its raw name
/// rather than being silently hidden.
private func humanStageVerb(for stageName: String) -> String {
    switch stageName {
    case "Whisper": return "Transcribing Audio"
    case "MLXVLM":  return "Extracting Captions"
    default:        return stageName
    }
}

/// StageBadge is gone — Rick 2026-06-13 replaced the colored chip
/// with the human verb directly inside the lane row's status line.
/// Kept as a stub so future stages can rebuild the badge if needed.
private struct StageBadge_Removed: View {
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

/// One completed file: checkmark, filename, per-stage timing summary,
/// per-channel ✓/✗/— indicators (moved here from ActiveLaneRow on
/// 2026-06-13 — they belong with the post-mortem summary). Right-click
/// opens Show in Catalog.
///
/// Rick 2026-06-13: we deliberately do NOT show "how long ago" — only
/// "how long it took". The `now: Date` argument is unused but kept so
/// the enclosing TimelineView can still trigger redraws without a
/// signature change to every callsite.
struct CompletedActivityRow: View {
    let item: CompletedActivity
    let now: Date
    let onShowInCatalog: (CompletedActivity) -> Void

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
            ChannelIndicator(label: "Audio Transcript", state: transcriptState)
            ChannelIndicator(label: "Captions", state: captionsState)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                onShowInCatalog(item)
            } label: {
                Label("Show in Catalog", systemImage: "film.stack")
            }
        }
    }

    private var transcriptState: ChannelIndicator.State {
        if item.isVideoOnly { return .notApplicable }
        if item.hasTranscript { return .ok }
        return .missing  // transcriptFailed or never-extracted both → red ✗
    }

    private var captionsState: ChannelIndicator.State {
        item.hasCaptions ? .ok : .missing
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
