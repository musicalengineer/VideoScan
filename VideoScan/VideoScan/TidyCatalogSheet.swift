import SwiftUI
import UniformTypeIdentifiers

// MARK: - Tidy Catalog sheet (video-only catalog, 2026-07-15)
//
// Nag-button flow: the sheet opens straight into a DRY-RUN — counts by
// category plus a CSV export of the full would-be-set-aside list —
// and only applies after Rick confirms. Friendly family language, no
// jargon ("set aside", "put back", never "purge"/"migrate"). Nothing is
// ever deleted: set-aside rows are hidden until "Show set-aside files"
// reveals them, and Undo restores the whole batch.

struct TidyCatalogSheet: View {
    @ObservedObject var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss

    @State private var plan: VideoScanModel.TidyCatalogPlan?
    @State private var csvSavedTo: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18))
                    .foregroundColor(.purple)
                Text("Tidy Catalog")
                    .font(.title2.weight(.semibold))
            }

            if let plan {
                if plan.rows.isEmpty {
                    Text("Nothing to tidy — every file in the catalog is a video or audio that belongs to one. 🎉")
                        .font(.body)
                } else {
                    Text("These files aren't home videos, so VideoScan can set them aside. They stay on your drives and in the catalog — just hidden from lists and searches until you want them.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        countRow("photo.stack", .orange,
                                 "Photos and camera images", plan.stillCount)
                        countRow("music.note", .pink,
                                 "Music files", plan.musicCount)
                        countRow("waveform.slash", .gray,
                                 "Audio with no matching video", plan.unlinkedAudioCount)
                        Divider()
                        countRow("checkmark.circle", .green,
                                 "Audio kept — belongs to a video", plan.keptLinkedAudio)
                        countRow("link.circle", .blue,
                                 "Kept — part of a recovered A/V pair", plan.keptPairProtected)
                    }
                    .font(.system(size: 13))

                    HStack(spacing: 8) {
                        Button {
                            exportCSV(plan)
                        } label: {
                            Label("Save Full List as CSV…", systemImage: "square.and.arrow.down")
                        }
                        if let csvSavedTo {
                            Text("Saved to \(csvSavedTo)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Text("Nothing is deleted — you can undo right after, or put files back one by one with “Show set-aside files.”")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking \(model.records.count) cataloged files…")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if let plan, !plan.rows.isEmpty {
                    Button("Set Aside \(plan.rows.count) File\(plan.rows.count == 1 ? "" : "s")") {
                        model.applyTidyCatalog(plan)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            // Dry run — off-main scoring; the sheet shows honest progress
            // until the plan lands (sub-second on M-series at 100k).
            plan = await model.computeTidyCatalogPlan()
        }
    }

    @ViewBuilder
    private func countRow(_ icon: String, _ color: Color, _ label: String, _ count: Int) -> some View {
        GridRow {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 18)
            Text(label)
            Text("\(count)")
                .monospacedDigit()
                .fontWeight(.medium)
                .gridColumnAlignment(.trailing)
        }
    }

    private func exportCSV(_ plan: VideoScanModel.TidyCatalogPlan) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "TidyCatalog_dry_run.csv"
        panel.title = "Save Tidy Catalog List"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try VideoScanModel.tidyPlanCSV(plan).write(to: url, atomically: true, encoding: .utf8)
            csvSavedTo = url.path
        } catch {
            csvSavedTo = "save failed: \(error.localizedDescription)"
        }
    }
}
