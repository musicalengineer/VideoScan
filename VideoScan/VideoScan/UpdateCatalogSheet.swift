// UpdateCatalogSheet.swift
// The ONE door for "someone moved things outside the app" (Rick
// 2026-08-17). Lists the eligible scan targets with checkboxes, Preview
// runs the deferred rescan + dry-run merge per target, Apply commits.
// A pure function of `model.updateCatalogRows` — every decision and all
// O(records) work live in VideoScanModel+UpdateCatalog.swift; the sheet
// only renders values and forwards button presses.
//
// Presented from ContentView via `.sheet(isPresented:
// $model.showUpdateCatalogSheet)`; opened by the Catalog menu, the
// volume-rename badge, the "looks moved" banner, and the target context
// menus. Closing (Cancel / ×) discards previewed-but-unapplied results.

import SwiftUI

struct UpdateCatalogSheet: View {
    @EnvironmentObject var model: VideoScanModel

    private var rows: [UpdateCatalogRow] { model.updateCatalogRows }
    private var anyBusy: Bool { rows.contains { $0.phase.isBusy } }
    private var canPreview: Bool {
        !anyBusy && rows.contains { $0.isSelected && $0.phase == .idle }
    }
    private var canApply: Bool {
        !anyBusy && rows.contains {
            $0.phase.isPreviewed || ($0.isSelected && $0.phase.isRenamePending)
        }
    }
    private var allDone: Bool {
        !rows.isEmpty && rows.allSatisfy { $0.phase.isDone || !$0.isSelected }
            && rows.contains { $0.phase.isDone }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if rows.isEmpty {
                emptyState
            } else {
                rowList
                legend
            }
            buttons
        }
        .padding(20)
        .frame(width: 720)
        .frame(minHeight: 320)
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath.circle")
                    .font(.system(size: 22))
                    .foregroundColor(.accentColor)
                Text("Update Catalog")
                    .font(.title2.weight(.semibold))
            }
            Text("If files or folders were moved, renamed, added or deleted outside VideoScan, this rescans the drives you pick and relinks each catalog record to wherever its file is now — tags, people, notes and dates stay with the file. Preview first; nothing changes until you press Apply.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("No drives to update")
                .font(.headline)
            Text("Connect a cataloged drive (retired drives are skipped) and reopen Update Catalog.")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private var rowList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    UpdateCatalogRowView(row: row,
                                         target: model.scanTargets.first { $0.id == row.id },
                                         isSelected: selectionBinding(row.id))
                    Divider()
                }
            }
        }
        .frame(minHeight: 140, maxHeight: 360)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
    }

    private var legend: some View {
        Text("moved = relinked to its new place · new = fresh record · missing = file gone (pruned only behind the mass-deletion safety net, which snapshots the catalog first) · unchanged = same place · ambiguous = several identical files; left alone for you to review.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var buttons: some View {
        HStack {
            if anyBusy {
                ProgressView().controlSize(.small)
                Text("Working…").font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button(allDone ? "Done" : "Cancel", role: .cancel) {
                model.closeUpdateCatalog()
            }
            .keyboardShortcut(.cancelAction)
            .help(allDone ? "Close." : "Close without applying — any previewed results are discarded and the catalog stays as it is.")
            Button("Preview") {
                model.startUpdateCatalogPreview()
            }
            .disabled(!canPreview || model.isReadOnly)
            .help("Rescan the checked drives and show what would change. Nothing is written yet.")
            .accessibilityIdentifier("updateCatalog.preview")
            Button("Apply") {
                Task { await model.applyUpdateCatalog() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canApply || model.isReadOnly)
            .help("Commit the previewed changes (and any pending volume renames).")
            .accessibilityIdentifier("updateCatalog.apply")
        }
    }

    private func selectionBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { model.updateCatalogRows.first { $0.id == id }?.isSelected ?? false },
            set: { newValue in
                if let i = model.updateCatalogRows.firstIndex(where: { $0.id == id }) {
                    model.updateCatalogRows[i].isSelected = newValue
                }
            })
    }
}

// MARK: - Row

/// One target row. Observes the live CatalogScanTarget only for scan
/// progress (filesScanned / filesFound) — everything else comes from the
/// value row.
struct UpdateCatalogRowView: View {
    let row: UpdateCatalogRow
    let target: CatalogScanTarget?
    @Binding var isSelected: Bool
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Toggle("", isOn: $isSelected)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(row.phase.isBusy || row.phase.isDone)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.displayName)
                            .font(.system(size: 13, weight: .semibold))
                        if row.phase.isRenamePending {
                            renameChip
                        }
                    }
                    Text(row.targetPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                statusView
            }
            if showDetails, case .previewed(let p) = row.phase {
                previewDetails(p)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var renameChip: some View {
        Text("Volume renamed")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).stroke(Color.orange.opacity(0.5)))
    }

    @ViewBuilder
    private var statusView: some View {
        switch row.phase {
        case .idle:
            if let n = row.missingCount {
                Text(n == 0 ? "All files where expected"
                             : "\(n) file\(n == 1 ? "" : "s") not where expected")
                    .font(.system(size: 11))
                    .foregroundColor(n == 0 ? .secondary : .orange)
            } else {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Checking…").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
        case .scanning:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                if let target {
                    UpdateCatalogScanProgress(target: target)
                } else {
                    Text("Rescanning…").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
        case .previewed(let p):
            Button {
                showDetails.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(Self.summaryLine(p))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(p.ambiguous.isEmpty && !p.tripwireWouldFire ? .primary : .orange)
                    if !p.relinks.isEmpty || !p.ambiguous.isEmpty || !p.note.isEmpty {
                        Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Click for the list of relinks and anything ambiguous.")
        case .applying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Applying…").font(.system(size: 11)).foregroundColor(.secondary)
            }
        case .applied(let s):
            Text("Applied — \(s.moved) moved, \(s.new) new, \(s.pruned) pruned, \(s.unchanged) unchanged\(s.ambiguous > 0 ? ", \(s.ambiguous) ambiguous" : "")")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.green)
        case .renamePending(let c):
            Text("\(c.oldVolumeName) is now \(c.newVolumeName) — \(c.matchingRecords) record\(c.matchingRecords == 1 ? "" : "s") will follow the rename")
                .font(.system(size: 11))
                .foregroundColor(.orange)
        case .renameApplied:
            Text("Rename applied").font(.system(size: 11, weight: .medium)).foregroundColor(.green)
        case .failed(let msg):
            Text(msg).font(.system(size: 11)).foregroundColor(.red)
        }
    }

    static func summaryLine(_ p: VideoScanModel.ScanMergePreview) -> String {
        if !p.note.isEmpty { return p.note }
        var s = "\(p.moved) moved (relinked) · \(p.new) new · \(p.missing) missing · \(p.unchanged) unchanged"
        if !p.ambiguous.isEmpty { s += " · \(p.ambiguous.count) ambiguous — review" }
        if p.retainedInvisible > 0 { s += " · \(p.retainedInvisible) kept (not visible to scan options)" }
        if !p.scanWasComplete { s += " · scan incomplete: nothing will be pruned" }
        if p.tripwireWouldFire { s += " · mass-deletion safety net will snapshot first" }
        return s
    }

    @ViewBuilder
    private func previewDetails(_ p: VideoScanModel.ScanMergePreview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !p.relinks.isEmpty {
                Text("Relinks\(p.moved > p.relinks.count ? " (first \(p.relinks.count) of \(p.moved))" : "")")
                    .font(.system(size: 11, weight: .semibold))
                ForEach(p.relinks, id: \.self) { r in
                    HStack(spacing: 4) {
                        Image(systemName: r.crossRoot ? "arrow.right.arrow.left" : "arrow.turn.down.right")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Text("\(r.oldPath) → \(r.newPath)")
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            if !p.ambiguous.isEmpty {
                Text("Ambiguous — review (left as new + missing)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.orange)
                ForEach(Array(p.ambiguous.enumerated()), id: \.offset) { _, a in
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(a.candidatePaths, id: \.self) { c in
                            Text("missing: \(c)").font(.system(size: 10, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                        }
                        ForEach(a.addedPaths, id: \.self) { n in
                            Text("new:     \(n)").font(.system(size: 10, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .padding(.bottom, 2)
                }
            }
        }
        .padding(.leading, 28)
        .padding(.top, 2)
    }
}

/// Live "n / m files" while a deferred rescan runs. Observes only the one
/// target so the rest of the sheet does not re-render per file.
struct UpdateCatalogScanProgress: View {
    @ObservedObject var target: CatalogScanTarget
    var body: some View {
        Text(target.filesFound > 0
             ? "Rescanning… \(target.filesScanned) / \(target.filesFound)"
             : "Rescanning… \(target.status.rawValue)")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .monospacedDigit()
    }
}
