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
//   1. exact full path (case-insensitive on the second pass). A path is
//      EXACT OR NOTHING (codex #976 item 3): "/Volumes/B/tape.mov" never
//      silently answers "/Volumes/A/tape.mov"; the miss carries the
//      same-basename files so the caller can offer them as chips;
//   2. exact filename, case-insensitive ("new hampshire.mov");
//   3. filename without its media extension ("New Hampshire" ↔
//      "New Hampshire.mov"; "Christmas.mov" ↔ "Christmas.mkv");
//   4. every whole token of the name is a token of the filename
//      ("Hampshire" ↔ "New Hampshire.mov") — unique, or a which-one.
//
// Catalog-verified extraction (codex #987 item 3): the recogniser hands
// over the LONGEST legal run of words before the extension ("the
// christmas tape.mov"), so tiers 2–3 are tried for that run and then for
// each shorter word-suffix of it ("christmas tape.mov", "tape.mov"), in
// that order, and the first that resolves EXACTLY wins; only then does
// the token tier run, and only for the longest run — a suffix is never
// token-matched ("Old Name.mov" must not reach "New Name.mov" through
// the tail "Name.mov"). A name that is really a file ("rick and
// donna.mov") is therefore never truncated by the recogniser, and a run
// that swallowed a sentence word ("the christmas tape.mov") still finds
// "christmas tape.mov".
//
// Two or more hits in a tier is an honest ambiguity: the TRUE count plus
// the first `maxCandidates` in catalog order; zero in every tier is not
// found. Purged records never match. The one tie-break (codex #987 item
// 5): when the question said "this video" AND a row is selected AND that
// row is one of the tied files, the selection is the answer — `preferredID`
// is that row, and it is consulted only against a real tie.
//
// Cost: O(records) per call, at most once per turn (the capture site
// resolves once and hands a snapshot to the executor); never from a view
// body. The optional index memoises tiers 2–3 for the app path so a
// 100k-record catalog pays the table once per catalog change. The memo
// key is AUTHORITATIVE (codex #987 item 1): it includes
// `VideoRecord.identityGeneration`, bumped by every filename / fullPath /
// purgedAt write in the process, so a same-buffer, same-version mutation
// rebuilds the table before it is read. Every hit is still REVALIDATED
// against the live record (codex #976 item 1) as belt and braces; a
// memo miss runs the linear tiers, which is the cost the token tier
// already paid on every miss.
// The linear form is nonisolated so the headless shell (no main actor,
// no model) uses the same rules; only the memo is `@MainActor`.
//
// (For Rick: an `enum` with only static functions ≈ a C++ namespace;
// VideoRecord is a class READ here, never mutated.)

import Foundation
import VideoScanCore

enum ArchivistRecordReferenceResolver {
    static let maxCandidates = 5
    /// At most this many word-suffixes of a typed name are tried (the
    /// full run and up to five shorter tails); longer runs are cut here.
    static let maxNameCandidates = 6

    /// One which-one choice for an ambiguous file name.
    struct Candidate: Sendable, Equatable {
        let id: UUID
        let filename: String
        let fullPath: String
    }

    enum Resolution {
        case resolved(VideoRecord)
        /// Two or more files fit the name: the first `maxCandidates` in
        /// catalog order, and how many fit in all (`total ≥ count`).
        case ambiguous([Candidate], total: Int)
        case notFound(name: String)
        /// An explicit path nobody has. `sameName` = live files whose
        /// filename is the path's basename (≤ maxCandidates, catalog
        /// order), `sameNameTotal` how many there are; both empty/0 when
        /// nothing is called that either.
        case pathNotFound(path: String, sameName: [Candidate], sameNameTotal: Int)
        /// `.currentSelection` with no selected row (or a stale id).
        case noSelection
    }

    /// The record a reference means. `recordForID` is the model's O(1)
    /// lookup (`VideoScanModel.record(forID:)`) or the shell's scan.
    /// `deictic` is true when the question itself said "this video" (or
    /// another selection noun) beside the file name: the selected row then
    /// breaks a tie among the files that fit, and nothing else.
    static func resolve(
        _ reference: ArchivistQueryAST.Record.Reference,
        selectedRecordID: UUID?,
        records: [VideoRecord],
        recordForID: (UUID) -> VideoRecord?,
        deictic: Bool = false
    ) -> Resolution {
        switch reference {
        case .currentSelection:
            return selection(selectedRecordID, recordForID: recordForID)
        case .file(let name):
            return resolve(file: name, in: records, preferredID: deictic ? selectedRecordID : nil)
        }
    }

    /// The app form: exact tiers from the revalidated memo.
    @MainActor
    static func resolve(
        _ reference: ArchivistQueryAST.Record.Reference,
        selectedRecordID: UUID?,
        records: [VideoRecord],
        recordForID: (UUID) -> VideoRecord?,
        index: ArchivistRecordReferenceIndex,
        version: RecordsVersion,
        deictic: Bool = false
    ) -> Resolution {
        switch reference {
        case .currentSelection:
            return selection(selectedRecordID, recordForID: recordForID)
        case .file(let name):
            return resolve(file: name, in: records, index: index, version: version,
                           preferredID: deictic ? selectedRecordID : nil)
        }
    }

    /// Tiers 1–4 for a file named in the question, linear: one pass over
    /// the catalog collects the exact, stem and token hits for every name
    /// candidate together, then the tiers settle in order.
    static func resolve(file rawName: String, in records: [VideoRecord], preferredID: UUID? = nil) -> Resolution {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .notFound(name: rawName) }
        let needle = filenamePart(of: name)
        if name.contains("/") {
            return pathTier(name, in: records, preferredID: preferredID, sameName: {
                let key = ArchivistKeywordText.normalizedPhrase(needle)
                return records.filter { $0.purgedAt == nil && ArchivistKeywordText.normalizedPhrase($0.filename) == key }
            })
        }
        return linearTiers(nameCandidates(needle), in: records, preferredID: preferredID)
            ?? .notFound(name: name)
    }

    /// Tiers 1–4 with tiers 2–3 served from the memo, every hit checked
    /// against the live record before it is believed.
    @MainActor
    static func resolve(
        file rawName: String,
        in records: [VideoRecord],
        index: ArchivistRecordReferenceIndex,
        version: RecordsVersion,
        preferredID: UUID? = nil
    ) -> Resolution {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .notFound(name: rawName) }
        let needle = filenamePart(of: name)
        if name.contains("/") {
            let nameKey = ArchivistKeywordText.normalizedPhrase(needle)
            return pathTier(name, in: records, preferredID: preferredID, sameName: {
                index.liveRecords(byFilename: nameKey, in: records, version: version)
                    ?? records.filter {
                        $0.purgedAt == nil && ArchivistKeywordText.normalizedPhrase($0.filename) == nameKey
                    }
            })
        }
        let candidates = nameCandidates(needle)
        for candidate in candidates {
            let nameKey = ArchivistKeywordText.normalizedPhrase(candidate)
            if let hits = index.liveRecords(byFilename: nameKey, in: records, version: version),
               let hit = settle(hits, preferredID: preferredID) {
                return hit
            }
            if let hits = index.liveRecords(byStem: stemKey(candidate), in: records, version: version),
               let hit = settle(hits, preferredID: preferredID) {
                return hit
            }
        }
        // A memo miss (or a table that was stale twice) is never trusted:
        // the linear tiers decide, at the cost the token tier already paid.
        return linearTiers(candidates, in: records, preferredID: preferredID) ?? .notFound(name: name)
    }

    /// The runs tried for a typed name, longest first: the name itself,
    /// then each word-suffix of it down to the last word plus extension
    /// ("the christmas tape.mov" → "christmas tape.mov" → "tape.mov"), at
    /// most `maxNameCandidates` of them. A one-word name is its own only
    /// candidate.
    static func nameCandidates(_ needle: String) -> [String] {
        let words = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > 1 else { return [needle] }
        var candidates: [String] = []
        for start in 0..<min(words.count, maxNameCandidates) {
            candidates.append(words[start...].joined(separator: " "))
        }
        return candidates
    }

    // MARK: - Chip labels

    /// A label per candidate for the which-one chips: the filename alone
    /// while filenames are distinct; when two candidates share a filename
    /// (the same tape on two volumes — codex #976 item 6) the volume is
    /// appended, and the parent folder when the volume is shared too.
    static func chipLabels(for candidates: [Candidate]) -> [String] {
        var byName: [String: Int] = [:]
        for candidate in candidates {
            byName[ArchivistKeywordText.normalizedPhrase(candidate.filename), default: 0] += 1
        }
        var byNameAndVolume: [String: Int] = [:]
        for candidate in candidates {
            let key = ArchivistKeywordText.normalizedPhrase(candidate.filename) + "\u{0}"
                + ArchivistKeywordText.normalizedPhrase(volumeName(of: candidate.fullPath))
            byNameAndVolume[key, default: 0] += 1
        }
        return candidates.map { candidate in
            let nameKey = ArchivistKeywordText.normalizedPhrase(candidate.filename)
            guard byName[nameKey, default: 0] > 1 else { return candidate.filename }
            let volume = volumeName(of: candidate.fullPath)
            let volumeKey = nameKey + "\u{0}" + ArchivistKeywordText.normalizedPhrase(volume)
            if byNameAndVolume[volumeKey, default: 0] > 1 {
                let folder = (candidate.fullPath as NSString).deletingLastPathComponent
                let parent = (folder as NSString).lastPathComponent
                return "\(candidate.filename) (\(parent.isEmpty ? folder : parent))"
            }
            return "\(candidate.filename) (\(volume))"
        }
    }

    /// "/Volumes/LaCie/…" → "LaCie"; a path outside /Volumes names its
    /// first folder ("Users"), a bare filename its parent folder or "/".
    static func volumeName(of path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "Volumes" { return String(parts[1]) }
        if parts.count >= 2 { return String(parts[0]) }
        return "/"
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

    /// Tier 1: a path, exact then case-insensitive; a miss is a miss
    /// (`sameName` supplies the files called the path's basename).
    private static func pathTier(
        _ path: String,
        in records: [VideoRecord],
        preferredID: UUID?,
        sameName: () -> [VideoRecord]
    ) -> Resolution {
        if let hit = settle(records.filter { $0.purgedAt == nil && $0.fullPath == path }, preferredID: preferredID) {
            return hit
        }
        let folded = ArchivistKeywordText.normalizedPhrase(path)
        if let hit = settle(records.filter {
            $0.purgedAt == nil && ArchivistKeywordText.normalizedPhrase($0.fullPath) == folded
        }, preferredID: preferredID) {
            return hit
        }
        let alike = sameName()
        return .pathNotFound(
            path: path, sameName: alike.prefix(maxCandidates).map(candidate),
            sameNameTotal: alike.count)
    }

    /// Tiers 2–4 in ONE pass over the catalog: exact and stem hits for
    /// every name candidate, settled candidate-major (the longest run's,
    /// then the next run's, …); the token tier last and for the LONGEST
    /// run only. Nil when no tier has a hit.
    private static func linearTiers(
        _ candidates: [String],
        in records: [VideoRecord],
        preferredID: UUID?
    ) -> Resolution? {
        guard !candidates.isEmpty else { return nil }
        // Per-candidate keys, computed once. The first candidate owning a
        // key wins the dictionary slot (a duplicated suffix is impossible
        // for distinct word counts, but the rule is cheap to state).
        var nameIndex: [String: Int] = [:]
        var stemIndex: [String: Int] = [:]
        for (position, candidate) in candidates.enumerated() {
            if nameIndex[ArchivistKeywordText.normalizedPhrase(candidate)] == nil {
                nameIndex[ArchivistKeywordText.normalizedPhrase(candidate)] = position
            }
            if stemIndex[stemKey(candidate)] == nil {
                stemIndex[stemKey(candidate)] = position
            }
        }
        let tokens = ArchivistKeywordText.tokens(stripMediaExtension(candidates[0]))
        var byName = [[VideoRecord]](repeating: [], count: candidates.count)
        var byStem = [[VideoRecord]](repeating: [], count: candidates.count)
        var byToken: [VideoRecord] = []
        var exactSeen = false
        for record in records where record.purgedAt == nil {
            let key = ArchivistKeywordText.normalizedPhrase(record.filename)
            if let position = nameIndex[key] { byName[position].append(record); exactSeen = true; continue }
            if let position = stemIndex[stemKey(record.filename)] { byStem[position].append(record); exactSeen = true; continue }
            if !exactSeen, !tokens.isEmpty, ArchivistKeywordText.containsAllTokens(record.filename, tokens) {
                byToken.append(record)
            }
        }
        for position in candidates.indices {
            if let hit = settle(byName[position], preferredID: preferredID) ?? settle(byStem[position], preferredID: preferredID) {
                return hit
            }
        }
        return settle(byToken, preferredID: preferredID)
    }

    /// One hit resolves; two or more are a which-one — unless the selected
    /// row (`preferredID`, set only for a deictic question) is among them.
    private static func settle(_ hits: [VideoRecord], preferredID: UUID?) -> Resolution? {
        switch hits.count {
        case 0: return nil
        case 1: return .resolved(hits[0])
        default:
            if let preferredID, let chosen = hits.first(where: { $0.id == preferredID }) {
                return .resolved(chosen)
            }
            return .ambiguous(hits.prefix(maxCandidates).map(candidate), total: hits.count)
        }
    }

    private static func candidate(_ record: VideoRecord) -> Candidate {
        Candidate(id: record.id, filename: record.filename, fullPath: record.fullPath)
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

/// Memoised filename / stem tables for the resolver's exact tiers.
///
/// Rebuilt when ANY of three keys changes: the `RecordsVersion` (count
/// catches add/remove, `volumeAggregatesRevision` catches bulk in-place
/// rewrites and, since codex #976, a Catalog rename); the records array's
/// storage identity (a same-count replacement of `VideoScanModel.records`
/// — the array is copy-on-write, so a new array is a new buffer even at
/// the same count); and `VideoRecord.identityGeneration` (codex #987 item
/// 1), bumped by every filename / fullPath / purgedAt write in the
/// process, which is what makes the table COMPLETE: a rename that turns
/// [foo, bar] into [foo, foo] at the same buffer and version is seen
/// before the "foo" bucket is read, so the second foo is in it and the
/// answer is a which-one, not the first foo. Per-hit revalidation (index
/// in range, same id, not purged, same key) stays as belt and braces and
/// rebuilds a stale table once. Memory: two dictionaries of String →
/// [Entry] over the catalog — roughly 120 bytes per record, ~12 MB at
/// 100k records, bounded by the catalog size. Purged records are left
/// out of both tables.
///
/// The generation is read through `identityGeneration` (default: the
/// live counter) so a test can pin it and exercise the revalidation path
/// on its own while other suites build records in the same process.
///
/// (For Rick: the buffer identity is `withUnsafeBufferPointer`'s base
/// address — the array's `data()` pointer; equal pointers mean the same
/// backing store, which in-place element writes keep and a replacement
/// array never has.)
@MainActor
final class ArchivistRecordReferenceIndex {
    struct Entry: Equatable {
        let index: Int
        let id: UUID
    }

    struct Tables {
        /// normalizedPhrase(filename) → entries, catalog order.
        let byFilename: [String: [Entry]]
        /// stemKey(filename) → entries, catalog order.
        let byStem: [String: [Entry]]
    }

    private let identityGeneration: () -> UInt64
    private var builtFor: RecordsVersion?
    private var builtStorage: UnsafeRawPointer?
    private var builtGeneration: UInt64?
    private var cached: Tables?
    /// Rebuild counter, exposed for the scale test ("did N lookups do
    /// ONE rebuild?") and the staleness tests.
    private(set) var rebuildCount = 0

    init(identityGeneration: @escaping () -> UInt64 = { VideoRecord.identityGeneration }) {
        self.identityGeneration = identityGeneration
    }

    /// Forget the tables; the next lookup rebuilds.
    func invalidate() {
        cached = nil
        builtFor = nil
        builtStorage = nil
        builtGeneration = nil
    }

    /// The tables for `records`, rebuilt when the version, the storage or
    /// the identity generation differs from what they were built for.
    func tables(for records: [VideoRecord], version: RecordsVersion) -> Tables {
        let storage = Self.storageIdentity(of: records)
        let generation = identityGeneration()
        if let cached, builtFor == version, builtStorage == storage, builtGeneration == generation { return cached }
        return rebuild(records, version: version, storage: storage, generation: generation)
    }

    /// The live records filed under `key` in the filename table, each one
    /// revalidated; a stale entry rebuilds the table and retries once.
    /// Nil when the table (fresh or rebuilt) is still stale — the caller
    /// falls back to the linear scan.
    func liveRecords(byFilename key: String, in records: [VideoRecord], version: RecordsVersion) -> [VideoRecord]? {
        liveRecords(in: records, version: version, entries: { $0.byFilename[key] ?? [] }) {
            ArchivistKeywordText.normalizedPhrase($0.filename) == key
        }
    }

    /// The live records filed under `stem` in the stem table, revalidated
    /// the same way.
    func liveRecords(byStem stem: String, in records: [VideoRecord], version: RecordsVersion) -> [VideoRecord]? {
        liveRecords(in: records, version: version, entries: { $0.byStem[stem] ?? [] }) {
            ArchivistRecordReferenceResolver.stemKey($0.filename) == stem
        }
    }

    private func liveRecords(
        in records: [VideoRecord],
        version: RecordsVersion,
        entries: (Tables) -> [Entry],
        stillMatches: (VideoRecord) -> Bool
    ) -> [VideoRecord]? {
        var tables = tables(for: records, version: version)
        for attempt in 0..<2 {
            if let live = Self.validated(entries(tables), in: records, stillMatches: stillMatches) {
                return live
            }
            guard attempt == 0 else { break }
            tables = rebuild(records, version: version,
                             storage: Self.storageIdentity(of: records), generation: identityGeneration())
        }
        return nil
    }

    /// The entries' records when EVERY entry still describes its record;
    /// nil the moment one does not (a rename, a replaced row, a purge).
    private static func validated(
        _ entries: [Entry],
        in records: [VideoRecord],
        stillMatches: (VideoRecord) -> Bool
    ) -> [VideoRecord]? {
        var live: [VideoRecord] = []
        live.reserveCapacity(entries.count)
        for entry in entries {
            guard records.indices.contains(entry.index) else { return nil }
            let record = records[entry.index]
            guard record.id == entry.id, record.purgedAt == nil, stillMatches(record) else { return nil }
            live.append(record)
        }
        return live
    }

    /// Build the tables. `generation` is the counter as read BEFORE the
    /// walk, so an identity write that lands during the walk invalidates
    /// the next lookup instead of hiding behind a later read.
    private func rebuild(
        _ records: [VideoRecord],
        version: RecordsVersion,
        storage: UnsafeRawPointer?,
        generation: UInt64
    ) -> Tables {
        var byFilename: [String: [Entry]] = [:]
        var byStem: [String: [Entry]] = [:]
        byFilename.reserveCapacity(records.count)
        byStem.reserveCapacity(records.count)
        for (index, record) in records.enumerated() where record.purgedAt == nil {
            let entry = Entry(index: index, id: record.id)
            byFilename[ArchivistKeywordText.normalizedPhrase(record.filename), default: []].append(entry)
            byStem[ArchivistRecordReferenceResolver.stemKey(record.filename), default: []].append(entry)
        }
        let built = Tables(byFilename: byFilename, byStem: byStem)
        cached = built
        builtFor = version
        builtStorage = storage
        builtGeneration = generation
        rebuildCount += 1
        return built
    }

    /// The array's backing-store address (internal so a test can prove an
    /// in-place element write kept the buffer).
    static func storageIdentity(of records: [VideoRecord]) -> UnsafeRawPointer? {
        records.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { UnsafeRawPointer($0) }
        }
    }
}
