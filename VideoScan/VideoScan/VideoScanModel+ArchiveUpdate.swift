// VideoScanModel+ArchiveUpdate.swift
// Right-click ▸ Update… on an archived file (Rick's ruling 2026-09-27):
// exactly two editable things, Name and Date (year / month / day + known /
// estimated). The folder follows the date through Promote's placement
// function. This file is the model glue: the sheet's preview, the main-actor
// refusals, the audited archive-write exception, the off-main engine
// (ArchiveRefile.swift), then THIS archived record + one ledger line.
//
// What it deliberately does NOT do (Rick: "too complicated"): no retry
// journal and no replay. If the catalog save or the ledger line fails AFTER
// the archive and its index are updated, it is logged loudly and the sheet
// says so — the archive and the index are the truth, and the next scan
// catalogs the file at its new path. It writes the date onto THIS archived
// record only (the Inspector's fields), never onto the original.
//
// Every step is one audit-grade line to the console + catalog.log +
// videoscan.log through ONE sink (`archiveUpdateNote`).
//
// (For Rick: `@concurrent` is what actually leaves the main actor — a plain
// `nonisolated async` here runs on the caller's actor.)

import Combine
import Foundation
import os
import VideoScanCore

/// Everything the Update sheet shows before anything is touched.
struct ArchiveUpdatePreview: Identifiable, Sendable {
    let id = UUID()
    let copyID: UUID
    let rootPath: String
    let archiveFilename: String
    let fromRelPath: String
    let streamTypeRaw: String
    let ext: String
    /// What the archive's own record (the manifest row) says now.
    let currentName: String
    let currentHint: ArchiveDateHint
    let currentKnown: Bool
    /// The manifest row's raw `record_date` / `date_confidence` cells —
    /// written back unchanged unless the date or known/estimated changed.
    let currentRecordDate: String
    let currentDateConfidence: String

    var streamType: StreamType { StreamType(rawValue: streamTypeRaw) ?? .ffprobeFailed }

    /// The filing-year guard for this date (nil = fine).
    func guardRefusal(hint: ArchiveDateHint, now: Date = Date()) -> String? {
        ArchivePathResolver.filingYearRefusal(
            facts: ArchiveRefile.facts(streamType: streamType, filename: archiveFilename, ext: ext, hint: hint),
            now: now)
    }

    /// What an Update with these fields would do — the ONE computation the
    /// sheet's list and the execution both use.
    struct Plan: Equatable, Sendable {
        let toRelPath: String
        let lines: [String]
        let recordDate: String
        let dateConfidence: String
        /// Write the date onto the archived record (the user changed it).
        let writesDate: Bool
    }

    /// True when the index's date is RICK's ("user-known" / "user-estimated"):
    /// then the file's place always follows it (Rick 2026-09-27, the 17:23
    /// DadThanksgiving case — the index said 1984, the folder said 1884). A
    /// machine date in the index never moves a file on its own: a GH #219
    /// row may carry the machine's date while the filename carries the one
    /// Rick typed, and there the filename is the better witness.
    var locationFollowsIndexDate: Bool { currentDateConfidence.hasPrefix("user-") }

    func plan(name: String, hint: ArchiveDateHint, known: Bool) -> Plan {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameChanged = !typed.isEmpty && typed != currentName && ArchivePathResolver.slug(from: typed) != currentName
        let dateChanged = hint != currentHint
        let dateTouched = dateChanged || known != currentKnown
        // The location follows the date: when the date changed, or the index
        // already holds Rick's date, the target is Promote's placement for it.
        // A file already placed there maps to its EXACT current path (r1 #4:
        // a known/estimated-only change on a correctly filed file = no rename).
        let follow = dateChanged || locationFollowsIndexDate
        let to = ArchiveRefile.updatedRelPath(fromRelPath: fromRelPath, streamType: streamType, currentName: currentName,
                                              newName: nameChanged ? typed : nil, newHint: follow ? hint : nil)
        var lines: [String] = []
        let fromStem = ((fromRelPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let toStem = ((to as NSString).lastPathComponent as NSString).deletingPathExtension
        let prefixMoved = !dateChanged && String(fromStem.dropLast(currentName.count)) != String(toStem.dropLast(
            (nameChanged ? ArchivePathResolver.slug(from: typed) : currentName).count))
        if prefixMoved {
            // Misfiled: the date prefix follows the index's date — one line
            // with the whole name, so nothing about the rename is hidden.
            lines.append("Name: \(fromStem) → \(toStem)")
        } else if nameChanged {
            lines.append("Name: \(currentName) → \(ArchivePathResolver.slug(from: typed))")
        }
        if dateTouched {
            let conf = known ? "known" : "estimated"
            let old = ArchiveRefile.datedLabel(currentHint) + (known != currentKnown ? " (\(currentKnown ? "known" : "estimated"))" : "")
            lines.append("Date: \(old) → \(ArchiveRefile.datedLabel(hint)) (\(conf))")
        }
        let (fromFolder, toFolder) = (ArchiveRefile.folder(ofRelPath: fromRelPath), ArchiveRefile.folder(ofRelPath: to))
        if fromFolder != toFolder { lines.append("Folder: \(fromFolder) → \(toFolder)") }
        return Plan(toRelPath: to, lines: lines,
                    recordDate: dateChanged ? hint.manifestDate : currentRecordDate,
                    dateConfidence: dateTouched ? (known ? "user-known" : "user-estimated") : currentDateConfidence,
                    writesDate: dateTouched)
    }

    /// The sheet's typed fields → the hint (or why not) and the plan.
    func evaluate(name: String, year: String, month: String, day: String, known: Bool)
        -> (hint: ArchiveDateHint?, refusal: String?, plan: Plan?) {
        let y = year.trimmingCharacters(in: .whitespaces)
        let m = month.trimmingCharacters(in: .whitespaces)
        let d = day.trimmingCharacters(in: .whitespaces)
        if y.isEmpty && m.isEmpty && d.isEmpty {
            // Blank = keep the current date (undated / decade-only files can
            // still be renamed without inventing a year — r2 #5).
            return (currentHint, nil, plan(name: name, hint: currentHint, known: known))
        }
        guard let yy = Int(y), y.count == 4 else {
            return (nil, y.isEmpty ? "Type the year (or leave the whole date blank to keep it)." : "The year must be four digits.", nil)
        }
        let mm = m.isEmpty ? nil : Int(m), dd = d.isEmpty ? nil : Int(d)
        if (!m.isEmpty && mm == nil) || (!d.isEmpty && dd == nil) {
            return (nil, "Month and day must be numbers (or left empty).", nil)
        }
        guard let hint = ArchiveRefile.hint(year: yy, month: mm, day: dd) else { return (nil, "That isn't a real date.", nil) }
        let plan = plan(name: name, hint: hint, known: known)
        if hint != currentHint, let g = guardRefusal(hint: hint) { return (hint, "Refused: this video \(g).", plan) }
        return (hint, nil, plan)
    }
}

/// What the sheet says when Update returns.
struct ArchiveUpdateResult: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case updated, updatedWithWarnings, refused, rolledBack, mixedState, incompleteRecovery }
    let kind: Kind
    let message: String
}

/// The catalog save and the ledger append, injectable so a test can fail
/// either. Production = the durable catalog save and the confirmed append.
struct ArchiveRefilePersistence: Sendable {
    var saveCatalog: @MainActor @Sendable (VideoScanModel) -> Bool
    var appendLedger: @MainActor @Sendable (VideoScanModel, [MediaLedgerEvent]) async -> Bool

    static let live = ArchiveRefilePersistence(
        saveCatalog: { $0.saveCatalogNow() },
        appendLedger: { model, events in await model.mediaLedger.appendConfirmed(events) })
}

/// Why Update is not offered for a row.
struct ArchiveUpdateRefusal: Error, Equatable, Sendable {
    let message: String
}

extension VideoScanModel {

    // MARK: - The one audit sink

    /// console + catalog.log (`log`), videoscan.log (`appLog`), unified log.
    func archiveUpdateNote(_ line: String) {
        log(line)
        appLog.write("[archive-update] " + line)
        refileLog.notice("\(line, privacy: .public)")
    }

    /// The same sink for the off-main engine: videoscan.log and the unified
    /// log synchronously (a hang leaves its "begin" line); the console /
    /// catalog.log line hops to the main actor in order.
    func archiveUpdateAuditSink() -> @Sendable (String) -> Void {
        { [weak self] line in
            appLog.write("[archive-update] " + line)
            refileLog.notice("\(line, privacy: .public)")
            Task { @MainActor [weak self] in self?.log(line) }
        }
    }

    // MARK: - Preview

    /// The archive copy a row stands for: itself, or the original's copy.
    func archiveCopyForUpdate(_ rec: VideoRecord) -> VideoRecord? {
        isArchiveCopy(rec) ? rec : masterArchiveCopy(of: rec)
    }

    /// Build the sheet's preview from the archive's own record (the manifest
    /// row, read off-main). Touches nothing. `.failure` = not offered (logged).
    func makeArchiveUpdatePreview(recordID: UUID) async -> Result<ArchiveUpdatePreview, ArchiveUpdateRefusal> {
        func no(_ why: String) -> Result<ArchiveUpdatePreview, ArchiveUpdateRefusal> {
            archiveUpdateNote("Update: not offered — \(why)")
            return .failure(ArchiveUpdateRefusal(message: why))
        }
        guard let row = record(forID: recordID) else { return no("that row is no longer in the catalog") }
        guard let root = masterArchiveRootPath else { return no("no Master Archive is designated") }
        guard let copy = archiveCopyForUpdate(row) else { return no("\(row.filename) has no copy in the Master Archive") }
        guard let rel = VerifyArchiveCopiesJob.relPath(of: copy.fullPath, underRoot: root) else {
            return no("the archive copy of \(row.filename) is not inside the archive (\(copy.fullPath))")
        }
        let rows = await Self.manifestRowsOffMain(root: root)
        guard case .success(let all) = rows, let mine = all.last(where: { $0.relPath == rel }) else {
            return no("the archive's manifest has no readable row for \(rel)")
        }
        let preview = ArchiveUpdatePreview(
            copyID: copy.id, rootPath: root, archiveFilename: copy.filename, fromRelPath: rel,
            streamTypeRaw: copy.streamTypeRaw, ext: copy.ext,
            currentName: ArchiveRefile.currentName(ofFilename: copy.filename),
            currentHint: ArchiveRefile.hint(fromManifestDate: mine.recordDate),
            currentKnown: mine.dateConfidence == "user-known",
            currentRecordDate: mine.recordDate, currentDateConfidence: mine.dateConfidence)
        archiveUpdateNote("Update: sheet opened for \(copy.filename) at \(rel) — the archive says \(ArchiveRefile.datedLabel(preview.currentHint))")
        return .success(preview)
    }

    // MARK: - One editor per archived file (Rick 2026-09-27)

    static let alreadyBeingEdited = "This file is already being edited in another Update sheet."

    /// Open Update… for a row: build the preview, then CLAIM the archived
    /// file — only one Update sheet per file at a time. A second open is
    /// refused with `alreadyBeingEdited` (logged). Pair with `closeArchiveUpdate`.
    func openArchiveUpdate(recordID: UUID) async -> Result<ArchiveUpdatePreview, ArchiveUpdateRefusal> {
        let result = await makeArchiveUpdatePreview(recordID: recordID)
        guard case .success(let p) = result else { return result }
        guard !archiveUpdatesOpen.contains(p.copyID) else {
            archiveUpdateNote("Update: \(p.archiveFilename) — not opened: \(Self.alreadyBeingEdited)")
            return .failure(ArchiveUpdateRefusal(message: Self.alreadyBeingEdited))
        }
        archiveUpdatesOpen.insert(p.copyID)
        return result
    }

    /// Release the claim — every close path (Update done, Cancel, the sheet
    /// or its window closing) ends here via the sheet's onDisappear.
    func closeArchiveUpdate(_ p: ArchiveUpdatePreview) {
        if archiveUpdatesOpen.remove(p.copyID) != nil {
            refileLog.debug("update sheet closed for \(p.archiveFilename, privacy: .public)")
        }
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func manifestRowsOffMain(root: String) async
        -> Result<[ArchiveRefile.ManifestRow], ArchiveRefile.ManifestReadFailure> {
        ArchiveRefile.manifestRows(rootPath: root)
    }

    // MARK: - Update

    /// Update ONE archived file's name and/or date. Order: main-actor
    /// refusals → the audited exception → the off-main engine (refusals,
    /// move, verify, index under backup + lock, rollback) → THIS record and
    /// one ledger line. Returns what the sheet should say.
    func updateArchivedFile(_ p: ArchiveUpdatePreview, name: String, hint: ArchiveDateHint, known: Bool,
                            seams: ArchiveRefileEngine.Seams = .live,
                            persistence: ArchiveRefilePersistence = .live,
                            now: Date = Date()) async -> ArchiveUpdateResult {
        let label = p.archiveFilename
        let plan = p.plan(name: name, hint: hint, known: known)
        let changes = plan.lines
        func refused(_ why: String) -> ArchiveUpdateResult {
            archiveUpdateNote("Update: \(label) — refused: \(why). Nothing was changed.")
            return ArchiveUpdateResult(kind: .refused, message: "Not updated — \(why). Nothing was changed.")
        }
        archiveUpdateNote("Update: \(label) — Update clicked (by rick): \(changes.isEmpty ? "no changes" : changes.joined(separator: "; "))")

        // ---- Main-actor refusals (nothing touched).
        guard !changes.isEmpty else { return refused("nothing was changed") }
        if isReadOnly { return refused("this Mac is a read-only viewer of the catalog") }
        guard let root = masterArchiveRootPath, root == p.rootPath else {
            return refused("the Master Archive designation changed since the sheet opened")
        }
        if let identity = masterArchiveIdentityRefusal() { return refused(identity) }
        if archiveIndexWriterActive?() == true {
            return refused("a Promote is writing to the archive index right now — try again when it finishes")
        }
        guard let copy = record(forID: p.copyID),
              VerifyArchiveCopiesJob.relPath(of: copy.fullPath, underRoot: root) == p.fromRelPath else {
            return refused("the archive copy is no longer at \(p.fromRelPath) in the catalog — reopen Update")
        }
        if hint != p.currentHint, let g = p.guardRefusal(hint: hint, now: now) { return refused("\(label) \(g)") }
        let to = plan.toRelPath
        let reason = changes.joined(separator: "; ")

        // ---- The ONE audited exception to the archive's read-only rule.
        let auth: ArchiveRefileAuthorization
        switch ArchiveRefileAuthorization.grant(rootPath: root, fromRelPath: p.fromRelPath, toRelPath: to,
                                                reason: reason, now: now, audit: { archiveUpdateNote($0) }) {
        case .success(let a): auth = a
        case .failure(let d): return refused(d.description)
        }
        let req = ArchiveRefileEngine.Request(rootPath: root, fromRelPath: p.fromRelPath, toRelPath: to,
                                              filename: label, recordDate: plan.recordDate,
                                              dateConfidence: plan.dateConfidence,
                                              expectedRecordDate: p.currentRecordDate,
                                              expectedDateConfidence: p.currentDateConfidence)
        archiveUpdateNote("Update: \(label) — BEGIN \(p.fromRelPath) → \(to) (by rick): \(reason)")
        let outcome = await Self.runRefileOffMain(req, authorization: auth, seams: seams, now: now,
                                                  audit: archiveUpdateAuditSink())
        await Task.yield()   // the engine's lines hop to main in order; let them land first

        switch outcome {
        case .refiled(let done):
            // The record's own date: the new one when the date changed; when
            // only known/estimated moved, the date it already has.
            let newUserDate = !plan.writesDate ? nil
                : (hint != p.currentHint ? ArchiveRefile.userDate(for: hint) : (copy.userDate ?? ArchiveRefile.userDate(for: hint)))
            return await applyUpdated(copy: copy, done: done, root: root, hint: hint, known: known,
                                      writesDate: plan.writesDate, newUserDate: newUserDate,
                                      reason: reason, now: now, persistence: persistence)
        case .refused(let why):
            archiveUpdateNote("Update: \(label) — refused: \(why). Nothing was changed.")
            return ArchiveUpdateResult(kind: .refused, message: "Not updated — \(why). Nothing was changed.")
        case .rolledBack(let why):
            ledgerUpdateRolledBack(copy: copy, from: p.fromRelPath, to: to, why: why, outcome: "rolledBack", location: p.fromRelPath, now: now)
            archiveUpdateNote("Update: \(label) — ROLLED BACK: \(why). The file is back at \(p.fromRelPath) and the archive index is as it was.")
            return ArchiveUpdateResult(kind: .rolledBack,
                                       message: "Update failed and was undone — \(why). The file is back where it was and the archive index is unchanged.")
        case .incompleteRecovery(let why):
            ledgerUpdateRolledBack(copy: copy, from: p.fromRelPath, to: to,
                                   why: "INCOMPLETE RECOVERY (not confirmed durable) — \(why)",
                                   outcome: "incompleteRecovery", location: p.fromRelPath, now: now)
            archiveUpdateNote("Update: \(label) — FAILED; the file was put back at \(p.fromRelPath) but the recovery is NOT confirmed durable: \(why). The archive index backup is kept in 00_Index/\(ArchiveIndexRename.backupFolder); run Verify Copies after checking the drive.")
            return ArchiveUpdateResult(kind: .incompleteRecovery,
                                       message: "Update failed and was put back, but the drive did not confirm the move back was saved (recovery not confirmed durable). The index backup was kept. Check the drive, then run Verify Copies.\n\(why)")
        case .mixedState(let why, let originalAt):
            ledgerUpdateRolledBack(copy: copy, from: p.fromRelPath, to: to, why: "ROLLBACK FAILED — \(why)",
                                   outcome: "mixedState", location: originalAt ?? "", now: now)
            // The record says where the ARCHIVED ORIGINAL is — found by
            // identity in the engine, never "a file exists there".
            if let originalAt, originalAt != p.fromRelPath {
                archiveUpdateNote("Update: \(label) — catalog record now points at the archived original, \(originalAt) (identity-checked); the file at \(p.fromRelPath) is NOT it and was left alone")
                moveRecord(copy, to: (root as NSString).appendingPathComponent(originalAt))
                _ = persistence.saveCatalog(self)
            } else if originalAt == nil {
                archiveUpdateNote("Update: \(label) — the archived original was not found by identity at \(p.fromRelPath) or \(to); the catalog record was left unchanged — check both paths by hand")
            }
            archiveUpdateNote("Update: \(label) — FAILED AND COULD NOT BE FULLY UNDONE: \(why)")
            return ArchiveUpdateResult(kind: .mixedState,
                                       message: "Update failed and could NOT be fully undone. Details (every path) are in the log:\n\(why)")
        }
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func runRefileOffMain(_ req: ArchiveRefileEngine.Request,
                                             authorization: ArchiveRefileAuthorization,
                                             seams: ArchiveRefileEngine.Seams, now: Date,
                                             audit: @escaping @Sendable (String) -> Void) async -> ArchiveRefileEngine.Outcome {
        ArchiveRefileEngine.execute(req, authorization: authorization, seams: seams, now: now, audit: audit)
    }

    /// After the archive and its index are updated: THIS record (path, name,
    /// date — the Inspector's fields), a catalog save, one ledger line. A
    /// failure here is reported, never retried: the archive is the truth.
    private func applyUpdated(copy: VideoRecord, done: ArchiveRefileEngine.Done, root: String,
                              hint: ArchiveDateHint, known: Bool, writesDate: Bool, newUserDate: String?,
                              reason: String, now: Date,
                              persistence: ArchiveRefilePersistence) async -> ArchiveUpdateResult {
        let label = copy.filename
        let oldDate = "\(copy.userDate ?? "none") (\(copy.userDateConfidence ?? "-"))"
        moveRecord(copy, to: (root as NSString).appendingPathComponent(done.toRelPath))
        // Only when the user changed the date or the known/estimated switch
        // (r2 #6): a name-only update leaves the record's date provenance
        // (and whether it has a user date at all) exactly as it was.
        if let ud = newUserDate {
            copy.userDate = ud
            copy.userDateConfidence = (known ? UserDateConfidence.known : .estimated).rawValue
        }
        if let fx = copy.archiveFixity, fx.digest == done.sha256 {
            copy.archiveFixity = ArchiveFixity(algorithm: fx.algorithm, digest: fx.digest,
                                               verifiedAt: now, sizeBytes: fx.sizeBytes)
        }
        let stamp = ISO8601DateFormatter().string(from: now)
        let note = "Update \(stamp): \(reason) · \(done.fromRelPath) → \(done.toRelPath) · sha256 verified before and after"
        copy.notes = copy.notes.isEmpty ? note : "\(copy.notes)\n\(note)"
        notifyVolumeAggregatesStale()
        objectWillChange.send()
        archiveUpdateNote("Update: \(label) — archive record date \(oldDate) → \(copy.userDate ?? "none") (\(copy.userDateConfidence ?? "-")); revert with Update or the Inspector")

        let saved = persistence.saveCatalog(self)
        let ledgered = await persistence.appendLedger(self, [ledgerEvent(.archiveUpdated, for: copy, by: .rick, at: now, detail: [
            MediaLedgerEvent.Detail.from: done.fromRelPath,
            MediaLedgerEvent.Detail.to: done.toRelPath,
            MediaLedgerEvent.Detail.reason: reason,
            MediaLedgerEvent.Detail.date: writesDate ? hint.manifestDate : "",
            MediaLedgerEvent.Detail.confidence: writesDate ? (known ? "known" : "estimated") : "",
            MediaLedgerEvent.Detail.fixity: done.sha256,
            MediaLedgerEvent.Detail.archive: MasterArchiveLayout.displayName(forRootPath: root),
            MediaLedgerEvent.Detail.locked: done.lockProblem == nil ? "true" : "false",
        ])])
        mediaLedger.mirror(intoArchiveRoot: root)
        let files = done.indexFilesChanged
        archiveUpdateNote("Update: \(label) — \(done.fromRelPath) → \(done.toRelPath); fixity verified; index updated (\(done.linesChanged) line(s) in \(files) file(s)\(done.backupDir.map { ", backup \($0)" } ?? "")); catalog saved: \(saved); ledger written: \(ledgered). To undo: Update it back.")
        let summary = "Updated — \(reason)."
        guard saved, ledgered, done.lockProblem == nil else {
            var missing: [String] = []
            if let lock = done.lockProblem { missing.append(lock) }
            if !saved { missing.append("the catalog could not be saved") }
            if !ledgered { missing.append("the ledger line could not be written") }
            let rescan = !saved || !ledgered
            archiveUpdateNote("Update: \(label) — WARNING: the archive and its index ARE updated, but \(missing.joined(separator: " and "))."
                              + (rescan ? " The next scan will catalog the file at its new path." : ""))
            return ArchiveUpdateResult(kind: .updatedWithWarnings,
                                       message: "\(summary) The archive is updated, but \(missing.joined(separator: " and "))"
                                           + (rescan ? "; the catalog will pick up the new path on the next scan." : "."))
        }
        return ArchiveUpdateResult(kind: .updated, message: summary)
    }

    /// Point a record at the file's new place (after the file moved).
    private func moveRecord(_ rec: VideoRecord, to newPath: String) {
        guard rec.fullPath != newPath else { return }
        let oldPath = rec.fullPath
        rec.fullPath = newPath
        rec.filename = (newPath as NSString).lastPathComponent
        rec.directory = (newPath as NSString).deletingLastPathComponent
        invalidateThumbnailCacheEntry(forPath: oldPath)
        searchIndex.update(rec)
        notifyVolumeAggregatesStale()
    }

    private func ledgerUpdateRolledBack(copy: VideoRecord, from: String, to: String, why: String,
                                        outcome: String, location: String, now: Date) {
        ledgerAppend([ledgerEvent(.archiveUpdateRolledBack, for: copy, by: .rick, at: now, detail: [
            MediaLedgerEvent.Detail.from: from,
            MediaLedgerEvent.Detail.to: to,
            MediaLedgerEvent.Detail.reason: why,
            MediaLedgerEvent.Detail.outcome: outcome,
            MediaLedgerEvent.Detail.location: location,
        ])])
    }
}
