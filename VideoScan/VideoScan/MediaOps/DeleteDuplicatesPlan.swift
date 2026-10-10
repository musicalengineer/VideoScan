// DeleteDuplicatesPlan.swift
// Delete Duplicates — the saved plan (Rick 2026-09-20: quit + resume,
// pause, a time estimate, and something to look at).
//
// `plan.json` under App Support/VideoScan/delete-duplicates/<jobID>/ is the
// job's memory: the volume, every target (record id, path, size, keeper),
// each one's status and reason, the safety snapshot it was taken under.
// It is rewritten atomically after EVERY pair through one ordered writer,
// so a quit or a crash mid-run leaves a plan the next launch can OFFER to
// resume — never resume on its own. A finished plan moves to `done/` and
// stays there for the log; nothing here is ever deleted. A plan with a
// row whose file is STILL IN QUARANTINE (a restore that failed) is never
// filed as done and stays offerable — "N files waiting to be put back" —
// whatever its `finishedAt` says (codex 1606 #3).
//
// KEEP ONE, TRASH ONLY (Rick 2026-10-09, design triage_delete_streamline
// §9 R3/R5; supersedes the 2026-09-20 copy-count tiers): "for content with
// several verified copies, keep one proven copy and move the extras I
// selected to the Trash, exactly as I reviewed them."
//     ≥ 1 verified copy remains (the keeper, proven THIS pair: read in
//       full or its stamp-bound stored fixity, digest matched, not an
//       alias of the file going)          → TRASH       (the drive's Trash)
//     none                                → LEFT ALONE  (put back untouched)
// Nothing is ever deleted outright: Rick's daily "trash day" is the one
// permanent step. Copy COUNTS are a disposal default, not proof of
// identity: a group of three or more copies has its extras PRE-SELECTED
// (`Entry.preselected`); a group of exactly two is allowed but not
// pre-selected — a deliberate tick. The bulk run (the Storage card) acts on
// pre-selected rows only; a reviewed plan acts on exactly its rows.
// The family's other verified copies are still COUNTED (an archive copy
// only through Verify Archive Copies' stamp-bound fixity, codex 1606 #1) —
// for the row's words and the ledger, never as a condition. Plans written
// before the ruling decode with their `.permanent` rows intact (history);
// such a row is never executed as recorded (`DeleteDuplicatesDiskWorker
// .trashOnly`).
//
// A sibling with no current evidence is PROVEN by the job — read in full
// once and stamped, exactly like the keeper (2026-09-21) — and then counts
// here through its fresh fixity like any other copy. `duplicateIdentity`
// keeps a hard link of the file about to go from ever counting.
//
// THE REMOVAL BOUNDARY (codex 1611): the tier is decided, then the
// ticket save is awaited — and the copies it rests on can change in that
// window (a sibling rewritten in place, an archive copy pulled). So the
// EVIDENCE of every counted copy (record id, path, the full stamp it
// reproduced — ctime included — and the digest it was counted under)
// rides on the row, and phase two re-stats each one immediately before
// the unlink / Trash move (`DeletionTierFacts.recheck`, stat only — the
// keeper is never read). A copy whose stamp no longer reproduces, or is
// gone, is dropped and the decision re-made from what still holds — put
// back untouched only if no verified copy would remain, the row naming
// the copy that changed.
//
// Same shape as ArchiveAngelPlan (plan.json + store + ordered writer), not
// the same files: a deletion plan has no buffer, no companions, no review.
//
// (For Rick: plain Codable value types + a namespace of static functions
// for the file work. `actor` at the bottom ≈ a class with an implicit
// mutex around all members — it serialises the saves.)

import Foundation
import VideoScanCore

// MARK: - Tier (pure)

/// Where a verified duplicate goes.
enum DeletionTier: String, Codable, Sendable, Equatable {
    /// HISTORY ONLY. Rows written before 2026-10-09 recorded an outright
    /// delete this way; they still decode and display. Nothing decides it
    /// any more, and the job never executes it (Trash only).
    case permanent
    /// Moved into the volume's Trash — the space comes back when Rick
    /// empties it; the file can be put back until then.
    case trash

    var label: String {
        switch self {
        case .permanent: return "Permanent"
        case .trash: return "Trash"
        }
    }
}

/// The family's copies the job asks the disk about after the duplicate
/// has been hashed — a Sendable snapshot from the fresh catalog, taken
/// on the main actor right before the pair is dispatched.
struct DeletionTierCandidates: Sendable, Equatable {
    struct ArchiveCopy: Sendable, Equatable {
        let path: String
        /// The archive's own whole-file digest (lowercase hex) + size —
        /// the promote read-back's word, on record. Informational: it
        /// says the family HAS an archive copy of these bytes.
        let digest: String
        let sizeBytes: Int64
        /// The archive record's stamp-bound general fixity (Verify
        /// Archive Copies writes it after ITS read, stat before and
        /// after; promotion deliberately does not). ONLY this can prove
        /// the copy holds the bytes NOW (codex 1606 #1) — without it the
        /// copy is "not verified now" and does not count.
        var fixity: ContentFixity? = nil
        /// "archive copy on FamilyArchive" — for the row's reason.
        var label: String = "archive copy"
        /// The catalog record, for the evidence on the row (codex 1611).
        var recordID: UUID? = nil
    }
    struct OtherCopy: Sendable, Equatable {
        let path: String
        /// `var` so a sibling PROVEN by a read this pair (2026-09-21) can
        /// carry its fresh fixity into the ordinary gather.
        var fixity: ContentFixity?
        /// "sibling copy.mov on M4drive" — for the row's reason.
        var label: String = "sibling"
        /// The catalog record, for the evidence on the row (codex 1611).
        var recordID: UUID? = nil
        /// The catalog's size for the copy — what a sibling read costs
        /// (for the log and the run's totals). 0 when unknown.
        var sizeBytes: Int64 = 0
        /// Why a copy WITHOUT a fixity was not proven this pass, when the
        /// job knows ("offline — not counted"); nil keeps the plain
        /// "not verified yet". Words only — never evidence.
        var unverifiedNote: String? = nil
    }
    /// "keeper on LaCieWorkspace".
    var keeperLabel = "keeper"
    /// The keeper's path, so a candidate that is the SAME inode (a hard
    /// link, two spellings of one name) is never counted twice (QA #2).
    var keeperPath = ""
    /// Family members that are themselves rows of THIS run still to be
    /// decided — they may go too, so they never count (QA #3); named
    /// for the reason.
    var alsoInThisRun: [String] = []
    /// Family members THIS run leaves alone on the drive it is cleaning —
    /// in use by the Archive Angel, on a folder marked Read only, or simply
    /// not a row of the run — each already worded ("sibling h.mov on X not
    /// counted (in use by the Archive Angel)"). They are never counted:
    /// main planned such a copy as a row of the run, "still to be decided",
    /// and leaving it alone must not turn it into a new surviving copy for
    /// the others (codex #258 F1). `VideoScanModel.duplicateSurvivorStandingRule`.
    var leftAloneByRun: [String] = []
    /// Fixity-verified Master Archive copies of any family member.
    var archiveCopies: [ArchiveCopy] = []
    /// The lengths (seconds) of EVERY Master Archive copy of the family,
    /// verified or not — the Tier 1 rule's input (R4: a copy longer than
    /// an archive master is never a target; `duplicateTargetHold`).
    var archiveMasterDurations: [Double] = []
    /// Every other active family member except the keeper and the
    /// duplicate itself.
    var otherCopies: [OtherCopy] = []
    /// The keeper itself is the family's verified archive copy. It is
    /// counted once, as the keeper; this only says the archive exists.
    var keeperIsVerifiedArchive = false
    /// The DUPLICATE's own identity (device + inode are what matter),
    /// set by the worker once it has the file in hand. A candidate that
    /// is the same inode — a hard link of the file about to go — is the
    /// same bytes on the same platter, not a copy that remains
    /// (2026-09-21, sibling proving). nil = not known; nothing excluded.
    var duplicateIdentity: FileIdentityStamp? = nil
}

/// What the disk said about the candidates, once the duplicate's digest
/// was known. The keeper is counted here (it was just verified). The
/// DUPLICATE is never counted — "remaining" means after it goes.
struct DeletionTierFacts: Sendable, Equatable {
    /// One copy the count rests on, as it was when it was counted: the
    /// full stamp it reproduced (ctime included) and the digest it was
    /// counted under. Rides on the plan row (Codable) so the removal
    /// boundary — and anyone reading the plan later — can see exactly
    /// what was trusted (codex 1611). The keeper is not listed: its own
    /// identity is on the quarantine ticket and phase two checks it.
    struct CountedCopy: Codable, Sendable, Equatable {
        var recordID: UUID?
        let path: String
        let label: String
        let stamp: FileIdentityStamp
        let digest: String
        /// The drive it was counted on (`DeletionTierFacts.Drive.key`).
        /// Additive: rows written before 2026-10-03 decode nil, and the
        /// stamp's own volume identity stands in.
        var driveKey: String? = nil
    }

    /// Verified copies that remain after this deletion: keeper + archive
    /// copies and other copies whose STAMP-BOUND fixity reproduces now
    /// (ctime included) and whose digest is this one's.
    var remainingVerifiedCopies: Int = 1
    /// The keeper's entry in `counted` ("keeper on LaCieWorkspace (the
    /// archive copy)") — kept apart so `recheck` can rebuild the list.
    var keeperCounted: String = "keeper"
    /// Every copy counted besides the keeper, with the evidence it was
    /// counted on. `remainingVerifiedCopies == 1 + countedCopies.count`.
    var countedCopies: [CountedCopy] = []
    /// Set by `recheck`: the counted copies dropped at the removal
    /// boundary, with why ("sibling b.mov on M4drive changed since it
    /// was counted"). Empty when the evidence held.
    var droppedAtBoundary: [String] = []
    /// INFORMATIONAL (Rick 2026-09-20, late: "the archive is NOT
    /// required"): at least one archive copy is online with this file's
    /// size and digest ON RECORD. The detail row says "not yet archived"
    /// when false; the tier does not care — and this is NOT the count's
    /// evidence (codex 1606 #1): an archive copy counts only through
    /// its stamp-bound fixity, like any sibling.
    var hasVerifiedArchive: Bool = false
    /// Family copies that exist but could not be counted (no fixity,
    /// stamp changed, offline, or a different digest).
    var unverifiedCopies: Int = 0
    /// Who counted, in words ("keeper on LaCieWorkspace", "archive copy
    /// on FamilyArchive").
    var counted: [String] = []
    /// Who did not, and why ("sibling b.mov on M4drive not verified yet").
    var notCounted: [String] = []

    /// One drive a counted copy sits on. `key` names the PHYSICAL DEVICE
    /// (`DuplicateDrives.key(for:)`): every volume of one device — two APFS
    /// volumes of one container, two partitions of one RAID — is the same
    /// drive, and one volume spelled, linked or mounted two ways is too
    /// (codex #258 F8; "a drive is a physical device", 2026-10-03).
    struct Drive: Sendable, Equatable {
        let key: String
        /// "LaCieWorkspace" — for the reason.
        let label: String
        /// What kind of volume it is: a disk image, or one whose kind cannot
        /// be established, is never a drive of its own (codex #258 F9).
        var kind: DuplicateDrives.VolumeKind = .physical
        /// The physical device's model ("Pegasus32 R4"), when known.
        var model: String? = nil
        /// The volumes of this drive the counted copies sit on (filled as
        /// copies are counted; empty = just `label`).
        var volumes: [String] = []

        /// "LaCie" — or, with copies on several volumes of the one device,
        /// "Pegasus32 R4 [FamilyArchive, Projects]".
        var name: String {
            let on = volumes.isEmpty ? [label] : volumes
            return on.count == 1 ? on[0] : "\(model ?? "one device") [\(on.joined(separator: ", "))]"
        }
    }
    /// The keeper's drive (nil when it could not be stat'ed — then it adds
    /// no drive to the count).
    var keeperDrive: Drive?
    /// The DISTINCT drives the counted copies sit on, the keeper's first —
    /// only volumes that count as a drive (`DuplicateDrives.VolumeKind
    /// .addsADrive`: never a disk image, never an unidentified volume).
    /// Empty when unknown (facts built without a stat) — counts as one.
    var countedDrives: [Drive] = []
    /// Why a counted copy's volume did not add a drive ("a disk image is
    /// not a second drive") — for the row's reason. Empty when all did.
    var notADriveNotes: [String] = []
    /// A verified archive copy is among the COUNTED copies (or the keeper
    /// is it) — unlike `hasVerifiedArchive`, this is the count's evidence.
    var countsArchiveCopy: Bool = false
    /// Paths of the counted archive copies, so `recheck` can tell whether
    /// one still holds.
    var countedArchivePaths: Set<String> = []
    /// The keeper is itself the verified archive copy (for `recheck`).
    var keeperIsArchiveCopy: Bool = false
    /// The keeper's path — so `recheck` can ask again which drive it is on.
    var keeperPath: String = ""
    /// THE GENERATION the drive evidence was gathered under
    /// (`DuplicateDrives.generation`, read BEFORE the first lookup): every
    /// mount / unmount / rename and every run start moves it. `recheck`
    /// compares; when it has moved, which drive each copy is on is asked
    /// again from scratch (codex #258 r2-3 — evidence gathered before a
    /// mount change must not survive it). nil = the drives were given by a
    /// test seam or the facts were built by hand: never re-derived.
    var driveGeneration: UInt64?

    /// How many different drives hold the copies that would remain (≥ 1).
    var distinctDriveCount: Int { max(1, countedDrives.count) }

    /// The drive a stamp was read on — the one key per volume.
    nonisolated static func driveKey(_ stamp: FileIdentityStamp) -> String {
        DuplicateDrives.key(device: stamp.device)
    }

    /// "/Volumes/LaCie/a.mov" → "LaCie"; anything else → "this Mac".
    nonisolated static func driveLabel(forPath path: String) -> String {
        let comps = (path as NSString).pathComponents
        return comps.count >= 3 && comps[1] == "Volumes" ? comps[2] : "this Mac"
    }

    private mutating func noteDrive(_ drive: Drive) {
        guard drive.kind.addsADrive else {
            // A copy there is a copy; its volume is never the second drive.
            if let note = drive.kind.notADriveNote, !notADriveNotes.contains(note) { notADriveNotes.append(note) }
            return
        }
        if let i = countedDrives.firstIndex(where: { $0.key == drive.key }) {
            // Another volume of a device already counted: named, not added.
            if !countedDrives[i].volumes.contains(drive.label) { countedDrives[i].volumes.append(drive.label) }
            if countedDrives[i].model == nil { countedDrives[i].model = drive.model }
        } else {
            var first = drive
            if first.volumes.isEmpty { first.volumes = [first.label] }
            countedDrives.append(first)
        }
    }

    /// One more verified copy, on `drive` — used by `gather`, and by the
    /// previews (the steward's proof) that ask "what if this copy matched?".
    mutating func addCounted(drive: Drive, isArchive: Bool = false) {
        remainingVerifiedCopies += 1
        noteDrive(drive)
        if isArchive { countsArchiveCopy = true }
    }

    /// "2 verified remain: keeper on LaCieWorkspace, archive copy on
    /// FamilyArchive — on 2 drives (LaCie · Pegasus32 R4 [FamilyArchive,
    /// Projects]); sibling b.mov on M4drive not verified yet". The drives
    /// are NAMED whenever there are two or more, or one device holds the
    /// copies on several of its volumes — so the ledger shows which
    /// physical devices the count rests on.
    var summary: String {
        var text = "\(remainingVerifiedCopies) verified remain: " + counted.joined(separator: ", ")
        if remainingVerifiedCopies >= 2, !countedDrives.isEmpty {
            text += " — on \(distinctDriveCount) drive\(distinctDriveCount == 1 ? "" : "s")"
            if countedDrives.count >= 2 || countedDrives.contains(where: { $0.volumes.count > 1 }) {
                text += " (" + countedDrives.map(\.name).joined(separator: " · ") + ")"
            }
        }
        if !notCounted.isEmpty { text += "; " + notCounted.joined(separator: ", ") }
        return text
    }

    /// Stat + compare every candidate. Off the main actor (called from the
    /// disk worker); one `stat` per candidate, no reads. `digest` is the
    /// duplicate's whole-file digest — a copy only counts when it holds
    /// THESE bytes.
    /// `driveOf` names the drive a stat'ed copy sits on (test seam: two
    /// drives cannot be had inside one temp folder); production (nil) asks
    /// ONE resolver for every copy of the pass — `DuplicateDrives.Resolver`:
    /// one key per volume, and whether that volume counts as a drive.
    nonisolated static func gather(_ candidates: DeletionTierCandidates, digest: String,
                                   driveOf seam: ((_ path: String, _ stamp: FileIdentityStamp) -> Drive)? = nil) -> DeletionTierFacts {
        // Read BEFORE any lookup: a mount change during this pass leaves the
        // facts on the OLD generation, and `recheck` asks again.
        let generation = DuplicateDrives.generation
        var resolver = DuplicateDrives.Resolver()
        func driveOf(_ path: String, _ stamp: FileIdentityStamp) -> Drive {
            seam?(path, stamp) ?? resolver.drive(path: path, stamp: stamp)
        }
        var facts = DeletionTierFacts()
        facts.driveGeneration = seam == nil ? generation : nil
        facts.keeperPath = candidates.keeperPath
        let wanted = digest.lowercased()
        facts.hasVerifiedArchive = candidates.keeperIsVerifiedArchive
        facts.keeperIsArchiveCopy = candidates.keeperIsVerifiedArchive
        facts.countsArchiveCopy = candidates.keeperIsVerifiedArchive
        facts.keeperCounted = candidates.keeperLabel + (candidates.keeperIsVerifiedArchive ? " (the archive copy)" : "")
        facts.counted.append(facts.keeperCounted)
        // One inode counts once: a hard link (or a second spelling of one
        // name on a case-insensitive volume) is the same bytes on the same
        // platter, not another copy.
        var seenInodes: Set<String> = []
        func key(_ s: FileIdentityStamp) -> String { "\(s.device):\(s.inode)" }
        if !candidates.keeperPath.isEmpty, let k = FileIdentityStamp.capture(path: candidates.keeperPath) {
            seenInodes.insert(key(k))
            let drive = driveOf(candidates.keeperPath, k)
            facts.keeperDrive = drive
            facts.noteDrive(drive)
        }
        func alreadyCounted(_ stamp: FileIdentityStamp, _ label: String) -> Bool {
            if let dup = candidates.duplicateIdentity, stamp.isSameFile(as: dup) {
                facts.unverifiedCopies += 1
                facts.notCounted.append("\(label) is the same file as the duplicate (hard link) — not another copy")
                return true
            }
            guard seenInodes.contains(key(stamp)) else { seenInodes.insert(key(stamp)); return false }
            facts.unverifiedCopies += 1
            facts.notCounted.append("\(label) is the same file as one already counted (hard link)")
            return true
        }
        for archive in candidates.archiveCopies {
            guard let stamp = FileIdentityStamp.capture(path: archive.path) else {
                facts.unverifiedCopies += 1
                facts.notCounted.append("\(archive.label) offline")
                continue
            }
            guard stamp.size == archive.sizeBytes, archive.digest.lowercased() == wanted,
                  archive.fixity.map({ $0.digest == wanted }) ?? true else {
                facts.unverifiedCopies += 1
                facts.notCounted.append("\(archive.label) holds different bytes")
                continue
            }
            // On record: the family has an archive copy of these bytes.
            // Informational only — the count below needs CURRENT,
            // identity-bound evidence, exactly as a sibling does (codex
            // 1606 #1: a same-size rewrite of the archive keeps its size
            // and its digest on record; only the kernel ctime tells).
            facts.hasVerifiedArchive = true
            guard let fixity = archive.fixity, fixity.isUsableForVerification else {
                facts.unverifiedCopies += 1
                facts.notCounted.append("\(archive.label) not verified now (no stamp-bound fixity — run Verify Archive Copies)")
                continue
            }
            guard fixity.describesFileNow(stamp) else {
                facts.unverifiedCopies += 1
                facts.notCounted.append("\(archive.label) not verified now (changed since it was verified)")
                continue
            }
            if alreadyCounted(stamp, archive.label) { continue }
            let drive = driveOf(archive.path, stamp)
            facts.addCounted(drive: drive, isArchive: true)
            facts.countedArchivePaths.insert(archive.path)
            facts.counted.append(archive.label)
            facts.countedCopies.append(CountedCopy(recordID: archive.recordID, path: archive.path, label: archive.label,
                                                   stamp: stamp, digest: wanted, driveKey: drive.key))
        }
        for copy in candidates.otherCopies {
            guard let fixity = copy.fixity, fixity.isUsableForVerification else {
                facts.unverifiedCopies += 1
                facts.notCounted.append("\(copy.label) \(copy.unverifiedNote ?? "not verified yet")")
                continue
            }
            guard fixity.digest == wanted else {
                facts.unverifiedCopies += 1
                facts.notCounted.append("\(copy.label) holds different bytes")
                continue
            }
            let now = FileIdentityStamp.capture(path: copy.path)
            guard fixity.describesFileNow(now), let stamp = now else {
                facts.unverifiedCopies += 1
                facts.notCounted.append("\(copy.label) \(now == nil ? "offline" : "changed since it was verified")")
                continue
            }
            if alreadyCounted(stamp, copy.label) { continue }
            let drive = driveOf(copy.path, stamp)
            facts.addCounted(drive: drive)
            facts.counted.append(copy.label)
            facts.countedCopies.append(CountedCopy(recordID: copy.recordID, path: copy.path, label: copy.label,
                                                   stamp: stamp, digest: wanted, driveKey: drive.key))
        }
        for label in candidates.alsoInThisRun {
            facts.unverifiedCopies += 1
            facts.notCounted.append("\(label) still to be decided in this run")
        }
        for words in candidates.leftAloneByRun {
            facts.unverifiedCopies += 1
            facts.notCounted.append(words)
        }
        return facts
    }

    /// THE REMOVAL BOUNDARY (codex 1611): re-stat every counted copy and
    /// require the exact stamp it was counted on (ctime included). One
    /// that is gone, offline, or changed is dropped — named first in
    /// `notCounted` and in `droppedAtBoundary` — and the count is what
    /// still holds. Nothing is ever ADDED here: a copy that became
    /// verifiable meanwhile waits for the next run. Stat only; the
    /// keeper is not touched (phase two checks its identity itself).
    /// Returns `self` unchanged when every stamp reproduces, so an
    /// unchanged row is never rewritten.
    ///
    /// THE DRIVES are evidence too, and AT THE FINAL VERDICT NOTHING COMES
    /// FROM A CACHE (codex #258 r3-1; MOPS-2). Whatever the gather learned
    /// — it may have been served by the drive cache — the keeper and every
    /// copy that still holds are asked AGAIN, here, which physical device
    /// they are on: `DuplicateDrives.Resolver(fresh: true)`, statfs +
    /// DiskArbitration now, the cache untouched. ALWAYS, whatever the
    /// generation says (a re-enumerated disk moves no generation until its
    /// notification arrives). If the drives come out differently, that is
    /// said in `droppedAtBoundary`, and the final verdict re-decides the
    /// tier from the fresh evidence alone — in either direction. Facts
    /// whose drives were given by a test seam (or built by hand) carry no
    /// generation and are left as given. (A DIFFERENT volume now at a
    /// copy's path fails the copy's stamp — the stamp carries the volume's
    /// UUID — and the copy is dropped above.)
    nonisolated func recheck() -> DeletionTierFacts {
        var still: [CountedCopy] = []
        var dropped: [String] = []
        for copy in countedCopies {
            guard let now = FileIdentityStamp.capture(path: copy.path) else {
                dropped.append("\(copy.label) gone since it was counted (removed or offline)")
                continue
            }
            guard now == copy.stamp else {
                dropped.append("\(copy.label) changed since it was counted")
                continue
            }
            still.append(copy)
        }
        let generationNow = DuplicateDrives.generation
        let askDrivesAfresh = driveGeneration != nil
        guard !dropped.isEmpty || askDrivesAfresh else { return self }
        var out = self
        var drivesChanged: [String] = []
        if askDrivesAfresh {
            // Ask again, uncached: nothing learned earlier is trusted.
            var resolver = DuplicateDrives.Resolver(fresh: true)
            var fresh = DeletionTierFacts()
            if !keeperPath.isEmpty, let k = FileIdentityStamp.capture(path: keeperPath) {
                let drive = resolver.drive(path: keeperPath, stamp: k)
                fresh.keeperDrive = drive
                fresh.noteDrive(drive)
            }
            var rekeyed: [CountedCopy] = []
            for copy in still {
                let drive = resolver.drive(path: copy.path, stamp: copy.stamp)
                fresh.noteDrive(drive)
                rekeyed.append(CountedCopy(recordID: copy.recordID, path: copy.path, label: copy.label, stamp: copy.stamp,
                                           digest: copy.digest, driveKey: drive.key))
            }
            let stillKeys = Set(still.map { $0.driveKey ?? Self.driveKey($0.stamp) })
            let before = Set(countedDrives.filter { $0.key == keeperDrive?.key || stillKeys.contains($0.key) }.map(\.key))
            if before != Set(fresh.countedDrives.map(\.key)) {
                drivesChanged = ["the drives were asked again before removal and are not what was counted"]
            }
            still = rekeyed
            out.keeperDrive = fresh.keeperDrive
            out.countedDrives = fresh.countedDrives
            out.notADriveNotes = fresh.notADriveNotes
            out.driveGeneration = generationNow
            out.countedCopies = still
            // Same copies, same drives: nothing for the verdict to re-decide.
            if dropped.isEmpty && drivesChanged.isEmpty { return out }
        } else {
            // The drives follow what still holds: a dropped copy takes its
            // drive with it unless another copy is there.
            let stillKeys = Set(still.map { $0.driveKey ?? Self.driveKey($0.stamp) })
            out.countedDrives = countedDrives.filter { $0.key == keeperDrive?.key || stillKeys.contains($0.key) }.map { drive in
                // …and each drive names only the volumes that still hold a copy.
                var drive = drive
                var on: [String] = []
                if let keeperDrive, keeperDrive.key == drive.key { on.append(keeperDrive.label) }
                for copy in still where (copy.driveKey ?? Self.driveKey(copy.stamp)) == drive.key {
                    let volume = Self.driveLabel(forPath: copy.path)
                    if !on.contains(volume) { on.append(volume) }
                }
                if !on.isEmpty, drive.volumes.count > 1 { drive.volumes = drive.volumes.filter { on.contains($0) } }
                return drive
            }
        }
        out.countedCopies = still
        out.remainingVerifiedCopies = 1 + still.count
        // The archive exception follows what still holds.
        out.countsArchiveCopy = keeperIsArchiveCopy || still.contains { countedArchivePaths.contains($0.path) }
        out.counted = [keeperCounted] + still.map(\.label)
        out.unverifiedCopies += dropped.count
        out.notCounted = dropped + notCounted
        out.droppedAtBoundary = dropped + drivesChanged
        return out
    }
}

/// The survival rule, pure and table-testable: KEEP ONE (Rick 2026-10-09).
/// One verified copy remaining — the keeper, proven this pair — is enough
/// for the Trash; fewer leaves the file alone. Nothing is ever decided
/// `.permanent` (Trash only). Where the other copies sit, and how many
/// there are, is information for the row — not a condition.
struct DeletionTierDecision: Equatable, Sendable {
    /// nil → left alone (not removed, not refused as "not identical").
    let tier: DeletionTier?
    let remainingVerifiedCopies: Int
    let reason: String

    /// One independently verified keeper suffices (was 2 — two copies had
    /// to REMAIN, so a pair of identical files never moved; codex F5).
    static let minimumForTrash = 1

    /// The survival rule in one sentence, from the constant — every place
    /// that prints the rule quotes this.
    static var ruleSentence: String {
        "A duplicate goes to the Trash only when at least one verified copy remains — the keeper, proven "
        + "identical at the moment of the move; with none it is left alone. Nothing is ever deleted outright: "
        + "emptying the Trash is yours."
    }

    static func decide(facts: DeletionTierFacts) -> DeletionTierDecision {
        let n = facts.remainingVerifiedCopies
        let who = facts.counted.isEmpty ? "\(n) verified remain" : facts.summary
        guard n >= minimumForTrash else {
            return DeletionTierDecision(tier: nil, remainingVerifiedCopies: n,
                                        reason: "no verified copy would remain — left alone (\(who))")
        }
        return DeletionTierDecision(tier: .trash, remainingVerifiedCopies: n, reason: "to the Trash (\(who))")
    }
}

/// The words of the tier, in one place.
enum DeletionTierText {
    static let notYetArchived = "not yet archived"
    static let preferTrashToggleLabel = "Prefer the Trash for every duplicate"
    /// Since 2026-10-09 the setting changes nothing: every duplicate goes to
    /// the Trash (Trash only). The toggle stays until the Duplicates view
    /// retires it; its caption says so.
    static let preferTrashCaption = "Always the Trash now: a duplicate leaves only when its keeper is proven identical at that moment, and it goes to the drive's Trash — VideoScan never deletes outright. Emptying the Trash is yours. This setting no longer changes anything."
    /// The bulk run's hold for a row of a two-copy group (R5).
    static func inTheTrashOf(_ volume: String) -> String { "in the Trash of \(volume)" }
    /// "1 file on SanDisk is waiting to be put back from quarantine".
    static func waitingToBePutBack(_ n: Int, volume: String) -> String {
        "\(n) file\(n == 1 ? " is" : "s are") on \(volume) waiting to be put back from quarantine"
    }
    /// "SanDisk is not connected — reconnect it and choose Put Back again"
    /// (codex 1619 #2): a file still owed a put-back cannot be forgotten
    /// while the drive that holds it is away.
    static func notConnected(_ volume: String, path: String, action: String = "Put Back") -> String {
        "\(volume) is not connected — reconnect it and choose \(action) again (\(path) is not reachable)"
    }
}

struct DeleteDuplicatesPlan: Codable, Sendable, Identifiable, Equatable {

    enum EntryStatus: String, Codable, Sendable {
        case pending
        /// Being read right now.
        case verifying
        /// In quarantine; the unlink (or the move to the Trash) is in
        /// flight. Transient — a plan reloaded with a row in this state
        /// puts the file back and re-verifies it.
        case verified
        /// Gone — unlinked.
        case deleted
        /// Verified identical and moved into the volume's Trash.
        case trashed
        /// The gate said no — `note` names the keeper and why.
        case refused
        /// The unlink itself failed (or the file was retained in quarantine).
        case failed
        /// Dropped at resume, left alone by the tier, or never reached:
        /// the record left the catalog, its path or keeper changed, no
        /// verified archive copy yet, or the run was cancelled.
        case skipped

        var isSettled: Bool {
            switch self {
            case .pending, .verifying, .verified: return false
            case .deleted, .trashed, .refused, .failed, .skipped: return true
            }
        }

        /// The file left its place (deleted or trashed).
        var isRemoved: Bool { self == .deleted || self == .trashed }
    }

    struct Entry: Codable, Sendable, Identifiable, Equatable {
        /// Catalog record id of the file to delete.
        var id: UUID
        var path: String
        var filename: String
        var sizeBytes: Int64
        var keeperID: UUID
        var keeperPath: String
        var keeperFilename: String
        /// The keeper's stat stamp when the plan was made. A resume refuses
        /// the row when the keeper on disk no longer reproduces it — a
        /// keeper rewritten between sessions is named, not re-trusted.
        var keeperStamp: FileIdentityStamp?
        /// REVIEWED plans: the target's stat stamp when Rick reviewed it
        /// (codex delete-engines F4, additive 2026-10-09). With
        /// `keeperStamp` it binds the pick to the files reviewed: either
        /// one changed since → held. nil on bulk and older plans.
        var targetStamp: FileIdentityStamp?
        /// Master on another drive (the "Also clean up working copies"
        /// mode) — drives the [WORKING-COPY] log line.
        var isWorkingCopy: Bool = false
        var status: EntryStatus = .pending
        var note: String = ""
        var settledAt: Date?
        /// True when the keeper was matched by its stored fixity (not
        /// re-read) for this row. nil until verified.
        var keeperMatchedByStoredFixity: Bool?
        /// WHERE the file is while it sits in quarantine (status
        /// `.verified`): the exact owner-only folder the job moved it into,
        /// written to disk BEFORE the unlink. A crash between the move and
        /// the unlink leaves a plan that names the folder to put the file
        /// back from — recovery never guesses from a basename (codex 1593
        /// blocker 2). Cleared once the row settles.
        var quarantineDirectory: String?
        /// The file's full stat stamp (ctime included) the instant it
        /// landed in quarantine. Recovery restores only a file that still
        /// reproduces it.
        var quarantinedStamp: FileIdentityStamp?
        /// The copy-count tier decided for this row, and why (additive,
        /// 2026-09-20 evening). nil on old plans and on rows not reached.
        var tier: DeletionTier?
        var tierReason: String?
        var remainingVerifiedCopies: Int?
        /// The copies the count rests on, with the stamp and digest each
        /// was counted under (codex 1611): recorded with the tier, before
        /// the ticket save; phase two re-stats every one immediately
        /// before the unlink / Trash move. After a boundary downgrade
        /// this is what STILL held. nil on old plans and rows not reached.
        var countedCopies: [DeletionTierFacts.CountedCopy]?
        /// For `.trashed`: the volume whose Trash holds the file now.
        var trashedOnVolume: String?
        /// Informational: the family has a fixity-verified archive copy
        /// of these bytes (nil until decided). The detail row says
        /// "not yet archived" when false; the tier does not care.
        var hasVerifiedArchive: Bool?
        /// NOT COUNTABLE (codex #258 r4-1). Set — with the why — when this
        /// run planned the row as a target and then RETAINED the file
        /// because of a protection found at its turn or at its removal
        /// boundary: in use by the Archive Angel, on a drive marked Read
        /// only, the Angel's buffer unreadable, or the Master Archive rule
        /// refusing it from the designation as it was AT THE REMOVAL where
        /// the check captured at its turn had let it go. Main (8aa4acde)
        /// would have removed such a file, so it is NEVER counted as a
        /// surviving copy for another copy of this run
        /// (`runScope` → `VideoScanModel.duplicateSurvivorStandingRule`).
        /// nil for a row decided on its merits — left alone by the tier,
        /// refused as not a duplicate, refused by the archive rule main
        /// itself asked — which keeps main's treatment. Additive: rows
        /// written before it decode nil and are classified by their note.
        var notCountedWhy: String?
        /// The duplicate group the row belongs to (additive, 2026-10-09):
        /// a reviewed plan keeps ONE keeper per group across its volumes.
        var groupID: UUID?
        /// How many copies of this content the catalog knows (group members
        /// plus Master Archive copies promoted from them) when the plan was
        /// made (additive, 2026-10-09). nil on older plans.
        var groupCopyCount: Int?
        /// R6: set where the status alone cannot say it — MISSING, OFFLINE,
        /// CANCELLED, or FAILED for a skip — when the row settles. nil = the
        /// status says it (`outcome`, DeleteDuplicatesOutcome.swift).
        var outcomeKind: DeleteDuplicatesOutcomeKind?

        /// UI INFORMATION ONLY (R5 revised by Rick 2026-10-09 evening — "no
        /// per-file ticks; pairs included"): the group has three or more
        /// copies. A future Duplicates view may sort by it; it gates nothing.
        var preselected: Bool { (groupCopyCount ?? 0) >= DeleteDuplicatesPlan.preselectMinimumCopies }

        var keeperVolumeName: String { VolumeReachability.volumeName(forPath: keeperPath) }

        /// RECOVERY NEEDED (codex 1606 #3): the row is settled — refused,
        /// failed, whatever — but its file is still sitting in the
        /// quarantine folder the plan names, because a put-back failed
        /// (the original path was occupied, the move failed). Distinct
        /// from permission to delete: this row is never re-verified or
        /// removed; the only thing owed is the move back to `path`.
        /// A row still `.verified` is in flight (or crashed mid-pair) and
        /// is the resume's business, not recovery's.
        var needsRecovery: Bool { status.isSettled && quarantineDirectory != nil }

        /// Where the stranded file sits: the named folder + the original
        /// basename (the quarantine move keeps the name).
        var quarantinedFileURL: URL? {
            guard let quarantineDirectory else { return nil }
            return URL(fileURLWithPath: quarantineDirectory, isDirectory: true)
                .appendingPathComponent((path as NSString).lastPathComponent)
        }

        /// "Permanent" / "Trash of SanDisk" / "—" for the detail view,
        /// with " · not yet archived" when the family has no verified
        /// archive copy (informational only).
        var tierLabel: String {
            let base: String
            switch tier {
            case .none: base = "—"
            case .permanent: base = "Permanent"
            case .trash: base = trashedOnVolume.map { "Trash of \($0)" } ?? "Trash"
            }
            return hasVerifiedArchive == false ? base + " · \(DeletionTierText.notYetArchived)" : base
        }
    }

    var id: UUID
    var createdAt: Date
    var volumePath: String
    var volumeName: String
    /// `catalogStore.fileLocation` of the catalog the plan was made from —
    /// a plan is only ever offered to the same catalog.
    var catalogLocation: String
    var crossVolumeMode: Bool
    /// Extras on the volume that were never targets, with the reasons
    /// (already logged when the plan was made).
    var skippedBeforePlan: Int
    var summaryLine: String
    /// The pre-delete safety snapshot the cross-volume part ran under.
    var snapshotPath: String?
    var snapshotTakenAt: Date?
    var entries: [Entry]
    var startedAt: Date?
    var finishedAt: Date?
    /// Why the run ended: "completed", "cancelled", "discarded", "stopped
    /// (plan not saved)". nil while the plan is still resumable — including
    /// after a Quit or a plain Stop, which suspend the run and leave the
    /// plan in place for the resume offer (codex 1593 #5; Rick 2026-09-20
    /// evening: Stop keeps the rest for later unless he discards it).
    var outcome: String?
    var log: [String] = []
    /// How many times this plan has been resumed.
    var resumeCount: Int = 0
    /// GH #258: extra copies on the volume that were NEVER rows of this run
    /// because the Archive Angel is using them (a batch, a running
    /// Prepare) or they are promoted archive copies — each with its
    /// reason, for the detail view (at most `leftAloneListCap`; the counts
    /// below are the whole truth). Additive and optional: plans written
    /// before it decode nil, and nothing here is ever a deletion target.
    var leftAloneCopies: [LeftAloneCopy]?
    /// How many were left alone when the plan was made, by kind.
    var leftAloneAtPlan: LeftAloneCounts?
    /// R2 (2026-10-09): the plan Rick REVIEWED (Triage ▸ Duplicates) —
    /// exactly these rows run, nothing is re-planned, and a working copy
    /// needs only its keeper's eligibility (the per-copy tick is the
    /// authorization the "Also clean up working copies" toggle gives a bulk
    /// run). Additive: nil on every older plan.
    var reviewed: Bool?
    var isReviewed: Bool { reviewed == true }

    /// One copy the run never considered (GH #258).
    struct LeftAloneCopy: Codable, Sendable, Identifiable, Equatable {
        var id: UUID
        var path: String
        var filename: String
        var sizeBytes: Int64
        /// "left alone — in use by the Archive Angel"
        var reason: String
    }

    /// Copies left alone, by kind: in use by the Angel, and promoted
    /// archive copies (only while no Master Archive is designated).
    struct LeftAloneCounts: Codable, Sendable, Equatable {
        var forAngel = 0
        var archived = 0
        var total: Int { forAngel + archived }

        mutating func add(_ hold: DuplicateDeletionHold) {
            switch hold {
            case .inUseByAngel: forAngel += 1
            case .promotedArchiveCopy: archived += 1
            }
        }

        /// "2 copies left alone — in use by the Archive Angel" (and, for
        /// promoted copies with no Master Archive designated, "· 1 promoted
        /// archive copy left alone") — nil when there are none.
        var line: String? {
            var parts: [String] = []
            if forAngel > 0 { parts.append("\(forAngel) cop\(forAngel == 1 ? "y" : "ies") left alone — in use by the Archive Angel") }
            if archived > 0 { parts.append("\(archived) promoted archive cop\(archived == 1 ? "y" : "ies") left alone") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    static let leftAloneListCap = 2_000

    /// A group with at least this many copies is `preselected` (UI only).
    static let preselectMinimumCopies = 3

    /// This run's rows, as the survivor count needs them (codex #258 F1,
    /// r4-1): which are still to be decided, which the run RETAINED FOR A
    /// PROTECTION found at their turn or at their removal boundary (a hold,
    /// a Read-only mark, unreadable Angel evidence, the Master Archive rule
    /// found only at the removal — `Entry.notCountedWhy`), and which it
    /// decided on their merits. `deciding` is the row being decided now (never listed); nil
    /// for the forecast. O(entries).
    func runScope(deciding id: UUID?) -> DuplicateRunScope {
        var scope = DuplicateRunScope(volumePath: volumePath)
        for e in entries where e.id != id {
            if !e.status.isSettled {
                scope.pending.insert(e.id)
            } else if let why = e.notCountedWhy {
                // The row says so itself: retained for a protection (r4-1).
                scope.leftAlone[e.id] = why
            } else if e.status == .skipped || e.status == .refused, let why = DuplicateDeletionHold.leftAloneWhy(note: e.note) {
                // A row written before `notCountedWhy` existed: by its note.
                scope.leftAlone[e.id] = why
            } else {
                scope.decided.insert(e.id)
            }
        }
        return scope
    }

    /// Left alone when the plan was made PLUS rows the run left alone at
    /// their turn for the same reasons (the Angel's sets change mid-run).
    var leftAlone: LeftAloneCounts {
        var counts = leftAloneAtPlan ?? LeftAloneCounts()
        for entry in entries where entry.status == .skipped {
            if let hold = DuplicateDeletionHold.allCases.first(where: { $0.note == entry.note }) { counts.add(hold) }
        }
        return counts
    }

    init(id: UUID = UUID(), createdAt: Date = Date(), volumePath: String, catalogLocation: String,
         crossVolumeMode: Bool, skippedBeforePlan: Int, summaryLine: String,
         snapshotPath: String? = nil, entries: [Entry]) {
        self.id = id
        self.createdAt = createdAt
        self.volumePath = volumePath
        self.volumeName = URL(fileURLWithPath: volumePath).lastPathComponent
        self.catalogLocation = catalogLocation
        self.crossVolumeMode = crossVolumeMode
        self.skippedBeforePlan = skippedBeforePlan
        self.summaryLine = summaryLine
        self.snapshotPath = snapshotPath
        self.snapshotTakenAt = snapshotPath == nil ? nil : createdAt
        self.entries = entries
    }

    // MARK: Counts (O(entries), called from the job, never from a view body)

    struct Counts: Equatable, Sendable {
        var total = 0
        var pending = 0
        /// Unlinked — HISTORY ONLY (plans before 2026-10-09).
        var deleted = 0
        /// Moved into a Trash.
        var trashed = 0
        var refused = 0
        var failed = 0
        var skipped = 0
        var totalBytes: Int64 = 0
        /// Bytes of duplicates whose verification is over (any settled
        /// status) — the progress numerator.
        var settledBytes: Int64 = 0
        /// Bytes deleted outright — HISTORY ONLY (plans before 2026-10-09).
        var freedBytes: Int64 = 0
        /// Bytes MOVED TO THE TRASH (R7: the space comes back when Rick
        /// empties it — never called "freed").
        var trashedBytes: Int64 = 0
        /// Files that left their place, either way.
        var removed: Int { deleted + trashed }
        var settled: Int { deleted + trashed + refused + failed + skipped }
        var fraction: Double { totalBytes > 0 ? Double(settledBytes) / Double(totalBytes) : (total > 0 ? Double(settled) / Double(total) : 0) }
    }

    var counts: Counts {
        var c = Counts()
        for e in entries {
            c.total += 1
            c.totalBytes += e.sizeBytes
            switch e.status {
            case .pending, .verifying, .verified: c.pending += 1
            case .deleted: c.deleted += 1; c.settledBytes += e.sizeBytes; c.freedBytes += e.sizeBytes
            case .trashed: c.trashed += 1; c.settledBytes += e.sizeBytes; c.trashedBytes += e.sizeBytes
            case .refused: c.refused += 1; c.settledBytes += e.sizeBytes
            case .failed: c.failed += 1; c.settledBytes += e.sizeBytes
            case .skipped: c.skipped += 1; c.settledBytes += e.sizeBytes
            }
        }
        return c
    }

    /// The volumes whose Trash holds rows of this plan (usually one).
    var trashVolumes: [String] {
        Array(Set(entries.compactMap { $0.status == .trashed ? $0.trashedOnVolume : nil })).sorted()
    }

    var remainingCount: Int { entries.reduce(0) { $0 + ($1.status.isSettled ? 0 : 1) } }
    var isFinished: Bool { finishedAt != nil }
    /// A plan whose rows can be RESUMED: not finished and with rows still
    /// to do. Says nothing about stranded files — see `needsRecovery`.
    var isResumable: Bool { finishedAt == nil && remainingCount > 0 }

    /// Rows whose file is still in quarantine and owed a put-back.
    var strandedEntries: [Entry] { entries.filter(\.needsRecovery) }
    var strandedCount: Int { entries.reduce(0) { $0 + ($1.needsRecovery ? 1 : 0) } }
    /// At least one file is waiting to be put back (codex 1606 #3).
    var needsRecovery: Bool { entries.contains { $0.needsRecovery } }
    /// Worth OFFERING at launch and after a run: resumable, or with files
    /// waiting to be put back — regardless of `finishedAt` and of any
    /// deletion authority. Such a plan is never under done/.
    var isOfferable: Bool { isResumable || needsRecovery }

    /// "1 file is on SanDisk waiting to be put back from quarantine".
    var recoveryOffer: String { DeletionTierText.waitingToBePutBack(strandedCount, volume: volumeName) }

    /// "Resume deleting duplicates on SanDisk — 1,203 of 2,992 remaining?"
    /// — and, when files are stranded, that too; a plan with ONLY
    /// stranded files says just that.
    var resumeOffer: String {
        guard isResumable else { return needsRecovery ? recoveryOffer : plainResumeOffer }
        return needsRecovery ? plainResumeOffer + " " + recoveryOffer + "." : plainResumeOffer
    }

    private var plainResumeOffer: String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        let remaining = f.string(from: NSNumber(value: remainingCount)) ?? "\(remainingCount)"
        let total = f.string(from: NSNumber(value: entries.count)) ?? "\(entries.count)"
        return "Resume deleting duplicates on \(volumeName) — \(remaining) of \(total) remaining?"
    }

    mutating func set(_ id: UUID, _ status: EntryStatus, note: String = "", at now: Date = Date(),
                      keeperMatchedByStoredFixity: Bool? = nil, kind: DeleteDuplicatesOutcomeKind? = nil) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].status = status
        entries[i].outcomeKind = status.isSettled ? kind : nil
        if !note.isEmpty { entries[i].note = note }
        if status.isSettled { entries[i].settledAt = now }
        if let k = keeperMatchedByStoredFixity { entries[i].keeperMatchedByStoredFixity = k }
    }

    /// The row is in quarantine: record exactly where, and the file's
    /// stamp there, so the plan on disk can name it (status `.verified`).
    mutating func setQuarantined(_ id: UUID, directory: String, stamp: FileIdentityStamp) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].status = .verified
        entries[i].quarantineDirectory = directory
        entries[i].quarantinedStamp = stamp
    }

    /// Phase one left the file in quarantine (a failed put-back after a
    /// doubt): record the folder and — when it could be taken — the
    /// file's stamp there, WITHOUT a status change; the row is settled by
    /// the outcome and stays `needsRecovery` (QA 2026-09-21 F1). A nil
    /// stamp means the restore falls back to the planned size.
    mutating func setRetainedInQuarantine(_ id: UUID, directory: String, stamp: FileIdentityStamp?) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].quarantineDirectory = directory
        entries[i].quarantinedStamp = stamp
    }

    /// The tier decided for the row (recorded before the unlink / move),
    /// and — when given — the evidence of every copy it was counted on
    /// (codex 1611). Called again after a boundary re-check that changed
    /// the count, with the final decision and what still held.
    mutating func setTier(_ id: UUID, _ decision: DeletionTierDecision, trashVolume: String? = nil,
                          hasVerifiedArchive: Bool? = nil,
                          evidence: [DeletionTierFacts.CountedCopy]? = nil) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].tier = decision.tier
        entries[i].tierReason = decision.reason
        entries[i].remainingVerifiedCopies = decision.remainingVerifiedCopies
        entries[i].trashedOnVolume = decision.tier == .trash ? trashVolume : nil
        if let hasVerifiedArchive { entries[i].hasVerifiedArchive = hasVerifiedArchive }
        if let evidence { entries[i].countedCopies = evidence }
    }

    /// The row was retained for a protection, not on its merits: it is
    /// never counted as a surviving copy for another copy of this run
    /// (`Entry.notCountedWhy`, codex #258 r4-1).
    mutating func setNotCounted(_ id: UUID, why: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].notCountedWhy = why
    }

    /// The row left quarantine (deleted, or put back): forget the folder.
    mutating func clearQuarantine(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].quarantineDirectory = nil
        entries[i].quarantinedStamp = nil
    }

    /// A stranded row's file was put back (or found gone from the folder):
    /// forget the folder and say so on the row; the status stays what the
    /// run decided — recovery is not a verdict.
    mutating func markRecovered(_ id: UUID, note: String, at now: Date = Date()) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].quarantineDirectory = nil
        entries[i].quarantinedStamp = nil
        entries[i].note = entries[i].note.isEmpty ? note : entries[i].note + " — " + note
        entries[i].settledAt = now
        log.append(note)
    }

    /// Rows still unsettled become `skipped` with `reason` (cancel / quit),
    /// their outcome `kind` (not reached, unless the plan could not be saved).
    mutating func skipRemaining(reason: String, kind: DeleteDuplicatesOutcomeKind = .cancelled,
                                at now: Date = Date()) -> Int {
        var n = 0
        for i in entries.indices where !entries[i].status.isSettled {
            entries[i].status = .skipped
            entries[i].outcomeKind = kind
            entries[i].note = reason
            entries[i].settledAt = now
            n += 1
        }
        return n
    }

    static let planFilename = "plan.json"
}

// MARK: - Rate / ETA (pure)

/// The subtitle's numbers: throughput over the last `window` pairs and
/// the time left at that rate. No clock of its own — the job feeds it
/// (bytes, seconds, pairs in flight) per pair — so it is table-testable.
struct DeleteDuplicatesRate: Equatable, Sendable {
    struct Sample: Equatable, Sendable {
        let bytes: Int64
        let seconds: Double
    }

    static let window = 20
    /// No estimate before this many pairs — the first few include the
    /// keeper's one-time full read and would say "3 days".
    static let minimumPairsForETA = 5

    private(set) var samples: [Sample] = []
    private(set) var pairsSeen = 0

    /// `concurrency` is how many pairs shared the wall clock while this
    /// one ran (SSD: up to 2). Its seconds are divided by that, so two
    /// pairs that each took 10 s side by side count as 5 s each — the
    /// throughput the drive actually delivered.
    mutating func add(bytes: Int64, seconds: Double, concurrency: Int = 1) {
        pairsSeen += 1
        let share = max(0, seconds) / Double(max(1, concurrency))
        samples.append(Sample(bytes: bytes, seconds: share))
        if samples.count > Self.window { samples.removeFirst(samples.count - Self.window) }
    }

    /// Bytes per second over the window; nil with no samples or no time.
    var bytesPerSecond: Double? {
        let seconds = samples.reduce(0.0) { $0 + $1.seconds }
        guard !samples.isEmpty, seconds > 0 else { return nil }
        return Double(samples.reduce(Int64(0)) { $0 + $1.bytes }) / seconds
    }

    /// Seconds left for `remainingBytes`; nil before `minimumPairsForETA`
    /// pairs or without a rate.
    func secondsRemaining(remainingBytes: Int64) -> Double? {
        guard pairsSeen >= Self.minimumPairsForETA, let rate = bytesPerSecond, rate > 0 else { return nil }
        return Double(max(0, remainingBytes)) / rate
    }

    /// "1.4 GB/s" — the family-facing rate.
    static func rateText(bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    /// "about 2 h 10 min left" / "about 4 min left" / "under a minute left".
    static func etaText(seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "under a minute left" }
        let h = s / 3600
        let m = (s % 3600) / 60
        if h == 0 { return "about \(m) min left" }
        if m == 0 { return "about \(h) h left" }
        return "about \(h) h \(m) min left"
    }

    /// "800 MB moved to the Trash of SanDisk" (R7: bytes MOVED TO THE
    /// TRASH, never "freed" — the space comes back when Rick empties it),
    /// plus "1.2 GB deleted outright" only for a plan written before
    /// 2026-10-09. Empty when nothing has left its place yet.
    static func movedText(counts c: DeleteDuplicatesPlan.Counts, trashVolumes: [String]) -> String {
        var parts: [String] = []
        if c.trashedBytes > 0 {
            let moved = ByteCountFormatter.string(fromByteCount: c.trashedBytes, countStyle: .file)
            let where_ = trashVolumes.isEmpty ? "the Trash" : "the Trash of \(trashVolumes.joined(separator: ", "))"
            parts.append("\(moved) moved to \(where_)")
        }
        if c.freedBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: c.freedBytes, countStyle: .file) + " deleted outright")
        }
        return parts.joined(separator: " · ")
    }

    /// The whole subtitle: "checked 4 of 2,992 · 3 moved to the Trash ·
    /// 1 held · 1.2 GB moved to the Trash of SanDisk · 1.4 GB/s · about
    /// 2 h 10 min left". Counts first, then
    /// only the numbers that exist yet. `pausing` = the pause is requested
    /// and the file in flight is being finished; `paused` = nothing in
    /// flight, the run is holding.
    static func subtitle(counts c: DeleteDuplicatesPlan.Counts, rate: DeleteDuplicatesRate,
                         paused: Bool = false, pausing: Bool = false,
                         trashVolumes: [String] = []) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        func n(_ v: Int) -> String { f.string(from: NSNumber(value: v)) ?? "\(v)" }
        if pausing {
            return "Pausing — finishing the current file (\(n(c.settled + 1)) of \(n(c.total)))"
        }
        if paused {
            let moved = movedText(counts: c, trashVolumes: trashVolumes)
            return "Paused at \(n(c.settled)) of \(n(c.total))" + (moved.isEmpty ? "" : " · \(moved) so far")
        }
        var parts = ["checked \(n(c.settled)) of \(n(c.total))"]
        if c.trashed > 0 { parts.append("\(n(c.trashed)) moved to the Trash") }
        if c.refused + c.skipped > 0 { parts.append("\(n(c.refused + c.skipped)) held") }
        if c.failed > 0 { parts.append("\(n(c.failed)) failed") }
        if c.deleted > 0 { parts.append("\(n(c.deleted)) deleted outright") }
        let moved = movedText(counts: c, trashVolumes: trashVolumes)
        if !moved.isEmpty { parts.append(moved) }
        if let bps = rate.bytesPerSecond {
            parts.append(rateText(bytesPerSecond: bps))
            if let eta = rate.secondsRemaining(remainingBytes: c.totalBytes - c.settledBytes) {
                parts.append(etaText(seconds: eta))
            }
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Store (atomic plan.json; list; done/)

enum DeleteDuplicatesPlanStore {

    /// App Support/VideoScan/delete-duplicates — the production home.
    /// Under a test host: a per-process scratch folder (the MediaLedger /
    /// evidence-store discipline) so no test can ever read or offer Rick's
    /// real plans.
    nonisolated static var defaultRoot: URL {
        if TestEnvironment.isTestHost { return testHostRoot }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent("delete-duplicates", isDirectory: true)
    }

    nonisolated static let testHostRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("VideoScan-tests/delete-duplicates-\(ProcessInfo.processInfo.processIdentifier)",
                                isDirectory: true)

    static let doneFolder = "done"

    nonisolated static func directory(for planID: UUID, root: URL) -> URL {
        root.appendingPathComponent(planID.uuidString, isDirectory: true)
    }

    nonisolated static func planURL(for planID: UUID, root: URL) -> URL {
        directory(for: planID, root: root).appendingPathComponent(DeleteDuplicatesPlan.planFilename)
    }

    nonisolated static func doneURL(for planID: UUID, root: URL) -> URL {
        root.appendingPathComponent(doneFolder, isDirectory: true)
            .appendingPathComponent(planID.uuidString, isDirectory: true)
    }

    /// Atomic, fully synced: a forced reboot is the operational reality of
    /// this app's worst bug, and the plan is what makes a resume honest.
    nonisolated static func save(_ plan: DeleteDuplicatesPlan, root: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try AtomicFilePublish.write(try enc.encode(plan), to: planURL(for: plan.id, root: root),
                                    durability: .fullFsync)
    }

    nonisolated static func load(url: URL) throws -> DeleteDuplicatesPlan {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(DeleteDuplicatesPlan.self, from: Data(contentsOf: url))
    }

    /// Every plan under `root` (not under done/) worth offering, newest
    /// first: resumable, or with files waiting to be put back from
    /// quarantine — a finished plan with a stranded row is listed too
    /// (codex 1606 #3). Unreadable folders are named to `log` once per
    /// call and left alone.
    nonisolated static func unfinishedPlans(root: URL,
                                            log: (String) -> Void = { appLog.write($0) }) -> [DeleteDuplicatesPlan] {
        let fm = FileManager.default
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: root.path)
        } catch {
            // No root yet = no plan ever made: quiet. A root that exists but
            // can't be listed is named (reflection review F2, 2026-09-21).
            if fm.fileExists(atPath: root.path) {
                log("Delete Duplicates: plan folder \(root.path) can't be listed — \(error.localizedDescription); "
                    + "no plan offered")
            }
            return []
        }
        var plans: [DeleteDuplicatesPlan] = []
        for name in names where name != doneFolder && UUID(uuidString: name) != nil {
            let url = root.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent(DeleteDuplicatesPlan.planFilename)
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                let plan = try load(url: url)
                if plan.isOfferable { plans.append(plan) }
            } catch {
                log("Delete Duplicates: plan \(name) can't be read — \(error.localizedDescription); left in place")
            }
        }
        return plans.sorted { $0.createdAt > $1.createdAt }
    }

    /// Move `<root>/<id>` to `<root>/done/<id>` — kept for the log, never
    /// deleted. A name collision (a plan resumed twice) gets a suffix.
    nonisolated static func moveToDone(_ plan: DeleteDuplicatesPlan, root: URL) throws {
        let fm = FileManager.default
        let source = directory(for: plan.id, root: root)
        guard fm.fileExists(atPath: source.path) else { return }
        let doneRoot = root.appendingPathComponent(doneFolder, isDirectory: true)
        try fm.createDirectory(at: doneRoot, withIntermediateDirectories: true)
        var target = doneURL(for: plan.id, root: root)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = doneRoot.appendingPathComponent("\(plan.id.uuidString)-\(n)", isDirectory: true)
            n += 1
        }
        try fm.moveItem(at: source, to: target)
    }
}

/// The ONE writer of a plan's plan.json (the ArchiveAngelPlanWriter shape):
/// each save carries a generation taken on the main actor when requested;
/// writes land in arrival order and a save older than the last one written
/// for that plan is dropped — the newer save already holds its change.
/// With two pairs in flight the job still takes generations on the main
/// actor in order, so the newest plan always wins.
actor DeleteDuplicatesPlanWriter {
    static let shared = DeleteDuplicatesPlanWriter()
    private var written: [UUID: UInt64] = [:]

    /// The last generation written for `planID` in this process (0 when
    /// none). A job that resumes a plan in the SAME process seeds its
    /// counter from this, so its saves are never dropped as stale (QA
    /// MINOR 4 on 462b034b).
    func lastGeneration(for planID: UUID) -> UInt64 { written[planID] ?? 0 }

    @discardableResult
    func write(_ plan: DeleteDuplicatesPlan, root: URL, generation: UInt64) throws -> Bool {
        if let last = written[plan.id], last >= generation { return false }
        try DeleteDuplicatesPlanStore.save(plan, root: root)
        written[plan.id] = generation
        return true
    }
}
