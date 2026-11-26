// FootageFoldersSnapshot.swift
// The ONE observed object behind the Footage folders view (docs/design/
// footage_folders_2026_10_16.md §4) — and the model half that feeds it.
//
// Pattern = AnalyzeCoverageSnapshot / CatalogFreshnessSnapshot: the
// model's debounced catalog-change pass projects `records` ONCE on the
// main actor (Sendable rows), the join runs in a detached task, and the
// result lands here equality-gated. The table observes THIS object and
// nothing else; NO O(records) work in any view body.
//
// Two values move:
//   index    the join (families, folders, summaries) — rebuilt on the
//            catalog cadence (`refreshDossierCountsNow`), when Rick's
//            event decisions change (`EventsDecisionStore.revision`), when
//            the machine eras land (the grey folders), and when a selected
//            grey row's hold is released (MachineEstimateFolders.swift), and
//            ONLY while the option is on and the Catalog pane is on screen
//            (`VideoScanModel.setFootageFoldersWanted`) — off by default,
//            the linear view pays nothing;
//   display  the flat rows for what the table shows right now — the
//            filter's survivors, the sort, the open folders, the scope —
//            re-composed off-main whenever any of those or the index
//            changes, equality-gated like everything else.
//
// A derivative landing in the catalog (Transcode / Reformat / Trim /
// Repair / Clean Up) goes through `adoptDerivative`, which publishes a
// `DerivativeLanding` the Catalog pane turns into "open the source's
// folder, select and reveal the new row" (§2: a new derivative lands
// under its source — Rick: "I have to go find it").
//
// Memory: one Index (~30 MB at 100k rows, see FootageFolders.swift) plus
// one Display per compose; a newer request cancels the older task.
//
// (For Rick: `@Published private(set)` ≈ a member with a change signal
// the views subscribe to; `AnyCancellable` ≈ an RAII subscription handle.)

import Combine
import Foundation
import VideoScanCore

// MARK: - The snapshot

@MainActor
final class FootageFoldersSnapshot: ObservableObject {

    @Published private(set) var index = FootageFolders.Index.empty
    @Published private(set) var display = FootageFolders.Display.empty
    /// Test hooks: how many writes actually landed.
    private(set) var indexPublishCount = 0
    private(set) var displayPublishCount = 0

    /// What the table asked for last; re-composed when the index moves.
    struct Request: Equatable {
        var visible: [UUID]
        var sort: FootageFolders.Sort
        var open: Set<UUID>
        var scope: FootageFolders.Scope?
    }

    private(set) var request: Request?
    private var composeTask: Task<Void, Never>?
    private var decisionsWatch: AnyCancellable?
    private var erasWatch: AnyCancellable?

    // MARK: The held grey row (MachineEstimateFolders.swift, THE HELD ROW)

    /// Selected rows that sit in a grey folder → that folder. The join files
    /// their content there whatever the era job says now, until the
    /// selection moves off them. Empty almost always.
    private(set) var machineHolds: [UUID: MachineEraResolver.EstimateFolder] = [:]
    /// The held rows the last join would have moved — a release of one of
    /// these is worth a re-join; any other release is free.
    private(set) var divergedHolds: Set<UUID> = []
    /// A selection larger than this takes no new holds (Select All over the
    /// catalog would cost a hash probe per row on every click). Worst-case
    /// memory: this many small entries.
    nonisolated static let machineHoldLimit = 2_000

    /// The selection changed: hold the grey folder of every selected row
    /// that sits in one (a row already held keeps its hold), release the
    /// rest. Returns true when a released row would now move — the caller
    /// re-joins. O(selection), main actor, event handlers only.
    @discardableResult
    func holdMachinePlacement(selected: Set<UUID>) -> Bool {
        let next = Self.holds(after: selected, current: machineHolds, index: index)
        let released = Set(machineHolds.keys).subtracting(next.keys)
        machineHolds = next
        guard !released.isEmpty else { return false }
        let moves = !released.isDisjoint(with: divergedHolds)
        divergedHolds.subtract(released)
        return moves
    }

    /// Pure: the holds after the selection moves. A selected row keeps its
    /// hold; a newly selected row in a grey folder takes one (its first grey
    /// folder, which is its only one: a content has one era); Rick's folders,
    /// folder rows and loose files are never held.
    nonisolated static func holds(after selected: Set<UUID>, current: [UUID: MachineEraResolver.EstimateFolder],
                                  index: FootageFolders.Index) -> [UUID: MachineEraResolver.EstimateFolder] {
        var next: [UUID: MachineEraResolver.EstimateFolder] = [:]
        let taking = selected.count <= machineHoldLimit
        for id in selected {
            if let kept = current[id] { next[id] = kept; continue }
            guard taking, let folders = index.foldersOf[id],
                  let grey = folders.first(where: MachineEstimateFolders.isEstimateFolder),
                  let folder = MachineEstimateFolders.estimateFolder(fromID: grey) else { continue }
            next[id] = folder
        }
        return next
    }

    /// Follow the machine eras while the folder view is on: a journal pass
    /// that lands new eras re-files the grey rows.
    func watchEras(_ store: MachineEraStore, onChange: @escaping @MainActor () -> Void) {
        erasWatch = store.$eras.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in onChange() }
    }

    init() {}

    /// From the model's pass: the join, and which held rows it kept from
    /// moving. Unchanged → nothing moves.
    func publish(index new: FootageFolders.Index, divergedHolds diverged: Set<UUID> = []) {
        // Only rows still held count (a hold released while the join ran is gone).
        divergedHolds = diverged.intersection(machineHolds.keys)
        guard new != index else { return }
        indexPublishCount += 1
        index = new
        recompose()
    }

    /// From the table: what it shows now. The same request twice is free.
    func compose(visible: [UUID], sort: FootageFolders.Sort, open: Set<UUID>, scope: FootageFolders.Scope?) {
        let req = Request(visible: visible, sort: sort, open: open, scope: scope)
        guard req != request else { return }
        request = req
        recompose()
    }

    /// Synchronous compose for tests and the reveal path (no task hop).
    func composeNow(visible: [UUID], sort: FootageFolders.Sort, open: Set<UUID>, scope: FootageFolders.Scope?) {
        request = Request(visible: visible, sort: sort, open: open, scope: scope)
        composeTask?.cancel()
        publish(display: FootageFolders.compose(index: index, visible: visible, sort: sort, open: open, scope: scope))
    }

    /// Follow Rick's event decisions: a confirm / dismiss / merge changes
    /// which folders exist without touching the catalog.
    func watchDecisions(_ store: EventsDecisionStore, onChange: @escaping @MainActor () -> Void) {
        decisionsWatch = store.$revision.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in onChange() }
    }

    /// The option went off (or the pane left the screen): drop the watch
    /// and the display; the index stays until the next pass replaces it.
    func stop() {
        decisionsWatch = nil
        erasWatch = nil
        composeTask?.cancel()
        request = nil
        machineHolds = [:]
        divergedHolds = []
        publish(display: .empty)
    }

    private func recompose() {
        guard let req = request else { return }
        composeTask?.cancel()
        let idx = index
        composeTask = Task { [weak self] in
            let d = await Task.detached(priority: .userInitiated) {
                FootageFolders.compose(index: idx, visible: req.visible, sort: req.sort, open: req.open, scope: req.scope)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.publish(display: d)
        }
    }

    private func publish(display new: FootageFolders.Display) {
        guard new != display else { return }
        displayPublishCount += 1
        display = new
    }
}

// MARK: - A derivative landing in the catalog

/// What a finished Transcode / Reformat / Trim / Repair / Clean Up job
/// appended: the new row, its source, when. The Catalog pane observes the
/// model's `lastDerivativeLanding` and reveals the row.
struct DerivativeLanding: Equatable, Sendable {
    let id: UUID
    let sourceID: UUID
    let kind: String?
    let at: Date
}

// MARK: - Model half

extension VideoScanModel {

    /// The pane says whether it wants the join kept warm: the option is
    /// on AND the Catalog pane is on screen. Off → nothing is computed.
    func setFootageFoldersWanted(_ wanted: Bool) {
        guard wanted != footageFoldersWanted else { return }
        footageFoldersWanted = wanted
        guard wanted else {
            footageFoldersTask?.cancel()
            footageFolders.stop()
            return
        }
        footageFolders.watchDecisions(EventsDecisionStore.shared) { [weak self] in
            self?.scheduleFootageFoldersRefresh()
        }
        footageFolders.watchEras(machineEras) { [weak self] in
            self?.scheduleFootageFoldersRefresh()
        }
        if !EventsDecisionStore.shared.hasLoaded {
            // The load bumps the store's revision → the watch above refreshes.
            Task { await EventsDecisionStore.shared.load() }
        }
        scheduleFootageFoldersRefresh()
    }

    /// Project on the main actor, join off it, publish once. A newer call
    /// cancels the in-flight one. No-op while nobody wants the folders.
    func scheduleFootageFoldersRefresh() {
        guard footageFoldersWanted else { return }
        footageFoldersTask?.cancel()
        let rows = footageFolderRows()
        // The one folder view (2026-11-17): Rick's folders AND the machine's
        // grey era guesses for every content he has not filed, in ONE join;
        // a selected grey row keeps its folder (the holds) until the
        // selection moves. Copies of the era map and the holds are CoW.
        let own = FootageFolders.Event.events(in: EventsDecisionStore.shared.snapshot())
        let eras = machineEras.eras
        let held = footageFolders.machineHolds
        footageFoldersTask = Task { [weak self] in
            let (index, diverged) = await Task.detached(priority: .utility) {
                let events = FootageFolders.oneViewEvents(rows: rows, own: own, eras: eras, held: held)
                return (FootageFolders.index(rows: rows, events: events),
                        FootageFolders.divergedHolds(rows: rows, own: own, eras: eras, held: held))
            }.value
            guard !Task.isCancelled, let self else { return }
            self.footageFolders.publish(index: index, divergedHolds: diverged)
        }
    }

    /// The ONE O(records) projection — Sendable rows for the join.
    func footageFolderRows() -> [FootageFolders.Row] {
        var out: [FootageFolders.Row] = []
        out.reserveCapacity(records.count)
        for r in records { out.append(footageFolderRow(r)) }
        return out
    }

    func footageFolderRow(_ r: VideoRecord) -> FootageFolders.Row {
        FootageFolders.Row(
            id: r.id,
            contentKey: Self.eventsContentKey(r),
            digest: Self.storedFullDigest(r),
            sizeBytes: r.sizeBytes,
            durationSeconds: r.durationSeconds,
            derivedFrom: r.derivedFrom,
            derivationKind: r.derivationKind,
            duplicateGroupID: r.duplicateGroupID,
            isHidden: r.isPurged || r.isSetAside,
            isSuperseded: r.isSuperseded,
            // Counted as "archived" in the folder line: PROVEN only (GH #327).
            isArchived: isProvenArchived(r),
            isArchiveFile: isArchiveCopy(r) || isInsideMasterArchive(path: r.fullPath),
            codec: Self.codecGeneration(video: r.videoCodec, audio: r.audioCodec),
            frameHeight: Self.frameHeight(fromResolution: r.resolution),
            bitRate: Self.bitRate(from: r.totalBitrate),
            volume: r.volumeName,
            displayCodec: r.displayCodec,
            keys: FootageFolders.SortKeys(
                filename: r.filename, volume: r.displayVolumeLabel, stream: r.streamTypeRaw,
                duration: r.durationSeconds, pixels: r.pixelCount, codec: r.displayCodec,
                dossier: r.dossierChannelCount, size: r.sizeBytes, date: r.resolvedDateSortKey,
                place: r.resolvedPlaceSortKey, people: r.peopleSortKey,
                tag: r.tagSortKey, duplicate: r.duplicateSortKey))
    }

    /// The one door a finished job's derivative enters the catalog by:
    /// replace the row at that path if one exists, else append — exactly
    /// what each job did inline — then say so, once, for the Catalog
    /// pane's reveal. A failed job never gets here.
    func adoptDerivative(_ newRec: VideoRecord, at path: String, from sourceID: UUID) {
        placeRecord(newRec, atPath: path, reason: "a finished job's output replaced the older record at its path")
        lastDerivativeLanding = DerivativeLanding(id: newRec.id, sourceID: sourceID, kind: newRec.derivationKind, at: Date())
    }
}
