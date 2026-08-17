import SwiftUI

// MARK: - RelocateJobsPanel
//
// "Relocate Jobs" panel — the user-facing surface for the §3 queue.
// Surfaces every queued/running/done/failed job with enough context
// (status pill, progress bar, elapsed time) that Rick can walk away,
// come back hours later, and see exactly which volumes are still
// pending vs already migrated.
//
// Reachable from the Volumes window toolbar's "Relocate Jobs" button
// (badged with queue depth). Kept as a `.sheet` rather than its own
// `Window` scene — the panel is review-only, and SwiftUI's
// `.sheet(isPresented:)` plumbing is the lightest touch.
//
// See docs/relocate_volume_plan.md §3.

struct RelocateJobsPanel: View {

    @EnvironmentObject var model: VideoScanModel
    @Environment(\.dismiss) var dismiss

    /// Backing for the "Show summary" context-menu action. When set,
    /// the existing `RelocateSummarySheet` is re-rendered against the
    /// job's archived summary (read-only — clicking Done just dismisses).
    @State private var summaryToShow: RelocateSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headline
            Divider()
            jobsList
            Divider()
            footerBar
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 720, minHeight: 420, idealHeight: 520)
        .accessibilityIdentifier("relocateJobsPanel.root")
        // Show-summary sheet — opened from row context menu. Carries
        // the archived RelocateSummary so the same family-friendly
        // view renders for a complete-state job. Done button just
        // dismisses (the queue advance already happened for this job).
        .sheet(item: $summaryToShow) { summary in
            RelocateSummarySheet(summary: summary)
                .environmentObject(model)
        }
    }

    // MARK: - Sections

    /// Friendly headline: "Queued N · Running M · Done K · Failed F".
    /// Mirrors the spec wording exactly — same string the panel header
    /// and a future user notification body could share.
    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "tray.full")
                .foregroundColor(.accentColor)
            Text("Migrate Jobs")
                .font(.headline)
            Text("Queued \(model.queuedCount) · Running \(model.runningCount) "
                 + "· Done \(model.completedCount) · Failed \(model.failedCount)")
                .font(.callout)
                .foregroundColor(.secondary)
                .accessibilityIdentifier("relocateJobsPanel.summary")
            Spacer()
        }
    }

    @ViewBuilder
    private var jobsList: some View {
        if sortedJobs.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(sortedJobs) { job in
                        jobRow(job)
                            .contextMenu { contextMenu(for: job) }
                            .accessibilityIdentifier("relocateJobsPanel.row.\(job.id.uuidString)")
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("No migrate jobs yet.")
                .foregroundColor(.secondary)
            Text("Use the Migrate Volume sheet to queue one.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("relocateJobsPanel.empty")
    }

    private func jobRow(_ job: RelocateQueuedJob) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statusPill(for: job)
                Text(job.sourceVolumeName)
                    .font(.body.weight(.medium))
                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Text(job.destinationRoot.path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.secondary)
                Spacer()
                trailingMetric(for: job)
                // Visible Cancel for anything not finished (Rick 2026-08-17:
                // "doesn't seem like it allows for cancelling" — it was only
                // in the right-click menu). Cancel is clean: everything
                // copied so far is verified + committed; a rerun adopts it.
                switch job.status {
                case .queued, .reconciling, .copying:
                    Button("Cancel") { _ = model.cancelRelocateJob(id: job.id) }
                        .controlSize(.small)
                        .help(job.status == .queued
                              ? "Remove this job from the queue."
                              : "Stop after the current file. Files already copied stay verified on the destination; rerunning the same Migrate adopts them.")
                        .accessibilityIdentifier("relocateJobsPanel.row.cancel")
                default:
                    EmptyView()
                }
            }
            if job.status == .copying, let p = job.copyProgress, p.total > 0 {
                progressBlock(p)
            }
            if job.status == .reconciling {
                reconcilingBlock
            }
            if case .failed(let reason) = job.status {
                Text(reason)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
                    .accessibilityIdentifier("relocateJobsPanel.row.failedReason")
            }
        }
        .padding(8)
        .background(rowBackground(for: job))
        .cornerRadius(6)
    }

    /// Per-status colored pill. Three semantic colors (queued/running/
    /// done/failed) plus secondary-grey for canceled.
    private func statusPill(for job: RelocateQueuedJob) -> some View {
        Text(job.statusLabel)
            .font(.caption.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(pillColor(for: job))
            .cornerRadius(4)
            .accessibilityIdentifier("relocateJobsPanel.row.pill")
    }

    private func pillColor(for job: RelocateQueuedJob) -> Color {
        switch job.status {
        case .queued:                    return .gray
        case .reconciling, .copying:     return .accentColor
        case .awaitingDone:              return .orange
        case .complete:                  return .green
        case .failed:                    return .red
        case .canceled:                  return .secondary
        }
    }

    private func rowBackground(for job: RelocateQueuedJob) -> Color {
        if job.isInFlight { return Color.accentColor.opacity(0.06) }
        if case .failed = job.status { return Color.red.opacity(0.05) }
        return Color.gray.opacity(0.04)
    }

    private func progressBlock(_ p: RelocateQueuedJob.CopyProgress) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(
                value: Double(p.done),
                total: max(Double(p.total), 1)
            )
            .progressViewStyle(.linear)
            HStack {
                Text("[\(p.done) / \(p.total)] \(Int(Double(p.done) / Double(max(p.total, 1)) * 100))%")
                    .font(.system(.caption2, design: .monospaced))
                Text(p.currentFile)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(byteString(p.bytesCopied))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Reconcile-phase indicator. Determinate since 2026-07-06: the
    /// classify loop publishes (done, total) through
    /// `model.reconcileProgress`, so the user sees "Comparing 12,500 /
    /// 49,000" instead of guessing whether a minutes-long pass is alive.
    /// Falls back to indeterminate during the enumeration phase (before
    /// the classify loop starts) — still honest: "actively working".
    private var reconcilingBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let p = model.reconcileProgress, p.total > 0 {
                ProgressView(value: Double(p.done), total: Double(p.total))
                    .progressViewStyle(.linear)
                Text("Comparing \(p.done) / \(p.total) files…")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                Text("Enumerating volumes…")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .accessibilityIdentifier("relocateJobsPanel.row.reconciling")
    }

    /// Right-aligned info: elapsed time for complete/failed jobs,
    /// "—" for queued, live tick for in-flight.
    @ViewBuilder
    private func trailingMetric(for job: RelocateQueuedJob) -> some View {
        if let elapsed = job.elapsedSeconds {
            Text(elapsedString(elapsed))
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
        } else if job.status == .queued {
            Text("—")
                .font(.caption)
                .foregroundColor(.secondary)
        } else if let started = job.startedAt {
            // Live elapsed for in-flight jobs. Cheap — only updates
            // when SwiftUI re-renders the row, which already happens
            // on each progress tick.
            Text(elapsedString(Date().timeIntervalSince(started)))
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
    }

    private var footerBar: some View {
        HStack {
            Button("Clear completed") {
                model.clearCompletedJobs()
            }
            .disabled(model.relocateQueue.allSatisfy { !$0.isTerminal })
            .accessibilityIdentifier("relocateJobsPanel.clearCompleted")

            Spacer()

            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("relocateJobsPanel.close")
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for job: RelocateQueuedJob) -> some View {
        switch job.status {
        case .queued:
            Button("Cancel") { _ = model.cancelRelocateJob(id: job.id) }
        case .reconciling, .copying:
            Button("Cancel", role: .destructive) { _ = model.cancelRelocateJob(id: job.id) }
        case .complete:
            if job.summary != nil {
                Button("Show summary") { summaryToShow = job.summary }
            }
        case .failed:
            if job.summary != nil {
                Button("Show details") { summaryToShow = job.summary }
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Helpers

    /// Stable ordering for the list — queued jobs at top in enqueue
    /// order, in-flight next, terminal jobs at bottom (most recently
    /// completed first). Mirrors how a worker queue feels in the UI.
    private var sortedJobs: [RelocateQueuedJob] {
        model.relocateQueue.sorted { a, b in
            // Bucket index: in-flight (0), queued (1), terminal (2).
            let ai = bucket(a)
            let bi = bucket(b)
            if ai != bi { return ai < bi }
            // Within bucket, sort by enqueuedAt — oldest first for
            // queued/in-flight (FIFO), newest first for terminal
            // (most recent completion at top).
            if ai == 2 {
                let aDone = a.completedAt ?? a.enqueuedAt
                let bDone = b.completedAt ?? b.enqueuedAt
                return aDone > bDone
            }
            return a.enqueuedAt < b.enqueuedAt
        }
    }

    private func bucket(_ job: RelocateQueuedJob) -> Int {
        if job.isInFlight { return 0 }
        if job.status == .queued { return 1 }
        return 2
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func elapsedString(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        let m = Int(seconds / 60)
        let s = Int(seconds.truncatingRemainder(dividingBy: 60))
        return "\(m)m \(s)s"
    }
}
