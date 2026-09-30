// ColorActionButton.swift
// The coloured, iconed, labelled action button Hallie's cited-video rows
// use (Rick 2026-08-17: "colored, spaced, iconed buttons — Play blue,
// Show in Finder orange, Show in Catalog purple"), lifted out of
// ArchivistCitationRow so other lists can wear the SAME style instead of
// inventing a third one. First reuse: the Archive Angel recommendations
// list (Rick 2026-09-24: bigger type and buttons for senior eyes — "better
// to see 10 files clearly than 25 needing a microscope").
//
// Two sizes. `.regular` is exactly what Hallie has drawn since 2026-08-17
// (14 pt, ~24 pt tall). `.large` is the senior-friendly size: 17 pt text,
// at least 34 pt tall, a wider hit target.
//
// The colours are shared too, so "Play" is the same blue everywhere.

import SwiftUI

struct ColorActionButton: View {

    enum Size {
        /// Hallie's citation rows (unchanged since 2026-08-17).
        case regular
        /// Senior-friendly: 17 pt, ≥ 34 pt tall.
        case large

        var fontSize: CGFloat { self == .large ? 17 : 14 }
        var horizontalPadding: CGFloat { self == .large ? 14 : 10 }
        var verticalPadding: CGFloat { self == .large ? 7 : 4 }
        var minHeight: CGFloat? { self == .large ? 34 : nil }
        var cornerRadius: CGFloat { self == .large ? 9 : 7 }
    }

    /// The palette Hallie established. Green is kept for "done / archived"
    /// (Rick 2026-08-24: orange frees green for the Archived badge).
    enum Palette {
        static let play: Color = .blue
        static let showInFinder: Color = .orange
        static let showInCatalog: Color = .purple
        static let archive = Color(red: 0.10, green: 0.62, blue: 0.30)
        static let info: Color = .indigo
    }

    let title: String
    let systemImage: String
    let color: Color
    var size: Size = .regular
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: size.fontSize, weight: .medium))
                .foregroundStyle(color)
                .padding(.horizontal, size.horizontalPadding)
                .padding(.vertical, size.verticalPadding)
                .frame(minHeight: size.minHeight)
                .background(RoundedRectangle(cornerRadius: size.cornerRadius).fill(color.opacity(0.12)))
                .contentShape(RoundedRectangle(cornerRadius: size.cornerRadius))
        }
        .buttonStyle(.plain)
    }
}
