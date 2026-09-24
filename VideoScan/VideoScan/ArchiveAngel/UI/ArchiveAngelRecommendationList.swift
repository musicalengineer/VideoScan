// ArchiveAngelRecommendationList.swift
// The Archive Angel strip's turndown — the recommended files, drawn for
// senior eyes (Rick 2026-09-24: "better to see 10 files clearly than 25
// needing a microscope"). Ten rows at a time, a "Show 10 more" button,
// large type and Hallie-style buttons (ArchiveAngelListRowView). Replaces
// the old compact rows (letter grade, 11 pt text, tiny icons, score).
//
// The rows arrive precomputed (ArchiveAngelAssessmentPanel builds them in
// a task keyed on the recommendations revision) — nothing here walks the
// catalog. The Archive Readiness sheet is a `.sheet(item:)` whose payload
// is the finished explanation (chained-sheet rule).

import SwiftUI

struct ArchiveAngelRecommendationList: View {
    let rows: [ArchiveAngelListRow]
    /// Every recommended file (the rows are the first `rows.count`).
    let totalCount: Int
    let isAssessed: Bool
    let isReadOnly: Bool
    /// An Archive Angel or Promote job is running — rows' Prepare waits.
    var angelJobRunning = false
    let actions: ArchiveAngelListActions
    let showMore: () -> Void

    @State private var readiness: ArchiveAngelReadinessExplanation?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Text(isAssessed ? "Nothing is recommended yet." : "Waiting for the first assessment…")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
            ForEach(rows) { row in
                ArchiveAngelListRowView(
                    row: row,
                    isReadOnly: isReadOnly,
                    angelJobRunning: angelJobRunning,
                    onPlay: { actions.play(row) },
                    onShowInCatalog: { actions.showInCatalog(row) },
                    onShowInFinder: { actions.showInFinder(row) },
                    onPromote: { actions.promote(row) },
                    onReadiness: { readiness = actions.readiness(row) })
                Divider()
            }
            if totalCount > rows.count {
                HStack(spacing: 14) {
                    Text("Showing \(rows.count) of \(totalCount.formatted()).")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                    Button(action: showMore) {
                        Text("Show \(min(ArchiveAngelAssessmentPanel.pageSize, totalCount - rows.count)) more")
                            .font(.system(size: 16, weight: .medium))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 30)
                    }
                    .accessibilityIdentifier("archiveAngel.list.showMore")
                }
                .padding(14)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .sheet(item: $readiness) { explanation in
            ArchiveAngelReadinessSheet(explanation: explanation)
        }
    }
}
