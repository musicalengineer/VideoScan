import SwiftUI

// MARK: - Ignored content sheet (the override, 2026-09-11)
//
// Rick: "once an item is marked remove/delete/ignore, remember not to
// ingest it again… There should always be an override." This is the
// override: every content the catalog remembers as set aside / removed,
// with a "Put back" that forgets it — the next rescan of its volume
// catalogs the file again. Plain list, same sheet styling as Tidy.
// Files were never deleted by any of this.

struct IgnoredContentSheet: View {
    @ObservedObject var model: VideoScanModel
    @ObservedObject var store: IgnoredContentStore
    @Environment(\.dismiss) private var dismiss

    /// Newest first — sorted ONCE per store revision, never in the body.
    @State private var rows: [IgnoredContentEntry] = []

    private static let addedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 18))
                    .foregroundColor(.orange)
                Text("Ignored content")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("\(store.count)")
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }

            Text("Files you set aside or removed from the catalog are remembered by their contents, so a rescan won't catalog another copy under a new name or folder. Put one back and the next scan of its volume brings it in again.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.isEmpty {
                Text("Nothing is being ignored.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                // Newest first — the row Rick just set aside is at the top.
                List(rows) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.filename)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(entry.friendlyReason) · added \(Self.addedFormatter.string(from: entry.addedAt))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Put back") {
                            model.putBackIgnoredContent(id: entry.id)
                        }
                        .controlSize(.small)
                        .disabled(model.isReadOnly)
                        .help("Forget this content. It is cataloged again on the next scan of its volume — the file is exactly where it was.")
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
                .frame(minHeight: 220, maxHeight: 360)
            }

            Divider()

            HStack {
                Text("Files were never deleted.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 580)
        .onAppear { rows = store.entries.reversed() }
        .onChange(of: store.revision) { rows = store.entries.reversed() }
    }
}
