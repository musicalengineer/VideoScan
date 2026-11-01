// CatalogTidy.swift — Catalog ▸ Tidy Catalog… (Rick 2026-11-01): the
// one-off hygiene actions, off the menu and into one sheet, each with its
// live count and a Run through its EXISTING engine (rule 4):
//
//   Non-video media rows          NonVideoMediaPurge — Run… opens today's
//                                 "Purge Non-Video Media" dialog (pick the
//                                 extensions; it removes only on Purge)
//   Duplicate groups to split     MediaFileOperationsCenter
//   by full hash                  .splitDuplicateGroupsKeepingSameFootage —
//                                 the retired menu item's exact call
//   Degenerate OCR captions       GH #402 — counted only: the caption path
//   stored before #402            refuses them as evidence; no cleanup
//                                 engine exists yet, so the row says so
//                                 and has no Run
//
// The menu item reads "Tidy Catalog… (N)" with N = the sum, and is not
// there when every count is 0 (CatalogMenuLayout).
//
// COUNTS. Computed in the coverage pass the Catalog Status snapshot already
// rides (VideoScanModel+AnalyzeCoverage): `project` on the main actor (one
// pass over `records`), `counts` off it; the result lands on
// AnalyzeCoverageReport.tidy, which the menu and this sheet read O(1). Each
// count uses the SAME predicate as the engine it names:
//   * non-video = `NonVideoMediaPurge.isOffered` over every record — the
//     dialog's own classification walks the same `records`;
//   * groups to split = live grouped rows' stored whole-file SHA-256
//     (`VideoScanModel.storedFullDigest`), a group counted when it holds
//     more than one known digest — `DuplicateGroupDigestSplit.partition`'s
//     rule (CatalogTidyTests pins both against the engines);
//   * degenerate OCR = the report's existing #402 count.
// Memory: the projection keeps one (group, digest) pair per LIVE GROUPED
// row (≈ 16 B id + a 64-char digest ≈ 100 B; ≈ 10 MB at 100k grouped rows,
// the worst case), freed when the pass ends; the result is three Ints.
//
// (For Rick: `Set(…).count` over the digests ≈ inserting into a
// std::unordered_set and asking its size.)

import SwiftUI
import VideoScanCore

// MARK: - The counts (pure)

struct CatalogTidyCounts: Sendable, Equatable {
    /// Rows Purge Non-Video Media would offer (any extension that is not a
    /// known video container or Avid essence).
    var nonVideoRows = 0
    /// Duplicate groups whose live members carry more than one known
    /// whole-file SHA-256 — what Split Duplicate Groups by Full Hash splits.
    var duplicateGroupsToSplit = 0
    /// GH #402 degenerate OCR date captions still stored on live rows.
    var degenerateOCRCaptions = 0

    var total: Int { nonVideoRows + duplicateGroupsToSplit + degenerateOCRCaptions }
}

/// One live grouped row, as the split count needs it.
struct CatalogTidyMember: Sendable, Equatable {
    var groupID: UUID
    var digest: String?
}

/// What the main-actor projection hands the off-main count.
struct CatalogTidyProjection: Sendable, Equatable {
    var nonVideoRows = 0
    var grouped: [CatalogTidyMember] = []
}

enum CatalogTidyCalculator {

    /// One pass over `records` (main actor — the records live there).
    @MainActor
    static func project(_ records: [VideoRecord]) -> CatalogTidyProjection {
        var out = CatalogTidyProjection()
        for r in records {
            if NonVideoMediaPurge.isOffered(r) { out.nonVideoRows += 1 }
            // The split's own facts: live rows with a group (duplicateDigestSplitFacts).
            if r.removal == nil, let g = r.duplicateGroupID {
                out.grouped.append(CatalogTidyMember(groupID: g, digest: VideoScanModel.storedFullDigest(r)))
            }
        }
        return out
    }

    /// Groups holding more than one known digest (case-insensitive) —
    /// `DuplicateGroupDigestSplit.partition`'s "known.count > 1".
    nonisolated static func groupsToSplit(_ members: [CatalogTidyMember]) -> Int {
        var digests: [UUID: Set<String>] = [:]
        for m in members {
            guard let d = m.digest?.lowercased() else { continue }
            digests[m.groupID, default: []].insert(d)
        }
        return digests.values.filter { $0.count > 1 }.count
    }

    nonisolated static func counts(_ p: CatalogTidyProjection, degenerateOCRCaptions: Int) -> CatalogTidyCounts {
        CatalogTidyCounts(nonVideoRows: p.nonVideoRows, duplicateGroupsToSplit: groupsToSplit(p.grouped),
                          degenerateOCRCaptions: degenerateOCRCaptions)
    }
}

// MARK: - The rows (pure)

struct CatalogTidyRow: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable, CaseIterable { case nonVideoRows, duplicateGroupsToSplit, degenerateOCRCaptions }
    var kind: Kind
    /// The live count (named apart from a collection's `count`).
    var number: Int
    var title: String
    var detail: String
    /// The Run button's title; nil = no engine (the row says why).
    var runTitle: String?
    var id: String { kind.rawValue }

    static func rows(_ c: CatalogTidyCounts) -> [CatalogTidyRow] {
        [
            CatalogTidyRow(kind: .nonVideoRows, number: c.nonVideoRows,
                           title: "Non-video media rows",
                           detail: "Photos, music and other files that are not video. Run… opens Purge Non-Video Media: pick the extensions and drives; rows leave the catalog only when you press Purge, after a recovery copy. Files on disk are not touched.",
                           runTitle: "Run…"),
            CatalogTidyRow(kind: .duplicateGroupsToSplit, number: c.duplicateGroupsToSplit,
                           title: "Duplicate groups to split by full hash",
                           detail: "Groups whose files carry different whole-file SHA-256s. Run splits them into groups of true copies (a safety copy of the catalog first; a file that is the same footage stays linked as same footage). Only duplicate-group fields change.",
                           runTitle: "Run"),
            CatalogTidyRow(kind: .degenerateOCRCaptions, number: c.degenerateOCRCaptions,
                           title: "Degenerate OCR captions stored before #402",
                           detail: "Junk readings (\"!!!!…\") the captioner wrote before this build refused them. They are already ignored as date evidence; there is no cleanup action yet.",
                           runTitle: nil),
        ]
    }
}

// MARK: - The sheet

struct CatalogTidySheet: View {
    let model: VideoScanModel
    let center: MediaFileOperationsCenter
    @ObservedObject private var coverage: AnalyzeCoverageSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var showPurge = false
    @State private var lastSplit: String?

    init(model: VideoScanModel, center: MediaFileOperationsCenter) {
        self.model = model
        self.center = center
        self._coverage = ObservedObject(wrappedValue: model.analyzeCoverageSnapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tidy Catalog").font(.title2.weight(.semibold))
            CatalogActionBriefHeader(brief: .tidyCatalog)
            VStack(spacing: 8) {
                ForEach(CatalogTidyRow.rows(coverage.report.tidy)) { row in
                    rowView(row)
                }
            }
            if let lastSplit {
                Text(lastSplit).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Counts as of \(MediaDistributionFormat.timeString(coverage.report.computedAt))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .accessibilityIdentifier("sheet.tidyCatalog")
        // The existing purge dialog, over this sheet (its own engine).
        .sheet(isPresented: $showPurge) {
            NonVideoMediaPurgeSheet(preselectedVolumeKey: nil)
                .environmentObject(model)
        }
    }

    private func rowView(_ row: CatalogTidyRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(row.number.formatted())
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)
                .foregroundStyle(row.number > 0 ? .primary : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.headline)
                Text(row.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let runTitle = row.runTitle {
                Button(runTitle) { run(row.kind) }
                    .disabled(row.number <= 0 || model.isReadOnly)
                    .accessibilityIdentifier("tidy.\(row.kind.rawValue).run")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    /// Each Run is the engine the retired menu item called.
    private func run(_ kind: CatalogTidyRow.Kind) {
        switch kind {
        case .nonVideoRows:
            showPurge = true
        case .duplicateGroupsToSplit:
            lastSplit = CatalogTidyWords.splitOutcome(center.splitDuplicateGroupsKeepingSameFootage(model: model))
        case .degenerateOCRCaptions:
            break
        }
    }
}

enum CatalogTidyWords {
    /// One line under the rows after a split (the engine's own log lines
    /// carry the detail).
    static func splitOutcome(_ o: DuplicateDigestSplitOutcome) -> String {
        switch o {
        case .nothingToSplit: return "Nothing to split — every duplicate group holds at most one whole-file SHA-256."
        case .split(let groups, let newGroups, let left, let saved, _):
            return "Split \(groups.formatted()) group(s) into \(newGroups.formatted()) new; \(left.formatted()) file(s) left their group"
                + (saved ? " — saved." : " — not saved yet; the console says why.")
        case .refused(let why): return "Not split: \(why)."
        }
    }
}
