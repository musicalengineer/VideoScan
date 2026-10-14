// ShowAgainReview.swift
// Where Rick finds "Show these files again": the TOTAL CATALOG footer's
// caption ("+ 976 GB hidden by a “deleted” label — never removed, still on
// disk") ends in a "Review…" link. The caption is exactly where those bytes
// are disclosed, so the fix sits on the number it explains. (Repair… is the
// one door for A/V repair of media files; this is a catalog-label repair,
// and touches no file.)
//
// Review… opens the dry run: the same check the job runs (ledger + one stat
// per labelled file), read-only, then "959 files, 976 GB will be shown
// again", what stays labelled and why, and the files. "Show them again"
// hands EXACTLY that plan to the Media File Operations job; Cancel changes
// nothing.
//
// No `@EnvironmentObject` here: the model arrives as a plain reference from
// the pane and the MFO center through the non-observing environment value,
// so neither the link nor the sheet re-renders on unrelated publishes.

import SwiftUI

/// The footer link — and, since 2026-10-14, Triage ▸ Cleanup's "Show them
/// again…" line (the same sheet, the same job). Holds only its own sheet
/// flag.
struct ShowAgainReviewLink: View {
    let model: VideoScanModel
    var title = "Review…"
    var accessibilityID = "catalog.totalMediaFooter.showAgainReview"
    @Environment(\.mediaFileOperationsCenterReference) private var center
    @State private var showReview = false

    var body: some View {
        Button(title) { showReview = true }
            .buttonStyle(.link)
            .font(.system(size: 11))
            .help("See which hidden files are on disk, untouched, and show them again in the catalog. Label only — no file is moved or changed.")
            .accessibilityIdentifier(accessibilityID)
            .sheet(isPresented: $showReview) {
                ShowAgainReviewSheet(model: model) { plan in
                    guard let center else {
                        model.showAgainNote("\(ShowAgainLines.prefix): refused — the Media File Operations window is not available here. Nothing was changed.")
                        return
                    }
                    center.startedByUser { $0.startShowAgain(model: model, reviewed: plan) }
                }
            }
    }
}

/// The dry run and the one confirmation.
struct ShowAgainReviewSheet: View {
    let model: VideoScanModel
    let onShowAgain: (ShowAgainPlan) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var plan: ShowAgainPlan?

    /// Files listed in the sheet (the job's detail and catalog.log list them all).
    static let listCap = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Files hidden by a “deleted” label")
                .font(.headline)
            Text("These files were never moved to the Trash. An old Migrate rule and a duplicate-cleanup bug (both fixed) put a “deleted” label on them, so the catalog hides them. Showing them again changes only that label: nothing is moved, renamed or opened for writing. A safety copy of the catalog is taken first, and the change can be undone from the job's row.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content
            buttons
        }
        .padding(20)
        .frame(width: 640, height: 520)
        .task { await review() }
    }

    @ViewBuilder private var content: some View {
        if let plan {
            if let refusal = plan.refusal {
                Text("Can't check safely: \(refusal). Nothing will change.")
                    .foregroundStyle(.red)
            } else {
                Text(plan.headline + ".")
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityIdentifier("showAgain.review.headline")
                if let stay = plan.stayLine {
                    Text(stay + ".").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                fileList(plan)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking each labelled file on disk and in the ledger (read only)…")
                    .font(.system(size: 12))
            }
            Spacer()
        }
    }

    private func fileList(_ plan: ShowAgainPlan) -> some View {
        List {
            ForEach(plan.staying.prefix(Self.listCap)) { item in
                line(item.candidate, note: stayWords(item.verdict), tint: .orange)
            }
            ForEach(plan.toShow.prefix(Self.listCap)) { item in
                line(item.candidate, note: "on disk · \(MediaBytes.display(item.candidate.sizeBytes))", tint: .green)
            }
            if plan.items.count > Self.listCap * 2 {
                Text("…the full list is written to catalog.log when it runs")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
    }

    private func stayWords(_ v: ShowAgainVerdict) -> String {
        if case .stays(let why) = v { return "stays labelled — " + why.words }
        return ""
    }

    private func line(_ c: ShowAgainCandidate, note: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(c.fullPath).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Text(note).font(.system(size: 11)).foregroundStyle(tint)
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(showTitle) {
                if let plan { onShowAgain(plan) }
                dismiss()
            }
            // No Return-key shortcut: a catalog-wide change is a deliberate click.
            .disabled(!(plan.map { $0.refusal == nil && $0.showCount > 0 } ?? false))
            .accessibilityIdentifier("showAgain.review.confirm")
        }
    }

    private var showTitle: String {
        guard let n = plan?.showCount, n > 0 else { return "Show Them Again" }
        return "Show \(n.formatted()) Again"
    }

    private func review() async {
        let result = await model.showAgainReview()
        plan = result
        model.showAgainNote("\(ShowAgainLines.prefix): review — \(result.refusal.map { "can't check safely: \($0)" } ?? result.headline)\(result.stayLine.map { "; \($0)" } ?? "") (dry run, nothing changed)")
    }
}
