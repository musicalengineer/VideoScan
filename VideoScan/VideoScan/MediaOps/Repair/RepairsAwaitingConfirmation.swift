// RepairsAwaitingConfirmation.swift
// The repair copies still waiting for the owner's "Sounds Good", listed in the
// Media File Operations window (DECISIONS 2026-11-17, "Show menu, final shape
// for now": the list left the Catalog's Show menu and lives here).
//
// ONE RULE, ONE ENGINE. Which records wait is `pfAwaitingConfirmation` (the
// rule the Show filter used). Confirming is `VideoScanModel.confirmRepairs`
// (the engine the row menu, the inspector and the Repair sheet call): this
// file stamps nothing itself. "Show in Catalog" is the app-wide
// `pendingCatalogSelection` hop.
//
// SHAPE. `RepairsAwaitingConfirmationStore` (an ObservableObject the window
// owns as a @StateObject — the CatalogShowFilterStore pattern, #337: no new
// VideoScanModel state) holds the prepared list. It is rebuilt when the window
// appears, shortly after a burst of catalog edits (`CatalogEditClock`, 0.25 s
// quiet), and right after a confirm made here. The section's body reads the
// prepared list only.
//
// COST. One pass over the catalog per rebuild (a few flags per record), plus a
// second pass only when at least one repair waits (to name its original).
// Never from a view body. Worst-case memory: one small Item per waiting repair
// (two short strings and two UUIDs — about 200 B each; a catalog holds a
// handful).
//
// (For Rick: the store is a small observable cache with a dirty timer — a C++
// class holding a vector it recomputes on a debounced "catalog changed"
// signal, with the window as its only observer.)

import Combine
import SwiftUI
import VideoScanCore

@MainActor
final class RepairsAwaitingConfirmationStore: ObservableObject {

    /// One waiting repair copy, as the row draws it.
    struct Item: Identifiable, Equatable, Sendable {
        let id: UUID
        let filename: String
        let fullPath: String
        /// The file this copy would replace; nil when that record is no
        /// longer in the catalog (the confirm engine refuses such a copy,
        /// so the row offers no confirm).
        let originalName: String?

        var canConfirm: Bool { originalName != nil }
    }

    /// The prepared list, in catalog order. Read anywhere; written only here.
    @Published private(set) var items: [Item] = []

    private let clock = CatalogEditClock()
    private var ticks: AnyCancellable?

    /// Swift 6: nonisolated so the window's `@StateObject` can build one.
    /// Nothing is read or subscribed here; `start` does that.
    nonisolated init() {}

    /// Begin following the catalog (idempotent): build the list now and
    /// again after each burst of edits. `records` is asked on the main actor.
    func start(reading records: @escaping @MainActor () -> [VideoRecord]) {
        refresh(from: records())
        guard ticks == nil else { return }
        clock.start()
        ticks = clock.$revision.dropFirst().sink { [weak self] _ in
            self?.refresh(from: records())
        }
    }

    /// Stop following (the window closed).
    func stop() {
        ticks = nil
        clock.stop()
    }

    /// Rebuild from `records`. Publishes only when the list changed, so an
    /// unrelated edit never redraws the window.
    func refresh(from records: [VideoRecord]) {
        let fresh = Self.items(in: records)
        if fresh != items { items = fresh }
    }

    /// THE list: every record `pfAwaitingConfirmation` names that is still a
    /// live row — not removed, not set aside, not itself superseded (the rows
    /// the Catalog's table could show, and the ones the confirm engine
    /// accepts). Pure.
    nonisolated static func items(in records: [VideoRecord]) -> [Item] {
        let waiting = records.filter {
            pfAwaitingConfirmation($0) && !$0.isPurged && !$0.isSetAside && !$0.isSuperseded
        }
        guard !waiting.isEmpty else { return [] }
        let wanted = Set(waiting.compactMap(\.derivedFrom))
        var originalNames: [UUID: String] = [:]
        for rec in records where wanted.contains(rec.id) {
            originalNames[rec.id] = rec.filename
        }
        return waiting.map { repair in
            Item(id: repair.id, filename: repair.filename, fullPath: repair.fullPath,
                 originalName: repair.derivedFrom.flatMap { originalNames[$0] })
        }
    }

    // MARK: Words

    static func title(count: Int) -> String {
        count == 1 ? "1 repaired copy is waiting for you to confirm it"
                   : "\(count.formatted()) repaired copies are waiting for you to confirm them"
    }
    static let explanation =
        "Play each one. Sounds Good makes the repaired copy the one the catalog lists; the original is hidden, never deleted."
    static func replaces(_ originalName: String?) -> String {
        originalName.map { "replaces \($0)" } ?? "its original is no longer in the catalog — it cannot be confirmed"
    }
    static let goneNotice =
        "This file is no longer in the catalog — it may have been removed or replaced by a re-scan."
}

// MARK: - The section in the Media File Operations window

/// "N repaired copies are waiting for you to confirm them", one row each with
/// Show in Catalog and Sounds Good. Draws nothing when none wait.
struct RepairsAwaitingConfirmationSection: View {
    @EnvironmentObject var model: VideoScanModel
    @ObservedObject var store: RepairsAwaitingConfirmationStore

    static let rowHeight: CGFloat = 36
    static let maxRowsHeight: CGFloat = 148

    /// Non-nil drives the "no longer in the catalog" notice.
    @State private var notice: String?

    var body: some View {
        if !store.items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal")
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(RepairsAwaitingConfirmationStore.title(count: store.items.count))
                            .font(.system(size: 13, weight: .semibold))
                        Text(RepairsAwaitingConfirmationStore.explanation)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                // Many may wait: the rows scroll inside a bounded height so the
                // job list below keeps its room.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.items) { item in
                            row(item)
                        }
                    }
                }
                .frame(height: min(CGFloat(store.items.count) * Self.rowHeight, Self.maxRowsHeight))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.07)))
            .accessibilityIdentifier("mfo.repairsAwaitingConfirmation")
            .alert("Show in Catalog",
                   isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }),
                   presenting: notice) { _ in
                Button("OK", role: .cancel) { notice = nil }
            } message: { Text($0) }
        }
    }

    private func row(_ item: RepairsAwaitingConfirmationStore.Item) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.filename)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.fullPath)
                Text(RepairsAwaitingConfirmationStore.replaces(item.originalName))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                showInCatalog(item.id)
            } label: {
                Label("Show in Catalog", systemImage: "film.stack")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .help("Jump to this file's row in the Catalog tab, to play it")
            .accessibilityIdentifier("mfo.repairsAwaitingConfirmation.show")
            if item.canConfirm {
                Button(CatalogRowMenuText.confirmRepairs(count: 1)) {
                    confirm(item.id)
                }
                .font(.system(size: 11))
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("mfo.repairsAwaitingConfirmation.confirm")
            }
        }
        .frame(height: Self.rowHeight)
    }

    /// The one confirm engine; then the list is rebuilt at once (the engine's
    /// own save is debounced, and the row must not linger).
    private func confirm(_ id: UUID) {
        _ = model.confirmRepairs(repairIDs: [id])
        store.refresh(from: model.records)
    }

    /// The app-wide "Show in Catalog" hop (the same three steps a finished
    /// job row takes): a focus on that one record, whatever the Show filters say.
    private func showInCatalog(_ id: UUID) {
        guard model.canNavigateToRecord(id: id) else {
            notice = RepairsAwaitingConfirmationStore.goneNotice
            store.refresh(from: model.records)
            return
        }
        UserDefaults.standard.set(1, forKey: "selectedTab")
        model.pendingCatalogSelection = id
        MainWindowHelper.shared.openMainWindow()
    }
}
