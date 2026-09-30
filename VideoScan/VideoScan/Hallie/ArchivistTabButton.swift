//
//  ArchivistTabButton.swift
//  VideoScan
//
//  The Family Archivist's front door in the main tab bar: pink-to-purple
//  "Hallie Mae" with a twinkling sparkles icon. Rick 2026-08-16: "move
//  the Pink AI Archivist to be after the Family Tree tab, prominently
//  displayed, and make the ai icon twinkle."
//
//  Twinkle is driven by TimelineView, not an implicit repeatForever
//  animation — macOS drops/desyncs implicit repeating animations on
//  re-render (see the SpinningRing memo); a time-based curve is stable
//  and costs nothing while the window is hidden. Respects Reduce Motion.
//

import SwiftUI

struct ArchivistTabButton: View {
    let fontSize: Double
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("archivist.name") private var archivistName: String = "Hallie Mae"

    private static let gradient = LinearGradient(
        colors: [Color(red: 0.98, green: 0.45, blue: 0.70), Color.purple],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    // Two slow sines out of phase → a soft, irregular twinkle.
                    let a = reduceMotion ? 1.0 : 0.72 + 0.28 * (0.5 + 0.5 * sin(t * 2.1))
                    let s = reduceMotion ? 1.0 : 0.94 + 0.10 * (0.5 + 0.5 * sin(t * 3.3 + 1.0))
                    Image(systemName: "sparkles")
                        .font(.system(size: fontSize + 2, weight: .semibold))
                        .foregroundStyle(Self.gradient)
                        .opacity(a)
                        .scaleEffect(s)
                        .shadow(color: Color.pink.opacity(0.35 * a), radius: 6)
                }
                Text(archivistName.isEmpty || archivistName == "Name TBD" ? "Archivist" : "Ask " + archivistName)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(Self.gradient)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Chat with the Family Archivist — “show me Donna down the cape 1990 to 1995”")
        .accessibilityIdentifier("tab.Archivist")
    }
}
