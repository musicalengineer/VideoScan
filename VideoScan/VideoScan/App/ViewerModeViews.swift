// ViewerModeViews.swift
// The viewer's face (Phase 1 §4, docs/remote_use_design.md): one status
// chip — "Viewing RicksM4's catalog · synced 2 min ago · media: streaming"
// — and one modifier for master-only controls, which stay visible but
// disabled with the hint "on the master (RicksM4)". Both read
// ViewerModeCenter; on the master the modifier is a no-op and the chip is
// never rendered (ContentView shows it only in viewer mode).

import SwiftUI

/// Pure text for the chip so a test pins the exact wording.
enum ViewerStatusChipText {
    static func compose(masterDisplayName: String, syncedAt: Date?, syncing: Bool,
                        media: String, now: Date = Date()) -> String {
        let synced: String
        if syncing {
            synced = "syncing…"
        } else if let syncedAt {
            synced = "synced \(relative(syncedAt, now: now))"
        } else {
            synced = "never synced"
        }
        return "Viewing \(masterDisplayName)'s catalog · \(synced) · media: \(media)"
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) hr ago" }
        return "\(hours / 24) days ago"
    }
}

/// `.masterOnly()` — disabled on a viewer with the "on the master" hint;
/// untouched on the master. `// A ViewModifier ≈ a decorator applied to a
/// view; `content` is the wrapped view.`
struct MasterOnlyModifier: ViewModifier {
    let isViewer = ViewerModeCenter.shared.isViewer
    func body(content: Content) -> some View {
        if isViewer {
            content
                .disabled(true)
                .help(ViewerModeCenter.shared.masterOnlyHint)
                .opacity(0.55)
        } else {
            content
        }
    }
}

extension View {
    /// Mark a control as something only the master can do (scan, ingest,
    /// FamilySearch pull, kinship/notes edits, dispositions, delete, media
    /// file operations). On a viewer it renders disabled with the hint.
    func masterOnly() -> some View { modifier(MasterOnlyModifier()) }
}

/// A one-line "on the master (RicksM4)" caption for places that hide a
/// whole section rather than disable a control.
struct MasterOnlyCaption: View {
    let what: String
    var body: some View {
        Label("\(what) happens \(ViewerModeCenter.shared.masterOnlyHint).", systemImage: "lock")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
