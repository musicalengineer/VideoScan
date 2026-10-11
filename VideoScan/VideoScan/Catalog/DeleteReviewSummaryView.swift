// DeleteReviewSummaryView.swift
// Draws a `DeleteReviewSummary` — the "is it safe to delete these?" table —
// for any front that fills one (today the Catalog footer's Review… sheet;
// later Triage's Delete Junk and Delete Duplicates).
//
// One line per recommendation: a checkbox where the row may be ticked, the
// recommendation in family words, its file count and the space it frees; a
// disclosure triangle opens that row's files with a one-line reason each.
// Under the table, the ticked rows' total.
//
// Data flow: the summary is a precomputed value the host owns; the ticked
// rows are the host's `@Binding` (≈ a non-const reference to the host's
// variable), so the host's button reads the same selection. Only the open /
// closed state of each disclosure is this view's own `@State`. Every number
// in the body is a stored total (O(rows)); no O(files) work runs here.

import SwiftUI

struct DeleteReviewSummaryView: View {
    let summary: DeleteReviewSummary
    @Binding var checked: Set<DeleteReviewCategory>
    @State private var expanded: Set<DeleteReviewCategory> = []

    /// Files listed per row (the job's detail and the logs list them all).
    static let listCap = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(summary.rows) { row in
                        rowView(row)
                    }
                }
                .padding(.vertical, 2)
            }
            Divider()
            Text(summary.totals(checked).footerLine)
                .font(.system(size: 12, weight: .semibold))
                .accessibilityIdentifier("deleteReview.footer")
        }
    }

    private var header: some View {
        HStack {
            Text("Recommendation").frame(maxWidth: .infinity, alignment: .leading)
            Text("Files").frame(width: Self.countWidth, alignment: .trailing)
            Text("Frees").frame(width: Self.bytesWidth, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.leading, Self.checkWidth + 6)
    }

    private static let checkWidth: CGFloat = 20
    private static let countWidth: CGFloat = 60
    private static let bytesWidth: CGFloat = 80

    private func rowView(_ row: DeleteReviewRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                checkbox(row).frame(width: Self.checkWidth)
                Button {
                    toggleExpanded(row.category)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: expanded.contains(row.category) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                        Image(systemName: row.category.symbol)
                            .foregroundStyle(tint(row.category))
                        Text(row.category.title)
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("deleteReview.row.\(row.category.rawValue)")
                Text(row.fileCount.formatted())
                    .monospacedDigit()
                    .frame(width: Self.countWidth, alignment: .trailing)
                Text(row.isSelectable ? MediaBytes.display(row.freeableBytes) : "—")
                    .monospacedDigit()
                    .frame(width: Self.bytesWidth, alignment: .trailing)
            }
            .font(.system(size: 13))
            Text(row.category.explanation)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Self.checkWidth + 22)
            if expanded.contains(row.category) {
                fileList(row).padding(.leading, Self.checkWidth + 22)
            }
        }
    }

    /// A checkbox only where ticking would move something; never on "Only copy".
    @ViewBuilder private func checkbox(_ row: DeleteReviewRow) -> some View {
        if row.isSelectable {
            Toggle("", isOn: Binding(
                get: { checked.contains(row.category) },
                set: { on in
                    if on { checked.insert(row.category) } else { checked.remove(row.category) }
                }))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(row.category.title)
            .accessibilityIdentifier("deleteReview.check.\(row.category.rawValue)")
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private func fileList(_ row: DeleteReviewRow) -> some View {
        LazyVStack(alignment: .leading, spacing: 3) {
            ForEach(row.items.prefix(Self.listCap)) { item in
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(item.path).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(MediaBytes.display(item.sizeBytes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                    Text(item.note).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if row.items.count > Self.listCap {
                Text("…and \((row.items.count - Self.listCap).formatted()) more (every file is listed in catalog.log when it runs)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func toggleExpanded(_ c: DeleteReviewCategory) {
        if expanded.contains(c) { expanded.remove(c) } else { expanded.insert(c) }
    }

    private func tint(_ c: DeleteReviewCategory) -> Color {
        switch c {
        case .copiesElsewhere, .copiesOfEachOther: return .green
        case .markedJunk: return .orange
        case .onlyCopy: return .blue
        case .unsure: return .secondary
        }
    }
}
