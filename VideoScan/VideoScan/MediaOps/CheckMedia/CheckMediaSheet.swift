import SwiftUI

// MARK: - "Check Media…" — choose quick or full (Rick 2026-10-07)
//
// The ellipsis earns its keep: one small choice before a job starts. A
// quick check costs seconds whatever the file's size; a full check reads
// every byte, so the sheet says how much that is before Rick commits.
// Presented with `.sheet(item:)` (never chained isPresented sheets).

struct CheckMediaRequest: Identifiable {
    let id = UUID()
    let records: [VideoRecord]

    /// Total bytes a full check reads (twice for files with picture and
    /// sound). O(selection).
    var totalBytes: Int64 { records.reduce(0) { $0 + $1.sizeBytes } }
}

struct CheckMediaSheet: View {
    @EnvironmentObject private var fileOpsCenter: MediaFileOperationsCenter
    @EnvironmentObject private var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    let request: CheckMediaRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.records.count == 1 ? "Check Media" : "Check \(request.records.count) Files")
                .font(.title2.weight(.semibold))
            if request.records.count == 1 {
                Text(request.records[0].filename)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("A quick check reads the file's header, samples its timing and decodes a few short stretches — seconds, however big the file is. A full check also decodes every frame and measures the sound (reads \(VerifyVideoRules.sizeText(request.totalBytes))).")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("Nothing on disk is changed. Results go on each file's report card (Get Media Info).")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button("Full Check") { start(.full) }
                    .accessibilityIdentifier("checkMedia.full")
                Button("Quick Check") { start(.quick) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("checkMedia.quick")
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 520)
    }

    private func start(_ tier: MediaReportCard.Tier) {
        let records = request.records
        dismiss()
        fileOpsCenter.startedByUser { center in
            for r in records { model.noteMissingFileForUserAction(r) }
            center.startCheckMedia(records: records, tier: tier, model: model)
        }
        MediaFileOperationsWindowOpener.openBehindMain(openWindow)
    }
}
