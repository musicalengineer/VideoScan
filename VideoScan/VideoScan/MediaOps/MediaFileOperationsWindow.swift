import Combine
import AppKit
import SwiftUI

// MARK: - Media File Operations window
//
// ONE non-modal window for every file-by-file operation — combine,
// compare, extract-frames, and future verbs. Evolved from
// the old "Combine & Render" window (same scene id "combine", same
// ⌘⇧R shortcut) rather than built fresh, because the combine queue
// already had the multi-job + pause/resume machinery.
//
// Phase-1 layout: two sections in one list.
//   - "Checks & Tools"  — new-style `MediaFileOperationJob` rows from
//     `MediaFileOperationsCenter` (compare since phase 1, extract
//     since phase 2).
//   - "Combining"       — the existing combine rows, rendered by their
//     original views (`CombineJobsSection`), behavior untouched.
// Visual unity first; type unity (combine conforming to the job
// protocol) is deferred.

/// Opens (or reveals) the Media File Operations window BEHIND the window
/// the user is working in (2026-09-02). Every job start used to call
/// `openWindow(id: "combine")` directly, and SwiftUI brings a newly opened
/// window to the front — so clicking Promote in the archive sheet, or
/// "Verify copies…", buried the main window (and any sheet on it) under the
/// job list. The window is still created and still updates; it just lands
/// one level down, where it is found rather than fought.
///
/// The anchor is the main window when there is one, else whatever window
/// was key BEFORE the open (captured first — the open makes the job window
/// key). SwiftUI creates the window asynchronously, so the reorder is
/// retried on two later run-loop turns; if it never appears, nothing
/// happens (no throw, no log spam).
@MainActor
enum MediaFileOperationsWindowOpener {
    static let sceneID = "combine"   // legacy "Combine & Render" scene id
    static let title = "Media File Operations"

    /// Pure predicate, so the window-identity rule is table-testable.
    nonisolated static func isJobWindow(identifier: String?, title: String) -> Bool {
        if let identifier, identifier.hasPrefix(sceneID) { return true }
        return title == Self.title
    }

    /// What one retry does. Pure, so the focus rules are table-testable
    /// (codex #964): never touch windows while an app-modal alert runs
    /// (the retry would fight NSAlert.runModal); restore key only when the
    /// open actually stole it, so a retry that finds the user already back
    /// in the main window does nothing; skip entirely with no usable anchor.
    enum Step: Equatable { case skip, reorder, reorderAndRestoreKey }

    nonisolated static func step(jobIsKey: Bool, modalRunning: Bool, anchorVisible: Bool) -> Step {
        if modalRunning || !anchorVisible { return .skip }
        return jobIsKey ? .reorderAndRestoreKey : .reorder
    }

    /// One open's retries share a ledger: the FIRST retry that acts retires
    /// the rest (codex #969 — after the 0.15 s retry had restored the main
    /// window, a user who then clicked the job window on purpose had focus
    /// stolen back by the stale 0.5 s retry). Pure, table-tested.
    struct RetryLedger: Equatable {
        private(set) var settled = false
        mutating func apply(_ step: Step) -> Step {
            if settled { return .skip }
            if step != .skip { settled = true }
            return step
        }
    }

    /// A newer open supersedes any older open's pending retries.
    private static var generation = 0

    /// Set by AppKitMediaFileOperationsWindowPresenter when a user-started
    /// job has just brought the window forward (Rick 2026-09-21). Inside
    /// that moment `openBehindMain` stands down, so the call site's legacy
    /// "open behind" does not bury the window the forwarder just raised.
    /// With the setting off nothing sets this and the behavior is unchanged.
    static var forwardedAt: Date?

    /// Pure, so the stand-down rule is table-testable.
    nonisolated static func defersToForward(forwardedAt: Date?, now: Date) -> Bool {
        guard let forwardedAt else { return false }
        let age = now.timeIntervalSince(forwardedAt)
        return age >= 0 && age < MediaFileOperationsWindowForwarder.debounceSeconds
    }

    /// The job window is the RESULT the user asked for (an Angel batch,
    /// Compare) — open it in front like any other window.
    static func openInFront(_ openWindow: OpenWindowAction) {
        openWindow(id: sceneID)
    }

    /// A job was started as a side effect; the window the user is working
    /// in stays on top. The anchor is captured BEFORE the open (the open
    /// makes the job window key); SwiftUI creates the window
    /// asynchronously, so the reorder is retried on later run-loop turns.
    /// If the captured anchor has since closed, the current main window
    /// stands in.
    static func openBehindMain(_ openWindow: OpenWindowAction) {
        if defersToForward(forwardedAt: forwardedAt, now: Date()) { return }
        let captured = MainWindowHelper.shared.findMainWindow() ?? NSApp.keyWindow
        generation += 1
        let mine = generation
        let ledger = RetryLedgerBox()
        openWindow(id: sceneID)
        for delay in [0.0, 0.15, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard mine == generation else { return }   // a newer open owns the window now
                // A user-started job raised the window AFTER this open was
                // scheduled: a late retry must not bury it (2026-09-22 fix —
                // the forwarder re-asserts for ~1 s, well inside this window).
                if defersToForward(forwardedAt: forwardedAt, now: Date()) { return }
                sendBehind(captured, ledger: ledger)
            }
        }
    }

    /// Reference holder so the three retries of ONE open share a ledger.
    private final class RetryLedgerBox { var ledger = RetryLedger() }

    private static func sendBehind(_ captured: NSWindow?, ledger: RetryLedgerBox) {
        guard let job = NSApp.windows.first(where: {
            isJobWindow(identifier: $0.identifier?.rawValue, title: $0.title)
        }) else { return }
        // A hidden captured main window must not stand in for itself:
        // only a VISIBLE anchor is worth ordering against (codex #969).
        let fallback = MainWindowHelper.shared.findMainWindow().flatMap { $0.isVisible ? $0 : nil }
        let anchor = (captured?.isVisible == true ? captured : nil) ?? fallback
        guard let anchor, anchor !== job else { return }
        let planned = step(jobIsKey: NSApp.keyWindow === job,
                           modalRunning: NSApp.modalWindow != nil,
                           anchorVisible: anchor.isVisible)
        switch ledger.ledger.apply(planned) {
        case .skip:
            return
        case .reorder:
            job.order(.below, relativeTo: anchor.windowNumber)
        case .reorderAndRestoreKey:
            job.order(.below, relativeTo: anchor.windowNumber)
            anchor.makeKeyAndOrderFront(nil)
        }
    }
}

struct MediaFileOperationsWindow: View {
    @EnvironmentObject var model: VideoScanModel
    @EnvironmentObject var dashboard: DashboardState
    @EnvironmentObject var center: MediaFileOperationsCenter

    /// Compare rows the user expanded for the verdict + metadata diff.
    @State private var expandedJobIDs: Set<UUID> = []

    private var combineSectionVisible: Bool {
        !dashboard.combineJobs.isEmpty || model.isCombining
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if let pending = model.pendingDeleteDuplicatesResume {
                DeleteDuplicatesResumeBanner(plan: pending,
                                             onResume: { _ = center.startedByUser { $0.resumeDeleteDuplicates(plan: pending, model: model) } },
                                             onPutBack: { model.putBackStrandedDuplicates() },
                                             onDiscard: { model.discardPendingDeleteDuplicatesPlan() })
                Divider()
            }
            if center.jobs.isEmpty && !combineSectionVisible {
                emptyState
            } else {
                jobList
            }
            Divider()
            footerBar
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 340, idealHeight: 560)
        .onAppear {
            DispatchQueue.main.async {
                for window in NSApp.windows where window.title.contains("Media File Operations") {
                    // A NORMAL-level window since 2026-09-02. It floated
                    // (2026-04-26, as the Combine progress palette) and a
                    // floating window sits above every normal window no
                    // matter how they are ordered — which is exactly the
                    // "job list covers the Promote sheet" complaint. It is
                    // now ordered behind the window a job was started from
                    // (MediaFileOperationsWindowOpener) and comes forward
                    // when clicked, like any other window.
                    window.level = .normal
                    window.isMovableByWindowBackground = true
                }
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Image(systemName: "film.stack")
                .foregroundColor(.blue)
            Text("Media File Operations")
                .font(.headline)

            Spacer()

            if center.activeCount > 0 {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(center.activeCount == 1
                         ? "1 operation running"
                         : "\(center.activeCount) operations running")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            // Bulk controls for many-jobs-in-flight (Rick 2026-07-31).
            // Pause All flips to Resume All once nothing unpaused
            // remains; Cancel All also stops a running Combine batch,
            // which runs through its own pipeline.
            // Liquid Glass spots 2026-10-06: the bulk controls are one
            // glass group, so neighbouring buttons blend as they come and go.
            VSGlassContainer(spacing: 8) {
                HStack(spacing: 8) {
                    bulkControls
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var bulkControls: some View {
        if center.hasPausableRunning {
            Button("Pause All") {
                center.pauseAll()
            }
            .vsGlassButtonStyle()
        } else if center.hasPausedJobs {
            Button("Resume All") {
                center.resumeAll()
            }
            .vsGlassButtonStyle()
        }

        if center.activeCount > 0 || model.isCombining {
            Button("Cancel All", role: .destructive) {
                center.cancelAll()
                if model.isCombining { model.stopCombine() }
            }
            .vsGlassButtonStyle()
        }

        if center.jobs.contains(where: { !$0.state.isActive }) {
            Button("Clear Finished") {
                center.clearFinished()
            }
            .vsGlassButtonStyle()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "film.stack")
                .font(.system(size: 36))
                .foregroundColor(.secondary.opacity(0.4))
            Text("No file operations running")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("Combine pairs, compare two files, or extract frames from the Catalog tab — progress shows up here.")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Job List

    /// Identifiable wrapper so ForEach can key heterogeneous
    /// `any MediaFileOperationJob` existentials (key paths can't be
    /// rooted on the existential directly).
    private struct OperationRowItem: Identifiable {
        let job: any MediaFileOperationJob
        var id: UUID { job.id }
    }

    private var jobList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                if !center.jobs.isEmpty {
                    sectionHeader("Checks & Tools")
                    ForEach(center.jobs.map { OperationRowItem(job: $0) }) { item in
                        MediaFileOperationRow(
                            job: item.job,
                            isExpanded: expandedJobIDs.contains(item.id),
                            onToggleExpand: { toggleExpanded(item.id) }
                        )
                    }
                }
                if combineSectionVisible {
                    CombineJobsSection()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func toggleExpanded(_ id: UUID) {
        if expandedJobIDs.contains(id) {
            expandedJobIDs.remove(id)
        } else {
            expandedJobIDs.insert(id)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    // MARK: - Footer (combine queue controls — behavior unchanged)

    private var footerBar: some View {
        HStack {
            if dashboard.combineSucceeded > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 13))
                    Text("\(dashboard.combineSucceeded) verified")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.green)
                }
            }
            if dashboard.combineSkipped > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.right.circle")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                    Text("\(dashboard.combineSkipped) already combined")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            if dashboard.combineFailed > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 13))
                    Text("\(dashboard.combineFailed) failed")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.red)
                }
            }

            Spacer()

            if model.isCombining {
                VSGlassContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Button(model.isCombinePaused ? "Resume All" : "Pause All") {
                            if model.isCombinePaused {
                                model.resumeCombine()
                            } else {
                                model.pauseCombine()
                            }
                        }
                        .vsGlassButtonStyle()
                        Button("Stop All") { model.stopCombine() }
                            .foregroundColor(.red)
                            .vsGlassButtonStyle()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Resume offer (Delete Duplicates, 2026-09-20)

/// "Resume deleting duplicates on SanDisk — 1,203 of 2,992 remaining?"
/// with Resume / Discard — and "N files waiting to be put back" with
/// Put Back when a run left files in quarantine (codex 1606 #3). Shown
/// while the model holds an offerable plan; NEVER acts on its own.
struct DeleteDuplicatesResumeBanner: View {
    let plan: DeleteDuplicatesPlan
    let onResume: () -> Void
    var onPutBack: () -> Void = {}
    let onDiscard: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundColor(.red)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.resumeOffer)
                    .font(.system(size: 13, weight: .semibold))
                Text(plan.isResumable
                     ? "Every remaining file is re-checked against the catalog and its keeper before anything is read or removed."
                     : "Put Back moves the file to where it lived — nothing is verified or deleted.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Discard", role: .destructive, action: onDiscard)
                .controlSize(.small)
                .accessibilityIdentifier("mfo.deleteDuplicates.discard")
            if plan.needsRecovery {
                Button("Put Back", action: onPutBack)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("mfo.deleteDuplicates.putBack")
            }
            if plan.isResumable {
                Button("Resume", action: onResume)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("mfo.deleteDuplicates.resume")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
        .accessibilityIdentifier("mfo.deleteDuplicates.resumeBanner")
    }
}

// MARK: - Generic operation row

/// One new-style job row: verb badge, file names, live subtitle, thin
/// progress bar, Cancel / Pause, relative start time — plus an
/// expandable detail area (compare jobs show the verdict banner and
/// the side-by-side metadata diff).
/// A job's double-click detail — the ONE place that maps a job to its
/// detail view (2026-10-07; this chain used to sit inline in the row's
/// body, growing it by a branch per verb). `hasDetailView` stays the
/// exhaustive list of which kinds expand; a kind marked true with no
/// branch here simply shows nothing. (`if let x = job as? T` ≈ C++
/// `dynamic_cast` to each concrete job type in turn.)
struct MediaFileOperationDetail: View {
    let job: any MediaFileOperationJob

    var body: some View {
        if let compare = job as? PairCompareJob {
            PairCompareDetailView(job: compare)
        } else if let find = job as? FindPersonJob {
            FindPersonDetailView(job: find)
        } else if let verify = job as? VerifyArchiveCopiesJob {
            VerifyArchiveDetailView(job: verify)
        } else if let angel = ArchiveAngelJobDetailView(job: job) {
            angel
        } else if let deletion = job as? DeleteDuplicatesJob {
            DeleteDuplicatesDetailView(job: deletion)
        } else if let verifyVideo = job as? VerifyVideoJob {
            VerifyVideoDetailView(job: verifyVideo)
        } else if let check = job as? CheckMediaJob {
            CheckMediaDetailView(job: check)
        } else if let repair = job as? MediaRepairJob {
            MediaRepairDetailView(job: repair)
        } else if let lock = job as? ArchiveLockJob {
            ArchiveLockDetailView(job: lock)
        } else if let spectrum = job as? FootageSpectrumJob {
            FootageSpectrumDetailView(job: spectrum)
        } else if let fingerprints = job as? PerceptualFingerprintBackfillJob {
            PerceptualFingerprintBackfillDetailView(job: fingerprints)
        } else if let prune = job as? PruneApplyJob {
            PruneApplyDetailView(job: prune)
        }
    }
}

struct MediaFileOperationRow: View {
    let job: any MediaFileOperationJob
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    /// For "Show in Catalog" on completed Reformat rows — same
    /// pendingCatalogSelection mechanism the dashboard uses. Rick
    /// 2026-06-14.
    @EnvironmentObject var model: VideoScanModel
    @Environment(\.openWindow) private var openWindow

    /// Re-render driver: the job is an existential, so @ObservedObject
    /// can't watch it directly. We subscribe to its objectWillChange
    /// and flip this bit, which invalidates the view.
    @State private var heartbeat = false

    /// punch-list #5: non-nil drives a brief alert when "Show in Catalog"
    /// is clicked for a record that's no longer in the catalog (stale id
    /// after live-reload identity churn). Mirrors the findOnlineNotice
    /// pattern in CatalogHelpers.
    @State private var showInCatalogNotice: String?
    /// The Stop button's confirm for a Delete Duplicates row (keep vs
    /// discard the remaining work).
    @State private var confirmStopDeleteDuplicates = false

    var body: some View {
        // Referencing `heartbeat` ties this view's identity to the
        // toggle below — that's what makes onReceive re-render us.
        let _ = heartbeat

        VStack(spacing: 0) {
            // Summary area — badge/title/status plus the progress bar.
            // ONLY this area toggles expansion (Bug A, Rick 2026-08-20:
            // the tap gesture used to sit on the whole row INCLUDING the
            // expanded detail panel, so clicking any non-control content
            // inside the panel — a role chip, a file row — collapsed it).
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    MediaFileOperationBadge(
                        kind: job.kind,
                        textOverride: (job as? AnalyzeJob)?.displayBadge
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(job.title)
                            .font(.system(size: 13, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            // Gauntlet flow 4 matches the balanced file's row
                            // by this title text. Test-only.
                            .accessibilityIdentifier("mfo.row.title")
                        Text(job.subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .accessibilityIdentifier("mfo.row.subtitle")
                    }

                    Spacer()

                    trailingStatus
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                if job.state == .running || job.state == .cancelling {
                    // A paused verb must LOOK paused (Rick 2026-08-04): a
                    // suspended child emits no progress, so the bar freezes
                    // at its last fraction — never the indeterminate bounce,
                    // which reads as work happening — and dims to gray.
                    ProgressView(value: job.isPaused
                        ? job.fraction
                        : (job.isIndeterminate ? nil : job.fraction))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .tint(job.state == .cancelling ? .orange
                              : (job.isPaused ? .gray : .blue))
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // Rows with a detail view expand on a summary click
                // (compare's pattern, extended to Find & Tag — Rick
                // 2026-08-04). Clicks INSIDE the expanded detail below
                // must never reach here (Bug A).
                if job.kind.hasDetailView { onToggleExpand() }
            }

            // The double-click detail (MediaFileOperationDetail below —
            // one place that maps a job to its detail view, 2026-10-07).
            if isExpanded {
                MediaFileOperationDetail(job: job)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .background(rowBackground)
        .onReceive(job.objectWillChange) { _ in
            heartbeat.toggle()
        }
        .alert(
            "Show in Catalog",
            isPresented: Binding(
                get: { showInCatalogNotice != nil },
                set: { if !$0 { showInCatalogNotice = nil } }
            ),
            presenting: showInCatalogNotice
        ) { _ in
            Button("OK", role: .cancel) { showInCatalogNotice = nil }
        } message: { msg in
            Text(msg)
        }
    }

    @ViewBuilder
    private var trailingStatus: some View {
        HStack(spacing: 8) {
            switch job.state {
            case .running, .cancelling:
                if job.canPause {
                    Button(job.isPaused ? "Resume" : "Pause") {
                        if job.isPaused {
                            job.resume()
                        } else {
                            job.pause()
                        }
                    }
                    .font(.system(size: 11))
                    .vsGlassButtonStyle()
                }
                // One verb, one meaning (Rick 2026-08-07: hunted for
                // "Stop" and found only Pause — the button said "Cancel"
                // then flipped to "Stopping…", two dialects for one act).
                // In flight the button reads the state's own badge label
                // ("Cancelling…") so button, row and log agree on one word.
                Button(job.state == .cancelling ? job.state.badge.label : "Stop") {
                    // Delete Duplicates keeps the rest for later by
                    // default (Rick 2026-09-20 evening); discarding it
                    // is the explicit, destructive choice.
                    if job is DeleteDuplicatesJob {
                        confirmStopDeleteDuplicates = true
                    } else {
                        job.cancel()
                    }
                }
                .font(.system(size: 11))
                // Liquid Glass spots 2026-10-06: a running row's Pause /
                // Stop are glass controls; the row itself stays solid.
                .vsGlassButtonStyle()
                .disabled(job.state == .cancelling)
                .confirmationDialog("Stop deleting duplicates?",
                                    isPresented: $confirmStopDeleteDuplicates, titleVisibility: .visible) {
                    Button("Stop, keep the rest for later") { job.cancel() }
                    Button("Stop and discard the rest", role: .destructive) {
                        (job as? DeleteDuplicatesJob)?.cancel(discardingRemaining: true)
                    }
                    Button("Keep going", role: .cancel) {}
                } message: {
                    Text("The file being checked is put back either way. “Keep the rest for later” leaves the run resumable — it is offered again right away and at the next launch. “Discard” files it as cancelled; what is left stays on disk untouched.")
                }
            case .finished(let summary):
                if let compare = job as? PairCompareJob,
                   let verdict = compare.comparator.verdict {
                    PairCompareVerdictChip(verdict: verdict)
                } else if let reformat = job as? ReformatJob {
                    // Rick 2026-06-14: after a Reformat finishes the
                    // user wants to see WHERE the output landed AND
                    // jump straight to the new catalog row. Both
                    // affordances inline on the finished row.
                    finishedChip(summary)
                    revealButton(reformat.publishedURL)
                    showInCatalogButton(reformat.publishedURL)
                } else if let transcode = job as? TranscodeJob {
                    // Pass C (Rick 2026-06-14): same finished treatment
                    // as Reformat — Reveal the new ProRes/HEVC file in
                    // Finder + jump to its catalog row. Show in Catalog
                    // is the affordance that proves the workspaceActive
                    // + derivedFrom wiring took effect.
                    finishedChip(summary)
                    revealButton(transcode.publishedURL)
                    showInCatalogButton(transcode.publishedURL)
                } else if let analyze = job as? AnalyzeJob {
                    // Same treatment for Analyze — the user wants to
                    // verify the catalog row got captions + transcript
                    // banked. Show in Catalog jumps straight there.
                    finishedChip(summary)
                    showInCatalogButtonByID(analyze.record.id)
                } else if let trim = job as? TrimJob {
                    // Trim finishes like Transcode: Reveal the trimmed
                    // master + jump to its catalog row (which proves the
                    // derivedFrom provenance wiring took effect).
                    // publishedURL is where it ACTUALLY landed (a
                    // publish-time collision can bump the planned name).
                    finishedChip(summary)
                    revealButton(trim.publishedURL ?? trim.outputURL)
                    showInCatalogButton(trim.publishedURL ?? trim.outputURL)
                } else if let balance = job as? BalanceAudioJob,
                          let published = balance.publishedURL {
                    // Balance Audio (GH #116): same finished treatment
                    // as Reformat/Transcode — Reveal the balanced copy
                    // and jump to its provenance-stamped catalog row.
                    finishedChip(summary)
                    revealButton(published)
                    showInCatalogButton(published)
                } else if let spectrum = job as? FootageSpectrumJob {
                    // Compare Footage: the one-line verdict, and the window.
                    finishedChip(summary)
                    openSpectrumButton(spectrum)
                } else if let promote = job as? PromoteToArchiveJob,
                          let line = promote.protectionLine {
                    // Promote (stage 2): when every copy landed verified
                    // the row carries the batch's protection line —
                    // "Archive ✓verified · N working copies (…) · cloud: … ·
                    // off-site: …" — computed off-main by the job.
                    finishedChip(summary)
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(line)
                        .accessibilityIdentifier("mfo.row.protectionLine")
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            case .failed:
                stateBadge(job.state.badge)
            case .cancelled:
                // Rick 2026-08-26: a cancelled job is not a failed one —
                // blue stop symbol + "Cancelled", never the red X.
                stateBadge(job.state.badge)
            }

            // Row clock. Active job: live elapsed via SwiftUI's
            // self-updating relative style. Terminal job: FROZEN run
            // duration (finishedAt − startedAt) — `style: .relative`
            // on every row was the 2026-07-07 bug where a finished
            // 5-minute job read "45 min" when glanced at 40 minutes
            // later (it counts up from startedAt forever).
            if job.state.isActive {
                Text(job.startedAt, style: .relative)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                Text(MediaFileOperationClock.text(for: job, at: Date()))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .help("Run duration — started \(job.startedAt.formatted(date: .abbreviated, time: .shortened))")
            }
        }
    }

    /// Green summary capsule for finished extract-style rows (shared
    /// by both frame verbs so they read identically in the list).
    private func finishedChip(_ summary: String) -> some View {
        Text(summary)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.green)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.green.opacity(0.15)))
            .lineLimit(1)
            .fixedSize()
            // Gauntlet flow 4 waits on this chip to prove the job reached
            // done in the MFO window. Test-only.
            .accessibilityIdentifier("mfo.row.finishedChip")
    }

    /// "Reveal in Finder" for extract rows — selects the output folder.
    /// Terminal badge drawn from the state's pure presentation mapping
    /// (MediaFileOperationState.badge) — the single place label, symbol
    /// and tint are decided, so Failed vs Cancelled can't drift apart
    /// between the row, the tests and any future surface.
    private func stateBadge(_ badge: MediaFileOperationState.Badge) -> some View {
        HStack(spacing: 4) {
            if let symbol = badge.symbol {
                Image(systemName: symbol)
                    .foregroundColor(badge.tint.color)
            }
            Text(badge.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(badge.tint.color)
        }
    }

    private func revealButton(_ url: URL) -> some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            Label("Reveal", systemImage: "folder")
                .font(.system(size: 11))
        }
        .buttonStyle(.bordered)
        .help(url.path)
    }

    /// "Show in Catalog" — jumps the main window to the Catalog tab
    /// and selects the record matching the given file path. Used by
    /// finished Reformat rows so the user can verify the new file
    /// landed in the catalog. Silently no-ops if the catalog hasn't
    /// indexed the file yet (auto-catalog after reformat is async; a
    /// click immediately after completion may race).
    private func showInCatalogButton(_ url: URL) -> some View {
        Button {
            guard let rec = model.records.first(where: { $0.fullPath == url.path }) else {
                return
            }
            UserDefaults.standard.set(1, forKey: "selectedTab")
            model.pendingCatalogSelection = rec.id
            MainWindowHelper.shared.openMainWindow()
        } label: {
            Label("Show in Catalog", systemImage: "film.stack")
                .font(.system(size: 11))
        }
        .buttonStyle(.bordered)
        .help("Jump to this file's row in the Catalog tab")
    }

    /// "Open" on a finished Compare Footage row: show THIS run in the
    /// Footage Spectrum window.
    private func openSpectrumButton(_ job: FootageSpectrumJob) -> some View {
        Button {
            FootageSpectrumViewer.shared.show(job)
            FootageSpectrumWindowOpener.open(using: openWindow, source: "mfo-row")
        } label: {
            Label("Open", systemImage: "waveform.path.ecg.rectangle")
                .font(.system(size: 11))
        }
        .buttonStyle(.bordered)
        .help("Show this comparison in the Footage Spectrum window")
        .accessibilityIdentifier("mfo.row.openSpectrum")
    }

    /// Same as showInCatalogButton, but keyed by record UUID — used by
    /// AnalyzeJob where the record is already in the catalog and we
    /// don't need a path-based lookup.
    private func showInCatalogButtonByID(_ id: UUID) -> some View {
        Button {
            // punch-list #5: validate the id still resolves to a live record
            // before navigating. Overnight live-reload/merge churns record
            // identity (e.g. IMG_0795.mov has 35 duplicate copies), so an MFO
            // job can hold an id that no longer exists. Mirror the url-path's
            // guard/no-op — but surface a brief notice instead of silently
            // blanking the catalog table.
            guard model.canNavigateToRecord(id: id) else {
                showInCatalogNotice = "This file is no longer in the catalog — it may have been removed or replaced by a re-scan."
                return
            }
            UserDefaults.standard.set(1, forKey: "selectedTab")
            model.pendingCatalogSelection = id
            MainWindowHelper.shared.openMainWindow()
        } label: {
            Label("Show in Catalog", systemImage: "film.stack")
                .font(.system(size: 11))
        }
        .buttonStyle(.bordered)
        .help("Jump to this file's row in the Catalog tab")
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(isExpanded
                  ? Color.accentColor.opacity(0.1)
                  : (job.state.isActive
                     ? Color.accentColor.opacity(0.04)
                     : Color.clear))
    }
}

// MARK: - Verb badge

/// Colored verb capsule: COMBINE green, COMPARE blue, FACES orange,
/// FRAMES purple — small caps bold.
struct MediaFileOperationBadge: View {
    let kind: MediaFileOperationKind
    /// When non-nil, overrides `kind.badgeText`. Used for `.analyze`
    /// jobs whose displayed verb depends on the AnalyzeJob's stage
    /// set (Transcribe / Captions / Analyze).
    var textOverride: String? = nil

    var body: some View {
        Text(textOverride ?? kind.badgeText)
            .font(Font.system(size: 10, weight: .bold).smallCaps())
            .foregroundColor(.white)
            // Uniform capsule width so the four verbs line up in the
            // job list ("Combine" is the widest at this font size).
            .frame(minWidth: 52)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(kind.badgeColor))
            .fixedSize()
            // The DELETE / TRASH chips are the ones a UI test (and Rick's
            // eye) must be able to find: white on red, their own identifiers.
            .accessibilityIdentifier(kind == .deleteDuplicates ? "mfo.row.deleteChip"
                                     : kind == .pruneCopies ? "mfo.row.trashChip" : "mfo.row.badge")
    }
}

extension MediaFileOperationKind {

    /// Does this row expand to show what the job actually did?
    ///
    /// ONE list. Until 2026-09-15 the set of expandable kinds was written
    /// twice — as a chain of `job is PairCompareJob || …` in the row's tap
    /// gesture, and again as the `if isExpanded, let x = job as? T` blocks
    /// in its body. Two lists of the same thing drift, and the drift is
    /// silent in both directions: a row that refuses to expand, or one that
    /// expands to nothing.
    ///
    /// DELIBERATELY EXHAUSTIVE — no `default`. Adding an eighteenth kind
    /// will not compile until someone decides whether it has a detail view,
    /// which is exactly the decision that gets forgotten. The twelve `false`
    /// cases are not an oversight; they are the backlog Rick picked up on
    /// 2026-09-15 ("detail views for the remaining job kinds"), and they are
    /// listed by name so that backlog is readable from the code.
    var hasDetailView: Bool {
        switch self {
        case .compare, .findPerson, .verifyArchive, .archiveAngel, .deleteDuplicates,
             .pruneCopies, .verifyVideo, .checkMedia, .repair, .lockArchive, .compareFootage, .fingerprintBackfill:
            return true
        case .combine, .extract, .ripFrames, .reformat, .analyze, .transcode,
             .cleanup, .trim, .balanceAudio, .rebuildAudio, .verifyAudio,
             .promote, .findSimilarFootage, .bindFixity:
            return false
        }
    }

    /// Badge capsule fill — `style.fill` (MediaFileOperations.swift keeps
    /// each kind's hue and the rationale for it).
    var badgeColor: Color {
        let c = style.fill
        return Color(red: c.red, green: c.green, blue: c.blue)
    }
}

// MARK: - Compare verdict chip

/// Inline verdict for finished compare rows. Title and colors match
/// the old MediaPairCompareSheet's verdict banner so the visual
/// language carries over.
struct PairCompareVerdictChip: View {
    let verdict: PairCompareVerdict

    var body: some View {
        Text(verdict.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(verdict.displayColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(verdict.displayColor.opacity(0.15)))
            .lineLimit(1)
            .fixedSize()
    }
}

extension PairCompareVerdict {
    /// Banner/chip color — lifted unchanged from the old sheet. Teal
    /// for the perceptual verdict: semantically between blue ("same
    /// packets, different wrapper") and orange ("different") — same
    /// pictures, weaker-than-packet-level proof.
    var displayColor: Color {
        switch self {
        case .exactDuplicates: return .green
        case .sameContentDifferentContainer: return .blue
        case .samePerceptualContent: return .teal
        case .differentMedia: return .orange
        case .sameFile: return .yellow
        }
    }

    var displaySymbol: String {
        switch self {
        case .exactDuplicates: return "doc.on.doc.fill"
        case .sameContentDifferentContainer: return "equal.circle.fill"
        case .samePerceptualContent: return "sparkles.tv.fill"
        case .differentMedia: return "circle.grid.cross"
        case .sameFile: return "doc.fill"
        }
    }
}

// MARK: - Compare detail (expanded row)
//
// Verdict banner + side-by-side metadata diff — lifted from the
// retired MediaPairCompareSheet. Sourced entirely from the cataloged
// VideoRecord fields, so it renders instantly even mid-comparison.

/// Expanded Find & Tag row (Rick 2026-08-04, compare-row pattern):
/// previous / current / next clip with the previous clip's verdict and
/// the live clip's %, plus a summary line with tallies and throughput.
struct FindPersonDetailView: View {
    @ObservedObject var job: FindPersonJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            clipRow(label: "Previous", name: job.clipContext.previous,
                    note: job.clipContext.previousOutcome)
            clipRow(label: "Now", name: job.clipContext.current,
                    note: job.currentClipFraction.map { "\(Int($0 * 100))%" })
            clipRow(label: "Next", name: job.clipContext.next, note: nil)
            Divider()
            Text(job.detailSummary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private func clipRow(label: String, name: String?, note: String?) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(name ?? "—")
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let note {
                Text(note)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(note.contains("*") ? .primary : .secondary)
            }
        }
    }
}

struct PairCompareDetailView: View {
    let job: PairCompareJob

    private var diffRows: [PairCompareLogic.MetadataDiffRow] {
        PairCompareLogic.metadataDiff(job.recordA, job.recordB)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let verdict = job.comparator.verdict {
                verdictBanner(verdict)
            }
            if let err = job.comparator.lastError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            metadataTable
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private func verdictBanner(_ verdict: PairCompareVerdict) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: verdict.displaySymbol)
                .font(.title2)
                .foregroundStyle(verdict.displayColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(verdict.title)
                    .font(.headline)
                // Duration short-circuit: the honest story is "lengths
                // are 5+ minutes apart, content tiers skipped" — the
                // generic differentMedia detail ("content doesn't
                // match") would falsely imply the content was examined.
                Text(job.comparator.durationMismatch?.summary ?? verdict.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Perceptual-tier statistics whenever the tier ran —
                // also under a differentMedia verdict, where "12/32
                // frames agree" tells Rick how close the call was.
                if let stats = job.comparator.perceptualStats {
                    Text(verdict == .samePerceptualContent
                         ? stats.summary
                         : "Visual check: \(stats.summary)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(verdict.displayColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private var metadataTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("")
                fileHeader(job.recordA)
                fileHeader(job.recordB)
            }
            Divider()
            ForEach(diffRows) { row in
                GridRow {
                    Text(row.label)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    diffValue(row.valueA, differs: row.differs)
                    diffValue(row.valueB, differs: row.differs)
                }
            }
        }
    }

    private func fileHeader(_ rec: VideoRecord) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(rec.filename)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(rec.fullPath)
            Text(VolumeReachability.displayLabel(forPath: rec.fullPath))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 230, alignment: .leading)
    }

    /// Differing fields get orange + semibold so the eye lands on what
    /// actually changed between the two copies.
    private func diffValue(_ value: String, differs: Bool) -> some View {
        Text(value)
            .font(.system(size: 12, weight: differs ? .semibold : .regular,
                          design: .monospaced))
            .foregroundStyle(differs ? Color.orange : Color.primary)
            .lineLimit(1)
    }
}

// MARK: - Badge tint → SwiftUI colour

extension MediaFileOperationState.BadgeTint {
    var color: Color {
        switch self {
        case .green: return .green
        case .red: return .red
        case .blue: return .blue
        case .orange: return .orange
        case .secondary: return .secondary
        }
    }
}
