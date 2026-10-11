// ShowAgainReview.swift
// Where Rick finds "Show these files again": the TOTAL CATALOG footer's
// caption ("+ 976 GB hidden by a “deleted” label — never removed, still on
// disk") ends in a "Review…" link. The caption is exactly where those bytes
// are disclosed, so the fix sits on the number it explains.
//
// Review… (redesigned 2026-10-11) answers ONE question — "is it safe to
// delete these?" — with a short table of plain-language recommendations
// (`DeleteReviewSummaryView`): copies that exist elsewhere, copies of each
// other, junk you confirmed, only copies, and the unsure ones; each with its
// file count, the space it frees and a checkbox where it may be ticked.
//
// The dry run behind it is read-only: the same check the job runs (ledger +
// one stat per labelled file), then the classification from the catalog
// (ShowAgainDeleteClassifier). The one Apply:
//   * shows ALL the files that pass the check again (label only — the
//     existing Show Again job, its snapshot, receipt and undo), and
//   * hands the ticked rows' files to the existing Delete Duplicates engine
//     (ShowAgainThenTrash), which proves the copy that stays byte for byte
//     at each move and holds anything that fails. Trash only.
// Cancel changes nothing. The primary button is never bound to Return.
//
// No `@EnvironmentObject` here: the model arrives as a plain reference from
// the pane and the MFO center through the non-observing environment value,
// so neither the link nor the sheet re-renders on unrelated publishes.

import SwiftUI

/// The footer link. Holds only its own sheet flag.
struct ShowAgainReviewLink: View {
    let model: VideoScanModel
    @Environment(\.mediaFileOperationsCenterReference) private var center
    @State private var showReview = false

    var body: some View {
        Button("Review…") { showReview = true }
            .buttonStyle(.link)
            .font(.system(size: 11))
            .help("See which hidden files are safe to delete, show them all in the catalog again, and move the ones you tick to the Trash.")
            .accessibilityIdentifier("catalog.totalMediaFooter.showAgainReview")
            .sheet(isPresented: $showReview) {
                ShowAgainReviewSheet(model: model) { plan, picks in
                    guard let center else {
                        model.showAgainNote("\(ShowAgainLines.prefix): refused — the Media File Operations window is not available here. Nothing was changed.")
                        return
                    }
                    center.startedByUser { $0.startShowAgainThenTrash(model: model, reviewed: plan, picks: picks) }
                }
            }
    }
}

/// The dry run, the "is it safe?" table and the one confirmation.
struct ShowAgainReviewSheet: View {
    let model: VideoScanModel
    let onApply: (ShowAgainPlan, [ReviewedDuplicatePick]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var plan: ShowAgainPlan?
    @State private var summary: DeleteReviewSummary = .empty
    @State private var checked: Set<DeleteReviewCategory> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Files hidden by a “deleted” label")
                .font(.headline)
            Text("These files were never moved to the Trash. An old Migrate rule and a duplicate-cleanup bug (both fixed) put a “deleted” label on them, so the Catalog hides them. All of them will be shown in the Catalog again. Tick what you want moved to the Trash.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content
            buttons
        }
        .padding(20)
        .frame(width: 720, height: 560)
        .task { await review() }
    }

    @ViewBuilder private var content: some View {
        if let plan {
            if let refusal = plan.refusal {
                Text("Can't check safely: \(refusal). Nothing will change.")
                    .foregroundStyle(.red)
                Spacer()
            } else {
                Text("\(plan.headline). Is it safe to delete them?")
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityIdentifier("showAgain.review.headline")
                if let stay = plan.stayLine {
                    Text(stay + ".").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                DeleteReviewSummaryView(summary: summary, checked: $checked)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking each labelled file on disk, in the ledger and in the catalog (read only)…")
                    .font(.system(size: 12))
            }
            Spacer()
        }
    }

    private var buttons: some View {
        HStack {
            Text("Moved files go to the Trash of their drive; each is checked byte for byte against the copy that stays first.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(applyTitle) {
                if let plan { onApply(plan, summary.duplicatePicks(checked)) }
                dismiss()
            }
            // No Return-key shortcut: moving files to the Trash is a deliberate click.
            .disabled(!canApply)
            .accessibilityIdentifier("showAgain.review.confirm")
        }
    }

    private var canApply: Bool {
        guard let plan else { return false }
        return plan.refusal == nil && plan.showCount > 0
    }

    /// "Move 701 to Trash" when rows are ticked; "Show 959 Again" when none are.
    private var applyTitle: String {
        let totals = summary.totals(checked)
        if !totals.isEmpty { return totals.moveTitle }
        guard let n = plan?.showCount, n > 0 else { return "Show Them Again" }
        return "Show \(n.formatted()) Again"
    }

    private func review() async {
        let result = await model.showAgainReview()
        let table = result.refusal == nil ? await model.showAgainDeleteReview(plan: result) : .empty
        summary = table
        checked = table.defaultSelection
        plan = result
        let what = result.refusal.map { "can't check safely: \($0)" } ?? result.headline
        model.showAgainNote("\(ShowAgainLines.prefix): review — \(what)\(result.stayLine.map { "; \($0)" } ?? "")\(table.logLine.isEmpty ? "" : " — \(table.logLine)") (dry run, nothing changed)")
    }
}
