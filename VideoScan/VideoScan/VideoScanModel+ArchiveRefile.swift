// VideoScanModel+ArchiveRefile.swift
// The model half of Refile (Rick's approved workflow, 2026-09-27): the
// Misfiled list (computed off-main, published once), the Refile sheet's
// preview (from → to, the Why line, the editable date and name), and the
// refile itself — main-actor refusals, the audited archive-write exception,
// the off-main engine (ArchiveRefile.swift), then step (e): the catalog
// record and the ledger. Every step is one audit-grade line to the console
// + catalog.log + videoscan.log through ONE sink (`refileNote`).
//
// (For Rick: `@MainActor` ≈ "runs on the UI thread"; `@concurrent` is what
// actually LEAVES it for the background pool — a plain `nonisolated async`
// in this project runs on the caller's actor, the Approachable Concurrency
// trap.)

import Combine
import Foundation
import os
import VideoScanCore

// MARK: - Published state

/// The Misfiled list as last computed. Views read it with O(1) lookups.
struct ArchiveMisfiledState {
    /// The records version this was computed for (nil = never computed).
    var version: RecordsVersion?
    var rootPath: String?
    /// Findings by the Archive window's ROW id (the original when it is
    /// still in the catalog, else the archive copy).
    var byRow: [UUID: ArchiveRefile.Finding] = [:]
    /// Archive-copy id → row id (the Catalog badge on a copy row).
    var rowByCopy: [UUID: UUID] = [:]
    /// Row ids in filed-path order (stable list order).
    var rowIDs: [UUID] = []
    /// Why the list is empty because it could NOT be computed (manifest
    /// missing / damaged), nil otherwise.
    var note: String?
    /// How many archive copies were looked at.
    var evaluated = 0

    var count: Int { rowIDs.count }

    func finding(forRecordID id: UUID) -> ArchiveRefile.Finding? {
        if let f = byRow[id] { return f }
        return rowByCopy[id].flatMap { byRow[$0] }
    }
}

/// Everything the Refile sheet shows before anything is touched.
struct ArchiveRefilePreview: Identifiable, Sendable {
    let id = UUID()
    let rowID: UUID
    let copyID: UUID
    let rootPath: String
    let archiveFilename: String
    let fromRelPath: String
    let streamTypeRaw: String
    let ext: String
    /// The date and name the sheet opens with (the current resolved date,
    /// or the folder's year when nothing trustworthy is known).
    let initialHint: ArchiveDateHint
    let initialName: String
    /// Where `initialHint` came from; nil = only the folder says.
    let provenance: ArchiveRefile.Provenance?
    let isMisfiled: Bool
    let why: String
    let promotedAt: Date?

    var streamType: StreamType { StreamType(rawValue: streamTypeRaw) ?? .ffprobeFailed }

    /// Promote's rule for this date + name.
    func target(hint: ArchiveDateHint, name: String) -> String {
        ArchiveRefile.targetRelPath(streamType: streamType, filename: archiveFilename, ext: ext,
                                    hint: hint, name: name)
    }

    /// The guard line for this date (nil = fine).
    func guardRefusal(hint: ArchiveDateHint, now: Date = Date()) -> String? {
        ArchivePathResolver.filingYearRefusal(
            facts: ArchiveRefile.facts(streamType: streamType, filename: archiveFilename, ext: ext, hint: hint),
            now: now)
    }
}

/// What the sheet says when Refile returns.
struct ArchiveRefileResult: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case refiled, refused, rolledBack, mixedState, incompleteRecovery, completedWithWarnings }
    let kind: Kind
    let message: String
}

extension VideoScanModel {

    // MARK: - The one audit sink

    /// console + catalog.log (`log`), videoscan.log (`appLog`), unified log.
    func refileNote(_ line: String) {
        log(line)
        appLog.write("[refile] " + line)
        refileLog.notice("\(line, privacy: .public)")
    }

    /// The same sink for the off-main engine: videoscan.log and the unified
    /// log are written synchronously (a hang leaves its "begin" line);
    /// the console / catalog.log line hops to the main actor in order.
    func refileAuditSink() -> @Sendable (String) -> Void {
        { [weak self] line in
            appLog.write("[refile] " + line)
            refileLog.notice("\(line, privacy: .public)")
            Task { @MainActor [weak self] in self?.log(line) }
        }
    }

    // MARK: - Misfiled

    /// Records captured per main-actor slice before the refresh yields.
    /// Measured 2026-09-27 (Debug, M4): ~25 µs per archive copy — the
    /// VideoRecord property reads dominate — so 2,000 ≈ 50 ms per slice;
    /// the scale test pins the slice under a load-aware 150 ms.
    static let misfiledCaptureChunk = 2_000

    /// The archive copies' date facts, captured on the main actor. O(slice)
    /// field reads (no I/O, no allocation per non-archive record) — called
    /// from a refresh in yielding slices, never from a view body.
    func archiveMisfiledCandidates(root: String, in slice: ArraySlice<VideoRecord>) -> [ArchiveRefile.Candidate] {
        var out: [ArchiveRefile.Candidate] = []
        for rec in slice where rec.derivationKind == ArchivePromotion.derivationKind && !rec.isPurged {
            guard let rel = Self.archiveRelPath(of: rec.fullPath, root: root) else { continue }
            out.append(refileCandidate(copy: rec, relPath: rel))
        }
        return out
    }

    /// The whole catalog in one go (tests / small catalogs).
    func archiveMisfiledCandidates(root: String) -> [ArchiveRefile.Candidate] {
        archiveMisfiledCandidates(root: root, in: records[...])
    }

    /// `path` relative to the archive root, or nil. The catalog's paths are
    /// already standardized, so the common case is a string prefix — two
    /// URL parses per record (VerifyArchiveCopiesJob.relPath) cost ~4 s on
    /// main for 100k copies in Debug (scale test, 2026-09-27). Anything with
    /// a "." / ".." / "//" component still takes the careful URL form, the
    /// same split `isInsideMasterArchive` makes.
    nonisolated static func archiveRelPath(of path: String, root: String) -> String? {
        let odd = path.contains("/./") || path.contains("/../") || path.contains("//")
            || path.hasSuffix("/.") || path.hasSuffix("/..")
        if odd { return VerifyArchiveCopiesJob.relPath(of: path, underRoot: root) }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix), path.count > prefix.count else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// One candidate for an archive copy at `relPath`.
    func refileCandidate(copy: VideoRecord, relPath: String) -> ArchiveRefile.Candidate {
        let source = promotionSource(of: copy).flatMap { $0.isPurged ? nil : $0 }
        let originalName = source?.filename
            ?? {
                let ext = (copy.filename as NSString).pathExtension
                let name = ArchiveRefile.currentName(ofFilename: copy.filename)
                return ext.isEmpty ? name : name + "." + ext
            }()
        return ArchiveRefile.Candidate(
            rowID: source?.id ?? copy.id, copyID: copy.id, copyRelPath: relPath,
            streamTypeRaw: copy.streamTypeRaw, copyFilename: copy.filename, ext: copy.ext,
            originalFilename: originalName,
            originalUserDate: source?.userDate, originalUserDateConfidence: source?.userDateConfidence,
            copyUserDate: copy.userDate, copyUserDateConfidence: copy.userDateConfidence,
            embeddedCreationDate: copy.embeddedCreationDate ?? source?.embeddedCreationDate,
            originMake: copy.originMake ?? source?.originMake,
            originModel: copy.originModel ?? source?.originModel,
            originEncoder: copy.originEncoder ?? source?.originEncoder,
            inferredRecordDate: copy.inferredRecordDate ?? source?.inferredRecordDate,
            inferredDateConfidence: copy.inferredDateConfidence ?? source?.inferredDateConfidence,
            inferredDateRange: copy.inferredDateRange ?? source?.inferredDateRange)
    }

    /// Recompute the Misfiled list (off-main) unless it is current for this
    /// records version. One computation at a time; a request while one runs
    /// queues exactly one more. Safe to call often.
    func refreshArchiveMisfiled(reason: String, force: Bool = false) {
        guard let root = masterArchiveRootPath else {
            if archiveMisfiled.version != nil || !archiveMisfiled.rowIDs.isEmpty { archiveMisfiled = ArchiveMisfiledState() }
            return
        }
        let version = RecordsVersion(count: records.count, revision: volumeAggregatesRevision)
        if !force, archiveMisfiled.version == version, archiveMisfiled.rootPath == root { return }
        if archiveMisfiledTask != nil {
            archiveMisfiledRefreshQueued = true
            return
        }
        let previousNote = archiveMisfiled.note
        let previousCount = archiveMisfiled.count
        // The records array is copied by reference (copy-on-write, O(1));
        // it is read in slices, yielding the main actor between them, so a
        // 100k catalog never blocks the UI for more than one slice.
        let snapshot = records
        archiveMisfiledTask = Task { [weak self] in
            var candidates: [ArchiveRefile.Candidate] = []
            var start = snapshot.startIndex
            while start < snapshot.endIndex {
                guard let self else { return }
                let end = min(start + Self.misfiledCaptureChunk, snapshot.endIndex)
                candidates += self.archiveMisfiledCandidates(root: root, in: snapshot[start..<end])
                start = end
                await Task.yield()
            }
            refileLog.debug("misfiled refresh (\(reason, privacy: .public)): \(candidates.count) archive copies")
            let result = await Self.computeArchiveMisfiledOffMain(root: root, candidates: candidates)
            guard let self else { return }
            var state = ArchiveMisfiledState(version: version, rootPath: root)
            state.evaluated = candidates.count
            state.note = result.note
            for f in result.findings.sorted(by: { $0.filedRelPath < $1.filedRelPath }) {
                state.byRow[f.rowID] = f
                state.rowByCopy[f.copyID] = f.rowID
                state.rowIDs.append(f.rowID)
            }
            self.archiveMisfiled = state
            if let note = result.note, note != previousNote {
                // Logged once per distinct problem, not per refresh.
                self.refileNote("Archive: the Misfiled list is empty — \(note)")
            } else if state.count != previousCount {
                self.log("Archive: \(state.count) archived file(s) are filed under a year their date no longer says (Misfiled).")
            }
            self.archiveMisfiledTask = nil
            if self.archiveMisfiledRefreshQueued {
                self.archiveMisfiledRefreshQueued = false
                self.refreshArchiveMisfiled(reason: "queued")
            }
        }
    }

    /// Off-main: read the manifest's relpaths (validated descriptor), then
    /// evaluate. A manifest that cannot be read → no findings + the reason.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func computeArchiveMisfiledOffMain(root: String,
                                                         candidates: [ArchiveRefile.Candidate]) async
        -> (findings: [ArchiveRefile.Finding], note: String?) {
        switch ArchiveRefile.manifestRelPaths(rootPath: root) {
        case .failure(let f):
            return ([], f.reason)
        case .success(let rel):
            return (ArchiveRefile.findings(candidates: candidates, manifestRelPaths: rel), nil)
        }
    }

    /// The Archive window's Misfiled rows, in list order. O(misfiled).
    var archiveMisfiledRecords: [VideoRecord] {
        archiveMisfiled.rowIDs.compactMap { record(forID: $0) }
    }

    /// The Catalog badge for a row (original or its archive copy), or nil.
    func misfiledBadgeText(for rec: VideoRecord) -> String? {
        archiveMisfiled.finding(forRecordID: rec.id)?.badgeText
    }

    // MARK: - Preview (the sheet opens with this)

    /// The archive copy a row stands for: itself, or the original's copy.
    func archiveCopyForRefile(_ rec: VideoRecord) -> VideoRecord? {
        isArchiveCopy(rec) ? rec : masterArchiveCopy(of: rec)
    }

    /// Build the sheet's preview for an archived row. Main-actor facts,
    /// then one off-main hop for the manifest row + the ledger's dateSet
    /// line. Touches nothing on disk. `.failure` = why Refile is not
    /// offered for this row (logged).
    func makeRefilePreview(recordID: UUID) async -> Result<ArchiveRefilePreview, ArchiveRefileRefusal> {
        func no(_ why: String) -> Result<ArchiveRefilePreview, ArchiveRefileRefusal> {
            refileNote("Refile: not offered — \(why)")
            return .failure(ArchiveRefileRefusal(message: why))
        }
        guard let row = record(forID: recordID) else { return no("that row is no longer in the catalog") }
        guard let root = masterArchiveRootPath else { return no("no Master Archive is designated") }
        guard let copy = archiveCopyForRefile(row) else { return no("\(row.filename) has no copy in the Master Archive") }
        guard let rel = VerifyArchiveCopiesJob.relPath(of: copy.fullPath, underRoot: root) else {
            return no("the archive copy of \(row.filename) is not inside the archive (\(copy.fullPath))")
        }
        let candidate = refileCandidate(copy: copy, relPath: rel)
        let finding = ArchiveRefile.evaluate(candidate)
        let current = ArchiveRefile.currentDate(of: candidate)
        let filedTail = ArchiveRefile.filedTail(relPath: rel)?.tail ?? ""
        // Nothing trustworthy known → open on the folder's own year.
        let folderYear = Int(filedTail.split(separator: "/").last.map(String.init) ?? "")
        let initialHint = finding?.dated ?? current?.hint ?? folderYear.map { .year($0) } ?? .unknown
        let provenance = finding?.provenance ?? current?.provenance
        // The date's own record: the original (row) or the copy.
        var datedRecordID: UUID?
        var datedCanonical: String?
        if case .userDate(let onCopy, _, let canonical)? = provenance {
            datedRecordID = onCopy ? copy.id : candidate.rowID
            datedCanonical = canonical
        }
        let ledger = mediaLedger
        let facts = await Self.refilePreviewFactsOffMain(root: root, relPath: rel, ledger: ledger,
                                                         datedRecordID: datedRecordID, datedCanonical: datedCanonical)
        let why: String
        if let provenance {
            why = ArchiveRefile.whyLine(provenance: provenance, dated: initialHint, datedOn: facts.datedOn,
                                        filedTail: filedTail, promotedAt: facts.promotedAt,
                                        isMisfiled: finding != nil)
        } else {
            why = "Nothing reliable says when this was filmed; it is filed as \(ArchiveRefile.folderLabel(tail: filedTail)). Type the date below to refile it."
        }
        let preview = ArchiveRefilePreview(
            rowID: candidate.rowID, copyID: copy.id, rootPath: root, archiveFilename: copy.filename,
            fromRelPath: rel, streamTypeRaw: copy.streamTypeRaw, ext: copy.ext,
            initialHint: initialHint, initialName: ArchiveRefile.currentName(ofFilename: copy.filename),
            provenance: provenance, isMisfiled: finding != nil, why: why, promotedAt: facts.promotedAt)
        refileNote("Refile: sheet opened for \(copy.filename) at \(rel) — \(why)")
        return .success(preview)
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func refilePreviewFactsOffMain(root: String, relPath: String, ledger: MediaLedger,
                                                     datedRecordID: UUID?, datedCanonical: String?) async
        -> (promotedAt: Date?, datedOn: Date?) {
        var promotedAt: Date?
        if case .success(let rows) = ArchiveRefile.manifestRows(rootPath: root) {
            promotedAt = rows.last(where: { $0.relPath == relPath })?.promotedAt
        }
        var datedOn: Date?
        if let id = datedRecordID, let canonical = datedCanonical {
            datedOn = ledger.events(forRecordID: id)
                .last(where: { $0.event == .dateSet && $0.detail[MediaLedgerEvent.Detail.date] == canonical })?.at
        }
        return (promotedAt, datedOn)
    }

    // MARK: - Refile

    /// Refile ONE archive copy to where Promote's rule puts `hint` + `name`.
    /// Order: main-actor refusals → the audited exception → the off-main
    /// engine (refusals, move, verify, index under backup, rollback) → the
    /// catalog record + the ledger. Returns what the sheet should say.
    func refileArchiveCopy(_ p: ArchiveRefilePreview, hint: ArchiveDateHint, name: String,
                           seams: ArchiveRefileEngine.Seams = .live,
                           persistence: ArchiveRefilePersistence = .live,
                           now: Date = Date()) async -> ArchiveRefileResult {
        let label = p.archiveFilename
        func refused(_ why: String) -> ArchiveRefileResult {
            refileNote("Refile: \(label) — refused: \(why). Nothing was changed.")
            return ArchiveRefileResult(kind: .refused, message: "Not refiled — \(why). Nothing was changed.")
        }
        refileNote("Refile: \(label) — Refile clicked (by rick): \(p.fromRelPath), date \(ArchiveRefile.datedLabel(hint)), name “\(name)”")

        // ---- Main-actor refusals (nothing touched).
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
            return refused("the archive copy is no longer at \(p.fromRelPath) in the catalog — reopen Refile")
        }
        if hint == .unknown { return refused("a year is needed to refile") }
        if let g = p.guardRefusal(hint: hint, now: now) { return refused("\(label) \(g)") }
        let to = p.target(hint: hint, name: name)
        guard to != p.fromRelPath else { return refused("the file is already at \(to)") }

        let dateEdited = hint != p.initialHint
        let nameEdited = name.trimmingCharacters(in: .whitespacesAndNewlines) != p.initialName
        let provenance: ArchiveRefile.Provenance = (dateEdited || p.provenance == nil)
            ? .typedOnRefileSheet : (p.provenance ?? .typedOnRefileSheet)
        var reason = p.why
        if dateEdited { reason += " You set the date to \(ArchiveRefile.datedLabel(hint)) on the Refile sheet." }
        if nameEdited { reason += " You changed the name on the Refile sheet." }

        // ---- The ONE audited exception to the archive's read-only rule.
        let auth: ArchiveRefileAuthorization
        switch ArchiveRefileAuthorization.grant(rootPath: root, fromRelPath: p.fromRelPath, toRelPath: to,
                                                reason: reason, now: now, audit: { refileNote($0) }) {
        case .success(let a): auth = a
        case .failure(let d): return refused(d.description)
        }

        let req = ArchiveRefileEngine.Request(rootPath: root, fromRelPath: p.fromRelPath, toRelPath: to,
                                              filename: label, recordDate: hint.manifestDate,
                                              dateConfidence: provenance.manifestConfidence)
        refileNote("Refile: \(label) — BEGIN \(p.fromRelPath) → \(to) (by rick; \(provenance.ledgerToken))")
        let outcome = await Self.runRefileOffMain(req, authorization: auth, seams: seams, now: now,
                                                  audit: refileAuditSink())
        // Lines from the engine hop to main in order; let them land first.
        await Task.yield()

        switch outcome {
        case .refiled(let done):
            let e = await applyRefiled(copy: copy, done: done, root: root, hint: hint, provenance: provenance,
                                       reason: reason, now: now, persistence: persistence)
            refreshArchiveMisfiled(reason: "refiled", force: true)
            let moved = "\(done.fromRelPath) → \(done.toRelPath). Fixity verified before and after; the archive index was updated (backup kept)."
            guard e.catalogSaved, e.ledgerWritten else {
                var pending: [String] = []
                if !e.catalogSaved { pending.append("the catalog could not be saved") }
                if !e.ledgerWritten { pending.append("the ledger line could not be written") }
                let retry = e.pendingWritten
                    ? "It will be finished automatically the next time VideoScan starts."
                    : "The automatic retry could NOT be recorded either — the catalog may show the old path after a restart; refile again or check the log."
                return ArchiveRefileResult(kind: .completedWithWarnings,
                                           message: "Refiled with warnings — \(moved) But \(pending.joined(separator: " and ")). \(retry)")
            }
            return ArchiveRefileResult(kind: .refiled, message: "Refiled — \(moved)")
        case .refused(let why):
            refileNote("Refile: \(label) — refused: \(why). Nothing was changed.")
            return ArchiveRefileResult(kind: .refused, message: "Not refiled — \(why). Nothing was changed.")
        case .rolledBack(let why):
            ledgerRefileRolledBack(copy: copy, from: p.fromRelPath, to: to, why: why, now: now)
            refileNote("Refile: \(label) — ROLLED BACK: \(why). The file is back at \(p.fromRelPath) and the archive index is as it was.")
            refreshArchiveMisfiled(reason: "refile rolled back", force: true)
            return ArchiveRefileResult(kind: .rolledBack,
                                       message: "Refile failed and was undone — \(why). The file is back where it was and the archive index is unchanged.")
        case .incompleteRecovery(let why):
            ledgerRefileRolledBack(copy: copy, from: p.fromRelPath, to: to,
                                   why: "INCOMPLETE RECOVERY (not confirmed durable) — \(why)", now: now)
            refileNote("Refile: \(label) — FAILED; the file was put back at \(p.fromRelPath) but the recovery is NOT confirmed durable: \(why). The archive index backup is kept in 00_Index/\(ArchiveIndexRename.backupFolder); run Verify Copies after checking the drive.")
            refreshArchiveMisfiled(reason: "refile incomplete recovery", force: true)
            return ArchiveRefileResult(kind: .incompleteRecovery,
                                       message: "Refile failed and was put back, but the drive did not confirm the move back was saved (recovery not confirmed durable). The index backup was kept. Check the drive, then run Verify Copies.\n\(why)")
        case .mixedState(let why, let originalAt):
            ledgerRefileRolledBack(copy: copy, from: p.fromRelPath, to: to, why: "ROLLBACK FAILED — \(why)", now: now)
            // The record must say where the ARCHIVED ORIGINAL is — found by
            // identity in the engine, never "a file exists there" (codex #3).
            if let originalAt, originalAt != p.fromRelPath {
                let at = (root as NSString).appendingPathComponent(originalAt)
                refileNote("Refile: \(label) — catalog record now points at the archived original, \(originalAt) (identity-checked); the file at \(p.fromRelPath) is NOT it and was left alone")
                moveRecord(copy, to: at)
                if !saveCatalogNow() { saveCatalogDebounced() }
            } else if originalAt == nil {
                refileNote("Refile: \(label) — the archived original was not found by identity at \(p.fromRelPath) or \(to); the catalog record was left unchanged — check both paths by hand")
            }
            refileNote("Refile: \(label) — FAILED AND COULD NOT BE FULLY UNDONE: \(why)")
            refreshArchiveMisfiled(reason: "refile mixed state", force: true)
            return ArchiveRefileResult(kind: .mixedState,
                                       message: "Refile failed and could NOT be fully undone. Details (every path) are in the log:\n\(why)")
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

    /// What step (e) managed to make durable.
    struct RefileStepE { let catalogSaved: Bool; let ledgerWritten: Bool; let pendingWritten: Bool }

    /// Step (e): the catalog record, the dates that must now agree with the
    /// folder, the ledger. A durable PENDING entry is written first; the
    /// catalog save and the ledger append are AWAITED and their results
    /// reported (codex review #5) — a failure is completedWithWarnings, and
    /// the pending entry is replayed at the next launch.
    private func applyRefiled(copy: VideoRecord, done: ArchiveRefileEngine.Done, root: String,
                              hint: ArchiveDateHint, provenance: ArchiveRefile.Provenance,
                              reason: String, now: Date, persistence: ArchiveRefilePersistence) async -> RefileStepE {
        let label = copy.filename
        let newPath = (root as NSString).appendingPathComponent(done.toRelPath)
        let oldPath = copy.fullPath
        moveRecord(copy, to: newPath)
        if let fx = copy.archiveFixity, fx.digest == done.sha256 {
            copy.archiveFixity = ArchiveFixity(algorithm: fx.algorithm, digest: fx.digest,
                                               verifiedAt: now, sizeBytes: fx.sizeBytes)
        }
        let stamp = ISO8601DateFormatter().string(from: now)
        let note = "Refile \(stamp): moved in the Master Archive from \(done.fromRelPath) to \(done.toRelPath) · sha256 verified before and after · \(reason)"
        copy.notes = copy.notes.isEmpty ? note : "\(copy.notes)\n\(note)"

        // Dates: after a refile the original's and the copy's hand-entered
        // dates both say what the folder says, so the Misfiled rule (the
        // date that DIFFERS is the one that changed) stays stable.
        let source = promotionSource(of: copy)
        var dateUpdates: [ArchiveRefilePendingEntry.DateUpdate] = []
        func setDate(_ rec: VideoRecord, _ ud: String, _ conf: String) {
            guard rec.userDate != ud || rec.userDateConfidence != conf else { return }
            refileNote("Refile: \(label) — date on \(rec === copy ? "the archive copy" : "the original") \(rec.filename): \(rec.userDate ?? "none") (\(rec.userDateConfidence ?? "-")) → \(ud) (\(conf)); revert in the Inspector's date field")
            rec.userDate = ud
            rec.userDateConfidence = conf
            dateUpdates.append(.init(recordID: rec.id, userDate: ud, confidence: conf))
        }
        switch provenance {
        case .userDate(let onCopy, let known, let canonical):
            let conf = (known ? UserDateConfidence.known : .estimated).rawValue
            if onCopy { if let source { setDate(source, canonical, conf) } } else { setDate(copy, canonical, conf) }
        case .typedOnRefileSheet:
            if let ud = ArchiveRefile.userDate(for: hint) {
                let conf = UserDateConfidence.estimated.rawValue
                setDate(copy, ud, conf)
                if let source { setDate(source, ud, conf) }
            }
        case .machine:
            break
        }
        notifyVolumeAggregatesStale()
        objectWillChange.send()

        // Ledger lines (append-only; "what happened to <file>?").
        let subject = source ?? copy
        var events = [ledgerEvent(.refiled, for: subject, by: .rick, at: now, detail: [
            MediaLedgerEvent.Detail.from: done.fromRelPath,
            MediaLedgerEvent.Detail.to: done.toRelPath,
            MediaLedgerEvent.Detail.reason: reason,
            MediaLedgerEvent.Detail.date: hint.manifestDate,
            MediaLedgerEvent.Detail.confidence: provenance.manifestConfidence,
            MediaLedgerEvent.Detail.provenance: provenance.ledgerToken,
            MediaLedgerEvent.Detail.fixity: done.sha256,
            MediaLedgerEvent.Detail.archive: MasterArchiveLayout.displayName(forRootPath: root),
        ])]
        for u in dateUpdates {
            guard let rec = record(forID: u.recordID) else { continue }
            events.append(ledgerEvent(.dateSet, for: rec, by: .rick, at: now, detail: [
                MediaLedgerEvent.Detail.date: u.userDate,
                MediaLedgerEvent.Detail.confidence: u.confidence,
            ]))
        }

        // Every line carries a stable idempotency key, so a retry after a
        // partial append writes exactly the missing ones (r3 #3).
        let entryID = UUID()
        events = events.enumerated().map { i, e in
            var detail = e.detail
            detail[MediaLedgerEvent.Detail.idempotencyKey] = "refile:\(entryID.uuidString):\(i)"
            return MediaLedgerEvent(at: e.at, event: e.event, recordID: e.recordID, contentKey: e.contentKey,
                                    filename: e.filename, fullPath: e.fullPath, by: e.by,
                                    batchID: e.batchID, detail: detail)
        }

        // The durable retry, BEFORE the two steps it covers.
        // A chain: older entries of this record whose catalog step is still
        // owed hand over their FROM paths and their date updates (newer
        // updates win per record), so a relaunch with NONE of the saves on
        // disk still recognizes the record and lands the latest state.
        let existing = loadPendingRefiles()
        let owed = existing.filter { $0.copyID == copy.id && !$0.catalogDone }.sorted { $0.sequence < $1.sequence }
        var chain: [String] = []
        var mergedDates: [UUID: ArchiveRefilePendingEntry.DateUpdate] = [:]
        for o in owed {
            for p in o.chainFromPaths + [o.fromFullPath] where !chain.contains(p) { chain.append(p) }
            for u in o.dateUpdates { mergedDates[u.recordID] = u }
        }
        for u in dateUpdates { mergedDates[u.recordID] = u }
        let chainDates = mergedDates.values.sorted { $0.recordID.uuidString < $1.recordID.uuidString }
        var entry = ArchiveRefilePendingEntry(id: entryID, at: now,
                                              sequence: (existing.map(\.sequence).max() ?? 0) + 1,
                                              copyID: copy.id, fromFullPath: oldPath, chainFromPaths: chain,
                                              newFullPath: newPath,
                                              fromRelPath: done.fromRelPath, toRelPath: done.toRelPath,
                                              device: done.device, inode: done.inode, size: done.size,
                                              sha256: done.sha256,
                                              dateUpdates: chainDates, ledgerEvents: events,
                                              catalogDone: false, ledgerDone: false)
        let pendingWritten = updatePendingRefiles { list in
            // This refile SUPERSEDES any older entry for the same record:
            // their catalog step is dropped (the record is here now); an
            // older ledger step still owed is kept — that history happened.
            for i in list.indices where list[i].copyID == entry.copyID && !list[i].catalogDone {
                list[i].catalogDone = true
                appLog.write("[refile] pending entry \(list[i].fromRelPath) → \(list[i].toRelPath) superseded by a newer refile of the same file; its catalog step is dropped")
            }
            list.removeAll { $0.copyID == entry.copyID && $0.catalogDone && $0.ledgerDone }
            list.append(entry)
        }
        if !pendingWritten {
            refileNote("Refile: \(label) — the pending-refile retry record could not be written (\(pendingRefilesURL.path)); continuing — the outcome will say so if anything below fails")
        }

        entry.catalogDone = persistence.saveCatalog(self)
        if !entry.catalogDone {
            refileNote("Refile: \(label) — the catalog could NOT be saved: the archive and its index are updated, the catalog record is not yet on disk. Pending retry: \(pendingWritten ? pendingRefilesURL.path : "NOT recorded")")
            persistence.scheduleRetrySave(self)
        }
        entry.ledgerDone = await persistence.appendLedger(self, events)
        if !entry.ledgerDone {
            refileNote("Refile: \(label) — the ledger line could NOT be written. Pending retry: \(pendingWritten ? pendingRefilesURL.path : "NOT recorded")")
        }
        if entry.catalogDone && entry.ledgerDone {
            _ = updatePendingRefiles { $0.removeAll { $0.id == entry.id } }
        } else if pendingWritten {
            let done = entry
            _ = updatePendingRefiles { list in
                if let i = list.firstIndex(where: { $0.id == done.id }) { list[i] = done }
            }
        }
        mediaLedger.mirror(intoArchiveRoot: root)

        let status = entry.catalogDone && entry.ledgerDone ? "ledger written" : "COMPLETED WITH WARNINGS (catalog saved: \(entry.catalogDone), ledger written: \(entry.ledgerDone))"
        refileNote("Refile: \(label) — moved \(done.fromRelPath) → \(done.toRelPath); fixity verified; index updated (\(done.linesChanged) line\(done.linesChanged == 1 ? "" : "s") in \(done.indexFilesChanged) file\(done.indexFilesChanged == 1 ? "" : "s")\(done.backupDir.map { ", backup \($0)" } ?? "")); \(status). To undo: Refile it back.")
        return RefileStepE(catalogSaved: entry.catalogDone, ledgerWritten: entry.ledgerDone, pendingWritten: pendingWritten)
    }

    static let pendingRefilesFilename = "pending-refiles.json"

    /// `<ledger folder>/pending-refiles.json` — beside the media ledger
    /// (App Support; a sandbox under tests).
    var pendingRefilesURL: URL { mediaLedger.directory.appendingPathComponent(Self.pendingRefilesFilename) }

    /// lstat identity of a path (a symlink is not the file); nil = absent.
    nonisolated static func lstatIdentity(_ path: String) -> (device: UInt64, inode: UInt64, size: Int64)? {
        var sb = stat()
        guard lstat(path, &sb) == 0, (sb.st_mode & S_IFMT) == S_IFREG else { return nil }
        return (UInt64(sb.st_dev), UInt64(sb.st_ino), Int64(sb.st_size))
    }

    /// On-disk shape of pending-refiles.json. `version` lets a future
    /// schema change migrate instead of guess (r4 #3).
    struct PendingRefilesFile: Codable {
        static let currentVersion = 1
        var version: Int
        var entries: [ArchiveRefilePendingEntry]
    }

    /// The pending list. A file that exists but cannot be read — damaged,
    /// or a schema this build does not know — is NEVER overwritten: it is
    /// moved aside to `pending-refiles.json.unreadable-<UTC>` (logged to the
    /// console, catalog.log and videoscan.log) and a fresh list starts.
    func loadPendingRefiles() -> [ArchiveRefilePendingEntry] {
        let url = pendingRefilesURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url),
           let file = try? dec.decode(PendingRefilesFile.self, from: data),
           file.version == PendingRefilesFile.currentVersion {
            return file.entries
        }
        setAsideUnreadablePendingFile(url)
        return []
    }

    private func setAsideUnreadablePendingFile(_ url: URL) {
        let stamp = ArchiveIndexRename.backupStamp(Date())
        // One no-clobber rename (RENAME_EXCL) to a fresh name: the set-aside
        // copy can never land on anything, and nothing is ever deleted.
        var aside = url
        var e: Int32 = EEXIST
        for n in 1...1_000 where e == EEXIST {
            aside = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).unreadable-\(stamp)\(n == 1 ? "" : "-\(n)")")
            e = renamex_np(url.path, aside.path, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
        }
        do {
            if e != 0 { throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO) }
            refileNote("Refile: the pending-refile list \(url.path) could not be read (damaged, or written by a different VideoScan version) — it was NOT overwritten: moved aside to \(aside.path) for a person to look at. A new list starts now; refiles recorded only in the old file are NOT being retried.")
        } catch {
            refileNote("Refile: the pending-refile list \(url.path) could not be read AND could not be moved aside (\(error.localizedDescription)) — it is left untouched and no new retry will be written over it.")
        }
    }

    /// Read-modify-publish the pending list (atomic, full fsync). Returns
    /// false (logged) when it could not be made durable — including when an
    /// unreadable file could not be moved aside (never overwritten).
    @discardableResult
    func updatePendingRefiles(_ change: (inout [ArchiveRefilePendingEntry]) -> Void) -> Bool {
        var list = loadPendingRefiles()
        if FileManager.default.fileExists(atPath: pendingRefilesURL.path),
           (try? Data(contentsOf: pendingRefilesURL)).flatMap({ data -> PendingRefilesFile? in
               let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
               return try? dec.decode(PendingRefilesFile.self, from: data)
           })?.version != PendingRefilesFile.currentVersion {
            return false   // still unreadable in place (could not be moved aside): never clobber it
        }
        change(&list)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        do {
            let file = PendingRefilesFile(version: PendingRefilesFile.currentVersion, entries: list)
            try AtomicFilePublish.write(try enc.encode(file), to: pendingRefilesURL,
                                        durability: .fullFsync, createIntermediates: true)
            return true
        } catch {
            appLog.write("[refile] pending-refile list \(pendingRefilesURL.path) not written — \(error.localizedDescription)")
            return false
        }
    }

    /// Finish refiles whose catalog save or ledger line did not land (run
    /// at launch, and callable any time). The catalog step re-applies the
    /// record's path and dates; the ledger step appends the saved lines
    /// unless the ledger already has them. Returns how many entries were
    /// completed and cleared.
    @discardableResult
    func replayPendingRefiles(persistence: ArchiveRefilePersistence = .live) async -> Int {
        let pending = loadPendingRefiles()
        guard !pending.isEmpty else { return 0 }
        refileNote("Refile: finishing \(pending.count) refile(s) whose catalog save or ledger line did not land (\(pendingRefilesURL.path))")
        var completed = 0
        for var entry in pending {
            if !entry.catalogDone {
                if let rec = record(forID: entry.copyID) {
                    // Apply ONLY while the record still points where this
                    // refile started (or already at its end) AND the file at
                    // the end is THIS file by identity. Anything else is
                    // stale: logged and dropped, never applied (r3 #2).
                    let pointsHere = rec.fullPath == entry.fromFullPath || rec.fullPath == entry.newFullPath
                        || entry.chainFromPaths.contains(rec.fullPath)
                    let ident = Self.lstatIdentity(entry.newFullPath)
                    let isThisFile = ident.map { $0.device == entry.device && $0.inode == entry.inode && $0.size == entry.size } ?? false
                    if pointsHere && isThisFile {
                        if rec.fullPath != entry.newFullPath { moveRecord(rec, to: entry.newFullPath) }
                        for u in entry.dateUpdates {
                            guard let r = record(forID: u.recordID) else { continue }
                            r.userDate = u.userDate
                            r.userDateConfidence = u.confidence
                        }
                        objectWillChange.send()
                        entry.catalogDone = persistence.saveCatalog(self)
                    } else if pointsHere && ident == nil {
                        refileNote("Refile: pending entry for \(entry.toRelPath) — the file is not reachable at \(entry.newFullPath) now; kept for the next launch")
                        continue
                    } else {
                        refileNote("Refile: pending entry \(entry.fromRelPath) → \(entry.toRelPath) is STALE (record now at \(rec.fullPath); file at the target \(isThisFile ? "is" : "is NOT") the refiled file) — dropped, not applied")
                        entry.catalogDone = true
                    }
                } else {
                    refileNote("Refile: pending entry for \(entry.toRelPath) — its archive copy is no longer in the catalog; catalog step dropped")
                    entry.catalogDone = true
                }
            }
            if !entry.ledgerDone {
                // Append exactly the lines whose idempotency key is not yet
                // in the ledger — a partial earlier append (a prefix landed)
                // is completed, never duplicated (r3 #3).
                let key = MediaLedgerEvent.Detail.idempotencyKey
                let ids = Set(entry.ledgerEvents.map(\.recordID))
                let present = Set(ids.flatMap { mediaLedger.events(forRecordID: $0) }.compactMap { $0.detail[key] })
                let missing = entry.ledgerEvents.filter { e in e.detail[key].map { !present.contains($0) } ?? true }
                entry.ledgerDone = missing.isEmpty ? true : await persistence.appendLedger(self, missing)
            }
            let finished = entry
            if finished.catalogDone && finished.ledgerDone {
                completed += 1
                _ = updatePendingRefiles { $0.removeAll { $0.id == finished.id } }
                refileNote("Refile: pending entry for \(finished.fromRelPath) → \(finished.toRelPath) completed (catalog + ledger)")
            } else {
                _ = updatePendingRefiles { list in
                    if let i = list.firstIndex(where: { $0.id == finished.id }) { list[i] = finished }
                }
                refileNote("Refile: pending entry for \(finished.toRelPath) still incomplete (catalog saved: \(finished.catalogDone), ledger written: \(finished.ledgerDone)); kept for the next launch")
            }
        }
        if completed > 0 { refreshArchiveMisfiled(reason: "pending refiles replayed", force: true) }
        return completed
    }

    /// Point a record at the file's new place (after the file moved).
    private func moveRecord(_ rec: VideoRecord, to newPath: String) {
        let oldPath = rec.fullPath
        rec.fullPath = newPath
        rec.filename = (newPath as NSString).lastPathComponent
        rec.directory = (newPath as NSString).deletingLastPathComponent
        invalidateThumbnailCacheEntry(forPath: oldPath)
        searchIndex.update(rec)
        notifyVolumeAggregatesStale()
    }

    private func ledgerRefileRolledBack(copy: VideoRecord, from: String, to: String, why: String, now: Date) {
        let subject = promotionSource(of: copy) ?? copy
        ledgerAppend([ledgerEvent(.refileRolledBack, for: subject, by: .rick, at: now, detail: [
            MediaLedgerEvent.Detail.from: from,
            MediaLedgerEvent.Detail.to: to,
            MediaLedgerEvent.Detail.reason: why,
        ])])
    }
}

/// Step (e)'s persistence, injectable so a test can fail the catalog save
/// and the ledger append independently (codex review #5). Production =
/// the durable catalog save and the ledger's confirmed append.
struct ArchiveRefilePersistence: Sendable {
    var saveCatalog: @MainActor @Sendable (VideoScanModel) -> Bool
    var appendLedger: @MainActor @Sendable (VideoScanModel, [MediaLedgerEvent]) async -> Bool
    /// The best-effort retry after a failed save (the debounced save).
    var scheduleRetrySave: @MainActor @Sendable (VideoScanModel) -> Void = { $0.saveCatalogDebounced() }

    static let live = ArchiveRefilePersistence(
        saveCatalog: { $0.saveCatalogNow() },
        appendLedger: { model, events in await model.mediaLedger.appendConfirmed(events) })
}

/// One refile whose step (e) did not fully land — replayed at launch.
struct ArchiveRefilePendingEntry: Codable, Equatable, Sendable {
    struct DateUpdate: Codable, Equatable, Sendable {
        let recordID: UUID
        let userDate: String
        let confidence: String
    }
    let id: UUID
    let at: Date
    /// Order of writing (max + 1); a newer refile of the same record
    /// supersedes older entries' catalog step (r3 #2).
    let sequence: Int
    let copyID: UUID
    /// Where the record pointed BEFORE this refile — replay applies only
    /// while it still points there (or already at `newFullPath`).
    let fromFullPath: String
    /// Earlier FROM paths of the same record's chain of refiles whose
    /// catalog saves also did not land (r4 #1): after a relaunch the
    /// record may still point at the FIRST of them. Replay accepts any.
    let chainFromPaths: [String]
    let newFullPath: String
    let fromRelPath: String
    let toRelPath: String
    /// The moved file's identity + fingerprint: replay applies only when
    /// THIS file is at `newFullPath`.
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let sha256: String
    let dateUpdates: [DateUpdate]
    let ledgerEvents: [MediaLedgerEvent]
    var catalogDone: Bool
    var ledgerDone: Bool
}

/// Why Refile is not offered for a row.
struct ArchiveRefileRefusal: Error, Equatable, Sendable {
    let message: String
}
