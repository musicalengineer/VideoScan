// SignatureVerification.swift
// The gate every destructive duplicate action must pass through.
//
// WHY THIS TYPE EXISTS. `segmentedHash` samples three 1 MiB windows out
// of files that reach 12 GB. It is excellent at saying "these are
// DIFFERENT" and incapable of saying "these are the SAME" — two files
// sharing a size and all three windows can still differ across the
// ~11.997 GB nobody read. I originally documented the segmented hash as
// "identity strong enough to delete on", which was false, and codex
// caught it before any delete feature shipped (#320).
//
// The fix is not more words in a comment. A rule that lives only in
// documentation gets forgotten by whoever writes the dedup UI in three
// weeks — possibly me. So the rule is a TYPE: to delete a duplicate you
// must hold a `VerifiedDuplicate`, and the only way to obtain one is to
// have compared every byte of the file about to be deleted against a
// whole-file digest of its keeper.
//
//     segmented hash equal   → CANDIDATE      (cheap, fleet-wide)
//     full hash equal        → VerifiedDuplicate (expensive, per pair)
//
// THREE WAYS TO EARN THE PROOF:
//
//   1. `verify(keeperPath:duplicatePath:)` — the original two-file path.
//      Both sides are read in full and hashed fresh. Used ONCE per keeper,
//      the first time it is met without a stored fixity; the proof carries
//      the keeper's fresh fixity for the caller to store.
//   2. `verifyAgainstStoredKeeper(...)` — the keeper is NOT read. Its
//      stored `ContentFixity` (whole-file digest + stat stamp from the
//      one time it was read) must reproduce under a fresh `stat`; then
//      only the DUPLICATE is read in full, at its public path, and its
//      digest compared. Kept for callers without a plan; the job no
//      longer uses it (see 3).
//   3. SINGLE READ — `holdForSingleRead` + `verifyHeld` (Rick 2026-09-20
//      evening: "implement the single-read design"). Until then a deleted
//      file was read TWICE: once to verify it at its public path, once
//      more after the move into quarantine (codex 1593 blocker 1 — a
//      same-length rewrite through an open descriptor between the two
//      could not otherwise be seen). Reordered, one read suffices: the
//      duplicate is MOVED FIRST into its owner-only quarantine folder,
//      its full identity (ctime included) is captured there as the
//      baseline, and THEN it is hashed once in full in quarantine. A
//      write before the move is in the bytes hashed; a write after the
//      baseline changes the kernel ctime and is refused by the re-stat.
//      The keeper is never read — its stored fixity must reproduce at the
//      hold and again after the hash. Net: one full read of the file that
//      goes, zero of the file that stays.
//
// THE DELETE ITSELF IS TWO STEPS (codex review 1593, blocker 1):
//
//   a. `quarantine(proof)` (paths 1 and 2) or `holdForSingleRead` (path 3)
//      — the directory entry is renamed into a fresh owner-only sibling
//      directory, and its FULL identity (device, inode, size, mtime AND
//      kernel ctime) is captured immediately after the rename. That stamp
//      is the baseline every later check compares to.
//   b. `deleteQuarantined(ticket, disposal:)` — unless the ticket says the
//      file was already hashed in quarantine (path 3), the quarantined
//      file is read in full again and its digest must equal the proof's;
//      then the baseline must reproduce to the ctime, the keeper must be
//      unchanged, the original pathname must still be empty; only then is
//      it unlinked — or, with `.trash`, moved into the volume's Trash
//      (the copy-count tier's cautious rung: "exactly the archive copy
//      and the keeper remain → the Trash, not gone").
//
//   The two steps exist as separate calls so the job can WRITE the
//   quarantine location into its plan between them — a crash between the
//   move and the unlink then leaves a plan that names the exact folder to
//   put the file back from (blocker 2). `quarantineAndDelete` composes
//   them for callers that have no plan.
//
// Either way the file that gets deleted is read end to end at the moment
// of deletion. Nothing stored — not `contentHash`, not `partialMD5`, not
// a fixity — ever authorises a delete on its own.

import Foundation
import Darwin
import CryptoKit
import VideoScanCore

/// Proof that two paths hold byte-identical content.
///
/// Deliberately has no public initializer: the ONLY ways to hold one are
/// `SignatureVerification.verify`, `verifyAgainstStoredKeeper` and
/// `verifyHeld`, all of which read the duplicate in full. A deletion API
/// that takes this type cannot be called on unverified candidates, which
/// is the point — the compiler enforces what a comment could only request.
struct VerifiedDuplicate: Equatable, Sendable {
    let keeperPath: String
    let duplicatePath: String
    /// Whole-file SHA-256 (lowercase hex) both sides produced.
    let fullHash: String
    let verifiedAt: Date
    let duplicateSize: Int64
    /// The keeper's whole-file fixity: freshly computed when
    /// `keeperReadInFull`, otherwise the stored one that stood in for
    /// the read. Callers store it on the keeper record when it is fresh.
    let keeperFixity: ContentFixity
    /// The duplicate's fixity — moot once the file is gone, harmless to
    /// keep for the log.
    let duplicateFixity: ContentFixity
    /// True when this proof cost a full read of the keeper (path 1).
    let keeperReadInFull: Bool
    fileprivate let keeperIdentity: FileIdentityStamp
    fileprivate let duplicateIdentity: FileIdentityStamp

    fileprivate init(keeperPath: String, duplicatePath: String,
                     fullHash: String, verifiedAt: Date,
                     keeperIdentity: FileIdentityStamp,
                     duplicateIdentity: FileIdentityStamp,
                     keeperFixity: ContentFixity,
                     duplicateFixity: ContentFixity,
                     keeperReadInFull: Bool) {
        self.keeperPath = keeperPath
        self.duplicatePath = duplicatePath
        self.fullHash = fullHash
        self.verifiedAt = verifiedAt
        self.duplicateSize = duplicateIdentity.size
        self.keeperIdentity = keeperIdentity
        self.duplicateIdentity = duplicateIdentity
        self.keeperFixity = keeperFixity
        self.duplicateFixity = duplicateFixity
        self.keeperReadInFull = keeperReadInFull
    }
}

/// A verified duplicate that has been moved out of its public name and
/// not yet removed. Only `SignatureVerification.quarantine` and
/// `verifyHeld` make one. (For Rick: a receipt — the proof, where the file
/// went, and the stat stamp taken the instant it landed there.)
struct QuarantineTicket: Equatable, Sendable {
    let proof: VerifiedDuplicate
    /// The original public path the file will be put back to if the
    /// deletion is refused.
    let originalPath: String
    /// The owner-only sibling directory the file was moved into.
    let quarantineDirectory: String
    /// The file's path inside `quarantineDirectory`.
    let quarantinedPath: String
    /// FULL identity (ctime included) captured immediately after the
    /// rename. The unlink requires it to reproduce exactly.
    let baseline: FileIdentityStamp
    /// True when the proof's full read happened IN quarantine, after the
    /// baseline (the single-read path): the unlink step then re-stats
    /// only. False when the read happened at the public path before the
    /// move: the unlink step reads the file once more.
    let hashedInQuarantine: Bool

    fileprivate init(proof: VerifiedDuplicate, originalPath: String, quarantineDirectory: String,
                     quarantinedPath: String, baseline: FileIdentityStamp, hashedInQuarantine: Bool) {
        self.proof = proof
        self.originalPath = originalPath
        self.quarantineDirectory = quarantineDirectory
        self.quarantinedPath = quarantinedPath
        self.baseline = baseline
        self.hashedInQuarantine = hashedInQuarantine
    }
}

/// A duplicate moved into quarantine BEFORE it has been read (the
/// single-read path). It authorises nothing: only `verifyHeld` can turn it
/// into a `QuarantineTicket`, and only by hashing the held file in full.
/// (For Rick: the receipt for the move, not for the identity.)
struct QuarantineHold: Equatable, Sendable {
    let keeperPath: String
    /// The stored keeper fixity that stood at the hold; the held file's
    /// digest must equal its digest.
    let keeperFixity: ContentFixity
    let originalPath: String
    let quarantineDirectory: String
    let quarantinedPath: String
    /// FULL identity (ctime included) captured immediately after the
    /// rename — BEFORE the read. Any write after this changes the ctime.
    let baseline: FileIdentityStamp
    fileprivate let keeperIdentity: FileIdentityStamp
    fileprivate let duplicateIdentityBeforeMove: FileIdentityStamp

    fileprivate init(keeperPath: String, keeperFixity: ContentFixity, originalPath: String,
                     quarantineDirectory: String, quarantinedPath: String, baseline: FileIdentityStamp,
                     keeperIdentity: FileIdentityStamp, duplicateIdentityBeforeMove: FileIdentityStamp) {
        self.keeperPath = keeperPath
        self.keeperFixity = keeperFixity
        self.originalPath = originalPath
        self.quarantineDirectory = quarantineDirectory
        self.quarantinedPath = quarantinedPath
        self.baseline = baseline
        self.keeperIdentity = keeperIdentity
        self.duplicateIdentityBeforeMove = duplicateIdentityBeforeMove
    }
}

enum SignatureVerification {

    struct Hooks: @unchecked Sendable {
        var shouldCancel: () -> Bool
        /// Called once per block read, with "keeper", "duplicate" or
        /// "quarantine" (a read of the duplicate in its quarantine folder
        /// — the single-read path's ONLY read, or the two-file path's
        /// re-read) — the seam tests use to count WHICH files were read.
        var didReadBlock: ((String) -> Void)?
        /// Called with the path of EVERY file the gate opens for reading
        /// — the head compare and the full hashes alike — so a test can
        /// count opens of the keeper path, not just full-hash blocks
        /// (codex 1593: "the read-once tests count only full-hash
        /// callbacks; `verify` also performs a head read").
        var didOpen: ((String) -> Void)?
        var didQuarantine: ((String) -> Void)?
        var removeQuarantineDirectory: ((URL) throws -> Void)?
        /// The Trash step of the `.trash` disposal: move the quarantined
        /// file into the Trash and return where it went. nil → the live
        /// `FileManager.trashItem` (the volume's own .Trashes). Tests
        /// inject a move into a scratch folder so no fixture ever lands
        /// in Rick's real Trash.
        var trashItem: ((URL) throws -> URL)?
        /// Called the moment `verify` (path 1) has hashed the KEEPER in
        /// full and re-stat'ed it — before the pair's verdict. The job
        /// stores that fixity on the keeper at once, so a refused first
        /// pair (a look-alike) does not cost the next pair a second read
        /// of the same keeper (codex follow-up P2 #6).
        var didComputeKeeperFixity: ((ContentFixity) -> Void)?

        static let live = Hooks(shouldCancel: { Task.isCancelled })
    }

    enum Failure: Error, Equatable {
        /// One or both files could not be read in full.
        case unreadable(String)
        /// They are genuinely different — the candidate was a false
        /// positive, which is exactly what verification is for.
        case contentDiffers
        /// Same path twice. Deleting "the duplicate" here would delete
        /// the only copy.
        case samePath
        /// A path was replaced or rewritten while/after it was verified.
        /// The caller must start over rather than act on stale proof.
        case changedSinceVerification(String)
        case cancelled
    }

    // MARK: Path 1 — both files read in full

    /// Compare two files byte-for-byte, via full-file digests.
    ///
    /// Expensive on purpose. Reads every byte of both files, so it is
    /// called on the pair about to be acted on, never across a catalog.
    ///
    /// Both sides are hashed FRESH at verification time rather than
    /// trusting anything stored: a signature computed last month says
    /// nothing about the bytes on disk right now, and the window between
    /// "decided to delete" and "deleted" is the one that matters. (The
    /// stored-fixity paths are the ONE exception, and they are guarded by
    /// a fresh stat stamp of the keeper.)
    static func verify(keeperPath: String, duplicatePath: String,
                       hooks: Hooks = .live)
        -> Result<VerifiedDuplicate, Failure> {

        guard keeperPath != duplicatePath else { return .failure(.samePath) }

        guard let keeperBefore = FileIdentityStamp.capture(path: keeperPath)
        else { return .failure(.unreadable(keeperPath)) }
        guard let duplicateBefore = FileIdentityStamp.capture(path: duplicatePath)
        else { return .failure(.unreadable(duplicatePath)) }
        // Two names, one inode (hard link, or two spellings of one path on
        // a case-insensitive volume): "the duplicate" IS the keeper. Refuse
        // before any read or move — QA MAJOR 2 on 462b034b.
        guard !keeperBefore.isSameFile(as: duplicateBefore) else { return .failure(.samePath) }

        // Refusal accelerators (Rick 2026-08-17: a LaCie pass with ~1,400
        // name-alike NON-duplicates was paying two full 50 GB reads per
        // refusal — "at this rate it'll be tomorrow night"). Both gates
        // can only REFUSE faster; the delete path below still requires
        // full, fresh, identical hashes of both files.
        //   1. Different sizes can never be identical bytes.
        //   2. Same size but different first bytes: compare the heads
        //      before committing to two full reads (encodes/containers
        //      almost always diverge within the first few MB).
        guard keeperBefore.size == duplicateBefore.size else {
            return .failure(.contentDiffers)
        }
        guard !hooks.shouldCancel() else { return .failure(.cancelled) }
        switch headsMatch(keeperPath: keeperPath, duplicatePath: duplicatePath, hooks: hooks) {
        case .some(false): return .failure(.contentDiffers)
        case .none: break            // unreadable head — let the full pass decide/report
        case .some(true): break
        }

        guard !hooks.shouldCancel() else { return .failure(.cancelled) }
        let keeperHash = cancellableFullHash(
            path: keeperPath, label: "keeper", hooks: hooks)
        guard !hooks.shouldCancel() else { return .failure(.cancelled) }
        guard !keeperHash.isEmpty else { return .failure(.unreadable(keeperPath)) }

        guard !hooks.shouldCancel() else { return .failure(.cancelled) }
        let duplicateHash = cancellableFullHash(
            path: duplicatePath, label: "duplicate", hooks: hooks)
        guard !hooks.shouldCancel() else { return .failure(.cancelled) }
        guard !duplicateHash.isEmpty else { return .failure(.unreadable(duplicatePath)) }

        guard !hooks.shouldCancel() else { return .failure(.cancelled) }

        guard let keeperAfter = FileIdentityStamp.capture(path: keeperPath),
              keeperAfter == keeperBefore else {
            return .failure(.changedSinceVerification(keeperPath))
        }
        // The keeper's whole-file fixity is knowledge worth keeping whatever
        // this pair's verdict turns out to be.
        let now = Date()
        let keeperFixity = ContentFixity(digest: keeperHash, byteCount: keeperAfter.size,
                                         stamp: keeperAfter, computedAt: now)
        hooks.didComputeKeeperFixity?(keeperFixity)
        guard let duplicateAfter = FileIdentityStamp.capture(path: duplicatePath),
              duplicateAfter == duplicateBefore else {
            return .failure(.changedSinceVerification(duplicatePath))
        }

        guard keeperHash == duplicateHash else { return .failure(.contentDiffers) }

        return .success(VerifiedDuplicate(
            keeperPath: keeperPath,
            duplicatePath: duplicatePath,
            fullHash: keeperHash,
            verifiedAt: now,
            keeperIdentity: keeperAfter,
            duplicateIdentity: duplicateAfter,
            keeperFixity: keeperFixity,
            duplicateFixity: ContentFixity(digest: duplicateHash, byteCount: duplicateAfter.size,
                                           stamp: duplicateAfter, computedAt: now),
            keeperReadInFull: true))
    }

    // MARK: Path 2 — keeper by stored fixity, duplicate read in full

    /// Verify a duplicate against a keeper WITHOUT re-reading the keeper,
    /// when the keeper's stored whole-file fixity still describes the
    /// file on disk (fresh `stat` reproduces the stamp). The duplicate is
    /// read in full, its identity checked before and after the read, and
    /// its digest must equal the stored one with equal sizes.
    ///
    /// Falls back to `verify` (both files read) when there is no fixity,
    /// the fixity is not sha256, or the keeper's stamp changed — the
    /// returned proof then carries the keeper's FRESH fixity
    /// (`keeperReadInFull == true`) for the caller to store.
    static func verifyAgainstStoredKeeper(keeperPath: String,
                                          keeperFixity: ContentFixity?,
                                          duplicatePath: String,
                                          hooks: Hooks = .live)
        -> Result<VerifiedDuplicate, Failure> {

        guard keeperPath != duplicatePath else { return .failure(.samePath) }
        guard let keeperBefore = FileIdentityStamp.capture(path: keeperPath)
        else { return .failure(.unreadable(keeperPath)) }
        guard let duplicateBefore = FileIdentityStamp.capture(path: duplicatePath)
        else { return .failure(.unreadable(duplicatePath)) }
        // Same inode as the keeper: nothing to free, and unlinking it
        // would be unlinking the keeper's own name. Before any read.
        guard !keeperBefore.isSameFile(as: duplicateBefore) else { return .failure(.samePath) }

        // No usable stored fixity → the two-file path, once. "Usable" is
        // the VERIFICATION-GRADE check (`describesFileNow`): sha256, a
        // ctime-bearing stamp, and device/inode/size/mtime/ctime all
        // reproducing under a fresh stat. mtime alone is user-settable
        // (QA MAJOR 1); ctime is the kernel's and is not.
        guard let fixity = keeperFixity,
              fixity.isUsableForVerification,
              fixity.describesFileNow(keeperBefore) else {
            return verify(keeperPath: keeperPath, duplicatePath: duplicatePath, hooks: hooks)
        }

        // Different sizes can never be identical bytes — refuse before
        // reading anything.
        guard duplicateBefore.size == fixity.byteCount else {
            return .failure(.contentDiffers)
        }

        guard !hooks.shouldCancel() else { return .failure(.cancelled) }
        let duplicateHash = cancellableFullHash(
            path: duplicatePath, label: "duplicate", hooks: hooks)
        guard !hooks.shouldCancel() else { return .failure(.cancelled) }
        guard !duplicateHash.isEmpty else { return .failure(.unreadable(duplicatePath)) }

        // Identity re-check on BOTH sides after the read: the keeper must
        // still be the file the fixity describes, the duplicate the one
        // just hashed.
        guard let keeperAfter = FileIdentityStamp.capture(path: keeperPath),
              keeperAfter == keeperBefore else {
            return .failure(.changedSinceVerification(keeperPath))
        }
        guard let duplicateAfter = FileIdentityStamp.capture(path: duplicatePath),
              duplicateAfter == duplicateBefore else {
            return .failure(.changedSinceVerification(duplicatePath))
        }

        guard duplicateHash == fixity.digest else { return .failure(.contentDiffers) }

        let now = Date()
        return .success(VerifiedDuplicate(
            keeperPath: keeperPath,
            duplicatePath: duplicatePath,
            fullHash: duplicateHash,
            verifiedAt: now,
            keeperIdentity: keeperAfter,
            duplicateIdentity: duplicateAfter,
            keeperFixity: fixity,
            duplicateFixity: ContentFixity(digest: duplicateHash, byteCount: duplicateAfter.size,
                                           stamp: duplicateAfter, computedAt: now),
            keeperReadInFull: false))
    }

    // MARK: Path 3 — single read: move first, hash once in quarantine

    /// The outcome of the hold: the file is in quarantine unread, or the
    /// keeper's stored fixity cannot stand in (no fixity / not sha256 /
    /// pre-ctime / stamp changed — the caller takes path 1 once and
    /// stores the fresh fixity), or nothing was moved.
    enum HoldOutcome: Equatable {
        case held(QuarantineHold)
        case keeperFixityUnusable
        case refused(Failure)
        case failed(String)
        case retainedQuarantine(path: String, reason: String)
    }

    /// Step (a) of the single-read path. Stats both files, requires the
    /// keeper's stored fixity to describe the keeper NOW (verification
    /// grade, ctime included) and the sizes to agree, then moves the
    /// duplicate into its owner-only quarantine folder and captures its
    /// full identity there. Nothing is read. The keeper is never read.
    static func holdForSingleRead(keeperPath: String, keeperFixity: ContentFixity?,
                                  duplicatePath: String, directoryName: String? = nil,
                                  hooks: Hooks = .live) -> HoldOutcome {
        guard keeperPath != duplicatePath else { return .refused(.samePath) }
        guard let keeperBefore = FileIdentityStamp.capture(path: keeperPath)
        else { return .refused(.unreadable(keeperPath)) }
        guard let duplicateBefore = FileIdentityStamp.capture(path: duplicatePath)
        else { return .refused(.unreadable(duplicatePath)) }
        guard !keeperBefore.isSameFile(as: duplicateBefore) else { return .refused(.samePath) }
        guard let fixity = keeperFixity,
              fixity.isUsableForVerification,
              fixity.describesFileNow(keeperBefore) else {
            return .keeperFixityUnusable
        }
        // Different sizes can never be identical bytes — refuse before
        // moving anything.
        guard duplicateBefore.size == fixity.byteCount else { return .refused(.contentDiffers) }
        guard !hooks.shouldCancel() else { return .refused(.cancelled) }

        switch moveIntoQuarantine(originalPath: duplicatePath, directoryName: directoryName,
                                  expected: duplicateBefore, hooks: hooks) {
        case .moved(let directory, let file, let baseline):
            return .held(QuarantineHold(keeperPath: keeperPath, keeperFixity: fixity,
                                        originalPath: duplicatePath, quarantineDirectory: directory.path,
                                        quarantinedPath: file.path, baseline: baseline,
                                        keeperIdentity: keeperBefore,
                                        duplicateIdentityBeforeMove: duplicateBefore))
        case .refused(let failure): return .refused(failure)
        case .failed(let reason): return .failed(reason)
        case .retainedQuarantine(let path, let reason): return .retainedQuarantine(path: path, reason: reason)
        }
    }

    enum HeldVerification: Equatable {
        case verified(QuarantineTicket)
        /// Refused and put back at its original path.
        case refused(Failure)
        /// Refused but could not be put back — left where it is, named.
        case retainedQuarantine(path: String, reason: String)
    }

    /// Step (e)–(f) of the single-read path: hash the held file ONCE in
    /// full, in quarantine; require the digest to equal the keeper's
    /// stored one, the keeper's stamp to still reproduce, and the held
    /// file's full identity (ctime included) to equal the post-move
    /// baseline. Any doubt puts the file back at its public path.
    static func verifyHeld(_ hold: QuarantineHold, hooks: Hooks = .live) -> HeldVerification {
        let quarantined = URL(fileURLWithPath: hold.quarantinedPath)
        let original = URL(fileURLWithPath: hold.originalPath)
        let directory = URL(fileURLWithPath: hold.quarantineDirectory, isDirectory: true)
        func putBack(_ failure: Failure, reason: String) -> HeldVerification {
            switch restoreOrRetain(quarantined: quarantined, original: original, quarantineDirectory: directory,
                                   reason: reason, failure: failure) {
            case .refused(let f): return .refused(f)
            case .retainedQuarantine(let path, let why): return .retainedQuarantine(path: path, reason: why)
            case .failed(let why): return .retainedQuarantine(path: quarantined.path, reason: why)
            case .deleted, .trashed: return .retainedQuarantine(path: quarantined.path, reason: "unreachable")
            }
        }

        guard !hooks.shouldCancel() else { return putBack(.cancelled, reason: "cancelled after quarantine") }
        // THE read: once, in full, in quarantine, after the baseline.
        let digest = cancellableFullHash(path: quarantined.path, label: "quarantine", hooks: hooks)
        guard !hooks.shouldCancel() else { return putBack(.cancelled, reason: "cancelled after quarantine") }
        guard !digest.isEmpty else {
            return putBack(.unreadable(hold.originalPath), reason: "quarantined file could not be read")
        }
        guard digest == hold.keeperFixity.digest else {
            return putBack(.contentDiffers, reason: "content differs from the keeper")
        }
        // The keeper must still be the file the fixity describes.
        guard let keeperNow = FileIdentityStamp.capture(path: hold.keeperPath), keeperNow == hold.keeperIdentity else {
            return putBack(.changedSinceVerification(hold.keeperPath), reason: "keeper changed during verification")
        }
        // The held file must be exactly what was baselined — a write
        // during the read moved the kernel ctime.
        guard let heldNow = FileIdentityStamp.capture(path: quarantined.path), heldNow == hold.baseline,
              heldNow.size == hold.keeperFixity.byteCount else {
            return putBack(.changedSinceVerification(hold.originalPath), reason: "quarantined file identity changed")
        }
        let now = Date()
        let proof = VerifiedDuplicate(
            keeperPath: hold.keeperPath, duplicatePath: hold.originalPath, fullHash: digest, verifiedAt: now,
            keeperIdentity: keeperNow, duplicateIdentity: hold.duplicateIdentityBeforeMove,
            keeperFixity: hold.keeperFixity,
            duplicateFixity: ContentFixity(digest: digest, byteCount: heldNow.size, stamp: heldNow, computedAt: now),
            keeperReadInFull: false)
        return .verified(QuarantineTicket(proof: proof, originalPath: hold.originalPath,
                                          quarantineDirectory: hold.quarantineDirectory,
                                          quarantinedPath: hold.quarantinedPath, baseline: hold.baseline,
                                          hashedInQuarantine: true))
    }

    /// Revalidate the exact path identities captured by `verify`. This must
    /// be called immediately before a destructive action; a matching digest
    /// from moments ago is not authority to delete after either path changed.
    static func revalidate(_ proof: VerifiedDuplicate) -> Result<Void, Failure> {
        guard FileIdentityStamp.capture(path: proof.keeperPath)
                == proof.keeperIdentity else {
            return .failure(.changedSinceVerification(proof.keeperPath))
        }
        guard FileIdentityStamp.capture(path: proof.duplicatePath)
                == proof.duplicateIdentity else {
            return .failure(.changedSinceVerification(proof.duplicatePath))
        }
        return .success(())
    }

    /// What happens to a verified file at the end: gone now, or into the
    /// volume's Trash (the copy-count tier's cautious rung).
    enum Disposal: String, Equatable, Sendable {
        case permanent
        case trash
    }

    /// The removal boundary's LAST word (codex 1619 #1): a caller-supplied
    /// check consulted after every read and identity check has passed,
    /// immediately before the unlink / Trash move — in the same
    /// synchronous stretch, no await between. `.proceed` may lower the
    /// disposal (permanent → Trash); `.putBack` restores the file
    /// untouched, reported as `.refused(.cancelled)` exactly like
    /// `releaseQuarantine`. The job uses it to re-stat every copy its
    /// copy-count tier was counted on — AFTER the fallback path's full
    /// re-read, not before it.
    enum FinalVerdict: Equatable, Sendable {
        case proceed(Disposal)
        case putBack(reason: String)
    }

    enum DeletionResult: Equatable {
        case deleted(bytes: Int64)
        /// Moved into the Trash; `location` is where it sits now.
        case trashed(bytes: Int64, location: String)
        case refused(Failure)
        case failed(String)
        case retainedQuarantine(path: String, reason: String)
    }

    /// The outcome of step (a): the file is either sitting in quarantine
    /// with a ticket, or nothing was moved (refused / failed), or it was
    /// moved and could not be put back (retained, named).
    enum QuarantineOutcome: Equatable {
        case quarantined(QuarantineTicket)
        case refused(Failure)
        case failed(String)
        case retainedQuarantine(path: String, reason: String)
    }

    /// The prefix every quarantine directory name starts with.
    static let quarantineDirectoryPrefix = ".videoscan-quarantine-"

    // MARK: Step (a) — quarantine

    /// Atomically moves the verified directory entry out of its public name
    /// into a fresh owner-only sibling directory and captures its FULL
    /// identity there. A replacement created at the original path can
    /// therefore never become the object subsequently removed, and a
    /// rewrite of the moved inode after this instant changes its ctime.
    ///
    /// `directoryName` lets the caller choose the folder name (the job
    /// derives one from its plan + row ids so a crash leaves a folder the
    /// plan can name); nil → a random UUID name. The directory must not
    /// already exist — an existing one is never reused or emptied.
    static func quarantine(_ proof: VerifiedDuplicate,
                           directoryName: String? = nil,
                           hooks: Hooks = .live) -> QuarantineOutcome {
        guard !hooks.shouldCancel() else { return .refused(.cancelled) }
        if case .failure(let failure) = revalidate(proof) {
            return .refused(failure)
        }
        switch moveIntoQuarantine(originalPath: proof.duplicatePath, directoryName: directoryName,
                                  expected: proof.duplicateIdentity, hooks: hooks) {
        case .moved(let directory, let file, let baseline):
            return .quarantined(QuarantineTicket(proof: proof, originalPath: proof.duplicatePath,
                                                 quarantineDirectory: directory.path,
                                                 quarantinedPath: file.path, baseline: baseline,
                                                 hashedInQuarantine: false))
        case .refused(let failure): return .refused(failure)
        case .failed(let reason): return .failed(reason)
        case .retainedQuarantine(let path, let reason): return .retainedQuarantine(path: path, reason: reason)
        }
    }

    private enum MoveOutcome {
        case moved(directory: URL, file: URL, baseline: FileIdentityStamp)
        case refused(Failure)
        case failed(String)
        case retainedQuarantine(path: String, reason: String)
    }

    /// The rename shared by `quarantine` and `holdForSingleRead`: a fresh
    /// owner-only sibling folder, the move, and the post-rename baseline,
    /// which must still be `expected` in every field a rename cannot
    /// change (device, inode, size, mtime).
    private static func moveIntoQuarantine(originalPath: String, directoryName: String?,
                                           expected: FileIdentityStamp, hooks: Hooks) -> MoveOutcome {
        let original = URL(fileURLWithPath: originalPath)
        let name = directoryName ?? (quarantineDirectoryPrefix + UUID().uuidString)
        let quarantineDirectory = original.deletingLastPathComponent()
            .appendingPathComponent(name, isDirectory: true)
        let quarantined = quarantineDirectory.appendingPathComponent(original.lastPathComponent)
        do {
            try FileManager.default.createDirectory(
                at: quarantineDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        } catch {
            // Nothing was created (or the name is taken): touch nothing.
            return .failed("could not create quarantine directory: \(error.localizedDescription)")
        }
        do {
            try FileManager.default.moveItem(at: original, to: quarantined)
        } catch {
            // We made the directory and it is still empty — rmdir only.
            _ = rmdir(quarantineDirectory.path)
            return .failed("could not quarantine target: \(error.localizedDescription)")
        }

        // The baseline: stat the moved file NOW. The rename bumped its
        // ctime; that new ctime is what the unlink step must see again.
        // Device / inode / size / mtime — the fields a rename cannot
        // change — must still be the expected file's.
        let baseline = FileIdentityStamp.capture(path: quarantined.path)
        hooks.didQuarantine?(quarantined.path)
        guard let baseline, baseline.matchesIgnoringChangeTime(expected) else {
            switch restoreOrRetain(quarantined: quarantined, original: original,
                                   quarantineDirectory: quarantineDirectory,
                                   reason: "quarantined file identity changed") {
            case .refused(let failure): return .refused(failure)
            case .retainedQuarantine(let path, let reason): return .retainedQuarantine(path: path, reason: reason)
            case .failed(let reason): return .failed(reason)
            case .deleted, .trashed: return .failed("unreachable")
            }
        }
        return .moved(directory: quarantineDirectory, file: quarantined, baseline: baseline)
    }

    // MARK: Step (b) — (re-read,) re-check, unlink or trash

    /// Unless the ticket's read already happened in quarantine, read the
    /// quarantined file in full again and require its digest to be the
    /// proof's; then require the baseline (ctime included) and the keeper
    /// to reproduce and the original name to be empty; then ask
    /// `finalVerdict` (if given) — the caller's own last check, run after
    /// ALL hashing so nothing it looked at can change under a long read
    /// (codex 1619 #1); then unlink — or, with `.trash`, move into the
    /// volume's Trash. Any doubt puts the file back (or retains it in
    /// place, named).
    static func deleteQuarantined(_ ticket: QuarantineTicket,
                                  disposal: Disposal = .permanent,
                                  hooks: Hooks = .live,
                                  finalVerdict: (() -> FinalVerdict)? = nil) -> DeletionResult {
        let proof = ticket.proof
        let quarantined = URL(fileURLWithPath: ticket.quarantinedPath)
        let original = URL(fileURLWithPath: ticket.originalPath)
        let quarantineDirectory = URL(fileURLWithPath: ticket.quarantineDirectory, isDirectory: true)

        guard !hooks.shouldCancel() else {
            return restoreOrRetain(quarantined: quarantined, original: original,
                                   quarantineDirectory: quarantineDirectory,
                                   reason: "cancelled after quarantine", cancelled: true)
        }

        if !ticket.hashedInQuarantine {
            // The second full read: the only thing that can see a rewrite
            // that landed between the verification read and the baseline.
            let rehash = cancellableFullHash(path: quarantined.path, label: "quarantine", hooks: hooks)
            guard !hooks.shouldCancel() else {
                return restoreOrRetain(quarantined: quarantined, original: original,
                                       quarantineDirectory: quarantineDirectory,
                                       reason: "cancelled after quarantine", cancelled: true)
            }
            guard !rehash.isEmpty, rehash == proof.fullHash else {
                return restoreOrRetain(quarantined: quarantined, original: original,
                                       quarantineDirectory: quarantineDirectory,
                                       reason: rehash.isEmpty
                                           ? "quarantined file could not be re-read before removal"
                                           : "quarantined file content no longer matches what was verified")
            }
        }

        // FULL identity — ctime included — against the post-rename
        // baseline: any write since the baseline changed the ctime.
        let quarantineMatches = FileIdentityStamp.capture(path: quarantined.path) == ticket.baseline
        let keeperMatches = FileIdentityStamp.capture(path: proof.keeperPath) == proof.keeperIdentity
        let originalOccupied = FileManager.default.fileExists(atPath: original.path)
        let cancelledAfterQuarantine = hooks.shouldCancel()
        guard quarantineMatches, keeperMatches, !originalOccupied,
              !cancelledAfterQuarantine else {
            let reason: String
            if cancelledAfterQuarantine {
                reason = "cancelled after quarantine"
            } else if !quarantineMatches {
                reason = "quarantined file identity changed"
            } else if originalOccupied {
                reason = "original pathname was replaced during deletion"
            } else {
                reason = "keeper changed after verification"
            }
            return restoreOrRetain(
                quarantined: quarantined, original: original,
                quarantineDirectory: quarantineDirectory, reason: reason,
                cancelled: cancelledAfterQuarantine)
        }

        // The caller's final word, AFTER the re-read and the identity checks
        // and with nothing else between here and the removal: the copy-count
        // evidence is re-stat'ed here, not before a read that could take
        // minutes on a spinning disk (codex 1619 #1).
        var disposal = disposal
        if let finalVerdict {
            switch finalVerdict() {
            case .proceed(let final):
                disposal = final
            case .putBack(let reason):
                return restoreOrRetain(quarantined: quarantined, original: original,
                                       quarantineDirectory: quarantineDirectory,
                                       reason: reason, cancelled: true)
            }
        }

        switch disposal {
        case .permanent:
            do {
                // No await precedes this removal after the identity check and
                // the final verdict. The entry is isolated in a fresh owner-only
                // directory.
                try FileManager.default.removeItem(at: quarantined)
            } catch {
                return .retainedQuarantine(
                    path: quarantined.path,
                    reason: "verified file retained because final removal failed: \(error.localizedDescription)")
            }
            // Empty-directory cleanup is housekeeping, not part of the media
            // deletion transaction. Once the quarantined file is gone, report
            // success so the catalog cannot retain a row for nonexistent media.
            // The directory is removed ONLY if empty (rmdir, never recursive):
            // anything else that ended up in there is not ours to delete.
            removeQuarantineDirectoryQuietly(quarantineDirectory, hooks: hooks, after: "removed verified duplicate")
            return .deleted(bytes: proof.duplicateSize)
        case .trash:
            // The file goes back to its PUBLIC path first and is handed to the
            // Trash from there: Finder's "Put Back" then restores it to where
            // it lived (QA #4), and a Trash step that fails — SMB and some
            // externals have no usable .Trashes — leaves the file at home,
            // never parked in a hidden folder (QA #1). The identity checks
            // above still cover it: nothing else can have the original name
            // (checked empty an instant ago) and the move is a rename.
            do {
                try FileManager.default.moveItem(at: quarantined, to: original)
            } catch {
                return .retainedQuarantine(
                    path: quarantined.path,
                    reason: "verified file retained because it could not be put back before the move to the Trash: \(error.localizedDescription)")
            }
            removeQuarantineDirectoryQuietly(quarantineDirectory, hooks: hooks, after: "put back before the Trash")
            do {
                let destination: URL
                if let trash = hooks.trashItem {
                    destination = try trash(original)
                } else {
                    var resulting: NSURL?
                    try FileManager.default.trashItem(at: original, resultingItemURL: &resulting)
                    destination = (resulting as URL?) ?? original
                }
                return .trashed(bytes: proof.duplicateSize, location: destination.path)
            } catch {
                return .failed("the move to the Trash failed: \(error.localizedDescription) — the file is back at \(original.path), untouched")
            }
        }
    }

    private static func removeQuarantineDirectoryQuietly(_ quarantineDirectory: URL, hooks: Hooks, after what: String) {
        do {
            if let removeDirectory = hooks.removeQuarantineDirectory {
                try removeDirectory(quarantineDirectory)
            } else {
                try removeEmptyDirectory(quarantineDirectory)
            }
        } catch {
            NSLog("VideoScan: %@ but could not remove quarantine directory %@ (left in place): %@",
                  what, quarantineDirectory.path, error.localizedDescription)
        }
    }

    /// Put a quarantined file back without deleting it — the caller could
    /// not record the quarantine (plan save failed), is stopping, or the
    /// copy-count tier said "not below the archive copy".
    static func releaseQuarantine(_ ticket: QuarantineTicket, reason: String,
                                  cancelled: Bool = true) -> DeletionResult {
        restoreOrRetain(quarantined: URL(fileURLWithPath: ticket.quarantinedPath),
                        original: URL(fileURLWithPath: ticket.originalPath),
                        quarantineDirectory: URL(fileURLWithPath: ticket.quarantineDirectory, isDirectory: true),
                        reason: reason, cancelled: cancelled)
    }

    /// Steps (a) and (b) back to back, for callers without a plan to
    /// record the quarantine in.
    static func quarantineAndDelete(_ proof: VerifiedDuplicate,
                                    hooks: Hooks = .live) -> DeletionResult {
        switch quarantine(proof, hooks: hooks) {
        case .quarantined(let ticket): return deleteQuarantined(ticket, hooks: hooks)
        case .refused(let failure): return .refused(failure)
        case .failed(let reason): return .failed(reason)
        case .retainedQuarantine(let path, let reason): return .retainedQuarantine(path: path, reason: reason)
        }
    }

    /// `rmdir(2)`: succeeds only on an empty directory. Never recursive.
    static func removeEmptyDirectory(_ directory: URL) throws {
        guard rmdir(directory.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
    }

    /// Put the quarantined file back. A Stop that landed after the move is
    /// reported as `.cancelled` once the file is restored (QA MINOR 3) —
    /// it is not a changed file, and the row must not be re-marked Review.
    /// `failure` names what the refusal IS (a content mismatch on the
    /// single-read path is `.contentDiffers`, not "changed"); nil → the
    /// path changed. The quarantine directory is removed only if it is
    /// empty afterwards.
    private static func restoreOrRetain(quarantined: URL, original: URL,
                                        quarantineDirectory: URL,
                                        reason: String,
                                        cancelled: Bool = false,
                                        failure: Failure? = nil) -> DeletionResult {
        guard !FileManager.default.fileExists(atPath: original.path) else {
            return .retainedQuarantine(
                path: quarantined.path,
                reason: "\(reason); original pathname is occupied")
        }
        do {
            try FileManager.default.moveItem(at: quarantined, to: original)
        } catch {
            return .retainedQuarantine(
                path: quarantined.path,
                reason: "\(reason); restore failed: \(error.localizedDescription)")
        }
        do {
            try removeEmptyDirectory(quarantineDirectory)
        } catch {
            NSLog("VideoScan: restored %@ but could not remove quarantine directory %@ (left in place): %@",
                  original.lastPathComponent, quarantineDirectory.path, error.localizedDescription)
        }
        if let failure { return .refused(failure) }
        return .refused(cancelled ? .cancelled : .changedSinceVerification(original.path))
    }

    /// Bytes compared by the head gate. 4 MB: past every container header
    /// and into the first frames, cheap on any medium.
    static let headCompareBytes = 4 * 1024 * 1024

    /// Compare the first `headCompareBytes` of both files. true = identical
    /// heads (files MAY still differ later — the full hash decides), false =
    /// definitely different, nil = could not read (caller falls through to
    /// the full pass so the real error is reported).
    static func headsMatch(keeperPath: String, duplicatePath: String,
                           bytes: Int = headCompareBytes,
                           hooks: Hooks = .live) -> Bool? {
        func head(_ path: String) -> Data? {
            let fd = open(path, O_RDONLY)
            guard fd >= 0 else { return nil }
            hooks.didOpen?(path)
            defer { close(fd) }
            var data = Data(count: bytes)
            let n = data.withUnsafeMutableBytes { buf -> Int in
                var total = 0
                while total < bytes {
                    let r = read(fd, buf.baseAddress! + total, bytes - total)
                    if r > 0 { total += r } else if r == 0 { break } else if errno != EINTR { return -1 }
                }
                return total
            }
            guard n >= 0 else { return nil }
            return data.prefix(n)
        }
        guard let a = head(keeperPath), let b = head(duplicatePath) else { return nil }
        return a == b
    }

    /// Whole-file SHA-256 as lowercase hex — the SAME value
    /// `CatalogStore.sha256HexStreaming` and the archive manifest carry, so
    /// a fixity written by Promote / Verify Archive is comparable here and
    /// vice versa. (Until 2026-09-20 this seeded the digest with
    /// "full:<size>:", which made it incomparable with every other sha256
    /// in the app; the size is compared separately by every caller.)
    /// Streams in `blockSize` blocks — bounded memory regardless of file
    /// size (worst case: one 1 MiB buffer per concurrent read; the job
    /// runs at most two). Returns "" on any I/O error, cancellation, or a
    /// size change mid-read.
    private static func cancellableFullHash(path: String, label: String,
                                            hooks: Hooks,
                                            blockSize: Int = FileHasher.segmentSize) -> String {
        guard blockSize > 0 else { return "" }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return "" }
        hooks.didOpen?(path)
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0 else { return "" }
        let expectedSize = Int(info.st_size)
        var sha = SHA256()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: blockSize, alignment: 16)
        defer { buffer.deallocate() }
        var total = 0
        while true {
            guard !hooks.shouldCancel() else { return "" }
            let count = read(fd, buffer, blockSize)
            if count > 0 {
                sha.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
                total += count
                hooks.didReadBlock?(label)
            } else if count == 0 {
                break
            } else if errno != EINTR {
                return ""
            }
        }
        guard !hooks.shouldCancel(), total == expectedSize else { return "" }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// What reading one whole file for its stamp-bound fixity found.
    enum WholeFileFixity: Equatable, Sendable {
        case fixity(ContentFixity)
        /// The path could not be stat'ed (offline drive, gone).
        case unavailable
        /// Opened but not read to the end (I/O error, not a regular file).
        case unreadable
        /// The stat after the read did not reproduce the stat before it.
        case changedDuringRead
        case cancelled
    }

    /// Read `path` IN FULL and bind the digest to its stat stamp — exactly
    /// the way `verify` produces a keeper's fixity: stamp before, stream
    /// the whole file (bounded 1 MiB buffer), stamp after, and the two
    /// stamps must be identical (ctime included). The Delete Duplicates
    /// job uses it to PROVE a sibling copy (2026-09-21): a sibling with no
    /// current evidence is read once on its own drive and, when its
    /// digest is the duplicate's, counts through the ordinary
    /// stamp-bound-fixity path. `label` is what `didReadBlock` reports
    /// ("sibling").
    static func wholeFileFixity(path: String, label: String, hooks: Hooks = .live) -> WholeFileFixity {
        guard !hooks.shouldCancel() else { return .cancelled }
        guard let before = FileIdentityStamp.capture(path: path) else { return .unavailable }
        let digest = cancellableFullHash(path: path, label: label, hooks: hooks)
        if hooks.shouldCancel() { return .cancelled }
        guard !digest.isEmpty else { return .unreadable }
        guard let fixity = ContentFixity.captured(path: path, digest: digest, byteCount: before.size, before: before)
        else { return .changedDuringRead }
        return .fixity(fixity)
    }

    /// Human-facing description of what a matching signature does and
    /// does not establish. Used wherever the UI reports a duplicate, so
    /// the interface never repeats the overclaim the code made.
    static let candidateDisclaimer =
        "Matching signatures mean these files are very likely identical. "
        + "Every byte is compared before anything is deleted."
}
