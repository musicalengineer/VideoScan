// ArchiveAngelPlayHistory.swift
// "A lot of play" (Rick 2026-09-09) — read from Spotlight. macOS bumps
// kMDItemUseCount / kMDItemLastUsedDate whenever Finder, QuickTime or the
// app's player opens a file, so this carries history from BEFORE VideoScan
// existed and needs no catalog field. Read-only, per candidate, off-main.
// In-app playCount/lastPlayedAt fields are a later additive schema step
// (design §3.3, open question 2).

import Foundation
import CoreServices

enum ArchiveAngelPlayHistory {

    struct Reading: Sendable, Equatable {
        var useCount: Int
        var lastUsed: Date?
        static let none = Reading(useCount: 0, lastUsed: nil)
    }

    /// Spotlight reading for one path. Returns `.none` when the file is
    /// not indexed (network volumes, excluded folders) or unreachable.
    nonisolated static func reading(forPath path: String) -> Reading {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return .none }
        var r = Reading.none
        if let n = MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? NSNumber {
            r.useCount = max(0, n.intValue)
        }
        if let d = MDItemCopyAttribute(item, "kMDItemLastUsedDate" as CFString) as? Date {
            r.lastUsed = d
        }
        return r
    }
}
