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

// MARK: - Derivative-suffix auto-detection

/// Strips known derivative suffix tokens from a filename and returns
/// the inferred parent stem, or nil if no known suffix matched.
///
/// Recognized derivative producers:
///   - Topaz Video AI: `_denoise`, `_upscale`, `_<modelcode><digits>` for
///     model codes like `thm`, `nyx`, `hyp`, `dio`, `art`, `prs`, `iri`,
///     `rhe`, `tho`, `gaa` (chained, e.g. `_denoise_thm2_nyx3_hyp1`)
///   - VideoScan Reformat: `_reformatted`
///   - VideoScan Transcode: `.vs.edit`, `.vs.archive`
///
/// Example: `Thanksgiving-Raw_Default_denoise_thm2_nyx3_hyp1.mov` →
/// `Thanksgiving-Raw_Default`.
///
/// Used by the Import sheet to pre-fill the lineage search box and
/// auto-select the parent when the inferred stem uniquely identifies
/// one catalog record.
nonisolated func workspaceImportSuggestedParentStem(forFilename filename: String) -> String? {
    var stem = (filename as NSString).deletingPathExtension
    let original = stem

    // VideoScan markers — single suffix, drop in one shot.
    let vsSuffixes = [".vs.edit", ".vs.archive", "_reformatted"]
    for sfx in vsSuffixes {
        if stem.lowercased().hasSuffix(sfx) {
            stem = String(stem.dropLast(sfx.count))
            return stem.isEmpty ? nil : stem
        }
    }

    // Topaz Video AI tokens. Operation names + 3-letter model codes
    // (Topaz uses short codes like `thm2`, `nyx3`, `hyp1` to identify
    // the chosen AI model variant). Long forms like `artemis` cover the
    // older versions where Topaz wrote the full model name.
    let topazTokens: [String] = [
        // Operations
        "denoise", "upscale", "interpolate", "stabilize", "deinterlace",
        "sharpen", "enhance",
        // 3-letter model codes (followed by 1+ digits)
        "thm", "nyx", "hyp", "dio", "ths", "prs", "art", "iri",
        "rhe", "tho", "gaa", "apo", "chr",
        // Long model names
        "artemis", "proteus", "theia", "iris", "dione", "gaia",
        "hyperion", "chronos", "apollo", "rhea", "nyx"
    ]

    var changed = true
    while changed {
        changed = false
        for tok in topazTokens {
            let pattern = "_\(tok)\\d*$"
            if let range = stem.range(of: pattern,
                                      options: [.regularExpression, .caseInsensitive]) {
                stem = String(stem[..<range.lowerBound])
                changed = true
                break
            }
        }
    }

    return stem == original || stem.isEmpty ? nil : stem
}

/// Looks for exactly one non-archived catalog record whose filename
/// stem (basename minus extension) equals the inferred parent stem
/// case-insensitively. Returns nil if zero or multiple matches —
/// in those cases the user should pick from the narrowed list.
nonisolated func workspaceImportFindExactStemMatch(
    stem: String,
    in records: [VideoRecord]
) -> VideoRecord? {
    let target = stem.lowercased()
    let matches = records.filter { rec in
        guard rec.lifecycleStage != .archived else { return false }
        let recStem = (rec.filename as NSString).deletingPathExtension.lowercased()
        return recStem == target
    }
    return matches.count == 1 ? matches.first : nil
}

/// Builds the Import-context banner text for a record carrying a
/// codec AVFoundation can't decode. Differs from
/// `unplayableLegacyReason` (which is phrased for the Reformat
/// pre-flight) — here we emphasize that import still succeeds and
/// point at the Transcode verb as the in-app fix.
///
/// Returns nil when neither codec is on the legacy list.
nonisolated func workspaceImportLegacyCodecBanner(
    videoCodec: String,
    audioCodec: String
) -> String? {
    let v = videoCodec.lowercased().trimmingCharacters(in: .whitespaces)
    let a = audioCodec.lowercased().trimmingCharacters(in: .whitespaces)
    let badVideo = !v.isEmpty && unplayableLegacyVideoCodecs.contains(v)
    let badAudio = !a.isEmpty && unplayableLegacyAudioCodecs.contains(a)

    switch (badVideo, badAudio) {
    case (false, false):
        return nil
    case (true, false):
        return "Heads up: this file's video uses \(videoCodec), a codec macOS deprecated in 2019. " +
               "It will import fine, but it can't be analyzed in-app or played in modern viewers. " +
               "Run Transcode → For Editing on this file once it's in your workspace to fix this."
    case (false, true):
        return "Heads up: this file's audio uses \(audioCodec), a codec macOS deprecated in 2019. " +
               "It will import fine, but the audio won't play in FCP and the dossier pipeline can't " +
               "transcribe it. Run Transcode → For Editing on this file once it's in your workspace to fix this."
    case (true, true):
        return "Heads up: this file's video (\(videoCodec)) and audio (\(audioCodec)) use codecs macOS " +
               "deprecated in 2019. It will import fine, but it can't be analyzed in-app or played in FCP. " +
               "Run Transcode → For Editing on this file once it's in your workspace to fix both."
    }
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

    @State private var search: String
    @State private var selectedParentID: UUID?

    // Custom init seeds the search field + selection from the imported
    // filename. If the filename matches a known derivative pattern
    // (Topaz suffix, VS Reformat/Transcode markers), we pre-fill the
    // search with the inferred parent stem and — when that stem maps
    // to exactly one non-archived catalog record — pre-select it as
    // the parent. The common case (Topaz output of a cataloged source)
    // becomes "press Enter to commit" instead of "scroll a list of 50".
    init(imported: VideoRecord,
         catalogRecords: [VideoRecord],
         onCommit: @escaping (UUID?) -> Void,
         onCancel: @escaping () -> Void) {
        self.imported = imported
        self.catalogRecords = catalogRecords
        self.onCommit = onCommit
        self.onCancel = onCancel

        let stem = workspaceImportSuggestedParentStem(forFilename: imported.filename)
        _search = State(initialValue: stem ?? "")
        if let stem,
           let unique = workspaceImportFindExactStemMatch(stem: stem,
                                                         in: catalogRecords) {
            _selectedParentID = State(initialValue: unique.id)
        } else {
            _selectedParentID = State(initialValue: nil)
        }
    }

    private var candidates: [VideoRecord] {
        workspaceImportLineageCandidates(in: catalogRecords, matching: search)
    }

    private var deadCodecBanner: String? {
        workspaceImportLegacyCodecBanner(videoCodec: imported.videoCodec,
                                         audioCodec: imported.audioCodec)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let banner = deadCodecBanner {
                deadCodecBannerView(banner)
            }

            Divider()

            Text("If this file was created by processing another catalog file " +
                 "(Topaz Video AI, FCP export, transcode, etc.), pick the source " +
                 "here so the app can track lineage. Otherwise click \"Import (no parent).\"")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if selectedParentID != nil {
                // Auto-detection succeeded — surface it so the user
                // sees what we picked and can change it before committing.
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .foregroundColor(.mint)
                    Text("Suggested parent picked from filename.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            // Search field + candidate list. Empty search shows the
            // first 50 non-archived records; typing narrows it. The
            // init pre-fills search with the inferred parent stem when
            // the imported filename matches a known derivative pattern.
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
