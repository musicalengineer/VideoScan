// DeleteDuplicatesDetailView.swift
// The expanded Delete Duplicates row in Media File Operations (Rick
// 2026-09-20: "clicking on the row reveals a list of files"). A header
// with the counts, the rate and the time left, then one line per file:
// file · size · status chip · keeper (volume: name). Read-only —
// presentation over the job's published plan. No catalog lookup, no media
// work; the only O(n) here is the plan's own rows, capped at
// `visibleCap` with "… and N more".

import SwiftUI

struct DeleteDuplicatesDetailView: View {
    @ObservedObject var job: DeleteDuplicatesJob

    /// Rows drawn at most — a 100k-row plan must not build 100k views.
    static let visibleCap = 2_000

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let plan = job.plan, !plan.entries.isEmpty {
                let visible = plan.entries.prefix(Self.visibleCap)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section(header: DeleteDuplicatesTableHeader()) {
                            ForEach(visible) { entry in
                                DeleteDuplicatesEntryRow(entry: entry)
                                Divider()
                            }
                            if plan.entries.count > visible.count {
                                Text("… and \(plan.entries.count - visible.count) more")
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
            } else {
                Text(job.state.isActive ? "Choosing what to delete…" : "Nothing was deleted.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(NSColor.textBackgroundColor).opacity(0.5)))
        .accessibilityIdentifier("mfo.deleteDuplicates.detail")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("DELETE")
                    .font(Font.system(size: 12, weight: .heavy))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.red))
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
            Text("Every file removed is read in full and compared with its keeper's whole-file digest at the moment of deletion. The keeper is read once; after that its stored fixity stands in, checked by stat.")
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
        case .refused: return ("Refused: \(entry.note)", .red)
        case .failed: return ("Failed: \(entry.note)", .red)
        case .skipped: return ("Skipped: \(entry.note)", .secondary)
        }
    }
}

enum DeleteDuplicatesTableLayout {
    static let sizeWidth: CGFloat = 84
    static let statusWidth: CGFloat = 220
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

    var body: some View {
        let chip = DeleteDuplicatesDetailView.chip(entry)
        HStack(spacing: 0) {
            Text(entry.filename)
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(entry.path)
            Text(ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: DeleteDuplicatesTableLayout.sizeWidth, alignment: .trailing)
            Text(chip.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(chip.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: DeleteDuplicatesTableLayout.statusWidth, alignment: .leading)
                .padding(.leading, 12)
                .help(entry.note.isEmpty ? chip.label : entry.note)
            Text(entry.keeperPath.isEmpty ? "—" : "\(entry.keeperVolumeName): \(entry.keeperFilename)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: DeleteDuplicatesTableLayout.keeperWidth, alignment: .leading)
                .help(entry.keeperPath)
        }
        .padding(.horizontal, DeleteDuplicatesTableLayout.rowPadding)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(entry.status == .verifying ? 0.08 : 0))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.filename): \(chip.label)")
    }
}
