// RemovalReservations.swift
// One process-wide register of the media files being removed RIGHT NOW and
// of the copies those removals rely on (Codex #150 F4; closing pass F4/F5,
// rule 2). Two doors (two ⌘⌫ batches; ⌘⌫ and Delete Junk; Delete
// Duplicates; Prune; a Transcode replacing its original) could each prove
// "the other copy survives" against the other's file and both move.
//
// The protocol:
//   * LEAVING — a removal turn reserves its file for the whole turn (the
//     door's proof, the last-word gates, the move) and releases it after.
//   * RELIED ON — a removal that needs a surviving copy PINS that copy for
//     the same span. A pinned file cannot start leaving.
//   * A file that is leaving or relied on cannot be reserved by any door;
//     a leaving file cannot be pinned as anyone's survivor.
// Each door reserves itself BEFORE it pins its survivor, so of two racing
// doors the second always sees the first: at most both are held, never
// both moved. (Refuse rather than guess.)
//
// Keyed by PHYSICAL identity from a fresh stat (st_dev + st_ino — the
// same file under any spelling: case variant, symlinked directory,
// firmlink, hard link). A path that cannot be stat'ed is keyed by its
// standardized, case-folded spelling (nothing is there to remove anyway).
// Memory: one entry per file in a removal turn plus its pins — a handful.
// (A `final class` with an NSLock ≈ a C++ singleton guarding two maps with
// a std::mutex.)

import Foundation

final class RemovalReservations: @unchecked Sendable {
    static let shared = RemovalReservations()

    private let lock = NSLock()
    /// leaving file key → the survivor keys it pinned.
    private var leaving: [String: [String]] = [:]
    /// survivor key → how many removals rely on it.
    private var reliedOn: [String: Int] = [:]

    /// The physical identity of `path` now (stat follows symlinks).
    nonisolated static func key(_ path: String) -> String {
        var info = stat()
        if stat(path, &info) == 0 { return "dev\(info.st_dev):ino\(info.st_ino)" }
        return "path:" + (path as NSString).standardizingPath.lowercased()
    }

    enum Reservation { case reserved(key: String), held(note: String) }

    /// Reserve `path` as leaving. Held when it is already leaving or
    /// another removal relies on it as the copy that stays.
    func reserve(_ path: String) -> Reservation {
        let k = Self.key(path)
        return lock.withLock {
            if leaving[k] != nil { return .held(note: Self.busyNote) }
            if (reliedOn[k] ?? 0) > 0 { return .held(note: Self.reliedOnNote) }
            leaving[k] = []
            return .reserved(key: k)
        }
    }

    /// Pin, for the leaving file at `leavingPath`, every one of `survivors`
    /// that is not itself leaving and is not the same physical file.
    /// Returns the survivor paths pinned (empty → no copy may be relied on).
    func pin(_ survivors: [String], for leavingPath: String) -> [String] {
        let me = Self.key(leavingPath)
        let keyed = survivors.map { ($0, Self.key($0)) }
        return lock.withLock {
            guard leaving[me] != nil else { return [] }   // only a reserved removal may pin
            var pinned: [String] = []
            for (path, k) in keyed where k != me && leaving[k] == nil {
                reliedOn[k, default: 0] += 1
                leaving[me, default: []].append(k)
                pinned.append(path)
            }
            return pinned
        }
    }

    /// End a removal turn: the file stops leaving, its pins are dropped.
    func release(_ key: String) {
        lock.withLock {
            for k in leaving.removeValue(forKey: key) ?? [] {
                let n = (reliedOn[k] ?? 1) - 1
                reliedOn[k] = n > 0 ? n : nil
            }
        }
    }

    /// Is `path` leaving or relied on right now?
    func isReserved(_ path: String) -> Bool {
        let k = Self.key(path)
        return lock.withLock { leaving[k] != nil || (reliedOn[k] ?? 0) > 0 }
    }

    /// Run `body` — one removal turn for `path` — with `path` reserved and
    /// `survivor` (when given) pinned; release both when the turn ends.
    /// `held(note)` instead when either cannot be had.
    func whileReserved<T>(_ path: String, survivor: String?, held: (String) -> T, _ body: () -> T) -> T {
        switch reserve(path) {
        case .held(let note):
            return held(note)
        case .reserved(let key):
            defer { release(key) }
            if let survivor, pin([survivor], for: path).isEmpty { return held(Self.survivorLeavingNote) }
            return body()
        }
    }

    /// The hold for a file another turn is removing right now.
    static let busyNote = "is being removed by another job right now — nothing moved"
    /// The hold for a file another removal relies on as the copy that stays.
    static let reliedOnNote = "another job is relying on it as the copy that stays — nothing moved"
    /// The hold for a door whose surviving copy is itself being removed.
    static let survivorLeavingNote =
        "the copy that would stay is being removed by another job right now — nothing moved"
}
