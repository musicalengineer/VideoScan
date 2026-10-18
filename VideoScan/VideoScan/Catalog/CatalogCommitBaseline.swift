// CatalogCommitBaseline.swift
// What the committer believes catalog.sqlite holds, record by record
// (cutover B2.1). One value type, owned by CatalogCommitter, so the
// committer file is the serial pipeline and this file is the bookkeeping:
//
//   prints   id → fingerprint of the state the store holds (the dirty test);
//   shared   id → the SHARED curated values (stars, notes, people, …) this
//            record last agreed with the store on — the per-FIELD baseline
//            codex B2 P1-1 asked for: a row writes a shared field only when
//            THIS record changed it since then;
//   waiting  rows the store deferred or refused, at the fingerprint it saw:
//            not sent again until they change;
//   held     ids held in `pending_rows` (no whole-file digest yet — gap 1);
//            durable, so an acknowledged save is not failed by them;
//   journal  a snapshot taken at EVERY removal-marker change between two
//            commits (gap 2), so each revision lands with its own tombstone.
//
// `absorb` moves all of it after one commit and says what the committer
// must do next (lines to log, ids that need a hash job, curated values to
// copy onto sibling records, revisions to set). `propagate` copies the
// COMMITTED values onto siblings that still hold their own baseline
// (codex P1-2), and moves a sibling's fingerprint only when it was clean.
//
// Memory: per record one Int (prints) + one CatalogSharedCurated (12 small
// fields, strings and arrays shared with the record until it changes) —
// ≈ 150 B a record, 14k records ≈ 2 MB, 100k ≈ 15 MB. The journal holds a
// snapshot per marker change since the last commit (cleared by it).
//
// (For Rick: the "shadow copy" a write-behind cache keeps of what is on
// disk — a checksum per row plus a copy of the few shared columns.)

import Foundation
import VideoScanCore

struct CatalogCommitBaseline {
    typealias Fingerprint = CatalogChangeDetector.Fingerprint

    private(set) var prints: [UUID: Fingerprint] = [:]
    private(set) var shared: [UUID: CatalogSharedCurated] = [:]
    private(set) var waiting: [UUID: (print: Fingerprint, words: String)] = [:]
    private(set) var held: Set<UUID> = []
    /// Per id: (the record instance, its snapshot) at each marker change.
    private var journal: [UUID: [(instance: ObjectIdentifier, snapshot: VideoRecordDTO)]] = [:]
    /// Words already said for a partly-written row (said once until they change).
    private var partialWords: [UUID: [String]] = [:]

    // MARK: - At launch

    /// The store holds exactly these records, except `held` ones (they live
    /// in `pending_rows`, not yet as rows: they stay changed).
    mutating func adopt(_ records: [VideoRecord], held heldIDs: Set<UUID>) {
        let stored = records.filter { !heldIDs.contains($0.id) }
        let snapshots = stored.map(VideoRecordDTO.init)
        let fingerprints = CatalogChangeDetector.fingerprints(of: snapshots)
        prints = Dictionary(zip(stored.map(\.id), fingerprints), uniquingKeysWith: { first, _ in first })
        shared = Dictionary(zip(stored.map(\.id), snapshots.map(CatalogSharedCurated.init)), uniquingKeysWith: { first, _ in first })
        held = heldIDs
        waiting = [:]
        journal = [:]
        partialWords = [:]
    }

    /// A Reopen: what was refused may be tried again.
    mutating func forgetWaiting() {
        waiting = [:]
    }

    // MARK: - Between commits

    /// One removal-marker change (gap 2). Only a row the store may hold an
    /// earlier revision of needs it.
    mutating func noteMarker(id: UUID, instance: ObjectIdentifier, snapshot: VideoRecordDTO) -> Bool {
        guard prints[id] != nil else { return false }
        journal[id, default: []].append((instance, snapshot))
        return true
    }

    /// The journal entries that belong to the records the app holds now
    /// (same instance), taken out for one commit.
    mutating func takeJournal(present: [UUID: VideoRecord]) -> [UUID: [VideoRecordDTO]] {
        guard !journal.isEmpty else { return [:] }
        var taken: [UUID: [VideoRecordDTO]] = [:]
        for (id, entries) in journal {
            guard let record = present[id] else { continue }
            let mine = entries.filter { $0.instance == ObjectIdentifier(record) }.map(\.snapshot)
            if !mine.isEmpty { taken[id] = mine }
        }
        journal = [:]
        return taken
    }

    /// A commit that did not land puts its journal entries back in front.
    mutating func restoreJournal(_ taken: [UUID: [VideoRecordDTO]], present: [UUID: VideoRecord]) {
        for (id, snapshots) in taken {
            guard let record = present[id] else { continue }
            let entries = snapshots.map { (instance: ObjectIdentifier(record), snapshot: $0) }
            journal[id] = entries + (journal[id] ?? [])
        }
    }

    /// Ids the store holds (or holds pending) that the app no longer has.
    func purges(present: Set<UUID>) -> [UUID] {
        (Array(prints.keys) + Array(held)).filter { !present.contains($0) }
    }

    /// Changed records the store took nothing from and that are NOT held:
    /// what keeps an acknowledged save from being durable.
    func notDurable(_ ids: [UUID]) -> Int {
        ids.filter { !held.contains($0) }.count
    }

    // MARK: - After a commit

    /// What the committer must do after one commit.
    struct Report {
        var allStored = true
        var lines: [String] = []
        var needDigest: Set<UUID> = []
        var heldCount = 0
        var purged = 0
        /// (source id, digest, groups written, the committed values).
        var shared: [(source: UUID, digest: String, groups: [CatalogSharedCurated.Group], committed: CatalogSharedCurated)] = []
        /// (id, revision) a record whose purged row came back must carry.
        var revisions: [(id: UUID, revision: Int)] = []
    }

    /// Move the baseline for one commit's rows. `purgeRows` first (as the
    /// body ran them), then one row per `sent` item, in order.
    mutating func absorb(purgeRows: ArraySlice<CatalogCommit.RowResult>, itemRows: ArraySlice<CatalogCommit.RowResult>,
                         sent: [CatalogCommit.Item]) -> Report {
        var report = Report()
        for row in purgeRows { absorbPurge(row, into: &report) }
        for (row, item) in zip(itemRows, sent) { absorbItem(row, item: item, into: &report) }
        if report.heldCount > 0 {
            report.lines.append("Catalog store: HELD \(report.heldCount) new row(s) with no whole-file hash yet in catalog.sqlite's "
                                + "pending rows (kept across a relaunch); Fill In Full Hashes is queued for them")
        }
        return report
    }

    private mutating func absorbPurge(_ row: CatalogCommit.RowResult, into report: inout Report) {
        guard case .removed(let landing) = row.landing else {
            report.allStored = false
            if case .refused(let words) = row.landing { report.lines.append("Catalog store: NOT REMOVED \(row.id.uuidString) — \(words)") }
            return
        }
        if case .purged = landing { report.purged += 1 }
        prints[row.id] = nil
        shared[row.id] = nil
        waiting[row.id] = nil
        held.remove(row.id)
        partialWords[row.id] = nil
    }

    private mutating func absorbItem(_ row: CatalogCommit.RowResult, item: CatalogCommit.Item, into report: inout Report) {
        if let revision = row.adoptedRevision { report.revisions.append((row.id, revision)) }
        switch row.landing {
        case .written(let curated, let notes):
            settle(row, item: item)
            for note in notes { report.lines.append("Catalog store: NOTE \(row.id.uuidString) — \(note)") }
            share(row, item: item, curated: curated, into: &report)
        case .unchanged:
            settle(row, item: item)
        case .partial(let curated, let words):
            // Curated values landed; the record stays CHANGED (codex P2-7).
            shared[row.id] = CatalogSharedCurated(item.snapshot)
            report.allStored = false
            if partialWords[row.id] != words {
                partialWords[row.id] = words
                report.lines.append("Catalog store: PARTLY SAVED \(row.id.uuidString) — " + words.joined(separator: "; ")
                                    + " (it stays changed and is sent again)")
            }
            share(row, item: item, curated: curated, into: &report)
        case .deferred(let words):
            noteWaiting(row, words: words, into: &report)
            guard row.heldPending else { report.allStored = false; return }
            if !held.contains(row.id) { report.heldCount += 1 }
            held.insert(row.id)
            report.needDigest.insert(row.id)
        case .refused(let words):
            report.allStored = false
            noteWaiting(row, words: words, into: &report)
        case .removed:
            break
        }
    }

    /// The store now holds exactly this snapshot of the record.
    private mutating func settle(_ row: CatalogCommit.RowResult, item: CatalogCommit.Item) {
        prints[row.id] = row.fingerprint
        shared[row.id] = CatalogSharedCurated(item.snapshot)
        waiting[row.id] = nil
        held.remove(row.id)
        partialWords[row.id] = nil
    }

    private mutating func noteWaiting(_ row: CatalogCommit.RowResult, words: String, into report: inout Report) {
        let said = waiting[row.id]?.words == words
        waiting[row.id] = (row.fingerprint, words)
        if !said, !row.heldPending { report.lines.append("Catalog store: NOT SAVED \(row.id.uuidString) — \(words)") }
    }

    private func share(_ row: CatalogCommit.RowResult, item: CatalogCommit.Item, curated: [CatalogDDL.KnowledgeField],
                       into report: inout Report) {
        guard let digest = row.digest, !curated.isEmpty else { return }
        report.shared.append((row.id, digest, CatalogSharedCurated.groups(of: curated), CatalogSharedCurated(item.snapshot)))
    }

    // MARK: - Copies of one content (codex P1-2)

    /// Copy what was COMMITTED onto every other in-memory copy of the same
    /// content — a group only where that copy still holds its own baseline
    /// (an edit it got while the commit ran is never overwritten). The
    /// copy's per-field baseline takes the committed values (the store now
    /// shows them); its fingerprint moves only when it was clean before.
    /// Returns whether any record changed.
    mutating func propagate(_ shares: [(source: UUID, digest: String, groups: [CatalogSharedCurated.Group], committed: CatalogSharedCurated)],
                            records: [VideoRecord]) -> Bool {
        let wanted = Set(shares.map(\.digest))
        var byDigest: [String: [VideoRecord]] = [:]
        for record in records {
            guard let digest = CatalogCommit.digest(of: record), wanted.contains(digest) else { continue }
            byDigest[digest, default: []].append(record)
        }
        var touched = false
        for entry in shares {
            for copy in byDigest[entry.digest] ?? [] where copy.id != entry.source {
                if share(entry.groups, committed: entry.committed, onto: copy) { touched = true }
            }
        }
        return touched
    }

    private mutating func share(_ groups: [CatalogSharedCurated.Group], committed: CatalogSharedCurated, onto copy: VideoRecord) -> Bool {
        guard var mine = shared[copy.id] else { return false }
        let now = CatalogSharedCurated(copy)
        let wasClean = prints[copy.id] == CatalogChangeDetector.fingerprint(VideoRecordDTO(copy))
        var changed = false
        for group in groups {
            if now.same(group, as: mine), !now.same(group, as: committed) {
                committed.apply(group, to: copy)
                changed = true
            }
            mine.take(group, from: committed)
        }
        shared[copy.id] = mine
        if changed, wasClean { prints[copy.id] = CatalogChangeDetector.fingerprint(VideoRecordDTO(copy)) }
        return changed
    }
}
