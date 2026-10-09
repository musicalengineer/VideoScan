// ExcessCopiesPane.swift
// Triage ▸ CLEAN UP ▸ "Excess copies (archived)" — Tier 1 of the delete-
// excess-copies lane (docs/design/delete_excess_copies_2026_10_06.md).
// Shown only with View ▸ Curator on (Rick 2026-10-07: "calm by default,
// depth on request").
//
// What the pane does: lists, per archived item, the copies outside the
// Master Archive that are byte-for-byte an archived file — what would go,
// what stays and why, and what is FLAGGED (a copy longer than the archive
// master is never offered). One bulk action, "Move N copies to Trash
// (X GB)…", opens the forecast and the confirmation; OK starts ONE Media
// File Operation (ExcessCopiesJob) carrying the very plan that was shown.
// Cancel is the default button.
//
// No file operation lives here — the job's pipeline is the one door.
// The plan is built off-main (`excessCopiesPlan`); the view only renders
// the value it is handed — never O(records) in a body.
// (For Rick: `ExcessCopiesStore` ≈ a small observer-pattern holder: the
// view re-renders when its `plan` member is replaced, nothing else.)

import Combine
import SwiftUI
import VideoScanCore

/// View ▸ Curator — persisted, default OFF.
enum CuratorMode {
    static let key = "curatorMode"
}

struct CuratorMenuToggle: View {
    @AppStorage(CuratorMode.key) private var curator = false
    var body: some View {
        Toggle("Curator", isOn: $curator)
            .help("Show the CLEAN UP section in Triage: excess copies of archived videos, duplicates, possible repeats.")
    }
}

@MainActor
final class ExcessCopiesStore: ObservableObject {
    /// The app's one store (one catalog, one Triage tab). Holds only the
    /// last plan the person asked for — a value, rebuilt on Refresh.
    static let shared = ExcessCopiesStore()

    @Published private(set) var plan: ExcessCopiesPlan?
    @Published private(set) var isBuilding = false

    /// Rebuild the plan off the main actor; one build at a time.
    func refresh(model: VideoScanModel) {
        guard !isBuilding else { return }
        isBuilding = true
        Task { [weak self] in
            let plan = await model.excessCopiesPlan()
            self?.plan = plan
            self?.isBuilding = false
        }
    }

    /// "N · X GB" for the sidebar row; "…" until the first build lands.
    var sidebarCount: String {
        guard let plan else { return "…" }
        return "\(plan.offeredCount) · \(MediaBytes.display(plan.offeredBytes))"
    }
}

/// The sidebar's CLEAN UP rows. Placeholders for the lanes not built yet.
struct CleanUpSidebarSection: View {
    @ObservedObject var store: ExcessCopiesStore
    @Binding var showingExcess: Bool
    let onSelectExcess: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("CLEAN UP")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
            Button(action: onSelectExcess) {
                row(icon: "square.stack.3d.down.right", title: "Excess copies (archived)", count: store.sidebarCount)
            }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(showingExcess ? 0.16 : 0)))
            .accessibilityIdentifier("triage.cleanUp.excessCopies")
            row(icon: "doc.on.doc", title: "Duplicates", count: "coming").foregroundStyle(.secondary)
            row(icon: "film.stack", title: "Possible repeats", count: "coming").foregroundStyle(.secondary)
        }
    }

    private func row(icon: String, title: String, count: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 18)
            Text(title).lineLimit(1)
            Spacer()
            Text(count).font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

/// The main pane: items grouped by archived master, and the bulk action.
struct ExcessCopiesPane: View {
    let model: VideoScanModel
    @ObservedObject var store: ExcessCopiesStore
    @Environment(\.mediaFileOperationsCenterReference) private var fileOpsCenter
    @State private var confirming: ExcessConfirmation?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(14)
            Divider()
            if let plan = store.plan {
                if plan.items.isEmpty {
                    Text("No copies outside the Master Archive match an archived file byte for byte.")
                        .foregroundStyle(.secondary).padding(20)
                    Spacer()
                } else {
                    itemList(plan)
                }
            } else {
                ProgressView("Looking for excess copies…").padding(20)
                Spacer()
            }
        }
        .onAppear { if store.plan == nil { store.refresh(model: model) } }
        .sheet(item: $confirming) { c in
            ExcessCopiesConfirmSheet(plan: c.plan, onCancel: { confirming = nil }, onConfirm: {
                confirming = nil
                start(c.plan)
            })
        }
    }

    private var header: some View {
        let plan = store.plan ?? .empty
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Excess copies of archived videos").font(.title3.weight(.semibold))
                Text(ExcessCopiesWords.summary(plan)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh") { store.refresh(model: model) }.disabled(store.isBuilding)
            Button(ExcessCopiesWords.actionTitle(plan)) { confirming = ExcessConfirmation(plan: plan) }
                .disabled(plan.offeredCount == 0 || model.isReadOnly || store.isBuilding)
                .accessibilityIdentifier("excessCopies.moveToTrash")
        }
    }

    private func itemList(_ plan: ExcessCopiesPlan) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(plan.items) { item in
                    ExcessItemCard(item: item, onKeep: { keep(item) })
                }
            }
            .padding(14)
        }
    }

    private func keep(_ item: ExcessCopiesPlan.Item) {
        guard ExcessKeepStore().keep(item.offered.map(\.id)) else {
            let line = "🔴 \(VideoScanModel.excessLogPrefix): Keep NOT saved — \(ExcessKeepStore.unreadableReason). The list was left as it is."
            model.log(line)
            appLog.write(line)
            return
        }
        model.log("\(VideoScanModel.excessLogPrefix): Keep — \(item.offered.count) cop\(item.offered.count == 1 ? "y" : "ies") of \(item.master.filename) are kept and will not be offered again.")
        store.refresh(model: model)
    }

    private func start(_ plan: ExcessCopiesPlan) {
        guard let center = fileOpsCenter else {
            model.log("\(VideoScanModel.excessLogPrefix): could not start — the Media File Operations center is not available here.")
            return
        }
        center.startExcessCopies(shown: plan, model: model)
    }
}

/// The confirmation sheet's item: the very plan that was shown.
struct ExcessConfirmation: Identifiable {
    let id = UUID()
    let plan: ExcessCopiesPlan
}

/// One archived item: what stays (the archive files), what goes, what is
/// left alone and why, and what is flagged.
struct ExcessItemCard: View {
    let item: ExcessCopiesPlan.Item
    let onKeep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.master.filename).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if !item.offered.isEmpty {
                    Button("Keep these") { onKeep() }.controlSize(.small)
                        .help("Never offer these copies again (remembered).")
                }
            }
            ForEach(item.archiveFiles) { a in
                Text("Stays: \(a.filename) — Master Archive on \(a.volumeName.isEmpty ? "its drive" : a.volumeName) · \(ExcessCopiesWords.fixity(a))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(item.offered) { c in
                ExcessCopyLine(copy: c, note: c.proof.chip, color: .primary, prefix: "Goes:")
            }
            ForEach(item.longer) { c in
                ExcessCopyLine(copy: c, note: ExcessCopiesPlan.longerFlag, color: .orange, prefix: "Flagged:")
            }
            ForEach(item.leftAlone) { l in
                ExcessCopyLine(copy: l.copy, note: l.reason, color: .secondary, prefix: "Stays:")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
    }
}

struct ExcessCopyLine: View {
    let copy: ExcessCopiesPlan.Copy
    let note: String
    let color: Color
    let prefix: String

    var body: some View {
        HStack(spacing: 8) {
            Text(prefix).font(.system(size: 12, weight: .medium)).frame(width: 56, alignment: .leading)
            Text(copy.filename).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                .help(copy.fullPath)
            Text(copy.volumeName.isEmpty ? "—" : copy.volumeName).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(MediaBytes.display(copy.sizeBytes)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            Text(note).font(.system(size: 12)).lineLimit(2)
        }
        .foregroundStyle(color)
    }
}

// MARK: - Forecast + confirmation (Rick's decision 1, plain words)

struct ExcessCopiesConfirmSheet: View {
    let plan: ExcessCopiesPlan
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ExcessCopiesWords.actionTitle(plan).replacingOccurrences(of: "…", with: "?"))
                .font(.title3.weight(.semibold))
            if let only = ExcessCopiesWords.archiveOnlySentence(plan) {
                Text(only).font(.system(size: 14, weight: .semibold)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(ExcessCopiesWords.forecast(plan)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            ScrollView { perItem.frame(maxWidth: .infinity, alignment: .leading) }
                .frame(minHeight: 160, maxHeight: 360)
            Text("Every copy is read in full and must match its archived file byte for byte before it moves; nothing is deleted permanently — it goes to its drive's Trash.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.defaultAction)   // Cancel is the default (Return)
                Button("Move to Trash", role: .destructive, action: onConfirm)
                    .accessibilityIdentifier("excessCopies.confirm")
            }
        }
        .padding(20)
        .frame(minWidth: 620)
    }

    private var perItem: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(plan.items.filter { !$0.offered.isEmpty }) { item in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(item.archiveFiles.filter { a in item.offered.contains { $0.archiveID == a.id } }) { a in
                        Text("Stays: \(a.filename) on \(a.volumeName.isEmpty ? "the archive drive" : a.volumeName) — \(ExcessCopiesWords.fixity(a))")
                            .font(.system(size: 12, weight: .medium))
                    }
                    ForEach(item.offered) { c in
                        Text("Goes: \(c.filename) · \(c.volumeName.isEmpty ? "—" : c.volumeName) · \(MediaBytes.display(c.sizeBytes))")
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
            }
        }
    }
}

/// Every sentence the lane shows, in one place (pure — the tests pin them).
enum ExcessCopiesWords {
    static func actionTitle(_ plan: ExcessCopiesPlan) -> String {
        let n = plan.offeredCount
        return "Move \(n) cop\(n == 1 ? "y" : "ies") to Trash (\(MediaBytes.display(plan.offeredBytes)))…"
    }

    static func summary(_ plan: ExcessCopiesPlan) -> String {
        var parts = ["\(plan.offeredCount) cop\(plan.offeredCount == 1 ? "y" : "ies") (\(MediaBytes.display(plan.offeredBytes))) can go"]
        if plan.leftAloneCount > 0 { parts.append("\(plan.leftAloneCount) left alone") }
        if plan.longerCount > 0 { parts.append("\(plan.longerCount) LONGER than the archive master — flagged") }
        if !plan.backupLikeVolumes.isEmpty { parts.append("looks like an archive backup: " + plan.backupLikeVolumes.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// Rick's decision 1: said plainly, BEFORE OK.
    static func archiveOnlySentence(_ plan: ExcessCopiesPlan) -> String? {
        let only = plan.archiveOnlyItems
        guard !only.isEmpty else { return nil }
        let n = only.count
        let drives = Set(only.flatMap { $0.archiveFiles.map(\.volumeName) }.filter { !$0.isEmpty }).sorted()
        let on = drives.isEmpty ? "" : " on \(drives.joined(separator: ", "))"
        return "After this, the Master Archive copy\(on) will be the ONLY copy of \(n == 1 ? "this video" : "these \(n) videos")."
    }

    /// "last fixity check: 3 Oct 2026, matched" — or that there is none.
    static func fixity(_ a: ExcessCopiesPlan.ArchiveFile) -> String {
        guard let at = a.verifiedAt else { return "no fixity check on record" }
        return "last fixity check: \(at.formatted(date: .abbreviated, time: .omitted)), matched"
    }

    /// Per drive: would go (exact / needs a read), and what is left alone.
    static func forecast(_ plan: ExcessCopiesPlan) -> String {
        var byDrive: [String: (exact: Int, read: Int, bytes: Int64)] = [:]
        for c in plan.offered {
            var d = byDrive[c.volumeName.isEmpty ? "this Mac" : c.volumeName] ?? (0, 0, 0)
            if c.proof == .digest { d.exact += 1 } else { d.read += 1 }
            d.bytes += c.sizeBytes
            byDrive[c.volumeName.isEmpty ? "this Mac" : c.volumeName] = d
        }
        var lines = byDrive.keys.sorted().map { name -> String in
            let d = byDrive[name] ?? (0, 0, 0)
            return "\(name): \(d.exact + d.read) to the Trash (\(MediaBytes.display(d.bytes)))"
                + (d.read > 0 ? " — \(d.read) matched by sampled hash; the full read decides" : "")
        }
        if plan.leftAloneCount > 0 { lines.append("Left alone: \(plan.leftAloneCount) (each with its reason below)") }
        if plan.longerCount > 0 { lines.append("Flagged, never moved: \(plan.longerCount) LONGER than the archive master") }
        return lines.joined(separator: "\n")
    }
}
