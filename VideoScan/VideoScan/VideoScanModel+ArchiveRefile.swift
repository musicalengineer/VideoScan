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
    enum Kind: Equatable, Sendable { case refiled, refused, rolledBack, mixedState, incompleteRecovery }
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
            applyRefiled(copy: copy, done: done, root: root, hint: hint, provenance: provenance,
                         reason: reason, now: now)
            refreshArchiveMisfiled(reason: "refiled", force: true)
            return ArchiveRefileResult(kind: .refiled,
                                       message: "Refiled — \(done.fromRelPath) → \(done.toRelPath). Fixity verified before and after; the index was updated (backup kept).")
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

    /// Step (e): the catalog record, the dates that must now agree with the
    /// folder, the ledger, the archive's ledger mirror, the done line.
    private func applyRefiled(copy: VideoRecord, done: ArchiveRefileEngine.Done, root: String,
                              hint: ArchiveDateHint, provenance: ArchiveRefile.Provenance,
                              reason: String, now: Date) {
        let label = copy.filename
        let newPath = (root as NSString).appendingPathComponent(done.toRelPath)
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
        var dateChanged: [VideoRecord] = []
        func setDate(_ rec: VideoRecord, _ ud: String, _ conf: String) {
            guard rec.userDate != ud || rec.userDateConfidence != conf else { return }
            refileNote("Refile: \(label) — date on \(rec === copy ? "the archive copy" : "the original") \(rec.filename): \(rec.userDate ?? "none") (\(rec.userDateConfidence ?? "-")) → \(ud) (\(conf)); revert in the Inspector's date field")
            rec.userDate = ud
            rec.userDateConfidence = conf
            dateChanged.append(rec)
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
        if !saveCatalogNow() {
            refileNote("Refile: \(label) — the immediate catalog save did not reach disk; the debounced save will retry (the archive and its index are already updated)")
            saveCatalogDebounced()
        }

        // Ledger (append-only; "what happened to <file>?").
        let subject = source ?? copy
        ledgerAppend([ledgerEvent(.refiled, for: subject, by: .rick, at: now, detail: [
            MediaLedgerEvent.Detail.from: done.fromRelPath,
            MediaLedgerEvent.Detail.to: done.toRelPath,
            MediaLedgerEvent.Detail.reason: reason,
            MediaLedgerEvent.Detail.date: hint.manifestDate,
            MediaLedgerEvent.Detail.confidence: provenance.manifestConfidence,
            MediaLedgerEvent.Detail.provenance: provenance.ledgerToken,
            MediaLedgerEvent.Detail.fixity: done.sha256,
            MediaLedgerEvent.Detail.archive: MasterArchiveLayout.displayName(forRootPath: root),
        ])])
        for rec in dateChanged { noteUserDateEdited(rec, by: .rick) }
        mediaLedger.mirror(intoArchiveRoot: root)

        refileNote("Refile: \(label) — moved \(done.fromRelPath) → \(done.toRelPath); fixity verified; index updated (\(done.linesChanged) line\(done.linesChanged == 1 ? "" : "s") in \(done.indexFilesChanged) file\(done.indexFilesChanged == 1 ? "" : "s")\(done.backupDir.map { ", backup \($0)" } ?? "")); ledger written. To undo: Refile it back.")
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

/// Why Refile is not offered for a row.
struct ArchiveRefileRefusal: Error, Equatable, Sendable {
    let message: String
}
