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

    /// "Archive anyway (I know this file)" — Rick's explicit override for
    /// un-probeable files (the ONE blocking readiness state).
    @State var overrideUnprobeable = false

    /// Archive-name overrides per entry (Promote-Helper, Rick 2026-08-19):
    /// a vertical list — Master / Lossless Copy / Edit Copy — each
    /// with its own name; empty = keep that file's stem. Seeded from the
    /// request (Assess pre-fills suggestions); editable for plain
    /// right-click Promotes too. Slugified at destination time.
    @State private var archiveTitles: [UUID: String] = [:]

    private var plan: ArchivePromotePlan { request.plan }

    /// Confirm is blocked ONLY by un-probeable files without the override
    /// (plus the pre-existing free-space / read-only / identity gates).
    private var blockedByReadiness: Bool {
        plan.unprobeableCount > 0 && !overrideUnprobeable
    }

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

            archiveNameSection

            readinessSection

            warnings

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(plan.entries.count == 1 ? "Promote" : "Promote \(plan.entries.count) Files") {
                    confirm()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.entries.isEmpty || !plan.hasEnoughFreeSpace || model.isReadOnly
                          || model.masterArchiveIdentityMismatch != nil || blockedByReadiness)
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
            // Skips are named, not just counted (Rick 2026-08-16: "I
            // promoted five, four landed — which one and why?").
            ForEach(Array(plan.skipped.enumerated()), id: \.offset) { _, skip in
                warnLine("Skipped \(skip.filename) — \(VideoScanModel.skipReasonLabel(skip.reason))",
                         color: .secondary)
            }
            let _ = (already, inside, offline)
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

    /// How many entries get an editable name row. A huge batch promote is
    /// about moving bytes, not christening — the fields would be noise.
    private static let maxNamingRows = 6

    /// "Names in the archive" — a vertical list, one row per file: role
    /// label (from Assess) or the filename, then the name to use. Empty =
    /// keep that file's own name. Masters on disk are never renamed.
    @ViewBuilder
    private var archiveNameSection: some View {
        if plan.entries.count <= Self.maxNamingRows {
            GroupBox("Names in the archive") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(plan.entries) { entry in
                        namingRow(entry)
                    }
                    if genericNameWarning {
                        Label("A generic filename tells the archive nothing — name it for the people, place, or occasion. The original file is never renamed.",
                              systemImage: "character.cursor.ibeam")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .onAppear { archiveTitles = plan.archiveTitles }
        }
    }

    private func namingRow(_ entry: ArchivePromotePlan.Entry) -> some View {
        let stem = (entry.filename as NSString).deletingPathExtension
        let role = plan.roleLabels[entry.recordID]
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(role ?? stem)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 130, alignment: .trailing)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.filename)
                TextField("keep “\(stem)”", text: titleBinding(entry.recordID))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .accessibilityIdentifier("promoteSheet.archiveName.\(role ?? stem)")
            }
            Text(namePreview(entry))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 138)
        }
    }

    private func titleBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { archiveTitles[id] ?? "" },
                set: { archiveTitles[id] = $0 })
    }

    /// Live preview of this entry's destination filename.
    private func namePreview(_ e: ArchivePromotePlan.Entry) -> String {
        let title = VideoScanModel.normalizedTitle(archiveTitles[e.recordID])
        let stemSource = title ?? (e.filename as NSString).deletingPathExtension
        let ext = (e.filename as NSString).pathExtension
        let stem = "\(e.dateHint.filenamePrefix)_\(ArchivePathResolver.slug(from: stemSource))"
        let name = ext.isEmpty ? stem : "\(stem).\(ext.lowercased())"
        return "→ \(e.folder)/\(name)"
    }

    private var genericNameWarning: Bool {
        plan.entries.contains { e in
            VideoScanModel.normalizedTitle(archiveTitles[e.recordID]) == nil
                && ArchiveNameAdvisor.isGenericStem((e.filename as NSString).deletingPathExtension)
        }
    }

    private func confirm() {
        var confirmed = plan
        confirmed.allowUnprobeable = overrideUnprobeable
        confirmed.archiveTitles = archiveTitles.compactMapValues { VideoScanModel.normalizedTitle($0) }
        fileOpsCenter.startPromote(plan: confirmed, model: model)
        dismiss()
        openWindow(id: "combine")   // Media File Operations window (legacy id)
    }
}
