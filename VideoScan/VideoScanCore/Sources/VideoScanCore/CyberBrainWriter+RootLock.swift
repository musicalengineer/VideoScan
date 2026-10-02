// CyberBrainWriter+RootLock.swift
// One writer per CyberBrain archive, in process (codex review #18 finding 1,
// GH #230, 2026-10-01). Split out of CyberBrainWriter.swift only to keep that
// file under the lint length limit; every durable writer there and in
// CyberBrainCorrections.swift goes through `withRootLock`.

import Foundation

extension CyberBrainWriter {

    // MARK: - One writer per archive (codex review #18, finding 1)

    /// Every durable write above and below is load → change → save. Two of
    /// them at once on one archive (the "I found a record" filer on a
    /// background task, the Research pane's Tell Hallie on the main actor,
    /// Hallie's conversation) each loaded the same file, and the last
    /// rename erased the other's passage — while BOTH callers got a receipt.
    /// So the whole read-modify-write runs under one lock per archive root,
    /// shared by every caller in this process because it lives HERE, in
    /// the writer, not in any one caller. Two app processes are not
    /// coordinated (known and accepted, same as the dossier lock).
    ///
    /// C++: a `std::mutex` per root in a mutex-guarded map, taken with a
    /// `lock_guard` around load → append → save. The lock is held for one
    /// JSON read + one fsync'd write; nothing inside awaits.
    static func withRootLock<T>(_ rootURL: URL, _ body: () throws -> T) rethrows -> T {
        let lock = rootLocks.lock(for: rootLockKey(rootURL))
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// The lock's key: the root as an absolute, standardized path with
    /// symlinks resolved, so `brain/`, `brain/sub/..` and a `/private/var`
    /// spelling of a temp root are one archive.
    static func rootLockKey(_ rootURL: URL) -> String {
        rootURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// `@unchecked Sendable` + a lock around the table ≈ a C++ class
    /// guarding its map with a mutex (Swift cannot prove the discipline).
    /// One small entry per archive root ever written — in practice one.
    fileprivate final class RootLocks: @unchecked Sendable {
        private let guardLock = NSLock()
        private var locks: [String: NSLock] = [:]
        func lock(for key: String) -> NSLock {
            guardLock.withLock {
                if let existing = locks[key] { return existing }
                let made = NSLock()
                locks[key] = made
                return made
            }
        }
    }

    fileprivate static let rootLocks = RootLocks()
}
