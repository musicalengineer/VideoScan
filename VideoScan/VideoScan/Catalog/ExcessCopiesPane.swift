// ExcessCopiesPane.swift
// Triage ▸ CLEAN UP ▸ "Excess copies (archived)" — the catalog-wide view of
// the ONE prune plan (2026-10-21, docs/design/pruneplan_simple_2026-10-21.md);
// "Archived — what next?" shows the same plan for one batch. Shown only with
// View ▸ Curator on (Rick 2026-10-07: "calm by default, depth on request").
//
// What the pane does: lists, per archive file, the copies outside the Master
// Archive that are byte-for-byte that file (checked by default) and the ones
// that are not obvious choices, with why. One bulk action, "Move N to Trash",
// opens the confirmation (Cancel is the default); OK starts ONE PruneApplyJob
// carrying the very plan that was shown.
//
// No file operation lives here — the job's pipeline is the one door. The
// plan is built off-main (`prunePlan(batch: nil)`) and capped to 200 rows;
// the view only renders the value — never O(records) in a body.
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

    /// The plan as SHOWN (capped to `PrunePlan.maxRows` rows).
    @Published private(set) var plan: PrunePlan?
    @Published private(set) var isBuilding = false

    /// Rebuild the plan off the main actor; one build at a time.
    func refresh(model: VideoScanModel) {
        guard !isBuilding else { return }
        isBuilding = true
        Task { [weak self] in
            let plan = await model.prunePlan(batch: nil)
            self?.plan = plan.shown()
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

/// The main pane: the one list, and the bulk action.
struct ExcessCopiesPane: View {
    let model: VideoScanModel
    @ObservedObject var store: ExcessCopiesStore
    @Environment(\.mediaFileOperationsCenterReference) private var fileOpsCenter
    /// Every offered row is checked when a plan lands; the person unchecks.
    @State private var selected: Set<UUID> = []
    @State private var confirming = false

    private static let archiveLabel = "the Master Archive"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(14)
            Divider()
            if let plan = store.plan {
                PruneChecklistView(plan: plan, selected: $selected, archiveLabel: Self.archiveLabel)
                    .padding(14)
            } else {
                ProgressView("Looking for excess copies…").padding(20)
                Spacer()
            }
        }
        .onAppear { if store.plan == nil { store.refresh(model: model) } else { selectAll() } }
        .onReceive(store.$plan) { _ in selectAll() }
        .sheet(isPresented: $confirming) {
            ExcessCopiesConfirmSheet(message: confirmMessage, title: actionTitle,
                                     onCancel: { confirming = false },
                                     onConfirm: { confirming = false; start() })
        }
    }

    private func selectAll() { selected = store.plan?.offeredIDs ?? [] }

    private var actionTitle: String {
        let plan = store.plan ?? .empty
        return PruneWords.actionTitle(count: plan.selectedCount(selected), bytes: plan.selectedBytes(selected))
    }

    private var confirmMessage: String {
        PruneWords.confirmMessage(store.plan ?? .empty, selected: selected, archiveLabel: Self.archiveLabel)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Excess copies of archived videos").font(.title3.weight(.semibold))
            Spacer()
            Button("Refresh") { store.refresh(model: model) }.disabled(store.isBuilding)
            Button(actionTitle + "…") { confirming = true }
                .disabled((store.plan?.selectedCount(selected) ?? 0) == 0 || model.isReadOnly || store.isBuilding)
                .accessibilityIdentifier("excessCopies.moveToTrash")
        }
    }

    private func start() {
        guard let center = fileOpsCenter, let shown = store.plan else {
            model.log("Excess copies: could not start — the Media File Operations center is not available here.")
            return
        }
        let chosen = selected
        _ = center.startedByUser {
            $0.startPruneApply(shown: shown, selected: chosen, batch: nil,
                               batchID: "excess-\(UUID().uuidString.prefix(8))", model: model)
        }
    }
}

/// The confirmation: what goes, and the advice, said plainly BEFORE OK.
struct ExcessCopiesConfirmSheet: View {
    let message: String
    let title: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title + "?").font(.title3.weight(.semibold))
            Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.defaultAction)   // Cancel is the default (Return)
                Button("Move to Trash", role: .destructive, action: onConfirm)
                    .accessibilityIdentifier("excessCopies.confirm")
            }
        }
        .padding(20)
        .frame(minWidth: 560)
    }
}
