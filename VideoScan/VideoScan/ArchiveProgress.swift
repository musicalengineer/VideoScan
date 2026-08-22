// ArchiveProgress.swift
// "How far along is the archive?" — one big bar at the top of the Archive
// tab (Rick 2026-08-21: "shows say 5% of files promoted to archive").
//
// Numerator: assets with a byte-verified Master Archive copy (the same
// count as the MASTER ARCHIVE panel), plus — as its own colour — copies
// that exist but have not been re-read and verified yet. Denominator:
// the catalog's UNIQUE media files (CatalogStorageTotals.uniqueFileCount:
// duplicates collapsed, junk / non-video / music excluded) — the "master
// total unique" Rick means. Both numbers are already computed elsewhere
// once per catalog version; this file only combines them, so it is O(1)
// in the view body.
//
// Status colours follow the house rule: good = green (verified), warning
// = amber (copied, not yet verified), the rest is neutral — each segment
// also carries its count in text, never colour alone.

import SwiftUI

struct ArchiveProgress: Equatable, Sendable {
    /// Assets with a verified archive copy.
    let verified: Int
    /// Copies present in the archive but not yet byte-verified.
    let unverified: Int
    /// Unique media files in the catalog (duplicates collapsed).
    let uniqueTotal: Int
    let verifiedBytes: Int64
    let uniqueBytes: Int64

    init(verified: Int, unverified: Int, uniqueTotal: Int,
         verifiedBytes: Int64 = 0, uniqueBytes: Int64 = 0) {
        self.verified = max(0, verified)
        self.unverified = max(0, unverified)
        self.uniqueTotal = max(0, uniqueTotal)
        self.verifiedBytes = max(0, verifiedBytes)
        self.uniqueBytes = max(0, uniqueBytes)
    }

    /// The honest denominator: never smaller than what is already archived
    /// (the unique count excludes junk; an archived junk file would
    /// otherwise push the bar past 100%).
    var total: Int { max(uniqueTotal, verified + unverified) }
    var remaining: Int { total - verified - unverified }

    var verifiedFraction: Double { total == 0 ? 0 : Double(verified) / Double(total) }
    var unverifiedFraction: Double { total == 0 ? 0 : Double(unverified) / Double(total) }

    /// "5%" — rounded, but never "0%" while something is verified and
    /// never "100%" while something remains (Rick must not read a false
    /// zero or a false finish).
    var percentText: String {
        guard total > 0 else { return "0%" }
        let pct = verifiedFraction * 100
        if verified > 0, pct < 1 { return "<1%" }
        if remaining > 0 || unverified > 0, pct >= 99.5 { return ">99%" }
        return "\(Int(pct.rounded()))%"
    }

    var headline: String {
        guard total > 0 else { return "Nothing to archive yet" }
        return "\(percentText) of the family's \(total.formatted()) unique media files are safely archived"
    }

    var detail: String {
        var parts = ["\(verified.formatted()) verified"]
        if unverified > 0 { parts.append("\(unverified.formatted()) copied, not yet verified") }
        parts.append("\(remaining.formatted()) to go")
        if verifiedBytes > 0 {
            parts.append("\(MediaBytes.display(verifiedBytes)) of \(MediaBytes.display(uniqueBytes)) verified")
        }
        return parts.joined(separator: " · ")
    }

    static func from(totals: ArchivePromotionIndex.Totals,
                     storage: CatalogStorageTotals) -> ArchiveProgress {
        ArchiveProgress(verified: totals.verified,
                        unverified: totals.unverified,
                        uniqueTotal: storage.uniqueFileCount,
                        verifiedBytes: totals.verifiedBytes,
                        uniqueBytes: storage.uniqueBytes)
    }
}

/// The bar itself: tall, rounded, three segments with a 2-pt surface gap,
/// the percentage as a hero number, the counts as text beside it.
struct ArchiveProgressBar: View {
    let progress: ArchiveProgress

    // Rick 2026-08-21: "a brighter green… if it popped a little more" —
    // a vivid, saturated green; the amber and gray stay recessive.
    private let verifiedColor = Color(red: 0.10, green: 0.80, blue: 0.36)     // good
    private let unverifiedColor = Color(red: 0.90, green: 0.62, blue: 0.16)   // warning
    private let remainingColor = Color.secondary.opacity(0.18)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(progress.percentText)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(progress.verified > 0 ? verifiedColor : Color.secondary)
                    .accessibilityLabel("\(progress.percentText) archived")
                VStack(alignment: .leading, spacing: 2) {
                    Text(progress.headline)
                        .font(.system(size: 16, weight: .semibold))
                    Text(progress.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            GeometryReader { geo in
                let width = geo.size.width
                let gap: CGFloat = 2
                let verifiedWidth = width * progress.verifiedFraction
                let unverifiedWidth = width * progress.unverifiedFraction
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(remainingColor)
                    HStack(spacing: gap) {
                        if verifiedWidth > 0 {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(verifiedColor)
                                .frame(width: max(4, verifiedWidth - (unverifiedWidth > 0 ? gap : 0)))
                        }
                        if unverifiedWidth > 0 {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(unverifiedColor)
                                .frame(width: max(4, unverifiedWidth))
                        }
                    }
                }
            }
            .frame(height: 22)
            .accessibilityHidden(true)
            HStack(spacing: 16) {
                legend(verifiedColor, "Verified in the Master Archive", progress.verified)
                if progress.unverified > 0 {
                    legend(unverifiedColor, "Copied, awaiting verification", progress.unverified)
                }
                legend(remainingColor, "Not yet promoted", progress.remaining)
                Spacer()
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .help("Verified = copied to the Master Archive, re-read and SHA-256 matched. Total = unique media files in the catalog (duplicates collapsed; junk, non-video and music excluded).")
    }

    private func legend(_ color: Color, _ label: String, _ count: Int) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 12, height: 12)
            Text("\(label) · \(count.formatted())")
        }
    }
}

/// The nudge under the bar: one loose sentence and a chevron that opens a
/// short, tidy list — the few files most likely to be ready — each with a
/// green Archive Helper… and a blue Show in Catalog. A nudge, not an
/// inventory (Rick 2026-08-21: "we can't overwhelm the user with a big
/// mess… a friendly way to promote a few more files").
struct ArchiveNudgeView: View {
    let nudge: ArchiveNudge
    /// Open the Archive Helper for ONE recording.
    let openHelper: (UUID) -> Void
    /// Jump to the record in the Catalog tab.
    let showInCatalog: (UUID) -> Void
    @State private var isOpen = false

    private let helperGreen = Color(red: 0.10, green: 0.62, blue: 0.30)
    private let catalogBlue = Color(red: 0.13, green: 0.45, blue: 0.85)
    private let yearWidth: CGFloat = 48
    private let whyWidth: CGFloat = 230
    private let actionsWidth: CGFloat = 250
    private let rowHeight: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text(nudge.headline)
                        .font(.system(size: 16))
                        .foregroundStyle(nudge.isEmpty ? Color.secondary : Color.primary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(nudge.isEmpty)

            if isOpen, !nudge.isEmpty {
                list
                    .padding(.top, 10)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    private var list: some View {
        let rows = nudge.shortlist
        return VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, candidate in
                        row(candidate)
                            .frame(height: rowHeight)
                        if index < rows.count - 1 { Divider() }
                    }
                }
            }
            .frame(maxHeight: rowHeight * 8 + 8)
            Divider()
            HStack {
                Text(rows.count < nudge.ready.count + nudge.nearReady.count
                     ? "Showing the \(rows.count) most likely — promote a few and more will take their place."
                     : "That's everyone waving right now — star or mark more keepers in the Catalog and they'll appear here.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 8)
        }
        .padding(.leading, 20)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("File").frame(maxWidth: .infinity, alignment: .leading)
            Text("Year").frame(width: yearWidth, alignment: .leading)
            Text("Why it looks ready").frame(width: whyWidth, alignment: .leading)
            Text("").frame(width: actionsWidth)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.bottom, 6)
    }

    private func row(_ candidate: ArchiveNudge.Candidate) -> some View {
        HStack(spacing: 12) {
            Text(candidate.filename)
                .font(.system(size: 15))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(candidate.filename)
            Text(candidate.year.map(String.init) ?? "—")
                .font(.system(size: 14).monospacedDigit())
                .foregroundStyle(candidate.year == nil ? Color.orange : Color.secondary)
                .frame(width: yearWidth, alignment: .leading)
            Text(candidate.needsDate
                 ? "needs a date · " + candidate.reasons.joined(separator: " · ")
                 : candidate.reasons.joined(separator: " · "))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: whyWidth, alignment: .leading)
            HStack(spacing: 8) {
                Button("Archive Helper…") { openHelper(candidate.id) }
                    .buttonStyle(.borderedProminent)
                    .tint(helperGreen)
                    .help("Copies, date, audio and name are checked before anything is promoted.")
                Button("Show in Catalog") { showInCatalog(candidate.id) }
                    .buttonStyle(.bordered)
                    .tint(catalogBlue)
                    .foregroundStyle(catalogBlue)
            }
            .controlSize(.regular)
            .frame(width: actionsWidth, alignment: .trailing)
        }
    }
}
