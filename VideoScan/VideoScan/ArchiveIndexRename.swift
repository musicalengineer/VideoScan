// ArchiveIndexRename.swift
// Carries a Catalog rename through to the Master Archive's index files
// (Rick 2026-09-25: "renaming a file in the Catalog is THE way to fix a
// typo in a name, including for files in the master archive"). KISS: a
// typo is not history, so the old strings are fixed IN PLACE — no new
// record kinds, no rename events.
//
// What is rewritten, under `<root>/00_Index/`:
//   - Archive_Inventory_Manifest.csv   (any cell EQUAL to an old value)
//   - .promote_journal.jsonl           (any JSON string value EQUAL to an old value)
//   - .attestation_journal.jsonl
//   - .promote_decisions.jsonl
// NOT the archive's media-ledger.jsonl: it is only a COPY of the App
// Support ledger. The rename rewrites that source and re-copies it
// (MediaLedger.rewriteExactValues, on the ledger's ordered writer).
// Exact values only — never substrings: `…_misc.mkv` never touches
// `…_misc.mkv.bak` or a longer folder name. One extra, equally exact rule:
// a JSON object's `filename` member that equals the old filename is
// updated ONLY when that same object's `fullPath` or `sourcePath` matched
// — the member that names the file `filename` describes. (In
// .promote_decisions, `detail` holds the ARCHIVE path while `filename` is
// the SOURCE's name; a `detail` match must not touch it — QA m1.)
//
// Byte stability: files are processed as raw bytes, line by line. A line
// with no match is copied through untouched; in a changed line only the
// matched token's bytes are replaced (JSON keys keep their order, the
// original writer's `\/` escaping style is kept, CSV cells stay quoted
// the way ArchiveManifestCSV.escape quotes them). Untouched lines are
// byte-identical by construction.
//
// Order and safety (see VideoScanModel+Rename.swift for the caller):
//   1. prepare  — read + parse + rewrite every index file IN MEMORY. Any
//                 unreadable / unparseable file refuses; nothing changed.
//   2. backup   — each affected file's original bytes are written to
//                 00_Index/.rename_backups/<timestamp>/.
//   3. recheck  — each affected file must still be the file we read
//                 (inode + size + mtime); a concurrent append refuses.
//   4. announce — one catalog.log line (old → new, backup folder) BEFORE
//                 the move, so a crash mid-rename leaves a trail.
//   5. move     — the media file is renamed. Failure ⇒ nothing published.
//   6. publish  — each index file atomically (AtomicFilePublish, full
//                 fsync), each preceded by the SAME identity recheck: an
//                 append that landed since prepare (Promote, the
//                 attestation or decisions writer) would be dropped by the
//                 whole-file replace, so it refuses instead (QA M1). A
//                 refusal or failure ROLLS BACK: files already published
//                 are restored from the in-memory originals and the media
//                 file is moved back, so the archive is left exactly as it
//                 was. Only if the rollback itself fails is the state
//                 mixed — then every path is logged loudly.
//   A refused rename removes its own backup folder; a successful one
//   keeps it, and `.rename_backups/` keeps the newest `backupRetention`.
//   Backup folders are named by a UTC stamp with the "Z" offset
//   designator ("2026-11-01T053000.123Z") and created EXCLUSIVELY (a name
//   already taken gets -2, -3 …) — GH #204. Retention never reads names
//   or clocks: it counts and orders only folders carrying our own marker
//   (`.videoscan-backup.json`, monotonic sequence, complete=true written
//   after publish) — codex review 2026-09-27. Legacy (markerless)
//   folders are left in place and never pruned.
//   UNVERIFIED: flock(2) on an SMB / exFAT / FAT volume may not exclude
//   across clients (two Macs claiming at once); the design stays
//   fail-closed there — a lock error refuses the rename, and nothing
//   without a verified complete marker is ever pruned.
//   Residual window: the recheck and the rename(2) that publishes are two
//   syscalls — an append in the microseconds between them is still lost.
//   The model also refuses while a Promote job runs (the main writer).
//
// Memory: one index file's bytes are held at a time during parse, plus
// the rewritten copy of each AFFECTED file until publish (worst case ≈ 2×
// the sum of the index files; a 100k-promotion archive is ~20 MB manifest
// + ~120 MB promote journal (4 lines per promotion) ⇒ ~280 MB peak, for
// the length of one rename). Each read is capped at `readLimit`
// (256 MB) — a larger file refuses rather than being silently truncated.
//
// (For Rick: an `enum` with no cases is Swift's namespace — ≈ a C++
// `namespace` of free functions. `ArraySlice<UInt8>` ≈ a `std::span` over
// the file's bytes — no copy.)

import Foundation
import os
import VideoScanCore

private let renameIndexLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "renameIndex")

enum ArchiveIndexRename {

    /// Index files considered, in publish order (manifest first: it is
    /// the file Verify reads, so it is the one a rollback most wants).
    /// The ledger mirror is deliberately absent (see the file header).
    static var indexFilenames: [String] {
        [MasterArchiveLayout.manifestFilename,
         ArchivePromoteJournal.filename,
         ArchiveAttestationJournal.filename,
         ArchivePromoteDecisions.filename]
    }

    /// `.rename_backups/` keeps this many timestamp folders (newest).
    static let backupRetention = 20

    /// The JSON members whose match lets a sibling `filename` follow.
    static let filenameOwnerKeys: Set<String> = ["fullPath", "sourcePath"]

    /// `00_Index/<backupFolder>/<timestamp>/<file>`.
    static let backupFolder = ".rename_backups"

    /// A read stops here; a file this large refuses instead of being
    /// rewritten from a truncated copy.
    static let readLimit = 256 << 20

    // MARK: Types

    /// Exact old value → new value. `values` holds the paths (absolute and
    /// archive-relative); the filename pair is applied only beside a
    /// matched path inside the same JSON object (see file header).
    struct Replacements: Sendable, Equatable {
        var values: [String: String]
        var oldFilename: String
        var newFilename: String

        var isEmpty: Bool { values.isEmpty }
    }

    /// One index file's prepared rewrite.
    struct FileRewrite: Sendable {
        let name: String
        let url: URL
        let original: Data
        let updated: Data
        let changedLines: Int
        let identity: ArchivePromoteEngine.FileIdentity
    }

    /// Every affected file. Files with zero matches are not in it.
    struct Plan: Sendable {
        let root: String
        let files: [FileRewrite]
        var isEmpty: Bool { files.isEmpty }
        var changedLines: Int { files.reduce(0) { $0 + $1.changedLines } }
        var indexURL: URL {
            URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent(MasterArchiveLayout.indexFolder, isDirectory: true)
        }
    }

    /// What a `moveMedia` error says about the backup taken for it. Any
    /// error that does not conform — or says false — KEEPS the backup
    /// (incomplete marker: never counted, never pruned).
    protocol BackupDisposition: Error {
        /// True only when nothing is left changed: the media never moved,
        /// or it was moved back and that move back was flushed.
        var backupIsSafeToDiscard: Bool { get }
    }

    /// The publish seam: production is an atomic full-fsync publish; a
    /// test injects a failure on the Nth file to exercise the rollback.
    typealias Publisher = (Data, URL) throws -> Void
    static func livePublish(_ data: Data, to url: URL) throws {
        try AtomicFilePublish.write(data, to: url, durability: .fullFsync, createIntermediates: false)
    }

    enum Failure: LocalizedError, Equatable {
        case unreadable(file: String, reason: String)
        case unparseable(file: String, line: Int, reason: String)
        case changedDuringRename(file: String)
        case backupFailed(path: String, reason: String)
        /// Publish failed; every published file was restored and the
        /// media file moved back. Nothing changed.
        case publishFailedRolledBack(file: String, reason: String)
        /// Publish failed AND the rollback failed — mixed state, details
        /// (exact paths) in `detail` and in catalog.log.
        case publishFailedNotRolledBack(file: String, reason: String, detail: String)
        /// Another writer holds the archive-index lock (ArchiveIndexLock).
        /// Nothing was changed.
        case indexBusy(detail: String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let f, let r):
                return "The archive's index file “\(f)” couldn't be read (\(r)). Nothing was renamed."
            case .unparseable(let f, let line, let r):
                return "The archive's index file “\(f)” has a damaged line (line \(line): \(r)). Nothing was renamed."
            case .changedDuringRename(let f):
                return "The archive's index file “\(f)” changed while the rename was being prepared — something else is writing to the archive. Nothing was renamed; try again in a moment."
            case .backupFailed(let p, let r):
                return "Couldn't save a backup of the archive's index before renaming:\n\(p)\n(\(r)). Nothing was renamed."
            case .publishFailedRolledBack(let f, let r):
                return "Couldn't update the archive's index file “\(f)” (\(r)). The rename was undone; nothing changed."
            case .publishFailedNotRolledBack(let f, let r, let detail):
                return "Couldn't update the archive's index file “\(f)” (\(r)), and undoing the rename also failed.\n\n\(detail)"
            case .indexBusy(let detail):
                return "The archive's index is being updated by something else right now — \(detail). Nothing was renamed; try again in a moment."
            }
        }
    }

    // MARK: Prepare (read + parse + rewrite in memory; touches nothing)

    /// Build the plan. A missing `00_Index/` or a missing index file is
    /// simply "nothing to do"; an index file that exists but cannot be
    /// read or parsed throws — the caller refuses the rename.
    static func prepare(root: String, replacements: Replacements) throws -> Plan {
        guard !replacements.isEmpty else { return Plan(root: root, files: []) }
        let indexDir = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(MasterArchiveLayout.indexFolder, isDirectory: true)
        var sb = stat()
        guard lstat(indexDir.path, &sb) == 0 else {
            if errno == ENOENT { return Plan(root: root, files: []) }
            throw Failure.unreadable(file: MasterArchiveLayout.indexFolder,
                                     reason: String(cString: strerror(errno)))
        }
        var files: [FileRewrite] = []
        for name in indexFilenames {
            let url = indexDir.appendingPathComponent(name)
            guard lstat(url.path, &sb) == 0 else {
                if errno == ENOENT { continue }
                throw Failure.unreadable(file: name, reason: String(cString: strerror(errno)))
            }
            let isManifest = name == MasterArchiveLayout.manifestFilename
            let (data, identity) = try readIndexFile(root: root, name: name,
                                                     expectedHeaders: isManifest ? MasterArchiveLayout.acceptedManifestHeaders : nil)
            let bytes = [UInt8](data)
            let result = isManifest
                ? try rewriteCSV(bytes, replacements: replacements, file: name)
                : try rewriteJSONL(bytes, replacements: replacements, file: name, lenient: false)
            guard result.changedLines > 0 else { continue }
            files.append(FileRewrite(name: name, url: url, original: data,
                                     updated: Data(result.bytes), changedLines: result.changedLines,
                                     identity: identity))
        }
        return Plan(root: root, files: files)
    }

    /// Read one index file through the validated descriptor (O_NOFOLLOW,
    /// regular file, header checked for the manifest).
    static func readIndexFile(root: String, name: String,
                              expectedHeaders: [String]?) throws -> (Data, ArchivePromoteEngine.FileIdentity) {
        let fd: Int32
        do {
            fd = try ArchivePromoteEngine.openIndexFile(root: root, name: name, mustExist: true,
                                                        expectedHeaders: expectedHeaders)
        } catch {
            throw Failure.unreadable(file: name, reason: ArchiveAttestationJournal.describe(error))
        }
        defer { close(fd) }
        guard let (identity, _) = ArchivePromoteEngine.FileIdentity.of(fd: fd) else {
            throw Failure.unreadable(file: name, reason: "could not stat")
        }
        let data: Data
        do {
            data = try ArchivePromoteEngine.readAll(fd: fd, limit: readLimit + 1)
        } catch {
            throw Failure.unreadable(file: name, reason: ArchiveAttestationJournal.describe(error))
        }
        guard data.count <= readLimit else {
            throw Failure.unreadable(file: name, reason: "larger than \(readLimit >> 20) MB")
        }
        return (data, identity)
    }

    /// The identity of the file at `name` right now (for the recheck).
    static func currentIdentity(root: String, name: String) -> ArchivePromoteEngine.FileIdentity? {
        guard let fd = try? ArchivePromoteEngine.openIndexFile(root: root, name: name, mustExist: true) else {
            return nil
        }
        defer { close(fd) }
        return ArchivePromoteEngine.FileIdentity.of(fd: fd)?.0
    }

    // MARK: Apply (backup → recheck → move → publish, rollback on failure)

    /// Run the plan around the media move. `moveMedia` performs the rename
    /// and throws its own error (propagated unchanged — nothing is
    /// published). `undoMoveMedia` moves it back during a rollback.
    /// Returns the backup folder (nil when the plan was empty).
    ///
    /// The whole of it — backups, rechecks, the media move, every publish
    /// and any rollback — runs holding the ONE archive-index write lock
    /// (ArchiveIndexLock, codex review of Refile #1), so no append can land
    /// between a recheck and the replace that would drop it. Lock busy →
    /// `.indexBusy`, nothing changed. `holder` names the writer in logs.
    @discardableResult
    static func apply(_ plan: Plan,
                      now: Date = Date(),
                      holder: String = "Catalog rename",
                      publisher: Publisher = livePublish(_:to:),
                      backupWriter: Publisher = livePublish(_:to:),
                      announce: (URL) -> Void = { _ in },
                      moveMedia: () throws -> Void,
                      undoMoveMedia: () throws -> Void) throws -> URL? {
        guard !plan.isEmpty else {
            try moveMedia()
            return nil
        }
        do {
            return try ArchiveIndexLock.withExclusive(root: plan.root, holder: holder) {
                try applyLocked(plan, now: now, publisher: publisher, backupWriter: backupWriter,
                                announce: announce, moveMedia: moveMedia, undoMoveMedia: undoMoveMedia)
            }
        } catch let busy as ArchiveIndexLock.Busy {
            throw Failure.indexBusy(detail: busy.description)
        }
    }

    private static func applyLocked(_ plan: Plan, now: Date, publisher: Publisher, backupWriter: Publisher,
                                    announce: (URL) -> Void, moveMedia: () throws -> Void,
                                    undoMoveMedia: () throws -> Void) throws -> URL? {
        // 2. Backups — the exact bytes the plan was built from.
        let backup = try writeBackups(plan, now: now, write: backupWriter)
        let backupDir = backup.dir

        // 3. Recheck: still the file we read? (A promote appending between
        //    prepare and here would otherwise be lost by the replace.)
        for f in plan.files where !isUnchanged(f, root: plan.root) {
            removeRefusedBackup(backupDir)
            throw Failure.changedDuringRename(file: f.name)
        }

        // 4. The trail a crash would leave, then 5. the media move. Its
        //    failure propagates; nothing published.
        announce(backupDir)
        do {
            try moveMedia()
        } catch {
            // A move that was put back without a confirmed-durable folder
            // flush says so; its backup is then KEPT (incomplete marker —
            // never counted, never pruned). Codex review of Refile, #4.
            // RETAIN BY DEFAULT (codex review of Refile r2 #1): the backup
            // goes only when the mover PROVES nothing is left changed
            // (the move never happened, or was undone and flushed).
            if (error as? BackupDisposition)?.backupIsSafeToDiscard == true {
                removeRefusedBackup(backupDir)
            } else {
                appLog.write("Catalog: archive index backup \(backupDir.path) KEPT — the media move failed and its undo is not proven (\(ArchiveAttestationJournal.describe(error))).")
                renameIndexLog.error("backup kept after an unproven media-move failure: \(backupDir.path, privacy: .public)")
            }
            throw error
        }

        // 6. Publish, each after its own recheck; roll back on the first
        //    refusal or failure. A file is TOUCHED the moment its publisher
        //    is called — before it returns — so a publisher that wrote the
        //    new bytes and then threw is restored too (codex review of
        //    Refile, finding 2). A file refused by the recheck was never
        //    touched by us and is left exactly as the other writer left it.
        var touched: [FileRewrite] = []
        for f in plan.files {
            guard isUnchanged(f, root: plan.root) else {
                throw rollback(published: touched, failed: f,
                               cause: .changedDuringRename(file: f.name), reason: "changed during the rename",
                               backupDir: backupDir, publisher: publisher, undoMoveMedia: undoMoveMedia)
            }
            touched.append(f)
            do {
                try publisher(f.updated, f.url)
            } catch {
                let reason = ArchiveAttestationJournal.describe(error)
                throw rollback(published: touched, failed: f,
                               cause: .publishFailedRolledBack(file: f.name, reason: reason), reason: reason,
                               backupDir: backupDir, publisher: publisher, undoMoveMedia: undoMoveMedia)
            }
        }
        // Published: only now is this backup complete, and so prunable.
        // A rollback that failed above leaves it incomplete — kept.
        markBackupComplete(backup)
        pruneBackups(in: backupDir.deletingLastPathComponent())
        return backupDir
    }

    private static func isUnchanged(_ f: FileRewrite, root: String) -> Bool {
        currentIdentity(root: root, name: f.name) == f.identity
    }

    /// Undo a half-published plan: restore every TOUCHED file (published,
    /// or handed to a publisher that then failed) from its in-memory
    /// original, byte for byte, then move the media back. Returns the error to
    /// throw — rolled back, or (if any undo step failed) the loud one.
    private static func rollback(published: [FileRewrite], failed: FileRewrite,
                                 cause: Failure, reason: String,
                                 backupDir: URL, publisher: Publisher,
                                 undoMoveMedia: () throws -> Void) -> Failure {
        var problems: [String] = []
        for f in published.reversed() {
            // Already the original bytes (a publisher that threw before it
            // wrote)? Nothing to restore. Otherwise restore, and judge the
            // restore by the bytes on disk, not by whether it threw.
            if (try? Data(contentsOf: f.url)) == f.original { continue }
            do {
                try publisher(f.original, f.url)
            } catch {
                // A restore that THREW is never a confirmed restore, even when
                // the bytes read back right — the flush may not have landed
                // (Archive Update review r2 #1). The backup is kept.
                if (try? Data(contentsOf: f.url)) == f.original {
                    problems.append("\(f.url.path) holds its original bytes again, but the restore is NOT confirmed durable — the backup \(backupDir.appendingPathComponent(f.name).path) is kept (\(ArchiveAttestationJournal.describe(error)))")
                } else {
                    problems.append("\(f.url.path) still holds the NEW names — restore it from \(backupDir.appendingPathComponent(f.name).path) (\(ArchiveAttestationJournal.describe(error)))")
                }
            }
        }
        do {
            try undoMoveMedia()
        } catch {
            problems.append("the media file keeps its NEW name — could not move it back (\(error.localizedDescription))")
        }
        if problems.isEmpty {
            // Everything is back as it was — the backups are redundant.
            removeRefusedBackup(backupDir)
            appLog.write("Catalog: rename refused — archive index \(failed.name) not updated (\(reason)); \(published.count) index file(s) restored, media file moved back.")
            renameIndexLog.error("rename rolled back: \(failed.name, privacy: .public) — \(reason, privacy: .public)")
            return cause
        }
        let unpublished = [failed.url.path]
        let detail = (["ARCHIVE INDEX RENAME LEFT MIXED STATE — backups at \(backupDir.path)",
                       "not updated (old names): \(unpublished.joined(separator: ", "))"] + problems)
            .joined(separator: "\n")
        appLog.write("Catalog: RENAME ROLLBACK FAILED — \(detail.replacingOccurrences(of: "\n", with: " | "))")
        renameIndexLog.fault("rename rollback failed: \(detail, privacy: .public)")
        return .publishFailedNotRolledBack(file: failed.name, reason: reason, detail: detail)
    }

    /// Remove a refused rename's own backup folder — only that folder,
    /// under the backups lock. `.rename_backups/` itself is PERMANENT
    /// (codex re-review #1, 2026-09-27): it is the lock inode, and removing
    /// it when "empty" raced a concurrent claim — another process could
    /// claim and fill a folder between the empty check and the removal and
    /// lose it. `afterOwnRemoval` runs after the lock is released (the
    /// test seam for that gap; nothing in production).
    static func removeRefusedBackup(_ dir: URL, afterOwnRemoval: () -> Void = {}) {
        let parent = dir.deletingLastPathComponent()
        do {
            try withBackupsLock(parent) {
                try FileManager.default.removeItem(at: dir)
            }
        } catch {
            appLog.write("Catalog: refused rename's backup \(dir.path) could not be removed (\(ArchiveAttestationJournal.describe(error))) — left in place; its marker is incomplete, so it is never pruned.")
            renameIndexLog.error("refused-rename backup not removed: \(dir.path, privacy: .public)")
        }
        afterOwnRemoval()
    }

    // MARK: Backup provenance (GH #204 + codex review 2026-09-27)
    //
    // Retention decides ONLY from something this code wrote: a marker file
    // `.videoscan-backup.json` inside each backup folder, carrying a
    // monotonic `sequence` (taken under an exclusive lock on the backups
    // folder when the folder is claimed) and `complete`, set true LAST,
    // after the rename it protects was published. Folder names and wall
    // clocks are for humans only: a clock rollback, a DST hour, a user's
    // look-alike folder or a stamp-named symlink cannot reorder or
    // authorize anything. A folder without a complete marker — a writer
    // still working, a failed write, a rollback that left mixed state, a
    // legacy backup, anything not ours — is never counted and never pruned.
    //
    // (C++: `Codable` ≈ a struct with generated JSON (de)serializers;
    // `flock` is the same BSD advisory lock you'd call from C.)

    /// The provenance file inside every backup folder written since the
    /// codex review.
    static let backupMarkerName = ".videoscan-backup.json"

    struct BackupMarker: Codable, Equatable {
        struct Entry: Codable, Equatable {
            let name: String
            let size: Int
        }
        var version = 1
        /// Order of claim, 1, 2, 3 … per `.rename_backups/` — max + 1 at
        /// claim time, under the folder lock. Retention orders by this.
        let sequence: Int
        /// UTC ISO-8601, informational only.
        let createdAt: String
        /// False while the backup is being written and until the rename it
        /// protects is published; true only after. Only true is prunable.
        var complete: Bool
        var files: [Entry]
    }

    /// A claimed backup folder and the marker it carries.
    struct BackupClaim {
        let dir: URL
        var marker: BackupMarker
    }

    /// lstat: is `url` itself a directory (a symlink to one is NOT)?
    static func isRealDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory
    }

    /// The marker in a REAL backup directory, if it is ours: a regular
    /// file (not a symlink), small, decodable, version 1. Nil otherwise.
    static func readMarker(in dir: URL) -> BackupMarker? {
        let url = dir.appendingPathComponent(backupMarkerName)
        guard isRealDirectory(dir),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? Int ?? .max) <= 1 << 20,
              let data = FileManager.default.contents(atPath: url.path),
              let marker = try? JSONDecoder().decode(BackupMarker.self, from: data),
              marker.version == 1,
              (1..<backupSequenceLimit).contains(marker.sequence) else { return nil }
        return marker
    }

    /// Sequences are 1 ..< this. Out of range = not ours (a damaged or
    /// foreign marker): never counted, never pruned, and never the base of
    /// the next claim — codex re-review #3: `Int.max + 1` trapped every
    /// later claim. 2^40 claims is ~35,000 years at one rename a second.
    static let backupSequenceLimit = 1 << 40

    /// Every sequence up to the limit is taken; the claim refuses (and so
    /// does the rename it would protect) instead of trapping.
    struct BackupSequenceExhausted: LocalizedError {
        let folder: String
        var errorDescription: String? {
            "The rename backups folder \(folder) has used every backup number — nothing was renamed. Move the old backups aside and try again."
        }
    }

    /// Does this folder still HOLD the backup its marker describes? Every
    /// listed file must be a plain name inside the folder, a regular file
    /// (lstat — a symlink is not), and exactly the listed size; an empty
    /// list is not a backup. Codex re-review #2 (2026-09-27): a complete
    /// marker with a missing or truncated file was counted, and evicted a
    /// valid backup. A folder failing this is never counted AND never
    /// deleted by pruning — it may be the only copy of something.
    static func isVerifiedBackup(_ dir: URL, marker: BackupMarker) -> Bool {
        guard !marker.files.isEmpty else { return false }
        let fm = FileManager.default
        for entry in marker.files {
            let name = entry.name
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
                  name != backupMarkerName,
                  let attrs = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.size] as? NSNumber)?.intValue == entry.size else { return false }
        }
        return true
    }

    /// Every entry directly inside `.rename_backups/`, classified.
    private static func scanBackups(_ parent: URL) -> (ours: [(name: String, marker: BackupMarker)], markerless: Int) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return ([], 0) }
        var ours: [(String, BackupMarker)] = []
        var markerless = 0
        for name in names {
            let dir = parent.appendingPathComponent(name, isDirectory: true)
            guard isRealDirectory(dir) else { continue }
            if let marker = readMarker(in: dir) { ours.append((name, marker)) } else { markerless += 1 }
        }
        return (ours, markerless)
    }

    /// Run `body` holding an exclusive flock(2) on the `.rename_backups/`
    /// directory itself (no lock file to clutter the folder). Opened
    /// O_NOFOLLOW so a symlinked backups folder is refused.
    private static func withBackupsLock<T>(_ parent: URL, _ body: () throws -> T) throws -> T {
        let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private static func writeMarker(_ marker: BackupMarker, in dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try AtomicFilePublish.write(try encoder.encode(marker), to: dir.appendingPathComponent(backupMarkerName),
                                    durability: .fullFsync, createIntermediates: false)
    }

    /// Claim a fresh backup folder: under the lock, take sequence = max of
    /// every marker present (complete or not) + 1, create the folder
    /// exclusively (`makeBackupDirectory`), and write an INCOMPLETE marker
    /// — so from its first instant the folder is ordered and never
    /// prunable. A marker that cannot be written takes the folder with it.
    static func claimBackupDirectory(in parent: URL, now: Date) throws -> BackupClaim {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return try withBackupsLock(parent) {
            let (next, overflow) = (scanBackups(parent).ours.map(\.marker.sequence).max() ?? 0)
                .addingReportingOverflow(1)
            guard !overflow, next < backupSequenceLimit else {
                appLog.write("Catalog: rename backup claim refused — sequence exhausted in \(parent.path); nothing renamed.")
                renameIndexLog.error("rename backup sequence exhausted: \(parent.path, privacy: .public)")
                throw BackupSequenceExhausted(folder: parent.path)
            }
            let dir = try makeBackupDirectory(in: parent, now: now)
            let marker = BackupMarker(sequence: next, createdAt: ISO8601DateFormatter().string(from: now),
                                      complete: false, files: [])
            do {
                try writeMarker(marker, in: dir)
            } catch {
                abandon(dir, reason: "marker write failed: \(ArchiveAttestationJournal.describe(error))")
                throw error
            }
            return BackupClaim(dir: dir, marker: marker)
        }
    }

    /// Write the backup's files into a claimed folder through `write` (the
    /// seam tests use to fail the Nth file). On any failure the folder is
    /// removed (logged); were that removal to fail too, its marker is
    /// still incomplete, so it is never counted or pruned.
    static func writeBackupFiles(_ claim: BackupClaim, files: [(name: String, data: Data)],
                                 write: Publisher = livePublish(_:to:)) throws -> BackupClaim {
        var claim = claim
        do {
            for file in files {
                try write(file.data, claim.dir.appendingPathComponent(file.name))
                claim.marker.files.append(.init(name: file.name, size: file.data.count))
            }
            try writeMarker(claim.marker, in: claim.dir)   // still incomplete; now lists the files
        } catch {
            abandon(claim.dir, reason: "backup write failed: \(ArchiveAttestationJournal.describe(error))")
            throw error
        }
        return claim
    }

    /// The rename this backup protects is published: mark it complete,
    /// the one state retention may count and prune. A failure is logged
    /// loudly and leaves the backup incomplete — kept forever, never lost.
    static func markBackupComplete(_ claim: BackupClaim) {
        var marker = claim.marker
        marker.complete = true
        do {
            try writeMarker(marker, in: claim.dir)
        } catch {
            appLog.write("Catalog: rename backup \(claim.dir.path) could not be marked complete (\(ArchiveAttestationJournal.describe(error))) — kept, never pruned.")
            renameIndexLog.error("rename backup mark-complete failed: \(claim.dir.path, privacy: .public)")
        }
    }

    /// Remove a backup folder this process created and could not finish.
    private static func abandon(_ dir: URL, reason: String) {
        do {
            try FileManager.default.removeItem(at: dir)
            renameIndexLog.error("rename backup abandoned (\(reason, privacy: .public)); removed \(dir.path, privacy: .public)")
        } catch {
            appLog.write("Catalog: rename backup \(dir.path) abandoned (\(reason)) and could not be removed (\(ArchiveAttestationJournal.describe(error))) — left in place, never pruned.")
            renameIndexLog.error("rename backup abandoned and NOT removed: \(dir.path, privacy: .public)")
        }
    }

    /// Keep the newest `backupRetention` COMPLETE backups, newest by marker
    /// sequence. Only real directories directly inside `.rename_backups/`
    /// with our complete marker are counted or removed; everything else
    /// there is left alone, and markerless folders (legacy backups written
    /// before the marker existed, or not ours) are reported once per pass.
    static func pruneBackups(in parent: URL) {
        guard parent.lastPathComponent == backupFolder, isRealDirectory(parent) else { return }
        do {
            try withBackupsLock(parent) {
                let scan = scanBackups(parent)
                if scan.markerless > 0 {
                    renameIndexLog.notice("\(scan.markerless, privacy: .public) legacy backup folder(s) left in place — not pruned (no provenance): \(parent.path, privacy: .public)")
                }
                let finished = scan.ours.filter(\.marker.complete)
                let complete = finished
                    .filter { isVerifiedBackup(parent.appendingPathComponent($0.name, isDirectory: true), marker: $0.marker) }
                    .sorted { $0.marker.sequence < $1.marker.sequence }
                if complete.count < finished.count {
                    let bad = finished.map(\.name).filter { name in !complete.contains { $0.name == name } }
                    renameIndexLog.error("\(bad.count, privacy: .public) complete backup folder(s) whose files are missing or the wrong size — not counted, not pruned: \(bad.joined(separator: ", "), privacy: .public) in \(parent.path, privacy: .public)")
                }
                guard complete.count > backupRetention else { return }
                for victim in complete.prefix(complete.count - backupRetention) {
                    do {
                        try FileManager.default.removeItem(at: parent.appendingPathComponent(victim.name, isDirectory: true))
                    } catch {
                        // Housekeeping: a folder that will not go is logged
                        // and retried by the next rename, never fatal.
                        renameIndexLog.error("rename backup prune failed: \(victim.name, privacy: .public) — \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        } catch {
            renameIndexLog.error("rename backup prune skipped — could not lock \(parent.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// "2026-11-01T053000.123Z" — UTC, millisecond, ISO-8601 basic time
    /// with the "Z" (zero offset) designator; no colons, so it is a safe
    /// folder name in Finder. For humans: retention never reads it.
    static func backupStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HHmmss.SSS'Z'"
        return f.string(from: date)
    }

    /// Create a backup folder no other rename can share: `<stamp>`, or
    /// `<stamp>-2`, `-3` … when taken. The leaf is made with
    /// `withIntermediateDirectories: false`, which is mkdir(2) — it FAILS
    /// on an existing folder instead of quietly reusing it (the ledger
    /// path's same-millisecond overwrite, GH #204), so the check and the
    /// claim are one atomic step.
    static func makeBackupDirectory(in parent: URL, now: Date) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let stamp = backupStamp(now)
        for n in 1...1_000 {
            let dir = parent.appendingPathComponent(n == 1 ? stamp : "\(stamp)-\(n)", isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: false)
                return dir
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: parent.appendingPathComponent(stamp).path])
    }

    /// Claim a backup folder and write every affected file's original
    /// bytes into it. The marker stays incomplete until `apply` publishes.
    private static func writeBackups(_ plan: Plan, now: Date, write: Publisher) throws -> BackupClaim {
        let parent = plan.indexURL.appendingPathComponent(backupFolder, isDirectory: true)
        do {
            let claim = try claimBackupDirectory(in: parent, now: now)
            return try writeBackupFiles(claim, files: plan.files.map { ($0.name, $0.original) }, write: write)
        } catch {
            throw Failure.backupFailed(path: parent.path, reason: ArchiveAttestationJournal.describe(error))
        }
    }

    // MARK: Line plumbing (bytes, so untouched lines stay byte-identical)

    struct Rewrite {
        let bytes: [UInt8]
        let changedLines: Int
    }

    private static let newline: UInt8 = 0x0A
    private static let cr: UInt8 = 0x0D
    private static let quote: UInt8 = 0x22
    private static let comma: UInt8 = 0x2C
    private static let backslash: UInt8 = 0x5C

    /// Split on LF only (a CR stays inside its line), call `transform` per
    /// line; nil = unchanged. Rejoining the pieces with LF reproduces the
    /// input exactly when nothing changed.
    private static func mapLines(_ bytes: [UInt8],
                                 _ transform: (_ line: ArraySlice<UInt8>, _ lineNumber: Int) throws -> [UInt8]?) rethrows -> Rewrite {
        var out: [UInt8] = []
        var changed = 0
        var start = 0
        var lineNumber = 1
        var touched = false
        while start <= bytes.count {
            let end = byteIndex(of: newline, in: bytes[start...]) ?? bytes.count
            let line = bytes[start..<end]
            if let replaced = try transform(line, lineNumber) {
                if !touched {
                    // First change: copy everything before this line.
                    out.reserveCapacity(bytes.count + 256)
                    out.append(contentsOf: bytes[0..<start])
                    touched = true
                }
                out.append(contentsOf: replaced)
                changed += 1
            } else if touched {
                out.append(contentsOf: line)
            }
            if end == bytes.count { break }
            if touched { out.append(newline) }
            start = end + 1
            lineNumber += 1
        }
        return Rewrite(bytes: touched ? out : bytes, changedLines: changed)
    }

    /// Cheap pre-filter: a line can only hold a matching JSON string / CSV
    /// cell if it contains an old value literally or has an escape in it.
    private static func mightMatch(_ line: ArraySlice<UInt8>, needles: [[UInt8]]) -> Bool {
        if byteIndex(of: backslash, in: line) != nil { return true }
        for n in needles where containsBytes(n, in: line) { return true }
        return false
    }

    // memchr / memmem: the scans run over every byte of every index file,
    // and the generic Collection versions are ~50× slower in a Debug
    // build (unspecialized). Same answers, C speed in both configurations.
    // (`withUnsafeBufferPointer` ≈ taking `&v[0]` + size in C++ — valid
    // only inside the closure.)

    /// Absolute index of the first `byte` in `slice`, or nil.
    static func byteIndex(of byte: UInt8, in slice: ArraySlice<UInt8>) -> Int? {
        slice.withUnsafeBufferPointer { buf -> Int? in
            guard let base = buf.baseAddress, !buf.isEmpty,
                  let hit = memchr(base, Int32(byte), buf.count) else { return nil }
            return slice.startIndex + (UnsafeRawPointer(hit) - UnsafeRawPointer(base))
        }
    }

    /// True when `needle` occurs in `slice` as a contiguous byte run.
    static func containsBytes(_ needle: [UInt8], in slice: ArraySlice<UInt8>) -> Bool {
        guard !needle.isEmpty else { return true }
        return slice.withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { n in
                guard let h = hay.baseAddress, let nb = n.baseAddress, hay.count >= n.count else { return false }
                return memmem(h, hay.count, nb, n.count) != nil
            }
        }
    }

    // MARK: CSV (the manifest)

    /// Rewrite every cell (any column, header excluded) whose decoded value
    /// equals an old value. A row with broken quoting refuses.
    static func rewriteCSV(_ bytes: [UInt8], replacements: Replacements, file: String) throws -> Rewrite {
        // The pre-filter looks for a value as it is WRITTEN in a cell: a
        // `"` is stored doubled (QA M2 — a quoted path was skipped here
        // while the JSONL rewrite caught it, splitting the index).
        let needles = replacements.values.keys.map { Array($0.replacingOccurrences(of: "\"", with: "\"\"").utf8) }
        return try mapLines(bytes) { line, number in
            guard number > 1, !line.isEmpty, mightMatch(line, needles: needles) else { return nil }
            var body = line
            var suffix: ArraySlice<UInt8> = []
            if body.last == cr {
                suffix = body[(body.endIndex - 1)...]
                body = body[..<(body.endIndex - 1)]
            }
            let cells = try csvCells(body, file: file, line: number)
            var edits: [(Range<Int>, [UInt8])] = []
            for cell in cells {
                let value = csvDecode(body[cell])
                if let new = replacements.values[value] {
                    edits.append((cell, Array(ArchiveManifestCSV.escape(new).utf8)))
                }
            }
            guard !edits.isEmpty else { return nil }
            return splice(Array(body), base: body.startIndex, edits: edits) + Array(suffix)
        }
    }

    /// Cell byte ranges (raw, including their quotes) of one CSV row.
    /// Internal (not private) since 2026-09-27: Refile's row-targeted
    /// manifest rewrite (ArchiveRefile.swift) uses the SAME parser.
    static func csvCells(_ b: ArraySlice<UInt8>, file: String, line: Int) throws -> [Range<Int>] {
        var cells: [Range<Int>] = []
        var i = b.startIndex
        while true {
            let cellStart = i
            if i < b.endIndex, b[i] == quote {
                i += 1
                var closed = false
                while i < b.endIndex {
                    if b[i] == quote {
                        if i + 1 < b.endIndex, b[i + 1] == quote { i += 2; continue }
                        i += 1
                        closed = true
                        break
                    }
                    i += 1
                }
                guard closed else {
                    throw Failure.unparseable(file: file, line: line, reason: "a quoted cell never ends")
                }
                guard i == b.endIndex || b[i] == comma else {
                    throw Failure.unparseable(file: file, line: line, reason: "text after a closing quote")
                }
            } else {
                while i < b.endIndex, b[i] != comma { i += 1 }
            }
            cells.append(cellStart..<i)
            if i == b.endIndex { break }
            i += 1                                   // the comma
            if i == b.endIndex { cells.append(i..<i); break }
        }
        return cells
    }

    /// A raw cell's value: outer quotes removed, doubled quotes collapsed.
    static func csvDecode(_ raw: ArraySlice<UInt8>) -> String {
        guard raw.count >= 2, raw.first == quote, raw.last == quote else {
            return String(decoding: raw, as: UTF8.self)
        }
        let inner = raw[(raw.startIndex + 1)..<(raw.endIndex - 1)]
        return String(decoding: inner, as: UTF8.self).replacingOccurrences(of: "\"\"", with: "\"")
    }

    // MARK: JSONL (journals, ledger mirror)

    /// Rewrite every JSON string VALUE (keys never) equal to an old value,
    /// at any depth, plus the same-object `filename` rule. `lenient` leaves
    /// an unparseable line untouched instead of refusing (used for the App
    /// Support ledger, which is rewritten after the rename already landed).
    static func rewriteJSONL(_ bytes: [UInt8], replacements: Replacements, file: String,
                             lenient: Bool) throws -> Rewrite {
        let needles = replacements.values.keys.map { Array($0.utf8) }
        // Strict mode must prove EVERY line parses. One parse of the whole
        // file as a JSON array is ~5× cheaper than 50k single-line parses;
        // only when it fails (or the element count disagrees) do we fall
        // back to per-line parsing, which names the damaged line.
        let wholeFileParses = !lenient && allLinesParse(bytes)
        return try mapLines(bytes) { line, number in
            // Blank lines are skipped by every reader; leave them be.
            guard line.contains(where: { !isBlank($0) }) else { return nil }
            // A damaged index refuses the rename (strict) — or, lenient,
            // the damaged line is simply left alone.
            if !lenient, !wholeFileParses, !parses(line) {
                throw Failure.unparseable(file: file, line: number, reason: "not valid JSON")
            }
            guard mightMatch(line, needles: needles) else { return nil }
            if lenient, !parses(line) { return nil }
            let tokens = jsonStringValues(line)
            var edits: [(Range<Int>, [UInt8])] = []
            var matchedContainers = Set<Int>()
            for t in tokens {
                if let new = replacements.values[t.value] {
                    edits.append((t.range, jsonEncode(new, escapeSlashes: t.escapedSlash)))
                    if let key = t.key, filenameOwnerKeys.contains(key) { matchedContainers.insert(t.container) }
                }
            }
            guard !edits.isEmpty else { return nil }
            if !replacements.oldFilename.isEmpty, replacements.oldFilename != replacements.newFilename {
                for t in tokens where t.key == "filename" && t.value == replacements.oldFilename
                    && matchedContainers.contains(t.container) && replacements.values[t.value] == nil {
                    edits.append((t.range, jsonEncode(replacements.newFilename, escapeSlashes: t.escapedSlash)))
                }
            }
            let rewritten = splice(Array(line), base: line.startIndex, edits: edits)
            // Belt and braces: the edited line must still be JSON.
            guard (try? JSONSerialization.jsonObject(with: Data(rewritten), options: [.fragmentsAllowed])) != nil else {
                throw Failure.unparseable(file: file, line: number, reason: "rewrite produced invalid JSON")
            }
            return rewritten
        }
    }

    private static func isBlank(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == cr }

    private static func parses(_ line: ArraySlice<UInt8>) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(line), options: [.fragmentsAllowed])) != nil
    }

    /// True when every non-blank line is ONE JSON value: the lines joined
    /// as `[l1,l2,…]` parse, and the array has exactly one element per
    /// line (so `1,2` on one line, or a value split across two lines, is
    /// caught by the count and sent to the per-line check).
    /// Memory: one extra copy of the file's bytes, for the call only.
    static func allLinesParse(_ bytes: [UInt8]) -> Bool {
        var joined: [UInt8] = [0x5B]
        joined.reserveCapacity(bytes.count + 2)
        var count = 0
        var start = 0
        while start <= bytes.count {
            let end = byteIndex(of: newline, in: bytes[start...]) ?? bytes.count
            let line = bytes[start..<end]
            if line.contains(where: { !isBlank($0) }) {
                if count > 0 { joined.append(comma) }
                joined.append(contentsOf: line)
                count += 1
            }
            if end == bytes.count { break }
            start = end + 1
        }
        joined.append(0x5D)
        guard let array = (try? JSONSerialization.jsonObject(with: Data(joined))) as? [Any] else { return false }
        return array.count == count
    }

    /// A JSON string value in a line: its raw byte range (quotes included),
    /// decoded value, the id of the object/array holding it, and its key
    /// when that container is an object.
    struct StringToken {
        let range: Range<Int>
        let value: String
        let container: Int
        let key: String?
        let escapedSlash: Bool
    }

    /// Minimal scanner over an already-validated JSON line.
    static func jsonStringValues(_ b: ArraySlice<UInt8>) -> [StringToken] {
        struct Frame { let id: Int; let isObject: Bool; var expectingKey: Bool; var lastKey: String? }
        var stack: [Frame] = []
        var nextID = 0
        var tokens: [StringToken] = []
        var i = b.startIndex
        while i < b.endIndex {
            switch b[i] {
            case 0x7B:                                           // {
                stack.append(Frame(id: nextID, isObject: true, expectingKey: true, lastKey: nil))
                nextID += 1; i += 1
            case 0x5B:                                           // [
                stack.append(Frame(id: nextID, isObject: false, expectingKey: false, lastKey: nil))
                nextID += 1; i += 1
            case 0x7D, 0x5D:                                     // } ]
                if !stack.isEmpty { stack.removeLast() }
                i += 1
            case comma:
                if let top = stack.last, top.isObject { stack[stack.count - 1].expectingKey = true }
                i += 1
            case 0x3A:                                           // :
                if !stack.isEmpty { stack[stack.count - 1].expectingKey = false }
                i += 1
            case quote:
                let start = i
                var hasEscape = false
                var escapedSlash = false
                i += 1
                while i < b.endIndex {
                    if b[i] == backslash {
                        hasEscape = true
                        if i + 1 < b.endIndex, b[i + 1] == 0x2F { escapedSlash = true }
                        i += 2
                        continue
                    }
                    if b[i] == quote { break }
                    i += 1
                }
                let end = min(i + 1, b.endIndex)
                i = end
                let raw = b[start..<end]
                let value: String
                if hasEscape {
                    value = (try? JSONSerialization.jsonObject(with: Data(raw), options: [.fragmentsAllowed])) as? String ?? ""
                } else {
                    value = String(decoding: raw.dropFirst().dropLast(), as: UTF8.self)
                }
                if let top = stack.last, top.isObject, top.expectingKey {
                    stack[stack.count - 1].lastKey = value
                } else {
                    let top = stack.last
                    tokens.append(StringToken(range: start..<end, value: value,
                                              container: top?.id ?? -1,
                                              key: top?.isObject == true ? top?.lastKey : nil,
                                              escapedSlash: escapedSlash))
                }
            default:
                i += 1
            }
        }
        return tokens
    }

    /// JSON string literal for `s`, matching JSONEncoder's escapes; `/` is
    /// escaped only when the token being replaced used `\/` (the promote
    /// journal's default encoder does, the sorted-key journals do not).
    static func jsonEncode(_ s: String, escapeSlashes: Bool) -> [UInt8] {
        var out: [UInt8] = [quote]
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += [backslash, quote]
            case "\\": out += [backslash, backslash]
            case "/" where escapeSlashes: out += [backslash, 0x2F]
            case "\n": out += Array("\\n".utf8)
            case "\r": out += Array("\\r".utf8)
            case "\t": out += Array("\\t".utf8)
            case "\u{08}": out += Array("\\b".utf8)
            case "\u{0C}": out += Array("\\f".utf8)
            default:
                if u.value < 0x20 {
                    out += Array(String(format: "\\u%04x", u.value).utf8)
                } else {
                    out += Array(String(u).utf8)
                }
            }
        }
        out.append(quote)
        return out
    }

    /// Replace byte ranges (absolute indices into the original buffer that
    /// started at `base`) — applied back to front so earlier ranges hold.
    /// A range overlapping one already applied is skipped: one token, one
    /// edit, never two.
    static func splice(_ bytes: [UInt8], base: Int, edits: [(Range<Int>, [UInt8])]) -> [UInt8] {
        var out = bytes
        var floor = Int.max
        for (range, replacement) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) where range.upperBound <= floor {
            out.replaceSubrange((range.lowerBound - base)..<(range.upperBound - base), with: replacement)
            floor = range.lowerBound
        }
        return out
    }

    // MARK: The App Support ledger (the mirror's source)

    /// Rewrite the App Support ledger with the same exact-value rules, so
    /// the next Promote mirror does not copy the old names back into the
    /// archive. Lenient (a damaged line is left alone — the rename has
    /// already happened), backed up beside the ledger, published
    /// atomically. Returns the number of changed lines.
    static func rewriteLedgerFile(at url: URL, replacements: Replacements, now: Date = Date(),
                                  backupWriter: Publisher = livePublish(_:to:)) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let data = try Data(contentsOf: url)
        guard data.count <= readLimit else {
            throw Failure.unreadable(file: url.lastPathComponent, reason: "larger than \(readLimit >> 20) MB")
        }
        let result = try rewriteJSONL([UInt8](data), replacements: replacements,
                                      file: url.lastPathComponent, lenient: true)
        guard result.changedLines > 0 else { return 0 }
        // Its own folder, never shared with a same-millisecond rename, and
        // ordered by its marker's sequence, not its name (GH #204). A
        // failed backup write removes its own folder and throws: the
        // ledger is not touched without a backup.
        let parent = url.deletingLastPathComponent().appendingPathComponent(backupFolder, isDirectory: true)
        let backup = try writeBackupFiles(claimBackupDirectory(in: parent, now: now),
                                          files: [(url.lastPathComponent, data)], write: backupWriter)
        do {
            try AtomicFilePublish.write(Data(result.bytes), to: url, durability: .fullFsync, createIntermediates: false)
        } catch {
            // The atomic publish left the old ledger in place: this backup
            // protects nothing. Remove it (logged) and report the failure.
            abandon(backup.dir, reason: "ledger publish failed: \(ArchiveAttestationJournal.describe(error))")
            throw error
        }
        // Same retention as the archive index's backups (publish path above).
        // Each rename copies the WHOLE ledger; without this the folder grew
        // by one full copy per rename, forever (night QA 2026-09-25, m2).
        // Complete — and so prunable — only after the publish, so the
        // backup for THIS rename is never at risk before the new ledger is
        // on disk.
        markBackupComplete(backup)
        pruneBackups(in: parent)
        return result.changedLines
    }
}
