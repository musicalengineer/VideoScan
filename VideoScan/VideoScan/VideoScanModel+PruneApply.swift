// VideoScanModel+PruneApply.swift
// "Archived — what next?" → Apply (promote-and-prune stage 2, turned on
// 2026-09-19). Rick: "we should be deleting dups if user wants once a file
// is promoted." Until then Apply was a disabled button with an empty
// action — the dry run he ruled on 9/12 — and after a week of real batches
// it acts.
//
// 2026-09-20 — the sheet became a per-copy CHECKLIST ("I want to see a
// list of dups and decide which ones to delete, maybe leave one behind,
// maybe not"). The bar ADVISES; the person's checks are the truth. So
// Apply takes `selected` — the copy record ids the person checked — and
// no longer intersects "the plan the user saw" with "the fresh plan's
// trash": a family the bar does not cover (★★★ with no cloud copy
// attested) used to hide its copies; now they are offered, and a choice
// that goes against the bar is recorded as such (`override` on the
// approval line) rather than refused.
//
// v3 (2026-09-20, Rick's ruling after using it): versions (trimmed /
// balanced / transcoded) and copies with a note are offered too. The
// note is CARRIED to the archive copy's record (the same union rules as
// duplicate deletion and repair adoption, `applyHumanMetadataInheritance`)
// before the file goes; a note ADDED since the list was shown holds the
// copy — the person did not see it. A version's archive copy is its
// FAMILY's (it has no promote link of its own), so the family from the
// fresh plan names the archive copy for the disk check and the carry.
//
// v4 (2026-09-20 evening, codex follow-up #1/#2/#3/#6 + Rick: "the app
// blocks when post-promote delete of big files"): the work is a PIPELINE
// of three steps that two drivers share —
//   `preparePrune`   the fresh plan, the person's checks, the cheap stat
//                    checks → the list of copies to work through;
//   `pruneOneCopy`   ONE copy: archive evidence → byte verdict → carry →
//                    the guarded Trash (verify → re-stat → live catalog
//                    re-authorization → move), nothing batched;
//   `finishPrune`    the approval ledger line with the ACTUAL counts.
// `applyPrune` runs them back to back (tests, and any caller that wants
// the whole thing in one await); `PruneApplyJob` runs them as a Media
// File Operation, one file at a time, with pause/cancel between files —
// nothing long runs behind a modal.
//
// This is a DELETE path, so like ⌘⌫ (VideoScanModel+TrashSelection) it
// adds NO file-deletion code of its own. It is a plan in front of the ONE
// existing Trash routine, `deleteConfirmedJunk(_:mode:guard:)`, which
// already leaves Master Archive files alone, skips offline drives, stamps
// purgedAt + .trashed, publishes, and writes a `copyTrashed` Media Ledger
// line per file that actually left the disk.
//
// What the plan adds, because this is the one delete that runs on files
// the user did not pick one by one in the table:
//   1. FRESH PLAN — the plan is recomputed with the same options at the
//      moment of Apply; a checked copy may go only if the fresh plan still
//      offers it as CHECKABLE: `isCandidate` (online, not a pair member,
//      not inside the archive) in a family with a FIXITY-VERIFIED archive
//      copy — AND the family's bar verdict is the one the person confirmed
//      (an override that appeared or grew since the sheet was read holds
//      the family's checked copies) — AND no note appeared on it since.
//      A drive unplugged, an archive copy that lost its fixity, an
//      attestation withdrawn since the sheet opened → that copy is held,
//      and named with the fresh reason.
//   2. ON-DISK SAFETY, per copy: the working copy the plan would keep
//      (the row hinted `.keeper`, if NOT itself checked) exists at its
//      recorded size; the copy itself is still its recorded size (a file
//      rewritten in place is a different file). Any failure holds the
//      copy, with the reason.
//   3. ARCHIVE EVIDENCE, once per archive copy per batch (codex follow-up
//      2026-09-20 #2 / #6): the family's fixity-verified archive copy must
//      be, NOW, the bytes its read-back digest describes — its stored
//      stamp reproduces to the ctime, or it is read in full and matches.
//      Anything else holds every copy in that family, named "archive copy
//      changed". The fresh fixity is stored on the archive record and
//      reused by every later copy in the batch (one archive read, not N).
//   4. BYTE-FOR-BYTE, per copy (VideoScanModel+PruneVerification): a
//      DUPLICATE is read in full against the archive copy's current
//      fixity (`SignatureVerification.verifyAgainstStoredKeeper`, off-
//      main); the promotion ORIGINAL is trusted unread only while its
//      current stat reproduces the stamp Promote bound to its digest
//      (codex #1 — never on the strength of a later archive audit), else
//      it is read like a duplicate; a VERSION goes on provenance — that IS
//      the ruling; it never claimed identical bytes. Every verdict yields
//      a `PruneProof`: the target's and the archive copy's identity stamps
//      plus the catalog facts it rests on.
//   5. THE PROOF TRAVELS TO THE MUTATION (codex #3): the Trash routine's
//      `JunkDeletionGuard` re-checks the file's proof twice — the live
//      catalog on the main actor just before the off-main hop (record
//      active, same path, same family, archive copy active with the same
//      fixity), and both stat stamps immediately before the file's own
//      trashItem. A mismatch holds the file, named; nothing moves.
//   6. An `approval` ledger line when the batch is done: "Rick approved N
//      copies to Trash" with the ACTUAL count moved — and `override` when
//      the choice went against the bar ("2 copies — ★★★ / Important — no
//      cloud or off-site copy attested").
// The PrunePlan rules themselves (fixity-verified archive copy, online,
// not a pair member, never inside the archive) are PrunePlan.compute's,
// unchanged. Unchecked copies are NEVER moved, even when the plan's
// default would have trashed them: the selection is the truth.
//
// Memory: O(copies in the batch's families). Whole-file reads stream in
// 1 MiB blocks off the main actor; nothing is held in memory.

import Foundation
import VideoScanCore

extension VideoScanModel {

    struct PruneApplyOutcome: Equatable {
        var trashed = 0
        var trashedBytes: Int64 = 0
        var alreadyMissing = 0
        var skippedOffline = 0
        /// Copies that went against the bar (from the approval's `override`).
        var overrideCount = 0
        /// Copies whose human metadata was carried to the archive copy.
        var carried = 0
        /// Copies read in full and found byte-identical to the archive copy.
        var verified = 0
        /// Archive copies read in full for their evidence (no usable stamp
        /// yet) — at most one per archive copy per batch.
        var archiveReads = 0
        /// "filename — reason" for copies Apply would not touch.
        var held: [String] = []
        /// "filename — error" for copies the Trash routine could not move.
        var failed: [String] = []

        var summary: String {
            var parts = ["Moved \(trashed) cop\(trashed == 1 ? "y" : "ies") to the Trash (\(MediaBytes.display(trashedBytes)))"]
            if overrideCount > 0 { parts.append("\(overrideCount) against the bar you set") }
            if verified > 0 { parts.append("\(verified) checked byte-for-byte against the archive") }
            if archiveReads > 0 { parts.append("\(archiveReads) archive cop\(archiveReads == 1 ? "y" : "ies") read in full") }
            if carried > 0 { parts.append("notes and marks from \(carried) carried to the archive copy") }
            if alreadyMissing > 0 { parts.append("\(alreadyMissing) already gone") }
            if skippedOffline > 0 { parts.append("\(skippedOffline) on a drive that isn't connected") }
            if !held.isEmpty { parts.append("\(held.count) held back — changed since the list was shown") }
            if !failed.isEmpty { parts.append("\(failed.count) could not be moved") }
            return parts.joined(separator: " · ")
        }

        /// Fold one copy's result in.
        mutating func absorb(_ o: PruneCopyOutcome, item: PruneItem) {
            if o.readInFull { verified += 1 }
            if o.archiveReadInFull { archiveReads += 1 }
            if o.carried { carried += 1 }
            switch o.result {
            case .trashed(let bytes): trashed += 1; trashedBytes += bytes
            case .held(let why): held.append("\(item.filename) — \(why)")
            case .failed(let why): failed.append("\(item.filename) — \(why)")
            case .alreadyMissing: alreadyMissing += 1
            case .skippedOffline: skippedOffline += 1
            }
        }
    }

    /// A copy held back, with why.
    struct PruneHeld: Equatable {
        let copy: PrunePlan.CopyRef
        let reason: String
        var line: String { "\(copy.filename) — \(reason)" }
    }

    /// Which of the copies the person checked may go: those the FRESH plan
    /// still offers as checkable, in families whose bar VERDICT is what
    /// the person confirmed. Order = the rows of the plan the person saw.
    /// A checked id that the shown plan never offered (an archive copy —
    /// never a row — or a disabled row) is held, not trusted; one the
    /// fresh plan no longer knows is held too; one that gained a NOTE
    /// since the sheet was read is held (the person did not see it); and
    /// a family whose fresh verdict carries an override the shown one did
    /// not (an attestation withdrawn in another window, a device gone)
    /// holds every checked copy in it — a verdict that got stricter since
    /// the sheet was read is a change, not a decision (QA 2026-09-20,
    /// MAJOR 1). Ids that match nothing the sheet listed are ignored.
    nonisolated static func pruneTargets(shown: PrunePlan, selected: Set<UUID>, fresh: PrunePlan)
        -> (go: [PrunePlan.CopyRef], held: [PruneHeld]) {
        guard !selected.isEmpty else { return ([], []) }
        var freshRows: [UUID: PrunePlan.CopyRow] = [:]
        var freshFamilyOf: [UUID: Int] = [:]
        for (i, family) in fresh.families.enumerated() {
            for row in family.rows { freshRows[row.id] = row; freshFamilyOf[row.id] = i }
        }
        var go: [PrunePlan.CopyRef] = [], held: [PruneHeld] = []
        /// The verdict the person confirmed, per copy (its SHOWN family).
        var shownVerdictOf: [UUID: PrunePlan.Selection] = [:]
        for family in shown.families {
            // The archive side is never a row; a check on it is a bug
            // upstream, and it is named rather than trusted.
            for a in family.archive + family.versionArchive where selected.contains(a.id) {
                held.append(PruneHeld(copy: a, reason: "was never offered: \(PrunePlan.KeepReason.archiveCopy.displayText)"))
            }
            var verdict: PrunePlan.Selection?
            for row in family.rows where selected.contains(row.id) {
                guard row.checkable else {
                    held.append(PruneHeld(copy: row.copy, reason: "was never offered: \(row.reasonText ?? "not a candidate")"))
                    continue
                }
                guard let now = freshRows[row.id] else {
                    held.append(PruneHeld(copy: row.copy, reason: "no longer in the plan"))
                    continue
                }
                guard now.checkable else {
                    held.append(PruneHeld(copy: now.copy,
                                          reason: "changed since the list was shown: \(now.reasonText ?? "no longer a candidate")"))
                    continue
                }
                if now.hasNote, !row.hasNote {
                    held.append(PruneHeld(copy: now.copy,
                                          reason: "changed since the list was shown: \(PrunePlan.KeepReason.humanNote.displayText)"))
                    continue
                }
                go.append(now.copy)
                if verdict == nil { verdict = family.selection(selected) }
                shownVerdictOf[row.id] = verdict
            }
        }
        // The bar's verdict on what would actually go, per FRESH family,
        // against what the sheet said when it was confirmed.
        let goIDs = Set(go.map(\.id))
        var verdictChanged = Set<Int>()
        for copy in go {
            guard let i = freshFamilyOf[copy.id], !verdictChanged.contains(i) else { continue }
            let now = fresh.families[i].selection(goIDs)
            let then = shownVerdictOf[copy.id] ?? .empty
            if now.overrideCount > 0, now.overrideShortfalls != then.overrideShortfalls {
                verdictChanged.insert(i)
            }
        }
        if !verdictChanged.isEmpty {
            let kept = go.filter { freshFamilyOf[$0.id].map { !verdictChanged.contains($0) } ?? true }
            held += go.filter { freshFamilyOf[$0.id].map(verdictChanged.contains) ?? false }
                .map { PruneHeld(copy: $0, reason: "the bar's verdict changed since the list was shown") }
            go = kept
        }
        return (go, held)
    }

    /// One copy's on-disk safety check, as plain paths and sizes so it can
    /// run off the main actor.
    struct PruneDiskCheck: Sendable {
        let copyID: UUID
        let filename: String
        let path: String
        let size: Int64
        let archivePath: String?
        let archiveSize: Int64
        let keeperPath: String?
        let keeperSize: Int64
    }

    /// Nil when the copy may go on to its evidence checks; otherwise why
    /// not. (The archive copy's REAL check — identity and digest — is
    /// `pruneArchiveVerdict`; this is the cheap first line.)
    nonisolated static func pruneDiskProblem(_ c: PruneDiskCheck, fileManager fm: FileManager = .default) -> String? {
        func size(_ path: String) -> Int64? {
            ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value
        }
        guard let archivePath = c.archivePath else { return "its archive copy is not in the catalog" }
        guard let archived = size(archivePath) else { return "its archive copy is not on disk" }
        guard archived == c.archiveSize else { return "its archive copy is not the size the catalog recorded" }
        if let keeper = c.keeperPath {
            guard let kept = size(keeper) else { return "the working copy to keep is not on disk" }
            guard kept == c.keeperSize else { return "the working copy to keep is not the size the catalog recorded" }
        }
        // Missing is judged at the verdict ("is not on disk where the
        // catalog says"); a different size is a different file now.
        if let now = size(c.path), now != c.size { return "it changed on disk since it was cataloged" }
        return nil
    }

    // MARK: The pipeline — step 1: prepare

    /// One copy the pipeline will work through.
    struct PruneItem: Sendable, Identifiable, Equatable {
        var id: UUID { copyID }
        let copyID: UUID
        let filename: String
        let path: String
        let sizeBytes: Int64
        let kind: PrunePlan.CopyRow.Kind
        let archiveID: UUID
        let archivePath: String
        let archiveFilename: String
    }

    /// A copy `preparePrune` would not even try, with why.
    struct PruneHeldCopy: Sendable, Equatable {
        let copyID: UUID
        let filename: String
        let sizeBytes: Int64
        let reason: String
        var line: String { "\(filename) — \(reason)" }
    }

    /// The batch, ready to run.
    struct PrunePrepared {
        let fresh: PrunePlan
        let items: [PruneItem]
        let held: [PruneHeldCopy]
        static let nothing = PrunePrepared(fresh: .empty, items: [], held: [])
    }

    /// Per-batch evidence: the archive copies already proven current
    /// (their fixity, reused by every later copy — codex #6), and those
    /// that failed (every copy of theirs is held without another read).
    @MainActor
    final class PruneBatchState {
        var archiveFixityNow: [UUID: ContentFixity] = [:]
        var archiveProblem: [UUID: String] = [:]
        init() {}
    }

    /// The fresh plan, the person's checks against it, and the cheap
    /// stat checks → the copies to work through, in the order the sheet
    /// listed them, plus what is held before any byte is read.
    func preparePrune(shown: PrunePlan, selected: Set<UUID>, recordIDs: [UUID],
                      options: PrunePlan.Options) async -> PrunePrepared {
        guard !isReadOnly else {
            log("Archived — what next?: Apply refused — read-only viewer mode.")
            return .nothing
        }
        guard !selected.isEmpty else {
            log("Archived — what next?: nothing checked — nothing to move.")
            return .nothing
        }
        let fresh = await prunePlan(for: recordIDs, options: options)
        let (go, changed) = Self.pruneTargets(shown: shown, selected: selected, fresh: fresh)
        var held = changed.map { PruneHeldCopy(copyID: $0.copy.id, filename: $0.copy.filename,
                                               sizeBytes: $0.copy.sizeBytes, reason: $0.reason) }

        // Family context from the FRESH plan: the family's fixity-VERIFIED
        // archive copy (`verifiedArchive` — a version has no promote link
        // of its own, the family names it; QA MINOR 3), and the working
        // copy the plan would keep, to protect on disk — the row hinted
        // `.keeper`, NOT `family.keeper`, which is nil in a family the bar
        // does not cover (QA 2026-09-20, MAJOR 2) — unless the person
        // checked it too (then there is no keeper, and the confirmation
        // said so). Every row's kind decides its verdict path.
        let goIDs = Set(go.map(\.id))
        var keeperOf: [UUID: PrunePlan.CopyRef] = [:]
        var archiveOf: [UUID: PrunePlan.CopyRef] = [:]
        var kindOf: [UUID: PrunePlan.CopyRow.Kind] = [:]
        for family in fresh.families {
            let keeper = family.rows.first(where: { $0.planKeeps == .keeper })?.copy
            for row in family.rows where row.checkable {
                if let keeper, !goIDs.contains(keeper.id) { keeperOf[row.id] = keeper }
                if let archive = family.verifiedArchive { archiveOf[row.id] = archive }
                kindOf[row.id] = row.kind
            }
        }
        var checks: [PruneDiskCheck] = []
        var itemOf: [UUID: PruneItem] = [:]
        for copy in go {
            guard let rec = record(forID: copy.id), rec.purgedAt == nil else {
                held.append(PruneHeldCopy(copyID: copy.id, filename: copy.filename, sizeBytes: copy.sizeBytes,
                                          reason: "no longer an active catalog record"))
                continue
            }
            let archive = archiveOf[copy.id].flatMap { record(forID: $0.id) }
            let keeper = keeperOf[copy.id].flatMap { record(forID: $0.id) }
            checks.append(PruneDiskCheck(copyID: copy.id, filename: copy.filename, path: rec.fullPath,
                                         size: rec.sizeBytes, archivePath: archive?.fullPath,
                                         archiveSize: archive?.sizeBytes ?? 0,
                                         keeperPath: keeper?.fullPath, keeperSize: keeper?.sizeBytes ?? 0))
            if let archive, let kind = kindOf[copy.id] {
                itemOf[copy.id] = PruneItem(copyID: copy.id, filename: copy.filename, path: rec.fullPath,
                                            sizeBytes: rec.sizeBytes, kind: kind,
                                            archiveID: archive.id, archivePath: archive.fullPath,
                                            archiveFilename: archive.filename)
            }
        }
        let problems = await Task.detached(priority: .userInitiated) {
            checks.compactMap { c in Self.pruneDiskProblem(c).map { (c.copyID, c.filename, c.size, $0) } }
        }.value
        let refused = Set(problems.map(\.0))
        held += problems.map { PruneHeldCopy(copyID: $0.0, filename: $0.1, sizeBytes: $0.2, reason: $0.3) }
        let items = checks.compactMap { c -> PruneItem? in
            guard !refused.contains(c.copyID) else { return nil }
            return itemOf[c.copyID]
        }
        for h in held { log("Archived — what next?: held back \(h.line)") }
        return PrunePrepared(fresh: fresh, items: items, held: held)
    }

    // MARK: Step 2: one copy

    enum PruneCopyResult: Sendable, Equatable {
        case trashed(bytes: Int64)
        case held(String)
        case failed(String)
        case alreadyMissing
        case skippedOffline
    }

    struct PruneCopyOutcome: Sendable, Equatable {
        let result: PruneCopyResult
        /// The copy was read in full and matched the archive copy.
        let readInFull: Bool
        /// The archive copy was read in full for its evidence (this copy
        /// was the first of its family in the batch, and it had no stamp).
        let archiveReadInFull: Bool
        /// Human metadata was carried to the archive copy.
        let carried: Bool

        static func held(_ why: String, readInFull: Bool = false, archiveReadInFull: Bool = false) -> PruneCopyOutcome {
            PruneCopyOutcome(result: .held(why), readInFull: readInFull, archiveReadInFull: archiveReadInFull, carried: false)
        }
    }

    /// Everything that happens to ONE copy, in order: the live catalog is
    /// re-read; the archive copy's evidence is established (once per
    /// archive copy per batch) and reused; the copy's verdict is reached
    /// off-main; the person's marks are carried; the ONE Trash routine
    /// moves the file behind the proof's guard. Any doubt at any step
    /// holds the copy, named. `hooks.shouldCancel` is honoured before
    /// every read and again before the move.
    func pruneOneCopy(_ item: PruneItem, batch: PruneBatchState,
                      mode: JunkDeletionMode, hooks: PruneVerifyHooks = .live) async -> PruneCopyOutcome {
        guard let rec = record(forID: item.copyID), rec.purgedAt == nil else {
            return .held("no longer an active catalog record")
        }
        guard rec.fullPath == item.path else {
            return .held("moved in the catalog since the list was worked out")
        }
        guard let archive = record(forID: item.archiveID), archive.purgedAt == nil,
              archive.fullPath == item.archivePath else {
            return .held("its archive copy is no longer an active catalog record at the verified path")
        }
        guard let archiveFixity = archive.archiveFixity else {
            return .held("its archive copy is not fixity-verified any more")
        }
        if let why = batch.archiveProblem[archive.id] { return .held(why) }

        // ARCHIVE EVIDENCE (#2), once per archive copy per batch (#6).
        var archiveReadInFull = false
        if batch.archiveFixityNow[archive.id] == nil {
            let evidence = PruneArchiveEvidence(archiveID: archive.id, archivePath: archive.fullPath,
                                                archiveFixity: archiveFixity, contentFixity: archive.contentFixity)
            if evidence.contentFixity == nil {
                log("Archived — what next?: reading \(archive.filename) (archive copy) in full — no stamp yet…")
            }
            let verdict = await Task.detached(priority: .userInitiated) {
                Self.pruneArchiveVerdict(evidence, hooks: hooks)
            }.value
            switch verdict {
            case .current(let fixity, let readInFull):
                batch.archiveFixityNow[archive.id] = fixity
                if readInFull {
                    archiveReadInFull = true
                    storeContentFixity(recordID: archive.id, path: archive.fullPath, fixity: fixity)
                    log("Archived — what next?: \(archive.filename) (archive copy) read in full — matches its verified fixity; stamp stored")
                }
            case .problem(let why):
                // A cancel is this copy's alone; anything else is the
                // archive copy's, and holds the rest of its family unread.
                if !hooks.shouldCancel() { batch.archiveProblem[archive.id] = why }
                return .held(why)
            }
        }
        guard let archiveFixityNow = batch.archiveFixityNow[archive.id] else {
            return .held("its archive copy presented no evidence", archiveReadInFull: archiveReadInFull)
        }

        // VERDICT (#1, #3), off-main.
        let check = PruneByteCheck(copyID: item.copyID, filename: item.filename, path: item.path, kind: item.kind,
                                   archiveID: archive.id, archivePath: archive.fullPath,
                                   archiveFixity: archiveFixityNow,
                                   ownFixity: item.kind == .original ? rec.contentFixity : nil,
                                   contentKey: rec.contentHash, derivedFrom: rec.derivedFrom)
        let verdict = await Task.detached(priority: .userInitiated) {
            Self.pruneByteVerdict(check, hooks: hooks)
        }.value
        if let problem = verdict.problem {
            return .held(problem, readInFull: false, archiveReadInFull: archiveReadInFull)
        }
        guard let proof = verdict.proof else {
            return .held("no proof was produced", archiveReadInFull: archiveReadInFull)
        }
        if verdict.readInFull {
            log("Archived — what next?: \(item.filename) is byte-identical to the archive copy")
        } else if item.kind == .original {
            log("Archived — what next?: \(item.filename) is the promotion source, unchanged since Promote read it — trusted on its promotion stamp")
        }
        // The verdict-to-mutation boundary (tests act here).
        hooks.beforeMutation?(item.path)

        // Stop between the verdict and the move: a Stop that lands here
        // leaves the file (done stays done, nothing half-done).
        guard !hooks.shouldCancel() else {
            return .held("stopped before it was moved", readInFull: verdict.readInFull, archiveReadInFull: archiveReadInFull)
        }

        // Carry the person's marks (note, tags, people, stars…) to the
        // family's archive copy BEFORE the file goes — the same union rules
        // as duplicate deletion; nothing on the archive copy is ever
        // clobbered. The row is stamped purged by the Trash routine below,
        // so the carry happens while it is still live.
        var carried = false
        if archive.id != rec.id {
            let fields = applyHumanMetadataInheritance(from: rec, to: archive)
            if !fields.isEmpty {
                carried = true
                searchIndex.update(archive)
                log("Archived — what next?: carried to \(archive.filename) from \(rec.filename): " + fields.joined(separator: ", "))
            }
        }

        // The ONE existing Trash routine does the file operation — with
        // the proof re-checked at the last moment (#3): the live catalog on
        // main just before the hop, both stat stamps immediately before
        // the file's own Trash.
        let fileGuard = JunkDeletionGuard(
            authorize: { [weak self] rec in
                guard let self else { return "the catalog went away — nothing moved" }
                return self.pruneProofProblemInCatalog(proof, record: rec)
            },
            beforeRemoval: { path in
                guard path == proof.path else { return "was never verified in this batch — nothing moved" }
                return Self.pruneProofProblemOnDisk(proof)
            })
        let result = await deleteConfirmedJunk([rec], mode: mode, guard: fileGuard)
        let outcome: PruneCopyResult
        if let refused = result.refused.first {
            outcome = .held(refused.reason)
            log("Archived — what next?: held back at the last moment: \(item.filename) — \(refused.reason)")
        } else if let failure = result.failed.first {
            outcome = .failed(failure.error.localizedDescription)
        } else if result.succeeded == 1 {
            outcome = .trashed(bytes: rec.sizeBytes)
        } else if result.alreadyMissing == 1 {
            outcome = .alreadyMissing
        } else if result.skippedOffline == 1 {
            outcome = .skippedOffline
        } else {
            outcome = .held("the Trash routine did not move it")
        }
        return PruneCopyOutcome(result: outcome, readInFull: verdict.readInFull,
                                archiveReadInFull: archiveReadInFull, carried: carried)
    }

    // MARK: Step 3: finish

    /// The approval line, once, with the ACTUAL counts — "Rick approved N
    /// copies to Trash", `override` when the choice went against the bar
    /// (judged on the fresh plan, over the copies that actually went).
    /// Nothing moved → no approval. Returns the override count.
    @discardableResult
    func finishPrune(fresh: PrunePlan, trashed: [VideoRecord], batchID: String?, mode: JunkDeletionMode) -> Int {
        guard let first = trashed.first else { return 0 }
        let judged = fresh.selection(Set(trashed.map(\.id)))
        let bytes = trashed.reduce(Int64(0)) { $0 + $1.sizeBytes }
        var detail: [String: String] = [
            MediaLedgerEvent.Detail.count: String(trashed.count),
            MediaLedgerEvent.Detail.bytes: String(bytes),
            MediaLedgerEvent.Detail.files: trashed.map(\.filename).joined(separator: "\n"),
            MediaLedgerEvent.Detail.action: mode == .toTrash ? "trash" : "delete",
        ]
        if let against = judged.overrideText {
            detail[MediaLedgerEvent.Detail.barOverride] = against
            log("Archived — what next?: against the bar — \(against)")
        }
        if let only = judged.archiveOnlySentence {
            log("Archived — what next?: \(only)")
        }
        ledgerAppend([ledgerEvent(.approval, for: first, by: .rick, batchID: batchID, detail: detail)])
        return judged.overrideCount
    }

    // MARK: The three steps back to back

    /// Apply the person's checklist in one await — the pipeline above,
    /// copy after copy. `shown` is the plan the sheet listed, `selected`
    /// the copy record ids checked in it. `mode` is `.toTrash` in the app;
    /// tests pass `.permanent` so fixtures never reach the real Trash.
    /// `hooks` are the verification seams (tests count file opens and act
    /// between verdict and mutation). The sheet itself does not call this
    /// — it starts a `PruneApplyJob`, which runs the same steps as a Media
    /// File Operation.
    func applyPrune(shown: PrunePlan, selected: Set<UUID>, recordIDs: [UUID], options: PrunePlan.Options,
                    batchID: String?, mode: JunkDeletionMode = .toTrash,
                    hooks: PruneVerifyHooks = .live) async -> PruneApplyOutcome {
        var outcome = PruneApplyOutcome()
        let prepared = await preparePrune(shown: shown, selected: selected, recordIDs: recordIDs, options: options)
        outcome.held = prepared.held.map(\.line)
        guard !prepared.items.isEmpty else {
            if !selected.isEmpty, !isReadOnly { log("Archived — what next?: " + outcome.summary) }
            return outcome
        }
        let batch = PruneBatchState()
        var trashedRecords: [VideoRecord] = []
        for item in prepared.items {
            let one = await pruneOneCopy(item, batch: batch, mode: mode, hooks: hooks)
            outcome.absorb(one, item: item)
            if case .trashed = one.result, let rec = record(forID: item.copyID) { trashedRecords.append(rec) }
            if case .held(let why) = one.result { log("Archived — what next?: held back \(item.filename) — \(why)") }
        }
        outcome.overrideCount = finishPrune(fresh: prepared.fresh, trashed: trashedRecords, batchID: batchID, mode: mode)
        log("Archived — what next?: " + outcome.summary)
        return outcome
    }
}
