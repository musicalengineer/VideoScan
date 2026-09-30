// FindTagHelperStatusLine.swift
// Settings status line for the detached Find and Tag daemon
// (2026-08-06) — the PreviewHelperStatusLine pattern plus a progress
// figure tailed from the newest journal's last heartbeat/verdict.
//
// Cost discipline: the probe reads only the final 4 KB of the newest
// journal (never a full parse — an overnight journal is ~1 MB) on a
// 5 s TimelineView cadence, and only while Settings is visible.

import SwiftUI
import VideoScanCore

enum FindTagStatusProbe {

    /// (index, planned, currentPath) from the newest journal's last
    /// heartbeat — or verdict, whichever is later — else nil.
    static func latestProgress(
        journalDir: URL = FindTagPaths.journalDirectoryURL()
    ) -> (index: Int, planned: Int)? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: journalDir, includingPropertiesForKeys: nil) else { return nil }
        guard let newest = files
            .filter({ $0.pathExtension == "jsonl" })
            .max(by: { $0.lastPathComponent < $1.lastPathComponent }) else { return nil }

        guard let handle = try? FileHandle(forReadingFrom: newest) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 4096
        let offset = size > window ? size - window : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }

        // Scan the tail's entries newest-first for a position. planned
        // comes from heartbeats; a trailing verdict's seq is the same
        // 1-based position when no heartbeat landed yet.
        var latest: (index: Int, planned: Int)?
        for entry in FindTagJournalReader.entries(in: data) {
            switch entry {
            case .heartbeat(let beat):
                latest = (beat.index, beat.planned)
            case .verdict(let verdict):
                latest = (verdict.seq, latest?.planned ?? 0)
            case .runStart, .runEnd:
                break
            }
        }
        return latest
    }
}

/// "● Background Find and Tag running — 148/2979" under the Settings
/// toggle; gray dot + "not running" otherwise.
struct FindTagHelperStatusLine: View {
    let isRunning: () -> Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            let running = isRunning()
            HStack(spacing: 6) {
                Image(systemName: running ? "circle.fill" : "circle")
                    .font(.system(size: 8))
                    .foregroundStyle(running ? Color.green : Color.secondary)
                Text(statusText(running: running))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.findTagHelper.status")
        }
    }

    private func statusText(running: Bool) -> String {
        guard running else { return "Background Find and Tag not running" }
        if let progress = FindTagStatusProbe.latestProgress(), progress.planned > 0 {
            return "Background Find and Tag running — \(progress.index)/\(progress.planned)"
        }
        return "Background Find and Tag running"
    }
}
