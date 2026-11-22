// VideoScanModel+PruneVerification.swift
// The evidence a copy needs before it may go to the Trash, and the proof it
// carries to the moment the file moves (docs/archive/design/pruneplan_simple_2026-10-21.md).
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
    /// `readHook`: the read-fault TEST seam (nil in production) — the
    /// calling task's task-local by default; the job reads it before its
    /// `Task.detached` hop and passes it in.
    private nonisolated static func pruneFullRead(_ path: String, hooks: PruneVerifyHooks,
                                                  readHook: ArchivePromoteEngine.ReadHook?) -> Result<ContentFixity, PruneHold> {
        guard !hooks.shouldCancel() else { return .failure(PruneHold("the check was cancelled")) }
        guard let before = FileIdentityStamp.capture(path: path) else { return .failure(PruneHold(PruneReason.missing.text)) }
        hooks.didOpen?(path)
        let digest: String?
        do {
            digest = try ArchivePromoteEngine.sha256(path: path, shouldCancel: hooks.shouldCancel, readHook: readHook)
        } catch ArchivePromoteEngine.Failure.changedDuringRead {
            // Its size moved under the read: changed, not unreadable.
            return .failure(PruneHold("changed while it was being read"))
        } catch {
            digest = nil
        }
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

    /// The candidate's catalog digest no longer names the archive's bytes.
    nonisolated static let catalogDigestChangedReason = "the catalog's record of this copy changed — kept"

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
                                              hooks: PruneVerifyHooks,
                                              readHook: ArchivePromoteEngine.ReadHook? = ArchivePromoteEngine.readHook)
        -> Result<PruneArchiveReading, PruneHold> {
        switch pruneFullRead(path, hooks: hooks, readHook: readHook) {
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
    /// archive and carry the archive's digest — and then be read in full a
    /// SECOND time with the same digest and the same stamp (GH #504 D3a,
    /// Codex r1 P0): the copy goes to the Trash on this proof, and one read
    /// that happens to match (a flip landing on the one bit by which the copy
    /// differs) must never be its only witness. The ONLY place a proof is made.
    ///
    /// The ARCHIVE side needs no second read: `readArchiveInFull` is itself a
    /// fresh read, once per batch, that must reproduce the archive record's
    /// STORED verified digest — a stored digest confirmed by one fresh read
    /// in this run, the same rule as Delete Duplicates' keeper (D4).
    ///
    /// Cost: one more full read of each copy that matches (from the page
    /// cache when the file fits in RAM); a copy that does not match is still
    /// read once. Memory: the engine's 24 MiB of chunk buffers per pass.
    nonisolated static func pruneCandidateProof(_ item: PruneItem, archive: PruneArchiveReading,
                                                hooks: PruneVerifyHooks,
                                                readHook: ArchivePromoteEngine.ReadHook? = ArchivePromoteEngine.readHook)
        -> Result<PruneProof, PruneHold> {
        switch pruneFullRead(item.path, hooks: hooks, readHook: readHook) {
        case .failure(let hold):
            return .failure(hold)
        case .success(let fixity):
            guard !fixity.stamp.isSameFile(as: archive.stamp) else {
                return .failure(PruneHold("it IS the archive copy's file (same inode)"))
            }
            guard fixity.digest == archive.digest, item.archiveDigest == archive.digest else {
                return .failure(PruneHold(PruneReason.mismatchAtMove.text))
            }
            if let hold = secondReadHold(of: item.path, first: fixity, hooks: hooks, readHook: readHook) {
                return .failure(hold)
            }
            return .success(PruneProof(copyID: item.copyID, path: item.path, targetStamp: fixity.stamp,
                                       archiveID: archive.archiveID, archivePath: archive.path,
                                       archiveStamp: archive.stamp, archiveDigest: archive.digest))
        }
    }

    /// The second witness (D3a): `path` read in full once more — a new open,
    /// nothing reused, cancellable like the first. nil = same digest under
    /// the same stat stamp. Otherwise why the copy is held: the second read's
    /// own failure, a stamp that moved between the reads, or two reads that
    /// disagree.
    private nonisolated static func secondReadHold(of path: String, first: ContentFixity, hooks: PruneVerifyHooks,
                                                   readHook: ArchivePromoteEngine.ReadHook?) -> PruneHold? {
        switch pruneFullRead(path, hooks: hooks, readHook: readHook) {
        case .failure(let hold):
            return hold
        case .success(let again):
            guard again.stamp == first.stamp else { return PruneHold("changed while it was being read") }
            if again.digest == first.digest { return nil }
            return PruneHold("two reads of \((path as NSString).lastPathComponent) disagreed — nothing was removed")
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
        // R1 at the move (codex P2, I5): the catalog still says this copy IS
        // the archive's bytes — the key its notes and marks are stored under.
        guard CatalogCommit.digest(of: rec) == p.archiveDigest else {
            return "\(Self.catalogDigestChangedReason) — nothing moved"
        }
        guard let archive = record(forID: p.archiveID), archive.removal == nil, archive.fullPath == p.archivePath,
              Self.verifiedArchiveDigest(archive) == p.archiveDigest else {
            return "its archive copy is no longer the verified file that was read — nothing moved"
        }
        return nil
    }
}
