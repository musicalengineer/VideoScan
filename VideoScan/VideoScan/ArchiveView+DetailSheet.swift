import SwiftUI

// MARK: - Archive Detail Sheet
//
// Split from ArchiveView.swift 2026-08-17. The "Archive Pipeline" section
// still shows the LEGACY archiveStage stamps (healthy / master / backed
// up / ready / archived) — provenance left by earlier reconciles, kept
// visible on purpose (File Journey shows them too). Nothing here writes.

struct ArchiveDetailSheet: View {
    let record: VideoRecord
    let allRecords: [VideoRecord]
    @Environment(\.dismiss) private var dismiss

    private var duplicates: [VideoRecord] {
        guard let gid = record.duplicateGroupID else { return [] }
        return allRecords.filter { $0.duplicateGroupID == gid && $0.id != record.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: record.archiveHealth.icon)
                    .font(.title2)
                    .foregroundColor(record.archiveHealth.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.filename)
                        .font(.headline)
                    Text(record.fullPath)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(record.archiveHealth.color.opacity(0.08))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailSection("Status") {
                        detailRow("Classification", record.mediaDisposition.rawValue,
                                  icon: record.mediaDisposition.icon, color: record.mediaDisposition.color)
                        detailRow("Rating", record.starRating > 0
                                  ? String(repeating: "\u{2605}", count: record.starRating)
                                  : "Not rated")
                        detailRow("Archive Health", record.archiveHealth.label,
                                  icon: record.archiveHealth.icon, color: record.archiveHealth.color)
                    }

                    detailSection("Media") {
                        detailRow("Stream Type", record.streamType.rawValue)
                        if !record.duration.isEmpty { detailRow("Duration", record.duration) }
                        if !record.size.isEmpty { detailRow("Size", record.size) }
                        if !record.resolution.isEmpty { detailRow("Resolution", record.resolution) }
                        if !record.videoCodec.isEmpty { detailRow("Video Codec", record.videoCodec) }
                        if !record.audioCodec.isEmpty { detailRow("Audio Codec", record.audioCodec) }
                        detailRow("Volume", record.volumeName)
                    }

                    detailSection("Archive Pipeline") {
                        pipelineRow("Healthy", record.archiveStage >= .healthy)
                        pipelineRow("Master Assigned", record.archiveStage >= .masterAssigned,
                                    detail: record.masterLocation.isEmpty ? nil : record.masterLocation)
                        pipelineRow("Backed Up", record.archiveStage >= .backedUp,
                                    detail: record.backupDestinations.isEmpty
                                    ? nil
                                    : record.backupDestinations.map { "\($0.name) (\($0.kind.rawValue))" }.joined(separator: ", "))
                        pipelineRow("Ready for Archive", record.archiveStage >= .readyForArchive)
                        pipelineRow("Archived", record.archiveStage >= .archived)
                    }

                    if !record.notes.isEmpty {
                        detailSection("Notes") {
                            Text(record.notes)
                                .font(.system(size: 16))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if !duplicates.isEmpty {
                        detailSection("Copies (\(duplicates.count))") {
                            ForEach(duplicates) { dup in
                                HStack(spacing: 6) {
                                    Image(systemName: VolumeReachability.isReachable(path: dup.fullPath)
                                          ? "externaldrive.fill" : "externaldrive.badge.xmark")
                                        .foregroundColor(VolumeReachability.isReachable(path: dup.fullPath) ? .green : .secondary)
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(dup.filename)
                                            .font(.system(size: 15, weight: .medium))
                                        Text("\(dup.volumeName)\(VolumeReachability.isReachable(path: dup.fullPath) ? "" : " (offline)")")
                                            .font(.system(size: 14))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    if record.pairedWith != nil {
                        detailSection("A/V Pair") {
                            if let partner = record.pairedWith {
                                detailRow("Partner", partner.filename)
                                detailRow("Partner Type", partner.streamType.rawValue)
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 480, height: 520)
    }

    @ViewBuilder
    private func detailSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)
            content()
        }
    }

    private func detailRow(_ label: String, _ value: String,
                           icon: String? = nil, color: Color? = nil) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 16))
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .trailing)
            if let icon = icon {
                Image(systemName: icon)
                    .foregroundColor(color ?? .primary)
                    .frame(width: 16)
            }
            Text(value)
                .font(.system(size: 16, weight: .medium))
            Spacer()
        }
    }

    private func pipelineRow(_ label: String, _ passed: Bool, detail: String? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: passed ? "checkmark.circle.fill" : "circle")
                .foregroundColor(passed ? .green : .secondary.opacity(0.4))
                .frame(width: 16)
            Text(label)
                .font(.system(size: 16, weight: passed ? .medium : .regular))
                .foregroundColor(passed ? .primary : .secondary)
            if let detail = detail {
                Text("— \(detail)")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}
