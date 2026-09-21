// VideoScanModel+PruneVerification.swift
// The evidence "Archived — what next?" → Apply demands before a copy may
// go, and the proof it carries to the moment the file actually moves.
// Split out of VideoScanModel+PruneApply.swift after codex's follow-up
// review of 90a54fb0 (2026-09-20, findings #1, #2, #3, #6). Everything
// here is a pure function of paths, stamps and stored fixities — it runs
// off the main actor and reads no VideoRecord. The ONLY byte comparison
// it performs itself is the archive copy's re-hash against the archive's
// own verified digest; duplicate-vs-archive comparison stays
// SignatureVerification's (`verifyAgainstStoredKeeper`).
//
// THE THREE RULES, each earned by a finding:
//
//   #2  The ARCHIVE copy must present CURRENT evidence before any copy
//       in its family goes. Existence + size was the whole check before,
//       so an archive rewritten to the same length after promotion still
//       authorised pruning the intact original. Now: the archive copy's
//       stored whole-file `contentFixity` must reproduce under a fresh
//       stat (device, inode, size, mtime AND kernel ctime — the
//       verification-grade `describesFileNow`) AND its digest must equal
//       the archive's read-back digest (`archiveFixity`); otherwise the
//       archive copy is read in full NOW and that digest must equal
//       `archiveFixity.digest`. Anything else holds every copy in the
//       family, named "archive copy changed". Versions get the same
//       check — they go on provenance, but provenance to a corrupted
//       archive is nothing.
//
//   #1  The promotion ORIGINAL may be trusted unread only on its
//       PROMOTION-TIME identity. The old shortcut compared the source's
//       mtime/ctime to the archive's `verifiedAt` — a date that a later
//       archive audit advances — so "edit A, audit the archive" made the
//       edited source pass unread. Now Promote binds the source's stat
//       stamp (taken before and after the read that produced the digest)
//       to that digest on the source's `contentFixity`; Apply trusts the
//       original only while its CURRENT stat reproduces that stamp and
//       the digest equals the archive's CURRENT evidence. No stamp (older
//       catalogs, adoptions), a stamp that no longer reproduces, a
//       different digest: read in full like any duplicate.
//
//   #3  Verification expires. The old Apply verified the whole batch,
//       kept nothing but a yes/no per copy, and handed records to the
//       Trash routine, which only checked existence — so a file rewritten
//       or replaced while its neighbour was hashing went to the Trash on
//       a stale verdict. Now every verdict yields a `PruneProof` — the
//       target's identity stamp, the archive copy's identity stamp, and
//       the catalog facts the verdict rests on — and the Trash routine's
//       `JunkDeletionGuard` re-checks it twice per file: the live catalog
//       on the main actor just before the off-main pass, and both stat
//       stamps immediately before that file's own trashItem. A mismatch
//       holds the file, named; nothing moves.
//
//   #6  N duplicates of one uncached archive copy used to read the
//       archive N times. The archive evidence above is computed ONCE per
//       archive copy per batch, and the fresh fixity it yields is what
//       every duplicate in the batch verifies against (one-sided, by
//       stamp) — one archive read, N duplicate reads.
//
// (For Rick: think of `PruneProof` as the receipt a verifier hands to the
// mover — "I checked THIS inode against THAT inode" — and the guard as
// the mover refusing to touch anything whose receipt no longer matches.)

import Foundation
import VideoScanCore

extension VideoScanModel {

    // MARK: Seams

    /// Hooks for the prune verification. `didOpen` fires with the path of
    /// EVERY file opened for reading (the archive re-hash here, and the
    /// duplicate / head reads inside SignatureVerification) so a test can
    /// count real opens, not labels. `beforeMutation` runs on the main
    /// actor with the copy's path after ITS verdict and before ITS move —
    /// the deterministic point a test uses to change the world between
    /// verdict and mutation.
    struct PruneVerifyHooks: @unchecked Sendable {
        var shouldCancel: () -> Bool
        var didOpen: ((String) -> Void)?
        var beforeMutation: (@MainActor (String) -> Void)?

        static let live = PruneVerifyHooks(shouldCancel: { Task.isCancelled })

        /// The same seams, in SignatureVerification's shape.
        var signature: SignatureVerification.Hooks {
            SignatureVerification.Hooks(shouldCancel: shouldCancel, didOpen: didOpen)
        }
    }

    // MARK: #2 — the archive copy's CURRENT evidence

    /// What Apply knows about one archive copy from the catalog.
    struct PruneArchiveEvidence: Sendable {
        let archiveID: UUID
        let archivePath: String
        /// The read-back digest the archive copy was promoted / audited
        /// with — the bar its current bytes must meet.
        let archiveFixity: ArchiveFixity
        /// Its stored whole-file fixity with a stat stamp (Verify Archive
        /// writes it; Promote does not — see registerPromotedCopy). nil →
        /// one full read now.
        let contentFixity: ContentFixity?
    }

    enum PruneArchiveVerdict: Sendable, Equatable {
        /// The archive copy on disk IS the verified bytes: `fixity` is its
        /// current whole-file fixity (fresh when `readInFull`, to be stored
        /// on the record and reused by the rest of the batch).
        case current(fixity: ContentFixity, readInFull: Bool)
        /// Why nothing in this family may go.
        case problem(String)
    }

    /// Stat the archive copy; accept its stored fixity only when it
    /// reproduces to the ctime AND carries the archive's verified digest;
    /// otherwise read it in full and require that digest. Never on the
    /// main actor (a whole-file read).
    nonisolated static func pruneArchiveVerdict(_ e: PruneArchiveEvidence,
                                                hooks: PruneVerifyHooks = .live) -> PruneArchiveVerdict {
        let wanted = e.archiveFixity.digest.lowercased()
        guard e.archiveFixity.algorithm == ContentFixity.sha256, !wanted.isEmpty else {
            return .problem("its archive copy's fixity is not a sha256 digest")
        }
        guard let before = FileIdentityStamp.capture(path: e.archivePath) else {
            return .problem("its archive copy is not on disk")
        }
        guard before.size == e.archiveFixity.sizeBytes else {
            return .problem("its archive copy is not the size the catalog recorded")
        }
        if let stored = e.contentFixity,
           stored.isUsableForVerification,
           stored.digest == wanted,
           stored.byteCount == e.archiveFixity.sizeBytes,
           stored.describesFileNow(before) {
            return .current(fixity: stored, readInFull: false)
        }
        // No usable stamp (or it no longer reproduces): the archive copy
        // is read end to end, once, and must still be the verified bytes.
        guard !hooks.shouldCancel() else { return .problem("the check was cancelled") }
        hooks.didOpen?(e.archivePath)
        let digest: String?
        do {
            digest = try ArchivePromoteEngine.sha256(path: e.archivePath, shouldCancel: hooks.shouldCancel)
        } catch {
            return .problem("its archive copy could not be read in full")
        }
        guard let digest, !digest.isEmpty else {
            return .problem(hooks.shouldCancel() ? "the check was cancelled" : "its archive copy could not be read in full")
        }
        guard digest.lowercased() == wanted else {
            return .problem("archive copy changed — its bytes no longer match its verified fixity; nothing in this family may go until Verify Archive Copies has looked at it")
        }
        // Bind the digest to the stamp taken BEFORE the read, which the
        // stamp after the read must reproduce (ContentFixity.captured).
        guard let fresh = ContentFixity.captured(path: e.archivePath, digest: digest,
                                                 byteCount: e.archiveFixity.sizeBytes, before: before) else {
            return .problem("its archive copy changed while it was being read")
        }
        return .current(fixity: fresh, readInFull: true)
    }

    // MARK: #1 / #3 — one copy's verdict, and the proof it yields

    /// One copy's check, as plain values so it runs off the main actor.
    struct PruneByteCheck: Sendable {
        let copyID: UUID
        let filename: String
        let path: String
        let kind: PrunePlan.CopyRow.Kind
        let archiveID: UUID
        let archivePath: String
        /// The archive copy's CURRENT fixity — `pruneArchiveVerdict`'s.
        let archiveFixity: ContentFixity
        /// The copy's own stored whole-file fixity. Consulted ONLY for the
        /// promotion original, where it is the promotion-time stamp
        /// (registerPromotedCopy); nil → read in full.
        let ownFixity: ContentFixity?
        /// Catalog facts the verdict rests on, re-checked live before the
        /// file moves.
        let contentKey: String
        let derivedFrom: UUID?
    }

    /// The receipt a verdict hands to the mover (see file header).
    struct PruneProof: Sendable, Equatable {
        let copyID: UUID
        let path: String
        /// The copy's identity the instant its verdict was reached.
        let targetStamp: FileIdentityStamp
        let archiveID: UUID
        let archivePath: String
        /// The archive copy's identity the evidence was taken against.
        let archiveStamp: FileIdentityStamp
        let archiveDigest: String
        let contentKey: String
        let derivedFrom: UUID?
    }

    /// nil `problem` = the copy may go, with `proof`; otherwise why not.
    struct PruneByteVerdict: Sendable {
        let copyID: UUID
        let problem: String?
        let proof: PruneProof?
        /// The copy was read in full (false = a version, or the promotion
        /// original trusted on its promotion-time stamp).
        let readInFull: Bool
    }

    /// Decide one copy. Versions: provenance only — a stamp for the
    /// proof, and never the archive copy's own inode. The promotion
    /// original: trusted unread on its promotion-time fixity when that
    /// stamp reproduces NOW and its digest is the archive's current
    /// digest; else read in full. Duplicates: read in full against the
    /// archive copy's current fixity (one-sided). Never on the main actor.
    nonisolated static func pruneByteVerdict(_ c: PruneByteCheck,
                                             hooks: PruneVerifyHooks = .live) -> PruneByteVerdict {
        func held(_ why: String, readInFull: Bool) -> PruneByteVerdict {
            PruneByteVerdict(copyID: c.copyID, problem: why, proof: nil, readInFull: readInFull)
        }
        func go(_ stamp: FileIdentityStamp, readInFull: Bool) -> PruneByteVerdict {
            PruneByteVerdict(copyID: c.copyID, problem: nil,
                             proof: PruneProof(copyID: c.copyID, path: c.path, targetStamp: stamp,
                                               archiveID: c.archiveID, archivePath: c.archivePath,
                                               archiveStamp: c.archiveFixity.stamp,
                                               archiveDigest: c.archiveFixity.digest,
                                               contentKey: c.contentKey, derivedFrom: c.derivedFrom),
                             readInFull: readInFull)
        }
        if c.kind.isVersion {
            guard let stamp = FileIdentityStamp.capture(path: c.path) else {
                return held("is not on disk where the catalog says", readInFull: false)
            }
            guard !stamp.isSameFile(as: c.archiveFixity.stamp) else {
                return held("it IS the archive copy's file (same inode)", readInFull: false)
            }
            return go(stamp, readInFull: false)
        }

        if c.kind == .original, let own = c.ownFixity,
           own.isUsableForVerification,
           own.digest == c.archiveFixity.digest,
           own.byteCount == c.archiveFixity.byteCount,
           let stamp = FileIdentityStamp.capture(path: c.path),
           own.describesFileNow(stamp),
           !stamp.isSameFile(as: c.archiveFixity.stamp) {
            return go(stamp, readInFull: false)
        }

        switch SignatureVerification.verifyAgainstStoredKeeper(keeperPath: c.archivePath,
                                                               keeperFixity: c.archiveFixity,
                                                               duplicatePath: c.path,
                                                               hooks: hooks.signature) {
        case .success(let proof):
            // The archive evidence was taken moments ago; if its stamp did
            // not reproduce here the gate fell back to reading BOTH files
            // and compared them to each other — that is not a comparison
            // against the archive's verified bytes. Hold rather than trust.
            guard !proof.keeperReadInFull, proof.fullHash == c.archiveFixity.digest else {
                return held("its archive copy changed while the batch was being checked", readInFull: true)
            }
            return go(proof.duplicateFixity.stamp, readInFull: true)
        case .failure(let failure):
            let why: String
            switch failure {
            case .contentDiffers:               why = "not the same bytes as the archive copy"
            case .samePath:                     why = "it IS the archive copy's file (same inode)"
            case .unreadable(let path):         why = "could not be read in full (\((path as NSString).lastPathComponent))"
            case .changedSinceVerification:     why = "changed while it was being checked against the archive copy"
            case .cancelled:                    why = "the check was cancelled"
            }
            return held(why, readInFull: true)
        }
    }

    // MARK: #3 — the proof, re-checked at the mutation

    /// Off-main, immediately before the file's own Trash: both stamps must
    /// reproduce exactly (ctime included). nil = go.
    nonisolated static func pruneProofProblemOnDisk(_ p: PruneProof) -> String? {
        guard let target = FileIdentityStamp.capture(path: p.path) else {
            return "is not on disk where the catalog says — nothing moved"
        }
        guard target == p.targetStamp else {
            return "changed on disk since it was verified — nothing moved"
        }
        guard let archive = FileIdentityStamp.capture(path: p.archivePath) else {
            return "its archive copy is no longer on disk — nothing moved"
        }
        guard archive == p.archiveStamp else {
            return "its archive copy changed since it was verified — nothing moved"
        }
        return nil
    }

    /// On the main actor, just before the off-main pass: the LIVE catalog
    /// must still say what the verdict rested on. nil = go.
    ///
    /// "Live" means looked up NOW by id and the very same instance the
    /// verdict was reached on (QA 2026-09-20 on 476f82b9): a catalog
    /// reload and the derivative jobs (Trim, Cleanup, Transcode, Reformat,
    /// Balance, Rebuild) replace rows with new instances of the same id and
    /// path. Judging the object the caller handed in would move the file
    /// on a row the catalog no longer holds, stamp purgedAt on that
    /// orphan, and leave the live row saying the file is there.
    func pruneProofProblemInCatalog(_ p: PruneProof, record rec: VideoRecord) -> String? {
        guard let live = record(forID: p.copyID), live === rec, live.purgedAt == nil else {
            return "the catalog row was rebuilt or retired since it was verified — nothing moved"
        }
        guard rec.id == p.copyID, rec.purgedAt == nil else {
            return "no longer an active catalog record — nothing moved"
        }
        guard rec.fullPath == p.path else {
            return "moved in the catalog since it was verified — nothing moved"
        }
        guard rec.contentHash == p.contentKey, rec.derivedFrom == p.derivedFrom else {
            return "no longer in the family it was verified in — nothing moved"
        }
        guard let archive = record(forID: p.archiveID), archive.purgedAt == nil,
              archive.fullPath == p.archivePath else {
            return "its archive copy is no longer an active catalog record at the verified path — nothing moved"
        }
        guard archive.archiveFixity?.digest.lowercased() == p.archiveDigest else {
            return "its archive copy lost or changed its fixity since it was verified — nothing moved"
        }
        return nil
    }
}
