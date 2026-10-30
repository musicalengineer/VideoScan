//
//  AISparkleIcon.swift
//  VideoScan
//
//  The one "AI sparkle" look: pink-to-purple gradient sparkles with a soft
//  twinkle and a pink glow that brightens on hover. Extracted 2026-10-30
//  from ArchivistTabButton (Hallie's tab) so the Family Tree's "Show me some
//  memories…" sparkle draws with the same code instead of a grey 13 pt copy
//  (Rick: "the AI sparkle icon next to Family Tree is too small").
//
//  Twinkle is driven by TimelineView, not an implicit repeatForever
//  animation — macOS drops/desyncs implicit repeating animations on
//  re-render (see the SpinningRing memo); a time-based curve is stable and
//  costs nothing while the window is hidden. Paused under Reduce Motion.
//  (For Rick: TimelineView ≈ a view whose body is re-run by a frame timer,
//  like a paint callback driven by a 30 Hz QTimer.)
//

import SwiftUI

struct AISparkleIcon: View {
    /// Point size of the sparkles glyph.
    let size: Double
    /// The caller owns hover (it is usually tracking it for its own lift);
    /// the glow brightens while true.
    var isHovering = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Shared with text that should match the sparkle (Hallie's tab label).
    static let gradient = LinearGradient(
        colors: [Color(red: 0.98, green: 0.45, blue: 0.70), Color.purple],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            // Two slow sines out of phase → a soft, irregular twinkle.
            let a = reduceMotion ? 1.0 : 0.72 + 0.28 * (0.5 + 0.5 * sin(t * 2.1))
            let s = reduceMotion ? 1.0 : 0.94 + 0.10 * (0.5 + 0.5 * sin(t * 3.3 + 1.0))
            Image(systemName: "sparkles")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Self.gradient)
                .opacity(a)
                .scaleEffect(s)
                .shadow(color: Color.pink.opacity((isHovering ? 0.6 : 0.35) * a),
                        radius: isHovering ? 9 : 6)
        }
    }
}
