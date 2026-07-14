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
///     orange (queued), green (100% done), red (error — Phase 2)
///   - filename count / % done
///   - progress bar + the skip-reason tallies line
///   - status word ("idle" / "analyzing" / "paused" / "Queued (#n)")
///   - action buttons appropriate to the state
///
/// Tap anywhere on the row body (not the buttons) to select it as the
/// drill-down focus. The selected row gets a subtle border.
///
/// Equatable + `.equatable()` at the call site (2026-07-14 render-loop
/// fix): when the dashboard body re-evaluates (snapshot tick), rows
/// whose displayed inputs didn't change skip their body entirely.
/// Closures are excluded from `==` (they're fresh every render but
/// behaviorally identical); `target` compares by identity — content
/// changes on the target still repaint via its own @ObservedObject
/// subscription, independent of this parent-diff gate.
struct DossierVolumeRow: View, Equatable {

    static func == (a: DossierVolumeRow, b: DossierVolumeRow) -> Bool {
        a.target === b.target
            && a.coverage == b.coverage
            && a.isAnalyzing == b.isAnalyzing
            && a.isPaused == b.isPaused
            && a.isSelected == b.isSelected
            && a.queuePosition == b.queuePosition
    }

    @ObservedObject var target: CatalogScanTarget
    let coverage: CatalogCoverage
    let isAnalyzing: Bool
    let isPaused: Bool
    let isSelected: Bool
    /// 1-based position in the analyze queue, nil when not queued.
    /// Replaces the old `canStart` disable (2026-07-14): clicking
    /// Analyze while another volume runs now ENQUEUES this one instead
    /// of being a dead button — intent is never blocked.
    let queuePosition: Int?

    let onSelect: () -> Void
    let onAnalyze: () -> Void
    let onDequeue: () -> Void
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
                // Skip-reason tallies — where did this volume's files
                // go? Fixed order so the eye can compare rows;
                // zero-count buckets drop out to keep the line short.
                // "Set aside" = Analysis Scope exclusions (reversible,
                // NOT junk). O(1) — all counts precomputed in
                // CatalogCoverage off the cached refresh, no per-render
                // records work.
                Text(talliesLabel)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .help("Eligible = files Analyze will process · Done = already analyzed · Set aside = audio-only files excluded by the Analysis Scope (flip the toggle below to include them) · Photos = still images (never analyzed here) · DRM = protected files we can't read · Archived = already put away · Junk = marked for cleanup")
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

    /// "Eligible 4419 · Done 4228 · Set aside 812 · …" — zero buckets
    /// drop out (except the two the user always compares).
    private var talliesLabel: String {
        var parts = [
            "Eligible \(coverage.eligible)",
            "Done \(coverage.dossiered)",
        ]
        if coverage.outOfScopeCount > 0 { parts.append("Set aside \(coverage.outOfScopeCount)") }
        if coverage.photoCount > 0 { parts.append("Photos \(coverage.photoCount)") }
        if coverage.drmCount > 0 { parts.append("DRM \(coverage.drmCount)") }
        if coverage.archivedCount > 0 { parts.append("Archived \(coverage.archivedCount)") }
        if coverage.junkCount > 0 { parts.append("Junk \(coverage.junkCount)") }
        return parts.joined(separator: " · ")
    }

    /// Status word matches the dot color. The complete-state language
    /// is deliberately affirmative ("Analyze Complete") so the user
    /// knows everything the orchestrator could touch IS touched —
    /// not just "idle, waiting."
    private var statusLabel: String {
        if isPaused { return "paused" }
        if isAnalyzing { return "analyzing" }
        if let n = queuePosition { return "Queued (#\(n))" }
        if coverage.eligible > 0 && coverage.dossiered >= coverage.eligible {
            return "Analyze Complete"
        }
        return "idle"
    }

    private var statusColor: Color {
        if isPaused { return .yellow }
        if isAnalyzing { return .blue }
        if queuePosition != nil { return .orange }
        if coverage.eligible > 0 && coverage.dossiered >= coverage.eligible {
            return .green
        }
        return .gray
    }

    /// Action buttons on the trailing edge. Four states:
    ///   - Idle: [Analyze] (enqueues when another volume is busy)
    ///   - Queued: [Remove from Line]
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
        } else if queuePosition != nil {
            Button { onDequeue() } label: {
                Label("Remove from Line", systemImage: "xmark.circle")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Take this volume out of the analyze line. Nothing else changes — you can re-add it any time.")
        } else {
            Button { onAnalyze() } label: {
                Label("Analyze", systemImage: "play.fill")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Analyze this volume's media. If another volume is already running, this one waits its turn in line.")
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
///
/// Equatable (2026-07-14): two renders are equal when the lane AND the
/// DISPLAYED elapsed second match — the enclosing 1 Hz TimelineView
/// hands us a new `now` every tick, but sub-second differences that
/// wouldn't change the "(Ns)" readout no longer re-render the row.
struct ActiveLaneRow: View, Equatable {
    let lane: PipelineLane
    let now: Date
    let onSkip: (PipelineLane) -> Void

    static func == (a: ActiveLaneRow, b: ActiveLaneRow) -> Bool {
        a.lane == b.lane && a.elapsedSeconds == b.elapsedSeconds
    }

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
///
/// Equatable (2026-07-14): equality is the item alone — `now` is
/// deliberately ignored (the row shows "how long it took", never "how
/// long ago"), so clock ticks can't re-render completed history.
struct CompletedActivityRow: View, Equatable {
    let item: CompletedActivity
    let now: Date
    let onShowInCatalog: (CompletedActivity) -> Void

    static func == (a: CompletedActivityRow, b: CompletedActivityRow) -> Bool {
        a.item == b.item
    }

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
