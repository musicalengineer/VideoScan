// PreviewHelperStatusLine.swift
// Quiet, live status for the detached preview-sweep helper in Settings.

import SwiftUI

enum PreviewHelperStatusPresentation {
    static func text(isRunning: Bool) -> String {
        "Background helper: \(isRunning ? "running" : "not running")"
    }

    static func symbolName(isRunning: Bool) -> String {
        isRunning ? "circle.fill" : "circle"
    }
}

/// Samples only while Settings is visible. The underlying probe is O(1):
/// one tiny pidfile, a nonblocking flock probe, and kill(pid, 0).
struct PreviewHelperStatusLine: View {
    let isRunning: () -> Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let running = isRunning()
            HStack(spacing: 6) {
                Image(systemName: PreviewHelperStatusPresentation.symbolName(isRunning: running))
                    .font(.system(size: 8))
                    .foregroundStyle(running ? Color.green : Color.secondary)
                Text(PreviewHelperStatusPresentation.text(isRunning: running))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.previewHelper.status")
        }
    }
}
