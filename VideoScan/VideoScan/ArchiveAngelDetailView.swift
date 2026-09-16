// ArchiveAngelDetailView.swift
// Expanded Archive Angel panel in Media File Operations. Each file keeps
// its identity, batch-only Skip action, and step outcomes in one card.
// Presentation over the job's published plan; full review stays in the
// Archive tab's sheet. No catalog lookup or media work belongs here.

import SwiftUI

struct ArchiveAngelDetailView: View {
    @ObservedObject var job: ArchiveAngelJob

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if job.plan.entries.isEmpty {
                Text(job.state.isActive ? "Walking the catalog…" : "No candidates in this batch.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(job.plan.entries) { entry in
                            ArchiveAngelEntryCard(entry: entry, canSkip: job.state.isActive) {
                                // Recheck at the click: preparation may have finished
                                // since SwiftUI rendered this card.
                                // isSkippable, NOT isUnsettled: `.ready` is
                                // precisely when Rick is watching a prepared
                                // file about to be promoted and says "skip
                                // that one". isUnsettled is the preparation
                                // loop's predicate and excludes .ready.
                                guard job.state.isActive,
                                      let current = job.plan.entries.first(where: { $0.id == entry.id }),
                                      current.status.isSkippable else { return }
                                job.skip(entryID: entry.id)
                            }
                        }
                    }
                    .padding(2)
                }
                .frame(maxHeight: 500)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(NSColor.textBackgroundColor).opacity(0.5)))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(job.plan.readyCount) ready\(job.plan.skippedClause) · \(job.plan.entries.count) picked · "
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

/// A value-only view: callers supply the action, so previews and layout
/// checks do not need to create a live ArchiveAngelJob.
struct ArchiveAngelEntryCard: View {
    let entry: ArchiveAngelPlan.Entry
    let canSkip: Bool
    let onSkip: () -> Void

    private let stageColumns = [GridItem(.adaptive(minimum: 240, maximum: 300),
                                        spacing: 10, alignment: .topLeading)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry.filename)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help("\(entry.filename)\n\(entry.sourcePath)")

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { identityControls }
                VStack(alignment: .leading, spacing: 10) { identityControls }
            }

            if let why = entry.evidence.first?.line {
                Text(why)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // A filename-only inference; do not claim the original exists.
            if let base = entry.derivativeOfStem {
                Label("Looks like a derivative export of “\(base)” — the original is not in the catalog",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let skipNote = entry.skipNote, entry.status == .skipped {
                Text(skipNote)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = entry.failure {
                Text(failure)
                    .font(.system(size: 14))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: stageColumns, alignment: .leading, spacing: 10) {
                ForEach(entry.steps) { step in
                    stepBadge(step)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(Color.accentColor.opacity(entry.status == .preparing ? 0.08 : 0)))
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(entry.status == .preparing
                          ? Color.accentColor.opacity(0.65)
                          : Color.primary.opacity(0.14),
                          lineWidth: entry.status == .preparing ? 2 : 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.filename)
    }

    @ViewBuilder
    private var identityControls: some View {
        Button(action: onSkip) {
            Label("Skip this time", systemImage: "arrow.uturn.forward")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(!canSkip || !entry.status.isSkippable)
        .help(!entry.status.isSkippable
              ? "This file is already settled and cannot be skipped."
              : !canSkip
              ? "This batch is no longer active."
              : entry.status == .preparing
              ? "Skip this file — stops its transcode, drops its partial companions and moves on to the next one. The batch keeps running."
              : "Skip this file for this batch. Nothing is written to the catalog, so a later batch may propose it again.")
        .accessibilityIdentifier("archiveAngel.row.skip")
        .accessibilityLabel("Skip \(entry.filename) this time")
        Label(ArchiveAngelStepPresentation.entryLabel(entry.status),
              systemImage: ArchiveAngelDetailView.icon(entry.status))
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(ArchiveAngelDetailView.color(entry.status))
        Text("Score \(entry.score)")
            .font(.system(size: 14, design: .monospaced))
            .foregroundStyle(.secondary)
    }

    private func stepBadge(_ step: ArchiveAngelPlan.StepOutcome) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(ArchiveAngelStepPresentation.label(step, entryStatus: entry.status),
                  systemImage: ArchiveAngelStepPresentation.icon(step.state))
                .font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .foregroundStyle(step.state == .done || step.state == .failed ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(ArchiveAngelStepPresentation.background(step.state)))
                .help(step.note.isEmpty ? step.kind.label : step.note)

            // Skipped can mean disabled, already verified, or interrupted.
            // Keep the actual reason visible instead of guessing "not needed".
            if (step.state == .skipped || step.state == .failed), !step.note.isEmpty {
                Text(step.note)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// Deterministic presentation only; persisted step meanings stay unchanged.
enum ArchiveAngelStepPresentation {
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
        let name: String
        switch step.kind {
        case .verifyAudio: name = "Verify Audio"
        case .balanceAudio: name = "Balance Audio"
        case .accessCopy: name = "Access Copy"
        case .losslessCopy: name = "Lossless Copy"
        }
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
