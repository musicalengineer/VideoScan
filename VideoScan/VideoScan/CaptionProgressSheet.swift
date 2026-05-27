import SwiftUI

// MARK: - CaptionProgressSheet
//
// Modal sheet shown while a CaptionOrchestrator batch is in flight.
// Mirrors the shape of the existing CombineSheet / per-job progress
// surfaces — title, progress bar, current-file label, counts, cancel.
//
// Display contract:
//   * Title         "Captioning [Volume Name]"
//   * Progress bar  0..1, sourced from orchestrator.currentStatus
//   * Current file  filename of the file actively being captioned,
//                   front-truncated with "…" if long so the tail (which
//                   carries the disambiguating filename) stays visible.
//   * Counts row    "[currentIdx] of [total] · captioned N · skipped N · failed N"
//   * ETA           "About 4m 30s remaining" — only after the first
//                   file completes; nil → "Estimating…"
//   * Cancel button Flips orchestrator.cancel(); disables itself + shows
//                   "Cancelling…" until status transitions to .finished.
//                   The sheet's `isPresented` binding is flipped to
//                   false by the .onChange(of: orchestrator.currentStatus)
//                   handler when status reaches .finished — so the
//                   sheet closes without further user action.
//
// Worst-case memory footprint: trivial. One String for the current
// file + handful of Ints. No image buffers, no streaming.

struct CaptionProgressSheet: View {
    @ObservedObject var orchestrator: CaptionOrchestrator
    @Binding var isPresented: Bool

    /// Display label for the title. Derived from the orchestrator's
    /// current target via VolumeReachability so the sheet stays useful
    /// when the target's path is opaque (mounted at /Volumes/...).
    private var titleLabel: String {
        if let t = orchestrator.currentTarget {
            return "Captioning " + VolumeReachability.displayLabel(forPath: t.searchPath)
        }
        return "Captioning"
    }

    /// Pulls a 0..1 fraction out of the current status, or 0 if we're
    /// in any non-running state. SwiftUI ProgressView clamps anyway.
    private var progressFraction: Double {
        if case .running(let p, _, _) = orchestrator.currentStatus { return p }
        if case .cancelling = orchestrator.currentStatus {
            // Hold the last-known progress steady — re-derive from the
            // live counts. Avoids the bar snapping back to 0 visually.
            guard orchestrator.liveTotal > 0 else { return 0 }
            return Double(orchestrator.liveCurrentIndex) / Double(orchestrator.liveTotal)
        }
        return 0
    }

    /// Current file's display name. We pull from the .running case's
    /// payload (the canonical source), not from any cached state.
    private var currentFileDisplay: String {
        if case .running(_, let file, _) = orchestrator.currentStatus { return file }
        if case .cancelling = orchestrator.currentStatus { return "Cancelling…" }
        return ""
    }

    /// ETA string. nil → "Estimating…" since the first file's load is
    /// dominated by the one-time model load.
    private var etaDisplay: String {
        if case .running(_, _, let etaSec) = orchestrator.currentStatus {
            if let s = etaSec { return "About \(formatETA(s)) remaining" }
            return "Estimating…"
        }
        if case .cancelling = orchestrator.currentStatus { return "" }
        return ""
    }

    /// Cancel button label. Switches to "Cancelling…" while the loop
    /// is winding down so the user can see their request was heard
    /// even if the runner is mid-frame.
    private var cancelLabel: String {
        if case .cancelling = orchestrator.currentStatus { return "Cancelling…" }
        return "Cancel"
    }

    private var cancelDisabled: Bool {
        if case .cancelling = orchestrator.currentStatus { return true }
        if case .finished = orchestrator.currentStatus { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Title row — clear what the sheet is doing and where.
            HStack(spacing: 8) {
                Image(systemName: "text.viewfinder")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(titleLabel)
                    .font(.title3.weight(.semibold))
            }

            // Progress bar — bounded 0..1; SwiftUI handles indeterminate
            // mode automatically when total is omitted, but we always
            // have a total here so a fixed bar is fine.
            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)

            // Current file. Front-truncate with .truncationMode so the
            // distinguishing filename stays readable when paths are
            // long. font monospaced so successive filenames don't
            // jiggle the row width.
            HStack(spacing: 6) {
                Text("Current:")
                    .foregroundStyle(.secondary)
                Text(currentFileDisplay.isEmpty ? "—" : currentFileDisplay)
                    .font(.system(size: 13, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(currentFileDisplay)
            }

            // Counts row. The captioned/skipped/failed counts come from
            // the orchestrator's live publishers — updated at each file
            // boundary, so the row reflects work-in-progress, not just
            // the end-state.
            HStack(spacing: 12) {
                Text("\(orchestrator.liveCurrentIndex) of \(orchestrator.liveTotal)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.primary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("captioned \(orchestrator.liveCaptioned)")
                    .foregroundStyle(.green)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("skipped \(orchestrator.liveSkipped)")
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("failed \(orchestrator.liveFailed)")
                    .foregroundStyle(orchestrator.liveFailed > 0 ? .red : .secondary)
            }
            .font(.system(size: 13))

            // ETA row. Subtle — secondary color, smaller font. We only
            // promise an estimate; the first file's load dominates and
            // throws the early-batch estimate way off.
            if !etaDisplay.isEmpty {
                Text(etaDisplay)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer().frame(height: 4)

            // Action row. Cancel only; the sheet auto-closes when the
            // batch finishes via the .onChange handler below.
            HStack {
                Spacer()
                Button(role: .cancel) {
                    orchestrator.cancel()
                } label: {
                    Text(cancelLabel).frame(minWidth: 110)
                }
                .keyboardShortcut(.cancelAction)
                .disabled(cancelDisabled)
            }
        }
        .padding(20)
        .frame(width: 520)
        // Auto-dismiss when the orchestrator reaches a terminal state.
        // The user doesn't have to click anything — once the batch is
        // done, the sheet just goes away.
        //
        // Swift's onChange(of:) on iOS 17 / macOS 14+ uses the 2-arg
        // closure (oldValue, newValue). We only care about the new.
        .onChange(of: statusKey) { _, _ in
            if case .finished = orchestrator.currentStatus {
                // Tiny delay so the user can see the final counts
                // settle. 600ms feels right; matches the dwell in the
                // existing CombineSheet's "done" pulse.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    isPresented = false
                }
            }
        }
    }

    /// Stable key for the .onChange watcher. CaptionJobStatus is
    /// Equatable but Swift's @ViewBuilder onChange needs a Hashable
    /// or Equatable plain value — we use an Int discriminator.
    private var statusKey: Int {
        switch orchestrator.currentStatus {
        case .idle: return 0
        case .running: return 1
        case .cancelling: return 2
        case .finished: return 3
        }
    }

    /// Formats an ETA in seconds to "Xm Ys" or "Xs". Tight format to
    /// fit the progress row; the existing Formatting.swift helpers
    /// emit longer "X minutes" strings that overflow.
    private func formatETA(_ sec: Int) -> String {
        if sec >= 60 {
            let m = sec / 60
            let s = sec % 60
            return s > 0 ? "\(m)m \(s)s" : "\(m)m"
        }
        return "\(sec)s"
    }
}
