// PromoteToArchiveSheet.swift
// "Promote to Archive" confirmation (design v2 §4): N files, total GB,
// destination folders grouped, warnings (undated / low-confidence /
// already promoted — skipped), the free-space check, and one Confirm
// that enqueues ONE MFO Promote job. Driven by
// `model.pendingPromoteRequest` (bound in ContentView) so the catalog
// right-click and the File ▸ Archive menu share it.

import SwiftUI

struct PromoteToArchiveSheet: View {
    @EnvironmentObject private var model: VideoScanModel
    @EnvironmentObject private var fileOpsCenter: MediaFileOperationsCenter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    let request: ArchivePromoteRequest

    private var plan: ArchivePromotePlan { request.plan }

    private var rootLabel: String {
        VolumeReachability.displayLabel(forPath: plan.rootPath)
            + "/" + MasterArchiveLayout.rootFolderName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "star.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.headline)
                    Text("Verified copies into \(rootLabel) — the originals stay where they are.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }

            if !plan.entries.isEmpty {
                GroupBox("Destination folders") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(plan.foldersGrouped, id: \.folder) { group in
                            HStack {
                                Text(group.folder)
                                    .font(.system(size: 11, design: .monospaced))
                                Spacer()
                                Text("\(group.count) file\(group.count == 1 ? "" : "s")")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }

            warnings

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(plan.entries.count == 1 ? "Promote" : "Promote \(plan.entries.count) Files") {
                    confirm()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.entries.isEmpty || !plan.hasEnoughFreeSpace || model.isReadOnly || model.masterArchiveIdentityMismatch != nil)
                .accessibilityIdentifier("promote.confirm")
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var headline: String {
        let n = plan.entries.count
        let size = PromoteToArchiveJob.humanBytes(plan.totalBytes)
        switch n {
        case 0:  return "Nothing to promote"
        case 1:  return "Promote 1 file (\(size)) to the Master Archive?"
        default: return "Promote \(n) files (\(size)) to the Master Archive?"
        }
    }

    @ViewBuilder
    private var warnings: some View {
        let undated = plan.undatedCount
        let low = plan.lowConfidenceCount
        let already = plan.alreadyPromotedCount
        let offline = plan.skipped.filter { $0.reason == .offline }.count
        let inside = plan.skipped.filter { $0.reason == .insideArchiveRoot }.count
        VStack(alignment: .leading, spacing: 4) {
            if undated > 0 {
                warnLine("\(undated) undated — will land in Undated/ (you can refile later once the date is known)",
                         color: .orange)
            }
            if low > 0 {
                warnLine("\(low) with a low-confidence inferred date — treated as undated rather than filed under a guess",
                         color: .orange)
            }
            if already > 0 {
                warnLine("\(already) already promoted — skipped", color: .secondary)
            }
            if inside > 0 {
                warnLine("\(inside) already inside the archive tree — skipped", color: .secondary)
            }
            if offline > 0 {
                warnLine("\(offline) on a disconnected volume — skipped", color: .secondary)
            }
            if let free = plan.freeBytesAtRoot {
                let ok = plan.hasEnoughFreeSpace
                warnLine(ok
                         ? "Free space on the archive volume: \(PromoteToArchiveJob.humanBytes(free)) — enough (needs about \(PromoteToArchiveJob.humanBytes(plan.requiredBytes)))"
                         : "Not enough free space: \(PromoteToArchiveJob.humanBytes(free)) free, about \(PromoteToArchiveJob.humanBytes(plan.requiredBytes)) needed",
                         color: ok ? .green : .red)
            } else {
                warnLine("Could not read free space on the archive volume — is it connected?", color: .orange)
            }
            if let mismatch = model.masterArchiveIdentityMismatch {
                warnLine(mismatch, color: .red)
            }
            if model.isReadOnly {
                warnLine("This Mac is a read-only viewer of the catalog — promotion runs on the master Mac.", color: .red)
            }
            warnLine("Every copy is verified byte-for-byte (SHA-256) and logged in the manifest. Promoted files become ★★★.",
                     color: .secondary)
        }
    }

    private func warnLine(_ text: String, color: Color) -> some View {
        Label(text, systemImage: color == .green ? "checkmark.circle" : "info.circle")
            .font(.system(size: 12))
            .foregroundColor(color)
    }

    private func confirm() {
        fileOpsCenter.startPromote(plan: plan, model: model)
        dismiss()
        openWindow(id: "combine")   // Media File Operations window (legacy id)
    }
}
