import SwiftUI

// MARK: - Workspace Import — Pass B
//
// The user picks a media file via NSOpenPanel, we probe it, then ask
// "Is this derived from a file already in the catalog?". If yes, the
// lineage picker shows a searchable list of candidate parents and the
// chosen one's UUID lands in `derivedFrom`. Either way, the new record
// is appended to `model.records` with `workspaceActive = true` and the
// catalog is saved.
//
// Sheet driver follows the JunkSheet pattern in JunkDeleteAction.swift
// — a single Identifiable enum + `.sheet(item:)`. Chained
// `.sheet(isPresented:)` modifiers race when the user clicks-and-types
// quickly; that bug class is documented in
// `feedback_chained_sheet_antipattern`.

/// Drives the post-probe lineage sheet. The associated `VideoRecord`
/// is the freshly probed record (not yet in the catalog) — the sheet
/// mutates it (`derivedFrom = parent.id` or leaves nil) and the
/// `onCommit` closure appends it to `model.records`.
enum WorkspaceImportSheet: Identifiable {
    case lineagePicker(VideoRecord)

    // Same id across cases so SwiftUI keeps the modal context alive on
    // re-entry. We never have two cases active, but matching the
    // JunkSheet pattern makes any future expansion safe by default.
    // `String` ≈ a stable hash key.
    var id: String { "workspaceImportSheet" }
}

// MARK: - Lineage candidate filter (testable)

/// Returns the list of records that can serve as a parent for a newly
/// imported workspace file. Excludes archived files (we don't derive
/// new work from archived sources) and applies the search query as a
/// case-insensitive filename substring match. Cap at 50 results for
/// list responsiveness.
///
/// Extracted as a free function so the unit test can pin the predicate
/// without spinning up a SwiftUI sheet. `nonisolated` ≈ "callable from
/// any thread, no actor hop" — pure logic, no shared state.
nonisolated func workspaceImportLineageCandidates(
    in records: [VideoRecord],
    matching query: String,
    limit: Int = 50
) -> [VideoRecord] {
    // Archived files are deliberately frozen — they represent the
    // long-term vault and shouldn't be parents of new in-progress work.
    let eligible = records.filter { $0.lifecycleStage != .archived }

    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let matched: [VideoRecord]
    if trimmed.isEmpty {
        matched = eligible
    } else {
        let q = trimmed.lowercased()
        matched = eligible.filter { $0.filename.lowercased().contains(q) }
    }
    // Stable order: by filename ascending. Matches what the user would
    // expect when typing into a list — the same query → the same order
    // every time, no LRU surprises.
    let sorted = matched.sorted { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }
    return Array(sorted.prefix(limit))
}

// MARK: - Lineage Picker Sheet View

/// Sheet shown after probing a freshly imported file. Two paths:
///   • "Not derived from anything" — `onCommit(nil)` — record imported
///     with `derivedFrom == nil`.
///   • Pick a parent from the searchable list — `onCommit(parent.id)`.
///
/// The dead-codec banner is informational only — it never blocks the
/// import. The user might be importing a Topaz output that genuinely
/// has a weird codec they want flagged for later reformat.
struct WorkspaceImportLineageSheet: View {
    let imported: VideoRecord
    let catalogRecords: [VideoRecord]
    let onCommit: (UUID?) -> Void
    let onCancel: () -> Void

    @State private var search: String = ""
    @State private var selectedParentID: UUID? = nil

    private var candidates: [VideoRecord] {
        workspaceImportLineageCandidates(in: catalogRecords, matching: search)
    }

    private var deadCodecBanner: String? {
        unplayableLegacyReason(videoCodec: imported.videoCodec,
                               audioCodec: imported.audioCodec)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let banner = deadCodecBanner {
                deadCodecBannerView(banner)
            }

            Divider()

            Text("Is this file derived from a file already in the catalog?")
                .font(.system(size: 13, weight: .medium))

            // Search field + candidate list. Empty search shows the
            // first 50 non-archived records; typing narrows it.
            TextField("Search by filename", text: $search)
                .textFieldStyle(.roundedBorder)

            candidateList

            footer
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 480, idealHeight: 560)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "hammer.fill")
                .font(.title)
                .foregroundColor(.mint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Import to Workspace")
                    .font(.title3.weight(.semibold))
                Text(imported.filename)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    private func deadCodecBannerView(_ message: String) -> some View {
        // Informational, not blocking. Mirrors the catalog's red `!`
        // glyph but in banner form. Uses Text-with-icon rather than
        // Label so we can color the parts independently.
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var candidateList: some View {
        // Native List w/ single-selection. Keeping the row layout flat
        // (filename + volume on one line) makes typing-to-narrow feel
        // snappy at 50 rows. `Optional<UUID>` selection ≈ a C++
        // `optional<UUID>` — nil means "nothing chosen".
        List(selection: $selectedParentID) {
            ForEach(candidates, id: \.id) { rec in
                HStack(spacing: 8) {
                    Image(systemName: rec.workspaceActive ? "hammer.fill" : "film")
                        .foregroundColor(rec.workspaceActive ? .mint : .secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rec.filename)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(rec.volumeName.isEmpty ? rec.directory : rec.volumeName)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .tag(rec.id)
            }
            if candidates.isEmpty {
                Text(search.isEmpty
                     ? "No catalog records to choose from."
                     : "No matches for \"\(search)\".")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .listStyle(.bordered)
        .frame(minHeight: 240)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Cancel", role: .cancel) {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button {
                onCommit(nil)
            } label: {
                Label("Import (no parent)", systemImage: "square.and.arrow.down")
            }
            .help("Add to catalog with no lineage link — this is an original.")

            Button {
                onCommit(selectedParentID)
            } label: {
                Label("Import with parent", systemImage: "link")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedParentID == nil)
            .help("Link this file to the selected parent record.")
        }
    }
}
