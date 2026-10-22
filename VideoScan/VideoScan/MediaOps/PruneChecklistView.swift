// PruneChecklistView.swift
// The one list of the one prune plan — shown by "Archived — what next?" and
// by Triage ▸ Clean up ▸ Excess copies (2026-10-21). One flat list grouped
// by archive file: every byte-identical copy that may go has a checkbox
// (checked by default — the person unchecks and confirms); everything else
// is listed with its "no obvious choices" reason and no checkbox. No score,
// no bar, no keeper.
//
// Body discipline: the plan VALUE is already capped (`PrunePlan.shown()`)
// and built off-main; the body walks its rows only — never `records`.
// (For Rick: a `Binding` ≈ a getter/setter pair handed to the child view.)

import SwiftUI
import VideoScanCore

/// Every sentence the prune list and its confirmation show, in one place.
enum PruneWords {
    static func title(_ plan: PrunePlan) -> String {
        let n = plan.offeredCount
        guard n > 0 else { return "No obvious choices" }
        return "\(n) identical cop\(n == 1 ? "y" : "ies") (\(MediaBytes.display(plan.offeredBytes))) outside the archive — uncheck any you want to keep"
    }

    static let noChoices = "Nothing here is a byte-for-byte copy of a verified archive file that can safely go. "
        + "Each line below says why; nothing is offered."

    static let empty = "No copies outside the Master Archive to look at."

    static func actionTitle(count: Int, bytes: Int64) -> String {
        count == 0 ? "Move to Trash" : "Move \(count) to Trash — \(MediaBytes.display(bytes))"
    }

    /// The confirmation's body: what goes, what stays, then the advice.
    static func confirmMessage(_ plan: PrunePlan, selected: Set<UUID>, archiveLabel: String) -> String {
        let n = plan.selectedCount(selected)
        var lines = ["\(n) cop\(n == 1 ? "y" : "ies") (\(MediaBytes.display(plan.selectedBytes(selected)))) go\(n == 1 ? "es" : "") to the Trash. "
                     + "Each is read in full, with its archive copy, and must match byte for byte before it moves. "
                     + "The files in \(archiveLabel) and every copy you left unchecked are untouched; anything moved can be restored from the Trash."]
        if let advice = plan.adviceSentence(after: selected) { lines.append(advice) }
        return lines.joined(separator: "\n\n")
    }
}

struct PruneChecklistView: View {
    let plan: PrunePlan
    @Binding var selected: Set<UUID>
    let archiveLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(PruneWords.title(plan))
                .font(.system(size: 13, weight: .semibold))
                .accessibilityIdentifier("prune.title")
            if plan.offeredCount == 0 {
                Text(plan.items.isEmpty && plan.unarchived.isEmpty ? PruneWords.empty : PruneWords.noChoices)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("prune.noObviousChoices")
            }
            if !plan.reasonSummary.isEmpty {
                Text("No obvious choices: " + plan.reasonSummary.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("prune.reasonCounts")
            }
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(plan.items) { item in
                    PruneItemHeader(item: item, archiveLabel: archiveLabel)
                    ForEach(item.rows) { row in PruneRowView(row: row, selected: $selected) }
                }
                if !plan.unarchived.isEmpty {
                    Text("Not in \(archiveLabel) yet")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.top, 8)
                    ForEach(plan.unarchived) { row in PruneRowView(row: row, selected: $selected) }
                }
                if plan.hiddenRowCount > 0 {
                    Text("… and \(plan.hiddenRowCount) more not listed (never moved from here)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("prune.moreRows")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 120, maxHeight: .infinity)
    }
}

/// One archive file: its name and whether it is verified.
struct PruneItemHeader: View {
    let item: PrunePlan.Item
    let archiveLabel: String

    var body: some View {
        HStack(spacing: 8) {
            Text(item.archive.filename)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(item.digest == nil ? "✗ \(PruneReason.archiveUnverified.text)" : "✓ In \(archiveLabel), verified")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(item.digest == nil ? .orange : .green)
            if item.rows.isEmpty {
                Text("— no other copies").font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding(.top, 8)
    }
}

/// One copy: a checkbox when it is offered, else its reason.
struct PruneRowView: View {
    let row: PrunePlan.Row
    @Binding var selected: Set<UUID>

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { selected.contains(row.id) }, set: { on in
                if on { selected.insert(row.id) } else { selected.remove(row.id) }
            }))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!row.isOffered)
            .opacity(row.isOffered ? 1 : 0.3)
            .accessibilityIdentifier("prune.copy.\(row.id.uuidString).check")
            Text(row.volumeName.isEmpty ? "—" : row.volumeName)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)
            Text(row.fullPath)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(row.isOffered ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(row.fullPath)
            Text(MediaBytes.display(row.sizeBytes))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(row.reason?.text ?? "identical")
                .font(.system(size: 10))
                .foregroundColor(row.isOffered ? .secondary : .orange)
                .lineLimit(1)
                .frame(width: 230, alignment: .leading)
        }
        .padding(.leading, 12)
    }
}
