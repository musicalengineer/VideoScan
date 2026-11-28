// AVSyncSheet.swift
// "Analyze ▸ Check A/V Sync…" (design docs/design/av_sync_analysis.md §6):
// the sheet shows, for each selected processed file, the original it will be
// compared against — the lineage original (derivedFrom) when the catalog knows
// it — and lets Rick choose one when it does not. Start hands the pairs to
// the one job (AVSyncJob, through MediaFileOperationsCenter.startAVSync).
//
// The candidate search (`AVSyncOriginals.candidates`) is one pass over the
// records, run in the sheet's .task — never in a view body (rule 5).
//
// (For Rick: a SwiftUI sheet ≈ a modal dialog whose model is the @State
// rows; `.task` ≈ an async on-show hook.)

import SwiftUI
import VideoScanCore

struct AVSyncSheetRequest: Identifiable {
    let id = UUID()
    let recordIDs: [UUID]
}

/// Which catalogued files could be a processed file's original.
enum AVSyncOriginals {

    /// A file can take part when it has both picture and sound and is live.
    @MainActor
    static func eligible(_ rec: VideoRecord) -> Bool {
        rec.streamType == .videoAndAudio && rec.removal == nil
    }

    /// The lineage original: the record `rec` was derived from, when it
    /// exists, is a different record, and can take part.
    @MainActor
    static func lineageOriginal(of rec: VideoRecord, lookup: (UUID) -> VideoRecord?) -> VideoRecord? {
        guard let parentID = rec.derivedFrom, parentID != rec.id, let parent = lookup(parentID),
              eligible(parent) else { return nil }
        return parent
    }

    /// The lineage original first, then live picture-and-sound files whose
    /// length is within 5 % (or 10 s) of `rec`'s, closest first, at most
    /// `limit`. One pass over `records`.
    @MainActor
    static func candidates(for rec: VideoRecord, in records: [VideoRecord], lookup: (UUID) -> VideoRecord?,
                           limit: Int = 12) -> [VideoRecord] {
        let lineage = lineageOriginal(of: rec, lookup: lookup)
        let target = rec.durationSeconds
        let tolerance = max(10, 0.05 * target)
        var similar: [(VideoRecord, Double)] = []
        if target > 0 {
            for other in records where other.id != rec.id && other.id != lineage?.id && eligible(other) {
                let gap = abs(other.durationSeconds - target)
                if gap <= tolerance { similar.append((other, gap)) }
            }
        }
        similar.sort { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.filename < $1.0.filename }
        let rest = similar.prefix(max(0, limit - (lineage == nil ? 0 : 1))).map(\.0)
        return (lineage.map { [$0] } ?? []) + rest
    }
}

struct AVSyncSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: AVSyncSheetRequest
    let model: VideoScanModel
    let onStart: ([AVSyncJob.Pair]) -> Void

    struct Candidate: Identifiable, Equatable {
        let id: UUID
        let label: String
    }

    struct Row: Identifiable {
        let id: UUID
        let filename: String
        let hasDigest: Bool
        var candidates: [Candidate]
        var lineageID: UUID?
        var chosen: UUID?
    }

    @State private var rows: [Row] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Check A/V Sync")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("avSync.title")
            Text("Measures whether processing moved each file's sound against its picture, by comparing it with its original. Both files are read; nothing is changed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !loaded {
                ProgressView().controlSize(.small)
            } else if rows.isEmpty {
                Text("None of the selected files has both picture and sound.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach($rows) { $row in rowView($row) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 120, maxHeight: 360)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Check") {
                    let pairs = Self.pairs(rows, lookup: model.record(forID:))
                    dismiss()
                    onStart(pairs)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!rows.contains { $0.chosen != nil })
                .accessibilityIdentifier("avSync.start")
            }
        }
        .padding(24)
        .frame(width: 620)
        .task { load() }
    }

    @ViewBuilder
    private func rowView(_ row: Binding<Row>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.wrappedValue.filename)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            if row.wrappedValue.candidates.isEmpty {
                Text("No original known, and no catalogued file of similar length to compare with.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Original:", selection: row.chosen) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(row.wrappedValue.candidates) { c in Text(c.label).tag(UUID?.some(c.id)) }
                }
                .accessibilityIdentifier("avSync.original")
                if row.wrappedValue.lineageID == nil {
                    Text("The catalog does not know which file this was made from — choose its original.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !row.wrappedValue.hasDigest {
                Text("This file has no whole-file fingerprint yet; the check will ask for Full Hashes first.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// One pass per selected file over the records (main actor, .task).
    private func load() {
        guard !loaded else { return }
        let records = model.records
        rows = request.recordIDs.compactMap { id -> Row? in
            guard let rec = model.record(forID: id), AVSyncOriginals.eligible(rec) else { return nil }
            let lineage = AVSyncOriginals.lineageOriginal(of: rec, lookup: model.record(forID:))
            let found = AVSyncOriginals.candidates(for: rec, in: records, lookup: model.record(forID:))
            let candidates = found.map { other in
                Candidate(id: other.id, label: Self.label(other, isLineage: other.id == lineage?.id))
            }
            return Row(id: rec.id, filename: rec.filename, hasDigest: CatalogCommit.digest(of: rec) != nil,
                       candidates: candidates, lineageID: lineage?.id, chosen: lineage?.id)
        }
        loaded = true
    }

    static func label(_ rec: VideoRecord, isLineage: Bool) -> String {
        let length = Duration.seconds(rec.durationSeconds).formatted(.time(pattern: .hourMinuteSecond))
        let fingerprint = CatalogCommit.digest(of: rec) == nil ? " · no full hash yet" : ""
        return (isLineage ? "Made from: " : "") + "\(rec.filename) (\(length))\(fingerprint)"
    }

    /// The chosen pairs, snapshotted on the main actor.
    static func pairs(_ rows: [Row], lookup: (UUID) -> VideoRecord?) -> [AVSyncJob.Pair] {
        rows.compactMap { row in
            guard let chosen = row.chosen, let processed = lookup(row.id), let original = lookup(chosen) else { return nil }
            return AVSyncJob.Pair(processed: AVSyncSide(record: processed), original: AVSyncSide(record: original))
        }
    }
}
