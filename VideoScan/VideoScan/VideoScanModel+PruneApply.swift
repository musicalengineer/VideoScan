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
// This is a DELETE path, so like ⌘⌫ (VideoScanModel+TrashSelection) it
// adds NO file-deletion code of its own. It is a plan in front of the ONE
// existing Trash routine, `deleteConfirmedJunk(_:mode:)`, which already
// leaves Master Archive files alone, skips offline drives, stamps
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
//   2. ON-DISK SAFETY, per copy, just before it goes: the family's
//      fixity-VERIFIED archive copy exists at its recorded size; the
//      working copy the plan would keep (the row hinted `.keeper`, if NOT
//      itself checked) exists at its recorded size; the copy itself is
//      still its recorded size (a file rewritten in place is a different
//      file). Any failure holds the copy, with the reason.
//   3. BYTE-FOR-BYTE, for every `.duplicate` row about to go (QA
//      2026-09-20 MAJOR 2): a duplicate CLAIMS byte identity with the
//      archive copy, and a segmented-hash match — which is how "Hash to
//      confirm" makes a join — is a candidate, never proof
//      (SignatureVerification's contract). So the file is read in full
//      against the archive copy's stored whole-file fixity, or against a
//      full read of the archive copy when there is none
//      (`SignatureVerification.verifyAgainstStoredKeeper`), off-main; a
//      mismatch holds it, named: "not the same bytes as the archive copy".
//      A fresh archive-copy fixity is stored so the next duplicate is
//      verified one-sided. Versions go on provenance alone — that IS the
//      ruling; they never claimed identical bytes.
//   4. An `approval` ledger line: "Rick approved N copies to Trash" — with
//      `override` when the choice went against the bar ("2 copies — ★★★ /
//      Important — no cloud or off-site copy attested").
// The PrunePlan rules themselves (fixity-verified archive copy, online,
// not a pair member, never inside the archive) are PrunePlan.compute's,
// unchanged. Unchecked copies are NEVER moved, even when the plan's
// default would have trashed them: the selection is the truth.
//
// Memory: O(copies in the batch's families). Disk checks are stat calls
// off the main actor; no file content is read.

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
        /// Duplicates read in full and found byte-identical to the archive copy.
        var verified = 0
        /// "filename — reason" for copies Apply would not touch.
        var held: [String] = []
        /// "filename — error" for copies the Trash routine could not move.
        var failed: [String] = []

        var summary: String {
            var parts = ["Moved \(trashed) cop\(trashed == 1 ? "y" : "ies") to the Trash (\(MediaBytes.display(trashedBytes)))"]
            if overrideCount > 0 { parts.append("\(overrideCount) against the bar you set") }
            if verified > 0 { parts.append("\(verified) checked byte-for-byte against the archive") }
            if carried > 0 { parts.append("notes and marks from \(carried) carried to the archive copy") }
            if alreadyMissing > 0 { parts.append("\(alreadyMissing) already gone") }
            if skippedOffline > 0 { parts.append("\(skippedOffline) on a drive that isn't connected") }
            if !held.isEmpty { parts.append("\(held.count) held back — changed since the list was shown") }
            if !failed.isEmpty { parts.append("\(failed.count) could not be moved") }
            return parts.joined(separator: " · ")
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

    /// Nil when the copy may go; otherwise why not.
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
        // Missing is the Trash routine's "already gone"; a different size
        // is a different file now.
        if let now = size(c.path), now != c.size { return "it changed on disk since it was cataloged" }
        return nil
    }

    /// One duplicate's byte-for-byte check, as plain values so it runs off
    /// the main actor. `archiveFixity` is the archive copy's stored
    /// whole-file fixity (nil → both files are read once).
    struct PruneByteCheck: Sendable {
        let copyID: UUID
        let filename: String
        let path: String
        let archiveID: UUID
        let archivePath: String
        let archiveFixity: ContentFixity?
        /// For the promotion ORIGINAL: the archive copy's read-back time.
        /// The promote read it in full and the archive copy's fixity is
        /// its digest, so it is trusted UNLESS a fresh stat shows it was
        /// written (mtime or ctime) after that moment — then it is read
        /// in full like any duplicate. nil = always read (a duplicate).
        let trustedUntil: Date?
    }

    /// The outcome of one byte check: nil = identical; otherwise why the
    /// copy is held. `freshArchiveFixity` is set when the archive copy was
    /// read in full (stored on its record so the next duplicate is
    /// verified one-sided).
    struct PruneByteVerdict: Sendable {
        let copyID: UUID
        let problem: String?
        let freshArchiveFixity: ContentFixity?
        /// The file was read in full (false = a trusted original).
        let readInFull: Bool
    }

    /// Read the duplicate in full against the archive copy. Never on the
    /// main actor (whole-file reads).
    nonisolated static func pruneByteVerdict(_ c: PruneByteCheck,
                                             hooks: SignatureVerification.Hooks = .live) -> PruneByteVerdict {
        if let trusted = c.trustedUntil {
            guard let stamp = FileIdentityStamp.capture(path: c.path) else {
                return PruneByteVerdict(copyID: c.copyID, problem: "could not be read in full (\((c.path as NSString).lastPathComponent))",
                                        freshArchiveFixity: nil, readInFull: false)
            }
            let limitNs = Int64(trusted.timeIntervalSince1970 * 1_000_000_000)
            if stamp.mtimeNs <= limitNs, stamp.ctimeNs <= limitNs {
                return PruneByteVerdict(copyID: c.copyID, problem: nil, freshArchiveFixity: nil, readInFull: false)
            }
            // Written after the archive copy was verified: it is a different
            // file until proven otherwise — read it like any duplicate.
        }
        switch SignatureVerification.verifyAgainstStoredKeeper(keeperPath: c.archivePath,
                                                               keeperFixity: c.archiveFixity,
                                                               duplicatePath: c.path, hooks: hooks) {
        case .success(let proof):
            return PruneByteVerdict(copyID: c.copyID, problem: nil,
                                    freshArchiveFixity: proof.keeperReadInFull ? proof.keeperFixity : nil,
                                    readInFull: true)
        case .failure(let failure):
            let why: String
            switch failure {
            case .contentDiffers:               why = "not the same bytes as the archive copy"
            case .samePath:                     why = "it IS the archive copy's file (same inode)"
            case .unreadable(let path):         why = "could not be read in full (\((path as NSString).lastPathComponent))"
            case .changedSinceVerification:     why = "changed while it was being checked against the archive copy"
            case .cancelled:                    why = "the check was cancelled"
            }
            return PruneByteVerdict(copyID: c.copyID, problem: why, freshArchiveFixity: nil, readInFull: true)
        }
    }

    /// Apply the person's checklist. `shown` is the plan the sheet listed,
    /// `selected` the copy record ids checked in it. `mode` is always
    /// `.toTrash` from the sheet; tests pass `.permanent` so fixtures never
    /// reach the real Trash.
    func applyPrune(shown: PrunePlan, selected: Set<UUID>, recordIDs: [UUID], options: PrunePlan.Options,
                    batchID: String?, mode: JunkDeletionMode = .toTrash) async -> PruneApplyOutcome {
        var outcome = PruneApplyOutcome()
        guard !isReadOnly else {
            log("Archived — what next?: Apply refused — read-only viewer mode.")
            return outcome
        }
        guard !selected.isEmpty else {
            log("Archived — what next?: nothing checked — nothing to move.")
            return outcome
        }
        let fresh = await prunePlan(for: recordIDs, options: options)
        let (go, changed) = Self.pruneTargets(shown: shown, selected: selected, fresh: fresh)
        outcome.held = changed.map(\.line)

        // Family context from the FRESH plan: the family's fixity-VERIFIED
        // archive copy (`verifiedArchive` — a version has no promote link
        // of its own, the family names it; QA MINOR 3), and the working
        // copy the plan would keep, to protect on disk — the row hinted
        // `.keeper`, NOT `family.keeper`, which is nil in a family the bar
        // does not cover (QA 2026-09-20, MAJOR 2) — unless the person
        // checked it too (then there is no keeper, and the confirmation
        // said so). Duplicate rows are remembered for the byte check.
        let goIDs = Set(go.map(\.id))
        var keeperOf: [UUID: PrunePlan.CopyRef] = [:]
        var archiveOf: [UUID: PrunePlan.CopyRef] = [:]
        // Rows that CLAIM identical bytes with the archive copy: a
        // duplicate (always read in full) and the promotion original
        // (read in full only if written since the archive copy's
        // read-back — see PruneByteCheck.trustedUntil). Versions never
        // claimed it.
        var claimsIdentity: [UUID: PrunePlan.CopyRow.Kind] = [:]
        for family in fresh.families {
            let keeper = family.rows.first(where: { $0.planKeeps == .keeper })?.copy
            for row in family.rows where row.checkable {
                if let keeper, !goIDs.contains(keeper.id) { keeperOf[row.id] = keeper }
                if let archive = family.verifiedArchive { archiveOf[row.id] = archive }
                if row.kind == .duplicate || row.kind == .original { claimsIdentity[row.id] = row.kind }
            }
        }
        var checks: [PruneDiskCheck] = []
        var recordsByID: [UUID: VideoRecord] = [:]
        var archiveRecordOf: [UUID: VideoRecord] = [:]
        for copy in go {
            guard let rec = record(forID: copy.id), rec.purgedAt == nil else {
                outcome.held.append("\(copy.filename) — no longer an active catalog record")
                continue
            }
            recordsByID[copy.id] = rec
            let archive = archiveOf[copy.id].flatMap { record(forID: $0.id) }
            if let archive { archiveRecordOf[copy.id] = archive }
            let keeper = keeperOf[copy.id].flatMap { record(forID: $0.id) }
            checks.append(PruneDiskCheck(copyID: copy.id, filename: copy.filename, path: rec.fullPath,
                                         size: rec.sizeBytes, archivePath: archive?.fullPath,
                                         archiveSize: archive?.sizeBytes ?? 0,
                                         keeperPath: keeper?.fullPath, keeperSize: keeper?.sizeBytes ?? 0))
        }
        let problems = await Task.detached(priority: .userInitiated) {
            checks.compactMap { c in Self.pruneDiskProblem(c).map { (c.copyID, c.filename, $0) } }
        }.value
        var refused = Set(problems.map(\.0))
        outcome.held += problems.map { "\($0.1) — \($0.2)" }

        // Byte-for-byte for every duplicate that passed the stat checks:
        // read in full against the archive copy, off-main, one file at a
        // time (streaming digests — no file is held in memory).
        let byteChecks: [PruneByteCheck] = checks.compactMap { c in
            guard !refused.contains(c.copyID), let kind = claimsIdentity[c.copyID],
                  let archive = archiveRecordOf[c.copyID] else { return nil }
            return PruneByteCheck(copyID: c.copyID, filename: c.filename, path: c.path,
                                  archiveID: archive.id, archivePath: archive.fullPath,
                                  archiveFixity: archive.contentFixity,
                                  trustedUntil: kind == .original ? archive.archiveFixity?.verifiedAt : nil)
        }
        if !byteChecks.isEmpty {
            let dups = byteChecks.filter { $0.trustedUntil == nil }.count
            log("Archived — what next?: checking \(dups) duplicate\(dups == 1 ? "" : "s") byte-for-byte against the archive"
                + (byteChecks.count > dups ? " (+ \(byteChecks.count - dups) original\(byteChecks.count - dups == 1 ? "" : "s") by stamp)" : "") + "…")
            let verdicts = await Task.detached(priority: .userInitiated) {
                byteChecks.map { Self.pruneByteVerdict($0) }
            }.value
            let names = Dictionary(uniqueKeysWithValues: byteChecks.map { ($0.copyID, $0) })
            for v in verdicts {
                guard let check = names[v.copyID] else { continue }
                if let problem = v.problem {
                    refused.insert(v.copyID)
                    outcome.held.append("\(check.filename) — \(problem)")
                } else if v.readInFull {
                    outcome.verified += 1
                    log("Archived — what next?: \(check.filename) is byte-identical to the archive copy")
                    if let fresh = v.freshArchiveFixity {
                        storeContentFixity(recordID: check.archiveID, path: check.archivePath, fixity: fresh)
                    }
                } else {
                    log("Archived — what next?: \(check.filename) is the promotion source, unchanged since the archive copy read back — trusted")
                }
            }
        }
        let targets = checks.filter { !refused.contains($0.copyID) }.compactMap { recordsByID[$0.copyID] }

        for line in outcome.held { log("Archived — what next?: held back \(line)") }
        guard !targets.isEmpty else {
            log("Archived — what next?: " + outcome.summary)
            return outcome
        }
        // The approval, before the files move: what Rick said yes to, and
        // whether it went against the bar (judged on the FRESH plan, over
        // the copies that actually go).
        let judged = fresh.selection(Set(targets.map(\.id)))
        outcome.overrideCount = judged.overrideCount
        let bytes = targets.reduce(Int64(0)) { $0 + $1.sizeBytes }
        var detail: [String: String] = [
            MediaLedgerEvent.Detail.count: String(targets.count),
            MediaLedgerEvent.Detail.bytes: String(bytes),
            MediaLedgerEvent.Detail.files: targets.map(\.filename).joined(separator: "\n"),
            MediaLedgerEvent.Detail.action: mode == .toTrash ? "trash" : "delete",
        ]
        if let against = judged.overrideText {
            detail[MediaLedgerEvent.Detail.barOverride] = against
            log("Archived — what next?: against the bar — \(against)")
        }
        if let only = judged.archiveOnlySentence {
            log("Archived — what next?: \(only)")
        }
        ledgerAppend([ledgerEvent(.approval, for: targets[0], by: .rick, batchID: batchID, detail: detail)])

        // Carry the person's marks (note, tags, people, stars…) from each
        // copy to the family's archive copy BEFORE the file goes — the same
        // union rules as duplicate deletion; nothing on the archive copy is
        // ever clobbered. The row is stamped purged by the Trash routine
        // below, so the carry happens while it is still live.
        for rec in targets {
            guard let archive = archiveRecordOf[rec.id], archive.id != rec.id else { continue }
            let carried = applyHumanMetadataInheritance(from: rec, to: archive)
            guard !carried.isEmpty else { continue }
            outcome.carried += 1
            searchIndex.update(archive)
            log("Archived — what next?: carried to \(archive.filename) from \(rec.filename): " + carried.joined(separator: ", "))
        }

        // The ONE existing Trash routine does every file operation.
        let result = await deleteConfirmedJunk(targets, mode: mode)
        let failedIDs = Set(result.failed.map { $0.record.id })
        outcome.trashed = result.succeeded
        outcome.trashedBytes = targets.filter { !failedIDs.contains($0.id) && $0.purgedAt != nil }
            .reduce(0) { $0 + $1.sizeBytes }
        outcome.alreadyMissing = result.alreadyMissing
        outcome.skippedOffline = result.skippedOffline
        outcome.failed = result.failed.map { "\($0.record.filename) — \($0.error.localizedDescription)" }
        log("Archived — what next?: " + outcome.summary)
        return outcome
    }
}
