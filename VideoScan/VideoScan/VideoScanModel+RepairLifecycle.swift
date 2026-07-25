import Foundation
import os

// MARK: - Repair lifecycle (GH #132)
//
// identify → repair → confirm → supersede. This file owns the catalog-
// level state transitions:
//
//   confirmRepair(s) — Rick's one-click "Sounds Good": stamps both
//                     records with the "Confirm" journey verb (in
//                     UserNotesMigration.journeyStampVerbs — lock-step),
//                     copies the HUMAN metadata original → repair,
//                     stamps repairConfirmedDate, and retires the
//                     original (supersededByID = repair.id). Human
//                     confirmation is the permanent gate — automated
//                     verification once passed a staggered v1 mux that
//                     Rick's eyes caught.
//   undoConfirmRepair — exact restore of the most recent confirm batch
//                     (the banner's one-tap undo, LastPurgedBatch
//                     pattern: session-scoped, one batch at a time).
//   unsupersede     — "Restore Original (Un-supersede)".
//
// The app NEVER touches the original's bytes — retire/restore are
// catalog-only, exactly like purge and set-aside.
//
// TODO(#132 follow-up): dossier-channel carryover (captions/transcripts
// from the original) is deliberately out of scope — Rick can Analyze
// the repair; cheap to widen later (Manager decision 2026-07-24 #1).

private let lifecycleLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                  category: "repairLifecycle")

// MARK: - External repair adoption (Link Repaired Copy…, GH #132 P4)

/// Provenance tag for adopted externally-repaired files — the sibling
/// of `RebuildAudioFix.derivationKind`. Lock-step with
/// `VideoRecord.repairDerivationKinds` (sensor in the adoption tests):
/// falling out of that set would silently drop adopted files from the
/// confirm lifecycle.
enum ExternalRepairAdoption {
    static let derivationKind = "externalRepair"
}

/// Why an adoption was refused — family language, surfaced in an alert.
enum AdoptRepairError: LocalizedError, Equatable {
    case originalNotFound
    case fileUnreadable(String)
    /// QA B1 (2026-07-24): the picker opens in the damaged file's own
    /// folder, so a stray double-click can land on the original itself.
    /// Adopting a file as its OWN repair would orphan the record
    /// (dangling derivedFrom, Confirm no-ops forever) — refuse it.
    case sameFileAsOriginal

    var errorDescription: String? {
        switch self {
        case .originalNotFound:
            return "The damaged file this repair belongs to is no longer in the catalog — nothing was linked."
        case .fileUnreadable(let detail):
            return "That file couldn't be read as media\(detail.isEmpty ? "" : " (\(detail))") — nothing was linked. Check that it plays, then try again."
        case .sameFileAsOriginal:
            return "That's the same file as the damaged original — pick the repaired copy instead. Nothing was linked."
        }
    }
}

extension VideoScanModel {

    // MARK: Undo snapshots

    /// Everything ONE confirm mutated, captured BEFORE mutation so undo
    /// restores EXACTLY — including the human-metadata fields the
    /// inheritance merged into the repair.
    struct ConfirmSnapshot: Equatable {
        let repairID: UUID
        let originalID: UUID
        // Repair-side pre-confirm values (inheritance targets + stamp).
        let repairTags: [String]
        let repairUserNotes: String
        let repairConfirmedByUserPeople: [ConfirmedTag]
        let repairRejectedPeople: [String]
        let repairStarRating: Int
        let repairMediaDisposition: MediaDisposition
        let repairLifecycleStage: LifecycleStage
        let repairArchiveStage: ArchiveStage
        let repairUserDate: String?
        let repairUserDateConfidence: String?
        let repairNotes: String
        // Original-side pre-confirm values.
        let originalNotes: String
    }

    /// The most recent confirm action (single click or multi-select
    /// batch). One banner target at a time — a new confirm supersedes
    /// the previous batch, exactly like LastPurgedBatch.
    struct LastConfirmBatch: Equatable {
        let snapshots: [ConfirmSnapshot]
    }

    // MARK: Human-metadata inheritance

    /// Copy the HUMAN metadata from the original onto its repair
    /// (Confirm-time carryover, GH #132 §3 — machine metadata is
    /// re-derived by the repair's own probe and is NOT copied; the
    /// original's `notes` File Journey lines are per-file and stay put).
    ///
    /// Merge rules — never clobber values Rick already put on the
    /// repair:
    ///   tags                    union (case-insensitive, WorkflowTags)
    ///   userNotes               copy; append with a newline when the
    ///                           repair already has text
    ///   confirmedByUserPeople   transfer only when the repair has NO
    ///                           judgment for that person — neither a
    ///                           confirmation NOR a rejection (deep-test
    ///                           finding 3: the repair-side judgment is
    ///                           Rick's most recent decision and the
    ///                           one-tier invariant must hold, matching
    ///                           ConfirmPersonSheet.catalogWriteback)
    ///   rejectedPeople          same no-judgment rule, both tiers
    ///                           checked, case-insensitive (finding 4)
    ///   starRating              max of the two
    ///   mediaDisposition        copy only while repair is unreviewed
    ///   lifecycleStage          copy only while repair is cataloged
    ///   archiveStage            copy only while repair is .none
    ///   userDate(+confidence)   copy only when repair's is nil
    @MainActor
    func applyHumanMetadataInheritance(from original: VideoRecord, to repair: VideoRecord) {
        for tag in original.tags {
            repair.tags = WorkflowTags.adding(tag, to: repair.tags)
        }
        if !original.userNotes.isEmpty {
            repair.userNotes = repair.userNotes.isEmpty
                ? original.userNotes
                : "\(repair.userNotes)\n\(original.userNotes)"
        }
        // People tiers (deep-test findings 3 + 4): a person lives in
        // EXACTLY ONE tier, and the repair's own judgment — confirmed
        // OR rejected — is Rick's most recent decision, so an
        // original-side entry transfers only when the repair has NO
        // judgment at all for that person. All identity comparisons
        // case-insensitive, like every other people comparison in the
        // app (ConfirmPersonSheet.catalogWriteback).
        func repairHasJudgment(for name: String) -> Bool {
            repair.confirmedByUserPeople.contains {
                $0.name.compare(name, options: .caseInsensitive) == .orderedSame
            } || repair.rejectedPeople.contains {
                $0.compare(name, options: .caseInsensitive) == .orderedSame
            }
        }
        for confirmed in original.confirmedByUserPeople
        where !repairHasJudgment(for: confirmed.name) {
            repair.confirmedByUserPeople.append(confirmed)
        }
        for name in original.rejectedPeople where !repairHasJudgment(for: name) {
            repair.rejectedPeople.append(name)
        }
        repair.starRating = max(repair.starRating, original.starRating)
        if repair.mediaDisposition == .unreviewed {
            repair.mediaDisposition = original.mediaDisposition
        }
        if repair.lifecycleStage == .cataloged {
            repair.lifecycleStage = original.lifecycleStage
        }
        if repair.archiveStage == .none {
            repair.archiveStage = original.archiveStage
        }
        if repair.userDate == nil {
            repair.userDate = original.userDate
            repair.userDateConfidence = original.userDateConfidence
        }
    }

    // MARK: Confirm

    /// The one-click "Sounds Good — Confirm Repair". Returns false (a
    /// complete no-op — nothing mutated, nothing saved) when the id is
    /// not an awaiting-confirmation repair or its original is gone from
    /// the catalog; true after the full stamp + inherit + supersede.
    /// Idempotent: a second confirm of the same repair is a no-op
    /// (repairConfirmedDate is already set).
    @MainActor
    @discardableResult
    func confirmRepair(repairID: UUID) -> Bool {
        confirmRepairs(repairIDs: [repairID]) == 1
    }

    /// Multi-select confirm: every awaiting-confirmation repair in
    /// `repairIDs` whose original is still in the catalog gets the full
    /// stamp + inherit + supersede; the rest are skipped. Arms ONE undo
    /// batch covering everything confirmed here (a later confirm
    /// supersedes it). Returns the count actually confirmed.
    @MainActor
    @discardableResult
    func confirmRepairs(repairIDs: Set<UUID>) -> Int {
        guard !repairIDs.isEmpty else { return 0 }
        var snapshots: [ConfirmSnapshot] = []
        let stampFormatter = ISO8601DateFormatter()
        for repair in records where repairIDs.contains(repair.id) {
            // QA M1 (2026-07-24): a purged or set-aside repair copy must
            // not be confirmable — confirming it would supersede the
            // original too, hiding the footage behind TWO invisible
            // records. Model-layer gate so every entry point (context
            // menu, inspector button, future callers) is covered.
            guard repair.isAwaitingConfirmation,
                  !repair.isPurged, !repair.isSetAside,
                  let originalID = repair.derivedFrom,
                  let original = record(forID: originalID)
            else { continue }

            // Snapshot BEFORE mutation so undo restores exactly.
            snapshots.append(ConfirmSnapshot(
                repairID: repair.id,
                originalID: original.id,
                repairTags: repair.tags,
                repairUserNotes: repair.userNotes,
                repairConfirmedByUserPeople: repair.confirmedByUserPeople,
                repairRejectedPeople: repair.rejectedPeople,
                repairStarRating: repair.starRating,
                repairMediaDisposition: repair.mediaDisposition,
                repairLifecycleStage: repair.lifecycleStage,
                repairArchiveStage: repair.archiveStage,
                repairUserDate: repair.userDate,
                repairUserDateConfidence: repair.userDateConfidence,
                repairNotes: repair.notes,
                originalNotes: original.notes))

            applyHumanMetadataInheritance(from: original, to: repair)

            // File Journey stamps — exact "<Verb> <ISO8601>: detail"
            // shape; "Confirm" is in journeyStampVerbs (lock-step, or
            // these would migrate into userNotes).
            let stamp = stampFormatter.string(from: Date())
            let repairNote = "Confirm \(stamp): repair confirmed by Rick — replaces \(original.filename)"
            let originalNote = "Confirm \(stamp): superseded by \(repair.filename) — confirmed by Rick"
            repair.notes = repair.notes.isEmpty
                ? repairNote
                : "\(repair.notes)\n\(repairNote)"
            original.notes = original.notes.isEmpty
                ? originalNote
                : "\(original.notes)\n\(originalNote)"

            repair.repairConfirmedDate = Date()
            original.supersededByID = repair.id

            searchIndex.update(repair)
            searchIndex.update(original)
            lifecycleLog.info("confirm: \(repair.filename, privacy: .public) confirmed — supersedes \(original.filename, privacy: .public)")
            appLog.write("confirm repair: \(repair.filename) confirmed by Rick — replaces \(original.filename) (original hidden, never deleted)")
        }
        guard !snapshots.isEmpty else { return 0 }
        saveCatalogDebounced()
        lastConfirmBatch = LastConfirmBatch(snapshots: snapshots)
        return snapshots.count
    }

    // MARK: Undo

    /// Exact restore of the most recent confirm batch: each repair's
    /// inherited fields, both records' notes (dropping the Confirm
    /// stamps), the confirm dates, and the originals' supersede markers.
    /// Returns true when something was restored; drops the banner
    /// either way.
    @MainActor
    @discardableResult
    func undoConfirmRepair() -> Bool {
        guard let batch = lastConfirmBatch else { return false }
        lastConfirmBatch = nil
        var restored = 0
        for snap in batch.snapshots {
            // QA m3 (2026-07-24): each side restores independently — a
            // missing repair record (hard-deleted after confirm) must
            // NOT strand the original in the superseded shadow.
            var touchedSomething = false
            if let repair = record(forID: snap.repairID) {
                repair.tags = snap.repairTags
                repair.userNotes = snap.repairUserNotes
                repair.confirmedByUserPeople = snap.repairConfirmedByUserPeople
                repair.rejectedPeople = snap.repairRejectedPeople
                repair.starRating = snap.repairStarRating
                repair.mediaDisposition = snap.repairMediaDisposition
                repair.lifecycleStage = snap.repairLifecycleStage
                repair.archiveStage = snap.repairArchiveStage
                repair.userDate = snap.repairUserDate
                repair.userDateConfidence = snap.repairUserDateConfidence
                repair.notes = snap.repairNotes
                repair.repairConfirmedDate = nil
                searchIndex.update(repair)
                touchedSomething = true
                lifecycleLog.info("confirm undo: \(repair.filename, privacy: .public) back to awaiting confirmation")
            }

            if let original = record(forID: snap.originalID) {
                original.notes = snap.originalNotes
                original.supersededByID = nil
                searchIndex.update(original)
                touchedSomething = true
                lifecycleLog.info("confirm undo: \(original.filename, privacy: .public) un-superseded")
            }
            if touchedSomething { restored += 1 }
        }
        guard restored > 0 else { return false }
        saveCatalogDebounced()
        return true
    }

    /// Dismiss the confirm-undo banner without restoring.
    @MainActor
    func dismissConfirmUndoBanner() {
        lastConfirmBatch = nil
    }

    // MARK: Adopt an externally-repaired file (Link Repaired Copy…)

    /// Catalog a file Rick repaired OUTSIDE the app (the
    /// JustPatsHouse_Recovered_v2 case) as the repaired copy of a
    /// damaged record: probe it, wire the same two-way provenance the
    /// rebuild writes (derivedFrom + "externalRepair" + "Verify Audio"
    /// journey stamps), carry the hand-entered date, and enter the
    /// repaired-unconfirmed state automatically (derivedFrom set,
    /// repairConfirmedDate nil) — confirm is still Rick's click.
    /// A probe failure throws and inserts NOTHING.
    ///
    /// QA B1 hardening (2026-07-24):
    ///   * Picking the ORIGINAL itself is refused (the picker opens in
    ///     the damaged file's own folder — a self-pick would replace
    ///     the original with a self-orphaned "repair" and lose its
    ///     whole catalog journey).
    ///   * A path collision with an ALREADY-CATALOGED record merges
    ///     provenance onto that record IN PLACE — its id and every
    ///     human field (tags, userNotes, people, starRating, verdicts,
    ///     dispositions) survive; only derivedFrom/derivationKind, the
    ///     journey stamp, and a nil-only date carryover are written.
    ///     The old upsert substituted a brand-new instance, silently
    ///     discarding all of that.
    @MainActor
    @discardableResult
    func adoptExternalRepair(originalID: UUID, fileURL: URL) async throws -> VideoRecord {
        guard let original = record(forID: originalID) else {
            throw AdoptRepairError.originalNotFound
        }
        // A repair must be a DIFFERENT file than its original — refuse
        // the self-pick before touching anything (raw, standardized,
        // and catalog-resolved forms of the picked path all checked).
        guard fileURL.path != original.fullPath,
              fileURL.standardizedFileURL.path != original.fullPath,
              record(forPath: fileURL.path)?.id != original.id else {
            throw AdoptRepairError.sameFileAsOriginal
        }

        let probed = await probeFile(url: fileURL)
        guard probed.streamType != .ffprobeFailed else {
            throw AdoptRepairError.fileUnreadable(probed.isPlayable)
        }

        // Already cataloged? Merge in place — never substitute a new
        // instance. Otherwise the fresh probe joins the catalog.
        // (Resolved AFTER the probe's await — the MainActor can
        // interleave other catalog work while ffprobe runs.)
        let adopted: VideoRecord
        if let existing = record(forPath: fileURL.path) {
            adopted = existing
        } else {
            adopted = probed
            records.append(probed)
        }

        // Same provenance shape as RebuildAudioJob.catalogRebuildOutput.
        adopted.derivedFrom = original.id
        adopted.derivationKind = ExternalRepairAdoption.derivationKind
        // The adopted copy is the same footage — Rick's hand-entered
        // date carries over with its confidence (GH #117 convention),
        // but a date he already put on the adopted record itself wins.
        if adopted.userDate == nil {
            adopted.userDate = original.userDate
            adopted.userDateConfidence = original.userDateConfidence
        }

        // "Verify Audio" journey stamps both ways — the existing verb
        // (already in journeyStampVerbs), no new verb needed.
        let stamp = ISO8601DateFormatter().string(from: Date())
        let sourceNote = "Verify Audio \(stamp): repaired copy linked: \(fileURL.lastPathComponent)"
        let derivedNote = "Verify Audio \(stamp): adopted as repaired copy of \(original.filename)"
        original.notes = original.notes.isEmpty
            ? sourceNote
            : "\(original.notes)\n\(sourceNote)"
        adopted.notes = adopted.notes.isEmpty
            ? derivedNote
            : "\(adopted.notes)\n\(derivedNote)"

        // Index ordering (QA B1 ride-along): the adopted record last, so
        // on any same-key overlap the record that OWNS the path after
        // this call also owns the index entry.
        searchIndex.update(original)
        searchIndex.update(adopted)
        NotificationCenter.default.post(name: .videoScanCatalogMutated, object: nil)
        saveCatalogDebounced()

        lifecycleLog.info("adopt: \(fileURL.lastPathComponent, privacy: .public) linked as repaired copy of \(original.filename, privacy: .public)")
        appLog.write("link repaired copy: \(fileURL.lastPathComponent) adopted as repaired copy of \(original.filename) — awaiting confirmation")
        return adopted
    }

    // MARK: Un-supersede

    /// Clear the superseded marker on a single record — "Restore
    /// Original (Un-supersede)" on a superseded row. The original
    /// returns to the default view and to correlate/dup candidacy; the
    /// repair record keeps its confirmation and its Confirm stamps (the
    /// history stays honest — un-supersede writes NO journey stamp,
    /// mirroring purge restore; Manager decision 2026-07-24 #4).
    /// Returns true when a record was actually mutated.
    @discardableResult
    func unsupersede(id: UUID) -> Bool {
        guard let rec = record(forID: id),
              rec.supersededByID != nil else { return false }
        rec.supersededByID = nil
        searchIndex.update(rec)
        saveCatalogDebounced()
        // A manual restore of a record inside the armed undo batch makes
        // that undo stale — drop the banner (restoreRecord's rule,
        // simplified to whole-batch because partial confirm-undo would
        // half-restore a stamp pair).
        if lastConfirmBatch?.snapshots.contains(where: { $0.originalID == id }) == true {
            lastConfirmBatch = nil
        }
        lifecycleLog.info("unsupersede: \(rec.filename, privacy: .public) restored to the default view")
        return true
    }
}
