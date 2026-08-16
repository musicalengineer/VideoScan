import Foundation
import Combine
import os

private let liveReloadLogger = Logger(subsystem: "Rick-Breen.VideoScan",
                                      category: "live-reload")

extension VideoScanModel {

    // MARK: - Live dossier reload from disk
    //
    // Polls `~/Library/Application Support/VideoScan/catalog.json` for
    // changes and merges the dossier-channel fields onto in-memory
    // records, without overwriting any user-editable fields. Lets the
    // running app pick up dossier results written by the external
    // dossier batch / cross-host merger (`scripts/dossier_batch.py
    // --output-jsonl` + `merge_dossier_jsonl.py`) without quitting +
    // relaunching.
    //
    // Why polling, not file-watch:
    //   The app itself writes catalog.json via saveCatalogDebounced(),
    //   so a naive file-watch would re-merge after every internal save
    //   (no-op work, but wasted CPU). Polling on a 30s cadence with an
    //   mtime check skips no-change ticks cheaply and is simpler than
    //   a write-suppression dance. The dossier workers write ~1 record
    //   per minute on average, so 30s polling captures their output
    //   well within human-perception latency.
    //
    // What we merge (and what we DON'T):
    //   Merged FROM disk (dossier writes these and nothing else):
    //     sceneCaptions, sceneCaptionModel, sceneCaptionDate
    //     audioTranscript, audioTranscriptModel, audioTranscriptDate
    //     ocrDateCandidates, ocrText
    //     inferredRecordDate, inferredDateConfidence
    //     dossierProcessedAt, dossierProcessedBy
    //   Preserved in memory (user edits — never overwritten):
    //     detectedPeople, suspectedPeople, confirmedByUserPeople, rejectedPeople
    //     mediaDisposition, lifecycleStage, archiveStage
    //     starRating, junkScore, notes
    //     everything else

    /// Start the live-reload polling task. Idempotent — repeated calls
    /// reuse the existing task. Cancel via `stopLiveDossierReload`.
    @MainActor
    func startLiveDossierReload(intervalSeconds: Double = 30) {
        guard liveReloadTask == nil else { return }
        let path = catalogStore.fileLocation
        liveReloadLogger.info("Live dossier reload: starting (\(intervalSeconds, privacy: .public)s interval, watching \(path, privacy: .public))")
        // Seed the high-water mark to the file's current mtime so the
        // first tick after launch doesn't re-merge what we just loaded.
        let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        lastLiveReloadMtime = (attrs[FileAttributeKey.modificationDate] as? Date) ?? Date()
        liveReloadTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(intervalSeconds))
                guard !Task.isCancelled else { break }
                await self?.pollAndMergeDossierFromDisk()
            }
        }
    }

    /// Stop the live-reload polling task. Idempotent.
    @MainActor
    func stopLiveDossierReload() {
        liveReloadTask?.cancel()
        liveReloadTask = nil
    }

    /// One poll iteration — check the file's mtime, and if it's newer
    /// than the last successful merge, do the merge. Public for tests.
    @MainActor
    func pollAndMergeDossierFromDisk() async {
        let path = catalogStore.fileLocation
        // mtime check — cheap, avoids parsing 30+ MB JSON when nothing
        // changed. The dossier merger atomically renames a tmp file
        // over the catalog every ~60s, which updates mtime.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[FileAttributeKey.modificationDate] as? Date
        else { return }
        if let last = lastLiveReloadMtime, mtime <= last { return }

        // Decode on a background actor to avoid hitching the main
        // thread on the ~30 MB JSON parse. Once we have records we hop
        // back to the main actor for the merge (touching @Published
        // state).
        let url = URL(fileURLWithPath: path)
        let snapshot: [VideoRecord]? = await Task.detached(priority: .utility) { [url] in
            try? Self.loadRecordsForLiveReload(from: url)
        }.value

        guard let snapshot else {
            liveReloadLogger.warning("Live dossier reload: snapshot decode failed; will retry next tick")
            return
        }

        let merged = mergeDossierFields(from: snapshot)
        lastLiveReloadMtime = mtime
        // We have now reconciled with whatever a cooperating external
        // writer put on disk, so its generation is ours to build on.
        // Without this, a merger that bumps `generation` (as the write
        // contract requires) would make every later save refuse as stale.
        catalogStore.adoptOnDiskGenerationAfterReconcile()
        if merged > 0 {
            liveReloadLogger.info("Live dossier reload: merged dossier fields onto \(merged, privacy: .public) record(s)")
            objectWillChange.send()
        }
    }

    // MARK: - Internals

    /// Background-actor-safe decoder. Mirrors CatalogStore.load()'s
    /// decode helper but skips file-rotation side effects since live
    /// reload is a read-only snapshot. Pair-references are NOT rewired
    /// because we only consume the dossier-channel fields, not the
    /// correlation graph — that lives on the in-memory records we're
    /// merging onto.
    nonisolated private static func loadRecordsForLiveReload(from url: URL) throws -> [VideoRecord] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(CatalogSnapshot.self, from: data)
        return snapshot.records
    }

    /// Apply dossier-channel fields from a freshly-loaded snapshot to
    /// the in-memory records, matched by `fullPath`. ALSO appends
    /// records that exist on disk but not in memory — the case Rick
    /// hit 2026-06-06: viewer (M5) had the app open during a sync,
    /// the catalog file got fresh records via rsync, but model.records
    /// stayed stale because this method only merged existing rows.
    /// Now: existing rows get dossier-merged in-place (preserving any
    /// user edits and the @ObservedObject identity); brand-new rows
    /// are appended at the end, in disk order.
    ///
    /// Returns the count of in-memory records touched (merged + added).
    ///
    /// `internal` (not `private`) so unit tests can drive this
    /// directly without round-tripping through disk.
    @MainActor
    func mergeDossierFields(from snapshot: [VideoRecord]) -> Int {
        // Index in-memory records by fullPath so we can decide
        // "merge onto existing" vs "this one is brand new, append it"
        // in one O(snapshot) pass.
        var existing: [String: VideoRecord] = [:]
        existing.reserveCapacity(records.count)
        for r in records { existing[r.fullPath] = r }

        var changed = 0
        var added = 0
        var newRecords: [VideoRecord] = []

        for fresh in snapshot {
            guard let mem = existing[fresh.fullPath] else {
                // Brand-new record — disk has it, memory doesn't. Add
                // it as-is. The snapshot record already has every
                // field populated by the decoder; we just take the
                // whole object instead of cherry-picking a few.
                // pairedWith back-refs are NOT resolved here (live
                // reload skips that wiring per the loader contract);
                // the next full launch will re-decode and rewire.
                newRecords.append(fresh)
                added += 1
                continue
            }
            // Existing record — merge only the dossier-channel fields,
            // preserving any in-memory user edits (people tags,
            // dispositions, ratings, notes, etc.).
            guard fresh.dossierProcessedAt != nil else { continue }
            if let myAt = mem.dossierProcessedAt,
               let theirsAt = fresh.dossierProcessedAt,
               myAt == theirsAt {
                continue
            }

            // Scene channel
            mem.sceneCaptions      = fresh.sceneCaptions
            mem.sceneCaptionModel  = fresh.sceneCaptionModel
            mem.sceneCaptionDate   = fresh.sceneCaptionDate

            // Whisper channel
            mem.audioTranscript      = fresh.audioTranscript
            mem.audioTranscriptModel = fresh.audioTranscriptModel
            mem.audioTranscriptDate  = fresh.audioTranscriptDate

            // OCR channels
            mem.ocrDateCandidates = fresh.ocrDateCandidates
            mem.ocrText           = fresh.ocrText

            // Inferred date
            mem.inferredRecordDate     = fresh.inferredRecordDate
            mem.inferredDateConfidence = fresh.inferredDateConfidence

            // Provenance
            mem.dossierProcessedAt = fresh.dossierProcessedAt
            mem.dossierProcessedBy = fresh.dossierProcessedBy

            // Search-index update: dossier fields just changed, so the
            // record's haystack needs a refresh or the new caption /
            // transcript text won't be searchable until the next full
            // catalog rebuild. O(record-fields), cheap.
            searchIndex.update(mem)

            changed += 1
        }
        if !newRecords.isEmpty {
            records.append(contentsOf: newRecords)
            // Same: append each new record to the search index so it's
            // immediately searchable.
            for rec in newRecords { searchIndex.update(rec) }
            liveReloadLogger.info("Live reload: appended \(added, privacy: .public) new record(s) from disk snapshot")
        }
        if changed > 0 {
            // The merged-in dossier stamps above are in-place writes the
            // records didSet can't see — refresh the cached chrome counts.
            // (Appends are covered by didSet, but the call is debounced so
            // an extra nudge here is free.)
            noteCatalogChangedForDossierCounts()
        }
        return changed + added
    }
}
