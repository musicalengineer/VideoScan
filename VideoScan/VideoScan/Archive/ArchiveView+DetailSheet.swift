import SwiftUI

// MARK: - The sheet's file facts, said per file

/// codex P2 (2026-10-16): the sheet showed the resolved copy's path under
/// the row's title and Volume — two files' identities on one card. When
/// the door substituted the archived copy, the header says so and names
/// both files with the row's own state; the Volume facts name each file's
/// own volume. Never one file's field beside another's. Pure.
enum ArchiveDetailWords {

    struct VolumeFact: Identifiable, Equatable {
        let label: String
        let value: String
        var id: String { label }
    }

    static func headerPath(row: VideoRecord, playable: ArchivePlayable?, rowPresence: JourneyPresence?) -> String {
        switch playable {
        case .record(let target)? where target.id != row.id:
            return "Playing the archived copy: \(target.fullPath) (this row: \(row.fullPath), \(rowState(rowPresence)))"
        case .record?, nil:
            return row.fullPath
        case .missing(_, let message)?:
            return message
        }
    }

    /// The row's own state, in a few words, from the probe's answer.
    static func rowState(_ presence: JourneyPresence?) -> String {
        guard let presence else { return "not checked" }
        switch presence {
        case .regularFile, .regularFileThroughLink, .linkToFile: return "also on disk"
        case .brokenLink: return "a dead link"
        case .missing: return "not at its path"
        case .notAFile: return "not a file at its path"
        case .volumeOffline(let volume): return "on \(volume), not connected"
        case .unknown(let reason), .linkTargetUnknown(_, let reason): return "could not be checked: \(reason)"
        }
    }

    /// One Volume fact per file: the copy's and the row's when the door
    /// substituted the copy, else the row's alone.
    static func volumeFacts(row: VideoRecord, playable: ArchivePlayable?) -> [VolumeFact] {
        if case .record(let target)? = playable, target.id != row.id {
            return [VolumeFact(label: "Volume (archived copy)", value: target.volumeName),
                    VolumeFact(label: "Volume (this row)", value: row.volumeName)]
        }
        return [VolumeFact(label: "Volume", value: row.volumeName)]
    }
}

// MARK: - Archive Detail Sheet
//
// Split from ArchiveView.swift 2026-08-17. The "Archive Pipeline" section
// still shows the LEGACY archiveStage stamps (healthy / master / backed
// up / ready / archived) — provenance left by earlier reconciles, kept
// visible on purpose (File Journey shows them too). Nothing here writes.

struct ArchiveDetailSheet: View {
    let record: VideoRecord
    let allRecords: [VideoRecord]
    /// The door's answer for this row (ArchivePlayable): the archived
    /// copy's path for a promotion source, or the "not at its path" words
    /// when neither file is on disk. nil = show the row's own path.
    var playable: ArchivePlayable? = nil
    /// What the disk said about THIS row's own path (one lstat at sheet
    /// open) — named in the header when the door substituted the copy.
    var rowPresence: JourneyPresence? = nil
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
                    Text(headerPathLine)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(headerPathColor)
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
                        // Each file's own volume, labelled — never the
                        // copy's volume under the row's name.
                        ForEach(ArchiveDetailWords.volumeFacts(row: record, playable: playable)) { fact in
                            detailRow(fact.label, fact.value)
                        }
                    }

                    detailSection("Archive Pipeline") {
                        pipelineRow("Healthy", record.archiveStage >= .healthy)
                        // Stored as "Master", shown as "Archived" (2026-10-26).
                        pipelineRow(ArchiveStage.masterAssigned.displayName, record.archiveStage >= .masterAssigned,
                                    detail: record.masterLocation.isEmpty ? nil : record.masterLocation)
                        pipelineRow("Backed Up", record.archiveStage >= .backedUp,
                                    detail: record.backupDestinations.isEmpty
                                    ? nil
                                    : record.backupDestinations.map { "\($0.name) (\($0.kind.rawValue))" }.joined(separator: ", "))
                        pipelineRow("Ready for Archive", record.archiveStage >= .readyForArchive)
                        // The legacy `.archived` stamp (never written since 2026-09-22) —
                        // named apart so it never reads as a second "Archived".
                        pipelineRow("Archived (legacy stamp)", record.archiveStage >= .archived)
                        if let archived = archivedAtForDetail {
                            detailRow("Archived On", archived.formatted(date: .long, time: .shortened))
                        }
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

    /// Orange when the header carries the "not at its path" words.
    private var headerPathColor: Color {
        playable?.message == nil ? .secondary : .orange
    }

    /// The file facts' path: the row's own, or — when the door substituted
    /// the archived copy — both, said so (ArchiveDetailWords).
    private var headerPathLine: String {
        ArchiveDetailWords.headerPath(row: record, playable: playable, rowPresence: rowPresence)
    }

    /// This record's archive date, or its promoted copy's (the copy is the
    /// record whose derivedFrom points here with the Promote derivation).
    private var archivedAtForDetail: Date? {
        if let own = record.resolvedArchivedAt { return own }
        return allRecords.first {
            $0.derivedFrom == record.id && $0.derivationKind == ArchivePromotion.derivationKind
        }?.resolvedArchivedAt
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
