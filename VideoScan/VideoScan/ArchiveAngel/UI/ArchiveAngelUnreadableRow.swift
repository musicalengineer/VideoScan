// ArchiveAngelUnreadableRow.swift
// Audit #7 (Rick 2026-09-19, option a): an Archive Angel batch whose
// plan.json can't be read is listed — how many, how big, why — with Reveal
// in Finder. Nothing here settles, moves or deletes it; Rick decides.

import AppKit
import SwiftUI

struct ArchiveAngelUnreadableRow: View {
    let batches: [ArchiveAngelPlanStore.UnreadableBatch]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
            Text(Self.title(batches))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.orange)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(batches.map { URL(fileURLWithPath: $0.batchDir) })
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
            .accessibilityIdentifier("archive.angelUnreadable.reveal")
        }
        .help(batches.map { "\(($0.batchDir as NSString).lastPathComponent): \($0.reason)" }.joined(separator: "\n"))
        .accessibilityIdentifier("archive.angelUnreadable")
    }

    /// "1 Angel batch can't be read (12.4 GB)" / "3 Angel batches can't be read (…)".
    static func title(_ batches: [ArchiveAngelPlanStore.UnreadableBatch]) -> String {
        let n = batches.count
        let bytes = batches.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return "\(n) Angel batch\(n == 1 ? "" : "es") can't be read (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))) — left untouched"
    }
}
