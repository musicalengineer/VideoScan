import Combine
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
                    window.level = .floating
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

            if center.runningCount > 0 {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(center.runningCount == 1
                         ? "1 operation running"
                         : "\(center.runningCount) operations running")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            if center.jobs.contains(where: { !$0.state.isActive }) {
                Button("Clear Finished") {
                    center.clearFinished()
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
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
                Button(model.isCombinePaused ? "Resume All" : "Pause All") {
                    if model.isCombinePaused {
                        model.resumeCombine()
                    } else {
                        model.pauseCombine()
                    }
                }
                Button("Stop All") { model.stopCombine() }
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Generic operation row

/// One new-style job row: verb badge, file names, live subtitle, thin
/// progress bar, Cancel / Pause, relative start time — plus an
/// expandable detail area (compare jobs show the verdict banner and
/// the side-by-side metadata diff).
struct MediaFileOperationRow: View {
    let job: any MediaFileOperationJob
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    /// For "Show in Catalog" on completed Reformat rows — same
    /// pendingCatalogSelection mechanism the dashboard uses. Rick
    /// 2026-06-14.
    @EnvironmentObject var model: VideoScanModel

    /// Re-render driver: the job is an existential, so @ObservedObject
    /// can't watch it directly. We subscribe to its objectWillChange
    /// and flip this bit, which invalidates the view.
    @State private var heartbeat = false

    /// punch-list #5: non-nil drives a brief alert when "Show in Catalog"
    /// is clicked for a record that's no longer in the catalog (stale id
    /// after live-reload identity churn). Mirrors the findOnlineNotice
    /// pattern in CatalogHelpers.
    @State private var showInCatalogNotice: String?

    var body: some View {
        // Referencing `heartbeat` ties this view's identity to the
        // toggle below — that's what makes onReceive re-render us.
        let _ = heartbeat

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
                    Text(job.subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                trailingStatus
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if job.state == .running || job.state == .cancelling {
                ProgressView(value: job.isIndeterminate ? nil : job.fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .tint(job.state == .cancelling ? .orange : .blue)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            if isExpanded, let compare = job as? PairCompareJob {
                PairCompareDetailView(job: compare)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture {
            // Only compare rows have a detail view today.
            if job is PairCompareJob { onToggleExpand() }
        }
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
                    .buttonStyle(.bordered)
                }
                Button(job.state == .cancelling ? "Stopping…" : "Cancel") {
                    job.cancel()
                }
                .font(.system(size: 11))
                .buttonStyle(.bordered)
                .disabled(job.state == .cancelling)
            case .finished(let summary):
                if let compare = job as? PairCompareJob,
                   let verdict = compare.comparator.verdict {
                    PairCompareVerdictChip(verdict: verdict)
                } else if let extract = job as? ExtractFramesJob,
                          let dest = extract.ripper.completedDestination {
                    // Verdict in-row, like compare's chip: frame count
                    // + jump straight to the PNGs (the affordance the
                    // retired FrameRipperSheet had).
                    finishedChip(summary)
                    revealButton(dest)
                } else if let rip = job as? RipAllFramesJob,
                          let dest = rip.ripper.completedDestination {
                    // Same finished treatment for the ffmpeg-only frame
                    // export — count + size chip, Reveal to the PNGs.
                    finishedChip(summary)
                    revealButton(dest)
                } else if let reformat = job as? ReformatJob {
                    // Rick 2026-06-14: after a Reformat finishes the
                    // user wants to see WHERE the output landed AND
                    // jump straight to the new catalog row. Both
                    // affordances inline on the finished row.
                    finishedChip(summary)
                    revealButton(reformat.outputURL)
                    showInCatalogButton(reformat.outputURL)
                } else if let transcode = job as? TranscodeJob {
                    // Pass C (Rick 2026-06-14): same finished treatment
                    // as Reformat — Reveal the new ProRes/HEVC file in
                    // Finder + jump to its catalog row. Show in Catalog
                    // is the affordance that proves the workspaceActive
                    // + derivedFrom wiring took effect.
                    finishedChip(summary)
                    revealButton(transcode.outputURL)
                    showInCatalogButton(transcode.outputURL)
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
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            case .failed:
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                    Text("Failed")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.red)
                }
            case .cancelled:
                Text("Stopped")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                // A cancelled extract keeps its already-saved frames —
                // offer Reveal on the partial output too. Both frame
                // verbs behave the same way here.
                if let extract = job as? ExtractFramesJob,
                   extract.ripper.framesSaved > 0,
                   let dest = extract.ripper.completedDestination {
                    revealButton(dest)
                } else if let rip = job as? RipAllFramesJob,
                          rip.ripper.framesWritten > 0,
                          let dest = rip.ripper.completedDestination {
                    revealButton(dest)
                }
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
    }

    /// "Reveal in Finder" for extract rows — selects the output folder.
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
    }
}

extension MediaFileOperationKind {
    var badgeColor: Color {
        switch self {
        case .combine: return .green
        case .compare: return .blue
        case .extract: return .orange
        case .ripFrames: return .purple
        case .reformat: return .red
        case .analyze: return .cyan
        // Pass C — Transcode's mint badge matches the workspaceActive
        // tint (mint hammer icon in the catalog filename column), so
        // the user reads "transcode → workspace" as the same
        // visual lineage.
        case .transcode: return .mint
        // Clean Up shares transcode's derivative-producing nature but
        // gets its own hue so the two verbs read apart at a glance.
        case .cleanup: return .teal
        // Trim is the third derivative-producing verb — indigo keeps it
        // distinct from transcode's mint and cleanup's teal.
        case .trim: return .indigo
        // Balance Audio — pink keeps it distinct from the other
        // derivative-producing verbs (mint/teal/indigo; indigo went to
        // Trim when the branches merged). GH #116.
        case .balanceAudio: return .pink
        }
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
