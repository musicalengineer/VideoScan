// CleanupProof.swift
// Triage ▸ Cleanup v1 — the proof at the moment of each move (design rule 1:
// "full hashes find the candidates; a fresh read of both files is the
// proof"; codex design F1). Runs OFF the main actor, inside the one Trash
// engine's `beforeRemoval` hook, in the same synchronous stretch as the
// move itself (`JunkDiskTurn.run` → `MediaTrash.move`).
//
// A COPY goes only when, right now:
//   1. the copy that stays is read in full (FixityRebind.rehash: one opened
//      descriptor, a regular file, identity — volume UUID, device, inode,
//      size, mtime, ctime — equal before and after the read, every byte
//      counted) and it is still the physical file the plan reserved;
//   2. the extra copy is read in full the same way, and it is still the
//      physical file the plan saw — and not the same file as the keeper;
//   3. both SHA-256 digests and both byte counts are equal;
//   4. the copy that stays has not changed while the extra copy was read.
// Anything else HOLDS the file, named, and nothing moves. There is no
// stat-only shortcut (codex showed size/mtime/inode can all hold while the
// bytes differ) and no cached keeper read: rule 1 reads both, every time.
//
// JUNK goes only when it is still the file that was planned (the Delete
// Junk door's own disk re-check, FrozenJunkFiles) and is not the copy that
// stays for any group in this run (the reserved survivors, codex F2).
//
// Execution boundary, said honestly (codex F2): the last identity check and
// the Trash call are microseconds apart on one thread; nothing can make a
// physical unplug in that gap impossible, and nothing here can promise the
// keeper's drive stays connected tomorrow.
//
// Read-only on media: files are only opened O_RDONLY (by FixityRebind).
// Memory: FixityRebind's one fixed read buffer; nothing grows with size.

import Foundation
import VideoScanCore

enum CleanupProof {

    /// One file's answer.
    enum Verdict: Equatable, Sendable {
        /// Proven: the words for the receipt ("sha256:… — both read in full").
        case proven(String)
        /// Not moved, with the reason.
        case held(String)
    }

    /// The hold reason when Stop interrupted the file's check. The job
    /// counts it as "cancelled", never as a held file.
    static let stoppedNote = "not reached — the run was stopped first"

    // MARK: Ancestry, at the moment of the move

    /// Rule 3 again, at execution, for BOTH files of BOTH lanes (codex r1
    /// P1-1): after the plan, a folder on the way can be moved to a Trash,
    /// or into the archive tree, and a symlink left at its old spelling —
    /// the old path still resolves, to a file that is now inside a Trash or
    /// the Master Archive. So the path must still name a plain file by its
    /// own real name (no link anywhere on the way), nowhere in a Trash, and
    /// — by that real spelling — not in an archive root folder or an Avid
    /// MediaFiles folder. A path that is simply gone is nil here: the
    /// callers decide what "missing" means.
    static func ancestryProblem(path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return "is not a plain file now (a link or a folder) — nothing moved" }
        guard let real = CleanupDiskProbe.realPath(path) else { return "its real place could not be resolved — nothing moved" }
        guard real == path else {
            return "its folder was moved, or replaced by a link, since Cleanup planned (it is really at \(real)) — nothing moved"
        }
        if CleanupPathRules.isInTrash(path) { return "is in a Trash now — nothing moved" }
        if CleanupPathRules.isInArchiveRootFolder(path) { return "is inside the Master Archive folder now — nothing moved" }
        if CleanupPathRules.isAvidMediaFiles(path) { return "is in an Avid MediaFiles folder now — nothing moved" }
        return nil
    }

    // MARK: Copies

    /// Rule 1 for one extra copy. Blocking (two full reads).
    static func verifyCopy(_ copy: CleanupPlan.Copy, control: FixityRebind.Control) -> Verdict {
        if let why = ancestryProblem(path: copy.keeper.path) { return .held("the copy that stays (\(copy.keeper.filename)) \(why)") }
        if let why = ancestryProblem(path: copy.target.path) { return .held(why) }
        let keeper: ContentFixity
        switch read(copy.keeper.path, control: control) {
        case .failure(let why): return .held(why.prefixed("the copy that stays (\(copy.keeper.filename))"))
        case .success(let f): keeper = f
        }
        if let why = plannedFileProblem(planned: copy.keeper.identity, now: keeper.stamp) {
            return .held("the copy that stays \(why)")
        }
        let extra: ContentFixity
        switch read(copy.target.path, control: control) {
        case .failure(let why): return .held(why.prefixed("this file"))
        case .success(let f): extra = f
        }
        if let why = sameBytes(extra: extra, keeper: keeper, planned: copy.target.identity) { return .held(why) }
        guard let keeperNow = FileIdentityStamp.capture(path: copy.keeper.path), keeperNow == keeper.stamp else {
            return .held("the copy that stays changed while this file was read — nothing moved")
        }
        return .proven("sha256:\(extra.digest.prefix(16))… — both copies read in full and equal")
    }

    /// Is the file at hand STILL the one the plan froze? By the persistent
    /// identity — volume UUID + inode + size + mtime — never by device
    /// number, which a remount renumbers and another disk may reuse (codex
    /// r1 P1-2). A plan with no volume UUID can never prove it. Pure.
    static func plannedFileProblem(planned: FileIdentityStamp, now: FileIdentityStamp) -> String? {
        guard planned.volumeUUID != nil else { return "was planned on a drive with no volume identity — nothing moved" }
        guard now.volumeUUID == planned.volumeUUID else {
            return "is on a different drive than Cleanup planned (the volume at its path was swapped) — refresh Cleanup — nothing moved"
        }
        guard planned.describesSameFile(now: now, changeTime: .ignored, volume: .persistentUUID) else {
            return "is not the file Cleanup planned (it was replaced or rewritten since) — refresh Cleanup — nothing moved"
        }
        return nil
    }

    /// Steps 2–3: the extra copy's fresh read against the keeper's. Pure.
    static func sameBytes(extra: ContentFixity, keeper: ContentFixity, planned: FileIdentityStamp) -> String? {
        if let why = plannedFileProblem(planned: planned, now: extra.stamp) { return why }
        if extra.stamp.volumeUUID == keeper.stamp.volumeUUID, extra.stamp.inode == keeper.stamp.inode {
            return "is the same file as the copy that stays — nothing moved"
        }
        if extra.byteCount != keeper.byteCount {
            return "is \(extra.byteCount) bytes, the copy that stays is \(keeper.byteCount) — nothing moved"
        }
        if extra.digest != keeper.digest {
            return "its bytes differ from the copy that stays (SHA-256 \(extra.digest.prefix(12))… vs \(keeper.digest.prefix(12))…) — nothing moved"
        }
        return nil
    }

    /// Why one full read failed, in words.
    struct ReadProblem: Error, Equatable {
        let words: String
        /// "the copy that stays (a.mov) could not be read in full: … — nothing moved"
        func prefixed(_ what: String) -> String {
            words == CleanupProof.stoppedNote ? words : "\(what) could not be read in full: \(words) — nothing moved"
        }
    }

    /// One full read through the app's one fixity reader. Only Stop
    /// interrupts it (Pause is honoured by the job between files, so no
    /// worker thread ever waits here — QA P3).
    static func read(_ path: String, control: FixityRebind.Control) -> Result<ContentFixity, ReadProblem> {
        switch FixityRebind.rehash(path: path, control: control) {
        case .bound(let fixity): return .success(fixity)
        case .interrupted: return .failure(ReadProblem(words: stoppedNote))
        case .offline: return .failure(ReadProblem(words: "it is not there (or its drive went away)"))
        case .unreadable(let why): return .failure(ReadProblem(words: why))
        case .noVolumeIdentity: return .failure(ReadProblem(words: "its drive reports no volume identity"))
        case .changedDuringRead(let why): return .failure(ReadProblem(words: why))
        }
    }

    // MARK: Junk

    /// The junk lane's disk re-check, immediately before the move: still
    /// the frozen file (the Delete Junk door's check), and not a reserved
    /// survivor. Blocking (one stat + one open).
    ///
    /// A file that is not there is the engine's "already missing" — it
    /// marks the row — ONLY once the drive it was planned on is proven to
    /// be the one mounted at its path now, by volume UUID (QA P2-3, codex
    /// r1 P1-2): the engine's reachability answer is a 5 s cache, and a
    /// different disk mounted under the same name is not "the file is
    /// gone". Anything else is a HOLD. `volumeUUIDNow` asks the kernel.
    static func verifyJunk(path: String, frozen: FrozenJunkFiles, reserved: Set<CleanupPhysicalID>,
                           volumeUUIDNow: (String) -> String? = CleanupDiskProbe.mountVolumeUUID(forPath:)) -> String? {
        if let why = ancestryProblem(path: path) { return why }
        if let why = frozen.diskProblem(at: path) { return why }
        let planned = frozen.byPath[path]?.identity
        guard let now = FileIdentityStamp.capture(path: path) else {
            return missingJunkProblem(path: path, planned: planned, volumeUUIDNow: volumeUUIDNow)
        }
        if let planned, let why = plannedFileProblem(planned: planned, now: now) { return why }
        if reserved.contains(CleanupPhysicalID(now)) {
            return "is the copy that stays for another file — nothing moved"
        }
        return nil
    }

    /// Why a junk file that is not at its path may NOT be called missing:
    /// nil only when the planned volume is the one mounted there now. A
    /// boot-disk path cannot be swapped and never asks.
    static func missingJunkProblem(path: String, planned: FileIdentityStamp?,
                                   volumeUUIDNow: (String) -> String?) -> String? {
        guard VideoScanModel.isExternalVolumePath(path) else { return nil }
        let drive = VolumeReachability.volumeName(forPath: path)
        guard let plannedUUID = planned?.volumeUUID else {
            return "was planned on \(drive) with no volume identity, so its absence proves nothing — nothing moved"
        }
        guard let mounted = volumeUUIDNow(path) else { return "its drive (\(drive)) isn't connected — nothing moved" }
        guard mounted == plannedUUID else {
            return "a different drive is mounted as \(drive) now, not the one it was planned on — nothing moved"
        }
        return nil
    }
}

/// Proof words per path, written by the off-main hook and read by the main
/// actor's `settled` callback for the receipt. (≈ a std::map behind a
/// std::mutex.)
final class CleanupProofLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var words: [String: String] = [:]

    func note(_ proof: String, for path: String) { lock.withLock { words[path] = proof } }
    func proof(for path: String) -> String? { lock.withLock { words[path] } }
}
