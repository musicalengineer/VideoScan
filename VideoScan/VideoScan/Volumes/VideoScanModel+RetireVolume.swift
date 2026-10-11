import Foundation
import VideoScanCore

// MARK: - PendingRetireOffer

/// State payload for the post-Relocate retire modal. `Identifiable`
/// conformance lets SwiftUI bind a `.sheet(item:)` to it directly. The
/// fields are everything the sheet needs to render and dispatch — no
/// look-back into the model required.
struct PendingRetireOffer: Identifiable, Equatable {
    let id = UUID()
    /// `/Volumes/Mini2TB`-shape root. Used to look up the scan target
    /// when the user confirms Retire.
    let volumeRootPath: String
    /// Friendly volume name for headline display ("Maxtor500FW").
    let volumeName: String
    /// Total catalogued records on the volume (all accounted for —
    /// `isAccountedForRetire` — that's what triggered the offer). Drives
    /// the "All N records…" headline.
    let recordCount: Int
    /// Default reason text the modal pre-populates. User-editable.
    let suggestedReason: String
    /// Pre-aggregated witness union to stamp into `retiredWitnesses`.
    /// Computed by `aggregateRetiredWitnesses` before the offer is set.
    let witnesses: [String]
}

// MARK: - VideoScanModel+RetireVolume
//
// §1B Retire Volume — companion feature to Relocate. After a Relocate run
// leaves 100% of catalogued records on the source volume accounted for
// (Bucket B: missing, labelled `.manuallyDeleted`; Bucket E: skipped because
// a proven copy is elsewhere, witness note), the volume itself can be retired:
// physically disconnected with no expectation of reconnection. Retired
// volumes are excluded from scan suggestions, "missing volume" dashboard
// nags, and reachability complaints, but their records remain in the
// catalog forever for audit and Compare & Rescue lookups.
//
// Real-world driving case: Maxtor500FW. Bucket E showed 100% of the
// records were duplicated on healthier drives; rather than physically
// reconnect every time the dashboard noticed it was offline, Rick wants
// to mark it retired and never see the nag again.
//
// Fully reversible: Reinstate clears all three retire fields. See
// docs/design/relocate_volume_plan.md §1B.

extension VideoScanModel {

    // MARK: - Counting helpers (pure / nonisolated where possible)

    /// Total number of catalog records whose `fullPath` is under
    /// `volumeRootPath` (trailing-slash safe). Counts every record
    /// regardless of `archiveStage` — the denominator for the 100%
    /// disposed check.
    nonisolated static func totalRecordsOn(volumeRootPath: String,
                                           in all: [VideoRecord]) -> Int {
        recordsScoped(to: volumeRootPath, in: all).count
    }

    /// Is this record ACCOUNTED FOR on its drive — nothing here still needs
    /// copying? Two Migrate outcomes leave a record behind under the source:
    ///   * Bucket B — the source file was missing: labelled `.manuallyDeleted`;
    ///   * Bucket E — skipped because a proven copy is on another drive: the
    ///     label is untouched (2026-10-11 — a skip is not a delete) and the
    ///     record carries a skip note whose `source` is ITS OWN CURRENT PATH
    ///     (`ownSkipWitnesses`). A note carried to another path by a later
    ///     copy or relink, or in the old sourceless shape, does not count.
    /// Catalog facts only. Such a record is never a Migrate witness
    /// (`isLiveRelocateWitness`) nor a relink source. Whether the drive may
    /// be RETIRED also needs a witness that still holds — `isDisposedForRetire`.
    nonisolated static func isAccountedForRetire(archiveStage: ArchiveStage, notes: String,
                                                 fullPath: String) -> Bool {
        archiveStage == .manuallyDeleted || ownSkipWitnesses(notes: notes, fullPath: fullPath) != nil
    }

    /// The marker `formatSafelyRedundantNote` writes (and
    /// `parseWitnessesFromNote` reads).
    nonisolated static let skippedWithWitnessMarker = "reason=dup-on-other-volume"

    /// The witnesses named by this record's OWN skip lines — those whose
    /// `source` is `fullPath`. nil = no such line (never skipped here).
    nonisolated static func ownSkipWitnesses(notes: String, fullPath: String) -> [String]? {
        guard !fullPath.isEmpty, notes.contains(skippedWithWitnessMarker) else { return nil }
        var out: [String]?
        for line in notes.split(separator: "\n") where line.contains(skippedWithWitnessMarker) {
            guard skipNoteSource(line) == fullPath else { continue }
            out = (out ?? []) + parseWitnessesFromNote(String(line))
        }
        return out
    }

    /// The `source="…"` field of one skip line; nil for the old shape.
    nonisolated static func skipNoteSource(_ line: Substring) -> String? {
        guard let start = line.range(of: " source=\"") else { return nil }
        var path = ""
        var escaped = false
        for ch in line[start.upperBound...] {
            if escaped { path.append(unescapedNoteChar(ch)); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { return path }
            path.append(ch)
        }
        return nil
    }

    /// Paths of catalog rows that can vouch for a skipped file NOW: a live
    /// witness (not purged, trashed, labelled deleted, nor itself accounted
    /// for) on a drive that is not retired.
    nonisolated static func liveWitnessPaths(in all: [VideoRecord], retiredRoots: [String]) -> Set<String> {
        var out = Set<String>()
        for r in all where r.isLiveRelocateWitness
            && !retiredRoots.contains(where: { PathScope.contains(r.fullPath, within: $0) }) {
            out.insert(r.fullPath)
        }
        return out
    }

    /// Disposed for the RETIRE check: labelled missing (Bucket B, as
    /// before), or skipped here with at least one witness that is a live
    /// row (`liveWitnesses`) OFF this drive. A skip whose witnesses all left
    /// the catalog (Delete Duplicates trashed them), went to a retired drive
    /// or were themselves skipped is not disposed — it may be the only copy.
    /// CATALOG FACTS ONLY — it decides whether Retire is offered. The label
    /// half is not a proof (tab-charter audit T1: 959 false labels); the
    /// retire gate itself (`retireCheck` → `RetireGate.evaluate`)
    /// re-proves every labelled row on disk before a drive is retired.
    nonisolated static func isDisposedForRetire(archiveStage: ArchiveStage, notes: String, fullPath: String,
                                                volumeRootPath: String, liveWitnesses: Set<String>) -> Bool {
        if archiveStage == .manuallyDeleted { return true }
        guard let witnesses = ownSkipWitnesses(notes: notes, fullPath: fullPath) else { return false }
        return witnesses.contains { liveWitnesses.contains($0) && !PathScope.contains($0, within: volumeRootPath) }
    }

    /// Subset of `totalRecordsOn` that is disposed (`isDisposedForRetire`).
    /// Numerator for the 100% disposed check.
    nonisolated static func disposedOn(volumeRootPath: String, in all: [VideoRecord],
                                       retiredRoots: [String] = []) -> Int {
        let live = liveWitnessPaths(in: all, retiredRoots: retiredRoots)
        return recordsScoped(to: volumeRootPath, in: all).filter {
            isDisposedForRetire(archiveStage: $0.archiveStage, notes: $0.notes, fullPath: $0.fullPath,
                                volumeRootPath: volumeRootPath, liveWitnesses: live)
        }.count
    }

    /// Count of records that originated on this volume — i.e. whose
    /// `originVolume` matches OR whose `originalFullPath` is under
    /// `volumeRootPath`. These records may have been relocated to
    /// another volume via Bucket-D adoption or Bucket-A copy, so their
    /// current `fullPath` no longer matches the source. We still want
    /// to count them when deciding retire eligibility, because the
    /// source volume IS effectively empty / dispositioned.
    nonisolated static func originatedOnCount(volumeRootPath: String,
                                              in all: [VideoRecord]) -> Int {
        let name = (volumeRootPath as NSString).lastPathComponent
        let pathPrefix = volumeRootPath.hasSuffix("/") ? volumeRootPath : volumeRootPath + "/"
        return all.filter { r in
            if let ov = r.originVolume, ov == name { return true }
            if let op = r.originalFullPath, op.hasPrefix(pathPrefix) { return true }
            return false
        }.count
    }

    /// Pure predicate: "should the retire prompt fire after the current
    /// Relocate run?" True iff the volume has at least one record (current
    /// OR originated-here) AND every record currently under this volume's
    /// path is accounted for (`isAccountedForRetire`). That covers three
    /// migration outcomes:
    ///   - Bucket E (safely redundant): records stay under this path,
    ///     skipped, with the witness note
    ///   - Bucket B (source not found): records stay, labelled `.manuallyDeleted`
    ///   - Bucket D (adopted) / Bucket A (copied): records' `fullPath`
    ///     is rewritten away from this volume — gate passes because the
    ///     "currently under this volume" set becomes empty (0 == 0 trivially
    ///     satisfies "no non-deleted record here")
    /// Used by the post-Relocate hook AND directly by tests.
    nonisolated static func shouldOfferRetire(volumeRootPath: String,
                                              in all: [VideoRecord],
                                              retiredRoots: [String] = []) -> Bool {
        let total = totalRecordsOn(volumeRootPath: volumeRootPath, in: all)
        let originated = originatedOnCount(volumeRootPath: volumeRootPath, in: all)
        // Volume must have been used at some point (currently has records
        // OR had records that moved away). Pure-empty volumes that were
        // never scanned shouldn't show as retire-eligible.
        guard total > 0 || originated > 0 else { return false }
        // Every record currently under this path must be accounted for.
        // If total == 0 (all records moved via Bucket A/D), this is
        // trivially true.
        return disposedOn(volumeRootPath: volumeRootPath, in: all, retiredRoots: retiredRoots) == total
    }

    // MARK: - Witness aggregation

    /// Walk every accounted-for record on the volume and pull out
    /// the witness paths embedded in their Bucket E audit-trail notes.
    /// Returns a deduped sorted union. Records with non-Bucket-E disposal
    /// notes (plain Bucket B "source file not found") contribute nothing
    /// — only the structured `formatSafelyRedundantNote` lines parse.
    ///
    /// Worst case: O(records on volume × witnesses per record). With ~5
    /// witnesses cap per record (RelocateReconcile.maxWitnessSample) and
    /// catalog volumes up to a few thousand records, the result set stays
    /// in the low thousands of strings — trivial in-memory footprint.
    nonisolated static func aggregateRetiredWitnesses(
        volumeRootPath: String,
        in all: [VideoRecord],
        retiredRoots: [String] = []
    ) -> [String] {
        let scoped = recordsScoped(to: volumeRootPath, in: all)
        let live = liveWitnessPaths(in: all, retiredRoots: retiredRoots)
        var seen = Set<String>()
        for rec in scoped {
            if rec.archiveStage == .manuallyDeleted {
                // Legacy Bucket B/E rows: every witness line they carry.
                seen.formUnion(parseWitnessesFromNote(rec.notes))
            } else if let own = ownSkipWitnesses(notes: rec.notes, fullPath: rec.fullPath) {
                // Only the witnesses that hold: a live row off this drive.
                seen.formUnion(own.filter { live.contains($0) && !PathScope.contains($0, within: volumeRootPath) })
            }
        }
        return seen.sorted()
    }

    /// Extract the quoted path list from a Reconcile note formatted by
    /// `formatSafelyRedundantNote`. The note shape is:
    ///   `Reconcile <stamp>: reason=dup-on-other-volume witnesses=["..","..."] totalWitnesses=N`
    /// A record's `notes` field can carry multiple such lines (one per
    /// disposal pass); we parse all of them. Anything else in the notes
    /// (free-form user notes, plain Bucket B markers) is ignored.
    ///
    /// Defensive — a malformed line yields no entries rather than crashing.
    nonisolated static func parseWitnessesFromNote(_ notes: String) -> [String] {
        var out: [String] = []
        // Scan line-by-line so multi-pass notes accumulate.
        for line in notes.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("reason=dup-on-other-volume"),
                  let openRange = line.range(of: "witnesses=["),
                  let closeRange = line.range(of: "] totalWitnesses=",
                                               range: openRange.upperBound..<line.endIndex)
            else { continue }
            let inner = line[openRange.upperBound..<closeRange.lowerBound]
            // `inner` is a comma-separated list of "..."-quoted paths. We
            // do not bring in a JSON parser for this — the producer is
            // `formatSafelyRedundantNote`, fully under our control. Hand
            // tokenization is fine and avoids the overhead.
            var current = ""
            var inQuote = false
            var prevWasEscape = false
            for ch in inner {
                if prevWasEscape {
                    current.append(unescapedNoteChar(ch))
                    prevWasEscape = false
                    continue
                }
                if ch == "\\" {
                    prevWasEscape = true
                    continue
                }
                if ch == "\"" {
                    if inQuote {
                        out.append(current)
                        current = ""
                    }
                    inQuote.toggle()
                    continue
                }
                if inQuote {
                    current.append(ch)
                }
            }
        }
        return out
    }

    // MARK: - Public mutations (MainActor — touch CatalogScanTarget)

    /// Mark `volumeRootPath` retired with the given reason + witness
    /// union. Idempotent — calling on an already-retired volume just
    /// refreshes the fields (reason update, witness re-aggregate). Logs
    /// to the relocate log + the in-app console. Persists immediately
    /// via the existing `persistScanDates` path.
    ///
    /// Returns true on success; false when the path doesn't match any scan
    /// target, or when the gate (`retireCheck`, RetireGate.swift) says no:
    /// a record on the drive nobody accounted for, a file resting on a
    /// witness that no longer holds on disk on another physical drive, or
    /// a file labelled deleted whose absence can't be proved (tab-charter
    /// audit T1 + QA round 1 — a label never vouches). Nothing changes on a
    /// refusal; the reason is logged with every file it names.
    /// Synchronous: the stats run on the caller. The retire sheet uses
    /// `retireCheckOffMain` + `commitRetire` instead (QA m2).
    @discardableResult
    func retireVolume(at volumeRootPath: String,
                      reason: String,
                      witnesses: [String],
                      disk: ShowAgainDisk = .retireLive,
                      drive: RetireDriveProbe = .live) -> Bool {
        guard scanTargets.contains(where: { $0.searchPath == volumeRootPath }) else {
            log("Retire refused: no scan target matches \(volumeRootPath).")
            return false
        }
        return commitRetire(at: volumeRootPath, reason: reason, witnesses: witnesses,
                            check: retireCheck(at: volumeRootPath, disk: disk, drive: drive))
    }

    /// Stamp the drive retired on the strength of ONE check made this click.
    /// Refuses when the check refused (logging its reason and files), or
    /// when the catalog no longer projects to what the check judged — a
    /// scan or Show Again changed the drive's rows while the disk was read.
    @discardableResult
    func commitRetire(at volumeRootPath: String, reason: String, witnesses: [String],
                      check: RetireCheck) -> Bool {
        guard let target = scanTargets.first(where: { $0.searchPath == volumeRootPath }) else {
            log("Retire refused: no scan target matches \(volumeRootPath).")
            return false
        }
        if let why = check.refusal {
            log("Retire refused: \(volumeRootPath) — \(why); nothing was changed.")
            for path in check.unproven.all.prefix(20) {
                log("  no surviving copy found for \(path)")
            }
            return false
        }
        guard retireGateInput(at: volumeRootPath) == check.input else {
            log("Retire refused: \(volumeRootPath) — \(Self.retireCatalogChangedReason); nothing was changed.")
            return false
        }
        let now = Date()
        target.retiredAt = now
        target.retiredReason = reason
        target.retiredWitnesses = witnesses.isEmpty ? nil : witnesses
        persistScanDates()
        notifyTargetsChanged()
        let stampStr = ISO8601DateFormatter().string(from: now)
        log("Retired volume \(volumeRootPath) at \(stampStr): \(reason)")
        return true
    }

    static let retireCatalogChangedReason = "the catalog changed while the drive was being checked — try again"

    /// Why `volumeRootPath` must NOT be retired right now, or nil — the
    /// refusal half of `retireCheck` (synchronous; tests and the log).
    func retireRefusal(at volumeRootPath: String, disk: ShowAgainDisk = .retireLive,
                       drive: RetireDriveProbe = .live) -> String? {
        retireCheck(at: volumeRootPath, disk: disk, drive: drive).refusal
    }

    /// The gate, synchronously on the caller:
    ///   1. every record on the drive is disposed by catalog facts
    ///      (`disposedOn`); an empty drive may be retired;
    ///   2. every file resting on a witness has one that holds NOW, and
    ///      every file LABELLED deleted has a witness that holds or is
    ///      provably gone (RetireGate.swift has the whole rule).
    func retireCheck(at volumeRootPath: String, disk: ShowAgainDisk = .retireLive,
                     drive: RetireDriveProbe = .live) -> RetireCheck {
        RetireGate.evaluate(retireGateInput(at: volumeRootPath), independence: relocateWitnessIndependence,
                            disk: disk, drive: drive)
    }

    /// The same check with the stats OFF the main actor (QA m2): the
    /// catalog is projected here, the disk is read on a background task.
    func retireCheckOffMain(at volumeRootPath: String, disk: ShowAgainDisk = .retireLive,
                            drive: RetireDriveProbe = .live) async -> RetireCheck {
        let input = retireGateInput(at: volumeRootPath)
        let independence = relocateWitnessIndependence
        return await Task.detached(priority: .userInitiated) {
            RetireGate.evaluate(input, independence: independence, disk: disk, drive: drive)
        }.value
    }

    private func otherRetiredRoots(than volumeRootPath: String) -> [String] {
        scanTargets.filter { $0.isRetired && !$0.searchPath.isEmpty && $0.searchPath != volumeRootPath }
            .map(\.searchPath)
    }

    /// The catalog's side of the gate, on the main actor — catalog facts
    /// only, O(records), no disk I/O: the step-1 counts, the rows the disk
    /// decides (labelled, or resting on a witness) with their witnesses
    /// that are live rows off this drive, and the drive's recorded UUID.
    func retireGateInput(at volumeRootPath: String) -> RetireGateInput {
        let retired = otherRetiredRoots(than: volumeRootPath)
        let scoped = Self.recordsScoped(to: volumeRootPath, in: records)
        let live = Self.liveWitnessPaths(in: records, retiredRoots: retired)
        let rows: [RetireGateInput.Row] = scoped.compactMap { rec in
            let labelled = rec.archiveStage == .manuallyDeleted
            let witnesses = Self.restingWitnesses(of: rec)
            guard labelled || !witnesses.isEmpty else { return nil }
            return .init(path: rec.fullPath, size: rec.sizeBytes, labelled: labelled,
                         witnesses: witnesses.filter { live.contains($0) && !PathScope.contains($0, within: volumeRootPath) })
        }
        return RetireGateInput(
            volumeRootPath: volumeRootPath,
            total: scoped.count,
            disposed: Self.disposedOn(volumeRootPath: volumeRootPath, in: records, retiredRoots: retired),
            rows: rows,
            recordedVolumeUUID: Self.recordedVolumeUUID(of: scoped))
    }

    /// The one persistent volume UUID the catalog recorded for these rows at
    /// scan time (`ScanContext.volumeUUID`). The scan target itself stores
    /// none, so the rows are the record. nil when none recorded one, or
    /// when they disagree — then no absence on the drive is proof.
    nonisolated static func recordedVolumeUUID(of rows: [VideoRecord]) -> String? {
        var found: String?
        for rec in rows {
            guard let u = VolumeIdentity.normalized(rec.scanContext.volumeUUID) else { continue }
            if let f = found, f != u { return nil }
            found = u
        }
        return found
    }

    /// The witnesses a record's place on its drive rests on: every witness
    /// line of a legacy labelled row, or the record's own skip witnesses.
    nonisolated static func restingWitnesses(of rec: VideoRecord) -> [String] {
        if rec.archiveStage == .manuallyDeleted { return parseWitnessesFromNote(rec.notes) }
        return ownSkipWitnesses(notes: rec.notes, fullPath: rec.fullPath) ?? []
    }

    /// Clear all three retire fields — volume returns to active status.
    /// Reverse of `retireVolume`. Used by the context menu Reinstate
    /// action. Logs the reversal.
    @discardableResult
    func reinstateVolume(at volumeRootPath: String) -> Bool {
        guard let target = scanTargets.first(where: { $0.searchPath == volumeRootPath }) else {
            log("Reinstate refused: no scan target matches \(volumeRootPath).")
            return false
        }
        target.retiredAt = nil
        target.retiredReason = nil
        target.retiredWitnesses = nil
        // `retiredAt` is the ONE owner of retirement (taxonomy 2026-08-16);
        // the role is untouched — a reinstated Backup is still a Backup.
        persistScanDates()
        persistScanTargets()
        notifyTargetsChanged()
        log("Reinstated volume \(volumeRootPath).")
        return true
    }

    // MARK: - UI hooks

    /// Suggested default reason text shown in the retire modal. The user
    /// can edit before committing. Embeds today's date so a glance at
    /// the retired-volumes list later tells Rick when the call was made.
    nonisolated static func defaultRetireReason(now: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone.current
        return "All records dup-elsewhere or source-deleted via Migrate \(fmt.string(from: now))"
    }
}
