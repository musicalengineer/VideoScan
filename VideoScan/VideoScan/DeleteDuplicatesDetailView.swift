// DeleteDuplicatesDetailView.swift
// The expanded Delete Duplicates row in Media File Operations (Rick
// 2026-09-20: "clicking on the row reveals a list of files"). A header
// with the counts, the rate and the time left, then one line per file:
// file · size · status chip · tier · keeper (volume: name). Read-only —
// presentation over the job's published plan. No catalog lookup, no media
// work; the only O(n) here is the plan's own rows, capped at
// `visibleCap` with "… and N more".

import SwiftUI

struct DeleteDuplicatesDetailView: View {
    @ObservedObject var job: DeleteDuplicatesJob

    /// Rows drawn at most — a 100k-row plan must not build 100k views.
    static let visibleCap = 2_000

    // Split into named pieces: one inline body timed out CI's type checker
    // budget (DeleteDuplicatesDetailView.swift:18, 1830 ms, nightly run 36121118356).
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let plan = job.plan, !plan.entries.isEmpty {
                entriesTable(plan)
            } else {
                Text(Self.emptyMessageText(isActive: job.state.isActive))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(NSColor.textBackgroundColor).opacity(0.5)))
        .accessibilityIdentifier("mfo.deleteDuplicates.detail")
    }

    /// Shown before the plan has any rows. String-typed on purpose: a
    /// ternary of literals inside Text(...) is slow to type-check.
    static func emptyMessageText(isActive: Bool) -> String {
        isActive ? "Choosing what to delete…" : "Nothing was deleted."
    }

    /// The capped, scrolling table of the plan's files (pinned column titles).
    private func entriesTable(_ plan: DeleteDuplicatesPlan) -> some View {
        let visible: ArraySlice<DeleteDuplicatesPlan.Entry> = plan.entries.prefix(Self.visibleCap)
        let hidden: Int = plan.entries.count - visible.count
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section(header: DeleteDuplicatesTableHeader()) {
                    ForEach(visible) { entry in
                        DeleteDuplicatesEntryRow(entry: entry)
                        Divider()
                    }
                    if hidden > 0 {
                        Text("… and \(hidden) more")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(DeleteDuplicatesTableLayout.rowPadding)
                    }
                }
            }
        }
        .frame(maxHeight: 520)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(NSColor.controlBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.primary.opacity(0.14)))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("DELETE")
                    .font(Font.system(size: 12, weight: .heavy))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(MediaFileOperationKind.deleteDuplicates.badgeColor))
                Text(job.volumeName)
                    .font(.system(size: 15, weight: .semibold))
            }
            Text(job.subtitle)
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
            if let plan = job.plan {
                Text(plan.summaryLine + (plan.snapshotPath.map { " · safety snapshot: \(($0 as NSString).lastPathComponent)" } ?? ""))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("Every file removed is moved aside, read in full once there, and compared with its keeper's whole-file digest at the moment of deletion. The keeper is read once; after that its stored fixity stands in, checked by stat. Tier, on the count of verified copies left behind (keeper, archive copy, siblings whose stored fixity reproduces): three or more → gone now; exactly two → the drive's Trash; fewer → left alone. An archive copy counts but is not required.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func chip(_ entry: DeleteDuplicatesPlan.Entry) -> (label: String, color: Color) {
        switch entry.status {
        case .pending: return ("Pending", .secondary)
        case .verifying: return ("Verifying…", .orange)
        case .verified: return ("Verified", .blue)
        case .deleted: return ("Deleted", .green)
        case .trashed:
            return (entry.trashedOnVolume.map { "In the Trash of \($0)" } ?? "In the Trash", .green)
        case .refused: return ("Refused: \(entry.note)", .red)
        case .failed: return ("Failed: \(entry.note)", .red)
        case .skipped: return ("Skipped: \(entry.note)", .secondary)
        }
    }
}

enum DeleteDuplicatesTableLayout {
    static let sizeWidth: CGFloat = 84
    static let statusWidth: CGFloat = 220
    static let tierWidth: CGFloat = 120
    static let keeperWidth: CGFloat = 240
    static let rowPadding: CGFloat = 10
}

struct DeleteDuplicatesTableHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("File").frame(maxWidth: .infinity, alignment: .leading)
            Text("Size").frame(width: DeleteDuplicatesTableLayout.sizeWidth, alignment: .trailing)
            Text("Status").frame(width: DeleteDuplicatesTableLayout.statusWidth, alignment: .leading)
                .padding(.leading, 12)
            Text("Tier").frame(width: DeleteDuplicatesTableLayout.tierWidth, alignment: .leading)
            Text("Keeper").frame(width: DeleteDuplicatesTableLayout.keeperWidth, alignment: .leading)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, DeleteDuplicatesTableLayout.rowPadding)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct DeleteDuplicatesEntryRow: View {
    let entry: DeleteDuplicatesPlan.Entry

    // Split into typed pieces (stage-0 triage R2, 2026-09-29): the single
    // inline body — five columns, nested optional maps inside `.help`, and
    // string ternaries — took 525 ms to type-check and turned the nightly
    // ratchet red (DeleteDuplicatesDetailView.swift:145, run 36558911631).
    // Every String below is computed once with an explicit type, so the
    // view builder only ever sees `Text(String)`.
    var body: some View {
        let chip: (label: String, color: Color) = DeleteDuplicatesDetailView.chip(entry)
        return HStack(spacing: 0) {
            fileColumn
            sizeColumn
            statusColumn(chip)
            tierColumn
            keeperColumn
        }
        .padding(.horizontal, DeleteDuplicatesTableLayout.rowPadding)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(rowHighlightOpacity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityText(entry, chipLabel: chip.label))
    }

    // MARK: Strings (pure, explicitly typed)

    private var rowHighlightOpacity: Double { entry.status == .verifying ? 0.08 : 0 }

    static func sizeText(_ entry: DeleteDuplicatesPlan.Entry) -> String {
        ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file)
    }

    static func statusHelp(_ entry: DeleteDuplicatesPlan.Entry, chipLabel: String) -> String {
        entry.note.isEmpty ? chipLabel : entry.note
    }

    static func tierHelp(_ entry: DeleteDuplicatesPlan.Entry) -> String {
        guard let reason = entry.tierReason else { return "Decided when the file is reached" }
        guard let remaining = entry.remainingVerifiedCopies else { return reason }
        return "\(reason) (\(remaining) verified copies remain)"
    }

    static func keeperText(_ entry: DeleteDuplicatesPlan.Entry) -> String {
        entry.keeperPath.isEmpty ? "—" : "\(entry.keeperVolumeName): \(entry.keeperFilename)"
    }

    static func accessibilityText(_ entry: DeleteDuplicatesPlan.Entry, chipLabel: String) -> String {
        "\(entry.filename): \(chipLabel)"
    }

    // MARK: Columns

    private var fileColumn: some View {
        Text(entry.filename)
            .font(.system(size: 13, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(entry.path)
    }

    private var sizeColumn: some View {
        Text(Self.sizeText(entry))
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: DeleteDuplicatesTableLayout.sizeWidth, alignment: .trailing)
    }

    private func statusColumn(_ chip: (label: String, color: Color)) -> some View {
        Text(chip.label)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(chip.color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: DeleteDuplicatesTableLayout.statusWidth, alignment: .leading)
            .padding(.leading, 12)
            .help(Self.statusHelp(entry, chipLabel: chip.label))
    }

    private var tierColumn: some View {
        Text(entry.tierLabel)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: DeleteDuplicatesTableLayout.tierWidth, alignment: .leading)
            .help(Self.tierHelp(entry))
    }

    private var keeperColumn: some View {
        Text(Self.keeperText(entry))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: DeleteDuplicatesTableLayout.keeperWidth, alignment: .leading)
            .help(entry.keeperPath)
    }
}
