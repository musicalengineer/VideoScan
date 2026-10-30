//
//  ArchivistTabButton.swift
//  VideoScan
//
//  The Family Archivist's front door in the main tab bar: pink-to-purple
//  "Hallie Mae" with a twinkling sparkles icon. Rick 2026-08-16: "move
//  the Pink AI Archivist to be after the Family Tree tab, prominently
//  displayed, and make the ai icon twinkle."
//
//  The sparkle itself is AISparkleIcon (Shared/), shared with the Family
//  Tree's "Show me some memories…" button so the two never drift apart.
//

import SwiftUI

struct ArchivistTabButton: View {
    let fontSize: Double
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("archivist.name") private var archivistName: String = "Hallie Mae"
    /// Hover lift + brighter sparkle glow (Liquid Glass refresh, 2026-10-04).
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                AISparkleIcon(size: fontSize + 2, isHovering: isHovering)
                Text(archivistName.isEmpty || archivistName == "Name TBD" ? "Archivist" : "Ask " + archivistName)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(AISparkleIcon.gradient)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering && !reduceMotion ? 1.04 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovering)
        .onHover { isHovering = $0 }
        .help("Chat with the Family Archivist — “show me Donna down the cape 1990 to 1995”")
        .accessibilityIdentifier("tab.Archivist")
    }
}
