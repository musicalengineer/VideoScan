// CatalogStatusBand.swift
// The summary band at the top of the Analyze panel (Rick 2026-10-16,
// docs/design/catalog_status_freshness_2026_10_16.md §2.1): one colour,
// one headline, one line per non-green item with its ONE button —
// yellow → Run now; red → the door a person needs (Fix Links…, which is
// not built yet and says so; Fingerprint again; Run again) — and "Update
// everything stale", which queues the yellow kinds through the existing
// scheduler, integrity rows first (CatalogStatusUpdateQueue).
//
// PROGRESS LIVES IN MFO; THE BAND MIRRORS IT. While an integrity kind's
// job runs, its line becomes a mirror of the MFO row's collapsed line:
// the job's own `subtitle` (what it is doing · N of M · time left — the
// words CatalogAuditTotals / FullHashBackfillTotals.progressLine already
// compose for the MFO row), a thin ProgressView on `fraction`, the row
// clock, and the SAME Pause / Resume / Stop calls (`job.pause()`,
// `job.resume()`, `job.cancel()`). CatalogStatusRunningLine observes the
// very job object MediaFileOperationRow observes (its `objectWillChange`
// heartbeat) — one job, one state, two views; no second progress
// implementation. "See details" opens the MFO window with that row
// expanded (MediaFileOperationsCenter.revealJobID).
//
// OBSERVATION: the band is handed a VALUE (CatalogFreshnessState) by the
// panel, which observes the model's CatalogFreshnessSnapshot; the queue is
// observed for its "queued" words; a running job is observed by its line
// only. NO O(records) work here (CatalogStatusSensorTests pins it).
//
// (For Rick: `FreshnessReason` is a tagged union; `CatalogStatusDoor.for`
// is the `switch` that turns it into a button — kept pure so it is a
// table test, not a UI test.)

import Combine
import SwiftUI
import VideoScanCore

// MARK: - Colours (view layer only; the policy stays colour-token-free)

extension FreshnessColour {
    var tint: Color {
        switch self {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        case .grey: return .secondary
        }
    }
}

// MARK: - The one button per item (pure)

/// What the ONE button on a band item is, from the row's reason.
enum CatalogStatusDoor: Equatable {
    /// Yellow — the run is the answer.
    case runNow
    /// Red, the last pass failed or was killed.
    case runAgain
    /// Red, the sound sidecar cannot be opened: a fresh run re-creates it.
    case fingerprintAgain
    /// Red, File Presence found rows pointing at nothing: Fix Links (§2b)
    /// is not built yet — the button is shown DISABLED and says so.
    case fixLinks
    /// Grey — not asked; nothing to press.
    case none

    var title: String {
        switch self {
        case .runNow: return "Run now"
        case .runAgain: return "Run again"
        case .fingerprintAgain: return "Fingerprint again"
        case .fixLinks: return "Fix Links…"
        case .none: return ""
        }
    }

    /// False only for the door that is not built yet.
    var isEnabled: Bool { self != .fixLinks }

    static let fixLinksHelp = "Fix Links is coming next: a review sheet for rows whose file is gone or changed, with relink / forget per row. Until then the Audit Catalog detail (Media File Operations) lists them."

    static func door(for reason: FreshnessReason, cycler: AnalyzeCycler) -> CatalogStatusDoor {
        switch reason {
        case .storeUnavailable:
            return .fingerprintAgain
        case .lastRunFailed:
            return .runAgain
        case .needsDecision:
            return cycler == .filePresence ? .fixLinks : .runNow
        case .uncovered, .neverRan, .lastRunPartial, .overdue:
            return .runNow
        case .notMounted, .nothingToCheck, .current:
            return .none
        }
    }
}

// MARK: - The band

struct CatalogStatusBand: View {

    let state: CatalogFreshnessState
    @ObservedObject var queue: CatalogStatusUpdateQueue
    /// The active MFO job behind an integrity kind (nil when none).
    let runningJob: (AnalyzeCycler) -> (any MediaFileOperationJob)?
    let onRunNow: (AnalyzeCycler) -> Void
    let onUpdateAll: () -> Void
    let onSeeDetails: (any MediaFileOperationJob) -> Void

    private var summary: FreshnessSummary { state.summary }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(summary.colour.tint)
                    .frame(width: 12, height: 12)
                    .offset(y: 1)
                Text(state.isComputed ? summary.headline : "Checking what the catalog knows…")
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityIdentifier("catalog.status.band.headline")
                Spacer()
                if !state.staleCyclers.isEmpty {
                    Button(queue.isActive ? "Updating… (\(queue.pending.count) in line)" : "Update everything stale") {
                        onUpdateAll()
                    }
                    .disabled(queue.isActive)
                    .help("Start every yellow item in turn — integrity checks first, one at a time, through the same jobs the rows use.")
                    .accessibilityIdentifier("catalog.status.band.updateAll")
                }
            }
            ForEach(summary.items, id: \.kind) { item in
                if let cycler = AnalyzeCycler(rawValue: item.kind) {
                    itemRow(item, cycler: cycler)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 10).fill(summary.colour.tint.opacity(summary.colour == .grey ? 0.06 : 0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(summary.colour.tint.opacity(0.35), lineWidth: 1))
        .accessibilityIdentifier("catalog.status.band")
    }

    @ViewBuilder
    private func itemRow(_ item: FreshnessSummary.Item, cycler: AnalyzeCycler) -> some View {
        let reason = state.verdict(cycler)?.reason
        let door = reason.map { CatalogStatusDoor.door(for: $0, cycler: cycler) } ?? .none
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(item.colour.tint).frame(width: 8, height: 8).offset(y: 1)
                Text(item.title).font(.system(size: 13, weight: .semibold))
                Text(item.words)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityIdentifier("catalog.status.band.item.\(cycler.rawValue)")
                Spacer()
                trailing(cycler: cycler, door: door)
            }
            if let job = runningJob(cycler) {
                CatalogStatusRunningLine(job: job, onSeeDetails: { onSeeDetails(job) })
                    .padding(.leading, 16)
            }
        }
    }

    @ViewBuilder
    private func trailing(cycler: AnalyzeCycler, door: CatalogStatusDoor) -> some View {
        if queue.current == cycler || queue.pending.contains(cycler) {
            Text(queue.current == cycler ? "updating…" : "in line")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        } else if state.isRunning(cycler) {
            // The mirror below carries the controls; an integrity job
            // with no MFO row (should not happen) just says so.
            if runningJob(cycler) == nil {
                Text("running").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } else if door != .none {
            Button(door.title) { onRunNow(cycler) }
                .controlSize(.small)
                .disabled(!door.isEnabled)
                .help(door == .fixLinks ? CatalogStatusDoor.fixLinksHelp : "Start \(cycler.title) now.")
                .accessibilityIdentifier("catalog.status.band.door.\(cycler.rawValue)")
        }
    }
}

// MARK: - The MFO mirror

/// One running integrity job, as the MFO row shows it: subtitle · thin
/// bar · clock · Pause/Resume · Stop · See details. Observes the job's
/// own change signal, exactly as MediaFileOperationRow does.
struct CatalogStatusRunningLine: View {
    let job: any MediaFileOperationJob
    let onSeeDetails: () -> Void

    /// Re-render driver (the job is an existential; see MediaFileOperationRow).
    @State private var heartbeat = false
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    var body: some View {
        let _ = heartbeat
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(job.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("catalog.status.band.mirror.subtitle")
                Spacer()
                Text(MediaFileOperationClock.text(for: job, at: now))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                if job.canPause {
                    Button(job.isPaused ? "Resume" : "Pause") {
                        if job.isPaused { job.resume() } else { job.pause() }
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("catalog.status.band.mirror.pause")
                }
                Button(job.state == .cancelling ? job.state.badge.label : "Stop") { job.cancel() }
                    .controlSize(.small)
                    .disabled(job.state == .cancelling)
                    .accessibilityIdentifier("catalog.status.band.mirror.stop")
                Button("See details", action: onSeeDetails)
                    .controlSize(.small)
                    .help("Open Media File Operations at this row — the per-file outcomes and running totals.")
                    .accessibilityIdentifier("catalog.status.band.mirror.details")
            }
            ProgressView(value: job.isPaused ? job.fraction : (job.isIndeterminate ? nil : job.fraction))
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(job.state == .cancelling ? .orange : (job.isPaused ? .gray : .blue))
        }
        .onReceive(job.objectWillChange) { _ in heartbeat.toggle() }
        .onReceive(clock) { now = $0 }
    }
}
