// PartialFileNaming.swift
//
// The one naming rule for "a file an ffmpeg job is still writing":
//   <stem>.<8 hex>.vs-partial.<ext>
// beside the final destination. Combine uses it today; the Transcode /
// Reformat lane (fix/archive-protection-followups, DerivativeOutputPublish)
// uses the same shape — kept dependency-free so the Manager can point both
// at this file after they merge.
//
// Also the in-process registry of LIVE partials, so a stale-partial sweep
// can never remove a file a running job reserved.

import Foundation
import os

enum PartialFileNaming {

    static let marker = "vs-partial"

    /// `<stem>.<8 hex>.vs-partial.<ext>` beside `output`: same directory
    /// (the publish is a same-volume rename), final extension kept.
    static func uniquePartialURL(for output: URL) -> URL {
        let ext = output.pathExtension
        let token = UUID().uuidString.prefix(8).lowercased()
        return output.deletingPathExtension()
            .appendingPathExtension(String(token))
            .appendingPathExtension(marker)
            .appendingPathExtension(ext)
    }

    /// True for a name `uniquePartialURL` produces — and nothing else.
    static func isPartialName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 4 else { return false }
        let token = parts[parts.count - 3]
        return parts[parts.count - 2] == marker
            && !parts[0].isEmpty
            && token.count == 8
            && token.allSatisfy { $0.isHexDigit }
    }

    /// Partials reserved by running jobs in THIS process (standardized
    /// paths). A sweep skips anything listed here regardless of age.
    /// (C++: a std::set guarded by a spinlock; OSAllocatedUnfairLock is the
    /// Sendable wrapper for os_unfair_lock.)
    static let live = OSAllocatedUnfairLock(initialState: Set<String>())

    static func registerLive(_ url: URL) {
        let key = url.standardizedFileURL.path
        live.withLock { _ = $0.insert(key) }
    }

    static func unregisterLive(_ url: URL) {
        let key = url.standardizedFileURL.path
        live.withLock { _ = $0.remove(key) }
    }

    static func isLive(_ url: URL) -> Bool {
        let key = url.standardizedFileURL.path
        return live.withLock { $0.contains(key) }
    }
}
