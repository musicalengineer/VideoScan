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
//            catalog cadence (`refreshDossierCountsNow`) and when Rick's
//            event decisions change (`EventsDecisionStore.revision`), and
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

    init() {}

    /// From the model's pass: the join. Unchanged → nothing moves.
    func publish(index new: FootageFolders.Index) {
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
        composeTask?.cancel()
        request = nil
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
        let events = FootageFolders.Event.events(in: EventsDecisionStore.shared.snapshot())
        footageFoldersTask = Task { [weak self] in
            let index = await Task.detached(priority: .utility) {
                FootageFolders.index(rows: rows, events: events)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.footageFolders.publish(index: index)
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
            isArchived: isArchived(r),
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
                place: r.resolvedPlaceSortKey, people: r.peopleSortKey))
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
