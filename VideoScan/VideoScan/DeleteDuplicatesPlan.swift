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
// COPY-COUNT TIERING (Rick 2026-09-20 evening): each row is decided at
// deletion time from the fresh catalog by how many VERIFIED copies of the
// family remain after it goes — the keeper just verified, and any other
// online copy (archive copy or sibling alike) whose STAMP-BOUND stored
// fixity reproduces on a fresh stat, ctime included, and whose digest is
// this one's. An archive copy's promote-time digest alone is a record,
// not current evidence: a same-size rewrite of the archive leaves size
// and digest-on-record intact (codex 1606 #1), so only Verify Archive
// Copies' stamp-bound fixity lets it count:
//     ≥ 3 remaining → PERMANENT   (space back now)
//     = 2 remaining → TRASH       (to the volume's Trash, not gone)
//     < 2 remaining → LEFT ALONE  (put back untouched)
// Purely the count — the archive is NOT required (Rick, late 2026-09-20:
// "the low-hanging fruit is a file with ten copies regardless of
// promotion"); an archive copy counts like any verified copy, and the
// row says "not yet archived" for information only. "Prefer the Trash
// for every duplicate" (Settings) forces TRASH for all tiers. The tier,
// its reason (who counted, who did not and why) and the count are on the
// row; the ledger line carries them too. Old plans decode with
// `tier == nil` and are decided afresh.
//
// THE REMOVAL BOUNDARY (codex 1611): the tier is decided, then the
// ticket save is awaited — and the copies it rests on can change in that
// window (a sibling rewritten in place, an archive copy pulled). So the
// EVIDENCE of every counted copy (record id, path, the full stamp it
// reproduced — ctime included — and the digest it was counted under)
// rides on the row, and phase two re-stats each one immediately before
// the unlink / Trash move (`DeletionTierFacts.recheck`, stat only — the
// keeper is never read). A copy whose stamp no longer reproduces, or is
// gone, is dropped and the tier re-decided from what still holds:
// permanent → Trash when the count falls to two; put back untouched when
// it falls below two, the row naming the copy that changed.
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
    /// Unlinked — the space is back now.
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
        let fixity: ContentFixity?
        /// "sibling copy.mov on M4drive" — for the row's reason.
        var label: String = "sibling"
        /// The catalog record, for the evidence on the row (codex 1611).
        var recordID: UUID? = nil
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
    /// Fixity-verified Master Archive copies of any family member.
    var archiveCopies: [ArchiveCopy] = []
    /// Every other active family member except the keeper and the
    /// duplicate itself.
    var otherCopies: [OtherCopy] = []
    /// The keeper itself is the family's verified archive copy. It is
    /// counted once, as the keeper; this only says the archive exists.
    var keeperIsVerifiedArchive = false
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

    /// "2 verified remain: keeper on LaCieWorkspace, archive copy on
    /// FamilyArchive; sibling b.mov on M4drive not verified yet".
    var summary: String {
        var text = "\(remainingVerifiedCopies) verified remain: " + counted.joined(separator: ", ")
        if !notCounted.isEmpty { text += "; " + notCounted.joined(separator: ", ") }
        return text
    }

    /// Stat + compare every candidate. Off the main actor (called from the
    /// disk worker); one `stat` per candidate, no reads. `digest` is the
    /// duplicate's whole-file digest — a copy only counts when it holds
    /// THESE bytes.
    nonisolated static func gather(_ candidates: DeletionTierCandidates, digest: String) -> DeletionTierFacts {
        var facts = DeletionTierFacts()
        let wanted = digest.lowercased()
        facts.hasVerifiedArchive = candidates.keeperIsVerifiedArchive
        facts.keeperCounted = candidates.keeperLabel + (candidates.keeperIsVerifiedArchive ? " (the archive copy)" : "")
        facts.counted.append(facts.keeperCounted)
        // One inode counts once: a hard link (or a second spelling of one
        // name on a case-insensitive volume) is the same bytes on the same
        // platter, not another copy.
        var seenInodes: Set<String> = []
        func key(_ s: FileIdentityStamp) -> String { "\(s.device):\(s.inode)" }
        if !candidates.keeperPath.isEmpty, let k = FileIdentityStamp.capture(path: candidates.keeperPath) {
            seenInodes.insert(key(k))
        }
        func alreadyCounted(_ stamp: FileIdentityStamp, _ label: String) -> Bool {
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
            facts.remainingVerifiedCopies += 1
            facts.counted.append(archive.label)
            facts.countedCopies.append(CountedCopy(recordID: archive.recordID, path: archive.path, label: archive.label,
                                                   stamp: stamp, digest: wanted))
        }
        for copy in candidates.otherCopies {
            guard let fixity = copy.fixity, fixity.isUsableForVerification else {
                facts.unverifiedCopies += 1
                facts.notCounted.append("\(copy.label) not verified yet")
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
            facts.remainingVerifiedCopies += 1
            facts.counted.append(copy.label)
            facts.countedCopies.append(CountedCopy(recordID: copy.recordID, path: copy.path, label: copy.label,
                                                   stamp: stamp, digest: wanted))
        }
        for label in candidates.alsoInThisRun {
            facts.unverifiedCopies += 1
            facts.notCounted.append("\(label) still to be decided in this run")
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
        guard !dropped.isEmpty else { return self }
        var out = self
        out.countedCopies = still
        out.remainingVerifiedCopies = 1 + still.count
        out.counted = [keeperCounted] + still.map(\.label)
        out.unverifiedCopies += dropped.count
        out.notCounted = dropped + notCounted
        out.droppedAtBoundary = dropped
        return out
    }
}

/// The tier rule, pure and table-testable. Purely the COUNT (Rick
/// 2026-09-20, late): the archive is not required — "the low-hanging
/// fruit is a file with ten copies regardless of promotion".
struct DeletionTierDecision: Equatable, Sendable {
    /// nil → left alone (not deleted, not refused as "not identical").
    let tier: DeletionTier?
    let remainingVerifiedCopies: Int
    let reason: String

    static let minimumForTrash = 2
    static let minimumForPermanent = 3

    static func decide(facts: DeletionTierFacts, preferTrash: Bool) -> DeletionTierDecision {
        let n = facts.remainingVerifiedCopies
        let who = facts.counted.isEmpty ? "\(n) verified remain" : facts.summary
        guard n >= minimumForTrash else {
            return DeletionTierDecision(tier: nil, remainingVerifiedCopies: n,
                                        reason: "only \(n) verified cop\(n == 1 ? "y" : "ies") would remain — left alone (\(who))")
        }
        if preferTrash {
            return DeletionTierDecision(tier: .trash, remainingVerifiedCopies: n,
                                        reason: "to the Trash by your setting (\(who))")
        }
        if n >= minimumForPermanent {
            return DeletionTierDecision(tier: .permanent, remainingVerifiedCopies: n,
                                        reason: "space back now (\(who))")
        }
        return DeletionTierDecision(tier: .trash, remainingVerifiedCopies: n,
                                    reason: "only two verified copies would remain — to the Trash, not gone (\(who))")
    }
}

/// The words of the tier, in one place.
enum DeletionTierText {
    static let notYetArchived = "not yet archived"
    static let preferTrashToggleLabel = "Prefer the Trash for every duplicate"
    static let preferTrashCaption = "Off: a duplicate with three or more verified copies left behind (the keeper, an archive copy, siblings whose stored fixity still reproduces) is deleted outright; with exactly two left, it goes to the drive's Trash instead; with fewer, it is left alone. On: every duplicate goes to the Trash, whatever the count. An archive copy counts but is not required."
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
        /// Unlinked (permanent).
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
        /// Bytes back NOW (permanent deletions only).
        var freedBytes: Int64 = 0
        /// Bytes waiting in a Trash.
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
                      keeperMatchedByStoredFixity: Bool? = nil) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].status = status
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

    /// Rows still unsettled become `skipped` with `reason` (cancel / quit).
    mutating func skipRemaining(reason: String, at now: Date = Date()) -> Int {
        var n = 0
        for i in entries.indices where !entries[i].status.isSettled {
            entries[i].status = .skipped
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

    /// "1.2 GB freed now · 800 MB waiting in the Trash of SanDisk" — or
    /// just "1.2 GB freed" when nothing went to a Trash. Empty when
    /// nothing has left the disk yet.
    static func freedText(counts c: DeleteDuplicatesPlan.Counts, trashVolumes: [String]) -> String {
        var parts: [String] = []
        let freed = ByteCountFormatter.string(fromByteCount: c.freedBytes, countStyle: .file)
        if c.trashedBytes > 0 {
            let waiting = ByteCountFormatter.string(fromByteCount: c.trashedBytes, countStyle: .file)
            if c.freedBytes > 0 { parts.append("\(freed) freed now") }
            let where_ = trashVolumes.isEmpty ? "the Trash" : "the Trash of \(trashVolumes.joined(separator: ", "))"
            parts.append("\(waiting) waiting in \(where_)")
        } else if c.freedBytes > 0 {
            parts.append("\(freed) freed")
        }
        return parts.joined(separator: " · ")
    }

    /// The whole subtitle: "verified 2 of 2,992 · 3 deleted · 1 to the
    /// Trash · 1 refused · 1.2 GB freed now · 800 MB waiting in the Trash
    /// of SanDisk · 1.4 GB/s · about 2 h 10 min left". Counts first, then
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
            let freed = freedText(counts: c, trashVolumes: trashVolumes)
            return "Paused at \(n(c.settled)) of \(n(c.total))" + (freed.isEmpty ? "" : " · \(freed) so far")
        }
        var parts = ["verified \(n(c.settled)) of \(n(c.total))"]
        if c.deleted > 0 { parts.append("\(n(c.deleted)) deleted") }
        if c.trashed > 0 { parts.append("\(n(c.trashed)) to the Trash") }
        if c.refused > 0 { parts.append("\(n(c.refused)) refused") }
        if c.failed > 0 { parts.append("\(n(c.failed)) failed") }
        let freed = freedText(counts: c, trashVolumes: trashVolumes)
        if !freed.isEmpty { parts.append(freed) }
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
