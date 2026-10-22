// VideoScanModel+PruneVerification.swift
// The evidence a copy needs before it may go to the Trash, and the proof it
// carries to the moment the file moves (docs/design/pruneplan_simple_2026-10-21.md).
//
// I1 — BOTH FILES, READ IN FULL, IN THIS BATCH. The archive file is read end
// to end once per archive file per batch (`pruneArchiveReading`); its SHA-256
// must equal the archive's verified digest. The candidate is then read end to
// end; its SHA-256 must equal the same digest. No stored stamp stands in for
// either read — not the promotion source's stamp, not a past Verify. Each
// read is bound to the stat taken before it (`ContentFixity.captured`), so a
// file that changed while it was read is held.
//
// THE PROOF TRAVELS TO THE MUTATION. A `PruneProof` can only be made from an
// archive reading of this batch and the candidate's own read
// (`pruneCandidateProof`, the one constructor). At the move, the Trash
// routine's `JunkDeletionGuard` re-asks the live catalog on the main actor
// (same row instance, same path, archive still the same verified file) and
// re-stats BOTH files immediately before the file's own Trash: either stamp
// changed → held, nothing moves.
//
// Everything here except `pruneProofProblemInCatalog` is a pure function of
// paths and digests, off the main actor. Memory: one 1 MiB read window per
// read (ArchivePromoteEngine.sha256); nothing is retained.
//
// (For Rick: `PruneProof` is the receipt the verifier hands the mover — "I
// read THIS inode and THAT inode in full and they agree" — and the guard is
// the mover refusing anything whose receipt no longer matches.)

import Foundation
import VideoScanCore

extension VideoScanModel {

    // MARK: Seams

    /// Hooks for the prune verification. `didOpen` fires with the path of
    /// EVERY file opened for a full read, so a test counts real opens.
    /// `beforeMutation` runs on the main actor with the copy's path after its
    /// verdict and before its move. `removeFile` replaces the Trash call
    /// (tests only — the mode is always `.toTrash`). `isNetworkMount` is the
    /// network probe asked immediately before the move.
    struct PruneVerifyHooks: @unchecked Sendable {
        var shouldCancel: () -> Bool
        var didOpen: ((String) -> Void)?
        var beforeMutation: (@MainActor (String) -> Void)?
        var removeFile: (@Sendable (URL) throws -> Void)?
        var isNetworkMount: @Sendable (String) -> Bool = { ArchiveVolumeProtection.isNetworkMount($0) }

        static let live = PruneVerifyHooks(shouldCancel: { Task.isCancelled })
    }

    /// Why a copy is held, as a value a `Result` can carry.
    struct PruneHold: Error, Equatable, Sendable {
        let text: String
        init(_ text: String) { self.text = text }
    }

    // MARK: One full read

    /// Read `path` end to end; the digest is bound to the stat taken before
    /// the read, which the stat after it must reproduce. Never on main.
    private nonisolated static func pruneFullRead(_ path: String, hooks: PruneVerifyHooks) -> Result<ContentFixity, PruneHold> {
        guard !hooks.shouldCancel() else { return .failure(PruneHold("the check was cancelled")) }
        guard let before = FileIdentityStamp.capture(path: path) else { return .failure(PruneHold(PruneReason.missing.text)) }
        hooks.didOpen?(path)
        let digest = (try? ArchivePromoteEngine.sha256(path: path, shouldCancel: hooks.shouldCancel)) ?? nil
        guard let digest, !digest.isEmpty else {
            return .failure(PruneHold(hooks.shouldCancel() ? "the check was cancelled" : "could not be read in full"))
        }
        guard let fixity = ContentFixity.captured(path: path, digest: digest.lowercased(), byteCount: before.size,
                                                  before: before) else {
            return .failure(PruneHold("changed while it was being read"))
        }
        return .success(fixity)
    }

    // MARK: The archive file, once per batch

    /// What a full read of the archive file proved, in this batch.
    struct PruneArchiveReading: Sendable, Equatable {
        let archiveID: UUID
        let path: String
        let digest: String
        let stamp: FileIdentityStamp
    }

    private nonisolated static let archiveChangedReason = "archive copy changed — its bytes no longer match its verified fixity; "
        + "nothing in this family may go until Verify Archive Copies has looked at it"

    nonisolated static func readArchiveInFull(id: UUID, path: String, digest: String,
                                              hooks: PruneVerifyHooks) -> Result<PruneArchiveReading, PruneHold> {
        switch pruneFullRead(path, hooks: hooks) {
        case .failure(let hold):
            return .failure(PruneHold("its archive copy: \(hold.text)"))
        case .success(let fixity):
            guard fixity.digest == digest else { return .failure(PruneHold(archiveChangedReason)) }
            return .success(PruneArchiveReading(archiveID: id, path: path, digest: digest, stamp: fixity.stamp))
        }
    }

    // MARK: The candidate, and the proof

    /// The receipt a verdict hands to the mover.
    struct PruneProof: Sendable, Equatable {
        let copyID: UUID
        let path: String
        /// The copy's identity when its full read finished.
        let targetStamp: FileIdentityStamp
        let archiveID: UUID
        let archivePath: String
        /// The archive file's identity when ITS full read (this batch) finished.
        let archiveStamp: FileIdentityStamp
        let archiveDigest: String
    }

    /// Read the candidate in full; it must be a different file from the
    /// archive and carry the archive's digest. The ONLY place a proof is made.
    nonisolated static func pruneCandidateProof(_ item: PruneItem, archive: PruneArchiveReading,
                                                hooks: PruneVerifyHooks) -> Result<PruneProof, PruneHold> {
        switch pruneFullRead(item.path, hooks: hooks) {
        case .failure(let hold):
            return .failure(hold)
        case .success(let fixity):
            guard !fixity.stamp.isSameFile(as: archive.stamp) else {
                return .failure(PruneHold("it IS the archive copy's file (same inode)"))
            }
            guard fixity.digest == archive.digest, item.archiveDigest == archive.digest else {
                return .failure(PruneHold(PruneReason.mismatchAtMove.text))
            }
            return .success(PruneProof(copyID: item.copyID, path: item.path, targetStamp: fixity.stamp,
                                       archiveID: archive.archiveID, archivePath: archive.path,
                                       archiveStamp: archive.stamp, archiveDigest: archive.digest))
        }
    }

    // MARK: The proof, re-checked at the mutation

    /// Off-main, immediately before the file's own Trash: both stamps must
    /// reproduce exactly (ctime included). nil = go.
    nonisolated static func pruneProofProblemOnDisk(_ p: PruneProof) -> String? {
        guard let target = FileIdentityStamp.capture(path: p.path) else {
            return "is not on disk where the catalog says — nothing moved"
        }
        guard target == p.targetStamp else { return "changed on disk since it was read — nothing moved" }
        guard let archive = FileIdentityStamp.capture(path: p.archivePath) else {
            return "its archive copy is no longer on disk — nothing moved"
        }
        guard archive == p.archiveStamp else { return "its archive copy changed since it was read — nothing moved" }
        return nil
    }

    /// On the main actor, just before the off-main pass: the LIVE catalog
    /// must still say what the proof rested on — the very row instance (a
    /// reload or a derivative job replaces rows with new instances of the
    /// same id and path), at the same path, and the archive file still the
    /// same verified file. nil = go.
    func pruneProofProblemInCatalog(_ p: PruneProof, record rec: VideoRecord) -> String? {
        guard let live = record(forID: p.copyID), live === rec, live.removal == nil else {
            return "the catalog row was rebuilt or retired since it was read — nothing moved"
        }
        guard rec.fullPath == p.path else { return "moved in the catalog since it was read — nothing moved" }
        guard let archive = record(forID: p.archiveID), archive.removal == nil, archive.fullPath == p.archivePath,
              Self.verifiedArchiveDigest(archive) == p.archiveDigest else {
            return "its archive copy is no longer the verified file that was read — nothing moved"
        }
        return nil
    }
}
