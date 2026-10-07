// ArchiveOccasionCueView.swift
// Archive tab — the occasion cue on a card and the occasion strip under a
// year header (Rick 2026-10-07: "color helps the eye … but nothing
// garish"). Model: ArchiveOccasion.swift.
//
// Rules: ALWAYS icon + word + tint (never colour alone — colour-blind
// safe); tints are soft, defined once below as named dynamic colours that
// resolve per appearance (light / dark); the card keeps its solid backing,
// the tint lives only in the small capsule and the thin strip.

import AppKit
import SwiftUI

// MARK: - Palette (defined once)

/// One soft tint per occasion. `NSColor(name:dynamicProvider:)` ≈ a colour
/// object whose value is computed per draw from the current appearance —
/// what an asset-catalog colour set does, in code, in one place.
enum ArchiveOccasionPalette {

    /// (light RGB, dark RGB) per occasion — muted, mid-saturation hues.
    private static let rgb: [ArchiveOccasion: (light: UInt32, dark: UInt32)] = [
        .christmas: (0x4F9A6A, 0x6FBF8A),      // pine green
        .thanksgiving: (0xB9824A, 0xD29A62),   // harvest amber
        .birthday: (0xC77A9A, 0xE09AB8),       // rose
        .trip: (0x4A93B0, 0x6CB3CF),           // lake blue
        .other: (0x8C7BB8, 0xA899D4),          // lavender
        .unlabeled: (0x8E8E93, 0x8E8E93),      // system grey
    ]

    private static func color(_ o: ArchiveOccasion, alpha: (light: CGFloat, dark: CGFloat), name: String) -> Color {
        let pair = rgb[o] ?? (0x8E8E93, 0x8E8E93)
        return Color(nsColor: NSColor(name: NSColor.Name("ArchiveOccasion.\(o.rawValue).\(name)")) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return nsColor(dark ? pair.dark : pair.light, alpha: dark ? alpha.dark : alpha.light)
        })
    }

    private static func nsColor(_ hex: UInt32, alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// Capsule background on a card — barely there, readable text on top.
    static let capsule: [ArchiveOccasion: Color] = Dictionary(uniqueKeysWithValues: ArchiveOccasion.allCases.map {
        ($0, color($0, alpha: (0.20, 0.28), name: "capsule"))
    })
    /// Strip segment — a little stronger, so a 6 pt bar still reads.
    static let strip: [ArchiveOccasion: Color] = Dictionary(uniqueKeysWithValues: ArchiveOccasion.allCases.map {
        ($0, color($0, alpha: (0.55, 0.65), name: "strip"))
    })
}

// MARK: - The card's cue

/// "🎄 Christmas" in a soft capsule. The word is primary text (senior
/// readability); the tint only groups by eye.
struct ArchiveOccasionCueView: View {
    let cue: ArchiveOccasionCue

    var body: some View {
        HStack(spacing: 4) {
            Text(cue.occasion.emoji)
                .foregroundStyle(cue.occasion == .unlabeled ? .secondary : .primary)
            Text(cue.word)
                .foregroundStyle(cue.occasion == .unlabeled ? .secondary : .primary)
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(ArchiveOccasionPalette.capsule[cue.occasion] ?? .clear))
        .help(cue.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Occasion: \(cue.word)")
    }
}

// MARK: - The year's strip

/// A thin bar under the year header: one segment per occasion, width by
/// minutes. Every value it draws was computed with the grouping
/// (ArchiveOccasionStrip.build) — the body only lays out ≤ 6 segments.
struct ArchiveOccasionStripView: View {
    let strip: ArchiveOccasionStrip

    var body: some View {
        VStack(spacing: 3) {
            // GeometryReader ≈ "give me my parent's size at layout time" —
            // needed to turn fractions into point widths.
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(strip.segments) { seg in
                        Rectangle()
                            .fill(ArchiveOccasionPalette.strip[seg.occasion] ?? .gray)
                            .frame(width: max(2, geo.size.width * seg.fraction - 1))
                    }
                }
            }
            .frame(height: 5)
            .clipShape(Capsule())
            Text(strip.summary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .help(strip.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Occasions this year")
        .accessibilityValue(strip.help)
    }
}
