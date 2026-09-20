// ArchiveAngelDetailView.swift
// Expanded Archive Angel panel in Media File Operations: one table row per
// file — who it is, where it stands and a big Skip on the left, the four
// stages as columns across (Rick, 2026-09-18: "the skip bigger … columns on
// left", the layout he and codex had planned). Presentation over the job's
// published plan; full review stays in the Archive tab's sheet. No catalog
// lookup or media work belongs here.

import SwiftUI

struct ArchiveAngelDetailView: View {
    @ObservedObject var job: ArchiveAngelJob
    // Forwarded to the review sheet only (sheets on this window are given
    // their objects explicitly, as ArchiveView does). A table of ~10 rows.
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject var model: VideoScanModel
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject var fileOpsCenter: MediaFileOperationsCenter
    /// Rick 2026-09-19: "once we're done with all that work in that AA
    /// screen … shouldn't there be a Promote Now button rather than
    /// requiring going back to another screen?" The review stays (names,
    /// dates, untick before anything reaches the archive); it opens here.
    @State private var reviewRequest: ArchiveAngelReviewRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if job.plan.entries.isEmpty {
                Text(job.state.isActive ? "Walking the catalog…" : "No candidates in this batch.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    // Pinned column titles: the stage columns stay labelled
                    // however far down the batch Rick scrolls.
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section(header: ArchiveAngelTableHeader()) {
                            ForEach(job.plan.entries) { entry in
                                ArchiveAngelEntryRow(entry: entry, canSkip: job.state.isActive) {
                                    // Recheck at the click: preparation may have finished
                                    // since SwiftUI rendered this row.
                                    // isSkippable, NOT isUnsettled: `.ready` is
                                    // precisely when Rick is watching a prepared
                                    // file about to be promoted and says "skip
                                    // that one". isUnsettled is the preparation
                                    // loop's predicate and excludes .ready.
                                    guard job.state.isActive,
                                          let current = job.plan.entries.first(where: { $0.id == entry.id }),
                                          current.isSkippable else { return }
                                    job.skip(entryID: entry.id)
                                }
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 560)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(Color(NSColor.controlBackgroundColor)))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.14)))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(NSColor.textBackgroundColor).opacity(0.5)))
        .sheet(item: $reviewRequest) { req in
            ArchiveAngelReviewSheet(plan: req.plan)
                .environmentObject(model)
                .environmentObject(fileOpsCenter)
        }
    }

    /// Finished, with files ready and not yet promoted.
    private var canReview: Bool {
        Self.offersReview(isActive: job.state.isActive, readyCount: job.plan.readyCount, status: job.plan.status)
    }

    static func offersReview(isActive: Bool, readyCount: Int, status: ArchiveAngelPlan.Status) -> Bool {
        !isActive && readyCount > 0 && status == .ready
    }

    private var reviewButton: some View {
        Button {
            // The plan on disk is the truth: it may have been promoted from
            // the Archive tab since this job finished.
            let fresh = (try? ArchiveAngelPlanStore.load(batchDir: job.plan.batchDir)) ?? job.plan
            reviewRequest = ArchiveAngelReviewRequest(plan: fresh)
        } label: {
            Label("Review and Promote \(job.plan.readyCount)…", systemImage: "archivebox")
                .font(.system(size: 16, weight: .bold))
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .help("Open the review for this batch: check names and dates, untick anything, then promote into the archive.")
        .accessibilityIdentifier("archiveAngel.reviewAndPromote")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if canReview { reviewButton.padding(.bottom, 4) }
            Text("\(job.plan.readyCount) ready\(job.plan.skippedClause)\(job.plan.bufferShortClause) · \(job.plan.entries.count) picked · "
                 + "\(job.plan.rejectedTotal) rejected · \(job.plan.overflow) more would qualify")
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(job.plan.batchDir)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .help(job.plan.batchDir)
        }
    }

    static func icon(_ s: ArchiveAngelPlan.EntryStatus) -> String {
        switch s {
        case .pending: return "circle.dotted"
        case .preparing: return "gearshape"
        case .ready: return "checkmark.circle.fill"
        case .promoted: return "archivebox.fill"
        case .failed: return "xmark.circle.fill"
        // A decision, not a breakage — never the red x of `.failed`.
        case .skipped: return "arrow.uturn.forward.circle"
        }
    }

    static func color(_ s: ArchiveAngelPlan.EntryStatus) -> Color {
        switch s {
        case .pending: return .secondary
        case .preparing: return .orange
        case .ready: return .green
        case .promoted: return .blue
        case .failed: return .red
        case .skipped: return .secondary
        }
    }

    static func chipColor(_ s: ArchiveAngelPlan.StepState) -> Color {
        switch s {
        case .pending: return .secondary
        case .done: return .green
        case .skipped: return .gray
        case .failed: return .red
        }
    }
}

/// Column geometry shared by the header and every row, so the stage
/// columns line up down the whole batch.
enum ArchiveAngelTableLayout {
    static let stageWidth: CGFloat = 116
    static let rowPadding: CGFloat = 12
}

/// The pinned column titles: "File", then one title per stage.
struct ArchiveAngelTableHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("File")
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(ArchiveAngelPlan.StepKind.allCases, id: \.self) { kind in
                Text(ArchiveAngelStepPresentation.columnTitle(kind))
                    .multilineTextAlignment(.center)
                    .frame(width: ArchiveAngelTableLayout.stageWidth)
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, ArchiveAngelTableLayout.rowPadding)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A value-only view: callers supply the action, so previews and layout
/// checks do not need to create a live ArchiveAngelJob.
struct ArchiveAngelEntryRow: View {
    let entry: ArchiveAngelPlan.Entry
    let canSkip: Bool
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 0) {
                identityColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(ArchiveAngelPlan.StepKind.allCases, id: \.self) { kind in
                    stageCell(kind)
                        .frame(width: ArchiveAngelTableLayout.stageWidth)
                }
            }
            notes
        }
        .padding(ArchiveAngelTableLayout.rowPadding)
        .background(Color.accentColor.opacity(entry.status == .preparing ? 0.08 : 0))
        .overlay(alignment: .leading) {
            // The file being worked on right now gets an accent bar.
            if entry.status == .preparing {
                Rectangle().fill(Color.accentColor).frame(width: 4)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.filename)
    }

    private var identityColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.filename)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help("\(entry.filename)\n\(entry.sourcePath)")
            HStack(spacing: 12) {
                // No room right now is not a breakage: orange, a drive, and
                // words that say it will come back (2026-09-19).
                Label(entry.isBufferShort ? "Waiting for buffer space"
                          : ArchiveAngelStepPresentation.entryLabel(entry.status),
                      systemImage: entry.isBufferShort ? "externaldrive.badge.exclamationmark"
                          : ArchiveAngelDetailView.icon(entry.status))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(entry.isBufferShort ? Color.orange : ArchiveAngelDetailView.color(entry.status))
                Text("Score \(entry.score)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if canSkip && entry.isSkippable {   // incl. rows waiting for buffer space
                skipButton
            }
        }
        .padding(.trailing, 12)
    }

    // Big on purpose (Rick, 2026-09-18): the one control he reaches for
    // while a batch runs. Shown only while it can act.
    private var skipButton: some View {
        Button(action: onSkip) {
            Label("Skip this one", systemImage: "forward.fill")
                .font(.system(size: 16, weight: .bold))
                .frame(minWidth: 170)
                .padding(.vertical, 5)
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .controlSize(.large)
        .help(entry.status == .preparing
              ? "Skip this file — stops its transcode, drops its partial companions and moves on to the next one. The batch keeps running."
              : "Skip this file for this batch. Nothing is written to the catalog, so a later batch may propose it again.")
        .accessibilityIdentifier("archiveAngel.row.skip")
        .accessibilityLabel("Skip \(entry.filename) this time")
    }

    private func stageCell(_ kind: ArchiveAngelPlan.StepKind) -> some View {
        let cell = ArchiveAngelStepPresentation.cell(kind, in: entry)
        let step = entry.steps.first { $0.kind == kind }
        return VStack(spacing: 5) {
            Image(systemName: cell.icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(cell.color)
                .symbolRenderingMode(.hierarchical)
            Text(cell.word)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(cell == .done ? Color.primary : cell == .working ? Color.orange : Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
        .help(step.map { $0.note.isEmpty ? ArchiveAngelStepPresentation.label($0, entryStatus: entry.status) : $0.note }
              ?? "Not part of this batch")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(ArchiveAngelStepPresentation.columnTitle(kind)): \(cell.word)")
    }

    @ViewBuilder
    private var notes: some View {
        if let why = entry.evidence.first?.line {
            Text(why)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // A filename-only inference; do not claim the original exists.
        if let base = entry.derivativeOfStem {
            Label("Looks like a derivative export of “\(base)” — the original is not in the catalog",
                  systemImage: "exclamationmark.triangle")
                .font(.system(size: 13))
                .foregroundStyle(Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let skipNote = entry.skipNote, entry.status == .skipped {
            Text(skipNote)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let failure = entry.failure {
            Text(failure)
                .font(.system(size: 13))
                .foregroundStyle(entry.isBufferShort ? Color.orange : Color.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Skipped can mean disabled, already verified, or interrupted — keep
        // each stage's actual reason visible instead of guessing.
        ForEach(entry.steps.filter { ($0.state == .skipped || $0.state == .failed) && !$0.note.isEmpty }) { step in
            Text("\(ArchiveAngelStepPresentation.columnTitle(step.kind)): \(step.note)")
                .font(.system(size: 13))
                .foregroundStyle(step.state == .failed ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Deterministic presentation only; persisted step meanings stay unchanged.
enum ArchiveAngelStepPresentation {
    /// What one stage cell of the table shows.
    enum Cell: Equatable {
        case notInBatch, working, pending, notRun, done, skipped, failed

        var icon: String {
            switch self {
            case .notInBatch: return "minus"
            case .working: return "arrow.triangle.2.circlepath.circle.fill"
            case .pending: return "circle.dotted"
            case .notRun: return "circle.slash"
            case .done: return "checkmark.circle.fill"
            case .skipped: return "minus.circle"
            case .failed: return "exclamationmark.circle.fill"
            }
        }

        var word: String {
            switch self {
            case .notInBatch: return "—"
            case .working: return "Working…"
            case .pending: return "Pending"
            case .notRun: return "Not run"
            case .done: return "Done"
            case .skipped: return "Skipped"
            case .failed: return "Failed"
            }
        }

        var color: Color {
            switch self {
            case .notInBatch, .pending, .notRun, .skipped: return .secondary
            case .working: return .orange
            case .done: return .green
            case .failed: return .red
            }
        }
    }

    /// The cell for one stage of one file. While a file is preparing, its
    /// first still-pending stage is the one being worked on.
    static func cell(_ kind: ArchiveAngelPlan.StepKind, in entry: ArchiveAngelPlan.Entry) -> Cell {
        guard let step = entry.steps.first(where: { $0.kind == kind }) else { return .notInBatch }
        switch step.state {
        case .done: return .done
        case .skipped: return .skipped
        case .failed: return .failed
        case .pending:
            if entry.status == .skipped || entry.status == .failed { return .notRun }
            if entry.status == .preparing,
               entry.steps.first(where: { $0.state == .pending })?.kind == kind { return .working }
            return .pending
        }
    }

    static func columnTitle(_ kind: ArchiveAngelPlan.StepKind) -> String {
        switch kind {
        case .verifyAudio: return "Verify Audio"
        case .balanceAudio: return "Balance Audio"
        case .accessCopy: return "Access Copy"
        case .losslessCopy: return "Lossless Copy"
        }
    }

    static func label(_ step: ArchiveAngelPlan.StepOutcome,
                      entryStatus: ArchiveAngelPlan.EntryStatus) -> String {
        if step.state == .done {
            switch step.kind {
            case .verifyAudio: return "Audio Verified"
            case .balanceAudio: return "Audio Balanced"
            case .accessCopy: return "Access Copy Created"
            case .losslessCopy: return "Lossless Copy Created"
            }
        }
        let name = columnTitle(step.kind)
        switch step.state {
        case .pending:
            // Pending outcomes can survive a skipped or interrupted entry.
            let stopped = entryStatus == .skipped || entryStatus == .failed
            return "\(name) · \(stopped ? "Not run" : "Pending")"
        case .skipped: return "\(name) · Skipped"
        case .failed: return "\(name) · Failed"
        case .done: return name // Handled above.
        }
    }

    static func icon(_ state: ArchiveAngelPlan.StepState) -> String {
        switch state {
        case .pending: return "clock"
        case .done: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    static func background(_ state: ArchiveAngelPlan.StepState) -> Color {
        switch state {
        // Dark green keeps white text legible in both light and dark mode.
        case .done: return Color(red: 0.08, green: 0.39, blue: 0.22)
        case .failed: return Color(red: 0.65, green: 0.14, blue: 0.13)
        case .pending, .skipped: return Color.primary.opacity(0.08)
        }
    }

    static func entryLabel(_ status: ArchiveAngelPlan.EntryStatus) -> String {
        switch status {
        case .pending: return "Waiting"
        case .preparing: return "Preparing"
        case .ready: return "Ready for review"
        case .promoted: return "Promoted"
        case .failed: return "Failed"
        case .skipped: return "Skipped this time"
        }
    }
}

#Preview("Archive Angel table rows") {
    let base = ArchiveAngelPlan.Entry(
        id: UUID(), sourcePath: "/Volumes/FamilyArchive/tapes/Xmas_1987.mov", filename: "Xmas_1987.mov",
        sizeBytes: 4_000_000_000, sourceContentHash: "", sourceModifiedAt: nil,
        durationSeconds: 3480, score: 812, evidence: [], proposedName: "Xmas_1987.mov",
        proposedDate: "1987", status: .preparing)
    var working = base
    working.steps[0].state = .done
    var waiting = base
    waiting.id = UUID(); waiting.filename = "Beach_1991.avi"; waiting.status = .pending; waiting.score = 790
    var ready = base
    ready.id = UUID(); ready.filename = "Wedding.mxf"; ready.status = .ready
    for i in ready.steps.indices { ready.steps[i].state = .done }
    return VStack(spacing: 0) {
        ArchiveAngelTableHeader()
        ForEach([working, waiting, ready]) { entry in
            ArchiveAngelEntryRow(entry: entry, canSkip: true) {}
            Divider()
        }
    }
    .frame(width: 900)
}
