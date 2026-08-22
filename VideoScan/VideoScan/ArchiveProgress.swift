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

    private let verifiedColor = Color(red: 0.18, green: 0.62, blue: 0.36)     // good
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
