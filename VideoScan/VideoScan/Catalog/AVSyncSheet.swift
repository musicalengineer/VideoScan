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

/// One catalogued file as the original-matching sees it: plain values, so the
/// matching runs off the main actor (review, 2026-11-28).
struct AVSyncFileFacts: Sendable, Equatable, Identifiable {
    let id: UUID
    let filename: String
    let durationSeconds: Double
    let eligible: Bool
    let derivedFrom: UUID?
    let hasDigest: Bool

    @MainActor
    init(record: VideoRecord) {
        id = record.id
        filename = record.filename
        durationSeconds = record.durationSeconds
        eligible = AVSyncOriginals.eligible(record)
        derivedFrom = record.derivedFrom
        hasDigest = CatalogCommit.digest(of: record) != nil
    }

    init(id: UUID = UUID(), filename: String, durationSeconds: Double, eligible: Bool = true,
         derivedFrom: UUID? = nil, hasDigest: Bool = true) {
        self.id = id
        self.filename = filename
        self.durationSeconds = durationSeconds
        self.eligible = eligible
        self.derivedFrom = derivedFrom
        self.hasDigest = hasDigest
    }
}

/// Which catalogued files could be a processed file's original. Pure over
/// `AVSyncFileFacts`; one pass per processed file.
enum AVSyncOriginals {

    /// A file can take part when it has both picture and sound and is live.
    @MainActor
    static func eligible(_ rec: VideoRecord) -> Bool {
        rec.streamType == .videoAndAudio && rec.removal == nil
    }

    /// The lineage original: the file `file` was derived from, when it
    /// exists, is a different file, and can take part.
    static func lineageOriginal(of file: AVSyncFileFacts, byID: [UUID: AVSyncFileFacts]) -> AVSyncFileFacts? {
        guard let parentID = file.derivedFrom, parentID != file.id, let parent = byID[parentID],
              parent.eligible else { return nil }
        return parent
    }

    /// The lineage original first, then live picture-and-sound files whose
    /// length is within 5 % (or 10 s) of `file`'s, closest first, at most
    /// `limit`.
    static func candidates(for file: AVSyncFileFacts, in all: [AVSyncFileFacts], byID: [UUID: AVSyncFileFacts],
                           limit: Int = 12) -> [AVSyncFileFacts] {
        let lineage = lineageOriginal(of: file, byID: byID)
        let target = file.durationSeconds
        let tolerance = max(10, 0.05 * target)
        var similar: [(AVSyncFileFacts, Double)] = []
        if target > 0 {
            for other in all where other.id != file.id && other.id != lineage?.id && other.eligible {
                let gap = abs(other.durationSeconds - target)
                if gap <= tolerance { similar.append((other, gap)) }
            }
        }
        similar.sort { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.filename < $1.0.filename }
        let rest = similar.prefix(max(0, limit - (lineage == nil ? 0 : 1))).map(\.0)
        return (lineage.map { [$0] } ?? []) + rest
    }

    /// The sheet's rows for the selected ids — the whole matching, off the
    /// main actor.
    @concurrent
    static func rows(for selected: [UUID], in all: [AVSyncFileFacts]) async -> [AVSyncSheet.Row] {
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return selected.compactMap { id -> AVSyncSheet.Row? in
            guard let file = byID[id], file.eligible else { return nil }
            let lineage = lineageOriginal(of: file, byID: byID)
            let candidates = candidates(for: file, in: all, byID: byID).map { other in
                AVSyncSheet.Candidate(id: other.id, label: AVSyncSheet.label(other, isLineage: other.id == lineage?.id))
            }
            return AVSyncSheet.Row(id: file.id, filename: file.filename, hasDigest: file.hasDigest,
                                   candidates: candidates, lineageID: lineage?.id, chosen: lineage?.id)
        }
    }
}

struct AVSyncSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: AVSyncSheetRequest
    let model: VideoScanModel
    let onStart: ([AVSyncJob.Pair]) -> Void

    struct Candidate: Identifiable, Equatable, Sendable {
        let id: UUID
        let label: String
    }

    struct Row: Identifiable, Sendable {
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
        .task { await load() }
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

    /// Plain facts are taken on the main actor (one field copy per record);
    /// the matching itself runs off it (`AVSyncOriginals.rows`).
    private func load() async {
        guard !loaded else { return }
        let facts = model.records.map(AVSyncFileFacts.init(record:))
        rows = await AVSyncOriginals.rows(for: request.recordIDs, in: facts)
        loaded = true
    }

    nonisolated static func label(_ file: AVSyncFileFacts, isLineage: Bool) -> String {
        let length = Duration.seconds(max(0, file.durationSeconds)).formatted(.time(pattern: .hourMinuteSecond))
        let fingerprint = file.hasDigest ? "" : " · no full hash yet"
        return (isLineage ? "Made from: " : "") + "\(file.filename) (\(length))\(fingerprint)"
    }

    /// The chosen pairs, snapshotted on the main actor.
    static func pairs(_ rows: [Row], lookup: (UUID) -> VideoRecord?) -> [AVSyncJob.Pair] {
        rows.compactMap { row in
            guard let chosen = row.chosen, let processed = lookup(row.id), let original = lookup(chosen) else { return nil }
            return AVSyncJob.Pair(processed: AVSyncSide(record: processed), original: AVSyncSide(record: original))
        }
    }
}
