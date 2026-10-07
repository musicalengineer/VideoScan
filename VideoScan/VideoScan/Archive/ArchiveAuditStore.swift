// ArchiveAuditStore.swift
// Archive tab — the two things "Audit <year>…" remembers (Rick 2026-10-07):
//
//   1. "These are different, keep both" — a repeat group Rick has looked at
//      and judged distinct. Keyed by the group's kind + the item ids, so it
//      never nags again (ArchiveAuditDecision, ArchiveAuditYear.swift).
//   2. Occasion tags — "Tag occasion ▸ Christmas / Thanksgiving / Birthday /
//      Trip / Other…" on a video the Angel could not label. The decade
//      page's cues and per-year strip honour the tag (ArchiveView+Timeline).
//
// App data, NOT the archive: one sidecar, `archive-audit.json`, under
// Application Support/VideoScan/ — the archived files and their manifest
// are read-only here (the archived-is-read-only rule; dates and names
// change only through Update…). Nothing in this file touches media.
//
// Shape follows IgnoredContentStore / HoldoutClearStore: a main-actor
// façade over a Codable value, loaded and saved off-main, written
// atomically via AtomicFilePublish (temp file + rename(2); never
// RENAME_SWAP — the Sandbox.kext wedge of 2026-09-14). Every read is O(1).
//
// POISONED STATE: a corrupt / truncated / future-version file starts the
// store EMPTY — the audit then shows every group again (over-reporting is
// the safe failure; hiding a real repeat is not) and cues fall back to the
// Angel's own reading.
//
// Worst-case memory: a decision ≈ 200 B + 40 B per id; a tag ≈ 150 B.
// Both lists are human gestures (tens to hundreds); each is capped at
// `maxEntries` (50 000, drop-oldest) so the bound is provable: ≈ 25 MB at
// the cap.

import Combine
import Foundation
import os
import VideoScanCore

private let auditStoreLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "archive.audit")

// MARK: - On-disk shapes

/// Rick's own occasion for one archived card.
struct ArchiveOccasionTag: Codable, Sendable, Equatable {
    var itemID: UUID
    /// ArchiveOccasion.rawValue ("christmas", "trip", "other", …).
    var occasion: String
    /// The row word ("Christmas", or what he typed for Other…).
    var word: String
    var taggedAt: Date
    /// Title at tag time — for a human reading the JSON, never matched.
    var title: String = ""

    /// The cue the timeline shows. An unknown raw value reads as Other.
    var cue: ArchiveOccasionCue {
        let o = ArchiveOccasion(rawValue: occasion) ?? .other
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        return ArchiveOccasionCue(occasion: o, word: w.isEmpty ? o.word : w,
                                  help: "\(w.isEmpty ? o.word : w) — you tagged this")
    }
}

struct ArchiveAuditFile: Codable, Sendable, Equatable {
    static let currentVersion = 1
    var storeVersion: Int = ArchiveAuditFile.currentVersion
    var savedAt: Date = Date()
    var decisions: [ArchiveAuditDecision] = []
    var tags: [ArchiveOccasionTag] = []
}

// MARK: - Applying tags (pure — used by the timeline memo and the audit)

enum ArchiveOccasionTags {
    /// Replace the cue of every tagged VIDEO card. O(items). Photos and
    /// audio carry no cue and stay as they are.
    static func apply(_ tags: [UUID: ArchiveOccasionTag], to items: [ArchiveTimelineItem]) -> [ArchiveTimelineItem] {
        guard !tags.isEmpty else { return items }
        return items.map { item in
            guard item.kind == .video, let tag = tags[item.id] else { return item }
            var copy = item
            copy.occasion = tag.cue
            return copy
        }
    }
}

// MARK: - Store

@MainActor
final class ArchiveAuditStore: ObservableObject {

    /// `nonisolated` so the off-main load/save can read it. (For Rick: an
    /// immutable `String` is `Sendable` — think `constexpr`.)
    nonisolated static let filename = "archive-audit.json"
    static let maxEntries = 50_000

    /// App Support/VideoScan/ in production; a per-process scratch folder
    /// under a unit-test host, so no test can write Rick's real decisions.
    nonisolated static var defaultDirectory: URL {
        if TestEnvironment.isTestHost {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("VideoScan-tests/archive-audit-\(ProcessInfo.processInfo.processIdentifier)",
                                        isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VideoScan", isDirectory: true)
    }

    let directory: URL
    nonisolated var fileURL: URL { directory.appendingPathComponent(Self.filename) }

    /// Bumped on every mutation and load — the one published signal.
    @Published private(set) var revision = 0
    /// True once `loadIfNeeded` has run (loaded or found nothing).
    private(set) var isLoaded = false

    private var decisionsByKey: [String: ArchiveAuditDecision] = [:]
    private var decisionOrder: [String] = []
    private(set) var tags: [UUID: ArchiveOccasionTag] = [:]
    private var tagOrder: [UUID] = []

    init(directory: URL = ArchiveAuditStore.defaultDirectory) {
        self.directory = directory
    }

    // MARK: Reads

    /// Oldest first — what the builder indexes and `save` writes.
    var decisions: [ArchiveAuditDecision] { decisionOrder.compactMap { decisionsByKey[$0] } }
    var decisionCount: Int { decisionsByKey.count }

    func hasDecision(kind: ArchiveAuditRepeatKind, ids: [UUID]) -> Bool {
        decisionsByKey[ArchiveAuditDecision.key(kind: kind, ids: ids)] != nil
    }

    func tag(for id: UUID) -> ArchiveOccasionTag? { tags[id] }

    // MARK: Writes (in memory — call `save()` to persist)

    /// "These are different, keep both". Returns false when already decided.
    @discardableResult
    func keepBoth(kind: ArchiveAuditRepeatKind, ids: [UUID], titles: [String] = [], now: Date = Date()) -> Bool {
        let unique = Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }
        guard unique.count >= 1 else { return false }
        let d = ArchiveAuditDecision(kind: kind, itemIDs: unique, decidedAt: now, titles: titles)
        guard decisionsByKey[d.key] == nil else { return false }
        decisionsByKey[d.key] = d
        decisionOrder.append(d.key)
        evict()
        revision &+= 1
        return true
    }

    /// Take a "keep both" back (the sheet's Undo). Returns true when found.
    @discardableResult
    func forgetDecision(kind: ArchiveAuditRepeatKind, ids: [UUID]) -> Bool {
        let key = ArchiveAuditDecision.key(kind: kind, ids: ids)
        guard decisionsByKey.removeValue(forKey: key) != nil else { return false }
        decisionOrder.removeAll { $0 == key }
        revision &+= 1
        return true
    }

    /// Tag (or re-tag) one card's occasion. `word` nil = the category word.
    func setTag(itemID: UUID, occasion: ArchiveOccasion, word: String? = nil, title: String = "",
                now: Date = Date()) {
        let w = (word ?? occasion.word).trimmingCharacters(in: .whitespacesAndNewlines)
        if tags[itemID] == nil { tagOrder.append(itemID) }
        tags[itemID] = ArchiveOccasionTag(itemID: itemID, occasion: occasion.rawValue,
                                          word: w.isEmpty ? occasion.word : w, taggedAt: now, title: title)
        evict()
        revision &+= 1
    }

    /// Back to the Angel's own reading.
    @discardableResult
    func clearTag(itemID: UUID) -> Bool {
        guard tags.removeValue(forKey: itemID) != nil else { return false }
        tagOrder.removeAll { $0 == itemID }
        revision &+= 1
        return true
    }

    /// Replace the in-memory state (does not touch disk). Duplicates
    /// collapse first-wins.
    func replace(with file: ArchiveAuditFile) {
        decisionsByKey.removeAll(); decisionOrder.removeAll()
        tags.removeAll(); tagOrder.removeAll()
        for d in file.decisions where decisionsByKey[d.key] == nil && !d.itemIDs.isEmpty {
            decisionsByKey[d.key] = d
            decisionOrder.append(d.key)
        }
        for t in file.tags where tags[t.itemID] == nil {
            tags[t.itemID] = t
            tagOrder.append(t.itemID)
        }
        evict()
        revision &+= 1
    }

    var file: ArchiveAuditFile {
        ArchiveAuditFile(decisions: decisions, tags: tagOrder.compactMap { tags[$0] })
    }

    private func evict() {
        while decisionOrder.count > Self.maxEntries { decisionsByKey.removeValue(forKey: decisionOrder.removeFirst()) }
        while tagOrder.count > Self.maxEntries { tags.removeValue(forKey: tagOrder.removeFirst()) }
    }

    // MARK: Disk

    /// Load once (the Archive tab's first appearance). Missing / malformed /
    /// wrong-version → empty.
    func loadIfNeeded() async {
        guard !isLoaded else { return }
        isLoaded = true
        if let loaded = await Self.loadOffMain(fileURL) { replace(with: loaded) }
    }

    @discardableResult
    func save() async -> Bool {
        let ok = await Self.saveOffMain(file, to: fileURL)
        if !ok { auditStoreLog.error("archive-audit.json could not be written under \(self.directory.path, privacy: .public)") }
        return ok
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func loadOffMain(_ url: URL) async -> ArchiveAuditFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let f = try? dec.decode(ArchiveAuditFile.self, from: data),
              f.storeVersion == ArchiveAuditFile.currentVersion else {
            auditStoreLog.error("archive-audit.json is unreadable or from another version — starting with no decisions or tags")
            return nil
        }
        return f
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func saveOffMain(_ file: ArchiveAuditFile, to url: URL) async -> Bool {
        do {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            // Two saves in flight (keep both, then Undo) are safe: each gets
            // its own temp, rename(2) publishes — last writer wins.
            try AtomicFilePublish.write(try enc.encode(file), to: url, durability: .fullFsync)
            return true
        } catch {
            return false
        }
    }
}
