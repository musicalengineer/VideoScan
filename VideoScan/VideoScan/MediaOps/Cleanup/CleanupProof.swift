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

    // MARK: Copies

    /// Rule 1 for one extra copy. Blocking (two full reads).
    static func verifyCopy(_ copy: CleanupPlan.Copy, control: FixityRebind.Control) -> Verdict {
        let keeper: ContentFixity
        switch read(copy.keeper.path, control: control) {
        case .failure(let why): return .held(why.prefixed("the copy that stays (\(copy.keeper.filename))"))
        case .success(let f): keeper = f
        }
        guard CleanupPhysicalID(keeper.stamp) == CleanupPhysicalID(copy.keeper.identity) else {
            return .held("the copy that stays is not the file Cleanup chose (it was replaced, or its drive was reconnected) — refresh Cleanup — nothing moved")
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

    /// Steps 2–3: the extra copy's fresh read against the keeper's. Pure.
    static func sameBytes(extra: ContentFixity, keeper: ContentFixity, planned: FileIdentityStamp) -> String? {
        if CleanupPhysicalID(extra.stamp) != CleanupPhysicalID(planned) {
            return "is not the file Cleanup planned (it was replaced, or its drive was reconnected) — refresh Cleanup — nothing moved"
        }
        if CleanupPhysicalID(extra.stamp) == CleanupPhysicalID(keeper.stamp) {
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

    /// One full read through the app's one fixity reader, waiting out a
    /// Pause (the file restarts from byte 0) and giving up on Stop.
    /// The wait blocks this worker thread — the same thread the read
    /// itself blocks for minutes; it is never the main thread.
    static func read(_ path: String, control: FixityRebind.Control) -> Result<ContentFixity, ReadProblem> {
        while true {
            switch FixityRebind.rehash(path: path, control: control) {
            case .bound(let fixity): return .success(fixity)
            case .interrupted:
                if control.isStopped { return .failure(ReadProblem(words: stoppedNote)) }
                while control.isPaused && !control.isStopped { Thread.sleep(forTimeInterval: 0.2) }
            case .offline: return .failure(ReadProblem(words: "it is not there (or its drive went away)"))
            case .unreadable(let why): return .failure(ReadProblem(words: why))
            case .noVolumeIdentity: return .failure(ReadProblem(words: "its drive reports no volume identity"))
            case .changedDuringRead(let why): return .failure(ReadProblem(words: why))
            }
        }
    }

    // MARK: Junk

    /// The junk lane's disk re-check, immediately before the move: still
    /// the frozen file (the Delete Junk door's check), and not a reserved
    /// survivor. Blocking (one stat + one open).
    ///
    /// A file that is not there is the engine's "already missing" — it
    /// marks the row — UNLESS its whole drive is gone (QA P2-3): the
    /// engine's reachability answer is a 5 s cache, so a drive unplugged a
    /// moment ago still reads "connected" there. `mountPresent` asks the
    /// kernel now; an unplugged drive is a HOLD, never a missing file.
    static func verifyJunk(path: String, frozen: FrozenJunkFiles, reserved: Set<CleanupPhysicalID>,
                           mountPresent: (String) -> Bool = CleanupDiskProbe.isMountPresent(forPath:)) -> String? {
        if let why = frozen.diskProblem(at: path) { return why }
        guard let now = FileIdentityStamp.capture(path: path) else {
            if VideoScanModel.isExternalVolumePath(path), !mountPresent(path) {
                return "its drive (\(VolumeReachability.volumeName(forPath: path))) isn't connected — nothing moved"
            }
            return nil
        }
        if reserved.contains(CleanupPhysicalID(now)) {
            return "is the copy that stays for another file — nothing moved"
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
