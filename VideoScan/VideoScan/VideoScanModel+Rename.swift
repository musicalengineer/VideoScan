import Foundation
import AppKit
import Combine

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
            }
        }
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
    ///  - On `FileManager.moveItem` failure → throws `.filesystem(underlying)`.
    ///  - On success: mutates `record.filename` + `record.fullPath`,
    ///    invalidates the stale thumbnail cache entry, persists via
    ///    `saveCatalogDebounced()`, and returns the new full path.
    ///
    /// Caller decides whether to display the error (UI surfaces alert)
    /// or swallow it (`.nameUnchanged` is normal for "user opened sheet
    /// and clicked OK without changing anything").
    @discardableResult
    func renameRecord(_ record: VideoRecord, toBaseName newBaseName: String) throws -> String {
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

        do {
            try fm.moveItem(atPath: oldPath, toPath: newPath)
        } catch {
            throw RenameError.filesystem(error)
        }

        // Mutate the record in place. `pairedWith`, `pairGroupID`, etc. are
        // identity-keyed (UUID or object reference) so they remain valid;
        // see the cross-reference audit at the top of this file.
        record.filename = newFilename
        record.fullPath = newPath

        // Invalidate the thumbnail cache entry under the old path so the
        // next preview generation rebuilds under the new key. The cache
        // lives inside VideoScanModel so we expose a tiny helper rather
        // than make the NSCache itself non-private.
        invalidateThumbnailCacheEntry(forPath: oldPath)

        // Persist. This is the line whose absence in the original
        // implementation made the rename appear to revert on relaunch.
        objectWillChange.send()
        saveCatalogDebounced()

        appLog.write("Catalog: renamed \((oldPath as NSString).lastPathComponent) → \(newFilename)")
        return newPath
    }
}
