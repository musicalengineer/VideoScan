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
    /// Total catalogued records on the volume (all `.manuallyDeleted` —
    /// that's what triggered the offer). Drives the "All N records…"
    /// headline.
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
// (Bucket B + Bucket E) leaves 100% of catalogued records on the source
// volume marked `.manuallyDeleted`, the volume itself can be retired:
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
// docs/relocate_volume_plan.md §1B.

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

    /// Subset of `totalRecordsOn` whose `archiveStage == .manuallyDeleted`.
    /// Numerator for the 100% disposed check. Bucket B + Bucket E both
    /// land in this state, so a Relocate run that retires the source has
    /// `manuallyDeletedOn == totalRecordsOn`.
    nonisolated static func manuallyDeletedOn(volumeRootPath: String,
                                              in all: [VideoRecord]) -> Int {
        recordsScoped(to: volumeRootPath, in: all)
            .filter { $0.archiveStage == .manuallyDeleted }
            .count
    }

    /// Pure predicate: "should the retire prompt fire after the current
    /// Relocate run?" True iff there's at least one record AND every
    /// catalogued record on the volume is `.manuallyDeleted`. Used by
    /// the post-Relocate hook AND directly by tests.
    nonisolated static func shouldOfferRetire(volumeRootPath: String,
                                              in all: [VideoRecord]) -> Bool {
        let total = totalRecordsOn(volumeRootPath: volumeRootPath, in: all)
        guard total > 0 else { return false }
        return manuallyDeletedOn(volumeRootPath: volumeRootPath, in: all) == total
    }

    // MARK: - Witness aggregation

    /// Walk every `.manuallyDeleted` record on the volume and pull out
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
        in all: [VideoRecord]
    ) -> [String] {
        let scoped = recordsScoped(to: volumeRootPath, in: all)
        var seen = Set<String>()
        for rec in scoped where rec.archiveStage == .manuallyDeleted {
            for w in parseWitnessesFromNote(rec.notes) {
                seen.insert(w)
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
                    current.append(ch)
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
    /// Returns true on success, false when the path doesn't match any
    /// scan target (defensive guard for stale UI state).
    @discardableResult
    func retireVolume(at volumeRootPath: String,
                      reason: String,
                      witnesses: [String]) -> Bool {
        guard let target = scanTargets.first(where: { $0.searchPath == volumeRootPath }) else {
            log("Retire refused: no scan target matches \(volumeRootPath).")
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
        persistScanDates()
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
