// ArchiveAngelLiveBatches.swift
// Which Archive Angel batches THIS app is running right now — the only
// honest "is it alive?" signal (audit #3/#4, 2026-09-19).
//
// Before this, a batch was alive while its plan.json kept moving (rewritten
// between steps) and dead once it was an hour old. One step can run far
// longer than that without touching plan.json — the lossless frame-MD5
// verify has run 14 hours, and it only READS, so not even the folder's
// timestamps move — and the Archive tab would then settle the batch and
// delete its folder while ffmpeg was still working in it. A promote had no
// liveness at all: left `.promoting` by a quit, it stayed hidden and kept
// its rows from every later batch forever.
//
// A batch registered here is never settled, deleted or treated as stale.
// After a quit or crash the registry is empty, so the hour rule (and the
// stranded-promote settle) still catch the leftovers. Process-local by
// design: one app instance owns its buffer.

import Foundation
import os

enum ArchiveAngelLiveBatches {
    private static let live = OSAllocatedUnfairLock(initialState: [String: Int]())

    /// Mark a batch folder as being worked on (preparation or promote).
    /// Counted, so an overlapping prepare and promote of one folder both
    /// have to end before it reads as idle.
    nonisolated static func begin(_ batchDir: String) {
        let key = normalized(batchDir)
        live.withLock { $0[key, default: 0] += 1 }
    }

    nonisolated static func end(_ batchDir: String) {
        let key = normalized(batchDir)
        live.withLock { state in
            guard let n = state[key] else { return }
            state[key] = n > 1 ? n - 1 : nil
        }
    }

    nonisolated static func isLive(_ batchDir: String) -> Bool {
        let key = normalized(batchDir)
        return live.withLock { $0[key] != nil }
    }

    /// The CANONICAL folder (symlinks resolved): an alias to a live batch
    /// reads as live too (codex review 2026-09-20 #3). A path that does
    /// not exist yet resolves lexically, so begin/end before and after the
    /// folder is made agree.
    private nonisolated static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
