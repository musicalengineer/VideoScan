// CatalogSizeTotals.swift
// The Catalog's three-figure size line, beside the Showing box
// (Rick 2026-09-11):
//
//     TOTAL CATALOG 10.7 TB · ARCHIVED 2.1 TB · UNIQUE 6.3 TB
//
// WHY. The catalog reads ~10 TB because it counts the Master Archive
// copies and the cleaned / transcoded versions as well as the originals.
// Three numbers say what is actually going on: how much the catalog
// knows about, how much of that is already safe in the Master Archive,
// and how much DISTINCT material there is once every copy of the same
// content is counted once.
//
// DEFINITIONS (exact — CatalogSizeTotalsTests pins each one):
//
//   TOTAL CATALOG  Sum of `sizeBytes` over ACTIVE records: not purged,
//                  not set aside. Nothing else is respected — not the
//                  table's current filter, not Connected drives, not the
//                  media-kind facet, not superseded / manually-deleted
//                  stages. The whole catalog. (This is the 11,431-record
//                  / 10.69 TB figure Rick measured on 2026-09-11.)
//
//   ARCHIVED       Sum over active records where `model.isArchived(rec)`
//                  is true: a promoted archive copy, anything living
//                  inside the Master Archive root, or a record whose
//                  content already has a master copy. Each record is
//                  counted ONCE at its own size — so an original and its
//                  archive copy both contribute when both are active.
//                  The predicate is injected (a closure), so this file
//                  never touches the model.
//
//   UNIQUE         One copy per content group. Group-key precedence, per
//                  record:
//                    1. `duplicateGroupID` when present
//                    2. else `contentHash` when non-empty
//                    3. else (`partialMD5`, `sizeBytes`) when partialMD5
//                       is non-empty — same hash, DIFFERENT length is not
//                       a twin
//                    4. else the record itself (a group of one)
//                  Per group the LARGEST member's `sizeBytes` is summed —
//                  the most-original copy is the largest in practice
//                  (transcodes shrink; archive copies are byte-identical,
//                  so ties change nothing).
//
//   NOT YET HASHED Active records carrying none of the three signals.
//                  They can only ever have scored as unique, so whenever
//                  the count is > 0 the UNIQUE figure is an UPPER BOUND
//                  and the tooltip on that figure says so.
//
// Invariants (the sensor tests): UNIQUE ≤ TOTAL and ARCHIVED ≤ TOTAL,
// always; N identical copies collapse to one copy's bytes.
//
// NOT THE SAME AS CatalogStorageTotals. That is the volume table's
// TOTAL MEDIA footer and answers "how big a drive do I buy" — it
// subtracts junk, photos and music. This line answers "what does the
// catalog contain and how much of it is safe" and subtracts nothing.
//
// COST. Two passes: `project` on the main actor (plain field reads plus
// the model's O(1) archived predicate, no I/O), then `compute` off the
// main actor (one pass plus a dictionary group-by). Budgeted at 100k
// records by CatalogSizeTotalsTests. Never called from a view body —
// CatalogView recomputes it on the same triggers as the volume-table
// footer and publishes the result into a @State.
//
// MEMORY. One `Entry` per active record, ~80 bytes: the two hash
// strings are copy-on-write shares of the record's own storage, not
// copies. ~1 MB at 11k records; ~8 MB worst case at 100k. The group-by
// dictionary holds one (key, Int64) per multi-member group and is freed
// on return.
//
// All functions `nonisolated` and pure — same testability contract as
// CatalogStorageTotals.swift. (Swift `enum`/`struct` with only static
// members ≈ a C++ namespace of free functions.)

import Foundation
import SwiftUI

// MARK: - Result

/// The three headline figures plus the counts behind them. Value type,
/// `Equatable` so SwiftUI skips redundant redraws, `Sendable` so the
/// off-main pass can hand it back to the main actor.
struct CatalogSizeTotals: Equatable, Sendable {

    /// TOTAL CATALOG — every active byte.
    var totalBytes: Int64 = 0
    /// ARCHIVED — active bytes the Master Archive already holds.
    var archivedBytes: Int64 = 0
    /// UNIQUE — one (largest) copy per content group. An UPPER BOUND
    /// when `unhashedCount > 0`.
    var uniqueBytes: Int64 = 0

    /// Active records counted into `totalBytes`.
    var recordCount: Int = 0
    /// Active records counted into `archivedBytes`.
    var archivedCount: Int = 0
    /// Content groups counted into `uniqueBytes` (one per group).
    var uniqueCount: Int = 0
    /// Active records with no duplicate signal at all — see the header.
    var unhashedCount: Int = 0

    /// Nothing to show: no active records at all.
    var isEmpty: Bool { recordCount == 0 }

    /// True when the UNIQUE figure is a bound rather than a measurement.
    var uniqueIsUpperBound: Bool { unhashedCount > 0 }

    // MARK: Projection

    /// The Sendable shadow of one active record — every field the
    /// arithmetic needs and nothing else. `VideoRecord` is a class the
    /// main actor owns, so this is what crosses to the detached task.
    struct Entry: Equatable, Sendable {
        var id: UUID
        var sizeBytes: Int64
        var duplicateGroupID: UUID?
        var contentHash: String
        var partialMD5: String
        var isArchived: Bool
    }

    /// The content-group identity of one entry, in precedence order.
    enum GroupKey: Hashable, Sendable {
        case duplicateGroup(UUID)
        case contentHash(String)
        case byteTwin(md5: String, sizeBytes: Int64)
        case solo(UUID)

        /// A group of one: the record carries no duplicate signal.
        var isSolo: Bool {
            if case .solo = self { return true }
            return false
        }
    }

    /// TOTAL CATALOG's population: not purged, not set aside. Nothing
    /// else — see the header.
    nonisolated static func isActive(_ rec: VideoRecord) -> Bool {
        !rec.isPurged && !rec.isSetAside
    }

    /// Precedence 1 → 4 from the header, as a pure function so the
    /// tests can pin it directly.
    nonisolated static func groupKey(for e: Entry) -> GroupKey {
        if let g = e.duplicateGroupID { return .duplicateGroup(g) }
        if !e.contentHash.isEmpty { return .contentHash(e.contentHash) }
        if !e.partialMD5.isEmpty { return .byteTwin(md5: e.partialMD5, sizeBytes: e.sizeBytes) }
        return .solo(e.id)
    }

    /// The main-actor half: drop inactive records and copy the fields
    /// the arithmetic needs. `isArchived` is called exactly once per
    /// ACTIVE record (never for purged / set-aside ones) — in production
    /// it is `model.isArchived`, O(1) per call after the promotion
    /// index's per-mutation rebuild. No I/O.
    nonisolated static func project(
        _ records: [VideoRecord],
        isArchived: (VideoRecord) -> Bool
    ) -> [Entry] {
        var out: [Entry] = []
        out.reserveCapacity(records.count)
        for rec in records where isActive(rec) {
            out.append(Entry(id: rec.id,
                             // A negative size is corrupt metadata, not a credit.
                             sizeBytes: max(0, rec.sizeBytes),
                             duplicateGroupID: rec.duplicateGroupID,
                             contentHash: rec.contentHash,
                             partialMD5: rec.partialMD5,
                             isArchived: isArchived(rec)))
        }
        return out
    }

    /// The off-main half: one pass over the projection plus a group-by.
    /// Solo entries never enter the dictionary — they are their own
    /// group, so their bytes go straight to UNIQUE.
    nonisolated static func compute(_ entries: [Entry]) -> CatalogSizeTotals {
        var t = CatalogSizeTotals()
        guard !entries.isEmpty else { return t }

        // Largest member per multi-member-capable group. Sized for the
        // common case where most records carry a hash.
        var largestByGroup: [GroupKey: Int64] = [:]
        largestByGroup.reserveCapacity(entries.count)

        for e in entries {
            t.totalBytes += e.sizeBytes
            t.recordCount += 1
            if e.isArchived {
                t.archivedBytes += e.sizeBytes
                t.archivedCount += 1
            }
            let key = groupKey(for: e)
            if key.isSolo {
                t.unhashedCount += 1
                t.uniqueBytes += e.sizeBytes
                t.uniqueCount += 1
            } else if let current = largestByGroup[key] {
                if e.sizeBytes > current { largestByGroup[key] = e.sizeBytes }
            } else {
                largestByGroup[key] = e.sizeBytes
            }
        }
        for (_, largest) in largestByGroup {
            t.uniqueBytes += largest
            t.uniqueCount += 1
        }
        return t
    }

    /// Both halves in one call — for tests and for callers that are
    /// already off the main actor. Production goes through `project`
    /// then `compute` so the group-by never runs on the UI thread.
    nonisolated static func compute(
        records: [VideoRecord],
        isArchived: (VideoRecord) -> Bool
    ) -> CatalogSizeTotals {
        compute(project(records, isArchived: isArchived))
    }
}

// MARK: - Display

extension CatalogSizeTotals {

    /// "10.7 TB", "150 GB" — via `MediaBytes`, the app-wide DECIMAL
    /// formatter, so this line agrees with the volume table's footer,
    /// the Media Size column, Finder and `df -H`.
    static func displaySize(_ bytes: Int64) -> String {
        MediaBytes.display(max(0, bytes))
    }

    var totalDisplay: String { Self.displaySize(totalBytes) }
    var archivedDisplay: String { Self.displaySize(archivedBytes) }
    var uniqueDisplay: String { Self.displaySize(uniqueBytes) }

    /// Rick's requested shape, as one string (VoiceOver, logs, tests).
    var line: String {
        "TOTAL CATALOG \(totalDisplay) · ARCHIVED \(archivedDisplay) · UNIQUE \(uniqueDisplay)"
    }

    /// The honesty note on the UNIQUE figure — present only when there
    /// is something to say.
    var unhashedTooltip: String? {
        guard unhashedCount > 0 else { return nil }
        return "\(unhashedCount.formatted()) file\(unhashedCount == 1 ? "" : "s") not yet hashed — UNIQUE is an upper bound"
    }

    var totalTooltip: String {
        "Every active record in the catalog — \(recordCount.formatted()) files, all drives, all filters. "
            + "Archive copies and cleaned / transcoded versions are counted alongside their originals."
    }

    var archivedTooltip: String {
        "\(archivedCount.formatted()) of those files are already safe in the Master Archive: "
            + "promoted copies, files inside the archive tree, and originals whose content has a master copy."
    }

    var uniqueTooltip: String {
        var s = "Distinct material once every copy of the same content is counted once — "
            + "\(uniqueCount.formatted()) content groups, each at its largest copy's size."
        if let note = unhashedTooltip { s += "\n\n\(note)." }
        return s
    }
}

// MARK: - The box

/// The line itself, beside the Showing box. Pure layout over an
/// already-computed `CatalogSizeTotals` — no records are touched here.
/// Same 14pt register as the Showing box so the two read as one row of
/// facts; neutral fill because this box states, it does not switch.
struct CatalogSizeTotalsBox: View {
    let totals: CatalogSizeTotals

    private static let labelFont = Font.system(size: 10, weight: .semibold)
    private static let valueFont = Font.system(size: 14, weight: .semibold).monospacedDigit()

    var body: some View {
        HStack(spacing: 12) {
            figure("TOTAL CATALOG", totals.totalDisplay, help: totals.totalTooltip)
                .accessibilityIdentifier("catalog.sizeTotals.total")
            separator
            figure("ARCHIVED", totals.archivedDisplay, help: totals.archivedTooltip)
                .accessibilityIdentifier("catalog.sizeTotals.archived")
            separator
            HStack(spacing: 4) {
                figure("UNIQUE", totals.uniqueDisplay, help: totals.uniqueTooltip)
                if totals.uniqueIsUpperBound {
                    // Same "this is a bound" glyph the volume footer uses.
                    Image(systemName: "lessthanorequalto")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.orange)
                        .help(totals.unhashedTooltip ?? "")
                }
            }
            .accessibilityIdentifier("catalog.sizeTotals.unique")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(totals.line)
        .accessibilityIdentifier("catalog.sizeTotals")
    }

    private var separator: some View {
        Text("·").font(Self.valueFont).foregroundColor(.secondary)
    }

    private func figure(_ label: String, _ value: String, help: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label)
                .font(Self.labelFont)
                .foregroundColor(.secondary)
            Text(value)
                .font(Self.valueFont)
                .foregroundColor(.primary)
        }
        .lineLimit(1)
        .help(help)
    }
}
