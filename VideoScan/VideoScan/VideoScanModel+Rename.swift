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
    // — or when an ordinary file's old path is quoted by the archive's
    // index as a promotion SOURCE — the rename carries through to the
    // index files in `00_Index/` (ArchiveIndexRename.swift: exact values
    // only, untouched lines byte-identical, backups first, rollback on a
    // failed publish). A typo is not history, so the old strings are
    // fixed in place; no new record kinds.
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
    //  - Master Archive index (`00_Index/` manifest + journals + ledger
    //    mirror) and the App Support media ledger: rewritten, see above.
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
            }
        }
    }

    /// True when renaming `record` also updates the Master Archive's index
    /// — the rename sheet's one friendly line. (Only the "file is in the
    /// archive" case; a source quoted by the index is found at rename time.)
    func renameUpdatesArchiveIndex(_ record: VideoRecord) -> Bool {
        isInsideMasterArchive(path: record.fullPath)
    }

    /// The exact old → new values a rename replaces in the archive index.
    /// Archive file: its absolute path (as cataloged, and as root + relPath
    /// when that spelling differs) and its archive-relative path. Any other
    /// file: its absolute path only (the manifest's / journals' source
    /// pointer). Pure — no I/O.
    nonisolated static func archiveIndexReplacements(oldPath: String, newPath: String,
                                                     archiveRoot: String?) -> ArchiveIndexRename.Replacements {
        var values: [String: String] = [oldPath: newPath]
        if let root = archiveRoot,
           let oldRel = VerifyArchiveCopiesJob.relPath(of: oldPath, underRoot: root) {
            let newFilename = (newPath as NSString).lastPathComponent
            let relDir = (oldRel as NSString).deletingLastPathComponent
            let newRel = relDir.isEmpty ? newFilename : relDir + "/" + newFilename
            values[oldRel] = newRel
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
    ///  - When a Master Archive is designated and online, the archive
    ///    index is prepared in memory FIRST; an unreadable / unparseable
    ///    index file throws `.archiveIndex` and nothing changes.
    ///  - On `FileManager.moveItem` failure → throws `.filesystem(underlying)`
    ///    and no index file is published.
    ///  - An index publish failure after the move rolls back (index files
    ///    restored, media moved back) and throws `.archiveIndex`.
    ///  - On success: mutates `record.filename` + `record.fullPath`,
    ///    invalidates the stale thumbnail cache entry, persists via
    ///    `saveCatalogDebounced()`, and returns the new full path.
    ///
    /// Caller decides whether to display the error (UI surfaces alert)
    /// or swallow it (`.nameUnchanged` is normal for "user opened sheet
    /// and clicked OK without changing anything").
    ///
    /// Cost: an archive-connected rename reads the index files once on
    /// the calling (main) thread — tens of MB at 100k promotions, a
    /// fraction of a second; one gesture, never per record.
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

        // Archive index: prepare everything in memory before touching
        // anything. Offline / undesignated archive ⇒ an empty plan (the
        // rename behaves exactly as it always did).
        let root = masterArchiveRootPath.flatMap { fm.fileExists(atPath: $0) ? $0 : nil }
        let inArchive = isInsideMasterArchive(path: oldPath)
        let replacements = Self.archiveIndexReplacements(oldPath: oldPath, newPath: newPath,
                                                         archiveRoot: inArchive ? root : nil)
        var plan: ArchiveIndexRename.Plan?
        if let root {
            do {
                plan = try ArchiveIndexRename.prepare(root: root, replacements: replacements)
            } catch let f as ArchiveIndexRename.Failure {
                appLog.write("Catalog: rename of \((oldPath as NSString).lastPathComponent) refused — \(f.errorDescription ?? "archive index unreadable")")
                throw RenameError.archiveIndex(f)
            }
        }

        // Swift's `do { } catch let x as T` ≈ C++ `catch (const T& x)`.
        let backupDir: URL?
        do {
            backupDir = try ArchiveIndexRename.apply(
                plan ?? ArchiveIndexRename.Plan(root: root ?? "", files: []),
                publisher: indexPublisher,
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
                applyRename(record, oldPath: oldPath, newPath: newPath, newFilename: newFilename)
            }
            throw RenameError.archiveIndex(f)
        }

        applyRename(record, oldPath: oldPath, newPath: newPath, newFilename: newFilename)

        // The App Support ledger is the source the archive's mirror is
        // copied from; carry the rename there too (chained, off-main) or
        // the next Promote would copy the old names back.
        if inArchive || !(plan?.isEmpty ?? true) {
            mediaLedger.rewriteExactValues(replacements)
        }

        let oldName = (oldPath as NSString).lastPathComponent
        if let plan, !plan.isEmpty {
            let lines = plan.changedLines, files = plan.files.count
            // One line, Rick's format; the backup folder (always
            // 00_Index/.rename_backups/<timestamp>/) goes to the unified log.
            appLog.write("Catalog: renamed \(oldName) → \(newFilename) (archive index: \(lines) line\(lines == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s") updated)")
            renameLog.info("rename backups: \(backupDir?.path ?? "?", privacy: .public)")
        } else {
            appLog.write("Catalog: renamed \(oldName) → \(newFilename)")
        }
        return newPath
    }

    /// The in-memory half of a rename (after the file is at `newPath`).
    private func applyRename(_ record: VideoRecord, oldPath: String, newPath: String, newFilename: String) {
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
        saveCatalogDebounced()
    }
}
