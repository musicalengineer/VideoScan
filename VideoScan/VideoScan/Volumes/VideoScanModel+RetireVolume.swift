import Foundation

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

// MARK: - RetireUnprovenFiles

/// The files that hold a drive back from Retire, by why (full paths). A
/// plain value: `retireRefusal` turns it into the sentence the retire sheet
/// shows and `retireVolume` logs.
struct RetireUnprovenFiles: Equatable {
    /// Rest on a witness (own skip note, or a labelled row's witness note)
    /// and none of them holds on disk on another physical drive now.
    var witnessGone: [String] = []
    /// Labelled deleted, yet the file is still on this drive (stat says it
    /// is there, or can't say it is gone) and no witness holds.
    var labelledStillHere: [String] = []
    /// Labelled deleted, no witness holds, and the drive is not connected —
    /// nothing can show the file is gone.
    var labelledUnchecked: [String] = []

    var all: [String] { witnessGone + labelledStillHere + labelledUnchecked }
    var isEmpty: Bool { witnessGone.isEmpty && labelledStillHere.isEmpty && labelledUnchecked.isEmpty }

    /// How many names each clause lists before "and N more".
    static let namesShown = 10

    /// One clause per non-empty bucket, each naming its files relative to
    /// the drive: "2 file(s) labelled deleted are still on this drive, with
    /// no copy on another drive: Tapes/a.mov, b.mov".
    func refusalText(volumeRootPath: String) -> String {
        let clauses: [(paths: [String], words: String)] = [
            (witnessGone, "no longer have a copy on disk on another drive"),
            (labelledStillHere, "labelled deleted are still on this drive, with no copy on another drive"),
            (labelledUnchecked, "labelled deleted can't be checked (the drive isn't connected) and have no copy on another drive"),
        ]
        return clauses.filter { !$0.paths.isEmpty }
            .map { "\($0.paths.count) file(s) \($0.words): \(Self.names($0.paths, under: volumeRootPath))" }
            .joined(separator: "; ")
    }

    private static func names(_ paths: [String], under root: String) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let shown = paths.prefix(namesShown).map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }
        let more = paths.count - shown.count
        return shown.joined(separator: ", ") + (more > 0 ? " and \(more) more" : "")
    }
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
    /// retire gate itself (`retireRefusal` → `filesWithoutAWitnessOnDisk`)
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
    /// target, or when `retireRefusal` says no (QA rounds 1–2, 2026-10-11):
    /// a record on the drive nobody accounted for, a file resting on a
    /// witness that no longer holds on disk on another physical drive, or
    /// a file labelled deleted that is still on the drive (tab-charter
    /// audit T1 — a label never vouches). Nothing changes on a refusal; the
    /// reason is logged with every file it names. `disk` is the stat +
    /// volume-online seam (one stat per witness tried, one per labelled
    /// file without a held witness); injectable for tests.
    @discardableResult
    func retireVolume(at volumeRootPath: String,
                      reason: String,
                      witnesses: [String],
                      disk: ShowAgainDisk = .live) -> Bool {
        guard let target = scanTargets.first(where: { $0.searchPath == volumeRootPath }) else {
            log("Retire refused: no scan target matches \(volumeRootPath).")
            return false
        }
        if let why = retireRefusal(at: volumeRootPath, disk: disk) {
            log("Retire refused: \(volumeRootPath) — \(why); nothing was changed.")
            let unproven = filesWithoutAWitnessOnDisk(volumeRootPath: volumeRootPath, disk: disk)
            for path in unproven.all.prefix(20) {
                log("  no surviving copy found for \(path)")
            }
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

    /// Why `volumeRootPath` must NOT be retired right now, or nil. Asked by
    /// `retireVolume` before anything changes, and by the retire sheet so it
    /// can show the reason (QA round 2):
    ///   1. every record on the drive is disposed (`disposedOn`, catalog
    ///      facts — a file nobody accounted for is never retired with it);
    ///      an empty drive has nothing to lose and may be retired;
    ///   2. every file that rests on a witness — a skipped file, or a
    ///      legacy labelled row carrying a witness note — has one that holds
    ///      NOW, and every file LABELLED deleted (`.manuallyDeleted`) either
    ///      has a witness that holds or is provably gone from a connected
    ///      drive (`filesWithoutAWitnessOnDisk`). The label alone never
    ///      vouches (tab-charter audit T1, 2026-10-11: 959 of Rick's labels
    ///      were false — the file was still there).
    /// The refusal names the files (relative to the drive), so the retire
    /// sheet can show which ones hold it back.
    func retireRefusal(at volumeRootPath: String, disk: ShowAgainDisk = .live) -> String? {
        let retired = otherRetiredRoots(than: volumeRootPath)
        let total = Self.totalRecordsOn(volumeRootPath: volumeRootPath, in: records)
        let disposed = Self.disposedOn(volumeRootPath: volumeRootPath, in: records, retiredRoots: retired)
        if disposed < total {
            return "\(total - disposed) file(s) on this drive are not accounted for — no proven copy elsewhere"
        }
        let unproven = filesWithoutAWitnessOnDisk(volumeRootPath: volumeRootPath, disk: disk)
        return unproven.isEmpty ? nil : unproven.refusalText(volumeRootPath: volumeRootPath)
    }

    private func otherRetiredRoots(than volumeRootPath: String) -> [String] {
        scanTargets.filter { $0.isRetired && !$0.searchPath.isEmpty && $0.searchPath != volumeRootPath }
            .map(\.searchPath)
    }

    /// The files on the drive whose absence nothing proves — retiring the
    /// drive could take the only copy with it. A record is DISPOSED for
    /// retire only when (b) one of its witnesses holds NOW — a live row off
    /// this drive, on another physical drive (`relocateWitnessIndependence`,
    /// the device + inode rule), on disk at the file's size — or, for a row
    /// labelled deleted, (a) its file is not on disk on a CONNECTED drive.
    /// A skipped record (own skip note) still needs (b): its file was on
    /// the drive when Migrate skipped it.
    /// Records that neither carry the label nor rest on a witness are step
    /// 1's business (`disposedOn`) and are not looked at here.
    func filesWithoutAWitnessOnDisk(volumeRootPath: String, disk: ShowAgainDisk) -> RetireUnprovenFiles {
        let live = Self.liveWitnessPaths(in: records, retiredRoots: otherRetiredRoots(than: volumeRootPath))
        let independent = relocateWitnessIndependence
        // Asked once, and only if a labelled row needs it: "missing" on a
        // drive that is not mounted proves nothing.
        var driveOnline: Bool?
        var out = RetireUnprovenFiles()
        for rec in Self.recordsScoped(to: volumeRootPath, in: records) {
            let labelled = rec.archiveStage == .manuallyDeleted
            let witnesses = Self.restingWitnesses(of: rec)
            guard labelled || !witnesses.isEmpty else { continue }
            let held = witnesses.contains { w in
                live.contains(w) && !PathScope.contains(w, within: volumeRootPath)
                    && disk.stat(w) == .file(size: rec.sizeBytes) && independent(w, rec.fullPath, volumeRootPath)
            }
            if held { continue }
            guard labelled else { out.witnessGone.append(rec.fullPath); continue }
            let online = driveOnline ?? disk.volumeOnline(volumeRootPath)
            driveOnline = online
            if !online {
                out.labelledUnchecked.append(rec.fullPath)
            } else if disk.stat(rec.fullPath) != .missing {
                out.labelledStillHere.append(rec.fullPath)
            }
        }
        return out
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
