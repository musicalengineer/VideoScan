import SwiftUI

// MARK: - MediaPairCompareSheet
//
// Modal sheet for the "Compare These Two Files…" quick check from the
// Catalog tab's row context menu. Mirrors the visual language of
// FrameRipperSheet / CaptionProgressSheet.
//
// Presented via `.sheet(item:)` with a `PairComparePayload` — a single
// Identifiable value drives present/dismiss, deliberately avoiding the
// chained `.sheet(isPresented:)` + asyncAfter race this project has
// hit before.
//
// Lifecycle: the comparison runs inside this view's `.task`, so
// SwiftUI cancels it automatically when the sheet is dismissed — the
// hash loop stops at the next chunk and any running ffmpeg child is
// terminated by ProcessRunner's cancellation handler.

/// The two catalog rows the user right-clicked. Identity is a fresh
/// UUID per invocation so re-comparing the same pair re-presents.
struct PairComparePayload: Identifiable {
    let id = UUID()
    let recordA: VideoRecord
    let recordB: VideoRecord
}

struct MediaPairCompareSheet: View {
    let payload: PairComparePayload

    @Environment(\.dismiss) private var dismiss
    @StateObject private var comparator = MediaPairComparator()

    /// Pure metadata diff from cataloged fields — available instantly,
    /// shown even while the byte/stream comparison is still running.
    private var diffRows: [PairCompareLogic.MetadataDiffRow] {
        PairCompareLogic.metadataDiff(payload.recordA, payload.recordB)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // Title row
            HStack(spacing: 8) {
                if comparator.lastError != nil {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.title2)
                } else if comparator.verdict != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title2)
                } else {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(.tint)
                        .font(.title2)
                }
                Text("Quick Two-File Check")
                    .font(.title3.weight(.semibold))
            }

            // Progress (real bytes-hashed / stream-read fraction —
            // these can be multi-GB files on spinning disks).
            if comparator.isRunning {
                // Indeterminate when there's no duration hint to turn
                // ffmpeg progress into a fraction — never a frozen bar.
                if comparator.isIndeterminate {
                    ProgressView()
                        .progressViewStyle(.linear)
                } else {
                    ProgressView(value: comparator.fraction)
                        .progressViewStyle(.linear)
                }
                Text(comparator.statusText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            // Verdict banner
            if let verdict = comparator.verdict {
                verdictBanner(verdict)
            }

            // Error display
            if let err = comparator.lastError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(.vertical, 4)
            }

            // Side-by-side metadata (from the catalog — no re-probe).
            metadataTable

            // Buttons row
            HStack {
                Spacer()
                if comparator.isRunning {
                    // Dismissing cancels the .task, which stops the
                    // hash loop and terminates any running ffmpeg.
                    Button("Cancel", role: .cancel) { dismiss() }
                } else {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 640)
        .task {
            await comparator.run(recordA: payload.recordA,
                                 recordB: payload.recordB)
        }
    }

    // MARK: - Verdict banner

    private func verdictBanner(_ verdict: PairCompareVerdict) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(for: verdict))
                .font(.title2)
                .foregroundStyle(color(for: verdict))
            VStack(alignment: .leading, spacing: 2) {
                Text(verdict.title)
                    .font(.headline)
                Text(verdict.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color(for: verdict).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private func symbol(for verdict: PairCompareVerdict) -> String {
        switch verdict {
        case .exactDuplicates: return "doc.on.doc.fill"
        case .sameContentDifferentContainer: return "equal.circle.fill"
        case .differentMedia: return "circle.grid.cross"
        case .sameFile: return "doc.fill"
        }
    }

    private func color(for verdict: PairCompareVerdict) -> Color {
        switch verdict {
        case .exactDuplicates: return .green
        case .sameContentDifferentContainer: return .blue
        case .differentMedia: return .orange
        case .sameFile: return .yellow
        }
    }

    // MARK: - Metadata table

    private var metadataTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("")
                    fileHeader(payload.recordA)
                    fileHeader(payload.recordB)
                }
                Divider()
                ForEach(diffRows) { row in
                    GridRow {
                        Text(row.label)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        diffValue(row.valueA, differs: row.differs)
                        diffValue(row.valueB, differs: row.differs)
                    }
                }
            }
        }
    }

    private func fileHeader(_ rec: VideoRecord) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(rec.filename)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(rec.fullPath)
            Text(VolumeReachability.displayLabel(forPath: rec.fullPath))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 230, alignment: .leading)
    }

    /// Differing fields get orange + semibold so the eye lands on what
    /// actually changed between the two copies.
    private func diffValue(_ value: String, differs: Bool) -> some View {
        Text(value)
            .font(.system(size: 12, weight: differs ? .semibold : .regular,
                          design: .monospaced))
            .foregroundStyle(differs ? Color.orange : Color.primary)
            .lineLimit(1)
    }
}
