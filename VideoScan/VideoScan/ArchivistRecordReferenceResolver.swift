// ArchivistRecordReferenceResolver.swift
// Which ONE catalog record a `record` question means (2026-09-02).
//
// The selected Catalog row is an exact id lookup. A file NAMED in the
// question ("New Hampshire.mov", "New Hampshire", a /Volumes path) is
// matched exact-first, never by substring — the old shell `:select`
// substring rule picked the first file whose name merely contained the
// text, which for "Christmas.mov" is whichever Christmas tape happens to
// sort first. Tiers, each tried only when the previous found nothing:
//
//   1. exact full path (case-insensitive on the second pass);
//   2. exact filename, case-insensitive ("new hampshire.mov");
//   3. filename without its media extension ("New Hampshire" ↔
//      "New Hampshire.mov"; "Christmas.mov" ↔ "Christmas.mkv");
//   4. every whole token of the name is a token of the filename
//      ("Hampshire" ↔ "New Hampshire.mov") — unique, or a which-one.
//
// Two or more hits in a tier is an honest ambiguity (≤ maxCandidates
// offered, catalog order); zero in every tier is not found. Purged
// records never match.
//
// Cost: O(records) per call, at most once per turn (the capture site
// resolves once and hands a snapshot to the executor); never from a view
// body. The optional index memoises tiers 2–3 per RecordsVersion for the
// app path so a 100k-record catalog pays the table once per catalog
// change; tier 4 is a linear scan of filenames only when the exact tiers
// miss. The linear form is nonisolated so the headless shell (no main
// actor, no model) uses the same rules; only the memo is `@MainActor`.
//
// (For Rick: an `enum` with only static functions ≈ a C++ namespace;
// VideoRecord is a class READ here, never mutated.)

import Foundation
import VideoScanCore

enum ArchivistRecordReferenceResolver {
    static let maxCandidates = 5

    /// One which-one choice for an ambiguous file name.
    struct Candidate: Sendable, Equatable {
        let id: UUID
        let filename: String
        let fullPath: String
    }

    enum Resolution {
        case resolved(VideoRecord)
        /// Two or more files fit the name; the first `maxCandidates`.
        case ambiguous([Candidate])
        case notFound(name: String)
        /// `.currentSelection` with no selected row (or a stale id).
        case noSelection
    }

    /// The record a reference means. `recordForID` is the model's O(1)
    /// lookup (`VideoScanModel.record(forID:)`) or the shell's scan.
    static func resolve(
        _ reference: ArchivistQueryAST.Record.Reference,
        selectedRecordID: UUID?,
        records: [VideoRecord],
        recordForID: (UUID) -> VideoRecord?
    ) -> Resolution {
        switch reference {
        case .currentSelection:
            return selection(selectedRecordID, recordForID: recordForID)
        case .file(let name):
            return resolve(file: name, in: records)
        }
    }

    /// The app form: exact tiers from the per-RecordsVersion memo.
    @MainActor
    static func resolve(
        _ reference: ArchivistQueryAST.Record.Reference,
        selectedRecordID: UUID?,
        records: [VideoRecord],
        recordForID: (UUID) -> VideoRecord?,
        index: ArchivistRecordReferenceIndex,
        version: RecordsVersion
    ) -> Resolution {
        switch reference {
        case .currentSelection:
            return selection(selectedRecordID, recordForID: recordForID)
        case .file(let name):
            return resolve(file: name, in: records, index: index, version: version)
        }
    }

    /// Tiers 1–4 for a file named in the question, linear.
    static func resolve(file rawName: String, in records: [VideoRecord]) -> Resolution {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .notFound(name: rawName) }
        if let hit = pathTier(name, in: records) { return hit }
        let needle = filenamePart(of: name)
        let needleKey = ArchivistKeywordText.normalizedPhrase(needle)
        let needleStem = stemKey(needle)
        if let hit = settle(records.filter {
            $0.purgedAt == nil && ArchivistKeywordText.normalizedPhrase($0.filename) == needleKey
        }) {
            return hit
        }
        if let hit = settle(records.filter {
            $0.purgedAt == nil && stemKey($0.filename) == needleStem
        }) {
            return hit
        }
        return tokenTier(needle, in: records) ?? .notFound(name: name)
    }

    /// Tiers 1–4 with tiers 2–3 served from the memo.
    @MainActor
    static func resolve(
        file rawName: String,
        in records: [VideoRecord],
        index: ArchivistRecordReferenceIndex,
        version: RecordsVersion
    ) -> Resolution {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .notFound(name: rawName) }
        if let hit = pathTier(name, in: records) { return hit }
        let needle = filenamePart(of: name)
        let tables = index.tables(for: records, version: version)
        let byName = tables.byFilename[ArchivistKeywordText.normalizedPhrase(needle)] ?? []
        if let hit = settle(byName.compactMap { records.indices.contains($0) ? records[$0] : nil }) {
            return hit
        }
        let byStem = tables.byStem[stemKey(needle)] ?? []
        if let hit = settle(byStem.compactMap { records.indices.contains($0) ? records[$0] : nil }) {
            return hit
        }
        return tokenTier(needle, in: records) ?? .notFound(name: name)
    }

    // MARK: - Tiers

    private static func selection(
        _ selectedRecordID: UUID?,
        recordForID: (UUID) -> VideoRecord?
    ) -> Resolution {
        guard let id = selectedRecordID, let record = recordForID(id),
              record.purgedAt == nil else { return .noSelection }
        return .resolved(record)
    }

    /// Tier 1: a path, exact then case-insensitive. Nil when `name` is not
    /// a path or nothing has that path.
    private static func pathTier(_ name: String, in records: [VideoRecord]) -> Resolution? {
        guard name.contains("/") else { return nil }
        if let hit = settle(records.filter { $0.purgedAt == nil && $0.fullPath == name }) {
            return hit
        }
        let folded = ArchivistKeywordText.normalizedPhrase(name)
        return settle(records.filter {
            $0.purgedAt == nil && ArchivistKeywordText.normalizedPhrase($0.fullPath) == folded
        })
    }

    /// Tier 4: every whole token of the name is a token of the filename.
    private static func tokenTier(_ needle: String, in records: [VideoRecord]) -> Resolution? {
        let tokens = ArchivistKeywordText.tokens(stripMediaExtension(needle))
        guard !tokens.isEmpty else { return nil }
        return settle(records.filter {
            $0.purgedAt == nil && ArchivistKeywordText.containsAllTokens($0.filename, tokens)
        })
    }

    private static func settle(_ hits: [VideoRecord]) -> Resolution? {
        switch hits.count {
        case 0: return nil
        case 1: return .resolved(hits[0])
        default:
            return .ambiguous(hits.prefix(maxCandidates).map {
                Candidate(id: $0.id, filename: $0.filename, fullPath: $0.fullPath)
            })
        }
    }

    /// The filename part of a path, or the name as typed.
    private static func filenamePart(of name: String) -> String {
        name.contains("/") ? (name as NSString).lastPathComponent : name
    }

    /// `name` without a trailing media extension ("New Hampshire.mov" →
    /// "New Hampshire"); other dots are left alone ("v1.2 tape" stays).
    static func stripMediaExtension(_ name: String) -> String {
        guard ArchivistQueryAST.Record.endsWithMediaExtension(name),
              let dot = name.lastIndex(of: ".") else { return name }
        return String(name[..<dot])
    }

    /// The case-folded stem used by tier 3 and the index.
    static func stemKey(_ name: String) -> String {
        ArchivistKeywordText.normalizedPhrase(
            stripMediaExtension(name.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}

/// Memoised filename / stem tables for the resolver's exact tiers, rebuilt
/// at most once per `RecordsVersion` (the CatalogHelpers memo discipline:
/// count catches add/remove, `volumeAggregatesRevision` catches in-place
/// renames). Memory: two dictionaries of String → [Int] over the catalog —
/// roughly 100 bytes per record, ~10 MB at 100k records, bounded by the
/// catalog size. Purged records are left out of both tables.
@MainActor
final class ArchivistRecordReferenceIndex {
    struct Tables {
        /// normalizedPhrase(filename) → record indices, catalog order.
        let byFilename: [String: [Int]]
        /// stemKey(filename) → record indices, catalog order.
        let byStem: [String: [Int]]
    }

    private var builtFor: RecordsVersion?
    private var cached: Tables?
    /// Rebuild counter, exposed for the scale test ("did N lookups do
    /// ONE rebuild?").
    private(set) var rebuildCount = 0

    func tables(for records: [VideoRecord], version: RecordsVersion) -> Tables {
        if let cached, builtFor == version { return cached }
        var byFilename: [String: [Int]] = [:]
        var byStem: [String: [Int]] = [:]
        byFilename.reserveCapacity(records.count)
        byStem.reserveCapacity(records.count)
        for (index, record) in records.enumerated() where record.purgedAt == nil {
            byFilename[ArchivistKeywordText.normalizedPhrase(record.filename), default: []].append(index)
            byStem[ArchivistRecordReferenceResolver.stemKey(record.filename), default: []].append(index)
        }
        let built = Tables(byFilename: byFilename, byStem: byStem)
        cached = built
        builtFor = version
        rebuildCount += 1
        return built
    }
}
