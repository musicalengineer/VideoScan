// CatalogBackupRestore.swift
// File ▸ Restore from Backup… (GH #343, Rick 2026-11-25: "yes"). One
// sentence: Rick picks a backup Back Up Catalog made, sees its date and row
// count, says Restore, and the catalog becomes the one in the backup — the
// catalog as it was goes to the Trash first, and the restored copy opens
// read-only until he adopts it.
//
// Steps — each refuses before anything changes, and every refusal after the
// write hold is taken gives the hold back (writes resume as before):
//   1. VERIFY the bundle, off the main actor: a catalog.sqlite bundle with a
//      v2 manifest naming it and the latch beside it; the bundle's
//      catalog.sqlite COPIED into a hidden work folder beside the live
//      catalog, then made read-only with its folder (codex #384 F2) and
//      PINNED — device + inode, size, mtime, ctime and a SHA-256 read
//      through one fd (`CatalogPinnedSource`); that SHA-256 and size equal
//      to the manifest's; the copy opened sealed and read-only
//      (integrity_check, foreign_key_check, schema version) and its
//      generation and table counts equal to the manifest's; the pin
//      re-checked after those reads (they read the pinned bytes); the
//      manifest's high-water not below its generation; the copy BELOW this
//      Mac's high-water (else it would open writable, unasked).
//   2. CONFIRM: one plain alert naming the backup's date, host, generation
//      and file-row count — read from the verified copy itself — beside the
//      live catalog's (Cancel is the default).
//   3. HOLD: the committer commits what is in memory, then admits nothing
//      (`commitBeforeSafetyCopy` + `beginRestore`), and the session turns
//      read-only "restoring the catalog — editing is paused" (codex #384
//      F3) — one synchronous main-actor turn, before the first await, so no
//      edit can land between the commit and the pause. Every refusal from
//      here gives both back.
//   4. SAFETY COPY: a sealed copy of the live catalog (VACUUM INTO, every
//      committed generation), checked sealed (its generation = the live
//      one), pinned, moved to the Trash through THE one Trash call
//      (MediaTrash.move) — and proven there before the first write: the
//      same file (device + inode), size, mtime and full SHA-256 (codex #384
//      P2). Rule 2's spirit for data: the catalog as it was is never
//      deleted; Rick empties the Trash.
//   5. RESTORE: `repository.restore(fromSealedCopy:…)` with the PINNED
//      staged copy — the store re-checks the pin under the source's SHARED
//      lock right before the first page — SQLite's backup API INTO the open
//      catalog.sqlite, one transaction, the file never replaced, this Mac's
//      catalog.highwater (+ .log) untouched (CatalogDatabaseRestore.swift
//      has the design and why). Once SQLite reports the copy done it is
//      committed: any later failure is "restored, not verified", never a
//      refusal (codex #384 F1).
//   6. STOP: the store closed itself; the committer stops for good
//      (`stopAfterRestore`), the session turns read-only, and Rick is asked
//      to quit. The RELAUNCH is the reload: the one tested launch path opens
//      the restored catalog read-only "restored below high-water" and the
//      existing Adopt sheet is his explicit choice. (An in-session reload
//      would have to re-seat every store attached to the committer —
//      folders, roles, marks, the journal, eras — with memory that no longer
//      matches the file; refusing that is the safer design.)
// Outcomes: restored · restoredUnverified (it wrote; the read-back
// disagreed — the safety copy is the way back) · refused (nothing changed)
// · cancelled. START / OUTCOME / REFUSED lines through the model's one sink.
//
// Not an MFO job: verification is a streamed copy + hash + one integrity
// check, and the restore one page-copy transaction — seconds at Rick's
// catalog size (the 100k-row restore measures 0.15 s); Back Up Catalog, its
// twin, is not a job either. Pause/Stop would mean nothing inside one
// SQLite transaction.
//
// Memory: the copy and the hash stream (FileManager's copy; 1 MB hash
// chunks — each copy is hashed twice in verify, once more by the store);
// SQLite's page cache for the checks and the backup. Disk: two copies the
// size of catalog.sqlite in the work folder (the staged backup in its
// read-only `source/` folder, the safety copy until it moves to the Trash)
// — the folder is deleted at the end (it holds only copies); the safety
// copy stays in the Trash.
//
// (For Rick: a caseless `enum` ≈ a C++ namespace of static functions;
// `@concurrent` ≈ "always on a worker thread, never the caller's actor".)

import AppKit
import Foundation
import VideoScanCore

@MainActor
enum CatalogBackupRestore {

    /// What step 1 proved about the bundle; what the confirmation shows.
    struct Plan: Equatable, Sendable {
        let bundleURL: URL
        /// Hidden scratch beside catalog.sqlite (deleted at the end).
        let workFolder: URL
        /// The bundle's catalog.sqlite, copied, made read-only, pinned and
        /// verified; the store restores these bytes or refuses.
        let staged: CatalogPinnedSource
        var stagedCopy: URL { staged.url }
        /// Read from `stagedCopy` itself (sealed open), not from the manifest.
        let backup: CatalogSealedCopyFacts
        /// The manifest's words (shown as such): when and where it was made.
        let exportedAt: Date
        let exportedFromHost: String
        /// This Mac's high-water (the higher of catalog.highwater and its log).
        let highWater: Int
    }

    /// The live catalog, for the confirmation.
    struct Live: Equatable, Sendable {
        let generation: Int
        let files: Int?
    }

    struct Restored: Equatable {
        let generation: Int
        let replaced: Int
        let files: Int
        /// Where the catalog as it was landed (the Trash).
        let safetyCopy: URL
    }

    enum Outcome: Equatable {
        case restored(Restored)
        /// It wrote, but the read-back disagreed. The session is stopped.
        case restoredUnverified(String, safetyCopy: URL)
        /// Nothing changed; the words say why.
        case refused(String)
        case cancelled
    }

    /// What the door borrows from the session. Production: `live(model:)`.
    @MainActor
    struct Context {
        let committer: CatalogCommitter
        let databaseURL: URL
        let note: (String) -> Void
        /// The session turns read-only (the model's read-only fact).
        let markRestored: () -> Void
        /// Editing paused (true) or given back (false) while the restore runs.
        let pauseEditing: (Bool) -> Void
        /// THE one Trash call; tests pass a failing one.
        var trash: @Sendable (URL) throws -> URL = { try MediaTrash.move($0) }
        /// Step 2. Production: the alert.
        var confirm: @MainActor (Plan, Live) -> Bool = CatalogBackupRestore.confirmWithAlert
        var pagesPerStep: Int32 = CatalogDatabaseRestore.defaultPagesPerStep

        /// nil when this Mac has no catalog.sqlite committer (a viewer, a launch that refused).
        static func live(model: VideoScanModel) -> Context? {
            guard let committer = model.catalogCutover.committer, let databaseURL = model.catalogCutover.databaseURL else { return nil }
            return Context(committer: committer, databaseURL: databaseURL,
                           note: { [weak model] in model?.catalogAuthorityNote($0) },
                           markRestored: { [weak model] in model?.updateReadOnlyFacts { $0.restoredFromBackup = true } },
                           pauseEditing: { [weak model] on in model?.updateReadOnlyFacts { $0.restoringFromBackup = on } })
        }
    }

    /// One restore at a time (≈ a file-scope `static bool` owned by the UI thread).
    private(set) static var running = false

    // MARK: - The door

    static func run(bundle: URL, context: Context) async -> Outcome {
        guard !running else { return .refused("a restore is already running") }
        running = true
        defer { running = false }
        let committer = context.committer
        context.note("START Restore from Backup — \(bundle.path)")
        if let why = committer.saveRefusal() {
            return refuse(context, nil, "the catalog cannot be written now (\(why))")
        }

        // 1. Verify.
        let plan: Plan
        switch await verify(bundle: bundle, databaseURL: context.databaseURL) {
        case .failure(let refusal): return refuse(context, nil, refusal.words)
        case .success(let verified): plan = verified
        }
        context.note("Restore from Backup: verified \(bundle.lastPathComponent) — generation \(plan.backup.generation), "
                     + "\(plan.backup.counts.files) file rows, \(plan.backup.counts.quarantine) quarantined, this Mac's high-water \(plan.highWater)")

        // 2. Confirm.
        let liveFiles = try? await committer.repository.read { try $0.recordCounts().files }
        let live = Live(generation: await committer.generationNow(), files: liveFiles)
        guard context.confirm(plan, live) else {
            removeWorkFolder(plan)
            context.note("OUTCOME Restore from Backup cancelled — nothing changed")
            return .cancelled
        }

        // 3. Hold (commit first, then admit nothing) and pause editing —
        // one synchronous turn, no await before the pause.
        if let why = committer.commitBeforeSafetyCopy() {
            return refuse(context, plan, "what is in memory could not be saved first (\(why))")
        }
        committer.beginRestore()
        context.pauseEditing(true)
        /// Every refusal from here: editing back, then the hold (its
        /// endRestore schedules a commit, which the pause would refuse).
        func giveBack() {
            context.pauseEditing(false)
            committer.endRestore()
        }
        let liveGeneration = await committer.generationNow()

        // 4. Safety copy → the Trash.
        let safetyCopy: URL
        switch await makeSafetyCopy(of: committer.repository, generation: liveGeneration, in: plan.workFolder, trash: context.trash) {
        case .failure(let refusal):
            giveBack()
            return refuse(context, plan, refusal.words)
        case .success(let trashed):
            safetyCopy = trashed
        }
        context.note("Restore from Backup: the catalog as it is (generation \(liveGeneration)) is in the Trash at \(safetyCopy.path)")

        // 5. Restore.
        let outcome = await committer.repository.restore(fromSealedCopy: plan.staged, expectedGeneration: plan.backup.generation,
                                                         pagesPerStep: context.pagesPerStep) { _, _ in }
        removeWorkFolder(plan)
        switch outcome {
        case .refused(let why):
            giveBack()
            return refuse(context, nil, "\(why) — the copy of the catalog in the Trash (\(safetyCopy.lastPathComponent)) is not needed")
        case .restored(let generation, let replaced, let pages):
            // 6. Stop.
            committer.stopAfterRestore(stopWords(plan))
            context.markRestored()
            context.pauseEditing(false)
            context.note("OUTCOME restored catalog.sqlite from \(plan.bundleURL.lastPathComponent): generation \(replaced) → \(generation) "
                         + "(\(pages) pages, one transaction, the file not replaced) · file rows before \(live.files.map(String.init) ?? "unknown") · "
                         + "after \(plan.backup.counts.files) · the catalog as it was is in the Trash at \(safetyCopy.path) · "
                         + "this Mac's high-water stays \(plan.highWater), so it opens read-only until Adopt · quit and reopen VideoScan")
            return .restored(Restored(generation: generation, replaced: replaced, files: plan.backup.counts.files, safetyCopy: safetyCopy))
        case .restoredUnverified(let why):
            committer.stopAfterRestore(stopWords(plan))
            context.markRestored()
            context.pauseEditing(false)
            context.note("OUTCOME restored catalog.sqlite from \(plan.bundleURL.lastPathComponent) but NOT VERIFIED — \(why). "
                         + "The catalog as it was is in the Trash at \(safetyCopy.path). Quit and reopen VideoScan; it will open "
                         + "read-only — do not adopt it until Catalog Status shows it whole")
            return .restoredUnverified(why, safetyCopy: safetyCopy)
        }
    }

    static func stopWords(_ plan: Plan) -> String {
        "catalog.sqlite was restored from the backup \(plan.bundleURL.lastPathComponent) — quit VideoScan and open it again"
    }

    private static func refuse(_ context: Context, _ plan: Plan?, _ words: String) -> Outcome {
        if let plan { removeWorkFolder(plan) }
        context.note("REFUSED Restore from Backup — \(words). Nothing changed.")
        return .refused(words)
    }

    // MARK: - 1. Verify

    struct Refusal: Error, Equatable {
        let words: String
    }

    nonisolated static let workFolderPrefix = ".restore-"
    /// The staged copy's folder inside the work folder: made non-writable
    /// once the copy is in (no rename, replace or new file inside it).
    nonisolated static let stagedFolderName = "source"

    /// What the bundle CLAIMS about its catalog.sqlite (manifest + latch),
    /// before any byte of the database is trusted. Reads only small files.
    nonisolated static func claims(of bundle: URL) -> Result<(manifest: BundleManifest, sealed: CatalogBackupSeal.Sealed), Refusal> {
        guard case .sqlite = BundleImporter.catalogKind(of: bundle) else {
            return .failure(Refusal(words: "\(bundle.lastPathComponent) holds no catalog.sqlite — not a backup this Mac can restore"))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("manifest.json")),
              let manifest = try? decoder.decode(BundleManifest.self, from: data) else {
            return .failure(Refusal(words: "the backup's manifest.json is missing or unreadable, so its catalog.sqlite cannot be checked"))
        }
        guard manifest.bundleVersion <= BundleManifest.currentVersion else {
            return .failure(Refusal(words: "the backup was made by a newer VideoScan (format \(manifest.bundleVersion))"))
        }
        guard let sealed = manifest.catalogDatabase, sealed.fileName == CatalogBackupSeal.databaseFileName else {
            return .failure(Refusal(words: "the backup's manifest does not describe a catalog.sqlite"))
        }
        guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent(CatalogBackupSeal.latchFileName).path) else {
            return .failure(Refusal(words: "the backup has no \(CatalogBackupSeal.latchFileName) beside its catalog.sqlite"))
        }
        if let highWater = sealed.highWater, highWater < sealed.generation {
            return .failure(Refusal(words: "the backup's manifest says high-water \(highWater) below its generation \(sealed.generation)"))
        }
        return .success((manifest, sealed))
    }

    /// The claims, then the proof: the database copied out, hashed, opened
    /// sealed, and compared with every claim; and below this Mac's high-water.
    @concurrent
    nonisolated static func verify(bundle: URL, databaseURL: URL) async -> Result<Plan, Refusal> {
        let fm = FileManager.default
        let manifest: BundleManifest
        let sealed: CatalogBackupSeal.Sealed
        switch claims(of: bundle) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let claimed): (manifest, sealed) = claimed
        }
        guard let thisMac = CatalogAdopt.highWater(besideDatabaseAt: databaseURL) else {
            return .failure(Refusal(words: "this Mac's high-water (\(CatalogHighWater.fileName)) cannot be read"))
        }
        let work = databaseURL.deletingLastPathComponent().appendingPathComponent("\(workFolderPrefix)\(UUID().uuidString)", isDirectory: true)
        let stagedFolder = work.appendingPathComponent(stagedFolderName, isDirectory: true)
        let stagedURL = stagedFolder.appendingPathComponent("backup-\(CatalogBackupSeal.databaseFileName)")
        func fail(_ words: String) -> Result<Plan, Refusal> {
            removeScratch(work)
            return .failure(Refusal(words: words))
        }
        do {
            try fm.createDirectory(at: stagedFolder, withIntermediateDirectories: true)
            try fm.copyItem(at: bundle.appendingPathComponent(CatalogBackupSeal.databaseFileName), to: stagedURL)
            // Read-only from here: the file, and its folder (no rename or
            // replace inside it). Before the pin, so the pin's ctime is final.
            try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: stagedURL.path)
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: stagedFolder.path)
        } catch {
            return fail("the backup's catalog.sqlite could not be copied for checking: \(error.localizedDescription)")
        }
        let staged: CatalogPinnedSource
        do {
            staged = try CatalogPinnedSource.pin(stagedURL)
        } catch {
            return fail("the backup's catalog.sqlite could not be read for checking: \(error)")
        }
        guard staged.identity.bytes == sealed.bytes else {
            return fail("the backup's catalog.sqlite is \(staged.identity.bytes) bytes, but its manifest says \(sealed.bytes)")
        }
        guard staged.sha256 == sealed.sha256.lowercased() else {
            return fail("the backup's catalog.sqlite does not match the SHA-256 its manifest recorded — it changed after the backup was made")
        }
        let facts: CatalogSealedCopyFacts
        do {
            facts = try await CatalogDatabaseRestore.inspectSealedCopy(stagedURL)
        } catch {
            return fail("the backup's catalog.sqlite did not pass its checks: \(error)")
        }
        // The checks read the pinned bytes, not something swapped in under them.
        if let changed = staged.changeSincePinned() {
            return fail(CatalogDatabaseRestore.changedWords(changed))
        }
        guard facts.generation == sealed.generation, facts.counts.files == sealed.files,
              facts.counts.quarantine == sealed.quarantine, facts.counts.content == sealed.content else {
            return fail("the backup's catalog.sqlite (generation \(facts.generation), \(facts.counts.files) file rows) "
                        + "is not what its manifest recorded (generation \(sealed.generation), \(sealed.files) file rows)")
        }
        guard facts.generation < thisMac else {
            return fail(CatalogDatabaseRestore.atOrAboveHighWaterWords(generation: facts.generation, highWater: thisMac))
        }
        return .success(Plan(bundleURL: bundle, workFolder: work, staged: staged, backup: facts,
                             exportedAt: manifest.exportedAt, exportedFromHost: manifest.exportedFromHost, highWater: thisMac))
    }

    /// The work folder holds only copies (the staged backup; the safety copy
    /// once it is in the Trash, never before). Scratch: deleted.
    nonisolated static func removeWorkFolder(_ plan: Plan) {
        removeScratch(plan.workFolder)
    }

    /// The one removal in this file: a `.restore-<uuid>` work folder beside
    /// catalog.sqlite, and nothing else (refused otherwise). Its read-only
    /// `source/` folder is made writable again first, or nothing in it
    /// could be removed.
    private nonisolated static func removeScratch(_ folder: URL) {
        guard folder.lastPathComponent.hasPrefix(workFolderPrefix) else { return }
        let stagedFolder = folder.appendingPathComponent(stagedFolderName, isDirectory: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedFolder.path)
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - 4. The safety copy

    @concurrent
    nonisolated static func makeSafetyCopy(of repository: any CatalogRepository, generation: Int, in folder: URL,
                                           trash: @Sendable (URL) throws -> URL) async -> Result<URL, Refusal> {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
        let copy = folder.appendingPathComponent("catalog.before-restore-\(stamp).sqlite")
        if let why = repository.sealedCopyBlocking(to: copy) {
            return .failure(Refusal(words: "a copy of the catalog as it is could not be made first: \(why)"))
        }
        do {
            let facts = try await CatalogDatabaseRestore.inspectSealedCopy(copy)
            guard facts.generation == generation else {
                return .failure(Refusal(words: "the copy of the catalog reads generation \(facts.generation), not the live \(generation)"))
            }
        } catch {
            return .failure(Refusal(words: "the copy of the catalog as it is did not pass its checks: \(error)"))
        }
        // Pinned after the checks (the same bytes they read: re-checked), so
        // what is proven in the Trash is the copy that passed them.
        let pinned: CatalogPinnedSource
        do {
            pinned = try CatalogPinnedSource.pin(copy)
        } catch {
            return .failure(Refusal(words: "the copy of the catalog as it is could not be read: \(error)"))
        }
        let trashed: URL
        do {
            trashed = try trash(copy)
        } catch {
            return .failure(Refusal(words: "the copy of the catalog as it is could not be moved to the Trash: \(error.localizedDescription)"))
        }
        // codex #384 P2: proven by identity (device + inode, size, mtime) AND
        // the full SHA-256 before the first write to catalog.sqlite.
        if let why = pinned.provenMoved(to: trashed) {
            return .failure(Refusal(words: "the copy of the catalog in the Trash at \(trashed.path) does not match the copy that was checked (\(why))"))
        }
        return .success(trashed)
    }

    // MARK: - 2. The confirmation (UI)

    static func confirmWithAlert(_ plan: Plan, _ live: Live) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Restore the catalog from this backup?"
        alert.informativeText = confirmationText(plan, live)
        let restore = alert.addButton(withTitle: "Restore")
        restore.hasDestructiveAction = true
        restore.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func confirmationText(_ plan: Plan, _ live: Live) -> String {
        let when = Date(timeIntervalSince1970: TimeInterval(plan.backup.savedAt))
        let liveFiles = live.files.map { "\($0.formatted()) file rows" } ?? "file rows unknown"
        return "Backup made \(plan.exportedAt.formatted(date: .abbreviated, time: .shortened)) on \(plan.exportedFromHost). "
            + "Its catalog was last saved \(when.formatted(date: .abbreviated, time: .shortened)) and holds "
            + "\(plan.backup.counts.files.formatted()) file rows (generation \(plan.backup.generation)).\n\n"
            + "Your catalog now: \(liveFiles) (generation \(live.generation)).\n\n"
            + "A copy of your catalog as it is goes to the Trash first. After the restore VideoScan must quit; when you open it "
            + "again the restored catalog is read-only until you choose Adopt in Catalog Status. "
            + "People, settings and reference photos are not changed."
    }

    // MARK: - Presenting the outcome (UI)

    static func present(_ outcome: Outcome) {
        switch outcome {
        case .cancelled:
            return
        case .refused(let words):
            VideoScanModel.showErrorAlert(title: "Not Restored", message: sentence(words))
        case .restored(let restored):
            quitAlert(title: "Catalog Restored",
                      message: "The catalog now holds the backup's \(restored.files.formatted()) file rows. A copy of the catalog "
                      + "as it was is in the Trash (\(restored.safetyCopy.lastPathComponent)).\n\nVideoScan will quit now. Open it "
                      + "again to see the restored catalog; it is read-only until you choose Adopt in Catalog Status.")
        case .restoredUnverified(let words, let safetyCopy):
            quitAlert(title: "Catalog Restored — Not Verified",
                      message: "\(sentence(words))\n\nA copy of the catalog as it was is in the Trash (\(safetyCopy.lastPathComponent)). "
                      + "VideoScan will quit now. When you open it again, check Catalog Status before you adopt anything.")
        }
    }

    private static func quitAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Quit VideoScan")
        alert.runModal()
        NSApp.terminate(nil)
    }

    private static func sentence(_ words: String) -> String {
        words.prefix(1).uppercased() + words.dropFirst() + (words.hasSuffix(".") ? "" : ".")
    }
}
