import SwiftUI

// MARK: - Workbench Tab
//
// Surfaces records with `lifecycleStage == .workbench` — currently the
// output of the Combine workflow (and any future Repair / Transcode
// pipelines that produce new files). The whole point is: you ran an
// overnight Combine batch, you want to see what came out, spot-check
// it, and either promote good results to the Archive or discard test
// artifacts. Without this view those rows were silently mixed into
// the main Catalog with no way to tell "I made this 10 minutes ago"
// from "scanned six months ago".
//
// Modeled on ArchiveView's filter+table+context-menu shape; simpler
// because Workbench has no sub-categories — every row is the same
// kind of "in-progress" item.

struct WorkbenchView: View {
    @EnvironmentObject var model: VideoScanModel
    @State private var searchText = ""
    @State private var selectedIDs: Set<UUID> = []
    // dateModifiedRaw is Date? and Optional<Date> isn't directly
    // Comparable, so we sort by the ISO 8601 string form whose
    // lexicographic order matches chronological order.
    @State private var sortOrder = [KeyPathComparator(\VideoRecord.dateModified, order: .reverse)]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if filteredRecords.isEmpty {
                emptyState
            } else {
                fileTable(rows: filteredRecords)
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "hammer.fill")
                .foregroundColor(.orange)
            Text("Workbench")
                .font(.headline)
            Text("(\(workbenchRecords.count))")
                .foregroundColor(.secondary)
                .font(.system(size: 13, design: .monospaced))

            Spacer()

            if !selectedIDs.isEmpty {
                bulkActionsToolbar
                Divider().frame(height: 18)
            }

            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var bulkActionsToolbar: some View {
        HStack(spacing: 6) {
            Text("\(selectedIDs.count) selected")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Button {
                let recs = selectedRecords
                model.promoteWorkbenchToArchive(recs)
                selectedIDs = []
            } label: {
                Label("Promote", systemImage: "archivebox.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Promote selected files to the Archive tab")

            Button {
                let recs = selectedRecords
                model.dropWorkbenchToCatalog(recs)
                selectedIDs = []
            } label: {
                Label("Drop to Catalog", systemImage: "tray.and.arrow.down.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Treat as ordinary media — moves off the Workbench but keeps the file")

            Button(role: .destructive) {
                let recs = selectedRecords
                let n = model.discardWorkbench(recs)
                selectedIDs = []
                if n > 0 {
                    model.log("Workbench: discarded \(n) file\(n == 1 ? "" : "s") to Trash")
                }
            } label: {
                Label("Discard", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Move the file to Trash and remove the record (recoverable from Finder until emptied)")
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "hammer")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("No work in progress")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Run a Combine batch from the Catalog tab — new files land here for review before you promote them to the Archive.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Table

    private func fileTable(rows: [VideoRecord]) -> some View {
        let sorted = rows.sorted(using: sortOrder)
        return Table(sorted, selection: $selectedIDs, sortOrder: $sortOrder) {
            TableColumn("Filename", value: \.filename) { rec in
                Text(rec.filename)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.green)
                    .lineLimit(1)
                    .help(rec.fullPath)
            }
            .width(min: 220, ideal: 320)

            TableColumn("Duration", value: \.durationSeconds) { rec in
                Text(rec.duration.isEmpty ? "—" : rec.duration)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .width(min: 60, ideal: 75)

            TableColumn("Size", value: \.sizeBytes) { rec in
                Text(rec.size.isEmpty ? "—" : rec.size)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Video Codec", value: \.videoCodec)
                .width(min: 80, ideal: 110)

            TableColumn("Resolution", value: \.resolution)
                .width(min: 80, ideal: 100)

            TableColumn("Produced", value: \.dateModified) { rec in
                if let d = rec.dateModifiedRaw {
                    Text(Self.relativeDateFmt.localizedString(for: d, relativeTo: Date()))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .help(d.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text("—").foregroundColor(.secondary)
                }
            }
            .width(min: 100, ideal: 130)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            let recs = ids.compactMap { id in rows.first { $0.id == id } }
            MediaOpener.openInQuickTime(recs)
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<UUID>) -> some View {
        let recs = ids.compactMap { id in model.records.first { $0.id == id } }

        Button {
            model.promoteWorkbenchToArchive(recs)
            selectedIDs = []
        } label: {
            Label("Promote to Archive", systemImage: "archivebox.fill")
        }

        Button {
            model.dropWorkbenchToCatalog(recs)
            selectedIDs = []
        } label: {
            Label("Drop to Catalog", systemImage: "tray.and.arrow.down.fill")
        }

        Divider()

        Button {
            if let rec = recs.first {
                NSWorkspace.shared.selectFile(rec.fullPath, inFileViewerRootedAtPath: "")
            }
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        .disabled(recs.count != 1)

        Divider()

        Button(role: .destructive) {
            let n = model.discardWorkbench(recs)
            selectedIDs = []
            if n > 0 {
                model.log("Workbench: discarded \(n) file\(n == 1 ? "" : "s") to Trash")
            }
        } label: {
            Label("Discard (move to Trash)", systemImage: "trash")
        }
    }

    // MARK: - Filtering

    private var workbenchRecords: [VideoRecord] {
        pfActiveRecords(model.records).filter { $0.lifecycleStage == .workbench }
    }

    private var filteredRecords: [VideoRecord] {
        guard !searchText.isEmpty else { return workbenchRecords }
        let q = searchText.lowercased()
        return workbenchRecords.filter {
            $0.filename.lowercased().contains(q) ||
            $0.fullPath.lowercased().contains(q) ||
            $0.videoCodec.lowercased().contains(q) ||
            $0.notes.lowercased().contains(q)
        }
    }

    private var selectedRecords: [VideoRecord] {
        selectedIDs.compactMap { id in model.records.first { $0.id == id } }
    }

    private static let relativeDateFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
