import SwiftUI

// MARK: - Unrelated Audio Purge confirmation sheet (2026-07-21)
//
// Opened from Catalog ▸ "Purge Non-Video Audio Junk…". Shows the LIVE
// candidate count AND a breakdown of the top parent directories among the
// candidates, so Rick can verify the doomed set is sample libraries
// (Logic Pro Samples, Apple Loops, Omnisphere) and NOT family media
// before clicking Purge. Removes only on an explicit Purge.
//
// The summary (count + top trees) is captured into @State on `.onAppear`
// so the body doesn't re-run the O(records) scan on every SwiftUI
// invalidation (the no-O(records)-work-in-a-view-body rule). It is
// computed ONCE, in a single combined pass, at present time — exactly
// right for a small static sheet.

struct UnrelatedAudioPurgeSheet: View {
    @EnvironmentObject var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss

    /// Live summary (count + top trees), filled on appear. nil = not yet
    /// computed.
    @State private var summary: UnrelatedAudioPurge.Summary? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 22))
                    .foregroundColor(.accentColor)
                Text("Purge Non-Video Audio Junk")
                    .font(.title3).bold()
            }

            if let summary {
                // Local Int binding (not a collection `.count`) so the
                // SwiftLint empty_count rule doesn't misfire on `== 0`.
                let n = summary.count
                if n < 1 {
                    Text("No unrelated audio records were found in the catalog. Nothing to remove.")
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Remove \(n) unrelated audio record\(n == 1 ? "" : "s") from the catalog? Files on disk are untouched.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("These are audio-only files with no relationship to any video — Logic Pro sample libraries, Apple Loops, Omnisphere / Pro Tools samples, standalone music. Audio that might belong to a video (same folder, matching name, or shared Avid UMID) is KEPT.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    treesBreakdown(summary.topTrees, total: summary.count)

                    Text("A recovery snapshot is saved first (its path is logged to the console). There is no in-app Undo — to restore, quit and copy that snapshot back over catalog.json (or simply re-scan the volume).")
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
                    model.purgeUnrelatedAudioRecords()
                    dismiss()
                }
                // Deliberately NOT the default action: this irreversibly
                // removes records, so a reflexive Enter must not trigger it.
                // Escape (Cancel) is the only keyboard path.
                .disabled((summary?.count ?? 0) == 0)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            // Recompute live — count + top trees in one combined pass.
            summary = model.unrelatedAudioPurgeSummary()
        }
    }

    /// The "what will be removed" breakdown: the top parent directories
    /// holding the most candidates, with counts. Read-only, cheap — the
    /// values were computed alongside the count in `summary`.
    @ViewBuilder
    private func treesBreakdown(_ trees: [UnrelatedAudioPurge.TreeCount], total: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Top locations to be removed:")
                .font(.callout).bold()
            ForEach(trees) { tree in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(tree.count)")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(minWidth: 60, alignment: .trailing)
                    Text(tree.path.isEmpty ? "(no path)" : tree.path)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(tree.path)
                }
            }
            let shown = trees.reduce(0) { $0 + $1.count }
            if shown < total {
                Text("…and \(total - shown) more in other locations.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(6)
    }
}
