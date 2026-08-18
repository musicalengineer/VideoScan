import Foundation

// MARK: - ReconcileLogLines
//
// ONE place that spells the relocate.log lines for a reconcile result, so
// the live Migrate run and the sheet's "Reconcile preview" cannot drift
// apart. GH #162 (2026-08-18): the preview classified every record and
// showed the counts, but wrote NOTHING to relocate.log — a preview studied
// and then cancelled left no trace, and the witness paths behind "will
// mark as deleted with audit trail" were invisible until Apply. Now the
// preview writes the same summary + per-file lines the live run writes,
// prefixed `[PREVIEW]` so a reader can never mistake a preview statement
// for a committed decision:
//
//   live:     Reconcile: ready=3 adopted=263 …
//             [RECONCILE] safely-redundant: /Volumes/… — 2 witness(es), first: …
//   preview:  [PREVIEW] Reconcile: ready=3 adopted=263 … source=… dest=…
//             [PREVIEW][RECONCILE] safely-redundant: /Volumes/… — 2 witness(es), first: …
//
// (Tag butts straight up against the bucket tag; a space separates it
// from the bare "Reconcile:" summary word.)
//
// Pure string builders — no I/O, no actor requirement beyond reading the
// records' `fullPath` on the actor that owns them (main). The live run
// calls the per-line formatters inline (it interleaves logging with the
// catalog mutations); the preview calls `allLines` once. Both funnel
// through the same formatters, which is the point.
//
// Caps: the live run has NEVER capped its per-file [RECONCILE] lines
// (relocate.log is the audit trail — every decision, every path), so the
// preview doesn't either. `perFileLineCap` exists as the single knob if
// that ever changes; nil = unlimited, matching today's live behaviour.

enum ReconcileLogLines {

    /// Tag prepended to every preview line. Sits BEFORE the existing
    /// `[RECONCILE]` bucket tag so `grep '^\[PREVIEW\]'` isolates previews
    /// and `grep '\[RECONCILE\]'` still finds both flavours.
    static let previewPrefix = "[PREVIEW]"

    /// Per-bucket cap on per-file lines. Nil = unlimited (the live run's
    /// historical behaviour — see the header note).
    static let perFileLineCap: Int? = nil

    // MARK: Summary

    /// The one-line bucket summary. `source`/`dest` are appended when
    /// given (the preview passes them — Rick asked for both paths on the
    /// summary line so a preview in the log is self-describing; the live
    /// run already logged them on its "Migrate started" line and keeps
    /// its historical format).
    static func summaryLine(_ r: ReconcileResult,
                            prefix: String = "",
                            source: String? = nil,
                            dest: String? = nil) -> String {
        let lead = prefix.isEmpty ? "" : prefix + " "
        var line = "\(lead)Reconcile: ready=\(r.ready.count) adopted=\(r.adopted.count) sourceMoves=\(r.sourceSideMoves.count) safelyRedundant=\(r.safelyRedundant.count) manuallyDeleted=\(r.manuallyDeleted.count) previouslyRelocated=\(r.previouslyRelocated.count)"
        if let source { line += " source=\(source)" }
        if let dest { line += " dest=\(dest)" }
        return line
    }

    // MARK: Per-file formatters (shared with the live run)

    static func manuallyDeletedLine(path: String, prefix: String = "") -> String {
        "\(prefix)[RECONCILE] manually-deleted: \(path)"
    }

    static func adoptedLine(path: String, dest: String, prefix: String = "") -> String {
        "\(prefix)[RECONCILE] adopted: \(path) → \(dest)"
    }

    static func safelyRedundantLine(path: String,
                                    totalWitnessCount: Int,
                                    firstWitness: String?,
                                    prefix: String = "") -> String {
        "\(prefix)[RECONCILE] safely-redundant: \(path) — \(totalWitnessCount) witness(es), first: \(firstWitness ?? "?")"
    }

    static func sourceMoveLine(path: String, newSourcePath: String, prefix: String = "") -> String {
        "\(prefix)[RECONCILE] source-move: \(path) → \(newSourcePath)"
    }

    static func previouslyRelocatedLine(path: String, prefix: String = "") -> String {
        "\(prefix)[RECONCILE] previously-relocated, skipping: \(path)"
    }

    // MARK: Whole result

    /// Every per-file line for `r`, bucket by bucket, in the same order
    /// the live run emits them (manually-deleted, adopted, safely-
    /// redundant, source-move, previously-relocated). Honours
    /// `perFileLineCap` per bucket with a trailing "…and N more" marker.
    static func perFileLines(_ r: ReconcileResult, prefix: String = "") -> [String] {
        var out: [String] = []
        func emit(_ lines: [String], bucket: String) {
            guard let cap = perFileLineCap, lines.count > cap else {
                out.append(contentsOf: lines)
                return
            }
            out.append(contentsOf: lines.prefix(cap))
            out.append("\(prefix)[RECONCILE] \(bucket): …and \(lines.count - cap) more")
        }
        emit(r.manuallyDeleted.map { manuallyDeletedLine(path: $0.fullPath, prefix: prefix) },
             bucket: "manually-deleted")
        emit(r.adopted.map { adoptedLine(path: $0.rec.fullPath, dest: $0.destPath, prefix: prefix) },
             bucket: "adopted")
        emit(r.safelyRedundant.map {
                safelyRedundantLine(path: $0.rec.fullPath,
                                    totalWitnessCount: $0.totalWitnessCount,
                                    firstWitness: $0.witnesses.first,
                                    prefix: prefix)
             },
             bucket: "safely-redundant")
        emit(r.sourceSideMoves.map { sourceMoveLine(path: $0.rec.fullPath, newSourcePath: $0.newSourcePath, prefix: prefix) },
             bucket: "source-move")
        emit(r.previouslyRelocated.map { previouslyRelocatedLine(path: $0.fullPath, prefix: prefix) },
             bucket: "previously-relocated")
        return out
    }

    /// Summary line followed by every per-file line — what the preview
    /// writes to relocate.log in one go.
    static func allLines(_ r: ReconcileResult,
                         prefix: String = "",
                         source: String? = nil,
                         dest: String? = nil) -> [String] {
        [summaryLine(r, prefix: prefix, source: source, dest: dest)]
            + perFileLines(r, prefix: prefix)
    }

    // MARK: Migrate button wording (GH #162, 2026-08-18)

    /// The Migrate button used to read "Migrate 134 record(s) (1.33 TB)" —
    /// the total bytes of every in-scope record — which misled Rick when
    /// only 3 of the 134 were actually copied (9.96 GB). With a preview
    /// in hand we can say what will REALLY happen; without one we keep
    /// the old wording and point at the preview.
    static func migrateButtonLabel(scopeCount: Int,
                                   scopeBytes: Int64,
                                   plan: ReconcileResult?,
                                   busy: Bool) -> String {
        let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        let verb = busy ? "Add to Queue —" : "Migrate"
        guard let plan else {
            return "\(verb) \(scopeCount) record(s) (\(fmt(scopeBytes))) — run Reconcile preview for the copy breakdown"
        }
        // "To copy" = Bucket A (ready) + Bucket C (source-side moves — path
        // rewritten, then copied like A). Adopt/redundant/deleted/done
        // never touch bytes.
        let toCopy = plan.ready + plan.sourceSideMoves.map(\.rec)
        let copyBytes = toCopy.reduce(Int64(0)) { $0 + $1.sizeBytes }
        var parts: [String] = ["\(toCopy.count) to copy (\(fmt(copyBytes)))"]
        if !plan.adopted.isEmpty {
            parts.append("\(plan.adopted.count) already at destination (adopt, no copy)")
        }
        if !plan.safelyRedundant.isEmpty {
            parts.append("\(plan.safelyRedundant.count) redundant elsewhere (mark deleted)")
        }
        if !plan.manuallyDeleted.isEmpty {
            parts.append("\(plan.manuallyDeleted.count) missing (mark deleted)")
        }
        if !plan.previouslyRelocated.isEmpty {
            parts.append("\(plan.previouslyRelocated.count) previously migrated (skip)")
        }
        return "\(verb) \(scopeCount) record(s): " + parts.joined(separator: ", ")
    }
}
