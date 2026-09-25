import Foundation
import AppKit
import Combine
import os

private let renameLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "rename")

extension VideoScanModel {

    // MARK: - Catalog Rename
    //
    // Renames a file on disk and updates the in-memory catalog record so the
    // change survives an app relaunch. Before this lived on the model, the
    // rename was a private helper inside `CatalogContent`'s view body — it
    // mutated `rec.filename` / `rec.fullPath` but never called
    // `saveCatalogDebounced()`, so the rename appeared to revert on next
    // launch (issue: silent fail on filesystem error + missing persistence
    // + no cross-reference backfill).
    //
    // Renaming is also THE way to fix a typo in a name for files in the
    // Master Archive (Rick 2026-09-25). When the file is inside the archive
    // — or is a promoted SOURCE, whose old path the archive's index quotes
    // — the rename carries through to the index files in `00_Index/`
    // (ArchiveIndexRename.swift: exact values only, untouched lines
    // byte-identical, backups first, rollback on a failed publish). A typo
    // is not history, so the old strings are fixed in place; no new record
    // kinds.
    //
    // Which renames touch the index (QA m4 — an ordinary rename must never
    // spin up the archive RAID):
    //  - inside the archive root                     → yes
    //  - a source with a promoted archive copy
    //    (ArchivePromotionIndex, O(1))                → yes
    //  - anything else                               → no index I/O at all
    // Guards, in order: archive volume identity (house rule, codex R3
    // blocker 1: inside-archive refuses, a source skips the index with a
    // log line), then prepare, then "a Promote is appending" (refuses when
    // the plan would rewrite anything).
    //
    // Cost (main thread, by design for now): an index-touching rename reads
    // the manifest + journals once — measured 0.73 s Debug on the M5 for
    // 50k-line manifest + 50k-line promote journal; an ordinary rename pays
    // one O(1) promotion-index lookup (after the index's once-per-mutation
    // rebuild) and nothing else.
    //
    // Cross-reference audit (what gets keyed by path or filename):
    //  - `pairedWith` (VideoRecord?): object reference. Unaffected.
    //  - `pairGroupID` / `duplicateGroupID` / `combinedFromPairID`: UUID. Unaffected.
    //  - Catalog `records` array: UUID-addressed via `id`. Unaffected.
    //  - `record.directory`: parent dir. Rename preserves the parent, unaffected.
    //  - `record.ext`: extension preserved by RenameSheet. Unaffected.
    //  - `applyDetectedPeople` / `applyCaptions`: build a transient
    //    `[fullPath: VideoRecord]` map inside each call. A rename *between*
    //    a PersonFinder job dispatching and its writeback returning would
    //    miss — but the writeback is fed paths captured at job-start, so
    //    the only window is "user renames mid-job." This is an inherent
    //    race we don't try to close here; documented for future hardening.
    //  - `thumbnailCache` (NSCache, keyed by fullPath string): orphaned
    //    after rename. We invalidate the old key — next preview
    //    regenerates fresh under the new path.
    //  - `MetadataCache` SQLite (`probe_cache`, keyed by path+size+mtime):
    //    becomes a stale entry under the old path. Tolerable leak — the
    //    next rescan adds a new entry under the new name, and the user
    //    can clear via "Clear All Cache."
    //  - Master Archive index (`00_Index/` manifest + journals) and the App
    //    Support media ledger (then re-mirrored into the archive): rewritten,
    //    see above.
    //  - All other call sites that read `fullPath` (`VolumeCompare`,
    //    `PersonFinderView.isInCatalog`, etc.) iterate-then-compare with
    //    no persistent cache, so they pick up the new path automatically.

    /// Error type for catalog rename. Surfaced to the user via alert so a
    /// failed rename doesn't disappear silently the way the original
    /// silent-catch implementation did.
    enum RenameError: LocalizedError {
        case emptyName
        case nameUnchanged
        case invalidName(String)
        case sourceMissing(String)
        case destinationExists(String)
        case filesystem(Error)
        /// The archive's index could not be carried through (refused before
        /// anything changed, or rolled back — see the wrapped failure).
        case archiveIndex(ArchiveIndexRename.Failure)
        /// The mounted volume is not the Master Archive volume
        /// (`masterArchiveIdentityRefusal`) — an archive file is not renamed.
        case archiveIdentity(String)
        /// A Promote job is appending to the archive's index right now.
        case archiveBusy

        var errorDescription: String? {
            switch self {
            case .emptyName:
                return "New filename can't be empty."
            case .nameUnchanged:
                return "New filename is the same as the old one."
            case .invalidName(let n):
                return "\"\(n)\" isn't a valid filename. Avoid '/' and ':'."
            case .sourceMissing(let p):
                return "Source file isn't where the catalog expects it:\n\(p)\n\nThe catalog may be stale — try refreshing the volume."
            case .destinationExists(let p):
                return "A file already exists at:\n\(p)"
            case .filesystem(let e):
                return "Couldn't rename file: \(e.localizedDescription)"
            case .archiveIndex(let f):
                return f.errorDescription
            case .archiveIdentity(let reason):
                return reason
            case .archiveBusy:
                return "The archive is busy adding files right now. Rename this file after that finishes — nothing was renamed."
            }
        }
    }

    /// True when renaming `record` also updates the Master Archive's index
    /// — the rename sheet's one friendly line. (Only the "file is in the
    /// archive" case; a promoted source's pointers are updated quietly.)
    func renameUpdatesArchiveIndex(_ record: VideoRecord) -> Bool {
        isInsideMasterArchive(path: record.fullPath)
    }

    /// The exact old → new values a rename replaces in the archive index.
    /// Archive file: its absolute path (as cataloged, and as root + relPath
    /// when that spelling differs) and its archive-relative path — the
    /// latter only when it has a folder in it (a bare name at the archive
    /// root would match any `filename` value anywhere). Any other file: its
    /// absolute path only (the manifest's / journals' source pointer).
    /// Pure — no I/O.
    nonisolated static func archiveIndexReplacements(oldPath: String, newPath: String,
                                                     archiveRoot: String?) -> ArchiveIndexRename.Replacements {
        var values: [String: String] = [oldPath: newPath]
        if let root = archiveRoot,
           let oldRel = VerifyArchiveCopiesJob.relPath(of: oldPath, underRoot: root) {
            let newFilename = (newPath as NSString).lastPathComponent
            let relDir = (oldRel as NSString).deletingLastPathComponent
            let newRel = relDir.isEmpty ? newFilename : relDir + "/" + newFilename
            if oldRel.contains("/") {
                values[oldRel] = newRel
            }
            let rootSpelled = (root as NSString).appendingPathComponent(oldRel)
            if rootSpelled != oldPath {
                values[rootSpelled] = (root as NSString).appendingPathComponent(newRel)
            }
        }
        return ArchiveIndexRename.Replacements(values: values,
                                               oldFilename: (oldPath as NSString).lastPathComponent,
                                               newFilename: (newPath as NSString).lastPathComponent)
    }

    /// Rename a catalog record on disk and update its in-memory fields.
    ///
    /// Behavior:
    ///  - If `newBaseName` (trimmed) is empty → throws `.emptyName`.
    ///  - If the trimmed name + original extension equals the existing
    ///    filename → throws `.nameUnchanged` (caller treats as no-op).
    ///  - If `newBaseName` contains a path separator → throws `.invalidName`.
    ///  - If `record.fullPath` doesn't exist → throws `.sourceMissing`.
    ///  - If the destination path already exists → throws `.destinationExists`.
    ///  - Archive file on a volume that is not the Master Archive volume →
    ///    `.archiveIdentity`; a promoted source there renames without
    ///    touching the index (logged).
    ///  - The archive index is prepared in memory FIRST; an unreadable /
    ///    unparseable index file throws `.archiveIndex` and nothing changes.
    ///    A Promote in progress throws `.archiveBusy` when the index would
    ///    be rewritten.
    ///  - On `FileManager.moveItem` failure → throws `.filesystem(underlying)`
    ///    and no index file is published.
    ///  - An index publish failure, or an index file that changed under us,
    ///    after the move rolls back (index files restored, media moved back)
    ///    and throws `.archiveIndex`.
    ///  - On success: mutates `record.filename` + `record.fullPath`,
    ///    invalidates the stale thumbnail cache entry, persists (immediately
    ///    when the archive index changed, else debounced), and returns the
    ///    new full path.
    ///
    /// Caller decides whether to display the error (UI surfaces alert)
    /// or swallow it (`.nameUnchanged` is normal for "user opened sheet
    /// and clicked OK without changing anything").
    @discardableResult
    func renameRecord(_ record: VideoRecord, toBaseName newBaseName: String,
                      indexPublisher: ArchiveIndexRename.Publisher = ArchiveIndexRename.livePublish(_:to:)) throws -> String {
        let trimmed = newBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RenameError.emptyName }

        // Reject path separators outright — a rename UI should not be a
        // back-door file mover. ':' is also invalid on HFS+/APFS classic
        // posix-name semantics.
        if trimmed.contains("/") || trimmed.contains(":") {
            throw RenameError.invalidName(trimmed)
        }

        let ext = (record.filename as NSString).pathExtension
        let newFilename = ext.isEmpty ? trimmed : "\(trimmed).\(ext)"
        guard newFilename != record.filename else {
            throw RenameError.nameUnchanged
        }

        let oldPath = record.fullPath
        let oldName = (oldPath as NSString).lastPathComponent
        let dir = (oldPath as NSString).deletingLastPathComponent
        let newPath = (dir as NSString).appendingPathComponent(newFilename)

        let fm = FileManager.default

        // Pre-rename validation: catch a stale catalog before we touch the
        // filesystem. Without this the original code surfaced
        // "moveItem: no such file" which the silent catch swallowed.
        guard fm.fileExists(atPath: oldPath) else {
            throw RenameError.sourceMissing(oldPath)
        }
        guard !fm.fileExists(atPath: newPath) else {
            throw RenameError.destinationExists(newPath)
        }

        // Archive index: decide cheaply whether it is involved at all, then
        // prepare everything in memory before touching anything.
        let inArchive = isInsideMasterArchive(path: oldPath)
        let promotedSource = !inArchive && masterArchiveCopy(of: record) != nil
        var root: String?
        if inArchive || promotedSource,
           let designated = masterArchiveRootPath, fm.fileExists(atPath: designated) {
            if let refusal = masterArchiveIdentityRefusal() {
                if inArchive {
                    appLog.write("Catalog: rename of \(oldName) refused — \(refusal)")
                    throw RenameError.archiveIdentity(refusal)
                }
                appLog.write("Catalog: rename of \(oldName) — archive index NOT updated: \(refusal)")
            } else {
                root = designated
            }
        }
        let replacements = Self.archiveIndexReplacements(oldPath: oldPath, newPath: newPath,
                                                         archiveRoot: inArchive ? root : nil)
        var plan: ArchiveIndexRename.Plan?
        if let root {
            do {
                plan = try ArchiveIndexRename.prepare(root: root, replacements: replacements)
            } catch let f as ArchiveIndexRename.Failure {
                appLog.write("Catalog: rename of \(oldName) refused — \(f.errorDescription ?? "archive index unreadable")")
                throw RenameError.archiveIndex(f)
            }
            if let p = plan, !p.isEmpty, archiveIndexWriterActive?() == true {
                appLog.write("Catalog: rename of \(oldName) refused — a Promote is writing to the archive index")
                throw RenameError.archiveBusy
            }
        }

        // Swift's `do { } catch let x as T` ≈ C++ `catch (const T& x)`.
        let backupDir: URL?
        do {
            backupDir = try ArchiveIndexRename.apply(
                plan ?? ArchiveIndexRename.Plan(root: root ?? "", files: []),
                publisher: indexPublisher,
                announce: { dir in
                    // The crash trail: written BEFORE the media moves.
                    appLog.write("Catalog: renaming \(oldName) → \(newFilename) — archive index backups in \(dir.path)")
                },
                moveMedia: {
                    do {
                        try fm.moveItem(atPath: oldPath, toPath: newPath)
                    } catch {
                        throw RenameError.filesystem(error)
                    }
                },
                undoMoveMedia: { try fm.moveItem(atPath: newPath, toPath: oldPath) })
        } catch let f as ArchiveIndexRename.Failure {
            // A rollback that could NOT move the media back leaves the file
            // at its new name — the record must say where the file IS.
            if case .publishFailedNotRolledBack = f, fm.fileExists(atPath: newPath), !fm.fileExists(atPath: oldPath) {
                applyRename(record, oldPath: oldPath, newPath: newPath, newFilename: newFilename, durable: true)
            }
            throw RenameError.archiveIndex(f)
        }

        let indexChanged = !(plan?.isEmpty ?? true)
        applyRename(record, oldPath: oldPath, newPath: newPath, newFilename: newFilename,
                    durable: inArchive || indexChanged)

        // The App Support ledger is the source the archive's mirror is
        // copied from; carry the rename there (chained, off-main), then
        // re-copy the mirror — never edit the copy directly.
        if root != nil {
            mediaLedger.rewriteExactValues(replacements, mirrorIntoArchiveRoot: root)
        }

        if let plan, indexChanged {
            let lines = plan.changedLines, files = plan.files.count
            appLog.write("Catalog: renamed \(oldName) → \(newFilename) (archive index: \(lines) line\(lines == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s") updated)")
            renameLog.info("rename backups: \(backupDir?.path ?? "?", privacy: .public)")
        } else {
            appLog.write("Catalog: renamed \(oldName) → \(newFilename)")
        }
        return newPath
    }

    /// The in-memory half of a rename (after the file is at `newPath`).
    /// `durable`: save the catalog NOW (an archive rename — the catalog and
    /// the archive index must not disagree after a crash), else debounced.
    private func applyRename(_ record: VideoRecord, oldPath: String, newPath: String,
                             newFilename: String, durable: Bool) {
        // Mutate the record in place. `pairedWith`, `pairGroupID`, etc. are
        // identity-keyed (UUID or object reference) so they remain valid;
        // see the cross-reference audit at the top of this file.
        record.filename = newFilename
        record.fullPath = newPath
        // An in-place path rewrite with no count change: bump the
        // revision every RecordsVersion memo keys on, or the path index
        // (`record(forPath:)`) and Hallie's filename memo
        // (ArchivistRecordReferenceIndex) would keep answering for the
        // OLD name and miss the new one (codex #976 item 1).
        notifyVolumeAggregatesStale()

        // Invalidate the thumbnail cache entry under the old path so the
        // next preview generation rebuilds under the new key. The cache
        // lives inside VideoScanModel so we expose a tiny helper rather
        // than make the NSCache itself non-private.
        invalidateThumbnailCacheEntry(forPath: oldPath)

        // Persist. This is the line whose absence in the original
        // implementation made the rename appear to revert on relaunch.
        objectWillChange.send()
        if durable {
            if !saveCatalogNow() {
                appLog.write("Catalog: rename of \((oldPath as NSString).lastPathComponent) → \(newFilename) — immediate catalog save did not reach disk; the debounced save will retry")
                saveCatalogDebounced()
            }
        } else {
            saveCatalogDebounced()
        }
    }
}
