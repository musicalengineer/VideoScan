import SwiftUI

// MARK: - Cover-Art Music Purge confirmation sheet (2026-07-20)
//
// The morning one-click flow. Opened from Catalog ▸ "Purge Cover-Art
// Music Records…". Shows the LIVE candidate count (recomputed on appear —
// never the historical 2,231) and removes only on an explicit Purge.
//
// The count is captured into @State on `.onAppear` so the body doesn't
// re-run the O(records) scan on every SwiftUI invalidation (the
// no-O(records)-work-in-a-view-body rule). CoverArtMusicPurge.count is a
// cheap single pass, but the sheet is tiny and static once shown, so one
// scan at present time is exactly right.

struct CoverArtMusicPurgeSheet: View {
    @EnvironmentObject var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss

    /// Live candidate count, filled on appear. nil = not yet computed.
    @State private var count: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 22))
                    .foregroundColor(.accentColor)
                Text("Purge Cover-Art Music Records")
                    .font(.title3).bold()
            }

            if let count {
                if count == 0 {
                    Text("No cover-art music records were found in the catalog. Nothing to remove.")
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Remove \(count) cover-art music record\(count == 1 ? "" : "s") from the catalog? Files on disk are untouched.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("These are commercial music files (iTunes purchases) whose embedded cover art was mistaken for video. A recovery snapshot of the catalog is written before anything is removed.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ProgressView().controlSize(.small)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Purge", role: .destructive) {
                    model.purgeCoverArtMusicRecords()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled((count ?? 0) == 0)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            // Recompute live — this is the morning "how many now?" number.
            count = model.coverArtMusicPurgeCount
        }
    }
}
