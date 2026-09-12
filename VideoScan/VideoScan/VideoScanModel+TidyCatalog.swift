import Foundation
import os

// MARK: - Tidy Catalog (set-aside migration, video-only catalog 2026-07-15)
//
// One-time (re-runnable) migration for the cruft ALREADY in the catalog:
// stills that leaked in, ~81k music-production audio files, and audio
// with no evidence of belonging to video. Rick's decision: HIDE, never
// delete — "only bothersome if it shows up in a list or in a search."
//
// Flow (nag-button pattern): "Tidy Catalog…" computes a DRY-RUN plan
// first — counts by category plus a CSV of the full would-be-set-aside
// list — Rick confirms, THEN it applies. Undo restores the whole batch
// (volume-rename migration undo shape). Apply mutates ONLY the
// `setAsideReason` field: never deletes records, never touches files on
// disk (the scoped-scan-wipe P0 class — record count before == after is
// a pinned sensor).
//
// Classification + evidence are the SAME rules the scan gate uses
// (CatalogScopePolicy / CatalogScopeEvidence) — one policy, two entry
// points. The pair-protection invariant is enforced twice: at plan time
// (protected records never enter the plan) and again at APPLY time (a
// correlate that ran between dry-run and confirm must win).
//
// 2026-09-11 (Rick: "once an item is marked remove/delete/ignore,
// remember not to ingest it again"): two more categories.
//   * "Junk that came back" — active records whose CONTENT matches
//     something already set aside or removed (the ignore list, plus the
//     catalog's own set-aside / purged rows so the category is
//     retroactive). Set aside with the ORIGINAL reason. Measured 2,030
//     such copies on 2026-09-11, none at the original path.
//   * "Copies of archived media" — DRY-RUN ONLY: active records outside
//     the Master Archive whose content has a copy inside it. Count + GB
//     for the sheet; no rows, nothing set aside, nothing touched. The
//     deletion policy is a separate design.
// Every record Tidy sets aside (and every Remove from Catalog) is
// written to the ignore list; Put Back / Undo removes it — the override.
// See IgnoredContentStore.swift and VideoScanModel+IgnoredContent.swift.

let tidyCatalogLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "tidyCatalog")

extension VideoScanModel {

    // MARK: Plan (dry run)

    /// The dry-run result: everything "Tidy Catalog" WOULD set aside,
    /// plus the kept-tallies the summary sheet shows. Sendable value —
    /// computed once, carried into the sheet, applied only on confirm.
    struct TidyCatalogPlan: Sendable, Equatable {
        struct Row: Sendable, Equatable {
            let id: UUID
            let filename: String
            let fullPath: String
            let sizeBytes: Int64
            let reason: CatalogScopePolicy.SetAsideReason
            /// True when this row is "Junk that came back": the reason is
            /// the ORIGINAL entry's reason, not a fresh classification.
            var cameBack: Bool = false
        }
        var rows: [Row] = []
        /// Ambiguous audio KEPT — video-linked per the correlator bar.
        var keptLinkedAudio = 0
        /// Records skipped by the hard invariant (existing pair members /
        /// combine outputs) — never classified, never in `rows`.
        var keptPairProtected = 0
        /// Active records examined (excludes purged + already-set-aside).
        var examined = 0

        /// Per-category tallies — STORED, tallied once in buildTidyPlan
        /// (QA fix, 2026-07-15: these were lazy filter passes over up to
        /// ~90k rows, and TidyCatalogSheet's body evaluates all three per
        /// constraint pass — the no-O(records)-work-in-view-bodies rule).
        var stillCount = 0
        var musicCount = 0
        var unlinkedAudioCount = 0
        var livePhotoComplementCount = 0
        /// Rows whose content matches the ignore list / a set-aside or
        /// purged record (2026-09-11). Included in `rows`.
        var junkCameBackCount = 0
        /// DRY-RUN ONLY (2026-09-11): active records outside the Master
        /// Archive whose content has a copy inside it. NOT in `rows`.
        var archivedCopyCount = 0
        var archivedCopyBytes: Int64 = 0
    }

    /// Compute the dry-run plan. Snapshot on the main actor (cheap value
    /// capture), classify + evidence-test off it (the catalog is ~103k
    /// records — no O(records) scoring on the UI thread).
    func computeTidyCatalogPlan() async -> TidyCatalogPlan {
        // Candidates: active records only. Purged and already-set-aside
        // records are untouched by Tidy (idempotent re-runs).
        var candidates: [TidyCandidate] = []
        candidates.reserveCapacity(records.count)
        var videoSnaps: [CorrelationScorer.Snap] = []
        // Archive evidence for "Copies of archived media": the promote /
        // content-hash / dup-group index (archivedCopy(of:), O(1) per
        // record after one rebuild) plus the archive copies' partialMD5 +
        // size fingerprints for records that never got a content hash.
        var archiveFingerprints = Set<ScanMergeFingerprint>()
        for rec in records where !rec.isPurged && !rec.isSetAside {
            let archiveSelf = isArchiveCopy(rec) || isInsideMasterArchive(path: rec.fullPath)
            if archiveSelf {
                let fp = ScanMergeFingerprint(of: rec)
                if fp.isViable { archiveFingerprints.insert(fp) }
            }
            candidates.append(TidyCandidate(
                snap: CorrelationScorer.snap(rec),
                fullPath: rec.fullPath,
                sizeBytes: rec.sizeBytes,
                ext: rec.ext,
                streamTypeRaw: rec.streamTypeRaw,
                pairProtected: CatalogScopePolicy.isPairProtected(rec),
                partialMD5: rec.partialMD5,
                isArchiveSelf: archiveSelf,
                hasArchivedCopy: !archiveSelf && archivedCopy(of: rec) != nil))
        }
        // Evidence pool: ALL active video-only records — deliberately
        // INCLUDING pair members. The evidence question is "does this
        // audio belong to a video", not "is this video free to pair":
        // a second audio copy sharing an already-paired video's Avid stem
        // still belongs to video. Purged / set-aside records provide no
        // evidence.
        for c in candidates where c.streamTypeRaw == StreamType.videoOnly.rawValue {
            videoSnaps.append(c.snap)
        }
        let ignored = retroactiveIgnoredContentIndex()

        let plan = await Self.buildTidyPlan(candidates: candidates, videoSnaps: videoSnaps,
                                            ignored: ignored, archiveFingerprints: archiveFingerprints)
        tidyCatalogLog.info("Tidy dry run: examined=\(plan.examined) stills=\(plan.stillCount) music=\(plan.musicCount) unlinkedAudio=\(plan.unlinkedAudioCount) livePhoto=\(plan.livePhotoComplementCount) junkCameBack=\(plan.junkCameBackCount) archivedCopies=\(plan.archivedCopyCount) (\(plan.archivedCopyBytes) bytes) keptLinked=\(plan.keptLinkedAudio) pairProtected=\(plan.keptPairProtected)")
        return plan
    }

    /// Sendable carrier for the off-main plan builder.
    struct TidyCandidate: Sendable {
        let snap: CorrelationScorer.Snap
        let fullPath: String
        let sizeBytes: Int64
        let ext: String
        let streamTypeRaw: String
        let pairProtected: Bool
        /// Ignore-list key half (with sizeBytes); "" = never hashed.
        var partialMD5: String = ""
        /// A promoted archive copy or anything under the Master Archive
        /// root — app-managed: never "junk that came back", never a
        /// "copy of archived media" (it IS the archived media).
        var isArchiveSelf: Bool = false
        /// archivedCopy(of:) found a master copy (promote link, content
        /// hash, or high-confidence hash-backed dup group).
        var hasArchivedCopy: Bool = false
    }

    /// Pure off-main plan builder: classification + indexed evidence.
    // #if guard: see evaluateVideoLinks (CI Xcode 16.4 @concurrent alias).
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func buildTidyPlan(
        candidates: [TidyCandidate],
        videoSnaps: [CorrelationScorer.Snap],
        ignored: IgnoredContentIndex = IgnoredContentIndex(),
        archiveFingerprints: Set<ScanMergeFingerprint> = []
    ) async -> TidyCatalogPlan {
        var plan = TidyCatalogPlan()
        plan.examined = candidates.count
        let evidence = CatalogScopeEvidence(videoSnaps: videoSnaps)
        for c in candidates {
            // HARD INVARIANT: pair members exit before classification.
            if c.pairProtected {
                plan.keptPairProtected += 1
                continue
            }
            // Copies of archived media — a TALLY, never a row (dry run;
            // the deletion policy is a separate design).
            if !c.isArchiveSelf {
                let fp = ScanMergeFingerprint(partialMD5: c.partialMD5, sizeBytes: c.sizeBytes)
                if c.hasArchivedCopy || (fp.isViable && archiveFingerprints.contains(fp)) {
                    plan.archivedCopyCount += 1
                    plan.archivedCopyBytes += c.sizeBytes
                }
            }
            // Junk that came back — checked BEFORE classification so the
            // row carries the ORIGINAL reason. Archive-managed rows are
            // never set aside by Tidy.
            if !c.isArchiveSelf,
               let original = ignored.reason(partialMD5: c.partialMD5, sizeBytes: c.sizeBytes,
                                             filename: c.snap.filename) {
                plan.rows.append(.init(id: c.snap.id, filename: c.snap.filename,
                                       fullPath: c.fullPath, sizeBytes: c.sizeBytes,
                                       reason: CatalogScopePolicy.SetAsideReason(rawValue: original) ?? .removedByUser,
                                       cameBack: true))
                plan.junkCameBackCount += 1
                continue
            }
            // Live Photo movie halves are VIDEO by format but Photos
            // artifacts by nature — classified before the format switch.
            if CatalogScopePolicy.isLivePhotoComplement(filename: c.snap.filename) {
                plan.rows.append(.init(id: c.snap.id, filename: c.snap.filename,
                                       fullPath: c.fullPath, sizeBytes: c.sizeBytes,
                                       reason: .livePhotoComplement))
                plan.livePhotoComplementCount += 1
                continue
            }
            switch CatalogScopePolicy.classify(ext: c.ext, streamTypeRaw: c.streamTypeRaw) {
            case .video, .extensionless:
                continue
            case .still:
                plan.rows.append(.init(id: c.snap.id, filename: c.snap.filename,
                                       fullPath: c.fullPath, sizeBytes: c.sizeBytes,
                                       reason: .stillImage))
                plan.stillCount += 1
            case .music:
                plan.rows.append(.init(id: c.snap.id, filename: c.snap.filename,
                                       fullPath: c.fullPath, sizeBytes: c.sizeBytes,
                                       reason: .musicFormat))
                plan.musicCount += 1
            case .ambiguousAudio:
                if evidence.isVideoLinked(c.snap) {
                    plan.keptLinkedAudio += 1
                } else {
                    plan.rows.append(.init(id: c.snap.id, filename: c.snap.filename,
                                           fullPath: c.fullPath, sizeBytes: c.sizeBytes,
                                           reason: .unlinkedAudio))
                    plan.unlinkedAudioCount += 1
                }
            }
        }
        return plan
    }

    // MARK: CSV export of the dry-run list

    /// The full would-be-set-aside list as CSV (Category, Filename, Path,
    /// SizeBytes). Pure — the sheet writes it wherever Rick picks.
    nonisolated static func tidyPlanCSV(_ plan: TidyCatalogPlan) -> String {
        func esc(_ s: String) -> String {
            s.contains(",") || s.contains("\"") || s.contains("\n")
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                : s
        }
        var out = "Category,Filename,Path,SizeBytes\n"
        for row in plan.rows {
            let category = row.cameBack
                ? "Junk that came back — " + row.reason.friendlyLabel
                : row.reason.friendlyLabel
            out += "\(esc(category)),\(esc(row.filename)),\(esc(row.fullPath)),\(row.sizeBytes)\n"
        }
        return out
    }

    // MARK: Apply + Undo

    /// Snapshot of the most recent Tidy apply, for one-tap undo (same
    /// session-scope shape as LastPurgedBatch).
    struct LastTidyBatch: Equatable {
        let ids: [UUID]
    }

    /// Apply a confirmed plan: set `setAsideReason` on every planned
    /// record. Mutates ONLY that field — never removes records, never
    /// touches files on disk. The pair-protection invariant is re-checked
    /// HERE too: a Correlate that paired a record between dry-run and
    /// confirm wins, and the record is skipped. Every record set aside is
    /// also written to the ignore list (content-keyed) so a rescan never
    /// catalogs another copy of it. Returns the count set aside.
    @discardableResult
    func applyTidyCatalog(_ plan: TidyCatalogPlan) -> Int {
        let countBefore = records.count
        var changed: [UUID] = []
        var remembered = 0
        let now = Date()
        for row in plan.rows {
            guard let rec = record(forID: row.id),
                  !rec.isPurged,
                  rec.setAsideReason == nil,
                  !CatalogScopePolicy.isPairProtected(rec)   // invariant, apply-time re-check
            else { continue }
            rec.setAsideReason = row.reason.rawValue
            changed.append(rec.id)
            if noteIgnoredContent(rec, reason: row.reason.rawValue, now: now) { remembered += 1 }
        }
        assert(records.count == countBefore, "Tidy must never add/remove records")
        guard !changed.isEmpty else { return 0 }
        saveCatalogDebounced()
        if remembered > 0 { scheduleIgnoredContentSave() }
        lastTidyBatch = LastTidyBatch(ids: changed)
        log("Tidy Catalog: set aside \(changed.count) file(s) — \(plan.stillCount) photos, \(plan.musicCount) music, \(plan.unlinkedAudioCount) audio with no matching video, \(plan.livePhotoComplementCount) Live Photo halves, \(plan.junkCameBackCount) that came back after being set aside. Nothing was deleted; flip “Show set-aside files” to browse or put any of them back. A rescan will not bring them back (Tidy → Ignored content to put back).")
        appLog.write("Tidy Catalog applied: \(changed.count) record(s) set aside (stills \(plan.stillCount), music \(plan.musicCount), unlinked audio \(plan.unlinkedAudioCount), live photo \(plan.livePhotoComplementCount), came back \(plan.junkCameBackCount)); \(remembered) new ignore-list entr\(remembered == 1 ? "y" : "ies"); records untouched on disk")
        tidyCatalogLog.info("Tidy applied: setAside=\(changed.count) of planned \(plan.rows.count) remembered=\(remembered)")
        return changed.count
    }

    /// "Remove from Catalog" for an explicit selection: set aside with
    /// reason `.removedByUser`. Files are never touched; reversible via the
    /// same Put Back / Undo as Tidy. Pair-protected records are skipped
    /// (Combine's raw material). The content is written to the ignore
    /// list so a rescan never catalogs another copy. Returns the count
    /// set aside.
    @discardableResult
    func removeFromCatalog(recordIDs ids: [UUID]) -> Int {
        guard !isReadOnly else {
            log("Remove from Catalog refused — read-only viewer mode.")
            return 0
        }
        var changed: [UUID] = []
        var remembered = 0
        let now = Date()
        let allowed = Set(excludingMasterArchiveFiles(ids.compactMap { record(forID: $0) },
                                                      verb: "Remove from Catalog").map(\.id))
        for id in ids where allowed.contains(id) {
            guard let rec = record(forID: id), !rec.isPurged, rec.setAsideReason == nil,
                  !CatalogScopePolicy.isPairProtected(rec) else { continue }
            rec.setAsideReason = CatalogScopePolicy.SetAsideReason.removedByUser.rawValue
            changed.append(rec.id)
            if noteIgnoredContent(rec, reason: CatalogScopePolicy.SetAsideReason.removedByUser.rawValue, now: now) {
                remembered += 1
            }
        }
        guard !changed.isEmpty else { return 0 }
        saveCatalogDebounced()
        if remembered > 0 { scheduleIgnoredContentSave() }
        lastTidyBatch = LastTidyBatch(ids: changed)
        noteCatalogRecordsMutated()
        log("Removed \(changed.count) file(s) from the catalog (files untouched). Flip “Show set-aside files” to browse or put any of them back. A rescan will not bring them back (Tidy → Ignored content to put back).")
        return changed.count
    }

    /// Undo the most recent Tidy apply — clears `setAsideReason` on the
    /// whole batch and forgets their content on the ignore list (the
    /// override). Returns true when at least one record was restored.
    @discardableResult
    func undoLastTidyCatalog() -> Bool {
        guard let batch = lastTidyBatch else { return false }
        var restored = 0
        var forgotten = 0
        for id in batch.ids {
            if let rec = record(forID: id), rec.setAsideReason != nil {
                rec.setAsideReason = nil
                restored += 1
                forgotten += forgetIgnoredContent(for: rec)
            }
        }
        lastTidyBatch = nil
        guard restored > 0 else { return false }
        saveCatalogDebounced()
        if forgotten > 0 { scheduleIgnoredContentSave() }
        log("Tidy Catalog: undo — put \(restored) file(s) back in the catalog.")
        appLog.write("Tidy Catalog undo: restored \(restored) set-aside record(s); \(forgotten) ignore-list entr\(forgotten == 1 ? "y" : "ies") removed")
        return true
    }

    /// Dismiss the Tidy undo banner without undoing.
    func dismissTidyUndoBanner() {
        lastTidyBatch = nil
    }

    /// Restore individual/bulk set-aside records (the "Show set-aside
    /// files" browse flow — right-click → Put Back in Catalog). Also
    /// forgets their content on the ignore list — THE OVERRIDE, so a
    /// put-back file's other copies can be cataloged again. Returns the
    /// count restored.
    ///
    /// PUBLISH discipline (QA fix, 2026-07-15 — restoreRecord template):
    /// `setAsideReason` lives on a plain class, so mutating it alone
    /// publishes nothing and the table's recompute triggers never fire.
    /// The observable state here is `lastTidyBatch` (@Published, watched
    /// by `.onChange(of: model.lastTidyBatch)`): restored ids are PRUNED
    /// from it — that both fires the recompute and keeps the Undo
    /// banner's count honest (Undo must not re-hide rows the user just
    /// put back, and an emptied batch drops the banner entirely).
    @discardableResult
    func restoreSetAsideRecords(ids: Set<UUID>) -> Int {
        var restored = 0
        var forgotten = 0
        for id in ids {
            if let rec = record(forID: id), rec.setAsideReason != nil {
                rec.setAsideReason = nil
                restored += 1
                forgotten += forgetIgnoredContent(for: rec)
            }
        }
        guard restored > 0 else { return 0 }
        saveCatalogDebounced()
        if forgotten > 0 { scheduleIgnoredContentSave() }
        if let batch = lastTidyBatch {
            let remaining = batch.ids.filter { !ids.contains($0) }
            lastTidyBatch = remaining.isEmpty ? nil : LastTidyBatch(ids: remaining)
        } else {
            // No Undo batch to prune (older-session set-asides). Publish
            // through the same observed state anyway — assigning nil is a
            // real @Published emission even when the value doesn't change,
            // so the table still refreshes the restored rows.
            lastTidyBatch = nil
        }
        appLog.write("Put back in catalog: \(restored) set-aside record(s) restored; \(forgotten) ignore-list entr\(forgotten == 1 ? "y" : "ies") removed")
        return restored
    }
}
