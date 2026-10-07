// ArchiveAngel+CatalogHints.swift
// The façade's "Ready for archive" / "Angel pick" hints for the Catalog's
// file list (Rick 2026-10-06). What "ready" means is spelled out in
// ArchiveAngelCatalogHint.swift — it is the Angel's own "Ready to archive".
//
// WHEN: after every recount (`publishRecommendations` → `scheduleCatalogHints`),
// i.e. after every sweep, batch change and (debounced) catalog change —
// never in a view body. A row then reads its hint with one dictionary
// lookup (`catalogBadge(for:)`).
//
// COST: the main actor copies a Sendable snapshot of each recommended record
// (O(picks) field copies, no I/O); the readiness assessment and the words
// run OFF the main actor; the result is published back on the main actor.
// A newer recount supersedes a build still running (generation check).
// Memory: one hint (~200 B) per recommended record; see the hint file.
//
// (For Rick: the off-main hop is the `@concurrent nonisolated static`
// function — under Approachable Concurrency a plain `nonisolated async`
// would run on the CALLER's actor, i.e. still the main thread. Think of
// `@concurrent` as "post this to the worker pool", like handing a job to a
// thread pool and awaiting its future.)

import Foundation
import OSLog

private let hintLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "archiveAngel")

/// Every recommended record's Catalog hint, plus a revision rows re-render on.
struct ArchiveAngelCatalogHints: Equatable {
    var byID: [UUID: ArchiveAngelCatalogHint] = [:]
    /// Bumps on every publish (folded into `evidenceRevisionPublisher`).
    var revision = 0
}

extension ArchiveAngel {

    // MARK: Row read (O(1) — safe in a cell)

    /// The Catalog row's Angel chip: "Ready for archive" / "Angel pick" for
    /// a recommended record whose hint matches its CURRENT class, otherwise
    /// the existing badge ("Prepared", or the old chip in the moment before
    /// the hints land). O(1): `badge(for:)`'s lookups plus one dictionary read.
    func catalogBadge(for id: UUID) -> Badge? {
        guard let kind = recommendationClass(for: id) else { return nil }
        if kind.isRecommended, let hint = catalogHints.byID[id], hint.kind == kind {
            return ArchiveAngelCatalogBadge.make(hint: hint)
        }
        return ArchiveAngelCatalogBadge.make(kind: kind, record: store.record(for: id))
    }

    // MARK: Build

    /// Snapshot on the main actor, build off it, publish if still current.
    func scheduleCatalogHints() {
        catalogHintGeneration &+= 1
        let generation = catalogHintGeneration
        let started = Date()
        let inputs = catalogHintInputs()
        let snapshotMs = Date().timeIntervalSince(started) * 1000
        catalogHintTask?.cancel()
        catalogHintTask = Task { [weak self] in
            let built = await Self.buildCatalogHintsOffMain(inputs)
            guard !Task.isCancelled, let self, generation == self.catalogHintGeneration else { return }
            self.publishCatalogHints(built)
            let ready = built.values.lazy.filter(\.isReady).count
            hintLog.debug("catalog hints — \(built.count) pick(s), \(ready) ready for archive (snapshot \(Int(snapshotMs)) ms, total \(Int(Date().timeIntervalSince(started) * 1000)) ms)")
        }
    }

    /// Waits for the hint build in flight (tests; instant when none).
    func catalogHintsSettled() async {
        await catalogHintTask?.value
    }

    /// One Sendable input per recommended record (Ready, Needs a date, Worth
    /// a look — `recommendations.ranked`, already filtered by the effective
    /// class and the live check in this same recount). Main actor, O(picks).
    func catalogHintInputs() -> [ArchiveAngelCatalogHint.Input] {
        guard let catalog else { return [] }
        var out: [ArchiveAngelCatalogHint.Input] = []
        out.reserveCapacity(recommendations.ranked.count)
        for id in recommendations.ranked {
            guard let evidence = store.record(for: id), let rec = catalog.record(forID: id) else { continue }
            out.append(ArchiveAngelCatalogHint.Input(
                id: id, kind: evidence.recommendationClass, filename: rec.filename,
                readiness: ArchiveReadiness.inputs(record: rec),
                videoVerifyStatus: rec.videoVerifyStatus, videoVerifyNote: rec.videoVerifyNote,
                pickLines: evidence.lines.prefix(3).map(\.line)))
        }
        return out
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func buildCatalogHintsOffMain(_ inputs: [ArchiveAngelCatalogHint.Input]) async -> [UUID: ArchiveAngelCatalogHint] {
        ArchiveAngelCatalogHint.build(inputs)
    }
}
