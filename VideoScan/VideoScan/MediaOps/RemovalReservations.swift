// RemovalReservations.swift
// One process-wide list of the media files being removed RIGHT NOW (Codex
// #150 F4, rule 2). Two doors (two ⌘⌫ batches; ⌘⌫ and Delete Duplicates;
// Prune) could each prove "the other copy survives" against the other's
// file and both move — each proof true when made, both copies gone after.
//
// The rule: the one Trash engine reserves every file for the whole of its
// disk turn — the door's proof (`beforeRemoval`), the last-word gates and
// the move itself, one synchronous stretch — and releases it when the turn
// ends (moved, held or failed). A door that needs a surviving copy accepts
// only a copy that is NOT reserved at its own (already reserved) turn.
// Because each door reserves itself BEFORE it checks the other, two doors
// racing for two copies can never both pass: whichever checks second sees
// the first reserved. (Both may be held — refuse rather than guess.)
// A file already reserved by another turn is held, never moved twice.
//
// Keyed by the file's path (case-folded, standardized): the reservation is
// about WHICH file is leaving; the surviving-copy rule (SHA-256 identity)
// decides which files are copies. Memory: one short string per file in a
// disk turn — at most one per running door.
// (A `final class` with an NSLock ≈ a C++ singleton guarding a std::set
// with a std::mutex.)

import Foundation

final class RemovalReservations: @unchecked Sendable {
    static let shared = RemovalReservations()

    private let lock = NSLock()
    private var reserved: Set<String> = []

    /// The key for `path`: standardized, case-folded (macOS volumes are
    /// case-insensitive by default).
    nonisolated static func key(_ path: String) -> String {
        (path as NSString).standardizingPath.lowercased()
    }

    /// Reserve `path` for removal. nil when another turn already holds it.
    func reserve(_ path: String) -> String? {
        let k = Self.key(path)
        return lock.withLock { reserved.insert(k).inserted ? k : nil }
    }

    func release(_ key: String) { _ = lock.withLock { reserved.remove(key) } }

    /// Is `path` being removed by some turn right now?
    func isReserved(_ path: String) -> Bool {
        let k = Self.key(path)
        return lock.withLock { reserved.contains(k) }
    }

    /// Run `body` — one removal turn for `path` — with `path` reserved, and
    /// release it when the turn ends. `held(note)` instead when `path` is
    /// already being removed, or when `survivor` (the copy that stays) is.
    /// `path` is reserved BEFORE `survivor` is asked (see the header).
    func whileReserved<T>(_ path: String, survivor: String?, held: (String) -> T, _ body: () -> T) -> T {
        guard let key = reserve(path) else { return held(Self.busyNote) }
        defer { release(key) }
        if let survivor, isReserved(survivor) { return held(Self.survivorLeavingNote) }
        return body()
    }

    /// The hold for a file another turn is removing right now.
    static let busyNote = "is being removed by another job right now — nothing moved"
    /// The hold for a door whose surviving copy is itself being removed.
    static let survivorLeavingNote =
        "the copy that would stay is being removed by another job right now — nothing moved"
}
